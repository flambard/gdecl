(in-package :gdextension-ffi)

;;;
;;; The GDExtension C interface, mapped as directly as possible: interface
;;; functions, enums and structs from gdextension_interface.h. The Lisp-style
;;; layer on top of this is the package GODOT (godot.lisp).
;;;

;;;
;;; The foreign lookups below must not happen at load time: ASDF loads this
;;; file into the build image, where there is no Godot. The C side calls
;;; LOAD-INTERFACE (through GODOT:INITIALIZE) once ECL is running inside Godot.
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
(defconstant +property-usage-default+ 6)

;;;
;;; Interface functions
;;;
;;; GDExtensionInterfaceGetGodotVersion get_godot_version =
;;;    (GDExtensionInterfaceGetGodotVersion)p_get_proc_address("get_godot_version");
;;;

(defvar *get-godot-version* nil)
(defvar *variant-get-ptr-destructor* nil)
(defvar *string-name-new-with-latin1-chars* nil)
(defvar *classdb-construct-object* nil)
(defvar *classdb-register-extension-class2* nil)
(defvar *classdb-register-extension-class4* nil)
(defvar *object-destroy* nil)
(defvar *object-set-instance* nil)
(defvar *object-set-instance-binding* nil)
(defvar *mem-alloc* nil)
(defvar *mem-free* nil)
(defvar *classdb-register-extension-class-method* nil)
(defvar *classdb-register-extension-class-property* nil)
(defvar *variant-get-ptr-operator-evaluator* nil)
(defvar *variant-get-ptr-constructor* nil)
(defvar *classdb-get-method-bind* nil)
(defvar *object-method-bind-ptrcall* nil)
(defvar *object-method-bind-call* nil)
(defvar *classdb-register-extension-class-signal* nil)
(defvar *variant-destroy* nil)
(defvar *global-get-singleton* nil)
(defvar *get-variant-from-type-constructor* nil)
(defvar *get-variant-to-type-constructor* nil)
(defvar *variant-get-type* nil)
(defvar *string-new-with-utf8-chars* nil)

;; Not interface functions: fetched with variant_get_ptr_destructor
(defvar *string-name-destructor* nil)
(defvar *string-destructor* nil)
(defvar *node-path-destructor* nil)
(defvar *callable-destructor* nil)

