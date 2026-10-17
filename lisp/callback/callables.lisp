(in-package :gd-extension-callback)

;;;
;;; Callables, see GD-EXTENSION-TYPES:CALLABLE and ENGINE-CALLABLE
;;;
;;; WRITE-CALLABLE makes a custom Godot Callable that calls a Lisp function, from
;;; a CALLABLE. All custom Callables share the same two callbacks,
;;; CALLABLE-CALL and CALLABLE-FREE. Their callable_userdata is the handle in
;;; *CALLABLES* (see handle-tables.lisp), which keeps the CALLABLE;
;;; CALLABLE-FREE forgets it when Godot frees the last copy of the Callable.
;;;
;;; READ-CALLABLE turns a Godot Callable back into a Lisp value: one of Lisp's
;;; own, found by its token and callable_userdata, into the CALLABLE it was
;;; made from, and any other into an ENGINE-CALLABLE with a copy of it, which
;;; the autorelease pool destroys when the call from Godot returns (see
;;; autorelease-pool.lisp in GD-EXTENSION-TYPES). KEEP-CALLABLE makes a copy
;;; that isn't in the pool, and FREE-CALLABLE destroys one.
;;;

(define-handle-table *callables*
  "The CALLABLEs of the custom Callables, by callable_userdata.")

(declaim (inline userdata-callable))
(defun userdata-callable (userdata)
  (handle-value *callables* userdata))

(defun copy-godot-callable (to from)
  "Construct a copy of the Godot Callable at FROM at TO, uninitialized memory."
  (with-foreign-memory ((args '(:array :pointer-void 1)))
    (setf (foreign-ref args :pointer-void 0) from)
    (call-ptr-constructor *callable-copy-constructor* to args)))

(defun new-engine-callable (pointer)
  "An ENGINE-CALLABLE with a copy of the Godot Callable at POINTER, which isn't
in the autorelease pool."
  (let ((copy (mem-alloc +callable-size+)))
    (copy-godot-callable copy pointer)
    (make-engine-callable copy)))

(defun read-callable (pointer)
  "The Godot Callable at POINTER as a Lisp value: the CALLABLE it was made from,
if it's one of Lisp's own, otherwise an ENGINE-CALLABLE with a copy of it, in
the autorelease pool."
  (let ((userdata (callable-custom-get-userdata pointer *class-library*)))
    (if (ffi:null-pointer-p userdata)
        (autorelease-callable (new-engine-callable pointer))
        (userdata-callable userdata))))

(defun write-callable (pointer callable)
  "Construct a Godot Callable at POINTER, uninitialized memory, from CALLABLE: a
custom Callable from a Lisp CALLABLE, or a copy of an ENGINE-CALLABLE's. Destroy
it with CALLABLE-DESTRUCTOR. Godot keeps a CALLABLE until the last copy of its
Callable is destroyed."
  (etypecase callable
    (callable
     (with-foreign-memory ((info 'callable-custom-info2))
       ;; All slots not set below are NULL/0
       (clear-foreign-object info 'callable-custom-info2)
       (set-foreign-slots (info callable-custom-info2)
         callable-userdata (add-handle *callables* callable)
         token *class-library*
         object-id (object-get-instance-id (object-pointer (callable-target callable)))
         call-func (callback-pointer 'callable-call)
         free-func (callback-pointer 'callable-free))
       (callable-custom-create2 pointer info)))
    (engine-callable
     (copy-godot-callable pointer (engine-callable-memory callable)))))

(add-value-type (make-value-type :variant-type +variant-type-callable+
                                 :ffi-type 'godot-callable
                                 :reader 'read-callable
                                 :writer 'write-callable
                                 :destructor 'callable-destructor
                                 :lisp-type '(or callable engine-callable)))

(defun keep-callable (callable)
  "CALLABLE, for keeping it after the call from Godot it came in returns, e.g. in
a slot: for an ENGINE-CALLABLE, a new ENGINE-CALLABLE with a copy of its Godot
Callable that isn't in the autorelease pool, to destroy with FREE-CALLABLE when
it's no longer needed; a Lisp CALLABLE as it is."
  (etypecase callable
    (callable callable)
    (engine-callable (new-engine-callable (engine-callable-memory callable)))))

(defun free-callable (callable)
  "Destroy the copy of a Godot Callable that the ENGINE-CALLABLE CALLABLE has, such
as one from KEEP-CALLABLE, now. Using CALLABLE afterwards signals an error. Does
nothing for a Lisp CALLABLE."
  (when (engine-callable-p callable)
    (release-engine-callable callable))
  nil)

;; void (*GDExtensionCallableCustomCall)(void *callable_userdata,
;;                                       const GDExtensionConstVariantPtr *p_args,
;;                                       GDExtensionInt p_argument_count,
;;                                       GDExtensionVariantPtr r_return,
;;                                       GDExtensionCallError *r_error)
;;
;; The pointers are integers, as for METHOD-PTRCALL (see PTRCALL-BOUND-METHOD),
;; so that no pointer objects are made for them, except for the arguments'
;; Variants and a result.
;;
;; The result of the function is returned as a Variant, if it can be one (see
;; VARIANT-VALUE-P); NIL, and values that can't be Variants yet, return null.
;; Callables are mostly signal handlers, whose results Godot ignores, so a
;; result that can't be returned isn't an error. Godot doesn't initialize
;; R-ERROR, so it's always set; to OK also after a Lisp error, as for a bound
;; method that fails.
(define-callback callable-call :void
    ((callable-userdata :uint64-t) (args :uint64-t) (argument-count :int64-t)
     (r-return :uint64-t) (r-error :uint64-t))
  (with-callback-protection ("Lisp callable")
    ;; GDExtensionCallError: error (OK), argument and expected
    (ffi:c-inline (r-error) (:uint64-t) :void
                  "{ int32_t *e = (int32_t *)#0; e[0] = 0; e[1] = 0; e[2] = 0; }"
                  :one-liner nil)
    (let ((result (apply (callable-function (address-handle-value *callables*
                                                                  callable-userdata))
                         (loop for i below argument-count
                               collect (read-variant (argument-pointer args i))))))
      (let ((variant-type (and result (lisp-variant-type result))))
        (when variant-type
          ;; R-RETURN is a Variant already (Nil). Written before the pool
          ;; gives back its references, so an object in it stays alive.
          (let ((r-return (address-pointer r-return)))
            (variant-destroy r-return)
            (write-variant-as r-return (find-value-type variant-type) result)))))))

;; void (*GDExtensionCallableCustomFree)(void *callable_userdata)
(define-callback callable-free :void ((callable-userdata :pointer-void))
  (with-callback-protection ("free Lisp callable")
    (remove-handle *callables* callable-userdata)))
