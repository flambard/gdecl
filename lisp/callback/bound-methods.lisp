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
;;; *BOUND-METHODS*, a handle table (see handle-tables.lisp), whose handles are
;;; the method_userdata.
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

(define-handle-table *bound-methods*
  "The BOUND-METHODs, by method_userdata.")

(defun register-method (function &key name (return-type +variant-type-nil+) argument-types
                                      invoker)
  "Register FUNCTION as a method and return its method_userdata. FUNCTION is
called with the instance's Lisp object and one Lisp value per argument.
RETURN-TYPE and ARGUMENT-TYPES are variant types. NAME, e.g. \"Player.start\",
is used in error messages. INVOKER, if given, is the function of
PTRCALL-INVOKER-FORM for the signature, which makes calls with ptrcall faster."
  (add-handle *bound-methods*
              (make-bound-method :name name
                                 :function function
                                 :return-type (unless (= return-type +variant-type-nil+)
                                                (method-value-type return-type))
                                 :argument-types (mapcar #'method-value-type argument-types)
                                 :invoker invoker)))

(declaim (inline userdata-method))
(defun userdata-method (userdata)
  (handle-value *bound-methods* userdata))

;; Inline: CALLABLE-CALL (callables.lisp) calls it at every call. With optional
;; arguments, not keywords, which ECL's inlined code would parse at runtime.
(declaim (inline set-call-error))
(defun set-call-error (r-error error &optional (argument 0) (expected 0))
  (set-foreign-slots (r-error call-error)
    error error
    argument argument
    expected expected))

;;; The callbacks of ptrcalls, METHOD-PTRCALL and CALL-VIRTUAL-WITH-DATA, get
;;; their pointers as integers, the addresses, as ECL would make a pointer
;;; object for each of them otherwise: measured with `make bench`, a call into
;;; an empty Lisp method took about 150 ns more, 90 ns of it making the four
;;; pointer objects (128 bytes) and 60 ns getting the addresses of the handles
;;; back out of them (FFI:POINTER-ADDRESS). The invokers read the raw values of
;;; simple types and write those results through the addresses in C; a pointer
;;; object is made only for the readers and writers of the other types.

(defun argument-pointer (args index)
  "A pointer object for the raw value of argument INDEX, from ARGS, the address
of ptrcall_func's array of pointers to them."
  (ffi:c-inline (args index) (:uint64-t :int) :pointer-void "((void **)#0)[#1]"
                :one-liner t))

(declaim (inline argument-address))
(defun argument-address (args index)
  "The address of argument INDEX, from ARGS, the address of an array of pointers
to the arguments."
  (ffi:c-inline (args index) (:uint64-t :int) :uint64-t "(uint64_t)((void **)#0)[#1]"
                :one-liner t))

(defun ptrcall-bound-method (method-address instance-address args r-ret)
  "Call the method whose method_userdata has the address METHOD-ADDRESS on the
instance whose GDExtensionClassInstancePtr has the address INSTANCE-ADDRESS,
with ARGS and R-RET as in ptrcall_func: the addresses of an array of pointers
to the raw argument values, and of where the raw return value goes. All are
integers (see above)."
  (let* ((method (address-handle-value *bound-methods* method-address))
         (invoker (bound-method-invoker method)))
    (if invoker
        (funcall invoker (bound-method-function method)
                 (address-instance-object instance-address) args r-ret)
        (let* ((return-type (bound-method-return-type method))
               (arguments (loop for type in (bound-method-argument-types method)
                                for i from 0
                                collect (read-value (argument-pointer args i) type)))
               (result (apply (bound-method-function method)
                              (address-instance-object instance-address)
                              arguments)))
          (when return-type
            ;; An Object result comes with a reference for Godot, if it's
            ;; RefCounted
            (when (eql (value-type-variant-type return-type) +variant-type-object+)
              (reference-for-caller result))
            (write-value (address-pointer r-ret) return-type result))))))

(defun write-failed-result (method r-ret)
  "After METHOD, a BOUND-METHOD called with ptrcall, signaled an error, store the
default value of its return type at R-RET (an address, an integer), such as 0,
false or Vector2(0, 0)
(the type's constructor 0), or null for an Object, so that the caller doesn't
read whatever was there before. A return type with a destructor, such as
String, is left as it is: Godot passes such a value constructed already, an
empty one when GDScript calls."
  (let ((return-type (bound-method-return-type method))
        (r-ret (address-pointer r-ret)))
    (when (and return-type (null (value-type-destructor return-type)))
      (let ((variant-type (value-type-variant-type return-type)))
        (if (= variant-type +variant-type-object+)
            (setf (foreign-ref r-ret :pointer-void) (ffi:make-null-pointer :void))
            (call-ptr-constructor (variant-get-ptr-constructor variant-type 0) r-ret
                                  (ffi:make-null-pointer :void)))))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun invoker-argument-form (value-type args index)
    "A form that reads argument INDEX, of VALUE-TYPE, from ARGS, the address of
ptrcall_func's array of pointers to raw values. The raw values of simple types
(see VALUE-TYPE-FROM-RAW) are read with C code, without a pointer object in
between."
    (let ((from-raw (value-type-from-raw value-type))
          (ffi-type (value-type-ffi-type value-type)))
      (if from-raw
          (funcall from-raw
                   `(ffi:c-inline (,args) (:uint64-t) ,ffi-type
                                  ,(format nil "*(~a *)((void **)#0)[~d]"
                                           (c-type-name ffi-type) index)
                                  :one-liner t))
          `(,(value-type-reader value-type)
            (ffi:c-inline (,args) (:uint64-t) :pointer-void
                          ,(format nil "((void **)#0)[~d]" index) :one-liner t)))))

  (defun invoker-result-form (value-type r-ret result)
    "A form that stores RESULT, a Lisp value of VALUE-TYPE, at R-RET, the address
where ptrcall_func's raw return value goes: with C code for a simple type,
otherwise with the type's writer."
    (let ((to-raw (value-type-to-raw value-type))
          (ffi-type (value-type-ffi-type value-type)))
      (if to-raw
          `(ffi:c-inline (,r-ret ,(funcall to-raw result)) (:uint64-t ,ffi-type) :void
                         ,(format nil "*(~a *)#0 = #1" (c-type-name ffi-type))
                         :one-liner t)
          `(,(value-type-writer value-type) (address-pointer ,r-ret) ,result))))

  (defun ptrcall-invoker-form (return-type argument-types)
    "A LAMBDA form for the invoker of a bound method with RETURN-TYPE and
ARGUMENT-TYPES (variant types, see REGISTER-METHOD): a function of the method's
function, the instance's Lisp object, and the addresses ARGS and R-RET of
ptrcall_func (integers, see PTRCALL-BOUND-METHOD), which
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
                     ,(invoker-result-form return-value-type r-ret result))
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
;;
;; If the method fails, its return value is the default value of its type
;; (WRITE-FAILED-RESULT), written only then, so it costs nothing per call.
;; The pointers are integers, see PTRCALL-BOUND-METHOD.
(define-callback method-ptrcall :void
    ((method-userdata :uint64-t) (instance :uint64-t)
     (args :uint64-t) (r-ret :uint64-t))
  (with-callback-protection ((bound-method-name (address-handle-value *bound-methods*
                                                                      method-userdata))
                             (catching-errors
                               (write-failed-result (address-handle-value *bound-methods*
                                                                          method-userdata)
                                                    r-ret)))
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
;;
;; The pointers are integers, see PTRCALL-BOUND-METHOD.
(define-callback call-virtual-with-data :void
    ((instance :uint64-t) (name :uint64-t) (virtual-call-userdata :uint64-t)
     (args :uint64-t) (r-ret :uint64-t))
  (declare (ignore name))
  (with-callback-protection ((bound-method-name (address-handle-value *bound-methods*
                                                                      virtual-call-userdata))
                             (catching-errors
                               (write-failed-result (address-handle-value *bound-methods*
                                                                          virtual-call-userdata)
                                                    r-ret)))
    (ptrcall-bound-method virtual-call-userdata instance args r-ret)))
