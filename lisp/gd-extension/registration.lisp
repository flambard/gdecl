(in-package :gd-extension)

;;;
;;; Binding helpers
;;;
;;; WITH-PROPERTY-INFOS makes an array of GDExtensionPropertyInfo, for
;;; registering methods, properties and signals, and destroys the StringNames
;;; and Strings in them when its body exits, also after an error.
;;;

;; PropertyHint and PropertyUsageFlags, the values used here
(defconstant +property-hint-none+ (api-constant "PROPERTY_HINT_NONE"))
(defconstant +property-hint-resource-type+ (api-constant "PROPERTY_HINT_RESOURCE_TYPE"))
(defconstant +property-hint-node-type+ (api-constant "PROPERTY_HINT_NODE_TYPE"))
(defconstant +property-usage-default+ (api-constant "PROPERTY_USAGE_DEFAULT"))

(defun fill-property-info (info name type &key (hint +property-hint-none+) (hint-string "")
                                          (class-name "") (usage +property-usage-default+))
  "Fill in the GDExtensionPropertyInfo at INFO (the C version returns the struct
by value). DESTRUCT-PROPERTY frees what it allocates."
  (let ((prop-name (mem-alloc +string-name-size+))
        (prop-hint-string (mem-alloc +string-size+))
        (prop-class-name (mem-alloc +string-name-size+)))
    (string-name-new-with-utf8-chars prop-name name)
    (string-new-with-utf8-chars prop-hint-string hint-string)
    (string-name-new-with-utf8-chars prop-class-name class-name)
    (set-foreign-slots (info property-info)
      name prop-name
      type type
      hint hint
      hint-string prop-hint-string
      class-name prop-class-name
      usage usage)))

(defun destruct-property (info)
  (let ((name (ffi:get-slot-value info 'property-info 'name))
        (hint-string (ffi:get-slot-value info 'property-info 'hint-string))
        (class-name (ffi:get-slot-value info 'property-info 'class-name)))
    (string-name-destructor name)
    (string-destructor hint-string)
    (string-name-destructor class-name)
    (mem-free name)
    (mem-free hint-string)
    (mem-free class-name)))

