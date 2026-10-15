;;;; The package GD-EXTENSION-BUILTINS: Lisp versions of Godot's builtin types,
;;;; such as Vector2 and Basis, with their functions named like Godot's methods,
;;;; <type>-<method> (VECTOR2-NORMALIZED). Plain Lisp, without calls into Godot.
;;;; Everything exported from here is for applications: the packages
;;;; GD-EXTENSION and GODOT re-export all of it (see packages.lisp).
;;;; GD-EXTENSION-TYPES converts them to and from raw values.

(in-package :gd-extension-builtins)

(defstruct (vector2 (:constructor %vector2 (x y)))
  "Godot's Vector2. Make one with (VECTOR2 X Y), like Vector2(x, y)."
  (x 0.0 :type single-float)
  (y 0.0 :type single-float))

;; The components are single-floats, like Godot's real_t, but the constructors
;; take any real, as Lisp code computes with doubles (such as delta) and
;; integers
(declaim (inline vector2))
(defun vector2 (&optional (x 0.0) (y 0.0))
  "Vector2(X, Y)"
  (%vector2 (float x 1.0) (float y 1.0)))

(defun vector2+ (a b)
  "A + B"
  (vector2 (+ (vector2-x a) (vector2-x b))
           (+ (vector2-y a) (vector2-y b))))

(defun vector2* (vector number)
  "VECTOR * NUMBER"
  (vector2 (* (vector2-x vector) number)
           (* (vector2-y vector) number)))

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
    (vector2 (- (* x cos) (* y sin))
             (+ (* x sin) (* y cos)))))

(defun vector2-clamp (vector min max)
  "VECTOR.clamp(MIN, MAX): each component of VECTOR clamped between those of MIN
and MAX."
  (vector2 (min (max (vector2-x vector) (vector2-x min)) (vector2-x max))
           (min (max (vector2-y vector) (vector2-y min)) (vector2-y max))))

(defstruct (rect2 (:constructor rect2 (&optional (position (vector2)) (size (vector2)))))
  "Godot's Rect2. Make one with (RECT2 POSITION SIZE), like Rect2(position, size)."
  (position (vector2) :type vector2)
  (size (vector2) :type vector2))

(defstruct (vector3 (:constructor %vector3 (x y z)))
  "Godot's Vector3. Make one with (VECTOR3 X Y Z), like Vector3(x, y, z)."
  (x 0.0 :type single-float)
  (y 0.0 :type single-float)
  (z 0.0 :type single-float))

(declaim (inline vector3))
(defun vector3 (&optional (x 0.0) (y 0.0) (z 0.0))
  "Vector3(X, Y, Z)"
  (%vector3 (float x 1.0) (float y 1.0) (float z 1.0)))

(defun vector3+ (a b)
  "A + B"
  (vector3 (+ (vector3-x a) (vector3-x b))
           (+ (vector3-y a) (vector3-y b))
           (+ (vector3-z a) (vector3-z b))))

(defun vector3- (a &optional b)
  "A - B, or -A without B"
  (if b
      (vector3 (- (vector3-x a) (vector3-x b))
               (- (vector3-y a) (vector3-y b))
               (- (vector3-z a) (vector3-z b)))
      (vector3 (- (vector3-x a)) (- (vector3-y a)) (- (vector3-z a)))))

(defun vector3* (vector number)
  "VECTOR * NUMBER"
  (vector3 (* (vector3-x vector) number)
           (* (vector3-y vector) number)
           (* (vector3-z vector) number)))

(defun vector3-length (vector)
  "Vector3.length()"
  (sqrt (vector3-dot vector vector)))

(defun vector3-normalized (vector)
  "Vector3.normalized(): VECTOR scaled to length 1, or (0, 0, 0) if it's (0, 0, 0)"
  (let ((length (vector3-length vector)))
    (if (zerop length)
        (vector3)
        (vector3 (/ (vector3-x vector) length)
                 (/ (vector3-y vector) length)
                 (/ (vector3-z vector) length)))))

(defun vector3-dot (a b)
  "Vector3.dot()"
  (+ (* (vector3-x a) (vector3-x b))
     (* (vector3-y a) (vector3-y b))
     (* (vector3-z a) (vector3-z b))))

(defun vector3-cross (a b)
  "Vector3.cross()"
  (vector3 (- (* (vector3-y a) (vector3-z b)) (* (vector3-z a) (vector3-y b)))
           (- (* (vector3-z a) (vector3-x b)) (* (vector3-x a) (vector3-z b)))
           (- (* (vector3-x a) (vector3-y b)) (* (vector3-y a) (vector3-x b)))))