;; void get_godot_version(GDExtensionGodotVersion *r_godot_version)
(defun get-godot-version (version)
  (si:call-cfun *get-godot-version* :void '(:pointer-void) (list version)))

;; GDExtensionPtrDestructor variant_get_ptr_destructor(GDExtensionVariantType p_type)
(defun variant-get-ptr-destructor (variant-type)
  (si:call-cfun *variant-get-ptr-destructor* :pointer-void '(:int) (list variant-type)))

;; void string_name_new_with_latin1_chars(GDExtensionUninitializedStringNamePtr r_dest,
;;                                        const char *p_contents,
;;                                        GDExtensionBool p_is_static)
(defun string-name-new-with-latin1-chars (dest contents &optional is-static)
  (ffi:with-cstring (c-contents contents)
    (si:call-cfun *string-name-new-with-latin1-chars*
                  :void
                  '(:pointer-void :cstring :uint8-t)
                  (list dest c-contents (if is-static 1 0)))))

;; void string_name_destructor(GDExtensionTypePtr p_base)
(defun string-name-destructor (string-name)
  (si:call-cfun *string-name-destructor* :void '(:pointer-void) (list string-name)))

;; GDExtensionObjectPtr classdb_construct_object(GDExtensionConstStringNamePtr p_classname)
(defun classdb-construct-object (class-name)
  (si:call-cfun *classdb-construct-object* :pointer-void '(:pointer-void) (list class-name)))

;; Deprecated in Godot 4.3, use CLASSDB-REGISTER-EXTENSION-CLASS4 instead.
;;
;; void classdb_register_extension_class2(GDExtensionClassLibraryPtr p_library,
;;                                        GDExtensionConstStringNamePtr p_class_name,
;;                                        GDExtensionConstStringNamePtr p_parent_class_name,
;;                                        const GDExtensionClassCreationInfo2 *p_extension_funcs)
(defun classdb-register-extension-class2 (library class-name parent-class-name extension-funcs)
  (si:call-cfun *classdb-register-extension-class2*
                :void
                '(:pointer-void :pointer-void :pointer-void :pointer-void)
                (list library class-name parent-class-name extension-funcs)))

;; void classdb_register_extension_class4(GDExtensionClassLibraryPtr p_library,
;;                                        GDExtensionConstStringNamePtr p_class_name,
;;                                        GDExtensionConstStringNamePtr p_parent_class_name,
;;                                        const GDExtensionClassCreationInfo4 *p_extension_funcs)
(defun classdb-register-extension-class4 (library class-name parent-class-name extension-funcs)
  (si:call-cfun *classdb-register-extension-class4*
                :void
                '(:pointer-void :pointer-void :pointer-void :pointer-void)
                (list library class-name parent-class-name extension-funcs)))

;; void object_destroy(GDExtensionObjectPtr p_o)
(defun object-destroy (object)
  (si:call-cfun *object-destroy* :void '(:pointer-void) (list object)))

;; void object_set_instance(GDExtensionObjectPtr p_o,
;;                          GDExtensionConstStringNamePtr p_classname,
;;                          GDExtensionClassInstancePtr p_instance)
(defun object-set-instance (object class-name instance)
  (si:call-cfun *object-set-instance*
                :void
                '(:pointer-void :pointer-void :pointer-void)
                (list object class-name instance)))

;; void object_set_instance_binding(GDExtensionObjectPtr p_o, void *p_token, void *p_binding,
;;                                  const GDExtensionInstanceBindingCallbacks *p_callbacks)
(defun object-set-instance-binding (object token binding callbacks)
  (si:call-cfun *object-set-instance-binding*
                :void
                '(:pointer-void :pointer-void :pointer-void :pointer-void)
                (list object token binding callbacks)))

;; void *mem_alloc(size_t p_bytes)
(defun mem-alloc (bytes)
  (si:call-cfun *mem-alloc* :pointer-void '(:unsigned-long) (list bytes)))

;; void mem_free(void *p_ptr)
(defun mem-free (pointer)
  (si:call-cfun *mem-free* :void '(:pointer-void) (list pointer)))

;; void classdb_register_extension_class_method(GDExtensionClassLibraryPtr p_library,
;;                                              GDExtensionConstStringNamePtr p_class_name,
;;                                              const GDExtensionClassMethodInfo *p_method_info)
(defun classdb-register-extension-class-method (library class-name method-info)
  (si:call-cfun *classdb-register-extension-class-method*
                :void
                '(:pointer-void :pointer-void :pointer-void)
                (list library class-name method-info)))

;; void classdb_register_extension_class_property(GDExtensionClassLibraryPtr p_library,
;;                                                GDExtensionConstStringNamePtr p_class_name,
;;                                                const GDExtensionPropertyInfo *p_info,
;;                                                GDExtensionConstStringNamePtr p_setter,
;;                                                GDExtensionConstStringNamePtr p_getter)
(defun classdb-register-extension-class-property (library class-name info setter getter)
  (si:call-cfun *classdb-register-extension-class-property*
                :void
                '(:pointer-void :pointer-void :pointer-void :pointer-void :pointer-void)
                (list library class-name info setter getter)))

;; GDExtensionPtrOperatorEvaluator
;; variant_get_ptr_operator_evaluator(GDExtensionVariantOperator p_operator,
;;                                    GDExtensionVariantType p_type_a,
;;                                    GDExtensionVariantType p_type_b)
(defun variant-get-ptr-operator-evaluator (operator type-a type-b)
  (si:call-cfun *variant-get-ptr-operator-evaluator*
                :pointer-void '(:int :int :int) (list operator type-a type-b)))

;; Call an evaluator returned by VARIANT-GET-PTR-OPERATOR-EVALUATOR:
;; void (*GDExtensionPtrOperatorEvaluator)(GDExtensionConstTypePtr p_left,
;;                                         GDExtensionConstTypePtr p_right,
;;                                         GDExtensionTypePtr r_result)
(defun call-ptr-operator-evaluator (evaluator left right result)
  (si:call-cfun evaluator :void '(:pointer-void :pointer-void :pointer-void)
                (list left right result)))

;; GDExtensionPtrConstructor variant_get_ptr_constructor(GDExtensionVariantType p_type,
;;                                                       int32_t p_constructor)
(defun variant-get-ptr-constructor (variant-type constructor)
  (si:call-cfun *variant-get-ptr-constructor*
                :pointer-void '(:int :int32-t) (list variant-type constructor)))

;; Call a constructor returned by VARIANT-GET-PTR-CONSTRUCTOR:
;; void (*GDExtensionPtrConstructor)(GDExtensionUninitializedTypePtr p_base,
;;                                   const GDExtensionConstTypePtr *p_args)
(defun call-ptr-constructor (constructor base args)
  (si:call-cfun constructor :void '(:pointer-void :pointer-void) (list base args)))

;; GDExtensionMethodBindPtr classdb_get_method_bind(GDExtensionConstStringNamePtr p_classname,
;;                                                  GDExtensionConstStringNamePtr p_methodname,
;;                                                  GDExtensionInt p_hash)
(defun classdb-get-method-bind (class-name method-name hash)
  (si:call-cfun *classdb-get-method-bind*
                :pointer-void '(:pointer-void :pointer-void :int64-t)
                (list class-name method-name hash)))

;; void object_method_bind_ptrcall(GDExtensionMethodBindPtr p_method_bind,
;;                                 GDExtensionObjectPtr p_instance,
;;                                 const GDExtensionConstTypePtr *p_args,
;;                                 GDExtensionTypePtr r_ret)
(defun object-method-bind-ptrcall (method-bind instance args r-ret)
  (si:call-cfun *object-method-bind-ptrcall*
                :void '(:pointer-void :pointer-void :pointer-void :pointer-void)
                (list method-bind instance args r-ret)))

;; void object_method_bind_call(GDExtensionMethodBindPtr p_method_bind,
;;                              GDExtensionObjectPtr p_instance,
;;                              const GDExtensionConstVariantPtr *p_args,
;;                              GDExtensionInt p_arg_count,
;;                              GDExtensionUninitializedVariantPtr r_ret,
;;                              GDExtensionCallError *r_error)
(defun object-method-bind-call (method-bind instance args arg-count r-ret r-error)
  (si:call-cfun *object-method-bind-call*
                :void
                '(:pointer-void :pointer-void :pointer-void :int64-t :pointer-void :pointer-void)
                (list method-bind instance args arg-count r-ret r-error)))

;; void classdb_register_extension_class_signal(GDExtensionClassLibraryPtr p_library,
;;                                              GDExtensionConstStringNamePtr p_class_name,
;;                                              GDExtensionConstStringNamePtr p_signal_name,
;;                                              const GDExtensionPropertyInfo *p_argument_info,
;;                                              GDExtensionInt p_argument_count)
(defun classdb-register-extension-class-signal (library class-name signal-name
                                                argument-info argument-count)
  (si:call-cfun *classdb-register-extension-class-signal*
                :void
                '(:pointer-void :pointer-void :pointer-void :pointer-void :int64-t)
                (list library class-name signal-name argument-info argument-count)))

;; GDExtensionObjectPtr global_get_singleton(GDExtensionConstStringNamePtr p_name)
(defun global-get-singleton (name)
  (si:call-cfun *global-get-singleton* :pointer-void '(:pointer-void) (list name)))

;; void variant_destroy(GDExtensionVariantPtr p_self)
(defun variant-destroy (variant)
  (si:call-cfun *variant-destroy* :void '(:pointer-void) (list variant)))

;; GDExtensionVariantFromTypeConstructorFunc
;; get_variant_from_type_constructor(GDExtensionVariantType p_type)
(defun get-variant-from-type-constructor (variant-type)
  (si:call-cfun *get-variant-from-type-constructor* :pointer-void '(:int) (list variant-type)))

;; GDExtensionTypeFromVariantConstructorFunc
;; get_variant_to_type_constructor(GDExtensionVariantType p_type)
(defun get-variant-to-type-constructor (variant-type)
  (si:call-cfun *get-variant-to-type-constructor* :pointer-void '(:int) (list variant-type)))

;; Call a constructor returned by GET-VARIANT-FROM-TYPE-CONSTRUCTOR:
;; void (*GDExtensionVariantFromTypeConstructorFunc)(GDExtensionUninitializedVariantPtr,
;;                                                   GDExtensionTypePtr)
(defun call-variant-from-type-constructor (constructor variant value)
  (si:call-cfun constructor :void '(:pointer-void :pointer-void) (list variant value)))

;; Call a constructor returned by GET-VARIANT-TO-TYPE-CONSTRUCTOR:
;; void (*GDExtensionTypeFromVariantConstructorFunc)(GDExtensionUninitializedTypePtr,
;;                                                   GDExtensionVariantPtr)
(defun call-type-from-variant-constructor (constructor value variant)
  (si:call-cfun constructor :void '(:pointer-void :pointer-void) (list value variant)))

;; GDExtensionVariantType variant_get_type(GDExtensionConstVariantPtr p_self)
(defun variant-get-type (variant)
  (si:call-cfun *variant-get-type* :int '(:pointer-void) (list variant)))

;; void string_new_with_utf8_chars(GDExtensionUninitializedStringPtr r_dest,
;;                                 const char *p_contents)
(defun string-new-with-utf8-chars (dest contents)
  ;; FFI:WITH-CSTRING only handles base characters, so encode explicitly
  (let ((octets (ext:string-to-octets contents :external-format :utf-8
                                               :null-terminate t)))
    (si:call-cfun *string-new-with-utf8-chars*
                  :void
                  '(:pointer-void :pointer-void)
                  (list dest (si:make-foreign-data-from-array octets)))))

;; void string_destructor(GDExtensionTypePtr p_base)
(defun string-destructor (string)
  (si:call-cfun *string-destructor* :void '(:pointer-void) (list string)))

;; void node_path_destructor(GDExtensionTypePtr p_base)
(defun node-path-destructor (node-path)
  (si:call-cfun *node-path-destructor* :void '(:pointer-void) (list node-path)))

;; void callable_destructor(GDExtensionTypePtr p_base)
(defun callable-destructor (callable)
  (si:call-cfun *callable-destructor* :void '(:pointer-void) (list callable)))

;;;
;;; Loading the interface
;;;

(defun load-interface (get-proc-address class-library)
  "Store the GDExtensionInterfaceGetProcAddress and GDExtensionClassLibraryPtr
that Godot gave the extension, and look up the interface functions."
  (setf *get-proc-address* get-proc-address
        *class-library* class-library)
  (setf *get-godot-version* (get-proc-address "get_godot_version")
        *variant-get-ptr-destructor* (get-proc-address "variant_get_ptr_destructor")
        *string-name-new-with-latin1-chars* (get-proc-address "string_name_new_with_latin1_chars")
        *classdb-construct-object* (get-proc-address "classdb_construct_object")
        *classdb-register-extension-class2* (get-proc-address "classdb_register_extension_class2")
        *classdb-register-extension-class4* (get-proc-address "classdb_register_extension_class4")
        *object-destroy* (get-proc-address "object_destroy")
        *object-set-instance* (get-proc-address "object_set_instance")
        *object-set-instance-binding* (get-proc-address "object_set_instance_binding")
        *mem-alloc* (get-proc-address "mem_alloc")
        *mem-free* (get-proc-address "mem_free")
        *classdb-register-extension-class-method* (get-proc-address "classdb_register_extension_class_method")
        *classdb-register-extension-class-property* (get-proc-address "classdb_register_extension_class_property")
        *variant-get-ptr-operator-evaluator* (get-proc-address "variant_get_ptr_operator_evaluator")
        *variant-get-ptr-constructor* (get-proc-address "variant_get_ptr_constructor")
        *classdb-get-method-bind* (get-proc-address "classdb_get_method_bind")
        *object-method-bind-ptrcall* (get-proc-address "object_method_bind_ptrcall")
        *object-method-bind-call* (get-proc-address "object_method_bind_call")
        *classdb-register-extension-class-signal* (get-proc-address "classdb_register_extension_class_signal")
        *variant-destroy* (get-proc-address "variant_destroy")
        *global-get-singleton* (get-proc-address "global_get_singleton")
        *get-variant-from-type-constructor* (get-proc-address "get_variant_from_type_constructor")
        *get-variant-to-type-constructor* (get-proc-address "get_variant_to_type_constructor")
        *variant-get-type* (get-proc-address "variant_get_type")
        *string-new-with-utf8-chars* (get-proc-address "string_new_with_utf8_chars"))
  (setf *string-name-destructor* (variant-get-ptr-destructor +variant-type-string-name+)
        *string-destructor* (variant-get-ptr-destructor +variant-type-string+)
        *node-path-destructor* (variant-get-ptr-destructor +variant-type-node-path+)
        *callable-destructor* (variant-get-ptr-destructor +variant-type-callable+))
  t)

;;;
;;; Structs
;;;

;; From builtin_class_sizes in extension_api.json (build configuration float_64)
(defconstant +string-name-size+ 8)
(defconstant +string-size+ 8)
(defconstant +variant-size+ 24)
(defconstant +vector2-size+ 8)
(defconstant +node-path-size+ 8)
(defconstant +callable-size+ 16)

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

(ffi:def-struct vector2
  (data '(:array :uint8-t #.+vector2-size+)))

(ffi:def-struct node-path
  (data '(:array :uint8-t #.+node-path-size+)))

(ffi:def-struct callable
  (data '(:array :uint8-t #.+callable-size+)))


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
