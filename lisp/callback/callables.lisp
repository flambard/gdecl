(in-package :gd-extension-callback)

;;;
;;; Callables, see GD-EXTENSION-TYPES:CALLABLE
;;;
;;; WRITE-CALLABLE makes a custom Godot Callable that calls a Lisp function. All
;;; custom Callables share the same two callbacks, CALLABLE-CALL and
;;; CALLABLE-FREE. Their callable_userdata is the handle in *CALLABLES* (see
;;; handle-tables.lisp), which keeps the functions; CALLABLE-FREE forgets the
;;; function when Godot frees the last copy of the Callable.
;;;

(define-handle-table *callables*
  "The functions of the Callables, by callable_userdata.")

(defun add-callable-function (function)
  (add-handle *callables* function))

(declaim (inline userdata-callable-function))
(defun userdata-callable-function (userdata)
  (handle-value *callables* userdata))

(defun write-callable (pointer callable)
  "Construct a custom Godot Callable at POINTER, uninitialized memory, from the
Lisp CALLABLE. Destroy it with CALLABLE-DESTRUCTOR; Godot keeps the Lisp function
until the last copy of the Callable is destroyed."
  (with-foreign-memory ((info 'callable-custom-info2))
    ;; All slots not set below are NULL/0
    (clear-foreign-object info 'callable-custom-info2)
    (set-foreign-slots (info callable-custom-info2)
      callable-userdata (add-callable-function (callable-function callable))
      token *class-library*
      object-id (object-get-instance-id (object-pointer (callable-target callable)))
      call-func (callback-pointer 'callable-call)
      free-func (callback-pointer 'callable-free))
    (callable-custom-create2 pointer info)))

(add-value-type (make-value-type :variant-type +variant-type-callable+
                                 :ffi-type 'godot-callable
                                 :writer 'write-callable
                                 :destructor 'callable-destructor
                                 :lisp-type 'callable))

;; void (*GDExtensionCallableCustomCall)(void *callable_userdata,
;;                                       const GDExtensionConstVariantPtr *p_args,
;;                                       GDExtensionInt p_argument_count,
;;                                       GDExtensionVariantPtr r_return,
;;                                       GDExtensionCallError *r_error)
;;
;; The result of the function is returned as a Variant, if it can be one (see
;; VARIANT-VALUE-P); NIL, and values that can't be Variants yet, return null.
;; Callables are mostly signal handlers, whose results Godot ignores, so a
;; result that can't be returned isn't an error. Godot doesn't initialize
;; R-ERROR, so it's always set; to OK also after a Lisp error, as for a bound
;; method that fails.
(define-callback callable-call :void
    ((callable-userdata :pointer-void) (args :pointer-void) (argument-count :int64-t)
     (r-return :pointer-void) (r-error :pointer-void))
  (with-callback-protection ("Lisp callable")
    (set-call-error r-error +call-ok+)
    (let ((result (apply (userdata-callable-function callable-userdata)
                         (loop for i below argument-count
                               collect (read-variant (foreign-ref args :pointer-void i))))))
      (let ((variant-type (and result (lisp-variant-type result))))
        (when variant-type
          ;; R-RETURN is a Variant already (Nil). Written before the pool
          ;; gives back its references, so an object in it stays alive.
          (variant-destroy r-return)
          (write-variant-as r-return (find-value-type variant-type) result))))))

;; void (*GDExtensionCallableCustomFree)(void *callable_userdata)
(define-callback callable-free :void ((callable-userdata :pointer-void))
  (with-callback-protection ("free Lisp callable")
    (remove-handle *callables* callable-userdata)))
