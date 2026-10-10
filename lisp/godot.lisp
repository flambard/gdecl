(in-package :godot)

;;;
;;; The Lisp-style layer of the framework: initialization, helpers and macros,
;;; and binding Lisp functions as methods, properties and signals. Built on
;;; the package GDEXTENSION-FFI (gdextension-ffi.lisp), which maps the C interface.
;;;

(ffi:clines "#include <string.h>")

;; Not interface functions: the results of get_variant_from_type_constructor and
;; get_variant_to_type_constructor for every variant type, indexed by type
(defvar *variant-from-type-constructors* nil)
(defvar *type-from-variant-constructors* nil)

;;;
;;; Initialization
;;;

;; Functions called at the end of INITIALIZE, see ADD-INITIALIZE-HOOK
(defvar *initialize-hooks* '())

(defun add-initialize-hook (function)
  "Call FUNCTION, a function designator taking no arguments, at the end of
INITIALIZE, once the framework is set up. Hooks run in the order they were
added; adding a hook again doesn't run it twice. This is how an application
registers its entry point: by calling ADD-INITIALIZE-HOOK when it's loaded."
  (setf *initialize-hooks*
        (append (remove function *initialize-hooks*) (list function))))

(defun initialize (get-proc-address class-library)
  "Set up the framework with the GDExtensionInterfaceGetProcAddress and
GDExtensionClassLibraryPtr that Godot gave the extension, then run the
initialize hooks. Called from src/gdecl.c."
  (load-interface get-proc-address class-library)
  (setf *variant-from-type-constructors* (make-array +variant-type-variant-max+ :initial-element nil)
        *type-from-variant-constructors* (make-array +variant-type-variant-max+ :initial-element nil))
  ;; There are no constructors for NIL
  (loop for type from 1 below +variant-type-variant-max+
        do (setf (aref *variant-from-type-constructors* type)
                 (get-variant-from-type-constructor type)
                 (aref *type-from-variant-constructors* type)
                 (get-variant-to-type-constructor type)))
  (dolist (hook *initialize-hooks*)
    (handler-case (funcall hook)
      (error (e)
        (format t "~&Error in initialize hook ~a: ~a~%" hook e))))
  t)

;;;
;;; Helpers
;;;

(defmacro with-string-name ((var contents) &body body)
  "Evaluate BODY with VAR bound to a pointer to a StringName created from the
string CONTENTS. The StringName is destroyed when BODY exits, also on a
non-local exit."
  `(ffi:with-foreign-object (,var 'string-name)
     (string-name-new-with-latin1-chars ,var ,contents)
     (unwind-protect (progn ,@body)
       (string-name-destructor ,var))))

(defun get-method-bind (class-name method-name hash)
  "The GDExtensionMethodBindPtr of the method METHOD-NAME of the class
CLASS-NAME (both strings). HASH is the hash of the method's signature, from
extension_api.json; the result is NULL if it doesn't match."
  (with-string-name (class-string-name class-name)
    (with-string-name (method-string-name method-name)
      (classdb-get-method-bind class-string-name method-string-name hash))))

(defun clear-foreign-object (pointer type)
  "Set all bytes of the foreign object of TYPE at POINTER to zero, like a C
initializer that leaves fields out. Foreign memory from Lisp isn't zeroed."
  (let ((size (ffi:size-of-foreign-type type)))
    (ffi:c-inline (pointer size) (:pointer-void :unsigned-long) :void
                  "memset(#0, 0, #1)" :one-liner t)))

(defun cast-pointer (pointer type)
  "POINTER as a pointer to TYPE. A :pointer-void returned by a foreign function
has no size in ECL, so it must be cast before its slots can be accessed."
  (ffi:make-pointer (ffi:pointer-address pointer) type))

(defun element-pointer (pointer type index)
  (ffi:make-pointer (+ (ffi:pointer-address pointer)
                       (* index (ffi:size-of-foreign-type type)))
                    type))

(defun foreign-ref (pointer type &optional (index 0))
  "Element INDEX of TYPE in the array at POINTER, like ((TYPE *)POINTER)[INDEX]
in C. Works on pointers without a size, such as callback arguments."
  (ffi:deref-pointer (element-pointer pointer type index) type))

(defun (setf foreign-ref) (value pointer type &optional (index 0))
  (setf (ffi:deref-pointer (element-pointer pointer type index) type) value))

(defmacro with-string ((var contents) &body body)
  "Evaluate BODY with VAR bound to a pointer to a Godot String created from the
Lisp string CONTENTS. The String is destroyed when BODY exits, also on a
non-local exit."
  `(ffi:with-foreign-object (,var 'godot-string)
     (string-new-with-utf8-chars ,var ,contents)
     (unwind-protect (progn ,@body)
       (string-destructor ,var))))

;;;
;;; Method calls
;;;
;;; Godot calls a bound method through one of two callbacks: ptrcall_func with
;;; pointers to the raw values (the fast path), or call_func with Variants (the
;;; dynamic path). All methods share the same two callbacks, METHOD-PTRCALL and
;;; METHOD-CALL. The method_userdata of a method identifies a BOUND-METHOD,
;;; which says which Lisp function to call and how to convert its arguments and
;;; return value.
;;;
;;; A Lisp function can't be passed to C, so the BOUND-METHODs are kept in
;;; *BOUND-METHODS* and method_userdata is (1+ index), so that it's never NULL.
;;;
;;; The functions get the GDExtensionClassInstancePtr as is (the pointer given
;;; to OBJECT-SET-INSTANCE) and must cast it to their own struct type.
;;;

;; Variant types whose raw values the dispatcher can convert, and their FFI
;; types. GDExtensionBool is uint8_t; Godot's int and float are 64 bits.
(defparameter *method-value-types*
  (list (cons +variant-type-bool+ :uint8-t)
        (cons +variant-type-int+ :int64-t)
        (cons +variant-type-float+ :double)))

(defun value-ffi-type (variant-type)
  (or (cdr (assoc variant-type *method-value-types*))
      (error "Unsupported type for a bound method: variant type ~d" variant-type)))

(defun read-value (pointer variant-type)
  "The raw value of VARIANT-TYPE at POINTER as a Lisp value."
  (let ((value (foreign-ref pointer (value-ffi-type variant-type))))
    (if (= variant-type +variant-type-bool+)
        (/= value 0)
        value)))

(defun write-value (pointer variant-type value)
  "Store the Lisp VALUE as a raw value of VARIANT-TYPE at POINTER."
  (setf (foreign-ref pointer (value-ffi-type variant-type))
        (cond ((= variant-type +variant-type-bool+) (if value 1 0))
              ((= variant-type +variant-type-float+) (float value 1d0))
              (t value))))

(defstruct bound-method
  function
  ;; Variant types; +VARIANT-TYPE-NIL+ as the return type means no return value
  return-type
  argument-types)

(defvar *bound-methods* (make-array 0 :adjustable t :fill-pointer t))

(defun register-method (function &key (return-type +variant-type-nil+) argument-types)
  "Register FUNCTION as a method and return its method_userdata. FUNCTION is
called with the instance pointer and one Lisp value per argument."
  (unless (= return-type +variant-type-nil+)
    (value-ffi-type return-type))
  (mapc #'value-ffi-type argument-types)
  (ffi:make-pointer (1+ (vector-push-extend (make-bound-method :function function
                                                               :return-type return-type
                                                               :argument-types argument-types)
                                            *bound-methods*))
                    :void))

(defun userdata-method (userdata)
  (aref *bound-methods* (1- (ffi:pointer-address userdata))))

(defun set-call-error (r-error error &key (argument 0) (expected 0))
  (let ((r-error (cast-pointer r-error 'call-error)))
    (setf (ffi:get-slot-value r-error 'call-error 'error) error
          (ffi:get-slot-value r-error 'call-error 'argument) argument
          (ffi:get-slot-value r-error 'call-error 'expected) expected)))

(defun ptrcall-bound-method (method-userdata instance args r-ret)
  "Call the method identified by METHOD-USERDATA, with ARGS and R-RET as in
ptrcall_func: an array of pointers to the raw argument values, and a pointer to
where the raw return value goes."
  (let* ((method (userdata-method method-userdata))
         (return-type (bound-method-return-type method))
         (arguments (loop for type in (bound-method-argument-types method)
                          for i from 0
                          collect (read-value (foreign-ref args :pointer-void i) type)))
         (result (apply (bound-method-function method) instance arguments)))
    (unless (= return-type +variant-type-nil+)
      (write-value r-ret return-type result))))

(defun call-bound-method (method-userdata instance args argument-count r-return r-error)
  "Call the method identified by METHOD-USERDATA, with arguments and return
value as Variants, as in call_func."
  (let* ((method (userdata-method method-userdata))
         (return-type (bound-method-return-type method))
         (argument-types (bound-method-argument-types method))
         (expected-count (length argument-types)))
    (cond ((< argument-count expected-count)
           (set-call-error r-error +call-error-too-few-arguments+ :expected expected-count))
          ((> argument-count expected-count)
           (set-call-error r-error +call-error-too-many-arguments+ :expected expected-count))
          (t
           (let ((arguments '()))
             (loop for type in argument-types
                   for i from 0
                   for variant = (foreign-ref args :pointer-void i)
                   do (unless (= (variant-get-type variant) type)
                        (set-call-error r-error +call-error-invalid-argument+
                                        :argument i :expected type)
                        (return-from call-bound-method))
                      (ffi:with-foreign-object (value (value-ffi-type type))
                        (call-type-from-variant-constructor
                         (aref *type-from-variant-constructors* type) value variant)
                        (push (read-value value type) arguments)))
             (let ((result (apply (bound-method-function method) instance
                                  (nreverse arguments))))
               (unless (= return-type +variant-type-nil+)
                 (ffi:with-foreign-object (value (value-ffi-type return-type))
                   (write-value value return-type result)
                   (call-variant-from-type-constructor
                    (aref *variant-from-type-constructors* return-type) r-return value)))))))))

;; void (*GDExtensionClassMethodPtrCall)(void *method_userdata,
;;                                       GDExtensionClassInstancePtr p_instance,
;;                                       const GDExtensionConstTypePtr *p_args,
;;                                       GDExtensionTypePtr r_ret)
(ffi:defcallback method-ptrcall :void
    ((method-userdata :pointer-void) (instance :pointer-void)
     (args :pointer-void) (r-ret :pointer-void))
  ;; Never let a Lisp error unwind through Godot's C frames
  (handler-case
      (ptrcall-bound-method method-userdata instance args r-ret)
    (error (e)
      (format t "~&Error in method ptrcall: ~a~%" e))))

;; void (*GDExtensionClassMethodCall)(void *method_userdata,
;;                                    GDExtensionClassInstancePtr p_instance,
;;                                    const GDExtensionConstVariantPtr *p_args,
;;                                    GDExtensionInt p_argument_count,
;;                                    GDExtensionVariantPtr r_return,
;;                                    GDExtensionCallError *r_error)
(ffi:defcallback method-call :void
    ((method-userdata :pointer-void) (instance :pointer-void)
     (args :pointer-void) (argument-count :int64-t)
     (r-return :pointer-void) (r-error :pointer-void))
  (handler-case
      (call-bound-method method-userdata instance args argument-count r-return r-error)
    (error (e)
      (format t "~&Error in method call: ~a~%" e)
      (set-call-error r-error +call-error-invalid-method+))))

;;;
;;; Binding helpers
;;;
;;; MAKE-PROPERTY fills in the GDExtensionPropertyInfo at INFO (the C version
;;; returns the struct by value). The StringNames and the String it allocates
;;; are freed by DESTRUCT-PROPERTY.
;;;

(defun make-property (info type name)
  (make-property-full info type name +property-hint-none+ "" "" +property-usage-default+))

(defun make-property-full (info type name hint hint-string class-name usage-flags)
  (let ((prop-name (mem-alloc +string-name-size+))
        (prop-hint-string (mem-alloc +string-size+))
        (prop-class-name (mem-alloc +string-name-size+)))
    (string-name-new-with-latin1-chars prop-name name)
    (string-new-with-utf8-chars prop-hint-string hint-string)
    (string-name-new-with-latin1-chars prop-class-name class-name)
    (setf (ffi:get-slot-value info 'property-info 'name) prop-name
          (ffi:get-slot-value info 'property-info 'type) type
          (ffi:get-slot-value info 'property-info 'hint) hint
          (ffi:get-slot-value info 'property-info 'hint-string) prop-hint-string
          (ffi:get-slot-value info 'property-info 'class-name) prop-class-name
          (ffi:get-slot-value info 'property-info 'usage) usage-flags)
    info))

(defun destruct-property (info)
  (let ((name (ffi:get-slot-value info 'property-info 'name))
        (hint-string (ffi:get-slot-value info 'property-info 'hint-string))
        (class-name (ffi:get-slot-value info 'property-info 'class-name)))
    (string-name-destructor name)
    (string-destructor hint-string)
    (string-name-destructor class-name)
    (mem-free name)
    (mem-free hint-string)
    (mem-free class-name)))

(defun bind-method (class-name method-name function
                    &key (return-type +variant-type-nil+) arguments)
  "Register FUNCTION as the method METHOD-NAME of the class CLASS-NAME.
ARGUMENTS is a list of (name variant-type), and RETURN-TYPE the variant type of
the return value (+VARIANT-TYPE-NIL+ for none). FUNCTION is called with the
instance pointer and the arguments as Lisp values."
  (let ((argument-count (length arguments))
        (has-return-value (/= return-type +variant-type-nil+)))
    (with-string-name (method-name-string method-name)
      (ffi:with-foreign-objects ((return-info 'property-info)
                                 ;; At least one element, so the arrays are never empty
                                 (args-info `(:array property-info ,(max argument-count 1)))
                                 (args-metadata `(:array :int ,(max argument-count 1)))
                                 (method-info 'class-method-info))
        (when has-return-value
          (make-property return-info return-type ""))
        (loop for (name type) in arguments
              for i from 0
              do (make-property (element-pointer args-info 'property-info i) type name)
                 (setf (foreign-ref args-metadata :int i) +method-argument-metadata-none+))
        ;; All slots not set below are NULL/0
        (clear-foreign-object method-info 'class-method-info)
        (setf (ffi:get-slot-value method-info 'class-method-info 'name) method-name-string
              (ffi:get-slot-value method-info 'class-method-info 'method-userdata)
              (register-method function :return-type return-type
                                        :argument-types (mapcar #'second arguments))
              (ffi:get-slot-value method-info 'class-method-info 'call-func)
              (ffi:callback 'method-call)
              (ffi:get-slot-value method-info 'class-method-info 'ptrcall-func)
              (ffi:callback 'method-ptrcall)
              (ffi:get-slot-value method-info 'class-method-info 'method-flags)
              +method-flags-default+
              (ffi:get-slot-value method-info 'class-method-info 'has-return-value)
              (if has-return-value 1 0)
              (ffi:get-slot-value method-info 'class-method-info 'return-value-info) return-info
              (ffi:get-slot-value method-info 'class-method-info 'return-value-metadata)
              +method-argument-metadata-none+
              (ffi:get-slot-value method-info 'class-method-info 'argument-count) argument-count
              (ffi:get-slot-value method-info 'class-method-info 'arguments-info) args-info
              (ffi:get-slot-value method-info 'class-method-info 'arguments-metadata)
              args-metadata)
        (with-string-name (class-name-string class-name)
          (classdb-register-extension-class-method *class-library* class-name-string
                                                   method-info))
        (when has-return-value
          (destruct-property return-info))
        (dotimes (i argument-count)
          (destruct-property (element-pointer args-info 'property-info i)))))))

(defun bind-property (class-name name type getter setter)
  (with-string-name (class-string-name class-name)
    (ffi:with-foreign-object (info 'property-info)
      (make-property info type name)
      (with-string-name (getter-name getter)
        (with-string-name (setter-name setter)
          (classdb-register-extension-class-property *class-library* class-string-name
                                                     info setter-name getter-name)))
      (destruct-property info))))

(defun bind-signal-1 (class-name signal-name arg1-name arg1-type)
  (with-string-name (class-string-name class-name)
    (with-string-name (signal-string-name signal-name)
      (ffi:with-foreign-object (args-info 'property-info)
        (make-property args-info arg1-type arg1-name)
        (classdb-register-extension-class-signal *class-library* class-string-name
                                                 signal-string-name args-info 1)
        (destruct-property args-info)))))
