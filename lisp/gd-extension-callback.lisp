(in-package :gd-extension-callback)

;;;
;;; What runs when Godot calls into Lisp (C -> Lisp): the callbacks, and the
;;; tables and dispatchers behind them. Each callback is a C function made with
;;; FFI:DEFCALLBACK, whose address (FFI:CALLBACK 'NAME) the package GD-EXTENSION
;;; (gd-extension.lisp) gives to Godot when it registers methods and classes.
;;;
;;; A Lisp error must never unwind through Godot's C frames, so every callback
;;; body is wrapped in HANDLER-CASE.
;;;

;;;
;;; Errors
;;;

(defun report-error (where condition)
  "Report the Lisp error CONDITION that happened in WHERE (a string, e.g. the
name of a method) with Godot's print_error, so that it shows up like Godot's
own errors, also in the editor. Called from the callbacks' error handlers, so
it must not fail itself: if print_error can't be used, it prints to standard
output."
  (let ((description (or (ignore-errors (princ-to-string condition)) "(unprintable error)"))
        (where (or where "Lisp code")))
    (unless (and *print-error*
                 (ignore-errors (print-error description where "Lisp" 0) t))
      (format t "~&ERROR: ~a~%   at: ~a~%" description where))))

;;;
;;; Methods, see GD-EXTENSION:BIND-METHOD
;;;
;;; Godot calls a bound method through one of two callbacks: ptrcall_func with
;;; pointers to the raw values (the fast path), or call_func with Variants (the
;;; dynamic path). All methods share the same two callbacks, METHOD-PTRCALL and
;;; METHOD-CALL. The method_userdata of a method identifies a BOUND-METHOD,
;;; which says which Lisp function to call and how to convert its arguments and
;;; return value.
;;;
;;; A Lisp function can't be passed to C, so the BOUND-METHODs are kept in
;;; *BOUND-METHODS* and method_userdata is (1+ index), so that it's never NULL.
;;;
;;; The functions get the instance's Lisp object (see INSTANCE-OBJECT), like
;;; self in GDScript.
;;;

(defun method-value-type (variant-type)
  "The VALUE-TYPE of VARIANT-TYPE, if the dispatcher can convert it: a type with
a raw value that can also be a Variant."
  (let ((value-type (find-value-type variant-type)))
    (unless (and (integerp (value-type-variant-type value-type))
                 (value-type-ffi-type value-type)
                 (value-type-reader value-type))
      (error "Unsupported type for a bound method: variant type ~s" variant-type))
    value-type))

(defun read-value (pointer value-type)
  "The raw value of VALUE-TYPE at POINTER as a Lisp value."
  (funcall (value-type-reader value-type) pointer))

(defun write-value (pointer value-type value)
  "Store the Lisp VALUE as a raw value of VALUE-TYPE at POINTER."
  (funcall (value-type-writer value-type) pointer value))

(defun destroy-value (pointer value-type)
  "Destroy the raw value of VALUE-TYPE at POINTER, if it needs it (e.g. a
String)."
  (let ((destructor (value-type-destructor value-type)))
    (when destructor
      (funcall destructor pointer))))

(defstruct bound-method
  ;; For error messages, e.g. "Player.start"
  name
  function
  ;; VALUE-TYPEs; NIL as the return type means no return value
  return-type
  argument-types)

(defvar *bound-methods* (make-array 0 :adjustable t :fill-pointer t))

(defun register-method (function &key name (return-type +variant-type-nil+) argument-types)
  "Register FUNCTION as a method and return its method_userdata. FUNCTION is
called with the instance's Lisp object and one Lisp value per argument.
RETURN-TYPE and ARGUMENT-TYPES are variant types. NAME, e.g. \"Player.start\",
is used in error messages."
  (ffi:make-pointer (1+ (vector-push-extend
                         (make-bound-method :name name
                                            :function function
                                            :return-type (unless (= return-type +variant-type-nil+)
                                                           (method-value-type return-type))
                                            :argument-types (mapcar #'method-value-type
                                                                    argument-types))
                         *bound-methods*))
                    :void))

(defun userdata-method (userdata)
  (aref *bound-methods* (1- (ffi:pointer-address userdata))))

