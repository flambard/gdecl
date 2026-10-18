;;;; The packages GD-EXTENSION-BUILTINS, Godot's builtin types in plain Lisp,
;;;; which depends on nothing else in gdecl, and GD-EXTENSION-TYPES, converting
;;;; values between Godot and Lisp, which uses ffi/, the builtin types, and
;;;; extension-api/ for the sizes of Godot's opaque values.
;;;; See Layers in CLAUDE.md.

(defpackage #:gd-extension-builtins
  (:documentation "Lisp versions of Godot's builtin types, such as Vector2 and
Basis, with their functions. Everything exported from here is for applications:
GODOT re-exports all of it, so a symbol is added here only.")
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
  (:import-from #:extension-api-json
                #:api-builtin-size
                #:*extension-api-file*)
  (:export ;; Foreign memory for Godot's opaque values (opaque-values.lisp)
           #:+string-name-size+
           #:+string-size+
           #:+variant-size+
           #:+node-path-size+
           #:string-name
           #:godot-string
           #:variant
           #:node-path
           #:godot-callable
           #:godot-signal
           #:+callable-size+
           #:packed-array
           #:godot-array
           #:godot-dictionary
           ;; Objects
           #:godot-object
           #:+godot-object-pointer-slot+
           #:+godot-object-pointer-location+
           #:make-godot-object
           #:godot-object-p
           #:godot-object-pointer
           #:object-pointer
           #:valid-object-p
           ;; Builtin types
           #:builtin-layout
           #:builtin-construct-form
           ;; Strings, StringNames and NodePaths
           #:with-string
           #:read-string-name
           #:write-string-name
           #:with-string-name
           #:string-name-equal
           #:write-node-path
           #:make-temporary-name
           #:destroy-temporary-name
           #:write-variant
           #:write-variant-at
           #:destroy-variant-at
           #:address-pointer
           #:variant-value-p
           #:lisp-variant-type
           #:read-variant
           #:read-variant-at
           #:variant-type-at
           #:read-variant-result
           ;; The autorelease pool
           #:*release-reference-function*
           #:autorelease-reference
           #:autorelease-callable
           #:release-engine-callable
           #:release-autoreleased
           #:reference-for-caller
           #:release-autorelease-pool
           #:*autorelease-pool*
           #:callable
           #:callable-p
           #:callable-target
           #:callable-function
           #:engine-callable
           #:engine-callable-p
           #:make-engine-callable
           #:engine-callable-memory
           #:engine-signal
           #:engine-signal-p
           #:engine-signal-object
           #:engine-signal-name
           ;; Value types
           #:value-type
           #:value-type-variant-type
           #:value-type-ffi-type
           #:value-type-reader
           #:value-type-writer
           #:value-type-to-raw
           #:value-type-from-raw
           #:value-type-from-address
           #:raw-result-conversion
           #:value-type-by-pointer
           #:value-type-literal-macro
           #:value-type-default-parser
           #:define-simple-value-type
           #:value-type-destructor
           #:value-type-lisp-type
           #:find-value-type
           #:add-value-type
           #:read-value
           #:write-value
           #:write-variant-as
           #:write-variant-as-at
           #:read-variant-as
           #:make-value-type))
