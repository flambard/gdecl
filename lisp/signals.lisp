(in-package :gd-extension)

;;;
;;; Signals
;;;
;;; CONNECT-SIGNAL connects a signal to a Lisp function, through a custom
;;; Callable (see GD-EXTENSION-TYPES:CALLABLE). AFTER-SIGNAL does it once, for
;;; what GDScript does with await.
;;;

;; Object.ConnectFlags.CONNECT_ONE_SHOT, for AFTER-SIGNAL. Applications use
;; GODOT:+OBJECT-CONNECT-ONE-SHOT+, generated from extension_api.json, which
;; GD-EXTENSION can't depend on.
(defconstant +connect-one-shot+ 4)

(define-engine-method object-connect ("Object" "connect"))

(defun connect-signal (object signal-name function &key (target object) (flags 0))
  "Connect the signal SIGNAL-NAME (a StringName, see SNAME, or a literal string)
of OBJECT to the Lisp FUNCTION, which is called with the signal's arguments as
Lisp values, like signal.connect(callable, flags) in GDScript. The connection
is bound to TARGET (a Godot object or its Lisp object, by default OBJECT): it's
removed when TARGET is freed. FLAGS are Object.ConnectFlags, such as
GODOT:+OBJECT-CONNECT-DEFERRED+. Returns Godot's error code, such as GODOT:+OK+."
  (object-connect object signal-name (callable target function) flags))

;; A literal string as SIGNAL-NAME becomes (SNAME string), as for engine methods
(define-compiler-macro connect-signal (&whole form &rest arguments)
  (or (wrap-literal-names 'connect-signal arguments '((1 . sname)))
      form))

(defmacro after-signal ((object signal-name &key target) &body body)
  "Evaluate BODY once, the next time OBJECT emits the signal SIGNAL-NAME (a
StringName, see SNAME, or a literal string), like the code after await object.signal_name in GDScript.
Returns right away. TARGET is as in CONNECT-SIGNAL; with TARGET the object that
the code belongs to, BODY isn't run if that object has been freed by then."
  (let ((object-var (gensym "OBJECT")))
    `(let ((,object-var ,object))
       (connect-signal ,object-var ,signal-name
                       (lambda (&rest arguments)
                         (declare (ignore arguments))
                         ,@body)
                       :target ,(or target object-var)
                       :flags +connect-one-shot+))))
