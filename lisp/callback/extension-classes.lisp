(in-package :gd-extension-callback)

;;;
;;; Classes, see GD-EXTENSION:REGISTER-CLASS
;;;
;;; All classes share the same two callbacks, CREATE-INSTANCE and
;;; FREE-INSTANCE. The class_userdata of a class is its handle in
;;; *EXTENSION-CLASSES* (see handle-tables.lisp).
;;;
;;; Each instance of an extension class has a Lisp object, made by the class's
;;; constructor. Godot only holds a pointer to the instance, so the Lisp objects
;;; are kept in *INSTANCES*, with their classes, which keeps them reachable for
;;; the GC, and the GDExtensionClassInstancePtr is the handle there.
;;; INSTANCE-OBJECT gives the Lisp object of an instance pointer, and
;;; LISP-OBJECT (instance-bindings.lisp) that of a Godot object pointer.
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
;;; Notifications, such as NOTIFICATION_PREDELETE, go through one more shared
;;; callback, NOTIFICATION, behind a filter in C (see Notifications below).
;;;

(defstruct extension-class
  ;; The class name, a string
  name
  ;; A StringName with the class name, kept for OBJECT-SET-INSTANCE
  string-name
  ;; A StringName with the name of the engine class its instances are made
  ;; from with CLASSDB-CONSTRUCT-OBJECT: the parent class, or for a class that
  ;; inherits from another extension class, that class's engine class, as Godot
  ;; can't construct an extension class as the base of another one
  engine-string-name
  ;; Called with the Godot object pointer; returns the instance's Lisp object
  constructor
  ;; Called with the instance's Lisp object when Godot frees it, or NIL
  destructor
  ;; Called with the instance's Lisp object, the notification and whether
  ;; it's sent in reverse order, for the notifications in NOTIFICATIONS, or NIL
  ;; (see Notifications below)
  (notification nil)
  ;; The notifications NOTIFICATION is called for: a list of integers, or T
  ;; for all
  (notifications '())
  ;; The virtual methods the class implements: a list of (StringName with the
  ;; name . method_userdata)
  (virtuals '()))

(define-handle-table *extension-classes*
  "The EXTENSION-CLASSes, by class_userdata.")

(defun add-extension-class (name string-name parent-string-name constructor destructor
                            notification notifications)
  "Add the class NAME (a string) to *EXTENSION-CLASSES* and return its
class_userdata. STRING-NAME and PARENT-STRING-NAME are StringNames with the
names of the class and its parent class, and must stay valid. For CONSTRUCTOR,
DESTRUCTOR, NOTIFICATION and NOTIFICATIONS, see GD-EXTENSION:REGISTER-CLASS."
  (prog1 (add-handle *extension-classes* (make-extension-class
                                          :name name
                                          :string-name string-name
                                          :engine-string-name (or (look-up-engine-string-name
                                                                   (read-string-name
                                                                    parent-string-name))
                                                                  parent-string-name)
                                          :constructor constructor
                                          :destructor destructor
                                          :notification notification
                                          :notifications (check-notifications notifications)))
    (when notification
      (update-notification-filter))))

(defun find-extension-class (name &optional (errorp t))
  "The EXTENSION-CLASS named NAME (a string). If there's none, signals an error,
or returns NIL if ERRORP is false."
  (or (find-handle-value *extension-classes*
                         (lambda (class) (string= name (extension-class-name class))))
      (and errorp (error "No extension class named ~s" name))))

(defun look-up-engine-string-name (name)
  "The ENGINE-STRING-NAME of the extension class NAME (a string), or NIL if
there's none of that name."
  (let ((class (find-extension-class name nil)))
    (and class (extension-class-engine-string-name class))))

(defun userdata-class (userdata)
  (handle-value *extension-classes* userdata))

(defun add-virtual (class-name string-name method-userdata)
  "Make the method identified by METHOD-USERDATA (see REGISTER-METHOD) the
virtual method of the class CLASS-NAME (a string) named by STRING-NAME, a
StringName that must stay valid."
  (let ((class (find-extension-class class-name)))
    (push (cons string-name method-userdata) (extension-class-virtuals class))))

(defun virtual-call-data (class-userdata name)
  "The method_userdata of the virtual method of the class identified by
CLASS-USERDATA named by the StringName NAME, or NULL if it doesn't implement it."
  (or (cdr (assoc name (extension-class-virtuals (userdata-class class-userdata))
                  :test #'string-name-equal))
      (ffi:make-null-pointer :void)))

(define-handle-table *instances*
  "The instances, by GDExtensionClassInstancePtr: a cons of the Lisp object and
the EXTENSION-CLASS, for NOTIFY-INSTANCE, as Godot doesn't give notifications
the class.")

;; Inline: bound methods (bound-methods.lisp) call them at every call
(declaim (inline instance-object address-instance-object))
(defun instance-object (instance)
  "The Lisp object of INSTANCE, a GDExtensionClassInstancePtr (as given to
bound methods)."
  (car (handle-value *instances* instance)))

(defun address-instance-object (address)
  "The Lisp object of the instance whose GDExtensionClassInstancePtr has the
address ADDRESS, an integer, as the callbacks of ptrcalls get it."
  (car (address-handle-value *instances* address)))

(defun create-class-instance (class-userdata)
  "Create a Godot object of the class identified by CLASS-USERDATA, with its Lisp
object, and return the object pointer."
  (let* ((class (userdata-class class-userdata))
         ;; An object of the engine class, which becomes an object of CLASS
         ;; through OBJECT-SET-INSTANCE
         (object (classdb-construct-object (extension-class-engine-string-name class)))
         (instance-set nil))
    ;; If the Lisp object can't be made, the Godot object is destroyed again,
    ;; as Godot only gets NULL
    (unwind-protect
         (let ((lisp-object (funcall (extension-class-constructor class) object)))
           (object-set-instance object (extension-class-string-name class)
                                (add-handle *instances* (cons lisp-object class)))
           (setf instance-set t)
           ;; So LISP-OBJECT finds it
           (object-set-instance-binding object *class-library* (add-handle *bindings* lisp-object)
                                        (binding-callbacks))
           object)
      (unless instance-set
        (object-destroy object)))))

(defun free-class-instance (class-userdata instance)
  (let ((destructor (extension-class-destructor (userdata-class class-userdata)))
        (object (car (remove-handle *instances* instance))))
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
;;;
;;; Notifications
;;;
;;; Godot sends an object its notifications (NOTIFICATION_PREDELETE, Node's
;;; NOTIFICATION_PARENTED, ...) through the notification_func of its class,
;;; which is the same callback, NOTIFICATION, for all classes that have a
;;; notification function (see GD-EXTENSION:REGISTER-CLASS). Godot sends some
;;; every frame, such as NOTIFICATION_PROCESS, and a call into Lisp costs 0.3 us
;;; or more, so Godot is given a C function in front of the callback,
;;; gdecl_notification, which passes on only the notifications that some class
;;; wants: the union of the classes' NOTIFICATIONS, a table of flags by
;;; notification, and one flag for those outside it (Godot's own notifications
;;; are below 4096, except the editor's, from 9001). Godot doesn't give the
;;; callback the class, so it finds the class in *INSTANCES*, and calls the
;;; class's notification function only for the notifications it wants.
;;;
;;; The table is written only when classes are registered or their
;;; notifications change, and read from any thread, without a lock: a byte is
;;; read or written whole.
;;;

(ffi:clines "
#define GDECL_NOTIFICATION_TABLE_SIZE 4096
/* Whether some class wants the notification, by notification, and for the
   notifications outside the table */
static unsigned char gdecl_notification_table[GDECL_NOTIFICATION_TABLE_SIZE];
static unsigned char gdecl_notification_other = 0;
/* The C function of the callback NOTIFICATION, set below */
static void (*gdecl_notification_callback)(void *, int, unsigned char);

static void gdecl_notification(void *instance, int what, unsigned char reversed)
{
    if ((unsigned int)what < GDECL_NOTIFICATION_TABLE_SIZE
        ? gdecl_notification_table[what]
        : gdecl_notification_other)
        gdecl_notification_callback(instance, what, reversed);
}")

(defun check-notifications (notifications)
  "NOTIFICATIONS, if it's a list of notifications or T, as the NOTIFICATIONS of
an EXTENSION-CLASS. Otherwise signals an error."
  (unless (or (eq notifications t)
              (and (listp notifications)
                   (every (lambda (what) (typep what '(signed-byte 32))) notifications)))
    (error "Notifications must be a list of integers, or T: ~s" notifications))
  notifications)

(defun update-notification-filter ()
  "Make gdecl_notification pass on the notifications that the classes want."
  (ffi:c-inline () () :void "
__builtin_memset(gdecl_notification_table, 0, GDECL_NOTIFICATION_TABLE_SIZE);
gdecl_notification_other = 0;")
  (do-handle-values (class *extension-classes*)
    (when (extension-class-notification class)
      (let ((notifications (extension-class-notifications class)))
        (if (eq notifications t)
            (ffi:c-inline () () :void "
__builtin_memset(gdecl_notification_table, 1, GDECL_NOTIFICATION_TABLE_SIZE);
gdecl_notification_other = 1;")
            (dolist (what notifications)
              (ffi:c-inline (what) (:int) :void "
if ((unsigned int)#0 < GDECL_NOTIFICATION_TABLE_SIZE)
    gdecl_notification_table[#0] = 1;
else
    gdecl_notification_other = 1;")))))))

(defun set-class-notifications (class-name notifications)
  "Make the notification function of the class CLASS-NAME (a string, see
GD-EXTENSION:REGISTER-CLASS) be called for NOTIFICATIONS, a list of
notifications, or T for all."
  (let ((class (find-extension-class class-name)))
    (unless (extension-class-notification class)
      (error "The class ~a has no notification function" class-name))
    (setf (extension-class-notifications class) (check-notifications notifications))
    (update-notification-filter)
    notifications))

(defun notify-instance (instance what reversed)
  "Call the notification function of the class of INSTANCE (a
GDExtensionClassInstancePtr) with its Lisp object, if the class wants the
notification WHAT."
  (let* ((entry (handle-value *instances* instance))
         (class (cdr entry))
         (notifications (extension-class-notifications class)))
    (when (or (eq notifications t) (member what notifications))
      (funcall (extension-class-notification class) (car entry) what reversed))))

;; void (*GDExtensionClassNotification2)(GDExtensionClassInstancePtr p_instance,
;;                                       int32_t p_what, GDExtensionBool p_reversed)
;;
;; Godot calls it through gdecl_notification (NOTIFICATION-FILTER-POINTER).
(define-callback notification :void
    ((instance :pointer-void) (what :int) (reversed :unsigned-byte))
  (with-callback-protection ((format nil "notification ~d" what))
    (notify-instance instance what (/= reversed 0))))

(ffi:c-inline ((callback-pointer 'notification)) (:pointer-void) :void
              "gdecl_notification_callback = (void (*)(void *, int, unsigned char))#0"
              :one-liner t)

(defun notification-filter-pointer ()
  "The address of gdecl_notification, the notification_func of classes with a
notification function."
  (ffi:c-inline () () :pointer-void "(void *)gdecl_notification" :one-liner t))