(defun vector3-rotated (vector axis angle)
  "Vector3.rotated(): VECTOR rotated around AXIS, a normalized vector, by ANGLE
radians"
  ;; Rodrigues' rotation formula
  (let ((cos (cos angle))
        (sin (sin angle)))
    (vector3+ (vector3+ (vector3* vector cos)
                        (vector3* (vector3-cross axis vector) sin))
              (vector3* axis (* (vector3-dot axis vector) (- 1 cos))))))

(defun vector3-is-zero-approx (vector)
  "Vector3.is_zero_approx(): true if each component is within Godot's
CMP_EPSILON of 0"
  (and (< (abs (vector3-x vector)) 1e-5)
       (< (abs (vector3-y vector)) 1e-5)
       (< (abs (vector3-z vector)) 1e-5)))

(defstruct (basis (:constructor basis (&optional (x (vector3 1.0 0.0 0.0))
                                                 (y (vector3 0.0 1.0 0.0))
                                                 (z (vector3 0.0 0.0 1.0)))))
  "Godot's Basis. Make one with (BASIS X Y Z) from its columns, like Basis(x, y,
z); (BASIS) is the identity. X, Y and Z are its columns, as in GDScript, though
Godot stores a Basis as its rows."
  (x (vector3 1.0 0.0 0.0) :type vector3)
  (y (vector3 0.0 1.0 0.0) :type vector3)
  (z (vector3 0.0 0.0 1.0) :type vector3))

(defun basis-looking-at (target &optional (up (vector3 0.0 1.0 0.0)) use-model-front)
  "Basis.looking_at(): the Basis of something that faces TARGET, a direction,
with its -Z axis (or its +Z axis if USE-MODEL-FRONT), and whose up is as close
to UP as can be."
  (when (vector3-is-zero-approx target)
    (error "The target vector can't be zero."))
  (when (vector3-is-zero-approx up)
    (error "The up vector can't be zero."))
  (let* ((v-z (if use-model-front
                  (vector3-normalized target)
                  (vector3- (vector3-normalized target))))
         (v-x (vector3-cross up v-z)))
    (when (vector3-is-zero-approx v-x)
      ;; TARGET and UP are (almost) parallel: Godot warns and uses any vector
      ;; perpendicular to UP (Vector3.get_any_perpendicular())
      (setf v-x (vector3-cross up (if (and (<= (abs (vector3-x up)) (abs (vector3-y up)))
                                           (<= (abs (vector3-x up)) (abs (vector3-z up))))
                                      (vector3 1.0 0.0 0.0)
                                      (vector3 0.0 1.0 0.0)))))
    (setf v-x (vector3-normalized v-x))
    (basis v-x (vector3-cross v-z v-x) v-z)))

;;;
;;; More builtin types, with constructors and accessors so far. Float
;;; components are single-floats, like Godot's real_t, and the constructors
;;; take any real for them; int components are 32-bit integers.
;;;

(defstruct (color (:constructor %color (r g b a)))
  "Godot's Color. Make one with (COLOR R G B &OPTIONAL (A 1.0)), like Color(r, g, b, a)."
  (r 0.0 :type single-float)
  (g 0.0 :type single-float)
  (b 0.0 :type single-float)
  (a 1.0 :type single-float))

(declaim (inline color))
(defun color (r g b &optional (a 1.0))
  "Color(R, G, B, A)"
  (%color (float r 1.0) (float g 1.0) (float b 1.0) (float a 1.0)))

(defstruct (vector2i (:constructor vector2i (&optional (x 0) (y 0))))
  "Godot's Vector2i. Make one with (VECTOR2I X Y), like Vector2i(x, y)."
  (x 0 :type (signed-byte 32))
  (y 0 :type (signed-byte 32)))

(defstruct (vector3i (:constructor vector3i (&optional (x 0) (y 0) (z 0))))
  "Godot's Vector3i. Make one with (VECTOR3I X Y Z), like Vector3i(x, y, z)."
  (x 0 :type (signed-byte 32))
  (y 0 :type (signed-byte 32))
  (z 0 :type (signed-byte 32)))

(defstruct (vector4 (:constructor %vector4 (x y z w)))
  "Godot's Vector4. Make one with (VECTOR4 X Y Z W), like Vector4(x, y, z, w)."
  (x 0.0 :type single-float)
  (y 0.0 :type single-float)
  (z 0.0 :type single-float)
  (w 0.0 :type single-float))

