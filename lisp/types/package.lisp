;;;; The package GD-EXTENSION-TYPES: converting values between Godot and Lisp. It
;;;; uses ffi/ and builtins/.
;;;; See Layers in CLAUDE.md.

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
