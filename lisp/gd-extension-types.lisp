(in-package :gd-extension-types)

;;;
;;; Converting Godot's types between raw values and Lisp values: READ-
;;; functions that make a Lisp value from the raw value at a pointer, and WRITE-
;;; functions that store one there. The Lisp versions of the builtin types, such
;;; as VECTOR2, are in GD-EXTENSION-BUILTINS (builtin-types.lisp). GD-EXTENSION
;;; re-exports what applications use.
;;;
;;; *VALUE-TYPES* says how to convert each type between raw values and Lisp
;;; values. It's used by GD-EXTENSION-CALLBACK for the arguments and results of
;;; bound methods, and by GD-EXTENSION for those of engine methods.
;;;

;;;
;;; Objects
;;;
;;; A Godot object is a pointer in Lisp, but an instance of an extension class
;;; has a Lisp object too (see GD-EXTENSION:REGISTER-CLASS), a GODOT-OBJECT:
;;; applications include GODOT-OBJECT in their structs. Wherever an Object is
;;; passed to Godot, either one will do, and NIL is null.
;;;

(defstruct godot-object
  "The Lisp object of an instance of an extension class. Include it in the
struct of a class's Lisp objects."
  ;; The Godot object pointer
  pointer)

(declaim (inline object-pointer))
(defun object-pointer (object)
  "The Godot object pointer of OBJECT: a GODOT-OBJECT, NIL for null (a NULL
pointer), or a Godot object pointer, which is returned as it is."
  (cond ((godot-object-p object) (godot-object-pointer object))
        ((null object) (load-time-value (ffi:make-null-pointer :void)))
        (t object)))

;;;
;;; Value types
;;;

(defstruct value-type
  ;; The variant type, or :VARIANT for any Variant
  variant-type
  ;; The FFI type of the raw value, or NIL if the value is passed as a pointer to
  ;; it, which is then also its Lisp value (StringName, NodePath)
  ffi-type
  ;; Names of functions that read the raw value at a pointer as a Lisp value,
  ;; and that store a Lisp value as a raw value at a pointer
  reader
  writer
  ;; The name of a function that destroys a raw value written by WRITER, or NIL
  destructor
  ;; The struct type of the Lisp values, for WRITE-VARIANT (see
  ;; LISP-VARIANT-TYPE), or NIL for the other types
  lisp-type)

