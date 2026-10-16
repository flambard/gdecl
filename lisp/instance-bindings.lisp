(in-package :gd-extension-callback)

;;;
;;; Bindings
;;;
;;; Every Godot object that Lisp gets has one Lisp object, a GODOT-OBJECT, so
;;; the same object is always the same (EQ) Lisp object. It's found through
;;; Godot's instance bindings: object_get_instance_binding, with the class
;;; library as the token, gives the binding, which is (1+ index) into
;;; *BINDINGS*, the table of the Lisp objects. An instance of an extension
;;; class gets its binding when it's created (the Lisp object made by its
;;; class's constructor); any other object the first time Lisp gets it, from
;;; CREATE-BINDING. When Godot frees the object, it calls FREE-BINDING, which
;;; clears the Lisp object's pointer, so using it signals an error (see
;;; OBJECT-POINTER) instead of passing Godot a dangling pointer.
;;;

(defvar *bindings* (make-array 0 :adjustable t :fill-pointer t))
(defvar *free-bindings* '())

(defun add-binding (lisp-object)
  "Keep LISP-OBJECT in *BINDINGS* and return the binding for it."
  (let ((index (if *free-bindings*
                   (let ((index (pop *free-bindings*)))
                     (setf (aref *bindings* index) lisp-object)
                     index)
                   (vector-push-extend lisp-object *bindings*))))
    (ffi:make-pointer (1+ index) :void)))

(defun binding-object (binding)
  "The Lisp object of BINDING."
  (aref *bindings* (1- (ffi:pointer-address binding))))

(defun remove-binding (binding)
  "Forget the Lisp object of BINDING, and return it."
  (let* ((index (1- (ffi:pointer-address binding)))
         (lisp-object (aref *bindings* index)))
    (setf (aref *bindings* index) nil)
    (push index *free-bindings*)
    lisp-object))

(defvar *wrapper-function* (lambda (object) (make-godot-object :pointer object))
  "The function that makes the Lisp object of a Godot object (a pointer) that
isn't an instance of an extension class, the first time Lisp gets it: a
GODOT-OBJECT, or a struct that includes it. GD-EXTENSION sets it to make one of
the type of the object's class (see GD-EXTENSION:DEFINE-ENGINE-CLASS).")

;; void *(*GDExtensionInstanceBindingCreateCallback)(void *p_token, void *p_instance)
(define-callback create-binding :pointer-void
    ((token :pointer-void) (object :pointer-void))
  (declare (ignore token))
  (with-callback-protection ("create binding" (ffi:make-null-pointer :void))
    (add-binding (funcall *wrapper-function* object))))

;; void (*GDExtensionInstanceBindingFreeCallback)(void *p_token, void *p_instance,
;;                                                void *p_binding)
(define-callback free-binding :void
    ((token :pointer-void) (object :pointer-void) (binding :pointer-void))
  (declare (ignore token object))
  (with-callback-protection ("free binding")
    (let ((lisp-object (remove-binding binding)))
      ;; Freed: using it is an error from now on
      (when (godot-object-p lisp-object)
        (setf (godot-object-pointer lisp-object) nil)))))

;; GDExtensionBool (*GDExtensionInstanceBindingReferenceCallback)(void *p_token,
;;                                                                void *p_binding,
;;                                                                GDExtensionBool p_reference)
;;
;; Called when the reference count of a RefCounted object changes, from any
;; thread; for tying the object's lifetime to its Lisp object, which gdecl
;; doesn't do (yet). Until then it's plain C, so it doesn't enter Lisp at every
;; change, and always lets the object go (returns true).
(ffi:clines "
static unsigned char gdecl_reference_binding(void *token, void *binding, unsigned char reference)
{
    return 1;
}")

(defun binding-callbacks ()
  "The GDExtensionInstanceBindingCallbacks of gdecl's bindings, made once."
  (car (load-time-value
        (make-initialize-cell
         (lambda ()
           ;; Kept until Godot unloads the extension
           (let ((callbacks (mem-alloc (ffi:size-of-foreign-type 'instance-binding-callbacks))))
             ;; create_callback, free_callback and reference_callback
             (setf (foreign-ref callbacks :pointer-void 0) (callback-pointer 'create-binding)
                   (foreign-ref callbacks :pointer-void 1) (callback-pointer 'free-binding)
                   (foreign-ref callbacks :pointer-void 2)
                   (ffi:c-inline () () :pointer-void "(void *)gdecl_reference_binding"
                                 :one-liner t))
             callbacks))))))

(defun lisp-object (godot-object)
  "The Lisp object of GODOT-OBJECT, a Godot object pointer (or its Lisp object):
for an instance of an extension class, the one its class's constructor made
(see GD-EXTENSION:REGISTER-CLASS), otherwise a GODOT-OBJECT made the first time.
The same Godot object always has the same Lisp object."
  ;; object_get_instance_binding, called with C code that returns the binding
  ;; as an integer, so no pointer object is made for it
  (let ((binding (ffi:c-inline (*object-get-instance-binding* (object-pointer godot-object)
                                *class-library* (binding-callbacks))
                               (:pointer-void :pointer-void :pointer-void :pointer-void)
                               :unsigned-long
                               "(unsigned long)((void *(*)(void *, void *, const void *))#0)(#1, #2, #3)"
                               :one-liner t)))
    (if (zerop binding)
        ;; Making the binding failed, which has been reported
        godot-object
        (aref *bindings* (1- binding)))))

(defun free-bindings ()
  "Free the bindings of the objects that still exist, so that Godot doesn't call
FREE-BINDING after Lisp is shut down, e.g. for engine singletons. A
deinitialize hook: it's added when this file is loaded, before the others, so
it runs last."
  (let ((objects (loop for lisp-object across *bindings*
                       when (and (godot-object-p lisp-object)
                                 (godot-object-pointer lisp-object))
                         collect (godot-object-pointer lisp-object))))
    (dolist (object objects)
      (object-free-instance-binding object *class-library*))))

(add-deinitialize-hook 'free-bindings)

(defun pointer-lisp-object (object)
  "The Lisp object of OBJECT, a Godot object pointer (see LISP-OBJECT), or NIL if
it's NULL."
  (and (not (ffi:null-pointer-p object))
       (lisp-object object)))

(defun read-lisp-object (pointer)
  "The Object at POINTER (as in READ-OBJECT) as a Lisp value: NIL for null,
otherwise its Lisp object (see LISP-OBJECT)."
  (pointer-lisp-object (read-object pointer)))

;; Objects that Godot gives Lisp (results of engine methods, arguments of
;; bound methods and Callables) are instances' Lisp objects where there are
;; any
(defun read-lisp-object-variant (variant)
  "The Object in the Variant at VARIANT as a Lisp value, as in READ-LISP-OBJECT."
  (pointer-lisp-object (raw-from-variant variant +variant-type-object+ :pointer-void "void *")))

(add-value-type (make-value-type :variant-type +variant-type-object+
                                 :ffi-type :pointer-void
                                 :reader 'read-lisp-object
                                 :writer 'write-object
                                 :variant-reader 'read-lisp-object-variant
                                 :variant-writer 'write-object-variant))
