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
;;; Every Godot object that Lisp gets has one Lisp object, a GODOT-OBJECT (see
;;; GD-EXTENSION-CALLBACK:LISP-OBJECT): an instance of an extension class the
;;; struct its class defines, which includes GODOT-OBJECT, any other object a
;;; struct of the type of its engine class (engine-objects.lisp in
;;; GD-EXTENSION). NIL is null. Wherever an Object is passed to Godot, a raw
;;; Godot object pointer will also do, for dropping down.
;;;

(defstruct godot-object
  "The Lisp object of a Godot object. The structs of engine classes and of
extension classes include it."
  ;; The Godot object pointer
  pointer)

(defun freed-object-error (object)
  (error "The Godot object of ~s has been freed" object))

(declaim (inline object-pointer))
(defun object-pointer (object)
  "The Godot object pointer of OBJECT: a GODOT-OBJECT, NIL for null (a NULL
pointer), or a Godot object pointer, which is returned as it is. Signals an
error if OBJECT is a GODOT-OBJECT whose Godot object has been freed."
  (cond ((godot-object-p object)
         (or (godot-object-pointer object)
             (freed-object-error object)))
        ((null object) (load-time-value (ffi:make-null-pointer :void)))
        (t object)))

(defun valid-object-p (object)
  "True if OBJECT is a GODOT-OBJECT whose Godot object hasn't been freed, like
is_instance_valid in GDScript, or a Godot object pointer that isn't NULL (which
can't be checked)."
  (if (godot-object-p object)
      (and (godot-object-pointer object) t)
      (and object (not (ffi:null-pointer-p object)))))

;;;
;;; Value types
;;;

(defstruct value-type
  ;; The variant type, or :VARIANT for any Variant
  variant-type
  ;; The FFI type of the raw value; its C type is C-TYPE-NAME's
  ffi-type
  ;; Names of functions that read the raw value at a pointer as a Lisp value,
  ;; and that store a Lisp value as a raw value at a pointer
  reader
  writer
  ;; The name of a function that destroys a raw value written by WRITER, or NIL
  destructor
  ;; The type specifier of the Lisp values that become Variants of this type in
  ;; WRITE-VARIANT (see LISP-VARIANT-TYPE): a struct name, HASH-TABLE, or a
  ;; vector type (SIMPLE-ARRAY element-type (*)), or SIMPLE-VECTOR. NIL for
  ;; the types LISP-VARIANT-TYPE knows itself, such as integers.
  lisp-type
  ;; The size of the raw value in bytes, set by ADD-VALUE-TYPE, so it isn't
  ;; looked up at every conversion
  (size nil)
  ;; Names of functions that read a Variant of this type as a Lisp value, and
  ;; that construct one from a Lisp value, faster than through a raw value in
  ;; foreign memory (see READ-VARIANT-AS and WRITE-VARIANT-AS), or NIL
  (variant-reader nil)
  (variant-writer nil)
  ;; For a simple type, whose raw value is a C number or pointer, so that code
  ;; generators convert it in C: functions of a form that make a form for the
  ;; raw value from the Lisp value of the form, e.g. (IF X 1 0) for a bool,
  ;; and for the Lisp value from the raw value of the form, e.g. (/= 0 X).
  ;; NIL for other types. See DEFINE-SIMPLE-VALUE-TYPE.
  (to-raw nil)
  (from-raw nil)
  ;; True for StringName and NodePath: an engine method's argument is passed
  ;; as a pointer to one, such as an SNAME, or to a temporary one made from a
  ;; Lisp string (see GD-EXTENSION::TEMPORARY-NAMES-FORM)
  (by-pointer nil)
  ;; The name of a macro that makes a value made once from a literal string,
  ;; such as GD-EXTENSION:SNAME, or NIL. Set by GD-EXTENSION, which defines the
  ;; macros.
  (literal-macro nil)
  ;; A function of the default value of an argument in extension_api.json, a
  ;; string in GDScript syntax, and the value type, that returns a list of one
  ;; form for it, or NIL if it isn't supported (yet)
  (default-parser nil))

