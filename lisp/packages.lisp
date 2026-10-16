(defpackage #:gd-extension-ffi
  (:documentation "The Godot GDExtension C interface, mapped 1-to-1")
  (:nicknames #:gdext-ffi)
  (:use #:cl)
  (:export #:load-interface
           ;; extension_api.json, when the code is compiled
           #:*extension-api-file*
           #:extension-api-json
           #:api-builtin-size
           #:*class-library*
           #:get-proc-address
           ;; Interface functions
           #:get-godot-version
           #:variant-get-ptr-destructor
           #:string-name-new-with-utf8-chars
           #:string-name-destructor
           #:classdb-construct-object
           #:classdb-register-extension-class4
           #:classdb-unregister-extension-class
           #:object-destroy
           #:object-set-instance
           #:object-set-instance-binding
           #:object-get-instance-binding
           #:*object-get-instance-binding*
           #:object-free-instance-binding
           #:object-get-class-name
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
           #:*object-method-bind-ptrcall*
           #:object-method-bind-call
           #:classdb-register-extension-class-signal
           #:variant-destroy
           #:variant-new-copy
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
           #:packed-string-array-destructor
           #:string-to-utf8-chars
           #:print-error
           #:callable-custom-create2
           #:object-get-instance-id
           #:*print-error*
           #:variant-get-ptr-builtin-method
           #:variant-get-ptr-utility-function
           #:call-ptr-utility-function
           #:call-ptr-builtin-method
           #:packed-string-array-operator-index
           #:packed-byte-array-operator-index
           #:packed-int32-array-operator-index
           #:packed-int64-array-operator-index
           #:packed-float32-array-operator-index
           #:packed-float64-array-operator-index
           #:packed-vector2-array-operator-index
           #:packed-vector3-array-operator-index
           #:packed-vector4-array-operator-index
           #:packed-color-array-operator-index
           #:array-operator-index
           #:dictionary-operator-index
           #:packed-byte-array-destructor
           #:packed-int32-array-destructor
           #:packed-int64-array-destructor
           #:packed-float32-array-destructor
           #:packed-float64-array-destructor
           #:packed-vector2-array-destructor
           #:packed-vector3-array-destructor
           #:packed-vector4-array-destructor
           #:packed-color-array-destructor
           #:array-destructor
           #:dictionary-destructor
           #:packed-array
           #:godot-array
           #:godot-dictionary
           #:*variant-from-type-constructors*
           #:*string-name-equal-evaluator*
           #:*string-from-string-name-constructor*
           #:*string-from-node-path-constructor*
           #:*node-path-from-string-constructor*
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
           ;; Structs
           #:+string-name-size+
           #:+string-size+
           #:+variant-size+
           #:+node-path-size+
           #:+callable-size+
           #:+packed-string-array-size+
           #:+packed-array-size+
           #:+array-size+
           #:+dictionary-size+
           #:string-name
           #:godot-string
           #:variant
           #:node-path
           #:godot-callable
           #:callable-custom-info2
           #:callable-userdata
           #:token
           #:object-id
           #:is-valid-func
           #:free-func
           #:hash-func
           #:equal-func
           #:less-than-func
           #:to-string-func
           #:get-argument-count-func
           #:packed-string-array
           #:data
           #:godot-version
           #:major
           #:minor
           #:patch
           #:instance-binding-callbacks
           #:create-callback
           #:free-callback
           #:reference-callback
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
           #:with-foreign-memory
           #:array-element
           #:cast-pointer
           #:element-pointer
           #:foreign-ref
           #:set-foreign-slots
           #:c-type-name))

(defpackage #:gd-extension-builtins
  (:documentation "Lisp versions of Godot's builtin types, such as Vector2 and
Basis, with their functions. Everything exported from here is for applications:
GD-EXTENSION and GODOT re-export all of it, so a symbol is added here only.")
  (:nicknames #:gdext-builtins)
  (:use #:cl)
  (:export #:vector2
           #:vector2-p
           #:vector2-x
           #:vector2-y
           #:vector2+
           #:vector2*
           #:vector2-length
           #:vector2-normalized
           #:vector2-rotated
           #:vector2-clamp
           #:rect2
           #:rect2-p
           #:rect2-position
           #:rect2-size
           #:vector3
           #:vector3-p
           #:vector3-x
           #:vector3-y
           #:vector3-z
           #:vector3+
           #:vector3-
           #:vector3*
           #:vector3-length
           #:vector3-normalized
           #:vector3-dot
           #:vector3-cross
           #:vector3-rotated
           #:vector3-is-zero-approx
           #:basis
           #:basis-p
           #:basis-x
           #:basis-y
           #:basis-z
           #:basis-looking-at
           #:color
           #:color-p
           #:color-r
           #:color-g
           #:color-b
           #:color-a
           #:vector2i
           #:vector2i-p
           #:vector2i-x
           #:vector2i-y
           #:vector3i
           #:vector3i-p
           #:vector3i-x
           #:vector3i-y
           #:vector3i-z
           #:vector4
           #:vector4-p
           #:vector4-x
           #:vector4-y
           #:vector4-z
           #:vector4-w
           #:vector4i
           #:vector4i-p
           #:vector4i-x
           #:vector4i-y
           #:vector4i-z
           #:vector4i-w
           #:rect2i
           #:rect2i-p
           #:rect2i-position
           #:rect2i-size
           #:plane
           #:plane-p
           #:plane-normal
           #:plane-d
           #:quaternion
           #:quaternion-p
           #:quaternion-x
           #:quaternion-y
           #:quaternion-z
           #:quaternion-w
           #:aabb
           #:aabb-p
           #:aabb-position
           #:aabb-size
           #:transform2d
           #:transform2d-p
           #:transform2d-x
           #:transform2d-y
           #:transform2d-origin
           #:transform3d
           #:transform3d-p
           #:transform3d-basis
           #:transform3d-origin
           #:projection
           #:projection-p
           #:projection-x
           #:projection-y
           #:projection-z
           #:projection-w
           #:rid
           #:rid-p
           #:rid-id))

(defpackage #:gd-extension-types
  (:documentation "Converting Godot's types between raw values, Lisp values and
Variants. The Lisp versions of the builtin types are in GD-EXTENSION-BUILTINS.")
  (:nicknames #:gdext-types)
  (:use #:cl #:gd-extension-ffi #:gd-extension-builtins)
  (:export #:godot-object
           #:make-godot-object
           #:godot-object-p
           #:godot-object-pointer
           #:object-pointer
           #:valid-object-p
           ;; Builtin types
           #:define-builtin-type
           #:builtin-type-components
           #:builtin-layout
           #:builtin-construct-form
           ;; Strings, StringNames and NodePaths
           #:read-godot-string
           #:write-godot-string
           #:with-string
           #:read-string-name
           #:write-string-name
           #:with-string-name
           #:string-name-equal
           #:read-node-path
           #:write-node-path
           #:make-temporary-name
           #:destroy-temporary-name
           #:write-variant
           #:variant-value-p
           #:lisp-variant-type
           #:read-variant
           #:read-variant-result
           ;; The autorelease pool
           #:*release-reference-function*
           #:autorelease-pool-p
           #:autorelease-reference
           #:release-autoreleased
           #:reference-for-caller
           #:release-autorelease-pool
           #:*autorelease-pool*
           #:callable
           #:callable-p
           #:callable-target
           #:callable-function
           ;; Value types
           #:value-type
           #:value-type-variant-type
           #:value-type-ffi-type
           #:value-type-reader
           #:value-type-writer
           #:value-type-to-raw
           #:value-type-from-raw
           #:value-type-by-pointer
           #:value-type-literal-macro
           #:value-type-default-parser
           #:define-simple-value-type
           #:parse-builtin-default
           #:value-type-destructor
           #:value-type-lisp-type
           #:value-type-variant-reader
           #:value-type-variant-writer
           #:raw-from-variant
           #:find-value-type
           #:add-value-type
           #:read-value
           #:write-value
           #:destroy-value
           #:write-variant-as
           #:read-variant-as
           #:make-value-type))

(defpackage #:gd-extension-callback
  (:documentation "What runs when Godot calls into Lisp: the callbacks, and the
tables and dispatchers behind them")
  (:nicknames #:gdext-callback)
  (:use #:cl #:gd-extension-ffi #:gd-extension-types)
  (:export ;; Callbacks
           #:callback-pointer
           #:method-ptrcall
           #:method-call
           #:create-instance
           #:free-instance
           #:get-virtual-call-data
           #:call-virtual-with-data
           ;; Initialization, called from src/gdecl.c
           #:initialize
           #:deinitialize
           #:add-initialize-hook
           #:add-deinitialize-hook
           #:*framework-initialize*
           #:*framework-deinitialize*
           #:free-bindings
           #:make-initialize-cell
           ;; Errors
           #:report-error
           #:*wrapper-function*
           #:pointer-lisp-object
           ;; Tables
           #:register-method
           #:ptrcall-invoker-form
           #:add-extension-class
           #:add-virtual
           #:instance-object
           #:lisp-object))

(defpackage #:gdecl-json
  (:documentation "A small JSON reader, for extension_api.json")
  (:use #:cl)
  (:export #:parse-json
           #:read-json-file
           #:json-get))

(defpackage #:gd-extension
  (:documentation "Lisp-style framework for programming Godot")
  (:nicknames #:gdext)
  (:use #:cl #:gd-extension-ffi #:gd-extension-builtins #:gd-extension-types)
  (:import-from #:gdecl-json
                #:json-get)
  (:import-from #:gd-extension-callback
                #:callback-pointer
                #:method-ptrcall
                #:method-call
                #:create-instance
                #:free-instance
                #:get-virtual-call-data
                #:call-virtual-with-data
                #:add-initialize-hook
                #:add-deinitialize-hook
                #:*framework-initialize*
                #:*framework-deinitialize*
                #:free-bindings
                #:make-initialize-cell
                #:report-error
                #:*wrapper-function*
                #:pointer-lisp-object
                #:register-method
                #:ptrcall-invoker-form
                #:add-extension-class
                #:add-virtual
                #:instance-object
                #:lisp-object)
  ;; Internal, but imported by GODOT-CLOS, the prototype of the high-level
  ;; layer, which must find them when this is read
  (:intern #:add-class-definition
           #:inherits-class-p
           #:virtual-signatures
           #:godot-property-name
           #:*engine-object-types*)
  (:export #:add-initialize-hook
           #:add-deinitialize-hook
           ;; Helpers
           #:variant-type
           #:with-string-name
           #:with-string
           #:get-method-bind
           ;; From GD-EXTENSION-FFI
           #:clear-foreign-object
           #:cast-pointer
           #:foreign-ref
           ;; From GD-EXTENSION-TYPES
           #:godot-object
           #:godot-object-p
           #:godot-object-pointer
           #:object-pointer
           #:valid-object-p
           ;; Values looked up once
           #:sname
           #:npath
           #:singleton
           ;; Calling engine methods
           #:define-engine-method
           #:define-engine-class
           #:define-utility-functions
           #:define-global-enums
           ;; Signals
           #:connect-signal
           #:after-signal
           ;; References
           #:add-reference
           #:release-reference
           #:with-reference
           #:setf-reference
           ;; Classes
           #:define-class
           #:register-class
           #:register-singleton
           #:bind-virtual
           #:instance-object
           #:lisp-object
           ;; Binding
           #:bind-method
           #:bind-property
           #:bind-signal)
  ;; Everything GD-EXTENSION-BUILTINS exports, computed when this is read
  #.`(:export ,@(let ((names '()))
                  (do-external-symbols (symbol '#:gd-extension-builtins names)
                    (push (symbol-name symbol) names)))))

(defpackage #:godot
  (:documentation "Godot's API in Lisp: the builtin types, such as Vector2 and
Basis (from GD-EXTENSION-BUILTINS), and functions that call the methods of
engine classes, named <class>-<method>, e.g. NODE-GET-NODE. GD-EXTENSION:
DEFINE-ENGINE-CLASS defines the functions and exports them from here, both for the
classes gdecl defines (godot-engine-classes.lisp) and those applications define.")
  (:nicknames #:gd)
  (:use #:cl #:gd-extension-builtins)
  ;; Everything GD-EXTENSION-BUILTINS exports, computed when this is read
  #.`(:export ,@(let ((names '()))
                  (do-external-symbols (symbol '#:gd-extension-builtins names)
                    (push (symbol-name symbol) names)))))

(defpackage #:godot-utility
  (:documentation "Godot's utility functions in Lisp: the global functions of
GDScript in @GlobalScope, e.g. RANDF-RANGE and PUSH-ERROR, defined with
GD-EXTENSION:DEFINE-UTILITY-FUNCTIONS. Those named like Common Lisp's are left
out; print is GODOT-PRINT.")
  (:nicknames #:gd-util)
  (:use #:cl))

(defpackage #:godot-clos
  (:documentation "A prototype of the high-level layer (TODO P): Godot classes
as CLOS classes. The metaclass GODOT-CLASS registers a DEFCLASS with Godot,
with slots exported as properties, :ONREADY slots and signals, and generic
functions are what Godot calls: virtual methods such as _process, defined with
DEFINE-VIRTUAL-FUNCTION, and methods that GDScript can call, defined with
DEFINE-GODOT-GENERIC. The classes inherit from the structs of engine classes
(DEFINE-ENGINE-CLASS), so their instances are GODOT-OBJECTs to the layers
below.")
  (:use #:cl)
  (:import-from #:gd-extension-types
                #:godot-object
                #:godot-object-pointer)
  (:import-from #:gd-extension-callback
                #:ptrcall-invoker-form
                #:report-error)
  (:import-from #:gd-extension
                #:add-class-definition
                #:inherits-class-p
                #:virtual-signatures
                #:variant-type
                #:godot-property-name
                #:*engine-object-types*)
  (:export ;; Classes
           #:godot-class
           #:godot-name
           ;; Generic functions that Godot calls
           #:virtual-function
           #:define-virtual-function
           #:godot-method
           #:define-godot-generic
           ;; Virtual methods of engine classes
           #:ready
           #:process
           #:physics-process
           #:enter-tree
           #:exit-tree
           #:unhandled-input
           #:draw))
