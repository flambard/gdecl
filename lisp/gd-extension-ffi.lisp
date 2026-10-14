(in-package :gd-extension-ffi)

;;;
;;; The GDExtension C interface, mapped as directly as possible: interface
;;; functions, enums and structs from gdextension_interface.h. The Lisp-style
;;; layer on top of this is the package GD-EXTENSION (gd-extension.lisp).
;;;

;;;
;;; The foreign lookups below must not happen at load time: ASDF loads this
;;; file into the build image, where there is no Godot. The C side calls
;;; LOAD-INTERFACE (through GD-EXTENSION-CALLBACK:INITIALIZE) once ECL is running
;;; inside Godot.
;;;
;;; Each interface function is kept in a variable named after the C function
;;; (*string-name-new-with-latin1-chars* for string_name_new_with_latin1_chars)
;;; and called through a Lisp function of the same name without earmuffs.
;;;

;; Use this to load other Godot extension interface functions
(defvar *get-proc-address* nil)

;; GDExtensionClassLibraryPtr, passed to Godot when registering classes
(defvar *class-library* nil)

(defun get-proc-address (name)
  (ffi:with-cstring (c-name name)
    (si:call-cfun *get-proc-address* :pointer-void '(:cstring) (list c-name))))

;; Copied from CFFI
;; `(si::call-cfun ,pointer ,return-type (list ,@types) (list ,@values))

;;;
;;; Enums
;;;

;; GDExtensionVariantType
(defconstant +variant-type-nil+ 0)
(defconstant +variant-type-bool+ 1)
(defconstant +variant-type-int+ 2)
(defconstant +variant-type-float+ 3)
(defconstant +variant-type-string+ 4)
(defconstant +variant-type-vector2+ 5)
(defconstant +variant-type-vector2i+ 6)
(defconstant +variant-type-rect2+ 7)
(defconstant +variant-type-rect2i+ 8)
(defconstant +variant-type-vector3+ 9)
(defconstant +variant-type-vector3i+ 10)
(defconstant +variant-type-transform2d+ 11)
(defconstant +variant-type-vector4+ 12)
(defconstant +variant-type-vector4i+ 13)
(defconstant +variant-type-plane+ 14)
(defconstant +variant-type-quaternion+ 15)
(defconstant +variant-type-aabb+ 16)
(defconstant +variant-type-basis+ 17)
(defconstant +variant-type-transform3d+ 18)
(defconstant +variant-type-projection+ 19)
(defconstant +variant-type-color+ 20)
(defconstant +variant-type-string-name+ 21)
(defconstant +variant-type-node-path+ 22)
(defconstant +variant-type-rid+ 23)
(defconstant +variant-type-object+ 24)
(defconstant +variant-type-callable+ 25)
(defconstant +variant-type-signal+ 26)
(defconstant +variant-type-dictionary+ 27)
(defconstant +variant-type-array+ 28)
(defconstant +variant-type-packed-byte-array+ 29)
(defconstant +variant-type-packed-int32-array+ 30)
(defconstant +variant-type-packed-int64-array+ 31)
(defconstant +variant-type-packed-float32-array+ 32)
(defconstant +variant-type-packed-float64-array+ 33)
(defconstant +variant-type-packed-string-array+ 34)
(defconstant +variant-type-packed-vector2-array+ 35)
(defconstant +variant-type-packed-vector3-array+ 36)
(defconstant +variant-type-packed-color-array+ 37)
(defconstant +variant-type-packed-vector4-array+ 38)
(defconstant +variant-type-variant-max+ 39)

;; GDExtensionVariantOperator
(defconstant +variant-op-equal+ 0)
(defconstant +variant-op-not-equal+ 1)
(defconstant +variant-op-less+ 2)
(defconstant +variant-op-less-equal+ 3)
(defconstant +variant-op-greater+ 4)
(defconstant +variant-op-greater-equal+ 5)
(defconstant +variant-op-add+ 6)
(defconstant +variant-op-subtract+ 7)
(defconstant +variant-op-multiply+ 8)
(defconstant +variant-op-divide+ 9)
(defconstant +variant-op-negate+ 10)
(defconstant +variant-op-positive+ 11)
(defconstant +variant-op-module+ 12)
(defconstant +variant-op-power+ 13)
(defconstant +variant-op-shift-left+ 14)
(defconstant +variant-op-shift-right+ 15)
(defconstant +variant-op-bit-and+ 16)
(defconstant +variant-op-bit-or+ 17)
(defconstant +variant-op-bit-xor+ 18)
(defconstant +variant-op-bit-negate+ 19)
(defconstant +variant-op-and+ 20)
(defconstant +variant-op-or+ 21)
(defconstant +variant-op-xor+ 22)
(defconstant +variant-op-not+ 23)
(defconstant +variant-op-in+ 24)
(defconstant +variant-op-max+ 25)

;; GDExtensionClassMethodFlags
(defconstant +method-flag-normal+ 1)
(defconstant +method-flag-editor+ 2)
(defconstant +method-flag-const+ 4)
(defconstant +method-flag-virtual+ 8)
(defconstant +method-flag-vararg+ 16)
(defconstant +method-flag-static+ 32)
(defconstant +method-flags-default+ +method-flag-normal+)

;; GDExtensionClassMethodArgumentMetadata
(defconstant +method-argument-metadata-none+ 0)
(defconstant +method-argument-metadata-int-is-int8+ 1)
(defconstant +method-argument-metadata-int-is-int16+ 2)
(defconstant +method-argument-metadata-int-is-int32+ 3)
(defconstant +method-argument-metadata-int-is-int64+ 4)
(defconstant +method-argument-metadata-int-is-uint8+ 5)
(defconstant +method-argument-metadata-int-is-uint16+ 6)
(defconstant +method-argument-metadata-int-is-uint32+ 7)
(defconstant +method-argument-metadata-int-is-uint64+ 8)
(defconstant +method-argument-metadata-real-is-float+ 9)
(defconstant +method-argument-metadata-real-is-double+ 10)
(defconstant +method-argument-metadata-int-is-char16+ 11)
(defconstant +method-argument-metadata-int-is-char32+ 12)

;; GDExtensionCallErrorType
(defconstant +call-ok+ 0)
(defconstant +call-error-invalid-method+ 1)
(defconstant +call-error-invalid-argument+ 2)
(defconstant +call-error-too-many-arguments+ 3)
(defconstant +call-error-too-few-arguments+ 4)
(defconstant +call-error-instance-is-null+ 5)
(defconstant +call-error-method-not-const+ 6)

;; PropertyHint and PropertyUsageFlags (global_enums in extension_api.json).
;; Only the values used so far.
(defconstant +property-hint-none+ 0)
(defconstant +property-hint-resource-type+ 17)
(defconstant +property-hint-node-type+ 34)
(defconstant +property-usage-default+ 6)

;;;
;;; Interface functions
;;;
;;; GDExtensionInterfaceGetGodotVersion get_godot_version =
;;;    (GDExtensionInterfaceGetGodotVersion)p_get_proc_address("get_godot_version");
;;;
;;; Each interface function is kept in a variable, set by LOAD-INTERFACE, and
;;; called through a function of the same name without earmuffs:
;;; DEFINE-INTERFACE-FUNCTION defines both. Function pointers that Godot returns,
;;; such as constructors, are called with CALL-* functions. All of them call
;;; through CALL-FOREIGN-POINTER.
;;;

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun c-type-name (ffi-type)
    "The C type of FFI-TYPE, for C code in FFI:C-INLINE."
    (ecase ffi-type
      (:void "void")
      (:pointer-void "void *")
      (:cstring "char *")
      (:int "int")
      (:int32-t "int32_t")
      (:int64-t "int64_t")
      (:uint8-t "uint8_t")
      (:uint64-t "uint64_t")
      (:unsigned-long "unsigned long")
      (:double "double")
      (:float "float"))))

(defmacro call-foreign-pointer (pointer return-type (&rest argument-types) &rest arguments)
  "Call the C function at POINTER with ARGUMENTS, of ARGUMENT-TYPES (FFI types
such as :POINTER-VOID and :INT64-T), and return its result, of RETURN-TYPE. The
call is compiled into C (FFI:C-INLINE), so it's about as cheap as calling the
function from C, unlike SI:CALL-CFUN, which interprets the types at every call."
  (assert (< (length arguments) 9))
  `(ffi:c-inline (,pointer ,@arguments) (:pointer-void ,@argument-types) ,return-type
                 ,(format nil "((~a (*)(~{~a~^, ~}))#0)(~{#~a~^, ~})"
                          (c-type-name return-type)
                          (mapcar #'c-type-name argument-types)
                          (loop for i from 1 to (length arguments) collect i))
                 :one-liner t))

;; The interface functions LOAD-INTERFACE looks up: a list of (c-name .
;; variable)
(defvar *interface-functions* '())

(defmacro define-interface-variable (variable c-name)
  "Define VARIABLE, which LOAD-INTERFACE sets to the interface function C-NAME."
  `(progn
     (defvar ,variable nil ,(format nil "The interface function ~a." c-name))
     (pushnew (cons ,c-name ',variable) *interface-functions* :test #'equal)))

(defmacro define-interface-function (name c-name return-type (&rest arguments))
  "Define the interface function C-NAME: the variable *NAME*, which
LOAD-INTERFACE sets, and the function NAME, which calls it with ARGUMENTS, a
list of (argument ffi-type), and returns its result, of RETURN-TYPE."
  (let ((variable (intern (format nil "*~a*" (symbol-name name)))))
    `(progn
       (define-interface-variable ,variable ,c-name)
       (defun ,name ,(mapcar #'first arguments)
         (call-foreign-pointer ,variable ,return-type ,(mapcar #'second arguments)
                               ,@(mapcar #'first arguments))))))

;; void get_godot_version(GDExtensionGodotVersion *r_godot_version)
(define-interface-function get-godot-version "get_godot_version" :void
  ((version :pointer-void)))

;; GDExtensionPtrDestructor variant_get_ptr_destructor(GDExtensionVariantType p_type)
(define-interface-function variant-get-ptr-destructor "variant_get_ptr_destructor" :pointer-void
  ((variant-type :int)))

;; void string_name_new_with_latin1_chars(GDExtensionUninitializedStringNamePtr r_dest,
;;                                        const char *p_contents,
;;                                        GDExtensionBool p_is_static)
(define-interface-variable *string-name-new-with-latin1-chars* "string_name_new_with_latin1_chars")

(defun string-name-new-with-latin1-chars (dest contents &optional is-static)
  (ffi:with-cstring (c-contents contents)
    (call-foreign-pointer *string-name-new-with-latin1-chars* :void
                          (:pointer-void :cstring :uint8-t)
                          dest c-contents (if is-static 1 0))))

;; void string_name_new_with_utf8_chars(GDExtensionUninitializedStringNamePtr r_dest,
;;                                      const char *p_contents)
(define-interface-variable *string-name-new-with-utf8-chars* "string_name_new_with_utf8_chars")

(defun string-name-new-with-utf8-chars (dest contents)
  ;; FFI:WITH-CSTRING only handles base characters, so encode explicitly
  (let ((octets (ext:string-to-octets contents :external-format :utf-8
                                               :null-terminate t)))
    (call-foreign-pointer *string-name-new-with-utf8-chars* :void
                          (:pointer-void :pointer-void)
                          dest (si:make-foreign-data-from-array octets))))

;; GDExtensionObjectPtr classdb_construct_object(GDExtensionConstStringNamePtr p_classname)
(define-interface-function classdb-construct-object "classdb_construct_object" :pointer-void
  ((class-name :pointer-void)))

;; Deprecated in Godot 4.3, use CLASSDB-REGISTER-EXTENSION-CLASS4 instead.
;;
;; void classdb_register_extension_class2(GDExtensionClassLibraryPtr p_library,
;;                                        GDExtensionConstStringNamePtr p_class_name,
;;                                        GDExtensionConstStringNamePtr p_parent_class_name,
;;                                        const GDExtensionClassCreationInfo2 *p_extension_funcs)
(define-interface-function classdb-register-extension-class2 "classdb_register_extension_class2"
    :void
  ((library :pointer-void) (class-name :pointer-void) (parent-class-name :pointer-void)
   (extension-funcs :pointer-void)))

;; void classdb_register_extension_class4(GDExtensionClassLibraryPtr p_library,
;;                                        GDExtensionConstStringNamePtr p_class_name,
;;                                        GDExtensionConstStringNamePtr p_parent_class_name,
;;                                        const GDExtensionClassCreationInfo4 *p_extension_funcs)
(define-interface-function classdb-register-extension-class4 "classdb_register_extension_class4"
    :void
  ((library :pointer-void) (class-name :pointer-void) (parent-class-name :pointer-void)
   (extension-funcs :pointer-void)))

;; void classdb_unregister_extension_class(GDExtensionClassLibraryPtr p_library,
;;                                        GDExtensionConstStringNamePtr p_class_name)
;;
;; Classes that inherit from a class must be unregistered before it.
(define-interface-function classdb-unregister-extension-class
    "classdb_unregister_extension_class" :void
  ((library :pointer-void) (class-name :pointer-void)))

;; void object_destroy(GDExtensionObjectPtr p_o)
(define-interface-function object-destroy "object_destroy" :void
  ((object :pointer-void)))

;; void object_set_instance(GDExtensionObjectPtr p_o,
;;                          GDExtensionConstStringNamePtr p_classname,
;;                          GDExtensionClassInstancePtr p_instance)
(define-interface-function object-set-instance "object_set_instance" :void
  ((object :pointer-void) (class-name :pointer-void) (instance :pointer-void)))

;; void object_set_instance_binding(GDExtensionObjectPtr p_o, void *p_token, void *p_binding,
;;                                  const GDExtensionInstanceBindingCallbacks *p_callbacks)
(define-interface-function object-set-instance-binding "object_set_instance_binding" :void
  ((object :pointer-void) (token :pointer-void) (binding :pointer-void)
   (callbacks :pointer-void)))

;; void *object_get_instance_binding(GDExtensionObjectPtr p_o, void *p_token,
;;                                    const GDExtensionInstanceBindingCallbacks *p_callbacks)
;;
;; With P_CALLBACKS NULL, returns NULL if the object has no binding for the
;; token; otherwise creates one with the create callback.
(define-interface-function object-get-instance-binding "object_get_instance_binding"
    :pointer-void
  ((object :pointer-void) (token :pointer-void) (callbacks :pointer-void)))

;; void object_free_instance_binding(GDExtensionObjectPtr p_o, void *p_token)
;;
;; Calls the binding's free callback.
(define-interface-function object-free-instance-binding "object_free_instance_binding" :void
  ((object :pointer-void) (token :pointer-void)))

;; void *mem_alloc(size_t p_bytes)
(define-interface-function mem-alloc "mem_alloc" :pointer-void
  ((bytes :unsigned-long)))

;; void mem_free(void *p_ptr)
(define-interface-function mem-free "mem_free" :void
  ((pointer :pointer-void)))

;; void classdb_register_extension_class_method(GDExtensionClassLibraryPtr p_library,
;;                                              GDExtensionConstStringNamePtr p_class_name,
;;                                              const GDExtensionClassMethodInfo *p_method_info)
(define-interface-function classdb-register-extension-class-method
    "classdb_register_extension_class_method" :void
  ((library :pointer-void) (class-name :pointer-void) (method-info :pointer-void)))

;; void classdb_register_extension_class_property(GDExtensionClassLibraryPtr p_library,
;;                                                GDExtensionConstStringNamePtr p_class_name,
;;                                                const GDExtensionPropertyInfo *p_info,
;;                                                GDExtensionConstStringNamePtr p_setter,
;;                                                GDExtensionConstStringNamePtr p_getter)
(define-interface-function classdb-register-extension-class-property
    "classdb_register_extension_class_property" :void
  ((library :pointer-void) (class-name :pointer-void) (info :pointer-void)
   (setter :pointer-void) (getter :pointer-void)))

;; GDExtensionPtrOperatorEvaluator
;; variant_get_ptr_operator_evaluator(GDExtensionVariantOperator p_operator,
;;                                    GDExtensionVariantType p_type_a,
;;                                    GDExtensionVariantType p_type_b)
(define-interface-function variant-get-ptr-operator-evaluator
    "variant_get_ptr_operator_evaluator" :pointer-void
  ((operator :int) (type-a :int) (type-b :int)))

;; Call an evaluator returned by VARIANT-GET-PTR-OPERATOR-EVALUATOR:
;; void (*GDExtensionPtrOperatorEvaluator)(GDExtensionConstTypePtr p_left,
;;                                         GDExtensionConstTypePtr p_right,
;;                                         GDExtensionTypePtr r_result)
(defun call-ptr-operator-evaluator (evaluator left right result)
  (call-foreign-pointer evaluator :void (:pointer-void :pointer-void :pointer-void)
                        left right result))

;; GDExtensionPtrConstructor variant_get_ptr_constructor(GDExtensionVariantType p_type,
;;                                                       int32_t p_constructor)
(define-interface-function variant-get-ptr-constructor "variant_get_ptr_constructor"
    :pointer-void
  ((variant-type :int) (constructor :int32-t)))

;; Call a constructor returned by VARIANT-GET-PTR-CONSTRUCTOR:
;; void (*GDExtensionPtrConstructor)(GDExtensionUninitializedTypePtr p_base,
;;                                   const GDExtensionConstTypePtr *p_args)
(defun call-ptr-constructor (constructor base args)
  (call-foreign-pointer constructor :void (:pointer-void :pointer-void) base args))

;; GDExtensionMethodBindPtr classdb_get_method_bind(GDExtensionConstStringNamePtr p_classname,
;;                                                  GDExtensionConstStringNamePtr p_methodname,
;;                                                  GDExtensionInt p_hash)
(define-interface-function classdb-get-method-bind "classdb_get_method_bind" :pointer-void
  ((class-name :pointer-void) (method-name :pointer-void) (hash :int64-t)))

;; void object_method_bind_ptrcall(GDExtensionMethodBindPtr p_method_bind,
;;                                 GDExtensionObjectPtr p_instance,
;;                                 const GDExtensionConstTypePtr *p_args,
;;                                 GDExtensionTypePtr r_ret)
(define-interface-function object-method-bind-ptrcall "object_method_bind_ptrcall" :void
  ((method-bind :pointer-void) (instance :pointer-void) (args :pointer-void)
   (r-ret :pointer-void)))

;; void object_method_bind_call(GDExtensionMethodBindPtr p_method_bind,
;;                              GDExtensionObjectPtr p_instance,
;;                              const GDExtensionConstVariantPtr *p_args,
;;                              GDExtensionInt p_arg_count,
;;                              GDExtensionUninitializedVariantPtr r_ret,
;;                              GDExtensionCallError *r_error)
(define-interface-function object-method-bind-call "object_method_bind_call" :void
  ((method-bind :pointer-void) (instance :pointer-void) (args :pointer-void)
   (arg-count :int64-t) (r-ret :pointer-void) (r-error :pointer-void)))

;; void classdb_register_extension_class_signal(GDExtensionClassLibraryPtr p_library,
;;                                              GDExtensionConstStringNamePtr p_class_name,
;;                                              GDExtensionConstStringNamePtr p_signal_name,
;;                                              const GDExtensionPropertyInfo *p_argument_info,
;;                                              GDExtensionInt p_argument_count)
(define-interface-function classdb-register-extension-class-signal
    "classdb_register_extension_class_signal" :void
  ((library :pointer-void) (class-name :pointer-void) (signal-name :pointer-void)
   (argument-info :pointer-void) (argument-count :int64-t)))

;; GDExtensionObjectPtr global_get_singleton(GDExtensionConstStringNamePtr p_name)
(define-interface-function global-get-singleton "global_get_singleton" :pointer-void
  ((name :pointer-void)))

;; void variant_destroy(GDExtensionVariantPtr p_self)
(define-interface-function variant-destroy "variant_destroy" :void
  ((variant :pointer-void)))

;; void variant_new_copy(GDExtensionUninitializedVariantPtr r_dest,
;;                       GDExtensionConstVariantPtr p_src)
(define-interface-function variant-new-copy "variant_new_copy" :void
  ((dest :pointer-void) (source :pointer-void)))

;; GDExtensionVariantFromTypeConstructorFunc
;; get_variant_from_type_constructor(GDExtensionVariantType p_type)
(define-interface-function get-variant-from-type-constructor
    "get_variant_from_type_constructor" :pointer-void
  ((variant-type :int)))

;; GDExtensionTypeFromVariantConstructorFunc
;; get_variant_to_type_constructor(GDExtensionVariantType p_type)
(define-interface-function get-variant-to-type-constructor
    "get_variant_to_type_constructor" :pointer-void
  ((variant-type :int)))

;; Call a constructor returned by GET-VARIANT-FROM-TYPE-CONSTRUCTOR:
;; void (*GDExtensionVariantFromTypeConstructorFunc)(GDExtensionUninitializedVariantPtr,
;;                                                   GDExtensionTypePtr)
(defun call-variant-from-type-constructor (constructor variant value)
  (call-foreign-pointer constructor :void (:pointer-void :pointer-void) variant value))

;; Call a constructor returned by GET-VARIANT-TO-TYPE-CONSTRUCTOR:
;; void (*GDExtensionTypeFromVariantConstructorFunc)(GDExtensionUninitializedTypePtr,
;;                                                   GDExtensionVariantPtr)
(defun call-type-from-variant-constructor (constructor value variant)
  (call-foreign-pointer constructor :void (:pointer-void :pointer-void) value variant))

;; GDExtensionVariantType variant_get_type(GDExtensionConstVariantPtr p_self)
(define-interface-function variant-get-type "variant_get_type" :int
  ((variant :pointer-void)))

;; void string_new_with_utf8_chars(GDExtensionUninitializedStringPtr r_dest,
;;                                 const char *p_contents)
(define-interface-variable *string-new-with-utf8-chars* "string_new_with_utf8_chars")

(defun string-new-with-utf8-chars (dest contents)
  ;; FFI:WITH-CSTRING only handles base characters, so encode explicitly
  (let ((octets (ext:string-to-octets contents :external-format :utf-8
                                               :null-terminate t)))
    (call-foreign-pointer *string-new-with-utf8-chars* :void (:pointer-void :pointer-void)
                          dest (si:make-foreign-data-from-array octets))))

;; void print_error(const char *p_description, const char *p_function,
;;                  const char *p_file, int32_t p_line, GDExtensionBool p_editor_notify)
(define-interface-variable *print-error* "print_error")

(defun print-error (description function file line &optional editor-notify)
  (flet ((utf8 (string)
           ;; FFI:WITH-CSTRING only handles base characters, so encode explicitly
           (si:make-foreign-data-from-array
            (ext:string-to-octets string :external-format :utf-8 :null-terminate t))))
    (call-foreign-pointer *print-error* :void
                          (:pointer-void :pointer-void :pointer-void :int32-t :uint8-t)
                          (utf8 description) (utf8 function) (utf8 file) line
                          (if editor-notify 1 0))))

;; void callable_custom_create2(GDExtensionUninitializedTypePtr r_callable,
;;                              GDExtensionCallableCustomInfo2 *p_callable_custom_info)
(define-interface-function callable-custom-create2 "callable_custom_create2" :void
  ((callable :pointer-void) (info :pointer-void)))

;; GDObjectInstanceID object_get_instance_id(GDExtensionConstObjectPtr p_object)
(define-interface-function object-get-instance-id "object_get_instance_id" :uint64-t
  ((object :pointer-void)))

;; GDExtensionInt string_to_utf8_chars(GDExtensionConstStringPtr p_self,
;;                                     char *r_text,
;;                                     GDExtensionInt p_max_write_length)
;;
;; Returns the length in bytes. With R-TEXT NULL, only computes the length.
(define-interface-function string-to-utf8-chars "string_to_utf8_chars" :int64-t
  ((string :pointer-void) (text :pointer-void) (max-write-length :int64-t)))

;; GDExtensionPtrUtilityFunction
;; variant_get_ptr_utility_function(GDExtensionConstStringNamePtr p_function,
;;                                  GDExtensionInt p_hash)
(define-interface-function variant-get-ptr-utility-function
    "variant_get_ptr_utility_function" :pointer-void
  ((function :pointer-void) (hash :int64-t)))

;; Call a function returned by VARIANT-GET-PTR-UTILITY-FUNCTION:
;; void (*GDExtensionPtrUtilityFunction)(GDExtensionTypePtr r_return,
;;                                       const GDExtensionConstTypePtr *p_args,
;;                                       int p_argument_count)
(defun call-ptr-utility-function (function r-return args argument-count)
  (call-foreign-pointer function :void (:pointer-void :pointer-void :int)
                        r-return args argument-count))

;; GDExtensionPtrBuiltInMethod
;; variant_get_ptr_builtin_method(GDExtensionVariantType p_type,
;;                                GDExtensionConstStringNamePtr p_method,
;;                                GDExtensionInt p_hash)
(define-interface-function variant-get-ptr-builtin-method "variant_get_ptr_builtin_method"
    :pointer-void
  ((variant-type :int) (method :pointer-void) (hash :int64-t)))

;; Call a method returned by VARIANT-GET-PTR-BUILTIN-METHOD:
;; void (*GDExtensionPtrBuiltInMethod)(GDExtensionTypePtr p_base,
;;                                     const GDExtensionConstTypePtr *p_args,
;;                                     GDExtensionTypePtr r_return,
;;                                     int p_argument_count)
(defun call-ptr-builtin-method (method base args r-return argument-count)
  (call-foreign-pointer method :void (:pointer-void :pointer-void :pointer-void :int)
                        base args r-return argument-count))

;; GDExtensionStringPtr packed_string_array_operator_index(GDExtensionTypePtr p_self,
;;                                                         GDExtensionInt p_index)
(define-interface-function packed-string-array-operator-index
    "packed_string_array_operator_index" :pointer-void
  ((packed-string-array :pointer-void) (index :int64-t)))

;;;
;;; Destructors of builtin types
;;;
;;; Not interface functions: looked up with variant_get_ptr_destructor in
;;; LOAD-INTERFACE, and called with void (*GDExtensionPtrDestructor)(GDExtensionTypePtr p_base).
;;;

;; The destructors LOAD-INTERFACE looks up: a list of (variant-type . variable)
(defvar *type-destructors* '())

(defmacro define-type-destructor (name variant-type)
  "Define the function NAME, which destroys a value of VARIANT-TYPE with the
destructor that LOAD-INTERFACE looks up into the variable *NAME*."
  (let ((variable (intern (format nil "*~a*" (symbol-name name)))))
    `(progn
       (defvar ,variable nil)
       (pushnew (cons ,variant-type ',variable) *type-destructors* :test #'equal)
       (defun ,name (pointer)
         (call-foreign-pointer ,variable :void (:pointer-void) pointer)))))

(define-type-destructor string-name-destructor +variant-type-string-name+)
(define-type-destructor string-destructor +variant-type-string+)
(define-type-destructor node-path-destructor +variant-type-node-path+)
(define-type-destructor callable-destructor +variant-type-callable+)
(define-type-destructor packed-string-array-destructor +variant-type-packed-string-array+)

;;;
;;; Other values looked up once
;;;

;; The results of get_variant_from_type_constructor and
;; get_variant_to_type_constructor for every variant type, indexed by type
(defvar *variant-from-type-constructors* nil)
(defvar *type-from-variant-constructors* nil)

;; The builtin method PackedStringArray.size(), fetched with
;; variant_get_ptr_builtin_method
(defvar *packed-string-array-size* nil)

;; The operator evaluator for StringName == StringName, fetched with
;; variant_get_ptr_operator_evaluator
(defvar *string-name-equal-evaluator* nil)

;;;
;;; Loading the interface
;;;

(defun load-interface (get-proc-address class-library)
  "Store the GDExtensionInterfaceGetProcAddress and GDExtensionClassLibraryPtr
that Godot gave the extension, and look up the interface functions and the
other values looked up once."
  (setf *get-proc-address* get-proc-address
        *class-library* class-library)
  (loop for (c-name . variable) in *interface-functions*
        do (setf (symbol-value variable) (get-proc-address c-name)))
  (loop for (variant-type . variable) in *type-destructors*
        do (setf (symbol-value variable) (variant-get-ptr-destructor variant-type)))
  (ffi:with-foreign-object (method 'string-name)
    (string-name-new-with-latin1-chars method "size")
    (setf *packed-string-array-size*
          (variant-get-ptr-builtin-method +variant-type-packed-string-array+ method 3173160232))
    (string-name-destructor method))
  (setf *string-name-equal-evaluator*
        (variant-get-ptr-operator-evaluator +variant-op-equal+ +variant-type-string-name+
                                            +variant-type-string-name+))
  (setf *variant-from-type-constructors* (make-array +variant-type-variant-max+ :initial-element nil)
        *type-from-variant-constructors* (make-array +variant-type-variant-max+ :initial-element nil))
  ;; There are no constructors for NIL
  (loop for type from 1 below +variant-type-variant-max+
        do (setf (aref *variant-from-type-constructors* type)
                 (get-variant-from-type-constructor type)
                 (aref *type-from-variant-constructors* type)
                 (get-variant-to-type-constructor type)))
  t)

;;;
;;; Structs
;;;

;; From builtin_class_sizes in extension_api.json (build configuration float_64)
(defconstant +string-name-size+ 8)
(defconstant +string-size+ 8)
(defconstant +variant-size+ 24)
(defconstant +node-path-size+ 8)
(defconstant +callable-size+ 16)
(defconstant +packed-string-array-size+ 16)

;;  typedef struct
;;  {
;;      uint8_t data[8];
;;  } StringName;
;;
(ffi:def-struct string-name
  (data '(:array :uint8-t #.+string-name-size+)))


;; Godot's String. Named GODOT-STRING, since STRING is taken by CL.
(ffi:def-struct godot-string
  (data '(:array :uint8-t #.+string-size+)))

(ffi:def-struct variant
  (data '(:array :uint8-t #.+variant-size+)))

(ffi:def-struct node-path
  (data '(:array :uint8-t #.+node-path-size+)))

;; Godot's Callable. Named GODOT-CALLABLE, since GD-EXTENSION-TYPES has a Lisp
;; type CALLABLE.
(ffi:def-struct godot-callable
  (data '(:array :uint8-t #.+callable-size+)))

(ffi:def-struct packed-string-array
  (data '(:array :uint8-t #.+packed-string-array-size+)))


;;  typedef struct
;;  {
;;		uint32_t major;
;;		uint32_t minor;
;;		uint32_t patch;
;;		const char *string;
;;	} GDExtensionGodotVersion;
;;
(ffi:def-struct godot-version
  (major :uint32-t)
  (minor :uint32-t)
  (patch :uint32-t)
  (string :cstring))


;;  typedef struct
;;  {
;;      GDExtensionInstanceBindingCreateCallback create_callback;
;;      GDExtensionInstanceBindingFreeCallback free_callback;
;;      GDExtensionInstanceBindingReferenceCallback reference_callback;
;;  } GDExtensionInstanceBindingCallbacks;
;;
(ffi:def-struct instance-binding-callbacks
  (create-callback :pointer-void)
  (free-callback :pointer-void)
  (reference-callback :pointer-void))


;;  GDExtensionClassCreationInfo2, see gdextension_interface.h for the
;;  documentation of each slot. GDExtensionBool is uint8_t and all the
;;  *_func slots are function pointers.
;;
;;  Deprecated, use CLASS-CREATION-INFO4 (with
;;  CLASSDB-REGISTER-EXTENSION-CLASS4) instead.
;;
(ffi:def-struct class-creation-info2
  (is-virtual :uint8-t)
  (is-abstract :uint8-t)
  (is-exposed :uint8-t)
  (set-func :pointer-void)
  (get-func :pointer-void)
  (get-property-list-func :pointer-void)
  (free-property-list-func :pointer-void)
  (property-can-revert-func :pointer-void)
  (property-get-revert-func :pointer-void)
  (validate-property-func :pointer-void)
  (notification-func :pointer-void)
  (to-string-func :pointer-void)
  (reference-func :pointer-void)
  (unreference-func :pointer-void)
  (create-instance-func :pointer-void)
  (free-instance-func :pointer-void)
  (recreate-instance-func :pointer-void)
  (get-virtual-func :pointer-void)
  (get-virtual-call-data-func :pointer-void)
  (call-virtual-with-data-func :pointer-void)
  (get-rid-func :pointer-void)
  (class-userdata :pointer-void))


;;  GDExtensionClassCreationInfo4, see gdextension_interface.h for the
;;  documentation of each slot. Compared to GDExtensionClassCreationInfo2 it
;;  adds is_runtime and icon_path and drops get_rid_func. Several *_func slots
;;  also take newer callback types (e.g. GDExtensionClassCreateInstance2).
;;
(ffi:def-struct class-creation-info4
  (is-virtual :uint8-t)
  (is-abstract :uint8-t)
  (is-exposed :uint8-t)
  (is-runtime :uint8-t)
  (icon-path :pointer-void)
  (set-func :pointer-void)
  (get-func :pointer-void)
  (get-property-list-func :pointer-void)
  (free-property-list-func :pointer-void)
  (property-can-revert-func :pointer-void)
  (property-get-revert-func :pointer-void)
  (validate-property-func :pointer-void)
  (notification-func :pointer-void)
  (to-string-func :pointer-void)
  (reference-func :pointer-void)
  (unreference-func :pointer-void)
  (create-instance-func :pointer-void)
  (free-instance-func :pointer-void)
  (recreate-instance-func :pointer-void)
  (get-virtual-func :pointer-void)
  (get-virtual-call-data-func :pointer-void)
  (call-virtual-with-data-func :pointer-void)
  (class-userdata :pointer-void))

;;  typedef struct {
;;      GDExtensionVariantType type;
;;      GDExtensionStringNamePtr name;
;;      GDExtensionStringNamePtr class_name;
;;      uint32_t hint; // Bitfield of `PropertyHint` (defined in `extension_api.json`).
;;      GDExtensionStringPtr hint_string;
;;      uint32_t usage; // Bitfield of `PropertyUsageFlags` (defined in `extension_api.json`).
;;  } GDExtensionPropertyInfo;
;;
(ffi:def-struct property-info
  (type :int)
  (name :pointer-void)
  (class-name :pointer-void)
  (hint :uint32-t)
  (hint-string :pointer-void)
  (usage :uint32-t))


;;  GDExtensionClassMethodInfo, see gdextension_interface.h for the
;;  documentation of each slot. call_func and ptrcall_func are function
;;  pointers; the *_metadata slots are GDExtensionClassMethodArgumentMetadata.
;;
(ffi:def-struct class-method-info
  (name :pointer-void)
  (method-userdata :pointer-void)
  (call-func :pointer-void)
  (ptrcall-func :pointer-void)
  (method-flags :uint32-t)
  (has-return-value :uint8-t)
  (return-value-info :pointer-void)
  (return-value-metadata :int)
  (argument-count :uint32-t)
  (arguments-info :pointer-void)
  (arguments-metadata :pointer-void)
  (default-argument-count :uint32-t)
  (default-arguments :pointer-void))


;;  GDExtensionCallableCustomInfo2, see gdextension_interface.h for the
;;  documentation of each slot. All the *_func slots are function pointers;
;;  object_id is a GDObjectInstanceID (uint64_t).
;;
(ffi:def-struct callable-custom-info2
  (callable-userdata :pointer-void)
  (token :pointer-void)
  (object-id :uint64-t)
  (call-func :pointer-void)
  (is-valid-func :pointer-void)
  (free-func :pointer-void)
  (hash-func :pointer-void)
  (equal-func :pointer-void)
  (less-than-func :pointer-void)
  (to-string-func :pointer-void)
  (get-argument-count-func :pointer-void))

;;  typedef struct {
;;      GDExtensionCallErrorType error;
;;      int32_t argument;
;;      int32_t expected;
;;  } GDExtensionCallError;
;;
(ffi:def-struct call-error
  (error :int)
  (argument :int32-t)
  (expected :int32-t))

;;;
;;; Foreign memory
;;;
;;; Helpers for ECL's FFI, used with the structs above and with the pointers
;;; Godot passes.
;;;

(ffi:clines "#include <string.h>")

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

;;; ECL's FFI does at every use what can be done when the code is compiled: it
;;; looks up the sizes of types (about 4 microseconds for a struct), and makes
;;; Lisp objects for pointers. WITH-FOREIGN-MEMORY and the compiler macros below
;;; do it when the code is compiled, for a constant TYPE, with C code
;;; (FFI:C-INLINE). Compiler macros only apply in other files than this one.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun constant-type-size (type-form)
    "The size of the FFI type TYPE-FORM, if it's a constant whose size is known
when the code is compiled, else NIL."
    (and (constantp type-form)
         (ignore-errors (ffi:size-of-foreign-type (eval type-form)))))

  (defun constant-c-type-name (type-form)
    "The C type of the FFI type TYPE-FORM, if it's a constant that C-TYPE-NAME
knows, else NIL."
    (and (constantp type-form)
         (ignore-errors (c-type-name (eval type-form))))))

(defmacro with-foreign-memory (bindings &body body)
  "Evaluate BODY with each variable of BINDINGS bound to a pointer to new,
uninitialized foreign memory, freed when BODY exits, also on a non-local exit.
Each binding is (variable type), where TYPE is evaluated to an FFI type, or
(variable :size size), with SIZE evaluated to a number of bytes. The size of a
constant TYPE is looked up when the code is compiled, so this is much cheaper
than FFI:WITH-FOREIGN-OBJECTS. The pointers have no size, like those Godot
passes (see CAST-POINTER)."
  (if (null bindings)
      `(progn ,@body)
      (destructuring-bind (variable type-or-key &optional size-form) (first bindings)
        (let ((size (cond ((eq type-or-key :size) size-form)
                          ((constant-type-size type-or-key))
                          (t `(ffi:size-of-foreign-type ,type-or-key)))))
          `(let ((,variable (ffi:c-inline (,size) (:unsigned-long) :pointer-void
                                          "__builtin_malloc(#0)" :one-liner t)))
             (unwind-protect (with-foreign-memory ,(rest bindings) ,@body)
               (ffi:c-inline (,variable) (:pointer-void) :void
                             "__builtin_free(#0)" :one-liner t)))))))

(defmacro array-element (pointer type index)
  "A pointer, without a size, to element INDEX of the array of TYPE at POINTER,
like &((TYPE *)POINTER)[INDEX] in C. The size of a constant TYPE is looked up
when the code is compiled, unlike with ELEMENT-POINTER."
  (let ((size (constant-type-size type)))
    (if size
        `(ffi:c-inline (,pointer ,index) (:pointer-void :long) :pointer-void
                       ,(format nil "(char *)#0 + #1 * ~d" size) :one-liner t)
        `(element-pointer ,pointer ,type ,index))))

(define-compiler-macro clear-foreign-object (&whole form pointer type)
  (let ((size (constant-type-size type)))
    (if size
        `(ffi:c-inline (,pointer) (:pointer-void) :void
                       ,(format nil "__builtin_memset(#0, 0, ~d)" size) :one-liner t)
        form)))

(define-compiler-macro foreign-ref (&whole form pointer type &optional (index 0))
  (let ((c-type (constant-c-type-name type)))
    (if c-type
        `(ffi:c-inline (,pointer ,index) (:pointer-void :long) ,(eval type)
                       ,(format nil "((~a *)#0)[#1]" c-type) :one-liner t)
        form)))

(define-compiler-macro (setf foreign-ref) (&whole form value pointer type &optional (index 0))
  (let ((c-type (constant-c-type-name type)))
    (if c-type
        (let ((new (gensym "NEW")))
          `(let ((,new ,value))
             (ffi:c-inline (,pointer ,index ,new) (:pointer-void :long ,(eval type)) :void
                           ,(format nil "((~a *)#0)[#1] = #2" c-type) :one-liner t)
             ,new))
        form)))
