;;;; The packages GDECL-JSON, a small JSON reader, and EXTENSION-API-JSON:
;;;; extension_api.json, Godot's description of its API, read with it when the
;;;; code is compiled into Lisp structs, so that nothing above depends on how
;;;; the file is laid out. This is the lowest layer: it depends on nothing else
;;;; in gdecl.
;;;; See Layers in CLAUDE.md.

(defpackage #:gdecl-json
  (:documentation "A small JSON reader, for extension_api.json")
  (:use #:cl)
  (:export #:read-json-file
           #:json-get))

(defpackage #:extension-api-json
  (:documentation "extension_api.json, Godot's description of its API, read when
the code is compiled: the sizes of the builtin types, and the engine classes,
their methods, enums and constants, and the utility functions, as Lisp structs
(API-CLASS, API-METHOD, API-ARGUMENT, API-ENUM). Only for code generation: the
library loaded into Godot never reads it.")
  (:use #:cl)
  (:import-from #:gdecl-json
                #:read-json-file
                #:json-get)
  (:export #:*extension-api-file*
           ;; Builtin types
           #:api-builtin-size
           #:api-builtin-method-hash
           ;; Engine classes
           #:api-class
           #:api-class-name
           #:api-class-parent-name
           #:api-class-methods
           #:api-class-enums
           #:api-class-constants
           #:api-class-names
           #:api-class-parents
           #:api-singleton
           #:api-ref-counted-class-p
           ;; Methods and utility functions
           #:api-method
           #:api-method-name
           #:api-method-hash
           #:api-method-arguments
           #:api-method-return-type
           #:api-method-vararg-p
           #:api-method-static-p
           #:api-method-virtual-p
           #:api-argument-name
           #:api-argument-type
           #:api-argument-default-value
           #:api-virtual-methods
           #:api-utility-functions
           ;; Enums and constants
           #:api-enum-name
           #:api-enum-values
           #:api-global-enums
           #:api-constant))