(defparameter *value-types*
  (make-array (1+ +variant-type-variant-max+) :initial-element nil)
  "How values of each supported type are converted between raw values and Lisp
values: the VALUE-TYPE of each variant type, by variant type, and that of
:VARIANT, any Variant, last.")

(defparameter *struct-variant-types* (make-hash-table :test #'eq)
  "The variant types of the value types with a LISP-TYPE, by the struct type.")

(defun value-type-index (variant-type)
  "The index of VARIANT-TYPE (or :VARIANT) in *VALUE-TYPES*, or NIL."
  (cond ((eq variant-type :variant) +variant-type-variant-max+)
        ((and (integerp variant-type) (< -1 variant-type +variant-type-variant-max+))
         variant-type)))

(defun find-value-type (variant-type)
  "The VALUE-TYPE of VARIANT-TYPE (or :VARIANT)."
  (let ((index (value-type-index variant-type)))
    (or (and index (aref *value-types* index))
        (error "Unsupported type: variant type ~s" variant-type))))

(defun add-value-type (value-type)
  "Add VALUE-TYPE to *VALUE-TYPES*, replacing one for the same variant type. For
types whose conversion needs a higher layer, such as Callable, and builtin types
(see DEFINE-BUILTIN-TYPE)."
  (setf (aref *value-types* (value-type-index (value-type-variant-type value-type)))
        value-type)
  (when (value-type-lisp-type value-type)
    (setf (gethash (value-type-lisp-type value-type) *struct-variant-types*)
          (value-type-variant-type value-type)))
  value-type)

(dolist (value-type
         (list (make-value-type :variant-type +variant-type-bool+ :ffi-type :uint8-t
                         :reader 'read-bool :writer 'write-bool)
        (make-value-type :variant-type +variant-type-int+ :ffi-type :int64-t
                         :reader 'read-int :writer 'write-int)
        (make-value-type :variant-type +variant-type-float+ :ffi-type :double
                         :reader 'read-float :writer 'write-float)
        (make-value-type :variant-type +variant-type-object+ :ffi-type :pointer-void
                         :reader 'read-object :writer 'write-object)
        (make-value-type :variant-type +variant-type-string+ :ffi-type 'godot-string
                         :reader 'read-godot-string :writer 'write-godot-string
                         :destructor 'string-destructor)
        (make-value-type :variant-type +variant-type-packed-string-array+
                         :ffi-type 'packed-string-array
                         :reader 'read-packed-string-array
                         :destructor 'packed-string-array-destructor)
        (make-value-type :variant-type +variant-type-string-name+)
        (make-value-type :variant-type +variant-type-node-path+)
        ;; The reader is for results, see READ-VARIANT-RESULT
        (make-value-type :variant-type :variant :ffi-type 'variant
                         :reader 'read-variant-result :writer 'write-variant
                         :destructor 'variant-destroy)))
  (add-value-type value-type))

(defun read-value (pointer value-type)
  "The raw value of VALUE-TYPE at POINTER as a Lisp value."
  (funcall (value-type-reader value-type) pointer))

(defun write-value (pointer value-type value)
  "Store the Lisp VALUE as a raw value of VALUE-TYPE at POINTER."
  (funcall (value-type-writer value-type) pointer value))

(defun destroy-value (pointer value-type)
  "Destroy the raw value of VALUE-TYPE at POINTER, if it needs it (e.g. a
String)."
  (let ((destructor (value-type-destructor value-type)))
    (when destructor
      (funcall destructor pointer))))

;; GDExtensionBool is uint8_t, and Godot's int and float are 64 bits (also
;; when a method's metadata says they're smaller). The raw value of an Object
;; is the object pointer.

(defun read-bool (pointer) (/= (foreign-ref pointer :uint8-t) 0))
(defun write-bool (pointer value) (setf (foreign-ref pointer :uint8-t) (if value 1 0)))
(defun read-int (pointer) (foreign-ref pointer :int64-t))
(defun write-int (pointer value) (setf (foreign-ref pointer :int64-t) value))
(defun read-float (pointer) (foreign-ref pointer :double))
(defun write-float (pointer value) (setf (foreign-ref pointer :double) (float value 1d0)))
(defun read-object (pointer) (foreign-ref pointer :pointer-void))
(defun write-object (pointer value)
  (setf (foreign-ref pointer :pointer-void) (object-pointer value)))

;;;
;;; Builtin types, see GD-EXTENSION-BUILTINS
;;;
;;; DEFINE-BUILTIN-TYPE connects a Lisp struct of GD-EXTENSION-BUILTINS to
;;; Godot's raw values of the type: the FFI mirror of Godot's layout, named
;;; GODOT-<type> (from builtin_class_member_offsets in extension_api.json, build
;;; configuration float_64, where real_t is float), READ-<type>, WRITE-<type>
;;; and the type's value type.
;;;

(defvar *builtin-type-components* (make-hash-table :test #'eq)
  "The COMPONENTS of DEFINE-BUILTIN-TYPE of each builtin type, by its name.")

(defun builtin-type-components (name)
  "The components of the builtin type NAME, as given to DEFINE-BUILTIN-TYPE, or
NIL if it's not one."
  (values (gethash name *builtin-type-components*)))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun builtin-type-symbol (format-control type)
    "The symbol in this package named by FORMAT-CONTROL with the name of the
builtin TYPE, e.g. GODOT-VECTOR2 for \"GODOT-~a\"."
    (intern (format nil format-control (symbol-name type)) :gd-extension-types))

  (defun builtin-component-ffi-type (type)
    "The FFI type of a component of TYPE in DEFINE-BUILTIN-TYPE: an FFI type such
as :FLOAT, or the mirror of a builtin type defined before."
    (if (keywordp type)
        type
        (builtin-type-symbol "GODOT-~a" type))))

(defmacro define-builtin-type (name variant-type components &key reader writer)
  "Define how the builtin type NAME, a struct of GD-EXTENSION-BUILTINS made with
(NAME component...), converts to and from Godot's raw values of VARIANT-TYPE.
COMPONENTS is a list of (component type) in the order of Godot's layout, where
the struct's accessor is NAME-<component>, and TYPE is an FFI type such as
:FLOAT, or a builtin type defined before. Defines the FFI mirror GODOT-<name>,
READ-<name> and WRITE-<name>, and adds the value type. READER and WRITER name
functions of your own instead, for a type whose Lisp components aren't Godot's
layout."
  (let ((mirror (builtin-type-symbol "GODOT-~a" name))
        (reader-name (or reader (builtin-type-symbol "READ-~a" name)))
        (writer-name (or writer (builtin-type-symbol "WRITE-~a" name))))
    (flet ((accessor (component)
             (intern (format nil "~a-~a" (symbol-name name) (symbol-name component))
                     (symbol-package name)))
           (slot-pointer (component)
             `(ffi:get-slot-pointer pointer ',mirror ',component)))
      `(progn
         (ffi:def-struct ,mirror
           ,@(loop for (component type) in components
                   collect `(,component ,(builtin-component-ffi-type type))))
         ,@(unless reader
             `((defun ,reader-name (pointer)
                 ,(format nil "The raw value at POINTER as a ~a." name)
                 (let ((pointer (cast-pointer pointer ',mirror)))
                   (,name ,@(loop for (component type) in components
                                  collect (if (keywordp type)
                                              `(ffi:get-slot-value pointer ',mirror ',component)
                                              `(,(builtin-type-symbol "READ-~a" type)
                                                ,(slot-pointer component)))))))))
         ,@(unless writer
             `((defun ,writer-name (pointer value)
                 ,(format nil "Store the ~a VALUE at POINTER as a raw value." name)
                 (let ((pointer (cast-pointer pointer ',mirror)))
                   ,@(loop for (component type) in components
                           collect (if (keywordp type)
                                       `(setf (ffi:get-slot-value pointer ',mirror ',component)
                                              (,(accessor component) value))
                                       `(,(builtin-type-symbol "WRITE-~a" type)
                                         ,(slot-pointer component)
                                         (,(accessor component) value))))))))
         (add-value-type (make-value-type :variant-type ,variant-type
                                          :ffi-type ',mirror
                                          :reader ',reader-name
                                          :writer ',writer-name
                                          :lisp-type ',name))
         (setf (gethash ',name *builtin-type-components*) ',components)
         ',name))))

(define-builtin-type vector2 +variant-type-vector2+
  ((x :float) (y :float)))

(define-builtin-type rect2 +variant-type-rect2+
  ((position vector2) (size vector2)))

(define-builtin-type vector3 +variant-type-vector3+
  ((x :float) (y :float) (z :float)))

;; Godot stores a Basis as its rows, but the Lisp BASIS has its columns, as
;; basis.x and Basis(x, y, z) in GDScript, so it has a reader and writer that
;; transpose
(define-builtin-type basis +variant-type-basis+
  ((x vector3) (y vector3) (z vector3))
  :reader read-basis
  :writer write-basis)

(defun read-basis (pointer)
  (let* ((pointer (cast-pointer pointer 'godot-basis))
         (row-x (read-vector3 (ffi:get-slot-pointer pointer 'godot-basis 'x)))
         (row-y (read-vector3 (ffi:get-slot-pointer pointer 'godot-basis 'y)))
         (row-z (read-vector3 (ffi:get-slot-pointer pointer 'godot-basis 'z))))
    (basis (vector3 (vector3-x row-x) (vector3-x row-y) (vector3-x row-z))
           (vector3 (vector3-y row-x) (vector3-y row-y) (vector3-y row-z))
           (vector3 (vector3-z row-x) (vector3-z row-y) (vector3-z row-z)))))

(defun write-basis (pointer basis)
  (let ((pointer (cast-pointer pointer 'godot-basis))
        (x (basis-x basis))
        (y (basis-y basis))
        (z (basis-z basis)))
    (write-vector3 (ffi:get-slot-pointer pointer 'godot-basis 'x)
                   (vector3 (vector3-x x) (vector3-x y) (vector3-x z)))
    (write-vector3 (ffi:get-slot-pointer pointer 'godot-basis 'y)
                   (vector3 (vector3-y x) (vector3-y y) (vector3-y z)))
    (write-vector3 (ffi:get-slot-pointer pointer 'godot-basis 'z)
                   (vector3 (vector3-z x) (vector3-z y) (vector3-z z)))))

(defun read-godot-string (pointer)
  "The Godot String at POINTER as a Lisp string."
  (let* ((length (string-to-utf8-chars pointer (ffi:make-null-pointer :void) 0))
         (octets (make-array length :element-type '(unsigned-byte 8))))
    (string-to-utf8-chars pointer (si:make-foreign-data-from-array octets) length)
    (ext:octets-to-string octets :external-format :utf-8)))

(defun write-godot-string (pointer string)
  "Construct a Godot String at POINTER, uninitialized memory, from the Lisp
STRING. Destroy it with STRING-DESTRUCTOR."
  (string-new-with-utf8-chars pointer string))

(defun read-packed-string-array (pointer)
  "The PackedStringArray at POINTER as a list of Lisp strings."
  (let ((size (ffi:with-foreign-object (r-return :int64-t)
                (call-ptr-builtin-method *packed-string-array-size* pointer
                                         (ffi:make-null-pointer :void) r-return 0)
                (foreign-ref r-return :int64-t))))
    (loop for i below size
          collect (read-godot-string (packed-string-array-operator-index pointer i)))))

(defstruct (callable (:constructor callable (target function)))
  "A Callable that calls the Lisp FUNCTION with the arguments as Lisp values,
bound to the Godot object TARGET (a pointer): Godot only calls it while TARGET
exists. Converted to a Godot Callable by GD-EXTENSION-CALLBACK."
  target
  function)

;;;
;;; Variants
;;;

(defun lisp-variant-type (value)
  "The variant type of the Variant that WRITE-VARIANT makes from VALUE, by its
Lisp type, or NIL if it can't make one. Structs, such as VECTOR2 and CALLABLE,
are found by the LISP-TYPE of their value types."
  (typecase value
    ;; Before integers, as NIL is also a list
    (boolean +variant-type-bool+)
    (integer +variant-type-int+)
    (real +variant-type-float+)
    (string +variant-type-string+)
    ;; Before other structs, as the Lisp objects of instances include it
    ((or godot-object si:foreign-data) +variant-type-object+)
    (structure-object (values (gethash (type-of value) *struct-variant-types*)))))

(defun variant-value-p (value)
  "True if WRITE-VARIANT can make a Variant from VALUE."
  (and (lisp-variant-type value) t))

(defun write-variant (variant value)
  "Construct a Variant at VARIANT, uninitialized memory, from the Lisp VALUE,
by its Lisp type: T or NIL is a bool, an integer an int, a real a float, a
string a String, a VECTOR2 a Vector2, a RECT2 a Rect2, a VECTOR3 a Vector3, a
BASIS a Basis, a GODOT-OBJECT or a pointer an Object, and a CALLABLE a Callable. Destroy it with VARIANT-DESTROY."
  (write-variant-as variant
                    (find-value-type (or (lisp-variant-type value)
                                         (error "Can't make a Variant from ~s" value)))
                    value))

(defun write-variant-as (variant value-type value)
  "Construct a Variant of VALUE-TYPE at VARIANT, uninitialized memory, from the
Lisp VALUE, through a temporary raw value. Destroy it with VARIANT-DESTROY."
  ;; The Variant gets a copy of the raw value
  (ffi:with-foreign-object (raw (value-type-ffi-type value-type))
    (write-value raw value-type value)
    (unwind-protect
         (call-variant-from-type-constructor
          (aref *variant-from-type-constructors* (value-type-variant-type value-type))
          variant raw)
      (destroy-value raw value-type))))

(defun read-variant-as (variant value-type)
  "The value of the Variant at VARIANT, which is of VALUE-TYPE, as a Lisp value,
through a temporary raw value."
  (ffi:with-foreign-object (raw (value-type-ffi-type value-type))
    (call-type-from-variant-constructor
     (aref *type-from-variant-constructors* (value-type-variant-type value-type)) raw variant)
    (unwind-protect (read-value raw value-type)
      (destroy-value raw value-type))))

(defun read-variant (variant)
  "The value of the Variant at VARIANT as a Lisp value, by its type: NIL for
Nil, otherwise as in *VALUE-TYPES*."
  (let ((variant-type (variant-get-type variant)))
    (if (= variant-type +variant-type-nil+)
        nil
        (let ((value-type (find-value-type variant-type)))
          (unless (and (value-type-ffi-type value-type) (value-type-reader value-type))
            (error "Unsupported type for a Variant: variant type ~s" variant-type))
          (read-variant-as variant value-type)))))

;;;
;;; The autorelease pool
;;;
;;; A RefCounted object that Lisp gets as the result of a call into Godot comes
;;; with a reference (like a Ref<T>). During a call from Godot into Lisp, those
;;; references go into the autorelease pool of that call, and are given back
;;; when it returns (see GD-EXTENSION-CALLBACK, which makes a pool for each
;;; callback), so Lisp code doesn't have to. To keep such an object, take a
;;; reference of its own (GD-EXTENSION:SETF-REFERENCE). Outside a call from
;;; Godot, e.g. at a REPL, there's no pool, and the caller owns the references.
;;;

(defvar *autorelease-pool* :none
  "The references to give back when the call from Godot that's running returns:
a list of (kind handle address), where KIND is :REFERENCE (HANDLE is a
RefCounted object with a reference) or :VARIANT (HANDLE is a Variant, in memory
from MEM-ALLOC, that keeps the reference of an Object result), and ADDRESS is
the object's address. :NONE when there's no pool.")

(defvar *release-reference-function* nil
  "The function that gives back a reference to a RefCounted object,
GD-EXTENSION:RELEASE-REFERENCE, which needs an engine method, so it's set when
GD-EXTENSION is loaded.")

(defun autorelease-pool-p ()
  "True if there's an autorelease pool, during a call from Godot."
  (listp *autorelease-pool*))

(defun autorelease-reference (object)
  "Put the reference to the RefCounted OBJECT (a pointer or a GODOT-OBJECT, or
NIL) that the caller got from a call into Godot in the autorelease pool, if
there's one. Returns OBJECT."
  (when (and object (autorelease-pool-p))
    (push (list :reference object (ffi:pointer-address (object-pointer object)))
          *autorelease-pool*))
  object)

(defun release-autorelease-entry (entry)
  (destructuring-bind (kind handle address) entry
    (declare (ignore address))
    (ecase kind
      (:reference (funcall *release-reference-function* handle))
      (:variant (variant-destroy handle)
                (mem-free handle)))))

(defun release-autorelease-pool ()
  "Give back the references in the autorelease pool, the last first, and empty
it."
  (loop while (consp *autorelease-pool*)
        do (release-autorelease-entry (pop *autorelease-pool*))))

(defun release-autoreleased (object)
  "Give back the reference to OBJECT in the autorelease pool now, and take it out
of the pool. Returns true if OBJECT was in it."
  (when (and object (autorelease-pool-p))
    (let* ((address (ffi:pointer-address (object-pointer object)))
           (entry (find address *autorelease-pool* :key #'third)))
      (when entry
        (setf *autorelease-pool* (delete entry *autorelease-pool* :count 1))
        (release-autorelease-entry entry)
        t))))

(defmacro with-autorelease-pool (&body body)
  "Evaluate BODY with an autorelease pool of its own, and give back the
references in it when BODY exits, also on a non-local exit."
  `(let ((*autorelease-pool* '()))
     (unwind-protect (progn ,@body)
       (release-autorelease-pool))))

(defun reference-for-caller (object)
  "Take a reference to OBJECT (a pointer or a GODOT-OBJECT, or NIL) if it's
RefCounted, for Godot, which calls a method with ptrcall and gets OBJECT as its
result: Godot puts the object pointer right into a Variant or a Ref<T> without
taking a reference, and gives one back later, as for the results of engine
methods. A Variant made from OBJECT and never destroyed keeps the reference, so
there's no need to ask Godot whether OBJECT is RefCounted."
  (when object
    (ffi:with-foreign-objects ((variant 'variant)
                               (raw :pointer-void))
      (setf (foreign-ref raw :pointer-void) (object-pointer object))
      (call-variant-from-type-constructor
       (aref *variant-from-type-constructors* +variant-type-object+) variant raw))))

(defun read-variant-result (variant)
  "The value of the Variant at VARIANT, the result of a call, as a Lisp value, as
in READ-VARIANT. If it's an Object, the caller gets the reference the Variant
has to it, if it's a RefCounted: like the RefCounted result of an engine method
(a Ref<T>), it goes into the autorelease pool, or without one, the caller gives
it back with GD-EXTENSION:RELEASE-REFERENCE. The caller destroys the Variant as
usual."
  (let ((value (read-variant variant)))
    ;; A copy of the Variant keeps the reference, without asking Godot whether
    ;; the object is RefCounted: a Variant with any other object has no
    ;; reference to give back
    (when (and value (= (variant-get-type variant) +variant-type-object+))
      (if (autorelease-pool-p)
          (let ((copy (mem-alloc +variant-size+)))
            (variant-new-copy copy variant)
            (push (list :variant copy (ffi:pointer-address (object-pointer value)))
                  *autorelease-pool*))
          ;; Never destroyed
          (ffi:with-foreign-object (copy 'variant)
            (variant-new-copy copy variant))))
    value))
