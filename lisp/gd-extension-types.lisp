(in-package :gd-extension-types)

;;;
;;; Lisp versions of Godot's builtin types, with READ- functions that make one
;;; from the raw value at a pointer, and WRITE- functions that store one there.
;;; Used by GD-EXTENSION-CALLBACK to convert the arguments of bound methods, and
;;; by GD-EXTENSION to call engine methods; GD-EXTENSION re-exports what
;;; applications use.
;;;

(defstruct (vector2 (:constructor vector2 (&optional (x 0.0) (y 0.0))))
  "Godot's Vector2. Make one with (VECTOR2 X Y), like Vector2(x, y)."
  (x 0.0 :type single-float)
  (y 0.0 :type single-float))

(defun read-vector2 (pointer)
  (vector2 (ffi:get-slot-value pointer 'godot-vector2 'x)
           (ffi:get-slot-value pointer 'godot-vector2 'y)))

(defun write-vector2 (pointer vector)
  (setf (ffi:get-slot-value pointer 'godot-vector2 'x) (vector2-x vector)
        (ffi:get-slot-value pointer 'godot-vector2 'y) (vector2-y vector)))

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
  (rect2 (read-vector2 (ffi:get-slot-pointer pointer 'godot-rect2 'position))
         (read-vector2 (ffi:get-slot-pointer pointer 'godot-rect2 'size))))

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