(defun call-with-property-infos (properties function)
  (let ((count 0))
    ;; At least one element, so the array is never empty
    (with-foreign-memory ((infos :size (* (max (length properties) 1)
                                          (load-time-value
                                           (ffi:size-of-foreign-type 'property-info)))))
      (unwind-protect
           (progn
             (dolist (property properties)
               (apply #'fill-property-info (element-pointer infos 'property-info count) property)
               (incf count))
             (funcall function infos))
        (dotimes (i count)
          (destruct-property (element-pointer infos 'property-info i)))))))

(defmacro with-property-infos ((variable properties) &body body)
  "Evaluate BODY with VARIABLE bound to a pointer to an array of
GDExtensionPropertyInfo, one for each of PROPERTIES, a list of argument lists of
FILL-PROPERTY-INFO without the INFO: (name type &key hint hint-string class-name
usage). The property infos are destroyed when BODY exits, also on a non-local
exit."
  `(call-with-property-infos ,properties (lambda (,variable) ,@body)))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun invoker-form (return-type argument-types)
    "The form of the invoker of a bound method with RETURN-TYPE and
ARGUMENT-TYPES, types as in VARIANT-TYPE (e.g. :INT), for the :INVOKER of
BIND-METHOD: a function generated for the signature, so that calls into the
method don't build a list of the arguments or call converters by name (see
REGISTER-METHOD). NIL if a type can't be converted that way, and then the
method's calls go through the generic dispatcher. For macros that know the
types when they're expanded, such as DEFINE-CLASS."
    (ptrcall-invoker-form (variant-type return-type)
                          (mapcar #'variant-type argument-types))))

(defun bind-method (class-name method-name function
                    &key (return-type +variant-type-nil+) arguments invoker)
  "Register FUNCTION as the method METHOD-NAME of the class CLASS-NAME.
ARGUMENTS is a list of (name type), and RETURN-TYPE the type of the return
value (:NIL for none), where a type is as in VARIANT-TYPE, e.g. :INT or
:VECTOR2. FUNCTION is called with the instance's Lisp object (see
REGISTER-CLASS) and the arguments as Lisp values. INVOKER is as in
REGISTER-METHOD, generated with INVOKER-FORM."
  (let* ((return-type (variant-type return-type))
         (arguments (loop for (name type) in arguments
                          collect (list name (variant-type type))))
         (argument-count (length arguments))
         (has-return-value (/= return-type +variant-type-nil+)))
    (with-string-name (method-name-string method-name)
      (with-property-infos (return-info (and has-return-value `(("" ,return-type))))
        (with-property-infos (args-info arguments)
          ;; At least one element, so the array is never empty
          (with-foreign-memory ((args-metadata :size (* (max argument-count 1)
                                                        (load-time-value
                                                         (ffi:size-of-foreign-type :int))))
                                (method-info 'class-method-info))
            (dotimes (i argument-count)
              (setf (foreign-ref args-metadata :int i) +method-argument-metadata-none+))
            ;; All slots not set below are NULL/0
            (clear-foreign-object method-info 'class-method-info)
            (set-foreign-slots (method-info class-method-info)
              name method-name-string
              method-userdata (register-method function
                                               :name (format nil "~a.~a" class-name method-name)
                                               :return-type return-type
                                               :argument-types (mapcar #'second arguments)
                                               :invoker invoker)
              call-func (callback-pointer 'method-call)
              ptrcall-func (callback-pointer 'method-ptrcall)
              method-flags +method-flags-default+
              has-return-value (if has-return-value 1 0)
              return-value-info return-info
              return-value-metadata +method-argument-metadata-none+
              argument-count argument-count
              arguments-info args-info
              arguments-metadata args-metadata)
            (with-string-name (class-name-string class-name)
              (classdb-register-extension-class-method *class-library* class-name-string
                                                       method-info))))))))

(define-engine-method class-db-is-parent-class ("ClassDB" "is_parent_class"))

(defun inherits-class-p (class-name parent-class-name)
  "True if the class CLASS-NAME is PARENT-CLASS-NAME or inherits from it (both
strings)."
  (with-string-name (class-string-name class-name)
    (with-string-name (parent-string-name parent-class-name)
      (class-db-is-parent-class class-string-name parent-string-name))))

(defun bind-property (class-name name type getter setter
                      &key class (hint +property-hint-none+) (hint-string ""))
  "Register the property NAME of the class CLASS-NAME, of TYPE (as in
VARIANT-TYPE, e.g. :INT), with the bound methods GETTER and SETTER (method
names).

For an :OBJECT property, CLASS is the class of its value, e.g. \"PackedScene\"
for a property like @export var mob_scene: PackedScene in GDScript. It's
edited in the editor as a resource of that class, or as a node of that class if
it's a Node class.

Otherwise, HINT and HINT-STRING tell the editor how to edit it, as in Godot's
PropertyHint."
  (let ((type (variant-type type))
        (property-class-name ""))
    (when class
      (unless (= type +variant-type-object+)
        (error "The property ~a.~a has a class, ~a, but isn't an :OBJECT" class-name name class))
      (setf hint (cond ((inherits-class-p class "Resource") +property-hint-resource-type+)
                       ((inherits-class-p class "Node") +property-hint-node-type+)
                       (t (error "The class ~a of the property ~a.~a is neither a Resource nor a Node"
                                 class class-name name)))
            hint-string class
            property-class-name class))
    (with-string-name (class-string-name class-name)
      (with-property-infos (info `((,name ,type :hint ,hint :hint-string ,hint-string
                                           :class-name ,property-class-name)))
        (with-string-name (getter-name getter)
          (with-string-name (setter-name setter)
            (classdb-register-extension-class-property *class-library* class-string-name
                                                       info setter-name getter-name)))))))

(defun bind-signal (class-name signal-name &optional arguments)
  "Register the signal SIGNAL-NAME of the class CLASS-NAME, like signal in
GDScript. ARGUMENTS is a list of (name type), as in BIND-METHOD; a signal
without arguments has none."
  (let* ((arguments (loop for (name type) in arguments
                          collect (list name (variant-type type))))
         (argument-count (length arguments)))
    (with-string-name (class-string-name class-name)
      (with-string-name (signal-string-name signal-name)
        (with-property-infos (args-info arguments)
          (classdb-register-extension-class-signal *class-library* class-string-name
                                                   signal-string-name args-info
                                                   argument-count))))))

;; StringNames with the names of the classes registered with REGISTER-CLASS,
;; the last one first
(defvar *registered-classes* '())

(defun register-class (class-name parent-class-name
                       &key constructor destructor notification (notifications t) tool)
  "Register the class CLASS-NAME, which inherits from the class
PARENT-CLASS-NAME (both strings). When Godot creates an instance, CONSTRUCTOR
is called with the Godot object pointer, and returns the instance's Lisp object
(see INSTANCE-OBJECT), a GODOT-OBJECT: usually a struct that includes
GODOT-OBJECT, made with the pointer as its POINTER. The default makes one of
the type of the engine class it inherits from (see DEFINE-ENGINE-CLASS), as
for an object of that class. When Godot frees the instance, DESTRUCTOR, if
given, is called with the Lisp object. It's called as the Godot object is
destroyed, so it mustn't call Godot with it; that's for
NOTIFICATION_PREDELETE.

When Godot sends an instance a notification, like _notification in GDScript,
NOTIFICATION, if given, is called with the Lisp object, the notification (an
integer, such as +OBJECT-NOTIFICATION-PREDELETE+ in GODOT) and whether it's
sent in reverse order (subclasses first, as PREDELETE is), for the
notifications in NOTIFICATIONS: a list, or T for all. SET-CLASS-NOTIFICATIONS
changes them. Godot sends some notifications every frame, such as
NOTIFICATION_PROCESS, so only those that some class wants call into Lisp.

Unless TOOL is true, the class is a runtime class: in the editor, its instances
are placeholders that keep their properties but run no code, like a GDScript
script without @tool."
  (let* ((constructor (or constructor
                          (let ((make (class-constructor parent-class-name)))
                            (lambda (pointer) (funcall make :pointer pointer)))))
         (string-name (new-string-name class-name))
         (parent-string-name (new-string-name parent-class-name))
         (class-userdata (add-extension-class class-name string-name parent-string-name
                                              constructor destructor
                                              notification notifications)))
    (ffi:with-foreign-object (info 'class-creation-info4)
      ;; All slots not set below are NULL/0
      (clear-foreign-object info 'class-creation-info4)
      (set-foreign-slots (info class-creation-info4)
        is-exposed 1
        is-runtime (if tool 0 1)
        create-instance-func (callback-pointer 'create-instance)
        free-instance-func (callback-pointer 'free-instance)
        notification-func (if notification
                              (notification-filter-pointer)
                              (ffi:make-null-pointer :void))
        get-virtual-call-data-func (callback-pointer 'get-virtual-call-data)
        call-virtual-with-data-func (callback-pointer 'call-virtual-with-data)
        class-userdata class-userdata)
      (classdb-register-extension-class4 *class-library* string-name parent-string-name
                                         info))
    (push string-name *registered-classes*)
    class-name))

(defun unregister-classes ()
  "Unregister the classes registered with REGISTER-CLASS, in the reverse order,
so that subclasses go before the classes they inherit from. A step of the
framework's shutdown (see lifecycle.lisp)."
  (dolist (string-name *registered-classes*)
    (classdb-unregister-extension-class *class-library* string-name))
  (setf *registered-classes* '()))

;;;
;;; Classes registered when Godot initializes the extension
;;;
;;; The layers above that define classes, DEFINE-CLASS and GODOT-CLOS, add a
;;; function that registers each class with ADD-CLASS-DEFINITION, so the
;;; classes are registered when Godot initializes the extension, in the order
;;; they were defined, by REGISTER-DEFINED-CLASSES, a step of the framework's
;;; startup (see lifecycle.lisp), before the application's initialize hooks.
;;;

;; The registration functions of the classes added with ADD-CLASS-DEFINITION:
;; a list of (class-name . function), in the order they were added
(defvar *class-definitions* '())

(defun add-class-definition (class-name function)
  "Make FUNCTION, which registers the class CLASS-NAME, run when Godot initializes
the extension, or now if it has (e.g. at a REPL). Defining the class again
replaces the function, keeping its place in the order."
  (let ((definition (assoc class-name *class-definitions* :test #'string=)))
    (if definition
        (setf (cdr definition) function)
        (setf *class-definitions*
              (append *class-definitions* (list (cons class-name function))))))
  (when *class-library*
    (funcall function))
  class-name)

(defun register-defined-classes ()
  "Register the classes added with ADD-CLASS-DEFINITION. A step of the
framework's startup (see lifecycle.lisp). A class that fails to register is
reported, and the others are still registered."
  (loop for (class-name . function) in *class-definitions*
        do (handler-case (funcall function)
             (error (e)
               (report-error (format nil "registering the class ~a" class-name) e)))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun godot-property-name (slot-name)
    "The name of the property of the slot SLOT-NAME, a symbol, in Godot style:
mob-scene becomes \"mob_scene\"."
    (substitute #\_ #\- (string-downcase (symbol-name slot-name)))))

;;;
;;; Singletons
;;;

(define-engine-method engine-register-singleton ("Engine" "register_singleton"))
(define-engine-method engine-unregister-singleton ("Engine" "unregister_singleton"))

;; The singletons registered with REGISTER-SINGLETON: a list of (name . object),
;; the last one first
(defvar *singletons* '())

(defun register-singleton (class-name &optional (name class-name))
  "Make an instance of the class CLASS-NAME and register it as the engine
singleton NAME (both strings), like Engine.register_singleton, so that GDScript
can use it by name, as Input. Returns its Lisp object, which (SINGLETON NAME)
also gives. It's unregistered and freed when Godot unloads the extension, after
the application's deinitialize hooks. The class can't be RefCounted: Godot's
singletons don't keep references."
  (when (inherits-class-p class-name "RefCounted")
    (error "The singleton ~a can't be of the RefCounted class ~a" name class-name))
  (let ((object (lisp-object (with-string-name (string-name class-name)
                               (classdb-construct-object string-name)))))
    (engine-register-singleton name object)
    (push (cons name object) *singletons*)
    object))

(defun unregister-singletons ()
  "Unregister and free the singletons registered with REGISTER-SINGLETON, the last
one first. A step of the framework's shutdown (see lifecycle.lisp)."
  (loop for (name . object) in *singletons*
        do (engine-unregister-singleton name)
           (object-destroy (object-pointer object)))
  (setf *singletons* '()))

;;;
;;; Virtual methods
;;;
;;; BIND-VIRTUAL looks up the virtual method's signature in extension_api.json
;;; when it's expanded. Engine classes can have virtual methods with the same
;;; name and different signatures (such as _process in Node and in
;;; AnimationNode), so the expansion has the signatures of all of them, and the
;;; one of the class that the extension class inherits from is chosen when it's
;;; bound, with ClassDB.is_parent_class.
;;;

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun virtual-signatures (virtual-name)
    "The signatures of the virtual methods VIRTUAL-NAME of the engine classes, as
a list of (class-name return-type argument-types problem): variant types, or a
string PROBLEM that says why the method can't be bound."
    (loop for (class-name . method) in (api-virtual-methods virtual-name)
          collect (handler-case
                      (let ((return-type (api-method-return-type method)))
                        (list class-name
                              (if return-type
                                  (api-variant-type return-type)
                                  +variant-type-nil+)
                              (mapcar (lambda (argument)
                                        (api-variant-type (api-argument-type argument)))
                                      (api-method-arguments method))
                              nil))
                    (unsupported-api-type (e)
                      (list class-name nil nil (princ-to-string e)))))))

(defun bind-virtual-with-signatures (class-name virtual-name function signatures)
  "Bind FUNCTION as the virtual method VIRTUAL-NAME of the class CLASS-NAME, with
the signature from SIGNATURES (see VIRTUAL-SIGNATURES, with the signature's
invoker, see REGISTER-METHOD, added to each) of the engine class that
CLASS-NAME inherits from."
  (destructuring-bind (&optional defining-class return-type argument-types problem invoker)
      (find-if (lambda (signature) (inherits-class-p class-name (first signature)))
               signatures)
    (unless defining-class
      (error "~a doesn't inherit from a class with the virtual method ~a (~{~a~^, ~})"
             class-name virtual-name (mapcar #'first signatures)))
    (when problem
      (error "The virtual method ~a.~a can't be bound: ~a" defining-class virtual-name problem))
    (add-virtual class-name
                 (new-string-name virtual-name)
                 (register-method function :name (format nil "~a.~a" class-name virtual-name)
                                           :return-type return-type
                                           :argument-types argument-types
                                           :invoker invoker))))

(defmacro bind-virtual (class-name virtual-name function)
  "Make FUNCTION the class CLASS-NAME's implementation of the virtual method
VIRTUAL-NAME, a literal string such as \"_ready\" or \"_process\". FUNCTION is
called with the instance's Lisp object and the arguments as Lisp values. The
virtual method's signature is looked up in extension_api.json, in the engine
class that CLASS-NAME inherits from. Call it after REGISTER-CLASS, before Godot
creates any instances of the class."
  (unless (stringp virtual-name)
    (error "The name of the virtual method in BIND-VIRTUAL must be a literal string: ~s"
           virtual-name))
  (let ((signatures (virtual-signatures virtual-name)))
    (unless signatures
      (error "No engine class has a virtual method ~a (~a)" virtual-name *extension-api-file*))
    ;; One invoker for each distinct signature that can be bound
    (let ((invokers '()))
      (loop for (nil return-type argument-types problem) in signatures
            for key = (cons return-type argument-types)
            unless (or problem (assoc key invokers :test #'equal))
              do (push (list key (gensym "INVOKER") (ptrcall-invoker-form return-type argument-types))
                       invokers))
      `(let (,@(loop for (nil variable form) in invokers
                     collect `(,variable ,form)))
         (bind-virtual-with-signatures
          ,class-name ,virtual-name ,function
          (list ,@(loop for (class return-type argument-types problem) in signatures
                        collect `(list ,class ,return-type ',argument-types ,problem
                                       ,(second (assoc (cons return-type argument-types)
                                                       invokers :test #'equal))))))))))
