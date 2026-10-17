;;;; Foreign memory for Godot's values whose layout is opaque to GDExtension:
;;;; String, StringName, NodePath, Variant, Callable, the packed arrays, Array
;;;; and Dictionary. Godot's C interface only passes pointers to them, so their
;;;; sizes come from extension_api.json (API-BUILTIN-SIZE, in
;;;; EXTENSION-API-JSON), when the code is compiled. Here rather than in
;;;; GD-EXTENSION-FFI, so that the C interface doesn't depend on
;;;; extension_api.json. The values are created, read and destroyed through
;;;; the interface functions of GD-EXTENSION-FFI and the value types in
;;;; gd-extension-types.lisp.

(in-package :gd-extension-types)

;; Also when the code is compiled, for the #. below
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defconstant +string-name-size+ (api-builtin-size "StringName"))
  (defconstant +string-size+ (api-builtin-size "String"))
  (defconstant +variant-size+ (api-builtin-size "Variant"))
  (defconstant +node-path-size+ (api-builtin-size "NodePath"))
  (defconstant +callable-size+ (api-builtin-size "Callable"))
  (defconstant +packed-string-array-size+ (api-builtin-size "PackedStringArray"))
  (defconstant +packed-array-size+ (api-builtin-size "PackedByteArray"))
  (defconstant +array-size+ (api-builtin-size "Array"))
  (defconstant +dictionary-size+ (api-builtin-size "Dictionary")))

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

;; Any packed array: they're all the same size, which the build checks
(ffi:def-struct packed-array
  (data '(:array :uint8-t #.+packed-array-size+)))

(eval-when (:compile-toplevel)
  (assert (every (lambda (class-name)
                   (= (macroexpand `(api-builtin-size ,class-name)) +packed-array-size+))
                 '("PackedByteArray" "PackedInt32Array" "PackedInt64Array"
                   "PackedFloat32Array" "PackedFloat64Array" "PackedStringArray"
                   "PackedVector2Array" "PackedVector3Array" "PackedVector4Array"
                   "PackedColorArray"))
          () "The packed arrays aren't all the same size in ~a" *extension-api-file*))

;; Godot's Array and Dictionary. Named GODOT-ARRAY and GODOT-DICTIONARY, since
;; ARRAY is taken by CL.
(ffi:def-struct godot-array
  (data '(:array :uint8-t #.+array-size+)))

(ffi:def-struct godot-dictionary
  (data '(:array :uint8-t #.+dictionary-size+)))
