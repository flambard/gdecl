(in-package :gd-extension)

;;;
;;; Godot's Callables in Lisp
;;;
;;; A Callable that Lisp gets from Godot is a Lisp CALLABLE if it's one of
;;; Lisp's own, and otherwise an ENGINE-CALLABLE, valid until the call from Godot
;;; it came in returns unless kept with KEEP-CALLABLE (both converted in
;;; callables.lisp in GD-EXTENSION-CALLBACK). CALL-CALLABLE calls either, and
;;; CALLABLE= compares them.
;;;

(defun call-callable (callable &rest arguments)
  "Call CALLABLE with ARGUMENTS, like callable.call(...) in GDScript, and return
its result. A Lisp CALLABLE's function is called directly. An ENGINE-CALLABLE is
called through Godot (Callable.callv), with ARGUMENTS as Variants, and its
result read as with READ-VARIANT-RESULT; if the call fails, Godot reports the
error, and the result is NIL."
  (etypecase callable
    (callable (apply (callable-function callable) arguments))
    (engine-callable
     (with-foreign-memory ((array 'godot-array)
                           (args '(:array :pointer-void 1))
                           (result 'variant))
       (write-array array arguments)
       (unwind-protect
            (progn
              (setf (foreign-ref args :pointer-void 0) array)
              ;; Null, as Godot assigns the result into it
              (clear-foreign-object result 'variant)
              (call-ptr-builtin-method (builtin-method "Callable" "callv")
                                       (engine-callable-memory callable) args result 1)
              (unwind-protect (read-variant-result result)
                (variant-destroy result)))
         (array-destructor array))))))

(defun callable= (a b)
  "True if the Callables A and B are equal: the same Lisp CALLABLE, or
ENGINE-CALLABLEs that Godot considers equal, such as the same method of the same
object."
  (if (and (engine-callable-p a) (engine-callable-p b))
      (with-foreign-memory ((result :uint8-t))
        (call-ptr-operator-evaluator *callable-equal-evaluator*
                                     (engine-callable-memory a) (engine-callable-memory b)
                                     result)
        (/= (foreign-ref result :uint8-t) 0))
      (eq a b)))
