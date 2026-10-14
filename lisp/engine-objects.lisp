(in-package :gd-extension)

;;;
;;; The Lisp types of engine objects
;;;
;;; DEFINE-ENGINE-CLASS defines a struct for the Lisp objects of the engine
;;; class's objects, which includes the struct of the nearest class it inherits
;;; from that's defined in Lisp, so the structs mirror Godot's inheritance:
;;; node-2d includes canvas-item, which includes node, ..., which includes
;;; godot-object. The first time Lisp gets an object (see
;;; GD-EXTENSION-CALLBACK:*WRAPPER-FUNCTION*), its Lisp object is made of the
;;; type of its class, or of the nearest class it inherits from that's defined
;;; in Lisp. An instance of a class defined with DEFINE-CLASS has the struct of
;;; its class, which includes that of the engine class it inherits from.
;;;

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defvar *engine-object-types* (make-hash-table :test #'equal)
    "The struct names of the engine classes defined with DEFINE-ENGINE-CLASS, by
class name. Also known when the code is compiled.")

  (defun engine-object-type (class-name)
    "The Lisp type for objects of the engine class CLASS-NAME (a string, or NIL):
the struct of the class or of the nearest class it inherits from that's defined
with DEFINE-ENGINE-CLASS, or GODOT-OBJECT. For code generation: the classes
the class inherits from are looked up in extension_api.json."
    (loop for name = class-name then (json-get class "inherits")
          for class = (and name (api-class name))
          while class
          do (let ((type (gethash name *engine-object-types*)))
               (when type
                 (return type)))
          finally (return 'godot-object))))

;; The constructors of the structs of DEFINE-ENGINE-CLASS, by class name
(defvar *engine-object-constructors* (make-hash-table :test #'equal))

;; The constructors found for classes, by the address of the class name's
;; StringName data, which is the same for the same name while the class is
;; registered, so the name needn't be converted to a Lisp string
(defvar *class-name-constructors* (make-hash-table))

(defun register-engine-object-type (class-name constructor)
  "Make CONSTRUCTOR, a function of :POINTER, make the Lisp objects of the
objects of the engine class CLASS-NAME, and of the classes that inherit from it
and aren't defined in Lisp."
  (setf (gethash class-name *engine-object-constructors*) constructor)
  ;; The constructors found for classes may have changed
  (clrhash *class-name-constructors*))

(defmacro define-engine-class-parents ()
  "Define *ENGINE-CLASS-PARENTS*, the class each engine class inherits from, by
class name, from extension_api.json when the code is compiled."
  `(defparameter *engine-class-parents*
     (let ((table (make-hash-table :test #'equal)))
       (loop for (class-name . parent) in ',(api-class-parents)
             do (setf (gethash class-name table) parent))
       table)))

(define-engine-class-parents)

(defun class-constructor (class-name)
  "The constructor of the Lisp objects of the objects of the class CLASS-NAME: of
the class, or of the nearest class it inherits from, that has one."
  (loop for name = class-name then (gethash name *engine-class-parents*)
        while name
        do (let ((constructor (gethash name *engine-object-constructors*)))
             (when constructor
               (return constructor)))
        finally (return #'make-godot-object)))

(defun string-name-string (string-name)
  "The StringName at STRING-NAME as a Lisp string."
  (with-foreign-memory ((string 'godot-string)
                        (args '(:array :pointer-void 1)))
    (setf (foreign-ref args :pointer-void 0) string-name)
    ;; Constructor 2 of String takes a StringName
    (call-ptr-constructor (initialize-cell-value
                           (variant-get-ptr-constructor +variant-type-string+ 2))
                          string args)
    (unwind-protect (read-godot-string string)
      (string-destructor string))))

(defun make-engine-object (object)
  "The Lisp object of the Godot object OBJECT (a pointer), of the type of its
class (see DEFINE-ENGINE-CLASS), for GD-EXTENSION-CALLBACK:*WRAPPER-FUNCTION*."
  (with-foreign-memory ((class-name 'string-name))
    (if (zerop (object-get-class-name object *class-library* class-name))
        (make-godot-object :pointer object)
        (unwind-protect
             (let* ((key (foreign-ref class-name :uint64-t))
                    (constructor (or (gethash key *class-name-constructors*)
                                     (setf (gethash key *class-name-constructors*)
                                           (class-constructor (string-name-string class-name))))))
               (funcall constructor :pointer object))
          (string-name-destructor class-name)))))

(setf *wrapper-function* 'make-engine-object)
