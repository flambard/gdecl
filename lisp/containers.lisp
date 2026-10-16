(in-package :gd-extension)

;;;
;;; Godot's packed arrays, Array and Dictionary as Lisp values: copies, as
;;; specialized Lisp vectors for packed arrays of numbers (with no conversion of
;;; each element), simple vectors for the other arrays, and hash tables for
;;; dictionaries. Their value types are added here, since converting them
;;; needs Godot's builtin methods, such as size and resize, looked up with
;;; hashes from extension_api.json.
;;;

(defmacro builtin-method (class-name method-name)
  "The builtin method METHOD-NAME of the builtin class CLASS-NAME (literal
strings, such as \"PackedByteArray\" and \"size\"), looked up once, with its hash
from extension_api.json."
  `(initialize-cell-value
    (with-string-name (name ,method-name)
      (variant-get-ptr-builtin-method ,(api-variant-type class-name) name
                                      ,(api-builtin-method-hash class-name method-name)))))

(defmacro builtin-size (class-name pointer)
  "The size of the value of the builtin class CLASS-NAME at POINTER, such as a
packed array."
  `(with-foreign-memory ((size :int64-t))
     (call-ptr-builtin-method (builtin-method ,class-name "size") ,pointer
                              (load-time-value (ffi:make-null-pointer :void)) size 0)
     (foreign-ref size :int64-t)))

(defmacro builtin-resize (class-name pointer size)
  "Resize the value of the builtin class CLASS-NAME at POINTER, such as a packed
array, to SIZE elements."
  `(with-foreign-memory ((new-size :int64-t)
                         (args '(:array :pointer-void 1))
                         (error :int64-t))
     (setf (foreign-ref new-size :int64-t) ,size
           (foreign-ref args :pointer-void 0) new-size)
     (call-ptr-builtin-method (builtin-method ,class-name "resize") ,pointer args error 1)))

(defmacro construct-empty (variant-type pointer)
  "Construct an empty value of VARIANT-TYPE at POINTER, uninitialized memory,
with its constructor 0."
  `(call-ptr-constructor (initialize-cell-value (variant-get-ptr-constructor ,variant-type 0))
                         ,pointer (load-time-value (ffi:make-null-pointer :void))))

(defun copy-memory (to from bytes)
  "Copy BYTES bytes from the pointer FROM to the pointer TO."
  (ffi:c-inline (to from bytes) (:pointer-void :pointer-void :unsigned-long) :void
                "__builtin_memcpy(#0, #1, #2)" :one-liner t))

;;;
;;; Packed arrays of numbers: specialized Lisp vectors, copied as they are
;;;

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun element-type-size (element-type)
    "The size in bytes of an element of a specialized vector of ELEMENT-TYPE, as
