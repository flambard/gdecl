(in-package :gd-extension-callback)

;;;
;;; Classes, see GD-EXTENSION:REGISTER-CLASS
;;;
;;; All classes share the same two callbacks, CREATE-INSTANCE and
;;; FREE-INSTANCE. The class_userdata of a class is (1+ index) into
;;; *EXTENSION-CLASSES*.
;;;
;;; Each instance of an extension class has a Lisp object, made by the class's
;;; constructor. Godot only holds a pointer to the instance, so the Lisp objects
;;; are kept in *INSTANCES*, which keeps them reachable for the GC, and the
;;; GDExtensionClassInstancePtr is (1+ index) into it. INSTANCE-OBJECT gives
;;; the Lisp object of an instance pointer, and LISP-OBJECT
;;; (instance-bindings.lisp) that of a Godot object pointer.
;;;
;;; Virtual methods, such as _ready and _process, go through two more shared
;;; callbacks. Godot asks GET-VIRTUAL-CALL-DATA once whether a class implements
;;; a virtual method, and calls it through CALL-VIRTUAL-WITH-DATA
;;; (bound-methods.lisp, next to the other dispatchers) with what that
;;; returned. A virtual method is a bound method (see REGISTER-METHOD) that Godot
;;; calls with raw values, as with ptrcall_func, so its call data is its
;;; method_userdata. For virtual methods the class doesn't implement, the call
;;; data is NULL, and Godot doesn't call into Lisp for them.
;;;