(declaim (inline vector4))
(defun vector4 (&optional (x 0.0) (y 0.0) (z 0.0) (w 0.0))
  "Vector4(X, Y, Z, W)"
  (%vector4 (float x 1.0) (float y 1.0) (float z 1.0) (float w 1.0)))

(defstruct (vector4i (:constructor vector4i (&optional (x 0) (y 0) (z 0) (w 0))))
  "Godot's Vector4i. Make one with (VECTOR4I X Y Z W), like Vector4i(x, y, z, w)."
  (x 0 :type (signed-byte 32))
  (y 0 :type (signed-byte 32))
  (z 0 :type (signed-byte 32))
  (w 0 :type (signed-byte 32)))

(defstruct (rect2i (:constructor rect2i (&optional (position (vector2i)) (size (vector2i)))))
  "Godot's Rect2i. Make one with (RECT2I POSITION SIZE), like Rect2i(position, size)."
  (position (vector2i) :type vector2i)
  (size (vector2i) :type vector2i))

(defstruct (plane (:constructor %plane (normal d)))
  "Godot's Plane. Make one with (PLANE NORMAL D), like Plane(normal, d)."
  (normal (vector3) :type vector3)
  (d 0.0 :type single-float))

(declaim (inline plane))
(defun plane (&optional (normal (vector3)) (d 0.0))
  "Plane(NORMAL, D)"
  (%plane normal (float d 1.0)))

(defstruct (quaternion (:constructor %quaternion (x y z w)))
  "Godot's Quaternion. Make one with (QUATERNION X Y Z W), like Quaternion(x, y,
z, w); (QUATERNION) is the identity."
  (x 0.0 :type single-float)
  (y 0.0 :type single-float)
  (z 0.0 :type single-float)
  (w 1.0 :type single-float))

(declaim (inline quaternion))
(defun quaternion (&optional (x 0.0) (y 0.0) (z 0.0) (w 1.0))
  "Quaternion(X, Y, Z, W)"
  (%quaternion (float x 1.0) (float y 1.0) (float z 1.0) (float w 1.0)))

(defstruct (aabb (:constructor aabb (&optional (position (vector3)) (size (vector3)))))
  "Godot's AABB. Make one with (AABB POSITION SIZE), like AABB(position, size)."
  (position (vector3) :type vector3)
  (size (vector3) :type vector3))

(defstruct (transform2d (:constructor transform2d (&optional (x (vector2 1.0 0.0))
                                                             (y (vector2 0.0 1.0))
                                                             (origin (vector2)))))
  "Godot's Transform2D. Make one with (TRANSFORM2D X Y ORIGIN), like
Transform2D(x_axis, y_axis, origin); (TRANSFORM2D) is the identity."
  (x (vector2 1.0 0.0) :type vector2)
  (y (vector2 0.0 1.0) :type vector2)
  (origin (vector2) :type vector2))

(defstruct (transform3d (:constructor transform3d (&optional (basis (basis)) (origin (vector3)))))
  "Godot's Transform3D. Make one with (TRANSFORM3D BASIS ORIGIN), like
Transform3D(basis, origin); (TRANSFORM3D) is the identity."
  (basis (basis) :type basis)
  (origin (vector3) :type vector3))

(defstruct (projection (:constructor projection (&optional (x (vector4 1.0 0.0 0.0 0.0))
                                                           (y (vector4 0.0 1.0 0.0 0.0))
                                                           (z (vector4 0.0 0.0 1.0 0.0))
                                                           (w (vector4 0.0 0.0 0.0 1.0)))))
  "Godot's Projection. Make one with (PROJECTION X Y Z W) from its columns, like
Projection(x, y, z, w); (PROJECTION) is the identity."
  (x (vector4 1.0 0.0 0.0 0.0) :type vector4)
  (y (vector4 0.0 1.0 0.0 0.0) :type vector4)
  (z (vector4 0.0 0.0 1.0 0.0) :type vector4)
  (w (vector4 0.0 0.0 0.0 1.0) :type vector4))

(defstruct (rid (:constructor rid (&optional (id 0))))
  "Godot's RID, an opaque ID of a resource of a server, such as the canvas item
of a node. (RID) is an invalid RID, like RID() in GDScript."
  (id 0 :type (unsigned-byte 64)))
