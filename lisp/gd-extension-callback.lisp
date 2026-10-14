(in-package :gd-extension-callback)

;;;
;;; What runs when Godot calls into Lisp (C -> Lisp): the callbacks, and the
;;; tables and dispatchers behind them. Each callback is a C function made with
;;; FFI:DEFCALLBACK, whose address (FFI:CALLBACK 'NAME) the package GD-EXTENSION
;;; (binding.lisp) gives to Godot when it registers methods and classes.
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

;; WITH-CALLBACK-PROTECTION catches errors with a handler made once: ECL's
;; HANDLER-BIND (and so HANDLER-CASE) conses a new handler cluster at every
;; entry, which is most of what a callback cost (measured with `make bench`).
;; It binds ECL's internal SI:*HANDLER-CLUSTERS* the way HANDLER-BIND does.

(defun throw-callback-error (condition)
  (throw 'callback-error condition))

(defmacro catching-errors (&body body)
  "Evaluate BODY and return NIL, or, if BODY signals an error, the condition,
after unwinding BODY. Like HANDLER-CASE, but cheaper."
  `(catch 'callback-error
     (let ((si:*handler-clusters*
             (cons (load-time-value (list (cons 'error #'throw-callback-error)))
                   si:*handler-clusters*)))
       ,@body
       nil)))

(defmacro with-callback-protection ((where &optional error-value) &body body)
  "Evaluate BODY, the work of a callback, with an autorelease pool of its own
(see GD-EXTENSION-TYPES:WITH-AUTORELEASE-POOL), and return its value. If BODY
signals an error, it's reported with REPORT-ERROR as happening in WHERE (a form
evaluated only then), and ERROR-VALUE is returned, as a Lisp error must never
unwind through Godot's C frames. The references in the pool are given back
afterwards, also after an error; no other non-local exit can leave a callback,
so this needs no UNWIND-PROTECT."
  (let ((result (gensym "RESULT"))
        (condition (gensym "CONDITION"))
        (release-condition (gensym "RELEASE-CONDITION")))
    `(let ((*autorelease-pool* '())
           (,result nil))
       (let ((,condition (catching-errors (setf ,result (progn ,@body)))))
         ;; Give back the references, also if giving back one of them fails
         (loop while (consp *autorelease-pool*)
               do (let ((,release-condition (catching-errors (release-autorelease-pool))))
                    (when ,release-condition
                      (report-error ,where ,release-condition))))
         (cond (,condition
                (report-error ,where ,condition)
                ,error-value)
               (t ,result))))))

;;;
;;; Initialization
;;;
;;; INITIALIZE and DEINITIALIZE are called from src/gdecl.c when Godot loads and
;;; unloads the extension: the entry points into Lisp, before there are any
;;; callbacks. Applications add hooks to them, re-exported by GD-EXTENSION.
;;;

;; Functions called at the end of INITIALIZE, see ADD-INITIALIZE-HOOK
(defvar *initialize-hooks* '())

(defun add-initialize-hook (function)
  "Call FUNCTION, a function designator taking no arguments, at the end of
INITIALIZE, once the framework is set up. Hooks run in the order they were
added; adding a hook again doesn't run it twice. This is how an application
registers its entry point: by calling ADD-INITIALIZE-HOOK when it's loaded."
  (setf *initialize-hooks*
        (append (remove function *initialize-hooks*) (list function))))

;; An initialize cell is a cons whose car is computed in INITIALIZE, for
;; things that must be looked up in Godot once, but can't be looked up at load
;; time (see GD-EXTENSION:SNAME).
(defvar *initialize-cells* '())

(defun make-initialize-cell (function)
  "A cons whose car will be the value of FUNCTION, called with no arguments in
INITIALIZE, or now if INITIALIZE has been called (e.g. at a REPL)."
  (let ((cell (cons nil nil)))
    (if *class-library*
        (setf (car cell) (funcall function))
        (push (cons cell function) *initialize-cells*))
    cell))

(defun initialize (get-proc-address class-library)
  "Set up the framework with the GDExtensionInterfaceGetProcAddress and
GDExtensionClassLibraryPtr that Godot gave the extension, fill in the
initialize cells made so far, then run the initialize hooks. Called from
src/gdecl.c."
  (load-interface get-proc-address class-library)
  (loop for (cell . function) in (reverse *initialize-cells*)
        do (handler-case (setf (car cell) (funcall function))
             (error (e)
               (report-error "initialize" e))))
  (setf *initialize-cells* '())
  (dolist (hook *initialize-hooks*)
    (handler-case (with-autorelease-pool (funcall hook))
      (error (e)
        (report-error (format nil "initialize hook ~a" hook) e))))
  t)

;; Functions called by DEINITIALIZE, see ADD-DEINITIALIZE-HOOK
(defvar *deinitialize-hooks* '())

(defun add-deinitialize-hook (function)
  "Call FUNCTION, a function designator taking no arguments, in DEINITIALIZE,
when Godot unloads the extension, while Godot can still be called. Hooks run in
the reverse order they were added, so that what was set up last is cleaned up
first; adding a hook again doesn't run it twice."
  (setf *deinitialize-hooks*
        (cons function (remove function *deinitialize-hooks*))))

(defun deinitialize ()
  "Clean up when Godot unloads the extension: run the deinitialize hooks.
Called from src/gdecl.c, before ECL is shut down."
  (dolist (hook *deinitialize-hooks*)
    (handler-case (with-autorelease-pool (funcall hook))
      (error (e)
        (report-error (format nil "deinitialize hook ~a" hook) e))))
  t)

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

(defun method-value-type (variant-type &optional (errorp t))
  "The VALUE-TYPE of VARIANT-TYPE, if the dispatcher can convert it: a type with
a raw value that can also be a Variant. Otherwise signals an error, or returns
NIL if ERRORP is false."
  (let ((value-type (find-value-type variant-type nil)))
    (cond ((and value-type
                (integerp (value-type-variant-type value-type))
                (value-type-ffi-type value-type)
                (value-type-reader value-type))
           value-type)
          (errorp
           (error "Unsupported type for a bound method: variant type ~s" variant-type)))))

(defstruct bound-method
  ;; For error messages, e.g. "Player.start"
  name
  function
  ;; VALUE-TYPEs; NIL as the return type means no return value
  return-type
  argument-types
  ;; A function that does what PTRCALL-BOUND-METHOD does, generated for the
  ;; method's signature (see PTRCALL-INVOKER-FORM), or NIL
  (invoker nil))

(defvar *bound-methods* (make-array 0 :adjustable t :fill-pointer t))

(defun register-method (function &key name (return-type +variant-type-nil+) argument-types
                                      invoker)
  "Register FUNCTION as a method and return its method_userdata. FUNCTION is
called with the instance's Lisp object and one Lisp value per argument.
RETURN-TYPE and ARGUMENT-TYPES are variant types. NAME, e.g. \"Player.start\",
is used in error messages. INVOKER, if given, is the function of
PTRCALL-INVOKER-FORM for the signature, which makes calls with ptrcall faster."
  (ffi:make-pointer (1+ (vector-push-extend
                         (make-bound-method :name name
                                            :function function
                                            :return-type (unless (= return-type +variant-type-nil+)
                                                           (method-value-type return-type))
                                            :argument-types (mapcar #'method-value-type
                                                                    argument-types)
                                            :invoker invoker)
                         *bound-methods*))
                    :void))

(defun userdata-method (userdata)
  (aref *bound-methods* (1- (ffi:pointer-address userdata))))

(defun set-call-error (r-error error &key (argument 0) (expected 0))
  ;; GDExtensionCallError's members are three 32-bit ints: error, argument and
  ;; expected
  (setf (foreign-ref r-error :int32-t 0) error
        (foreign-ref r-error :int32-t 1) argument
        (foreign-ref r-error :int32-t 2) expected))

(defun ptrcall-bound-method (method-userdata instance args r-ret)
  "Call the method identified by METHOD-USERDATA, with ARGS and R-RET as in
ptrcall_func: an array of pointers to the raw argument values, and a pointer to
where the raw return value goes."
  (let* ((method (userdata-method method-userdata))
         (invoker (bound-method-invoker method)))
    (if invoker
        (funcall invoker (bound-method-function method) (instance-object instance) args r-ret)
        (let* ((return-type (bound-method-return-type method))
               (arguments (loop for type in (bound-method-argument-types method)
                                for i from 0
                                collect (read-value (foreign-ref args :pointer-void i) type)))
               (result (apply (bound-method-function method) (instance-object instance)
                              arguments)))
          (when return-type
            ;; An Object result comes with a reference for Godot, if it's
            ;; RefCounted
            (when (eql (value-type-variant-type return-type) +variant-type-object+)
              (reference-for-caller result))
            (write-value r-ret return-type result))))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun invoker-argument-form (value-type args index)
    "A form that reads argument INDEX, of VALUE-TYPE, from ARGS, the array of
pointers to raw values of ptrcall_func. bool, int and float are read with C
code, without a pointer object in between."
    (let ((c-type (case (value-type-ffi-type value-type)
                    (:uint8-t "uint8_t")
                    (:int64-t "int64_t")
                    (:double "double"))))
      (if c-type
          (let ((form `(ffi:c-inline (,args) (:pointer-void) ,(value-type-ffi-type value-type)
                                     ,(format nil "*(~a *)((void **)#0)[~d]" c-type index)
                                     :one-liner t)))
            (if (eq (value-type-ffi-type value-type) :uint8-t)
                `(/= 0 ,form)
                form))
          `(,(value-type-reader value-type) (foreign-ref ,args :pointer-void ,index)))))

  (defun ptrcall-invoker-form (return-type argument-types)
    "A LAMBDA form for the invoker of a bound method with RETURN-TYPE and
ARGUMENT-TYPES (variant types, see REGISTER-METHOD): a function of the method's
function, the instance's Lisp object, and ARGS and R-RET of ptrcall_func, which
does what PTRCALL-BOUND-METHOD does, with the code for each type generated, so
without a list of the arguments, APPLY or calling converters by name. NIL if
the dispatcher can't convert one of the types."
    (let ((return-value-type (and (not (eql return-type +variant-type-nil+))
                                  (method-value-type return-type nil)))
          (argument-value-types (mapcar (lambda (type) (method-value-type type nil))
                                        argument-types))
          (function (gensym "FUNCTION"))
          (self (gensym "SELF"))
          (args (gensym "ARGS"))
          (r-ret (gensym "R-RET"))
          (result (gensym "RESULT")))
      (unless (or (and (not return-value-type) (not (eql return-type +variant-type-nil+)))
                  (member nil argument-value-types))
        `(lambda (,function ,self ,args ,r-ret)
           (declare (ignorable ,args ,r-ret))
           ,(let ((call `(funcall ,function ,self
                                  ,@(loop for value-type in argument-value-types
                                          for i from 0
                                          collect (invoker-argument-form value-type args i)))))
              (if return-value-type
                  `(let ((,result ,call))
                     ;; An Object result comes with a reference for Godot, if
                     ;; it's RefCounted
                     ,@(when (eql return-type +variant-type-object+)
                         `((reference-for-caller ,result)))
                     (,(value-type-writer return-value-type) ,r-ret ,result))
                  call)))))))

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
                             (push (read-variant-as variant value-type) arguments))
                            ;; null for an Object
                            ((and (= type +variant-type-object+)
                                  (= variant-type +variant-type-nil+))
                             (push nil arguments))
                            ;; A float for an int and an int for a float, as
                            ;; Godot converts them for its own methods (the
                            ;; float truncated, like int() in GDScript)
                            ((and (= type +variant-type-int+)
                                  (= variant-type +variant-type-float+))
                             (push (values (truncate (read-variant variant))) arguments))
                            ((and (= type +variant-type-float+)
                                  (= variant-type +variant-type-int+))
                             (push (float (read-variant variant) 1d0) arguments))
                            (t
                             (set-call-error r-error +call-error-invalid-argument+
                                             :argument i :expected type)
                             (return-from call-bound-method))))
             (let ((result (apply (bound-method-function method) (instance-object instance)
                                  (nreverse arguments))))
               (when return-type
                 (write-variant-as r-return return-type result))))))))

;; void (*GDExtensionClassMethodPtrCall)(void *method_userdata,
;;                                       GDExtensionClassInstancePtr p_instance,
;;                                       const GDExtensionConstTypePtr *p_args,
;;                                       GDExtensionTypePtr r_ret)
(ffi:defcallback method-ptrcall :void
    ((method-userdata :pointer-void) (instance :pointer-void)
     (args :pointer-void) (r-ret :pointer-void))
  (with-callback-protection ((bound-method-name (userdata-method method-userdata)))
    (ptrcall-bound-method method-userdata instance args r-ret)))

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
  (with-callback-protection ((bound-method-name (userdata-method method-userdata)))
    (call-bound-method method-userdata instance args argument-count r-return r-error)))

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

;; void *(*GDExtensionInstanceBindingCreateCallback)(void *p_token, void *p_instance)
(ffi:defcallback create-binding :pointer-void
    ((token :pointer-void) (object :pointer-void))
  (declare (ignore token))
  (with-callback-protection ("create binding" (ffi:make-null-pointer :void))
    (add-binding (make-godot-object :pointer object))))

;; void (*GDExtensionInstanceBindingFreeCallback)(void *p_token, void *p_instance,
;;                                                void *p_binding)
(ffi:defcallback free-binding :void
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
;; Called when the reference count of a RefCounted object changes; for tying
;; the object's lifetime to its Lisp object, which gdecl doesn't do (yet).
(ffi:defcallback reference-binding :unsigned-byte
    ((token :pointer-void) (binding :pointer-void) (reference :unsigned-byte))
  (declare (ignore token binding reference))
  1)

(defun binding-callbacks ()
  "The GDExtensionInstanceBindingCallbacks of gdecl's bindings, made once."
  (car (load-time-value
        (make-initialize-cell
         (lambda ()
           ;; Kept until Godot unloads the extension
           (let ((callbacks (mem-alloc (ffi:size-of-foreign-type 'instance-binding-callbacks))))
             ;; create_callback, free_callback and reference_callback
             (setf (foreign-ref callbacks :pointer-void 0) (ffi:callback 'create-binding)
                   (foreign-ref callbacks :pointer-void 1) (ffi:callback 'free-binding)
                   (foreign-ref callbacks :pointer-void 2) (ffi:callback 'reference-binding))
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

(defun read-lisp-object (pointer)
  "The Object at POINTER (as in READ-OBJECT) as a Lisp value: NIL for null, the
Lisp object of an instance of an extension class, else the Godot object
pointer."
  (let ((object (read-object pointer)))
    (and (not (ffi:null-pointer-p object))
         (or (lisp-object object) object))))

;; Objects that Godot gives Lisp (results of engine methods, arguments of
;; bound methods and Callables) are instances' Lisp objects where there are
;; any
(defun read-lisp-object-variant (variant)
  "The Object in the Variant at VARIANT as a Lisp value, as in READ-LISP-OBJECT."
  (let ((object (raw-from-variant variant +variant-type-object+ :pointer-void "void *")))
    (and (not (ffi:null-pointer-p object))
         (or (lisp-object object) object))))

(add-value-type (make-value-type :variant-type +variant-type-object+
                                 :ffi-type :pointer-void
                                 :reader 'read-lisp-object
                                 :writer 'write-object
                                 :variant-reader 'read-lisp-object-variant
                                 :variant-writer 'write-object-variant))

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
(ffi:defcallback create-instance :pointer-void
    ((class-userdata :pointer-void) (notify-postinitialize :unsigned-byte))
  (declare (ignore notify-postinitialize))
  (with-callback-protection ("create instance" (ffi:make-null-pointer :void))
    (create-class-instance class-userdata)))

;; void (*GDExtensionClassFreeInstance)(void *p_class_userdata,
;;                                      GDExtensionClassInstancePtr p_instance)
(ffi:defcallback free-instance :void
    ((class-userdata :pointer-void) (instance :pointer-void))
  (with-callback-protection ("free instance")
    (free-class-instance class-userdata instance)))

;; void *(*GDExtensionClassGetVirtualCallData2)(void *p_class_userdata,
;;                                              GDExtensionConstStringNamePtr p_name,
;;                                              uint32_t p_hash)
;;
;; P_HASH is the hash of the virtual method's signature, not used.
(ffi:defcallback get-virtual-call-data :pointer-void
    ((class-userdata :pointer-void) (name :pointer-void) (hash :unsigned-int))
  (declare (ignore hash))
  (with-callback-protection ("get virtual call data" (ffi:make-null-pointer :void))
    (virtual-call-data class-userdata name)))

;; void (*GDExtensionClassCallVirtualWithData)(GDExtensionClassInstancePtr p_instance,
;;                                             GDExtensionConstStringNamePtr p_name,
;;                                             void *p_virtual_call_userdata,
;;                                             const GDExtensionConstTypePtr *p_args,
;;                                             GDExtensionTypePtr r_ret)
(ffi:defcallback call-virtual-with-data :void
    ((instance :pointer-void) (name :pointer-void) (virtual-call-userdata :pointer-void)
     (args :pointer-void) (r-ret :pointer-void))
  (declare (ignore name))
  (with-callback-protection ((bound-method-name (userdata-method virtual-call-userdata)))
    (ptrcall-bound-method virtual-call-userdata instance args r-ret)))

;;;
;;; Callables, see GD-EXTENSION-TYPES:CALLABLE
;;;
;;; WRITE-CALLABLE makes a custom Godot Callable that calls a Lisp function. All
;;; custom Callables share the same two callbacks, CALLABLE-CALL and
;;; CALLABLE-FREE. Their callable_userdata is (1+ index) into *CALLABLES*, which
;;; keeps the functions; CALLABLE-FREE forgets the function when Godot frees the
;;; last copy of the Callable.
;;;

(defvar *callables* (make-array 0 :adjustable t :fill-pointer t))
(defvar *free-callables* '())

(defun add-callable-function (function)
  (let ((index (if *free-callables*
                   (let ((index (pop *free-callables*)))
                     (setf (aref *callables* index) function)
                     index)
                   (vector-push-extend function *callables*))))
    (ffi:make-pointer (1+ index) :void)))

(defun userdata-callable-function (userdata)
  (aref *callables* (1- (ffi:pointer-address userdata))))

(defun write-callable (pointer callable)
  "Construct a custom Godot Callable at POINTER, uninitialized memory, from the
Lisp CALLABLE. Destroy it with CALLABLE-DESTRUCTOR; Godot keeps the Lisp function
until the last copy of the Callable is destroyed."
  (ffi:with-foreign-object (info 'callable-custom-info2)
    ;; All slots not set below are NULL/0
    (clear-foreign-object info 'callable-custom-info2)
    (setf (ffi:get-slot-value info 'callable-custom-info2 'callable-userdata)
          (add-callable-function (callable-function callable))
          (ffi:get-slot-value info 'callable-custom-info2 'token) *class-library*
          (ffi:get-slot-value info 'callable-custom-info2 'object-id)
          (object-get-instance-id (object-pointer (callable-target callable)))
          (ffi:get-slot-value info 'callable-custom-info2 'call-func)
          (ffi:callback 'callable-call)
          (ffi:get-slot-value info 'callable-custom-info2 'free-func)
          (ffi:callback 'callable-free))
    (callable-custom-create2 pointer info)))

(add-value-type (make-value-type :variant-type +variant-type-callable+
                                 :ffi-type 'godot-callable
                                 :writer 'write-callable
                                 :destructor 'callable-destructor
                                 :lisp-type 'callable))

;; void (*GDExtensionCallableCustomCall)(void *callable_userdata,
;;                                       const GDExtensionConstVariantPtr *p_args,
;;                                       GDExtensionInt p_argument_count,
;;                                       GDExtensionVariantPtr r_return,
;;                                       GDExtensionCallError *r_error)
;;
;; The result of the function is returned as a Variant, if it can be one (see
;; VARIANT-VALUE-P); NIL, and values that can't be Variants yet, return null.
;; Callables are mostly signal handlers, whose results Godot ignores, so a
;; result that can't be returned isn't an error. Godot doesn't initialize
;; R-ERROR, so it's always set; to OK also after a Lisp error, as for a bound
;; method that fails.
(ffi:defcallback callable-call :void
    ((callable-userdata :pointer-void) (args :pointer-void) (argument-count :int64-t)
     (r-return :pointer-void) (r-error :pointer-void))
  (with-callback-protection ("Lisp callable")
    (set-call-error r-error +call-ok+)
    (let ((result (apply (userdata-callable-function callable-userdata)
                         (loop for i below argument-count
                               collect (read-variant (foreign-ref args :pointer-void i))))))
      (let ((variant-type (and result (lisp-variant-type result))))
        (when variant-type
          ;; R-RETURN is a Variant already (Nil). Written before the pool
          ;; gives back its references, so an object in it stays alive.
          (variant-destroy r-return)
          (write-variant-as r-return (find-value-type variant-type) result))))))

;; void (*GDExtensionCallableCustomFree)(void *callable_userdata)
(ffi:defcallback callable-free :void ((callable-userdata :pointer-void))
  (with-callback-protection ("free Lisp callable")
    (let ((index (1- (ffi:pointer-address callable-userdata))))
      (setf (aref *callables* index) nil)
      (push index *free-callables*))))