(defun set-call-error (r-error error &key (argument 0) (expected 0))
  (let ((r-error (cast-pointer r-error 'call-error)))
    (setf (ffi:get-slot-value r-error 'call-error 'error) error
          (ffi:get-slot-value r-error 'call-error 'argument) argument
          (ffi:get-slot-value r-error 'call-error 'expected) expected)))

(defun ptrcall-bound-method (method-userdata instance args r-ret)
  "Call the method identified by METHOD-USERDATA, with ARGS and R-RET as in
ptrcall_func: an array of pointers to the raw argument values, and a pointer to
where the raw return value goes."
  (let* ((method (userdata-method method-userdata))
         (return-type (bound-method-return-type method))
         (arguments (loop for type in (bound-method-argument-types method)
                          for i from 0
                          collect (read-value (foreign-ref args :pointer-void i) type)))
         (result (apply (bound-method-function method) (instance-object instance)
                        arguments)))
    (when return-type
      (write-value r-ret return-type result))))

(defun call-bound-method (method-userdata instance args argument-count r-return r-error)
  "Call the method identified by METHOD-USERDATA, with arguments and return
value as Variants, as in call_func."
  (let* ((method (userdata-method method-userdata))
         (return-type (bound-method-return-type method))
         (argument-types (bound-method-argument-types method))
         (expected-count (length argument-types)))
    (cond ((< argument-count expected-count)
           (set-call-error r-error +call-error-too-few-arguments+ :expected expected-count))
          ((> argument-count expected-count)
           (set-call-error r-error +call-error-too-many-arguments+ :expected expected-count))
          (t
           (let ((arguments '()))
             (loop for value-type in argument-types
                   for type = (value-type-variant-type value-type)
                   for i from 0
                   for variant = (foreign-ref args :pointer-void i)
                   for variant-type = (variant-get-type variant)
                   do (cond ((= variant-type type)
                             (ffi:with-foreign-object (value (value-type-ffi-type value-type))
                               (call-type-from-variant-constructor
                                (aref *type-from-variant-constructors* type) value variant)
                               (unwind-protect (push (read-value value value-type) arguments)
                                 (destroy-value value value-type))))
                            ;; null for an Object
                            ((and (= type +variant-type-object+)
                                  (= variant-type +variant-type-nil+))
                             (push (ffi:make-null-pointer :void) arguments))
                            (t
                             (set-call-error r-error +call-error-invalid-argument+
                                             :argument i :expected type)
                             (return-from call-bound-method))))
             (let ((result (apply (bound-method-function method) (instance-object instance)
                                  (nreverse arguments))))
               (when return-type
                 (ffi:with-foreign-object (value (value-type-ffi-type return-type))
                   (write-value value return-type result)
                   ;; The Variant gets a copy
                   (unwind-protect
                        (call-variant-from-type-constructor
                         (aref *variant-from-type-constructors* (value-type-variant-type return-type))
                         r-return value)
                     (destroy-value value return-type))))))))))

;; void (*GDExtensionClassMethodPtrCall)(void *method_userdata,
;;                                       GDExtensionClassInstancePtr p_instance,
;;                                       const GDExtensionConstTypePtr *p_args,
;;                                       GDExtensionTypePtr r_ret)
(ffi:defcallback method-ptrcall :void
    ((method-userdata :pointer-void) (instance :pointer-void)
     (args :pointer-void) (r-ret :pointer-void))
  (handler-case
      (ptrcall-bound-method method-userdata instance args r-ret)
    (error (e)
      (report-error (bound-method-name (userdata-method method-userdata)) e))))

;; void (*GDExtensionClassMethodCall)(void *method_userdata,
;;                                    GDExtensionClassInstancePtr p_instance,
;;                                    const GDExtensionConstVariantPtr *p_args,
;;                                    GDExtensionInt p_argument_count,
;;                                    GDExtensionVariantPtr r_return,
;;                                    GDExtensionCallError *r_error)
(ffi:defcallback method-call :void
    ((method-userdata :pointer-void) (instance :pointer-void)
     (args :pointer-void) (argument-count :int64-t)
     (r-return :pointer-void) (r-error :pointer-void))
  ;; There's no call error for a failing method, and Godot already initialized
  ;; R-ERROR to OK and R-RETURN to Nil, so after an error the method returns
  ;; null, like a GDScript method that fails
  (handler-case
      (call-bound-method method-userdata instance args argument-count r-return r-error)
    (error (e)
      (report-error (bound-method-name (userdata-method method-userdata)) e))))

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
;;; the Lisp object of an instance pointer, and LISP-OBJECT that of a Godot
;;; object pointer.
;;;
;;; Virtual methods, such as _ready and _process, go through two more shared
;;; callbacks. Godot asks GET-VIRTUAL-CALL-DATA once whether a class implements
;;; a virtual method, and calls it through CALL-VIRTUAL-WITH-DATA with what that
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
  (ffi:with-foreign-object (result :uint8-t)
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

;; The addresses of the Godot objects of the instances, by index like
;; *INSTANCES*, and their Lisp objects by address, for LISP-OBJECT
(defvar *instance-addresses* (make-array 0 :adjustable t :fill-pointer t))
(defvar *lisp-objects* (make-hash-table))

(defun add-instance (godot-object lisp-object)
  "Keep LISP-OBJECT, the Lisp object of GODOT-OBJECT, in *INSTANCES* and return
its GDExtensionClassInstancePtr."
  (let ((address (ffi:pointer-address godot-object))
        (index (if *free-instances*
                   (let ((index (pop *free-instances*)))
                     (setf (aref *instances* index) lisp-object)
                     index)
                   (vector-push-extend lisp-object *instances*))))
    (if (< index (length *instance-addresses*))
        (setf (aref *instance-addresses* index) address)
        (vector-push-extend address *instance-addresses*))
    (setf (gethash address *lisp-objects*) lisp-object)
    (ffi:make-pointer (1+ index) :void)))

(defun remove-instance (instance)
  "Forget the Lisp object of INSTANCE, and return it."
  (let* ((index (1- (ffi:pointer-address instance)))
         (lisp-object (aref *instances* index)))
    (remhash (aref *instance-addresses* index) *lisp-objects*)
    (setf (aref *instances* index) nil
          (aref *instance-addresses* index) nil)
    (push index *free-instances*)
    lisp-object))

(defun lisp-object (godot-object)
  "The Lisp object of GODOT-OBJECT, a Godot object pointer, if it's an instance
of an extension class registered with GD-EXTENSION:REGISTER-CLASS, else NIL."
  (values (gethash (ffi:pointer-address godot-object) *lisp-objects*)))

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
         (object (classdb-construct-object (extension-class-parent-string-name class))))
    (object-set-instance object (extension-class-string-name class)
                         (add-instance object (funcall (extension-class-constructor class) object)))
    object))

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
(ffi:defcallback create-instance :pointer-void
    ((class-userdata :pointer-void) (notify-postinitialize :unsigned-byte))
  (declare (ignore notify-postinitialize))
  (handler-case (create-class-instance class-userdata)
    (error (e)
      (report-error "create instance" e)
      (ffi:make-null-pointer :void))))

;; void (*GDExtensionClassFreeInstance)(void *p_class_userdata,
;;                                      GDExtensionClassInstancePtr p_instance)
(ffi:defcallback free-instance :void
    ((class-userdata :pointer-void) (instance :pointer-void))
  (handler-case (free-class-instance class-userdata instance)
    (error (e)
      (report-error "free instance" e))))

;; void *(*GDExtensionClassGetVirtualCallData2)(void *p_class_userdata,
;;                                              GDExtensionConstStringNamePtr p_name,
;;                                              uint32_t p_hash)
;;
;; P_HASH is the hash of the virtual method's signature, not used.
(ffi:defcallback get-virtual-call-data :pointer-void
    ((class-userdata :pointer-void) (name :pointer-void) (hash :unsigned-int))
  (declare (ignore hash))
  (handler-case (virtual-call-data class-userdata name)
    (error (e)
      (report-error "get virtual call data" e)
      (ffi:make-null-pointer :void))))

;; void (*GDExtensionClassCallVirtualWithData)(GDExtensionClassInstancePtr p_instance,
;;                                             GDExtensionConstStringNamePtr p_name,
;;                                             void *p_virtual_call_userdata,
;;                                             const GDExtensionConstTypePtr *p_args,
;;                                             GDExtensionTypePtr r_ret)
(ffi:defcallback call-virtual-with-data :void
    ((instance :pointer-void) (name :pointer-void) (virtual-call-userdata :pointer-void)
     (args :pointer-void) (r-ret :pointer-void))
  (declare (ignore name))
  (handler-case
      (ptrcall-bound-method virtual-call-userdata instance args r-ret)
    (error (e)
      (report-error (bound-method-name (userdata-method virtual-call-userdata)) e))))
