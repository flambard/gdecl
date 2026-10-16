(in-package :gd-extension-callback)

;;;
;;; Callables, see GD-EXTENSION-TYPES:CALLABLE
;;;
;;; WRITE-CALLABLE makes a custom Godot Callable that calls a Lisp function. All
;;; custom Callables share the same two callbacks, CALLABLE-CALL and
;;; CALLABLE-FREE. Their callable_userdata is (1+ index) into *CALLABLES*, which
;;; keeps the functions; CALLABLE-FREE forgets the function when Godot frees the
;;; last copy of the Callable.
;;;

(defvar *callables* (make-array 0 :adjustable t :fill-pointer t))
(defvar *free-callables* '())

(defun add-callable-function (function)
  (let ((index (if *free-callables*
                   (let ((index (pop *free-callables*)))
                     (setf (aref *callables* index) function)
                     index)
                   (vector-push-extend function *callables*))))
    (ffi:make-pointer (1+ index) :void)))

(defun userdata-callable-function (userdata)
  (aref *callables* (1- (ffi:pointer-address userdata))))

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
    (let ((index (1- (ffi:pointer-address callable-userdata))))
      (setf (aref *callables* index) nil)
      (push index *free-callables*))))
