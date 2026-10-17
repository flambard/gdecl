(in-package :gd-extension)

;;;
;;; Making and freeing Godot objects, like ClassName.new() and free() in
;;; GDScript
;;;
;;; MAKE-OBJECT makes an object of any class that can be instantiated, an
;;; engine class or one the extension registered, and returns its Lisp object
;;; (see LISP-OBJECT). A RefCounted object comes with a reference, as an engine
;;; method's RefCounted result does (see references.lisp), so it goes into the
;;; autorelease pool during a call from Godot. FREE-OBJECT frees any other
;;; object. GODOT-CLOS's MAKE-INSTANCE is built on MAKE-OBJECT.
;;;

(define-engine-method class-db-class-exists ("ClassDB" "class_exists"))
(define-engine-method class-db-can-instantiate ("ClassDB" "can_instantiate"))
(define-engine-method ref-counted-init-ref ("RefCounted" "init_ref"))
(define-engine-method object-is-class ("Object" "is_class"))

;; What MAKE-OBJECT needs to know about a class, by class name: a cons of a
;; StringName with the name (see NEW-STRING-NAME) and whether the class is
;; RefCounted, looked up the first time, so that making objects, e.g. every
;; frame, doesn't make StringNames or ask ClassDB. Like SNAME values, it must not
;; be used after the framework's shutdown.
(defvar *object-classes* (make-hash-table :test #'equal))

(defun look-up-object-class (class-name)
  "The entry of *OBJECT-CLASSES* for CLASS-NAME, a string. Signals an error if
Godot can't make objects of that class."
  (or (gethash class-name *object-classes*)
      (progn
        (unless (and (class-db-class-exists class-name)
                     (class-db-can-instantiate class-name))
          (error "Godot can't make objects of the class ~s" class-name))
        (setf (gethash class-name *object-classes*)
              (cons (new-string-name class-name)
                    (inherits-class-p class-name "RefCounted"))))))

(defun make-object (class-name)
  "Make a Godot object of the class CLASS-NAME (a string), an engine class or one
registered by the extension, like ClassName.new() in GDScript, and return its
Lisp object.

A RefCounted object comes with a reference, as an engine method's result does:
during a call from Godot, the reference is in the autorelease pool and given
back when the call returns, so take one of your own to keep the object
\(SETF-REFERENCE); otherwise the caller gives it back (RELEASE-REFERENCE, or
WITH-REFERENCE). Other objects are freed with FREE-OBJECT, or with the scene
tree they're added to."
  (let* ((class (look-up-object-class class-name))
         (pointer (classdb-construct-object (car class))))
    (when (ffi:null-pointer-p pointer)
      (error "Godot couldn't make an object of the class ~s" class-name))
    (let ((object (lisp-object pointer)))
      (when (cdr class)
        (ref-counted-init-ref object)
        (autorelease-reference object))
      object)))

(defun free-object (object)
  "Free OBJECT (its Lisp object or a Godot object pointer) now, like free() in
GDScript. A node is removed from the scene tree, and its children are freed
with it. The Lisp object becomes invalid (see VALID-OBJECT-P). RefCounted
objects can't be freed: they're freed when their last reference is given back
\(RELEASE-REFERENCE)."
  (when (object-is-class object "RefCounted")
    (error "~a is RefCounted, so it can't be freed; give back its reference instead"
           object))
  (object-destroy (object-pointer object))
  nil)
