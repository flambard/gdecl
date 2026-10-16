(in-package :gd-extension-callback)

;;;
;;; Methods, see GD-EXTENSION:BIND-METHOD
;;;
;;; Godot calls a bound method through one of two callbacks: ptrcall_func with
;;; pointers to the raw values (the fast path), or call_func with Variants (the
;;; dynamic path). All methods share the same two callbacks, METHOD-PTRCALL and
;;; METHOD-CALL. The method_userdata of a method identifies a BOUND-METHOD,
;;; which says which Lisp function to call and how to convert its arguments and
;;; return value. Virtual methods are bound methods too, called through
;;; CALL-VIRTUAL-WITH-DATA, at the end of this file (see extension-classes.lisp).
;;;
;;; A Lisp function can't be passed to C, so the BOUND-METHODs are kept in
;;; *BOUND-METHODS* and method_userdata is (1+ index), so that it's never NULL.
;;;
;;; The functions get the instance's Lisp object (see INSTANCE-OBJECT), like
;;; self in GDScript.
;;;

(defun method-value-type (variant-type &optional (errorp t))
  "The VALUE-TYPE of VARIANT-TYPE, if the dispatcher can convert it: a type with
a raw value that can also be a Variant. Otherwise signals an error, or returns
NIL if ERRORP is false."
  (let ((value-type (find-value-type variant-type nil)))
    (cond ((and value-type
                (integerp (value-type-variant-type value-type))
                (value-type-ffi-type value-type)
                (value-type-reader value-type))
           value-type)
          (errorp
           (error "Unsupported type for a bound method: variant type ~s" variant-type)))))

(defstruct bound-method
  ;; For error messages, e.g. "Player.start"
  name
  function
  ;; VALUE-TYPEs; NIL as the return type means no return value
  return-type
  argument-types
  ;; A function that does what PTRCALL-BOUND-METHOD does, generated for the
  ;; method's signature (see PTRCALL-INVOKER-FORM), or NIL
  (invoker nil))

(defvar *bound-methods* (make-array 0 :adjustable t :fill-pointer t))

(defun register-method (function &key name (return-type +variant-type-nil+) argument-types
                                      invoker)
  "Register FUNCTION as a method and return its method_userdata. FUNCTION is
called with the instance's Lisp object and one Lisp value per argument.
RETURN-TYPE and ARGUMENT-TYPES are variant types. NAME, e.g. \"Player.start\",
is used in error messages. INVOKER, if given, is the function of
PTRCALL-INVOKER-FORM for the signature, which makes calls with ptrcall faster."
  (ffi:make-pointer (1+ (vector-push-extend
                         (make-bound-method :name name
                                            :function function
                                            :return-type (unless (= return-type +variant-type-nil+)
                                                           (method-value-type return-type))
                                            :argument-types (mapcar #'method-value-type
                                                                    argument-types)
                                            :invoker invoker)
                         *bound-methods*))
                    :void))

(defun userdata-method (userdata)
  (aref *bound-methods* (1- (ffi:pointer-address userdata))))

;; Inline: CALLABLE-CALL (callables.lisp) calls it at every call. With optional
;; arguments, not keywords, which ECL's inlined code would parse at runtime.
(declaim (inline set-call-error))
(defun set-call-error (r-error error &optional (argument 0) (expected 0))
  (set-foreign-slots (r-error call-error)
    error error
    argument argument
    expected expected))

(defun ptrcall-bound-method (method-userdata instance args r-ret)
  "Call the method identified by METHOD-USERDATA, with ARGS and R-RET as in
ptrcall_func: an array of pointers to the raw argument values, and a pointer to
where the raw return value goes."
  (let* ((method (userdata-method method-userdata))
         (invoker (bound-method-invoker method)))
    (if invoker
        (funcall invoker (bound-method-function method) (instance-object instance) args r-ret)
        (let* ((return-type (bound-method-return-type method))
               (arguments (loop for type in (bound-method-argument-types method)
                                for i from 0
                                collect (read-value (foreign-ref args :pointer-void i) type)))
               (result (apply (bound-method-function method) (instance-object instance)
                              arguments)))
          (when return-type
            ;; An Object result comes with a reference for Godot, if it's
            ;; RefCounted
            (when (eql (value-type-variant-type return-type) +variant-type-object+)
              (reference-for-caller result))
            (write-value r-ret return-type result))))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun invoker-argument-form (value-type args index)
    "A form that reads argument INDEX, of VALUE-TYPE, from ARGS, the array of
pointers to raw values of ptrcall_func. The raw values of simple types (see
VALUE-TYPE-FROM-RAW) are read with C code, without a pointer object in between."
    (let ((from-raw (value-type-from-raw value-type))
          (ffi-type (value-type-ffi-type value-type)))
      (if from-raw
          (funcall from-raw
                   `(ffi:c-inline (,args) (:pointer-void) ,ffi-type
                                  ,(format nil "*(~a *)((void **)#0)[~d]"
                                           (c-type-name ffi-type) index)
                                  :one-liner t))
          `(,(value-type-reader value-type) (foreign-ref ,args :pointer-void ,index)))))

  (defun ptrcall-invoker-form (return-type argument-types)
    "A LAMBDA form for the invoker of a bound method with RETURN-TYPE and
ARGUMENT-TYPES (variant types, see REGISTER-METHOD): a function of the method's
function, the instance's Lisp object, and ARGS and R-RET of ptrcall_func, which
does what PTRCALL-BOUND-METHOD does, with the code for each type generated, so
without a list of the arguments, APPLY or calling converters by name. NIL if
the dispatcher can't convert one of the types."
    (let ((return-value-type (and (not (eql return-type +variant-type-nil+))
                                  (method-value-type return-type nil)))
          (argument-value-types (mapcar (lambda (type) (method-value-type type nil))
                                        argument-types))
          (function (gensym "FUNCTION"))
          (self (gensym "SELF"))
          (args (gensym "ARGS"))
          (r-ret (gensym "R-RET"))
          (result (gensym "RESULT")))
      (unless (or (and (not return-value-type) (not (eql return-type +variant-type-nil+)))
                  (member nil argument-value-types))
        `(lambda (,function ,self ,args ,r-ret)
           (declare (ignorable ,args ,r-ret))
           ,(let ((call `(funcall ,function ,self
                                  ,@(loop for value-type in argument-value-types
                                          for i from 0
                                          collect (invoker-argument-form value-type args i)))))
              (if return-value-type
                  `(let ((,result ,call))
                     ;; An Object result comes with a reference for Godot, if
                     ;; it's RefCounted
                     ,@(when (eql return-type +variant-type-object+)
                         `((reference-for-caller ,result)))
                     (,(value-type-writer return-value-type) ,r-ret ,result))
                  call)))))))