the packed array of the same element type stores it."
    (cond ((and (consp element-type)
                (member (first element-type) '(signed-byte unsigned-byte)))
           (/ (second element-type) 8))
          ((eq element-type 'single-float) 4)
          ((eq element-type 'double-float) 8)
          (t (error "No size for the element type ~s" element-type)))))

(defmacro define-packed-number-array (class-name variant-type element-type
                                      operator-index destructor &optional (convert 'identity))
  "Add the value type of the packed array CLASS-NAME of numbers: a specialized
Lisp vector of ELEMENT-TYPE, whose data is copied as it is; OPERATOR-INDEX
gives the pointer to an element. CONVERT, a function name, converts the
elements of other sequences given as one."
  (let* ((element-size (element-type-size element-type))
         (lisp-name (lisp-style-class-name class-name))
         (reader (intern (format nil "READ-~a" lisp-name)))
         (writer (intern (format nil "WRITE-~a" lisp-name)))
         (vector-type `(simple-array ,element-type (*))))
    `(progn
       (defun ,reader (pointer)
         ,(format nil "The ~a at POINTER as a ~s." class-name vector-type)
         (let* ((size (builtin-size ,class-name pointer))
                (vector (make-array size :element-type ',element-type)))
           (when (plusp size)
             (copy-memory (si:make-foreign-data-from-array vector) (,operator-index pointer 0)
                          (* size ,element-size)))
           vector))
       (defun ,writer (pointer value)
         ,(format nil "Construct a ~a at POINTER, uninitialized memory, from the sequence
VALUE, best a ~s, which is copied as it is." class-name vector-type)
         (let ((vector (if (typep value ',vector-type)
                           value
                           (map ',vector-type #',convert value))))
           (construct-empty ,variant-type pointer)
           (when (plusp (length vector))
             (builtin-resize ,class-name pointer (length vector))
             (copy-memory (,operator-index pointer 0) (si:make-foreign-data-from-array vector)
                          (* (length vector) ,element-size)))))
       (add-value-type (make-value-type :variant-type ,variant-type
                                        :ffi-type 'packed-array
                                        :reader ',reader
                                        :writer ',writer
                                        :destructor ',destructor)))))

(defun to-single-float (x) (float x 1.0))
(defun to-double-float (x) (float x 1d0))

(define-packed-number-array "PackedByteArray" +variant-type-packed-byte-array+
  (unsigned-byte 8) packed-byte-array-operator-index packed-byte-array-destructor)
(define-packed-number-array "PackedInt32Array" +variant-type-packed-int32-array+
  (signed-byte 32) packed-int32-array-operator-index packed-int32-array-destructor)
(define-packed-number-array "PackedInt64Array" +variant-type-packed-int64-array+
  (signed-byte 64) packed-int64-array-operator-index packed-int64-array-destructor)
(define-packed-number-array "PackedFloat32Array" +variant-type-packed-float32-array+
  single-float packed-float32-array-operator-index packed-float32-array-destructor
  to-single-float)
(define-packed-number-array "PackedFloat64Array" +variant-type-packed-float64-array+
  double-float packed-float64-array-operator-index packed-float64-array-destructor
  to-double-float)

;;;
;;; Packed arrays of other types: simple vectors, converted element by element
;;;

(defmacro define-packed-element-array (class-name variant-type element-variant-type
                                       element-mirror operator-index destructor
                                       &key destroy-before-write)
  "Add the value type of the packed array CLASS-NAME of ELEMENT-VARIANT-TYPE: a
simple vector, whose elements are read and written with that type's reader and
writer, at ELEMENT-MIRROR's size apart. OPERATOR-INDEX gives the pointer to an
element. DESTROY-BEFORE-WRITE is the destructor of elements that are
constructed, such as Strings, which a resize constructs empty."
  (let* ((lisp-name (lisp-style-class-name class-name))
         (reader (intern (format nil "READ-~a" lisp-name)))
         (writer (intern (format nil "WRITE-~a" lisp-name)))
         (element-type (find-value-type (eval element-variant-type))))
    `(progn
       (defun ,reader (pointer)
         ,(format nil "The ~a at POINTER as a simple vector." class-name)
         (let* ((size (builtin-size ,class-name pointer))
                (vector (make-array size)))
           (when (plusp size)
             (let ((base (,operator-index pointer 0)))
               (dotimes (i size)
                 (setf (svref vector i)
                       (,(value-type-reader element-type)
                        (array-element base ',element-mirror i))))))
           vector))
       (defun ,writer (pointer value)
         ,(format nil "Construct a ~a at POINTER, uninitialized memory, from the
sequence VALUE." class-name)
         (let ((vector (coerce value 'simple-vector)))
           (construct-empty ,variant-type pointer)
           (when (plusp (length vector))
             (builtin-resize ,class-name pointer (length vector))
             (let ((base (,operator-index pointer 0)))
               (dotimes (i (length vector))
                 (let ((element (array-element base ',element-mirror i)))
                   ,@(when destroy-before-write
                       `((,destroy-before-write element)))
                   (,(value-type-writer element-type) element (svref vector i))))))))
       (add-value-type (make-value-type :variant-type ,variant-type
                                        :ffi-type 'packed-array
                                        :reader ',reader
                                        :writer ',writer
                                        :destructor ',destructor)))))

(define-packed-element-array "PackedVector2Array" +variant-type-packed-vector2-array+
  +variant-type-vector2+ godot-vector2
  packed-vector2-array-operator-index packed-vector2-array-destructor)
(define-packed-element-array "PackedVector3Array" +variant-type-packed-vector3-array+
  +variant-type-vector3+ godot-vector3
  packed-vector3-array-operator-index packed-vector3-array-destructor)
(define-packed-element-array "PackedVector4Array" +variant-type-packed-vector4-array+
  +variant-type-vector4+ godot-vector4
  packed-vector4-array-operator-index packed-vector4-array-destructor)
(define-packed-element-array "PackedColorArray" +variant-type-packed-color-array+
  +variant-type-color+ godot-color
  packed-color-array-operator-index packed-color-array-destructor)
(define-packed-element-array "PackedStringArray" +variant-type-packed-string-array+
  +variant-type-string+ godot-string
  packed-string-array-operator-index packed-string-array-destructor
  :destroy-before-write string-destructor)

;;;
;;; Array (also typed arrays) and Dictionary: a simple vector and a hash table,
;;; each element converted as a Variant
;;;

(defun read-array (pointer)
  "The Array at POINTER as a simple vector."
  (let* ((size (builtin-size "Array" pointer))
         (vector (make-array size)))
    (dotimes (i size)
      (setf (svref vector i) (read-variant (array-operator-index pointer i))))
    vector))

(defun write-array (pointer value)
  "Construct an Array at POINTER, uninitialized memory, from the sequence VALUE."
  (let ((vector (coerce value 'simple-vector)))
    (construct-empty +variant-type-array+ pointer)
    (when (plusp (length vector))
      (builtin-resize "Array" pointer (length vector))
      (dotimes (i (length vector))
        (let ((variant (array-operator-index pointer i)))
          ;; Nil after the resize
          (variant-destroy variant)
          (write-variant variant (svref vector i)))))))

(add-value-type (make-value-type :variant-type +variant-type-array+
                                 :ffi-type 'godot-array
                                 :reader 'read-array
                                 :writer 'write-array
                                 :destructor 'array-destructor))

(defun read-dictionary (pointer)
  "The Dictionary at POINTER as an EQUAL hash table."
  (let ((table (make-hash-table :test #'equal)))
    (with-foreign-memory ((keys 'godot-array))
      ;; Godot assigns the result, so it must be empty
      (clear-foreign-object keys 'godot-array)
      (call-ptr-builtin-method (builtin-method "Dictionary" "keys") pointer
                               (load-time-value (ffi:make-null-pointer :void)) keys 0)
      (unwind-protect
           (dotimes (i (builtin-size "Array" keys))
             (let ((key (array-operator-index keys i)))
               (setf (gethash (read-variant key) table)
                     (read-variant (dictionary-operator-index pointer key)))))
        (array-destructor keys)))
    table))

(defun write-dictionary (pointer value)
  "Construct a Dictionary at POINTER, uninitialized memory, from the hash table
VALUE."
  (construct-empty +variant-type-dictionary+ pointer)
  (with-foreign-memory ((key 'variant))
    (maphash (lambda (lisp-key lisp-value)
               (write-variant key lisp-key)
               (unwind-protect
                    (let ((variant (dictionary-operator-index pointer key)))
                      ;; Nil, as the key was just added
                      (variant-destroy variant)
                      (write-variant variant lisp-value))
                 (variant-destroy key)))
             value)))

(add-value-type (make-value-type :variant-type +variant-type-dictionary+
                                 :ffi-type 'godot-dictionary
                                 :reader 'read-dictionary
                                 :writer 'write-dictionary
                                 :destructor 'dictionary-destructor))
