;;;; The package GD-EXTENSION-API: extension_api.json, Godot's description of its
;;;; API, read when the code is compiled. It uses GDECL-JSON (util/), and
;;;; re-exports JSON-GET, for reading the JSON objects its lookups return.
;;;; See Layers in CLAUDE.md.

(defpackage #:gd-extension-api
  (:documentation "extension_api.json, Godot's description of its API, read when
the code is compiled: the sizes of the builtin types, and the engine classes,
methods, enums, constants and utility functions, as JSON objects, read with
JSON-GET. Only for code generation: the library loaded into Godot never reads
it.")
  (:nicknames #:gdext-api)
  (:use #:cl)
  (:import-from #:gdecl-json
                #:read-json-file
                #:json-get)
  (:export ;; The file
           #:*extension-api-file*
           #:extension-api-json
           #:json-get
           ;; Builtin types
           #:api-builtin-size
           #:api-builtin-method-hash
           ;; Engine classes
           #:extension-api
           #:extension-api-classes
           #:api-class
           #:api-class-parents
           #:api-singleton
           #:api-ref-counted-class-p
           #:api-method
           #:api-virtual-methods
           ;; Global scope
           #:api-utility-functions
           #:api-global-enums
           ;; Constants
           #:api-constant-value
           #:api-constant))
