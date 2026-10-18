(in-package :gd-extension)

;;;
;;; Signals
;;;
;;; CONNECT-SIGNAL connects a signal to a Lisp function, through a custom
;;; Callable (see GD-EXTENSION-TYPES:CALLABLE). GODOT:AFTER-SIGNAL
;;; (godot/signals.lisp) does it once, for what GDScript does with await.
;;;
;;; A Signal as a value is an ENGINE-SIGNAL, the signal's object and name, a Lisp
;;; value of its own. Its value type is added here, since reading a Signal
;;; needs its builtin methods get_object and get_name. EMIT-ENGINE-SIGNAL and
;;; CONNECT-ENGINE-SIGNAL emit and connect it.
;;;

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

;;;
;;; Signals as values
;;;

(defun read-signal (pointer)
  "The Godot Signal at POINTER as an ENGINE-SIGNAL."
  (with-foreign-memory ((object :pointer-void)
                        (name 'string-name))
    (let ((no-arguments (load-time-value (ffi:make-null-pointer :void))))
      (call-ptr-builtin-method (builtin-method "Signal" "get_object") pointer no-arguments
                               object 0)
      ;; An empty StringName, as Godot assigns the result into it
      (clear-foreign-object name 'string-name)
      (call-ptr-builtin-method (builtin-method "Signal" "get_name") pointer no-arguments
                               name 0)
      (unwind-protect
           (engine-signal (read-value object (find-value-type +variant-type-object+))
                          (read-string-name name))
        (string-name-destructor name)))))

(defun write-signal (pointer signal)
  "Construct a Godot Signal at POINTER, uninitialized memory, from the
ENGINE-SIGNAL SIGNAL. Destroy it with SIGNAL-DESTRUCTOR."
  (with-string-name (name (engine-signal-name signal))
    (with-foreign-memory ((object :pointer-void)
                          (args '(:array :pointer-void 2)))
      (setf (foreign-ref object :pointer-void) (object-pointer (engine-signal-object signal))
            (foreign-ref args :pointer-void 0) object
            (foreign-ref args :pointer-void 1) name)
      ;; Constructor 2 of Signal takes an Object and a StringName
      (call-ptr-constructor (initialize-cell-value
                             (variant-get-ptr-constructor +variant-type-signal+ 2))
                            pointer args))))

(add-value-type (make-value-type :variant-type +variant-type-signal+
                                 :ffi-type 'godot-signal
                                 :reader 'read-signal
                                 :writer 'write-signal
                                 :destructor 'signal-destructor
                                 :lisp-type 'engine-signal))

(define-engine-method object-emit-signal ("Object" "emit_signal"))

(defun emit-engine-signal (signal &rest arguments)
  "Emit the ENGINE-SIGNAL SIGNAL with ARGUMENTS, converted to Variants, like
signal.emit(...) in GDScript. Returns Godot's error code, such as GODOT:+OK+."
  (apply #'object-emit-signal (engine-signal-object signal) (engine-signal-name signal)
         arguments))

(defun connect-engine-signal (signal function
                              &key (target (engine-signal-object signal)) (flags 0))
  "Connect the ENGINE-SIGNAL SIGNAL to the Lisp FUNCTION, as CONNECT-SIGNAL does,
with TARGET and FLAGS as there. Returns Godot's error code."
  (connect-signal (engine-signal-object signal) (engine-signal-name signal) function
                  :target target :flags flags))
