(in-package :gd-extension)

;;;
;;; The eval server: evaluating Lisp forms in a running application
;;;
;;; For development: with the environment variable GDECL_EVAL_PORT set to a
;;; port number, START-EVAL-SERVER, a step of the framework's startup
;;; (lifecycle.lisp), listens on that port on 127.0.0.1, and evaluates the forms
;;; that clients send, such as bin/gdecl-eval. It runs anything it's sent, so it
;;; only listens on the loopback interface, and only when asked to.
;;;
;;; It's served once every frame on the main thread (SET-FRAME-FUNCTION,
;;; main-loop.lisp in GD-EXTENSION-CALLBACK), so the forms can call any of
;;; Godot's API, and nothing but the sockets is shared with another thread. Every
;;; socket call is non-blocking, so a slow client can't hold up a frame; a form
;;; that takes long does, as it runs in the frame.
;;;
;;; The protocol: a client connects, sends the forms as UTF-8 text ending with a
;;; NUL byte (or by closing its side of the connection), and reads the reply
;;; until the server closes the connection. The reply's first line is "ok" or
;;; "error"; then comes what the forms printed, then the values of the last form
;;; one per line, printed with PRIN1, or, after an error, its type and message.
;;; The forms are read and evaluated in the package the previous request ended
;;; in, CL-USER at first, so an IN-PACKAGE lasts, and *, ** and *** are set as
;;; in a REPL.
;;;
;;; Each form is compiled before it runs (EVALUATE), as ECL's interpreter can't
;;; run what gdecl's macros expand into, so a request takes about 0.1 s a form
;;; and needs the C compiler and ECL's compiler module.
;;;
;;; The forms run as at a REPL, not as in a callback: there's no autorelease
;;; pool (see autorelease-pool.lisp), so they own the references they get, and
;;; there's no standard input to read from or debugger to enter: either signals
;;; an error, reported to the client.
;;;
;;; The sockets are ECL's module SOCKETS (SB-BSD-SOCKETS), loaded only when the
;;; server starts, as it's a file of ECL's installation rather than part of the
;;; library. So its package doesn't exist when this file is loaded, and its
;;; functions are found by name (SOCKETS-CALL). With nothing to accept, its
;;; non-blocking SOCKET-ACCEPT signals INTERRUPTED-ERROR rather than returning
;;; NIL, about 9 us and 600 bytes a frame (measured standalone).
;;;

(defvar *eval-server-socket* nil
  "The eval server's listening socket while it runs, otherwise NIL.")

(defvar *eval-connections* '()
  "The EVAL-CONNECTIONs being served.")

(defvar *eval-package* (find-package "COMMON-LISP-USER")
  "The package the next request is read and evaluated in.")

(defstruct (eval-connection (:constructor make-eval-connection (socket)))
  socket
  ;; The request's octets received so far
  (request (make-array 256 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))
  ;; The reply's octets once the request is evaluated, and how many are sent
  (reply nil)
  (sent 0))

;;;
;;; ECL's sockets, by name
;;;

