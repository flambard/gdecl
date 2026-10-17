(in-package :gd-extension-types)

;;;
;;; The autorelease pool, and who owns the references to RefCounted results
;;;
;;; A RefCounted object that Lisp gets as the result of a call into Godot comes
;;; with a reference (like a Ref<T>). During a call from Godot into Lisp, those
;;; references go into the autorelease pool of that call, and are given back
;;; when it returns (see GD-EXTENSION-CALLBACK, which makes a pool for each
;;; callback), so Lisp code doesn't have to. To keep such an object, take a
;;; reference of its own (GD-EXTENSION:SETF-REFERENCE). Outside a call from
;;; Godot, e.g. at a REPL, there's no pool, and the caller owns the references.
;;;
;;; The copies of Godot Callables that Lisp gets (ENGINE-CALLABLEs) go into the
;;; pool too, and are destroyed when the call returns; GD-EXTENSION:KEEP-CALLABLE
;;; makes a copy that isn't in it.
;;;

(defvar *autorelease-pool* :none
  "The references to give back when the call from Godot that's running returns:
a list of (kind handle address), where KIND is :REFERENCE (HANDLE is a
RefCounted object with a reference), :VARIANT (HANDLE is a Variant, in memory
from MEM-ALLOC, that keeps the reference of an Object result) or :CALLABLE
(HANDLE is an ENGINE-CALLABLE), and ADDRESS is the object's or the Callable's
address. :NONE when there's no pool.")

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
                (mem-free handle))
      (:callable (destroy-engine-callable handle)))))

(defun release-autorelease-pool ()
  "Give back the references in the autorelease pool, the last first, and empty
it. If giving one back signals an error, the pool keeps the ones not given back
yet, so calling this again goes on with them."
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

(defun destroy-engine-callable (callable)
  "Destroy the copy of a Godot Callable that the ENGINE-CALLABLE CALLABLE has, and
free its memory. Using CALLABLE afterwards signals an error."
  (let ((pointer (engine-callable-pointer callable)))
    (when pointer
      (setf (engine-callable-pointer callable) nil)
      (callable-destructor pointer)
      (mem-free pointer))))

(defun autorelease-callable (callable)
  "Put the ENGINE-CALLABLE CALLABLE into the autorelease pool, if there's one, so
that its copy of the Godot Callable is destroyed when the call from Godot
returns. Returns CALLABLE."
  (when (autorelease-pool-p)
    (push (list :callable callable (ffi:pointer-address (engine-callable-pointer callable)))
          *autorelease-pool*))
  callable)

(defun release-engine-callable (callable)
  "Destroy the copy of a Godot Callable that the ENGINE-CALLABLE CALLABLE has now,
and take it out of the autorelease pool if it's there."
  (when (autorelease-pool-p)
    (setf *autorelease-pool* (delete callable *autorelease-pool* :key #'second :count 1)))
  (destroy-engine-callable callable))

(defun reference-for-caller (object)
  "Take a reference to OBJECT (a pointer or a GODOT-OBJECT, or NIL) if it's
RefCounted, for Godot, which calls a method with ptrcall and gets OBJECT as its
result: Godot puts the object pointer right into a Variant or a Ref<T> without
taking a reference, and gives one back later, as for the results of engine
methods. A Variant made from OBJECT and never destroyed keeps the reference, so
there's no need to ask Godot whether OBJECT is RefCounted."
  (when object
    (with-foreign-memory ((variant 'variant)
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
          (with-foreign-memory ((copy 'variant))
            (variant-new-copy copy variant))))
    value))
