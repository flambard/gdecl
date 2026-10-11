(in-package :gd-extension-types)

;;;
;;; Lisp versions of Godot's builtin types, with READ- functions that make one
;;; from the raw value at a pointer, and WRITE- functions that store one there.
;;; GD-EXTENSION re-exports what applications use.
;;;
;;; *VALUE-TYPES* says how to convert each type between raw values and Lisp
;;; values. It's used by GD-EXTENSION-CALLBACK for the arguments and results of
;;; bound methods, and by GD-EXTENSION for those of engine methods.
;;;

(defstruct (vector2 (:constructor vector2 (&optional (x 0.0) (y 0.0))))
  "Godot's Vector2. Make one with (VECTOR2 X Y), like Vector2(x, y)."
  (x 0.0 :type single-float)
  (y 0.0 :type single-float))

(defun read-vector2 (pointer)
  (let ((pointer (cast-pointer pointer 'godot-vector2)))
    (vector2 (ffi:get-slot-value pointer 'godot-vector2 'x)
             (ffi:get-slot-value pointer 'godot-vector2 'y))))

(defun write-vector2 (pointer vector)
  (let ((pointer (cast-pointer pointer 'godot-vector2)))
    (setf (ffi:get-slot-value pointer 'godot-vector2 'x) (vector2-x vector)
          (ffi:get-slot-value pointer 'godot-vector2 'y) (vector2-y vector))))

(defun vector2+ (a b)
  "A + B"
  (vector2 (+ (vector2-x a) (vector2-x b))
           (+ (vector2-y a) (vector2-y b))))

(defun vector2* (vector number)
  "VECTOR * NUMBER"
  (vector2 (float (* (vector2-x vector) number) 1.0)
           (float (* (vector2-y vector) number) 1.0)))

(defun vector2-length (vector)
  "VECTOR.length()"
  (sqrt (+ (* (vector2-x vector) (vector2-x vector))
           (* (vector2-y vector) (vector2-y vector)))))

(defun vector2-normalized (vector)
  "VECTOR.normalized(): VECTOR scaled to length 1, or (0, 0) if it has length 0."
  (let ((length (vector2-length vector)))
    (if (zerop length)
        (vector2)
        (vector2 (/ (vector2-x vector) length)
                 (/ (vector2-y vector) length)))))

(defun vector2-rotated (vector angle)
  "VECTOR.rotated(ANGLE): VECTOR rotated by ANGLE radians."
  (let ((cos (cos angle))
        (sin (sin angle))
        (x (vector2-x vector))
        (y (vector2-y vector)))
    (vector2 (float (- (* x cos) (* y sin)) 1.0)
             (float (+ (* x sin) (* y cos)) 1.0))))

(defun vector2-clamp (vector min max)
  "VECTOR.clamp(MIN, MAX): each component of VECTOR clamped between those of MIN
and MAX."
  (vector2 (min (max (vector2-x vector) (vector2-x min)) (vector2-x max))
           (min (max (vector2-y vector) (vector2-y min)) (vector2-y max))))

(defstruct (rect2 (:constructor rect2 (&optional (position (vector2)) (size (vector2)))))
  "Godot's Rect2. Make one with (RECT2 POSITION SIZE), like Rect2(position, size)."
  (position (vector2) :type vector2)
  (size (vector2) :type vector2))

(defun read-rect2 (pointer)
  (let ((pointer (cast-pointer pointer 'godot-rect2)))
    (rect2 (read-vector2 (ffi:get-slot-pointer pointer 'godot-rect2 'position))
           (read-vector2 (ffi:get-slot-pointer pointer 'godot-rect2 'size)))))

(defun write-rect2 (pointer rect)
  (let ((pointer (cast-pointer pointer 'godot-rect2)))
    (write-vector2 (ffi:get-slot-pointer pointer 'godot-rect2 'position) (rect2-position rect))
    (write-vector2 (ffi:get-slot-pointer pointer 'godot-rect2 'size) (rect2-size rect))))

(defun read-string (pointer)
  "The Godot String at POINTER as a Lisp string."
  (let* ((length (string-to-utf8-chars pointer (ffi:make-null-pointer :void) 0))
         (octets (make-array length :element-type '(unsigned-byte 8))))
    (string-to-utf8-chars pointer (si:make-foreign-data-from-array octets) length)
    (ext:octets-to-string octets :external-format :utf-8)))

(defun read-packed-string-array (pointer)
  "The PackedStringArray at POINTER as a list of Lisp strings."
  (let ((size (ffi:with-foreign-object (r-return :int64-t)
                (call-ptr-builtin-method *packed-string-array-size* pointer
                                         (ffi:make-null-pointer :void) r-return 0)
                (foreign-ref r-return :int64-t))))
    (loop for i below size
          collect (read-string (packed-string-array-operator-index pointer i)))))

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
(defun write-object (pointer value) (setf (foreign-ref pointer :pointer-void) value))

(defun write-variant (variant value)
  "Construct a Variant at VARIANT, uninitialized memory, from the Lisp VALUE,
by its Lisp type: T or NIL is a bool, an integer an int, a real a float and a
VECTOR2 a Vector2. Destroy it with VARIANT-DESTROY."
  (flet ((construct (variant-type raw)
           (call-variant-from-type-constructor
            (aref *variant-from-type-constructors* variant-type) variant raw)))
    (etypecase value
      (boolean
       (ffi:with-foreign-object (raw :uint8-t)
         (setf (foreign-ref raw :uint8-t) (if value 1 0))
         (construct +variant-type-bool+ raw)))
      (integer
       (ffi:with-foreign-object (raw :int64-t)
         (setf (foreign-ref raw :int64-t) value)
         (construct +variant-type-int+ raw)))
      (real
       (ffi:with-foreign-object (raw :double)
         (setf (foreign-ref raw :double) (float value 1d0))
         (construct +variant-type-float+ raw)))
      (vector2
       (ffi:with-foreign-object (raw 'godot-vector2)
         (write-vector2 raw value)
         (construct +variant-type-vector2+ raw))))))

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
  destructor)

(defparameter *value-types*
  (list (make-value-type :variant-type +variant-type-bool+ :ffi-type :uint8-t
                         :reader 'read-bool :writer 'write-bool)
        (make-value-type :variant-type +variant-type-int+ :ffi-type :int64-t
                         :reader 'read-int :writer 'write-int)
        (make-value-type :variant-type +variant-type-float+ :ffi-type :double
                         :reader 'read-float :writer 'write-float)
        (make-value-type :variant-type +variant-type-vector2+ :ffi-type 'godot-vector2
                         :reader 'read-vector2 :writer 'write-vector2)
        (make-value-type :variant-type +variant-type-rect2+ :ffi-type 'godot-rect2
                         :reader 'read-rect2 :writer 'write-rect2)
        (make-value-type :variant-type +variant-type-object+ :ffi-type :pointer-void
                         :reader 'read-object :writer 'write-object)
        (make-value-type :variant-type +variant-type-packed-string-array+
                         :ffi-type 'packed-string-array
                         :reader 'read-packed-string-array
                         :destructor 'packed-string-array-destructor)
        (make-value-type :variant-type +variant-type-string-name+)
        (make-value-type :variant-type +variant-type-node-path+)
        (make-value-type :variant-type :variant :ffi-type 'variant
                         :writer 'write-variant :destructor 'variant-destroy))
  "How values of each supported type are converted between raw values and Lisp
values, see VALUE-TYPE.")

(defun find-value-type (variant-type)
  "The VALUE-TYPE of VARIANT-TYPE (or :VARIANT)."
  (or (find variant-type *value-types* :key #'value-type-variant-type)
      (error "Unsupported type: variant type ~s" variant-type)))