(defun sockets-function (name)
  "The function NAME of SB-BSD-SOCKETS, a string, or (SETF string)."
  (flet ((sockets-symbol (name)
           (or (find-symbol name "SB-BSD-SOCKETS")
               (error "SB-BSD-SOCKETS has no symbol ~a" name))))
    (fdefinition (if (consp name)
                     (list 'setf (sockets-symbol (second name)))
                     (sockets-symbol name)))))

(defmacro sockets-call (name &rest arguments)
  "Call the function NAME of SB-BSD-SOCKETS (see SOCKETS-FUNCTION) with
ARGUMENTS."
  `(funcall (sockets-function ',name) ,@arguments))

(defun socket-would-block-p (condition)
  "True if CONDITION is how a non-blocking socket call of SB-BSD-SOCKETS says it
has nothing to do now, in ECL an INTERRUPTED-ERROR."
  (typep condition (find-symbol "INTERRUPTED-ERROR" "SB-BSD-SOCKETS")))

(defmacro unless-would-block (&body body)
  "Evaluate BODY, and return NIL instead if a socket call in it would block."
  `(handler-case (progn ,@body)
     (error (condition)
       (if (socket-would-block-p condition)
           nil
           (error condition)))))

(defun make-non-blocking (socket)
  (sockets-call (setf "NON-BLOCKING-MODE") t socket))

;;;
;;; Starting and stopping
;;;

(defun eval-server-port ()
  "The port in the environment variable GDECL_EVAL_PORT, or NIL if it isn't
set."
  (let ((value (ext:getenv "GDECL_EVAL_PORT")))
    (when (and value (string/= value ""))
      (let ((port (ignore-errors (parse-integer value))))
        (unless (and port (< 0 port 65536))
          (error "GDECL_EVAL_PORT must be a port number, not ~s" value))
        port))))

(defun start-eval-server ()
  "Start the eval server, if the environment variable GDECL_EVAL_PORT has a port
for it (see EVAL-SERVER-PORT): listen on that port on 127.0.0.1, and serve the
requests once every frame."
  (let ((port (eval-server-port)))
    (when (and port (not *eval-server-socket*))
      (require :sockets)
      ;; For EVALUATE, now rather than in the first request's output
      (require :cmp)
      (let ((socket (make-instance (find-symbol "INET-SOCKET" "SB-BSD-SOCKETS")
                                   :type :stream :protocol :tcp))
            (listening nil))
        (unwind-protect
             (progn
               ;; So a restarted application can listen on the port at once
               (sockets-call (setf "SOCKOPT-REUSE-ADDRESS") t socket)
               (sockets-call "SOCKET-BIND" socket #(127 0 0 1) port)
               (sockets-call "SOCKET-LISTEN" socket 5)
               (make-non-blocking socket)
               (setf *eval-server-socket* socket)
               (set-frame-function 'serve-eval-requests)
               (setf listening t))
          (unless listening
            (setf *eval-server-socket* nil)
            (ignore-errors (sockets-call "SOCKET-CLOSE" socket))))
        (format t "~&gdecl: the eval server is listening on 127.0.0.1:~d~%" port)
        (finish-output)))))

(defun stop-eval-server ()
  "Stop the eval server, if it runs, and close its connections."
  (when *eval-server-socket*
    (set-frame-function nil)
    (dolist (connection *eval-connections*)
      (ignore-errors (sockets-call "SOCKET-CLOSE" (eval-connection-socket connection))))
    (setf *eval-connections* '())
    (ignore-errors (sockets-call "SOCKET-CLOSE" *eval-server-socket*))
    (setf *eval-server-socket* nil)))

;;;
;;; Serving
;;;

(defun serve-eval-requests ()
  "Accept new connections, and serve each one: receive its request, evaluate it
once it's complete, and send the reply. The frame function of the eval server.
An error here, rather than in a client's forms, stops the server, so that it's
reported once rather than every frame."
  (let ((served nil))
    (unwind-protect
         (progn
           (loop for socket = (unless-would-block
                                (sockets-call "SOCKET-ACCEPT" *eval-server-socket*))
                 while socket
                 do (make-non-blocking socket)
                    (push (make-eval-connection socket) *eval-connections*))
           (setf *eval-connections* (delete-if-not #'serve-eval-connection *eval-connections*)
                 served t))
      (unless served
        (stop-eval-server)))))

(defun serve-eval-connection (connection)
  "Serve CONNECTION as far as can be done now. Returns true if it's to be served
again, and NIL once it's closed: the reply is sent, or the client is gone."
  (let ((finished (handler-case
                       (progn
                         (unless (eval-connection-reply connection)
                           (receive-eval-request connection))
                         (and (eval-connection-reply connection)
                              (send-eval-reply connection)))
                     ;; E.g. the client closed the connection
                     (error () t))))
    (when finished
      (ignore-errors (sockets-call "SOCKET-CLOSE" (eval-connection-socket connection))))
    (not finished)))

(defvar *eval-receive-buffer*
  (make-array 4096 :element-type '(unsigned-byte 8)))

(defun receive-eval-request (connection)
  "Receive what the client of CONNECTION has sent. Once the request is complete,
evaluate it and set the connection's reply."
  (let ((request (eval-connection-request connection)))
    (loop
      (multiple-value-bind (octets length)
          (unless-would-block
            (sockets-call "SOCKET-RECEIVE" (eval-connection-socket connection)
                          *eval-receive-buffer* nil))
        (cond ((null octets)            ; Nothing more for now
               (return))
              ((zerop length)           ; The client closed its side
               (setf (eval-connection-reply connection) (evaluate-request request))
               (return))
              (t
               (loop for i below length
                     do (vector-push-extend (aref octets i) request))
               (let ((end (position 0 request)))
                 (when end
                   (setf (fill-pointer request) end
                         (eval-connection-reply connection) (evaluate-request request))
                   (return)))))))))

(defun send-eval-reply (connection)
  "Send as much of CONNECTION's reply as the socket takes now. Returns true once
it's all sent."
  (let ((reply (eval-connection-reply connection)))
    (loop while (< (eval-connection-sent connection) (length reply))
          do (let ((count (unless-would-block
                            (sockets-call "SOCKET-SEND" (eval-connection-socket connection)
                                          (subseq reply (eval-connection-sent connection))
                                          nil :nosignal t))))
               (if (and count (plusp count))
                   (incf (eval-connection-sent connection) count)
                   (return))))
    (>= (eval-connection-sent connection) (length reply))))

;;;
;;; Evaluating
;;;

(defun evaluate (form)
  "Evaluate FORM compiled, as the application's code is, rather than with ECL's
bytecode interpreter, which can't run FFI:C-INLINE, and gdecl's macros expand
into it (the invokers of DEFINE-GODOT-GENERIC, DEFINE-ENGINE-CLASS,
WITH-FOREIGN-MEMORY, ...). Compiling takes about 0.1 s, as ECL runs the C
compiler, so an atom, which can't contain any, is evaluated as it is."
  (if (consp form)
      (let ((function (compile nil `(lambda () ,form))))
        (unless function
          (error "Compiling the form failed"))
        (funcall function))
      (eval form)))

(defun evaluate-request (octets)
  "Read and evaluate the forms in OCTETS, UTF-8 text, as described at the top of
this file, and return the reply, as UTF-8 octets."
  (let* ((output (make-string-output-stream))
         (no-input (make-string-input-stream ""))
         (io (make-two-way-stream no-input output))
         (*standard-output* output)
         (*error-output* output)
         (*trace-output* output)
         (*standard-input* no-input)
         (*query-io* io)
         (*debug-io* io)
         (*terminal-io* io)
         (*package* *eval-package*)
         (*autorelease-pool* :none)
         ;; Rather than *DEBUGGER-HOOK*, which BREAK binds to NIL
         (ext:*invoke-debugger-hook* (lambda (condition hook)
                                       (declare (ignore hook))
                                       (throw 'eval-request condition)))
         (results '())
         (condition
           (catch 'eval-request
             (handler-bind ((serious-condition
                              (lambda (condition) (throw 'eval-request condition))))
               (with-input-from-string
                   (forms (ext:octets-to-string octets :external-format :utf-8))
                 (loop for form = (read forms nil forms)
                       until (eq form forms)
                       do (setf results (multiple-value-list (evaluate form)))
                          (setf *** ** ** * * (first results))))
               (fresh-line output)
               (dolist (result results)
                 (prin1 result output)
                 (terpri output)))
             nil)))
    (setf *eval-package* *package*)
    (when condition
      (fresh-line output)
      (format output "~s: ~a~%" (type-of condition)
              (or (ignore-errors (princ-to-string condition)) "(unprintable)")))
    (ext:string-to-octets (format nil "~:[ok~;error~]~%~a" condition
                                  (get-output-stream-string output))
                          :external-format :utf-8)))