(defparameter *value-types*
  (make-array (1+ +variant-type-variant-max+) :initial-element nil)
  "How values of each supported type are converted between raw values and Lisp
values: the VALUE-TYPE of each variant type, by variant type, and that of
:VARIANT, any Variant, last.")

(defparameter *type-of-variant-types* (make-hash-table :test #'eq)
  "The variant types of the value types whose LISP-TYPE is a symbol (a struct
name, or HASH-TABLE), by that symbol, which TYPE-OF gives for their values.")

(defparameter *element-type-variant-types* (make-hash-table :test #'equal)
  "The variant types of the value types whose LISP-TYPE is a vector type, by
the element type as ARRAY-ELEMENT-TYPE gives it for their values (the upgraded
element type, T for SIMPLE-VECTOR).")

;; Inline: called for every Variant converted, and a call of a function in
;; another file costs about 50 ns in ECL
(declaim (inline value-type-index find-value-type))
(defun value-type-index (variant-type)
  "The index of VARIANT-TYPE (or :VARIANT) in *VALUE-TYPES*, or NIL."
  (cond ((eq variant-type :variant) +variant-type-variant-max+)
        ((and (integerp variant-type) (< -1 variant-type +variant-type-variant-max+))
         variant-type)))

(defun find-value-type (variant-type &optional (errorp t))
  "The VALUE-TYPE of VARIANT-TYPE (or :VARIANT). If there's none, signals an
error, or returns NIL if ERRORP is false."
  (let ((index (value-type-index variant-type)))
    (or (and index (aref *value-types* index))
        (and errorp
             (error "Unsupported type: variant type ~s" variant-type)))))

(defun add-value-type (value-type)
  "Add VALUE-TYPE to *VALUE-TYPES*, replacing one for the same variant type. For
types whose conversion needs a higher layer, such as Callable, and builtin types
(see DEFINE-BUILTIN-TYPE)."
  (when (value-type-ffi-type value-type)
    (setf (value-type-size value-type)
          (ffi:size-of-foreign-type (value-type-ffi-type value-type))))
  (setf (aref *value-types* (value-type-index (value-type-variant-type value-type)))
        value-type)
  (let ((lisp-type (value-type-lisp-type value-type))
        (variant-type (value-type-variant-type value-type)))
    (cond ((null lisp-type))
          ((eq lisp-type 'simple-vector)
           (setf (gethash t *element-type-variant-types*) variant-type))
          ((and (consp lisp-type) (eq (first lisp-type) 'simple-array))
           ;; As ARRAY-ELEMENT-TYPE gives it: in ECL, EXT:BYTE8 for
           ;; (UNSIGNED-BYTE 8)
           (setf (gethash (upgraded-array-element-type (second lisp-type))
                          *element-type-variant-types*)
                 variant-type))
          ((symbolp lisp-type)
           (setf (gethash lisp-type *type-of-variant-types*) variant-type))
          (t (error "Unsupported LISP-TYPE ~s of a value type" lisp-type))))
  value-type)

(defun literal-macro-form (value-type string)
  "The form for a value of VALUE-TYPE made once from the literal STRING, with
its LITERAL-MACRO, such as (GD-EXTENSION:SNAME \"x\")."
  `(,(or (value-type-literal-macro value-type)
         (error "No literal macro for variant type ~s" (value-type-variant-type value-type)))
    ,string))

;;; Parsing default values of arguments in extension_api.json, strings in
;;; GDScript syntax, for the DEFAULT-PARSER of value types

(defun default-number (string)
  "The number STRING is, or NIL."
  (let ((*read-default-float-format* 'double-float)
        (*read-eval* nil))
    (let ((number (ignore-errors (read-from-string string))))
      (and (realp number) number))))

(defun default-string-literal (string start)
  "The contents of the string literal \"...\" in STRING from START to the end,
without escapes, or NIL."
  (let ((end (1- (length string))))
    (and (> end start)
         (char= (char string start) #\")
         (char= (char string end) #\")
         (not (find #\\ string))
         (subseq string (1+ start) end))))

(defun parse-bool-default (default value-type)
  (declare (ignore value-type))
  (cond ((string= default "true") (list t))
        ((string= default "false") (list nil))))

(defun parse-int-default (default value-type)
  (declare (ignore value-type))
  (let ((number (default-number default)))
    (and (integerp number) (list number))))

(defun parse-float-default (default value-type)
  (declare (ignore value-type))
  (let ((number (default-number default)))
    (and number (list (float number 1d0)))))

(defun parse-string-default (default value-type)
  (declare (ignore value-type))
  (let ((contents (default-string-literal default 0)))
    (and contents (list contents))))

(defun parse-string-name-default (default value-type)
  ;; &"name"
  (let ((contents (and (eql 0 (search "&" default)) (default-string-literal default 1))))
    (and contents (list (literal-macro-form value-type contents)))))

(defun parse-node-path-default (default value-type)
  ;; NodePath("path")
  (let ((contents (and (eql 0 (search "NodePath(" default))
                       (string= default ")" :start1 (1- (length default)))
                       (default-string-literal (subseq default 0 (1- (length default))) 9))))
    (and contents (list (literal-macro-form value-type contents)))))

(defun parse-builtin-default (default value-type)
  "For a builtin type whose components are all floats, such as Vector2:
Vector2(x, y) is (VECTOR2 X Y)."
  (let* ((name (value-type-lisp-type value-type))
         (prefix (format nil "~a(" (car (rassoc (value-type-variant-type value-type)
                                                *variant-type-names*))))
         (count (length (builtin-type-components name)))
         (components
           (and (eql 0 (search prefix default))
                (ignore-errors
                 (let ((*read-default-float-format* 'single-float)
                       (*read-eval* nil))
                   (read-from-string
                    (substitute #\Space #\, (subseq default (1- (length prefix))))))))))
    (and (listp components)
         (= (length components) count)
         (every #'realp components)
         (list `(,name ,@(mapcar (lambda (x) (float x 1.0)) components))))))

;; bool, int and float are defined with DEFINE-SIMPLE-VALUE-TYPE below, and
;; Object, whose values are Lisp objects, in GD-EXTENSION-CALLBACK
;; (instance-bindings.lisp)
(dolist (value-type
         (list (make-value-type :variant-type +variant-type-string+ :ffi-type 'godot-string
                         :reader 'read-godot-string :writer 'write-godot-string
                         :destructor 'string-destructor
                         :default-parser 'parse-string-default)
        ;; Read as Lisp strings, and written from them (strings.lisp)
        (make-value-type :variant-type +variant-type-string-name+ :ffi-type 'string-name
                         :reader 'read-string-name :writer 'write-string-name
                         :destructor 'string-name-destructor
                         :by-pointer t
                         :default-parser 'parse-string-name-default)
        (make-value-type :variant-type +variant-type-node-path+ :ffi-type 'node-path
                         :reader 'read-node-path :writer 'write-node-path
                         :destructor 'node-path-destructor
                         :by-pointer t
                         :default-parser 'parse-node-path-default)
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

;;;
;;; Builtin types, see GD-EXTENSION-BUILTINS
;;;
;;; DEFINE-BUILTIN-TYPE connects a Lisp struct of GD-EXTENSION-BUILTINS to
;;; Godot's raw values of the type: the FFI mirror of Godot's layout, named
;;; GODOT-<type> (from builtin_class_member_offsets in extension_api.json, build
;;; configuration float_64, where real_t is float), READ-<type>, WRITE-<type>
;;; and the type's value type.
;;;

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defvar *builtin-type-components* (make-hash-table :test #'eq)
    "The COMPONENTS of DEFINE-BUILTIN-TYPE of each builtin type, by its name.
Also known when the code is compiled, for the builtin types that contain them.")

  (defun builtin-type-components (name)
    "The components of the builtin type NAME, as given to DEFINE-BUILTIN-TYPE, or
NIL if it's not one."
    (values (gethash name *builtin-type-components*)))

  (defvar *builtin-types-with-own-conversion* '()
    "The builtin types whose DEFINE-BUILTIN-TYPE has a READER or WRITER of its own,
as their Lisp components aren't Godot's layout (Basis).")

  (defun builtin-layout (name)
    "The components of a value of the builtin type NAME in the order of Godot's
layout, those of nested builtin types flattened: a list of (ffi-type accessors),
where ACCESSORS are the accessor functions that get the component from the
value, outermost first. NIL if NAME isn't a builtin type whose Lisp components
are in Godot's layout."
    (unless (member name *builtin-types-with-own-conversion*)
      (let ((components (builtin-type-components name)))
        (when components
          (loop for (component type) in components
                for accessor = (builtin-accessor name component)
                append (if (keywordp type)
                           (list (list type (list accessor)))
                           (let ((nested (builtin-layout type)))
                             (unless nested
                               (return-from builtin-layout nil))
                             (loop for (ffi-type accessors) in nested
                                   collect (list ffi-type (cons accessor accessors))))))))))

  (defun builtin-construct-form (name component-forms)
    "A form that makes a value of the builtin type NAME from COMPONENT-FORMS, one
for each component in BUILTIN-LAYOUT, in its order."
    (let ((forms component-forms))
      (labels ((construct (name)
                 `(,name ,@(loop for (nil type) in (builtin-type-components name)
                                 collect (if (keywordp type)
                                             (pop forms)
                                             (construct type))))))
        (construct name))))

  (defun builtin-type-symbol (format-control type)
    "The symbol in this package named by FORMAT-CONTROL with the name of the
builtin TYPE, e.g. GODOT-VECTOR2 for \"GODOT-~a\"."
    (intern (format nil format-control (symbol-name type)) :gd-extension-types))

  (defun builtin-component-ffi-type (type)
    "The FFI type of a component of TYPE in DEFINE-BUILTIN-TYPE: an FFI type such
as :FLOAT, or the mirror of a builtin type defined before."
    (if (keywordp type)
        type
        (builtin-type-symbol "GODOT-~a" type)))

  (defun builtin-accessor (name component)
    "The accessor of COMPONENT of the builtin type NAME, NAME-<component>."
    (intern (format nil "~a-~a" (symbol-name name) (symbol-name component))
            (symbol-package name)))

  (defun builtin-raw-forms (name components pointer value)
    "The form that reads a NAME with COMPONENTS (as in DEFINE-BUILTIN-TYPE) from
its raw value at POINTER, and the forms that write the NAME VALUE there. Each
component, also of nested builtin types, is read and written at its index with
FOREIGN-REF, which a compiler macro makes C code of."
    (let ((offset 0)
          (write-forms '()))
      (labels ((read-form (name components value)
                 `(,name
                   ,@(loop for (component type) in components
                           for accessor-form = `(,(builtin-accessor name component) ,value)
                           collect (if (keywordp type)
                                       (let ((size (ffi:size-of-foreign-type type)))
                                         ;; Godot's layout has no padding
                                         (assert (zerop (mod offset size)))
                                         (let ((index (/ offset size)))
                                           (incf offset size)
                                           (push `(setf (foreign-ref ,pointer ,type ,index)
                                                        ,accessor-form)
                                                 write-forms)
                                           `(foreign-ref ,pointer ,type ,index)))
                                       (read-form type (builtin-type-components type)
                                                  accessor-form))))))
        (values (read-form name components value)
                (reverse write-forms))))))

(defmacro define-builtin-type (name variant-type components &key reader writer)
  "Define how the builtin type NAME, a struct of GD-EXTENSION-BUILTINS made with
(NAME component...), converts to and from Godot's raw values of VARIANT-TYPE.
COMPONENTS is a list of (component type) in the order of Godot's layout, where
the struct's accessor is NAME-<component>, and TYPE is an FFI type such as
:FLOAT, or a builtin type defined before. Defines the FFI mirror GODOT-<name>,
READ-<name> and WRITE-<name>, exports them, and adds the value type. READER and
WRITER name functions of your own instead, for a type whose Lisp components
aren't Godot's layout."
  (let ((mirror (builtin-type-symbol "GODOT-~a" name))
        (reader-name (or reader (builtin-type-symbol "READ-~a" name)))
        (writer-name (or writer (builtin-type-symbol "WRITE-~a" name))))
    (multiple-value-bind (read-form write-forms)
        (builtin-raw-forms name components 'pointer 'value)
      `(progn
         (eval-when (:compile-toplevel :load-toplevel :execute)
           (export '(,mirror ,reader-name ,writer-name) '#:gd-extension-types))
         (ffi:def-struct ,mirror
           ,@(loop for (component type) in components
                   collect `(,component ,(builtin-component-ffi-type type))))
         ,@(unless reader
             `((defun ,reader-name (pointer)
                 ,(format nil "The raw value at POINTER as a ~a." name)
                 ,read-form)))
         ,@(unless writer
             `((defun ,writer-name (pointer value)
                 ,(format nil "Store the ~a VALUE at POINTER as a raw value." name)
                 ,@write-forms)))
         (add-value-type (make-value-type :variant-type ,variant-type
                                          :ffi-type ',mirror
                                          :reader ',reader-name
                                          :writer ',writer-name
                                          :lisp-type ',name
                                          ;; Defaults such as Vector2(0, 0)
                                          ,@(when (every (lambda (component)
                                                           (eq (second component) :float))
                                                         components)
                                              '(:default-parser 'parse-builtin-default))))
         (eval-when (:compile-toplevel :load-toplevel :execute)
           (setf (gethash ',name *builtin-type-components*) ',components)
           ,@(when (or reader writer)
               `((pushnew ',name *builtin-types-with-own-conversion*))))
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

(define-builtin-type color +variant-type-color+
  ((r :float) (g :float) (b :float) (a :float)))

(define-builtin-type vector2i +variant-type-vector2i+
  ((x :int32-t) (y :int32-t)))

(define-builtin-type vector3i +variant-type-vector3i+
  ((x :int32-t) (y :int32-t) (z :int32-t)))

(define-builtin-type vector4 +variant-type-vector4+
  ((x :float) (y :float) (z :float) (w :float)))

(define-builtin-type vector4i +variant-type-vector4i+
  ((x :int32-t) (y :int32-t) (z :int32-t) (w :int32-t)))

(define-builtin-type rect2i +variant-type-rect2i+
  ((position vector2i) (size vector2i)))

(define-builtin-type plane +variant-type-plane+
  ((normal vector3) (d :float)))

(define-builtin-type quaternion +variant-type-quaternion+
  ((x :float) (y :float) (z :float) (w :float)))

(define-builtin-type aabb +variant-type-aabb+
  ((position vector3) (size vector3)))

;; Godot's x, y and origin are the columns, like the Lisp TRANSFORM2D's
(define-builtin-type transform2d +variant-type-transform2d+
  ((x vector2) (y vector2) (origin vector2)))

;; Godot's x, y, z and w are the columns, like the Lisp PROJECTION's
(define-builtin-type projection +variant-type-projection+
  ((x vector4) (y vector4) (z vector4) (w vector4)))

(define-builtin-type rid +variant-type-rid+
  ((id :uint64-t)))

;; Its Basis is stored as rows, see READ-BASIS
(define-builtin-type transform3d +variant-type-transform3d+
  ((basis basis) (origin vector3))
  :reader read-transform3d
  :writer write-transform3d)

(defun read-transform3d (pointer)
  "The raw value at POINTER as a TRANSFORM3D: the Basis, then the origin, after
the 9 floats of the Basis."
  (transform3d (read-basis pointer)
               (read-vector3 (array-element pointer :float 9))))

(defun write-transform3d (pointer transform)
  "Store the TRANSFORM3D at POINTER as a raw value."
  (write-basis pointer (transform3d-basis transform))
  (write-vector3 (array-element pointer :float 9) (transform3d-origin transform)))

(defun read-basis (pointer)
  "The raw value at POINTER as a BASIS, made from Godot's rows."
  ;; Row I, column J is at index 3I + J
  (flet ((at (row column)
           (foreign-ref pointer :float (+ (* 3 row) column))))
    (basis (vector3 (at 0 0) (at 1 0) (at 2 0))
           (vector3 (at 0 1) (at 1 1) (at 2 1))
           (vector3 (at 0 2) (at 1 2) (at 2 2)))))

(defun write-basis (pointer basis)
  "Store the BASIS at POINTER as a raw value, with Godot's rows."
  (loop for column in (list (basis-x basis) (basis-y basis) (basis-z basis))
        for j from 0
        do (setf (foreign-ref pointer :float j) (vector3-x column)
                 (foreign-ref pointer :float (+ 3 j)) (vector3-y column)
                 (foreign-ref pointer :float (+ 6 j)) (vector3-z column))))

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
    ;; Before other vectors
    (string +variant-type-string+)
    ;; Before other structs, as the Lisp objects of instances include it. Not
    ;; raw pointers, which might point to something else than an Object, such
    ;; as a StringName.
    (godot-object +variant-type-object+)
    ;; By element type: specialized vectors are packed arrays, and simple
    ;; vectors Arrays (see containers.lisp in GD-EXTENSION)
    ((simple-array * (*))
     (values (gethash (array-element-type value) *element-type-variant-types*)))
    ;; Structs, such as VECTOR2, and hash tables, which are Dictionaries
    (t (values (gethash (type-of value) *type-of-variant-types*)))))

(defun variant-value-p (value)
  "True if WRITE-VARIANT can make a Variant from VALUE."
  (and (lisp-variant-type value) t))

(defun write-variant (variant value)
  "Construct a Variant at VARIANT, uninitialized memory, from the Lisp VALUE,
of the variant type LISP-VARIANT-TYPE gives by its Lisp type: e.g. T or NIL is a
bool, a string a String, a VECTOR2 a Vector2, a specialized vector a packed
array, a simple vector an Array, a hash table a Dictionary, and a GODOT-OBJECT
an Object (but not a raw pointer, which might point to something else, such as
a StringName). Destroy it with VARIANT-DESTROY."
  (write-variant-as variant
                    (find-value-type (or (lisp-variant-type value)
                                         (error "Can't make a Variant from ~s" value)))
                    value))

(defun write-variant-as (variant value-type value)
  "Construct a Variant of VALUE-TYPE at VARIANT, uninitialized memory, from the
Lisp VALUE, with the type's VARIANT-WRITER, or through a temporary raw value.
Destroy it with VARIANT-DESTROY."
  (let ((variant-writer (value-type-variant-writer value-type)))
    (if variant-writer
        (funcall variant-writer variant value)
        ;; The Variant gets a copy of the raw value
        (with-foreign-memory ((raw :size (value-type-size value-type)))
          (write-value raw value-type value)
          (unwind-protect
               (call-variant-from-type-constructor
                (aref *variant-from-type-constructors* (value-type-variant-type value-type))
                variant raw)
            (destroy-value raw value-type))))))

(defun read-variant-as (variant value-type)
  "The value of the Variant at VARIANT, which is of VALUE-TYPE, as a Lisp value,
with the type's VARIANT-READER, or through a temporary raw value."
  (let ((variant-reader (value-type-variant-reader value-type)))
    (if variant-reader
        (funcall variant-reader variant)
        (with-foreign-memory ((raw :size (value-type-size value-type)))
          (call-type-from-variant-constructor
           (aref *type-from-variant-constructors* (value-type-variant-type value-type))
           raw variant)
          (unwind-protect (read-value raw value-type)
            (destroy-value raw value-type))))))

;;; The primitive types' Variants are converted in one piece of C code each,
;;; with the raw value in a C variable, instead of in foreign memory from
;;; Lisp: that allocates nothing, and is several times faster.

(defmacro variant-from-raw (variant variant-type ffi-type c-type value)
  "Construct a Variant of VARIANT-TYPE at VARIANT from VALUE, a raw value of
FFI-TYPE (C-TYPE in C), with Godot's constructor."
  `(ffi:c-inline ((aref *variant-from-type-constructors* ,variant-type) ,variant ,value)
                 (:pointer-void :pointer-void ,ffi-type) :void
                 ,(format nil "{ ~a value = #2; ((void (*)(void *, void *))#0)(#1, &value); }"
                          c-type)))

(defmacro raw-from-variant (variant variant-type ffi-type c-type)
  "The raw value of FFI-TYPE (C-TYPE in C) of the Variant of VARIANT-TYPE at
VARIANT, with Godot's constructor."
  `(ffi:c-inline ((aref *type-from-variant-constructors* ,variant-type) ,variant)
                 (:pointer-void :pointer-void) ,ffi-type
                 ,(format nil "{ ~a value; ((void (*)(void *, void *))#0)(&value, #1); @(return 0) = value; }"
                          c-type)))

(defmacro define-simple-value-type (variant-type ffi-type
                                    &key reader writer variant-reader variant-writer
                                         to-raw from-raw default-parser)
  "Define the value type of VARIANT-TYPE, a simple type whose raw value is of
FFI-TYPE, a C number or pointer: the functions READER and WRITER of the raw
value at a pointer, VARIANT-READER and VARIANT-WRITER of a Variant, converted
in one piece of C code, and the value type, whose TO-RAW and FROM-RAW (LAMBDA
forms, see VALUE-TYPE) make the conversions between the Lisp and the raw value
here and in the code generators."
  (let ((c-type (c-type-name ffi-type))
        (to-raw-function (coerce (eval to-raw) 'function))
        (from-raw-function (coerce (eval from-raw) 'function)))
    `(progn
       (defun ,reader (pointer)
         ,(funcall from-raw-function `(foreign-ref pointer ,ffi-type)))
       (defun ,writer (pointer value)
         (setf (foreign-ref pointer ,ffi-type) ,(funcall to-raw-function 'value)))
       (defun ,variant-reader (variant)
         ,(funcall from-raw-function
                   `(raw-from-variant variant ,variant-type ,ffi-type ,c-type)))
       (defun ,variant-writer (variant value)
         (variant-from-raw variant ,variant-type ,ffi-type ,c-type
                           ,(funcall to-raw-function 'value)))
       (add-value-type (make-value-type :variant-type ,variant-type :ffi-type ,ffi-type
                                        :reader ',reader :writer ',writer
                                        :variant-reader ',variant-reader
                                        :variant-writer ',variant-writer
                                        :to-raw ,to-raw :from-raw ,from-raw
                                        :default-parser ,default-parser)))))

;; GDExtensionBool is uint8_t, and Godot's int and float are 64 bits (also
;; when a method's metadata says they're smaller)

(define-simple-value-type +variant-type-bool+ :uint8-t
  :reader read-bool :writer write-bool
  :variant-reader read-bool-variant :variant-writer write-bool-variant
  :to-raw (lambda (form) `(if ,form 1 0))
  :from-raw (lambda (form) `(/= 0 ,form))
  :default-parser 'parse-bool-default)

(define-simple-value-type +variant-type-int+ :int64-t
  :reader read-int :writer write-int
  :variant-reader read-int-variant :variant-writer write-int-variant
  :to-raw (lambda (form) form)
  :from-raw (lambda (form) form)
  :default-parser 'parse-int-default)

(define-simple-value-type +variant-type-float+ :double
  :reader read-float :writer write-float
  :variant-reader read-float-variant :variant-writer write-float-variant
  :to-raw (lambda (form) `(float ,form 1d0))
  :from-raw (lambda (form) form)
  :default-parser 'parse-float-default)

(defun read-variant (variant)
  "The value of the Variant at VARIANT as a Lisp value, by its type: NIL for
Nil, otherwise as in *VALUE-TYPES*."
  (let ((variant-type (variant-get-type variant)))
    (if (= variant-type +variant-type-nil+)
        nil
        (let* ((value-type (find-value-type variant-type))
               (variant-reader (value-type-variant-reader value-type)))
          (cond (variant-reader
                 (funcall variant-reader variant))
                ((and (value-type-ffi-type value-type) (value-type-reader value-type))
                 (read-variant-as variant value-type))
                (t
                 (error "Unsupported type for a Variant: variant type ~s" variant-type)))))))
