(in-package :gd-extension-callback)

;;;
;;; Bindings
;;;
;;; Every Godot object that Lisp gets has one Lisp object, a GODOT-OBJECT, so
;;; the same object is always the same (EQ) Lisp object. It's found through
;;; Godot's instance bindings: object_get_instance_binding, with the class
;;; library as the token, gives the binding, a handle of *BINDINGS*, the table
;;; of the Lisp objects (see handle-tables.lisp). An instance of an extension
;;; class gets its binding when it's created (the Lisp object made by its
;;; class's constructor); any other object the first time Lisp gets it, from
;;; CREATE-BINDING. When Godot frees the object, it calls FREE-BINDING, which
;;; clears the Lisp object's pointer, so using it signals an error (see
;;; OBJECT-POINTER) instead of passing Godot a dangling pointer.
;;;

(define-handle-table *bindings*
  "The Lisp objects of Godot objects, by instance binding.")

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
    (add-handle *bindings* (funcall *wrapper-function* object))))

;; void (*GDExtensionInstanceBindingFreeCallback)(void *p_token, void *p_instance,
;;                                                void *p_binding)
(define-callback free-binding :void
    ((token :pointer-void) (object :pointer-void) (binding :pointer-void))
  (declare (ignore token object))
  (with-callback-protection ("free binding")
    (let ((lisp-object (remove-handle *bindings* binding)))
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

(defmacro instance-binding-address (object ffi-type)
  "The address of the binding of OBJECT, a Godot object pointer of FFI-TYPE
(:POINTER-VOID, or :UINT64-T for its address), from object_get_instance_binding,
called with C code that returns it as an integer, so no pointer object is made
for it; 0 if making the binding failed, which has been reported."
  `(ffi:c-inline (*object-get-instance-binding* ,object *class-library* (binding-callbacks))
                 (:pointer-void ,ffi-type :pointer-void :pointer-void) :unsigned-long
                 "(unsigned long)((void *(*)(void *, void *, const void *))#0)((void *)#1, #2, #3)"
                 :one-liner t))

(defun lisp-object (godot-object)
  "The Lisp object of GODOT-OBJECT, a Godot object pointer (or its Lisp object):
for an instance of an extension class, the one its class's constructor made
(see GD-EXTENSION:REGISTER-CLASS), otherwise a GODOT-OBJECT made the first time.
The same Godot object always has the same Lisp object."
  (let ((binding (instance-binding-address (object-pointer godot-object) :pointer-void)))
    (if (zerop binding)
        godot-object
        (address-handle-value *bindings* binding))))

(defun address-lisp-object (address)
  "The Lisp object of the Godot object pointer whose address is ADDRESS, an
integer, as C code returns it without a pointer object being made for it (see
LISP-OBJECT), or NIL if it's 0: the FROM-ADDRESS of the Object value type, for
Object results of engine methods and arguments of bound methods."
  (if (zerop address)
      nil
      (let ((binding (instance-binding-address address :uint64-t)))
        (if (zerop binding)
            (address-pointer address)
            (address-handle-value *bindings* binding)))))

(defun free-bindings ()
  "Free the bindings of the objects that still exist, so that Godot doesn't call
FREE-BINDING after Lisp is shut down, e.g. for engine singletons. The
framework's last step at shutdown (see lifecycle.lisp in GD-EXTENSION)."
  (let ((objects '()))
    (do-handle-values (lisp-object *bindings*)
      (when (and (godot-object-p lisp-object) (godot-object-pointer lisp-object))
        (push (godot-object-pointer lisp-object) objects)))
    (dolist (object objects)
      (object-free-instance-binding object *class-library*))))

(defun pointer-lisp-object (object)
  "The Lisp object of OBJECT, a Godot object pointer (see LISP-OBJECT), or NIL if
it's NULL."
  (and (not (ffi:null-pointer-p object))
       (lisp-object object)))

;; The Object value type. The raw value of an Object is the object pointer, and
;; its Lisp value the object's Lisp object (NIL for null): objects that Godot
;; gives Lisp, as results of engine methods and arguments of bound methods and
;; Callables, are read with LISP-OBJECT. Wherever an Object is passed to Godot,
;; OBJECT-POINTER takes a Lisp object or a raw pointer.
(define-simple-value-type +variant-type-object+ :pointer-void
  :reader read-lisp-object :writer write-lisp-object
  :variant-reader read-lisp-object-variant :variant-writer write-lisp-object-variant
  :to-raw (lambda (form) `(object-pointer ,form))
  :from-raw (lambda (form) `(pointer-lisp-object ,form))
  :from-address (lambda (form) `(address-lisp-object ,form))
  ;; Only null can be an Object's default value
  :default-parser (lambda (default value-type)
                    (declare (ignore value-type))
                    (and (string= default "null") (list nil))))
