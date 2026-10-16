(in-package :gd-extension)

;;;
;;; References
;;;
;;; An engine method that returns a RefCounted object, such as a Resource,
;;; returns it with a reference, like a Ref<T> in C++. During a call from Godot
;;; into Lisp, the reference goes into the autorelease pool, and is given back
;;; when the call returns (see GD-EXTENSION-TYPES:WITH-AUTORELEASE-POOL);
;;; WITH-REFERENCE gives it back earlier. To keep the object longer, e.g. in a
;;; slot, take a reference of its own with SETF-REFERENCE (or ADD-REFERENCE and
;;; RELEASE-REFERENCE). Outside a call from Godot, e.g. at a REPL, there's no
;;; pool, and the caller gives the reference back with RELEASE-REFERENCE or
;;; WITH-REFERENCE.
;;;

(define-engine-method ref-counted-reference ("RefCounted" "reference"))

(define-engine-method ref-counted-unreference ("RefCounted" "unreference"))

(defun add-reference (object)
  "Take a reference to the RefCounted OBJECT (a Godot object pointer, a
GODOT-OBJECT, or NIL), to keep it alive while Lisp holds on to it. Give it back
with RELEASE-REFERENCE. Returns OBJECT."
  (unless (ffi:null-pointer-p (object-pointer object))
    (ref-counted-reference object))
  object)

(defun release-reference (object)
  "Give back a reference to the RefCounted OBJECT (a Godot object pointer, a
GODOT-OBJECT, or NIL), and destroy the object if it was the last one, like the
destructor of Ref<T>."
  (let ((pointer (object-pointer object)))
    (unless (ffi:null-pointer-p pointer)
      (when (ref-counted-unreference pointer)
        (object-destroy pointer)))))

;; The autorelease pool gives back references with it
(setf *release-reference-function* 'release-reference)

(defmacro with-reference ((var form) &body body)
  "Evaluate BODY with VAR bound to the RefCounted object (its Lisp object)
returned by FORM, a call of an engine method, and give the reference back when
BODY exits, also on a non-local exit: from the autorelease pool, during a call
from Godot, so it's given back earlier than when the call returns, or else the
caller's."
  `(let ((,var ,form))
     (unwind-protect (progn ,@body)
       (unless (release-autoreleased ,var)
         (release-reference ,var)))))

(defmacro setf-reference (place value)
  "Set PLACE, where Lisp keeps a RefCounted object, to the RefCounted VALUE (or
NIL): take a reference to VALUE, and give back the one to the old value of
PLACE, like assigning a Ref<T>. Returns VALUE."
  (multiple-value-bind (vars vals stores setter getter) (get-setf-expansion place)
    (let ((new (gensym "NEW"))
          (old (gensym "OLD")))
      `(let* (,@(mapcar #'list vars vals)
              (,new (add-reference ,value))
              (,old ,getter)
              (,(first stores) ,new))
         ,setter
         ;; After taking the new reference, in case it's the same object
         (release-reference ,old)
         ,new))))