(defstruct extension-class
  ;; The class name, a string
  name
  ;; A StringName with the class name, kept for OBJECT-SET-INSTANCE
  string-name
  ;; A StringName with the name of the parent class, kept for
  ;; CLASSDB-CONSTRUCT-OBJECT
  parent-string-name
  ;; Called with the Godot object pointer; returns the instance's Lisp object
  constructor
  ;; Called with the instance's Lisp object when Godot frees it, or NIL
  destructor
  ;; The virtual methods the class implements: a list of (StringName with the
  ;; name . method_userdata)
  (virtuals '()))

(defvar *extension-classes* (make-array 0 :adjustable t :fill-pointer t))

(defun add-extension-class (name string-name parent-string-name constructor destructor)
  "Add the class NAME (a string) to *EXTENSION-CLASSES* and return its
class_userdata. STRING-NAME and PARENT-STRING-NAME are StringNames with the
names of the class and its parent class, and must stay valid. For CONSTRUCTOR
and DESTRUCTOR, see GD-EXTENSION:REGISTER-CLASS."
  (ffi:make-pointer (1+ (vector-push-extend (make-extension-class
                                             :name name
                                             :string-name string-name
                                             :parent-string-name parent-string-name
                                             :constructor constructor
                                             :destructor destructor)
                                            *extension-classes*))
                    :void))

(defun userdata-class (userdata)
  (aref *extension-classes* (1- (ffi:pointer-address userdata))))

(defun add-virtual (class-name string-name method-userdata)
  "Make the method identified by METHOD-USERDATA (see REGISTER-METHOD) the
virtual method of the class CLASS-NAME (a string) named by STRING-NAME, a
StringName that must stay valid."
  (let ((class (or (find class-name *extension-classes*
                         :key #'extension-class-name :test #'string=)
                   (error "No extension class named ~s" class-name))))
    (push (cons string-name method-userdata) (extension-class-virtuals class))))

(defun string-name-equal (a b)
  (with-foreign-memory ((result :uint8-t))
    (call-ptr-operator-evaluator *string-name-equal-evaluator* a b result)
    (/= (foreign-ref result :uint8-t) 0)))

(defun virtual-call-data (class-userdata name)
  "The method_userdata of the virtual method of the class identified by
CLASS-USERDATA named by the StringName NAME, or NULL if it doesn't implement it."
  (or (cdr (assoc name (extension-class-virtuals (userdata-class class-userdata))
                  :test #'string-name-equal))
      (ffi:make-null-pointer :void)))

;; The Lisp objects of the instances, and the indices of the free elements
(defvar *instances* (make-array 0 :adjustable t :fill-pointer t))
(defvar *free-instances* '())

(defun add-instance (lisp-object)
  "Keep LISP-OBJECT, the Lisp object of an instance, in *INSTANCES* and return its
GDExtensionClassInstancePtr."
  (let ((index (if *free-instances*
                   (let ((index (pop *free-instances*)))
                     (setf (aref *instances* index) lisp-object)
                     index)
                   (vector-push-extend lisp-object *instances*))))
    (ffi:make-pointer (1+ index) :void)))

(defun remove-instance (instance)
  "Forget the Lisp object of INSTANCE, and return it."
  (let* ((index (1- (ffi:pointer-address instance)))
         (lisp-object (aref *instances* index)))
    (setf (aref *instances* index) nil)
    (push index *free-instances*)
    lisp-object))

;; Inline: bound methods (bound-methods.lisp) call it at every call
(declaim (inline instance-object))
(defun instance-object (instance)
  "The Lisp object of INSTANCE, a GDExtensionClassInstancePtr (as given to
bound methods)."
  (aref *instances* (1- (ffi:pointer-address instance))))

(defun create-class-instance (class-userdata)
  "Create a Godot object of the class identified by CLASS-USERDATA, with its Lisp
object, and return the object pointer."
  (let* ((class (userdata-class class-userdata))
         ;; An object of the parent class, which becomes an object of CLASS
         ;; through OBJECT-SET-INSTANCE
         (object (classdb-construct-object (extension-class-parent-string-name class)))
         (instance-set nil))
    ;; If the Lisp object can't be made, the Godot object is destroyed again,
    ;; as Godot only gets NULL
    (unwind-protect
         (let ((lisp-object (funcall (extension-class-constructor class) object)))
           (object-set-instance object (extension-class-string-name class)
                                (add-instance lisp-object))
           (setf instance-set t)
           ;; So LISP-OBJECT finds it
           (object-set-instance-binding object *class-library* (add-binding lisp-object)
                                        (binding-callbacks))
           object)
      (unless instance-set
        (object-destroy object)))))

(defun free-class-instance (class-userdata instance)
  (let ((destructor (extension-class-destructor (userdata-class class-userdata)))
        (object (remove-instance instance)))
    (when destructor
      (funcall destructor object))))

;; GDExtensionObjectPtr (*GDExtensionClassCreateInstance2)(void *p_class_userdata,
;;                                                         GDExtensionBool p_notify_postinitialize)
;;
;; CLASSDB-CONSTRUCT-OBJECT always sends NOTIFICATION_POSTINITIALIZE, so
;; NOTIFY-POSTINITIALIZE isn't used.
(define-callback create-instance :pointer-void
    ((class-userdata :pointer-void) (notify-postinitialize :unsigned-byte))
  (declare (ignore notify-postinitialize))
  (with-callback-protection ("create instance" (ffi:make-null-pointer :void))
    (create-class-instance class-userdata)))

;; void (*GDExtensionClassFreeInstance)(void *p_class_userdata,
;;                                      GDExtensionClassInstancePtr p_instance)
(define-callback free-instance :void
    ((class-userdata :pointer-void) (instance :pointer-void))
  (with-callback-protection ("free instance")
    (free-class-instance class-userdata instance)))

;; void *(*GDExtensionClassGetVirtualCallData2)(void *p_class_userdata,
;;                                              GDExtensionConstStringNamePtr p_name,
;;                                              uint32_t p_hash)
;;
;; P_HASH is the hash of the virtual method's signature, not used.
(define-callback get-virtual-call-data :pointer-void
    ((class-userdata :pointer-void) (name :pointer-void) (hash :unsigned-int))
  (declare (ignore hash))
  (with-callback-protection ("get virtual call data" (ffi:make-null-pointer :void))
    (virtual-call-data class-userdata name)))
