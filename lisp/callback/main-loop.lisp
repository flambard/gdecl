(in-package :gd-extension-callback)

;;;
;;; A function called once every frame
;;;
;;; Godot 4.5 and later call an extension's frame callback once every frame, on
;;; the main thread, after the nodes' _process methods
;;; (register_main_loop_callbacks). The callback is registered only when a frame
;;; function is first set, so an application that doesn't use one doesn't enter
;;; Lisp every frame for nothing. The eval server (eval-server.lisp in
;;; GD-EXTENSION) sets it.
;;;

(defvar *frame-function* nil
  "The function designator MAIN-LOOP-FRAME calls once every frame, or NIL.")

(define-callback main-loop-frame :void ()
  (with-callback-protection ("frame function")
    (when *frame-function*
      (funcall *frame-function*))))

(defvar *main-loop-callbacks-registered* nil)

(defun register-main-loop-callbacks ()
  "Have Godot call MAIN-LOOP-FRAME once every frame. Looked up only now, rather
than by LOAD-INTERFACE, as Godot before 4.5 reports an error for an interface
function it doesn't have."
  (let ((register (get-proc-address "register_main_loop_callbacks")))
    (when (ffi:null-pointer-p register)
      (error "Calling a function every frame needs Godot 4.5 or later"))
    ;; GDExtensionMainLoopCallbacks: startup_func, shutdown_func and
    ;; frame_func. Godot copies them.
    (with-foreign-memory ((callbacks '(:array :pointer-void 3)))
      (setf (foreign-ref callbacks :pointer-void 0) (ffi:make-null-pointer :void)
            (foreign-ref callbacks :pointer-void 1) (ffi:make-null-pointer :void)
            (foreign-ref callbacks :pointer-void 2) (callback-pointer 'main-loop-frame))
      (ffi:c-inline (register *class-library* callbacks)
                    (:pointer-void :pointer-void :pointer-void) :void
                    "((void (*)(void *, const void *))#0)(#1, #2)" :one-liner t))))

(defun set-frame-function (function)
  "Call FUNCTION, a function designator taking no arguments, once every frame
from now on, on the main thread, after the nodes' _process methods; no function
if NIL. Each call is a callback, with an autorelease pool of its own, and an
error in it is reported. Signals an error before Godot 4.5."
  (when (and function (not *main-loop-callbacks-registered*))
    (register-main-loop-callbacks)
    (setf *main-loop-callbacks-registered* t))
  (setf *frame-function* function))
