(defpackage #:gd-extension-ffi
  (:documentation "The Godot GDExtension C interface, mapped 1-to-1")
  (:nicknames #:gdext-ffi)
  (:use #:cl)
  (:export #:load-interface
           #:*class-library*
           #:get-proc-address
           ;; Interface functions
           #:get-godot-version
           #:variant-get-ptr-destructor
           #:string-name-new-with-latin1-chars
           #:string-name-destructor
           #:classdb-construct-object
           #:classdb-register-extension-class2 ; deprecated
           #:classdb-register-extension-class4
           #:object-destroy
           #:object-set-instance
           #:object-set-instance-binding
           #:mem-alloc
           #:mem-free
           #:classdb-register-extension-class-method
           #:classdb-register-extension-class-property
           #:variant-get-ptr-operator-evaluator
           #:call-ptr-operator-evaluator
           #:variant-get-ptr-constructor
           #:call-ptr-constructor
           #:classdb-get-method-bind
           #:object-method-bind-ptrcall
           #:object-method-bind-call
           #:classdb-register-extension-class-signal
           #:variant-destroy
           #:global-get-singleton
           #:get-variant-from-type-constructor
           #:get-variant-to-type-constructor
           #:call-variant-from-type-constructor
           #:call-type-from-variant-constructor
           #:variant-get-type
           #:string-new-with-utf8-chars
           #:string-destructor
           #:node-path-destructor
           #:callable-destructor
           #:*variant-from-type-constructors*
           #:*string-name-equal-evaluator*
           #:*type-from-variant-constructors*
           ;; Enums
           #:+variant-op-equal+
           #:+variant-op-not-equal+
           #:+variant-op-less+
           #:+variant-op-less-equal+
           #:+variant-op-greater+
           #:+variant-op-greater-equal+
           #:+variant-op-add+
           #:+variant-op-subtract+
           #:+variant-op-multiply+
           #:+variant-op-divide+
           #:+variant-op-negate+
           #:+variant-op-positive+
           #:+variant-op-module+
           #:+variant-op-power+
           #:+variant-op-shift-left+
           #:+variant-op-shift-right+
           #:+variant-op-bit-and+
           #:+variant-op-bit-or+
           #:+variant-op-bit-xor+
           #:+variant-op-bit-negate+
           #:+variant-op-and+
           #:+variant-op-or+
           #:+variant-op-xor+
           #:+variant-op-not+
           #:+variant-op-in+
           #:+variant-op-max+
           #:+variant-type-nil+
           #:+variant-type-bool+
           #:+variant-type-int+
           #:+variant-type-float+
           #:+variant-type-string+
           #:+variant-type-vector2+
           #:+variant-type-vector2i+
           #:+variant-type-rect2+
           #:+variant-type-rect2i+
           #:+variant-type-vector3+
           #:+variant-type-vector3i+
           #:+variant-type-transform2d+
           #:+variant-type-vector4+
           #:+variant-type-vector4i+
           #:+variant-type-plane+
           #:+variant-type-quaternion+
           #:+variant-type-aabb+
           #:+variant-type-basis+
           #:+variant-type-transform3d+
           #:+variant-type-projection+
           #:+variant-type-color+
           #:+variant-type-string-name+
           #:+variant-type-node-path+
           #:+variant-type-rid+
           #:+variant-type-object+
           #:+variant-type-callable+
           #:+variant-type-signal+
           #:+variant-type-dictionary+
           #:+variant-type-array+
           #:+variant-type-packed-byte-array+
           #:+variant-type-packed-int32-array+
           #:+variant-type-packed-int64-array+
           #:+variant-type-packed-float32-array+
           #:+variant-type-packed-float64-array+
           #:+variant-type-packed-string-array+
           #:+variant-type-packed-vector2-array+
           #:+variant-type-packed-vector3-array+
           #:+variant-type-packed-color-array+
           #:+variant-type-packed-vector4-array+
           #:+variant-type-variant-max+
           #:+method-flag-normal+
           #:+method-flag-editor+
           #:+method-flag-const+
           #:+method-flag-virtual+
           #:+method-flag-vararg+
           #:+method-flag-static+
           #:+method-flags-default+
           #:+method-argument-metadata-none+
           #:+method-argument-metadata-int-is-int8+
           #:+method-argument-metadata-int-is-int16+
           #:+method-argument-metadata-int-is-int32+
           #:+method-argument-metadata-int-is-int64+
           #:+method-argument-metadata-int-is-uint8+
           #:+method-argument-metadata-int-is-uint16+
           #:+method-argument-metadata-int-is-uint32+
           #:+method-argument-metadata-int-is-uint64+
           #:+method-argument-metadata-real-is-float+
           #:+method-argument-metadata-real-is-double+
           #:+method-argument-metadata-int-is-char16+
           #:+method-argument-metadata-int-is-char32+
           #:+call-ok+
           #:+call-error-invalid-method+
           #:+call-error-invalid-argument+
           #:+call-error-too-many-arguments+
           #:+call-error-too-few-arguments+
           #:+call-error-instance-is-null+
           #:+call-error-method-not-const+
           #:+property-hint-none+
           #:+property-usage-default+
           ;; Structs
           #:+string-name-size+
           #:+string-size+
           #:+variant-size+
           #:+vector2-size+
           #:+rect2-size+
           #:+node-path-size+
           #:+callable-size+
           #:string-name
           #:godot-string
           #:variant
           #:godot-vector2
           #:x
           #:y
           #:godot-rect2
           #:position
           #:size
           #:node-path
           #:callable
           #:data
           #:godot-version
           #:major
           #:minor
           #:patch
           #:instance-binding-callbacks
           #:create-callback
           #:free-callback
           #:reference-callback
           #:class-creation-info2 ; deprecated
           #:class-creation-info4
           #:is-runtime
           #:icon-path
           #:is-virtual
           #:is-abstract
           #:is-exposed
           #:set-func
           #:get-func
           #:get-property-list-func
           #:free-property-list-func
           #:property-can-revert-func
           #:property-get-revert-func
           #:validate-property-func
           #:notification-func
           #:to-string-func
           #:reference-func
           #:unreference-func
           #:create-instance-func
           #:free-instance-func
           #:recreate-instance-func
           #:get-virtual-func
           #:get-virtual-call-data-func
           #:call-virtual-with-data-func
           #:get-rid-func
           #:class-userdata
           ;; The TYPE, CLASS-NAME and ERROR slots are CL symbols
           #:property-info
           #:name
           #:hint
           #:hint-string
           #:usage
           #:class-method-info
           #:method-userdata
           #:call-func
           #:ptrcall-func
           #:method-flags
           #:has-return-value
           #:return-value-info
           #:return-value-metadata
           #:argument-count
           #:arguments-info
           #:arguments-metadata
           #:default-argument-count
           #:default-arguments
           #:call-error
           #:argument
           #:expected
           ;; Foreign memory
           #:clear-foreign-object
           #:cast-pointer
           #:element-pointer
           #:foreign-ref))

(defpackage #:gd-extension-callback
  (:documentation "What runs when Godot calls into Lisp: the callbacks, and the
tables and dispatchers behind them")
  (:nicknames #:gdext-callback)
  (:use #:cl #:gd-extension-ffi)
  (:export ;; Callbacks
           #:method-ptrcall
           #:method-call
           #:create-instance
           #:free-instance
           #:get-virtual-call-data
           #:call-virtual-with-data
           ;; Tables
           #:register-method
           #:add-extension-class
           #:add-virtual
           #:instance-object))

(defpackage #:gd-extension
  (:documentation "Lisp-style framework for programming Godot")
  (:nicknames #:gdext)
  (:use #:cl #:gd-extension-ffi)
  (:import-from #:gd-extension-callback
                #:method-ptrcall
                #:method-call
                #:create-instance
                #:free-instance
                #:get-virtual-call-data
                #:call-virtual-with-data
                #:register-method
                #:add-extension-class
                #:add-virtual
                #:instance-object)
  (:export #:initialize
           #:add-initialize-hook
           ;; Helpers
           #:with-string-name
           #:with-string
           #:get-method-bind
           ;; From GD-EXTENSION-FFI
           #:clear-foreign-object
           #:cast-pointer
           #:foreign-ref
           ;; Builtin types
           #:vector2
           #:vector2-p
           #:vector2-x
           #:vector2-y
           #:rect2
           #:rect2-p
           #:rect2-position
           #:rect2-size
           #:vector2+
           #:vector2*
           #:vector2-length
           #:vector2-normalized
           #:vector2-clamp
           ;; Values looked up once
           #:sname
           #:npath
           #:singleton
           ;; Calling engine methods
           #:define-engine-method
           ;; Classes
           #:register-class
           #:bind-virtual
           #:instance-object
           ;; Binding
           #:register-method
           #:make-property
           #:make-property-full
           #:destruct-property
           #:bind-method
           #:bind-property
           #:bind-signal-1))
