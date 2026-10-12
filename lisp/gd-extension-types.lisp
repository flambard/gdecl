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

(defun lisp-variant-type (value)
  "The variant type of the Variant that WRITE-VARIANT makes from VALUE, by its
Lisp type, or NIL if it can't make one."
  (typecase value
    ;; Before integers, as NIL is also a list
    (boolean +variant-type-bool+)
    (integer +variant-type-int+)
    (real +variant-type-float+)
    (string +variant-type-string+)
    (vector2 +variant-type-vector2+)
    (rect2 +variant-type-rect2+)
    ((or godot-object si:foreign-data) +variant-type-object+)
    (callable +variant-type-callable+)))

(defun variant-value-p (value)
  "True if WRITE-VARIANT can make a Variant from VALUE."
  (and (lisp-variant-type value) t))

(defun write-variant (variant value)
  "Construct a Variant at VARIANT, uninitialized memory, from the Lisp VALUE,
by its Lisp type: T or NIL is a bool, an integer an int, a real a float, a
string a String, a VECTOR2 a Vector2, a RECT2 a Rect2, a GODOT-OBJECT or a
pointer an Object, and a CALLABLE a Callable. Destroy it with VARIANT-DESTROY."
  (let* ((variant-type (or (lisp-variant-type value)
                           (error "Can't make a Variant from ~s" value)))
         (value-type (find-value-type variant-type)))
    ;; The raw value, from which the Variant is made with a copy
    (ffi:with-foreign-object (raw (value-type-ffi-type value-type))
      (funcall (value-type-writer value-type) raw value)
      (unwind-protect
           (call-variant-from-type-constructor
            (aref *variant-from-type-constructors* variant-type) variant raw)
        (let ((destructor (value-type-destructor value-type)))
          (when destructor
            (funcall destructor raw)))))))

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
                         :destructor 'variant-destroy))
  "How values of each supported type are converted between raw values and Lisp
values, see VALUE-TYPE.")

(defun find-value-type (variant-type)
  "The VALUE-TYPE of VARIANT-TYPE (or :VARIANT)."
  (or (find variant-type *value-types* :key #'value-type-variant-type)
      (error "Unsupported type: variant type ~s" variant-type)))

(defun add-value-type (value-type)
  "Add VALUE-TYPE to *VALUE-TYPES*, replacing one for the same variant type. For
types whose conversion needs a higher layer, such as Callable."
  (setf *value-types*
        (cons value-type (remove (value-type-variant-type value-type) *value-types*
                                 :key #'value-type-variant-type))))

(defun read-variant (variant)
  "The value of the Variant at VARIANT as a Lisp value, by its type: NIL for
Nil, otherwise as in *VALUE-TYPES*."
  (let ((variant-type (variant-get-type variant)))
    (if (= variant-type +variant-type-nil+)
        nil
        (let ((value-type (find-value-type variant-type)))
          (unless (and (value-type-ffi-type value-type) (value-type-reader value-type))
            (error "Unsupported type for a Variant: variant type ~s" variant-type))
          (ffi:with-foreign-object (raw (value-type-ffi-type value-type))
            (call-type-from-variant-constructor
             (aref *type-from-variant-constructors* variant-type) raw variant)
            (unwind-protect (funcall (value-type-reader value-type) raw)
              (let ((destructor (value-type-destructor value-type)))
                (when destructor
                  (funcall destructor raw)))))))))

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