(defun call-bound-method (method-userdata instance args argument-count r-return r-error)
  "Call the method identified by METHOD-USERDATA, with arguments and return
value as Variants, as in call_func."
  (let* ((method (userdata-method method-userdata))
         (return-type (bound-method-return-type method))
         (argument-types (bound-method-argument-types method))
         (expected-count (length argument-types)))
    (cond ((< argument-count expected-count)
           (set-call-error r-error +call-error-too-few-arguments+ 0 expected-count))
          ((> argument-count expected-count)
           (set-call-error r-error +call-error-too-many-arguments+ 0 expected-count))
          (t
           (let ((arguments '()))
             (loop for value-type in argument-types
                   for type = (value-type-variant-type value-type)
                   for i from 0
                   for variant = (foreign-ref args :pointer-void i)
                   for variant-type = (variant-get-type variant)
                   do (cond ((= variant-type type)
                             (push (read-variant-as variant value-type) arguments))
                            ;; null for an Object
                            ((and (= type +variant-type-object+)
                                  (= variant-type +variant-type-nil+))
                             (push nil arguments))
                            ;; A float for an int and an int for a float, as
                            ;; Godot converts them for its own methods (the
                            ;; float truncated, like int() in GDScript)
                            ((and (= type +variant-type-int+)
                                  (= variant-type +variant-type-float+))
                             (push (values (truncate (read-variant variant))) arguments))
                            ((and (= type +variant-type-float+)
                                  (= variant-type +variant-type-int+))
                             (push (float (read-variant variant) 1d0) arguments))
                            (t
                             (set-call-error r-error +call-error-invalid-argument+ i type)
                             (return-from call-bound-method))))
             (let ((result (apply (bound-method-function method) (instance-object instance)
                                  (nreverse arguments))))
               (when return-type
                 (write-variant-as r-return return-type result))))))))

;; void (*GDExtensionClassMethodPtrCall)(void *method_userdata,
;;                                       GDExtensionClassInstancePtr p_instance,
;;                                       const GDExtensionConstTypePtr *p_args,
;;                                       GDExtensionTypePtr r_ret)
(define-callback method-ptrcall :void
    ((method-userdata :pointer-void) (instance :pointer-void)
     (args :pointer-void) (r-ret :pointer-void))
  (with-callback-protection ((bound-method-name (userdata-method method-userdata)))
    (ptrcall-bound-method method-userdata instance args r-ret)))

;; void (*GDExtensionClassMethodCall)(void *method_userdata,
;;                                    GDExtensionClassInstancePtr p_instance,
;;                                    const GDExtensionConstVariantPtr *p_args,
;;                                    GDExtensionInt p_argument_count,
;;                                    GDExtensionVariantPtr r_return,
;;                                    GDExtensionCallError *r_error)
(define-callback method-call :void
    ((method-userdata :pointer-void) (instance :pointer-void)
     (args :pointer-void) (argument-count :int64-t)
     (r-return :pointer-void) (r-error :pointer-void))
  ;; There's no call error for a failing method, and Godot already initialized
  ;; R-ERROR to OK and R-RETURN to Nil, so after an error the method returns
  ;; null, like a GDScript method that fails
  (with-callback-protection ((bound-method-name (userdata-method method-userdata)))
    (call-bound-method method-userdata instance args argument-count r-return r-error)))

;; void (*GDExtensionClassCallVirtualWithData)(GDExtensionClassInstancePtr p_instance,
;;                                             GDExtensionConstStringNamePtr p_name,
;;                                             void *p_virtual_call_userdata,
;;                                             const GDExtensionConstTypePtr *p_args,
;;                                             GDExtensionTypePtr r_ret)
(define-callback call-virtual-with-data :void
    ((instance :pointer-void) (name :pointer-void) (virtual-call-userdata :pointer-void)
     (args :pointer-void) (r-ret :pointer-void))
  (declare (ignore name))
  (with-callback-protection ((bound-method-name (userdata-method virtual-call-userdata)))
    (ptrcall-bound-method virtual-call-userdata instance args r-ret)))
