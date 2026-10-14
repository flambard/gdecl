(in-package :gd-extension)

;;;
;;; Binding helpers
;;;
;;; MAKE-PROPERTY fills in the GDExtensionPropertyInfo at INFO (the C version
;;; returns the struct by value). The StringNames and the String it allocates
;;; are freed by DESTRUCT-PROPERTY.
;;;

(defun make-property (info type name)
  (make-property-full info type name +property-hint-none+ "" "" +property-usage-default+))

(defun make-property-full (info type name hint hint-string class-name usage-flags)
  (let ((prop-name (mem-alloc +string-name-size+))
        (prop-hint-string (mem-alloc +string-size+))
        (prop-class-name (mem-alloc +string-name-size+)))
    (string-name-new-with-latin1-chars prop-name name)
    (string-new-with-utf8-chars prop-hint-string hint-string)
    (string-name-new-with-latin1-chars prop-class-name class-name)
    (setf (ffi:get-slot-value info 'property-info 'name) prop-name
          (ffi:get-slot-value info 'property-info 'type) type
          (ffi:get-slot-value info 'property-info 'hint) hint
          (ffi:get-slot-value info 'property-info 'hint-string) prop-hint-string
          (ffi:get-slot-value info 'property-info 'class-name) prop-class-name
          (ffi:get-slot-value info 'property-info 'usage) usage-flags)
    info))

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

(defun bind-method (class-name method-name function
                    &key (return-type +variant-type-nil+) arguments)
  "Register FUNCTION as the method METHOD-NAME of the class CLASS-NAME.
ARGUMENTS is a list of (name type), and RETURN-TYPE the type of the return
value (:NIL for none), where a type is as in VARIANT-TYPE, e.g. :INT or
:VECTOR2. FUNCTION is called with the instance's Lisp object (see
REGISTER-CLASS) and the arguments as Lisp values."
  (let* ((return-type (variant-type return-type))
         (arguments (loop for (name type) in arguments
                          collect (list name (variant-type type))))
         (argument-count (length arguments))
         (has-return-value (/= return-type +variant-type-nil+)))
    (with-string-name (method-name-string method-name)
      (ffi:with-foreign-objects ((return-info 'property-info)
                                 ;; At least one element, so the arrays are never empty
                                 (args-info `(:array property-info ,(max argument-count 1)))
                                 (args-metadata `(:array :int ,(max argument-count 1)))
                                 (method-info 'class-method-info))
        (when has-return-value
          (make-property return-info return-type ""))
        (loop for (name type) in arguments
              for i from 0
              do (make-property (element-pointer args-info 'property-info i) type name)
                 (setf (foreign-ref args-metadata :int i) +method-argument-metadata-none+))
        ;; All slots not set below are NULL/0
        (clear-foreign-object method-info 'class-method-info)
        (setf (ffi:get-slot-value method-info 'class-method-info 'name) method-name-string
              (ffi:get-slot-value method-info 'class-method-info 'method-userdata)
              (register-method function :name (format nil "~a.~a" class-name method-name)
                                        :return-type return-type
                                        :argument-types (mapcar #'second arguments))
              (ffi:get-slot-value method-info 'class-method-info 'call-func)
              (ffi:callback 'method-call)
              (ffi:get-slot-value method-info 'class-method-info 'ptrcall-func)
              (ffi:callback 'method-ptrcall)
              (ffi:get-slot-value method-info 'class-method-info 'method-flags)
              +method-flags-default+
              (ffi:get-slot-value method-info 'class-method-info 'has-return-value)
              (if has-return-value 1 0)
              (ffi:get-slot-value method-info 'class-method-info 'return-value-info) return-info
              (ffi:get-slot-value method-info 'class-method-info 'return-value-metadata)
              +method-argument-metadata-none+
              (ffi:get-slot-value method-info 'class-method-info 'argument-count) argument-count
              (ffi:get-slot-value method-info 'class-method-info 'arguments-info) args-info
              (ffi:get-slot-value method-info 'class-method-info 'arguments-metadata)
              args-metadata)
        (with-string-name (class-name-string class-name)
          (classdb-register-extension-class-method *class-library* class-name-string
                                                   method-info))
        (when has-return-value
          (destruct-property return-info))
        (dotimes (i argument-count)
          (destruct-property (element-pointer args-info 'property-info i)))))))

(define-engine-method class-db-is-parent-class ("ClassDB" "is_parent_class"))

;; For the :ONREADY slots of DEFINE-CLASS
(define-engine-method node-get-node ("Node" "get_node"))

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
      (ffi:with-foreign-object (info 'property-info)
        (make-property-full info type name hint hint-string property-class-name
                            +property-usage-default+)
        (with-string-name (getter-name getter)
          (with-string-name (setter-name setter)
            (classdb-register-extension-class-property *class-library* class-string-name
                                                       info setter-name getter-name)))
        (destruct-property info)))))

(defun bind-signal (class-name signal-name &optional arguments)
  "Register the signal SIGNAL-NAME of the class CLASS-NAME, like signal in
GDScript. ARGUMENTS is a list of (name type), as in BIND-METHOD; a signal
without arguments has none."
  (let* ((arguments (loop for (name type) in arguments
                          collect (list name (variant-type type))))
         (argument-count (length arguments)))
    (with-string-name (class-string-name class-name)
      (with-string-name (signal-string-name signal-name)
        ;; At least one element, so the array is never empty
        (ffi:with-foreign-object (args-info `(:array property-info ,(max argument-count 1)))
          (loop for (name type) in arguments
                for i from 0
                do (make-property (element-pointer args-info 'property-info i) type name))
          (classdb-register-extension-class-signal *class-library* class-string-name
                                                   signal-string-name args-info argument-count)
          (dotimes (i argument-count)
            (destruct-property (element-pointer args-info 'property-info i))))))))

;; StringNames with the names of the classes registered with REGISTER-CLASS,
;; the last one first
(defvar *registered-classes* '())

(defun register-class (class-name parent-class-name
                       &key (constructor (lambda (pointer)
                                           (make-godot-object :pointer pointer)))
                            destructor tool)
  "Register the class CLASS-NAME, which inherits from the class
PARENT-CLASS-NAME (both strings). When Godot creates an instance, CONSTRUCTOR
is called with the Godot object pointer, and returns the instance's Lisp object
(see INSTANCE-OBJECT), a GODOT-OBJECT: usually a struct that includes
GODOT-OBJECT, made with the pointer as its POINTER. The default makes a plain
GODOT-OBJECT. When Godot
frees the instance, DESTRUCTOR, if given, is called with the Lisp object.

Unless TOOL is true, the class is a runtime class: in the editor, its instances
are placeholders that keep their properties but run no code, like a GDScript
script without @tool."
  (let* ((string-name (new-string-name class-name))
         (parent-string-name (new-string-name parent-class-name))
         (class-userdata (add-extension-class class-name string-name parent-string-name
                                              constructor destructor)))
    (ffi:with-foreign-object (info 'class-creation-info4)
      ;; All slots not set below are NULL/0
      (clear-foreign-object info 'class-creation-info4)
      (setf (ffi:get-slot-value info 'class-creation-info4 'is-exposed) 1
            (ffi:get-slot-value info 'class-creation-info4 'is-runtime) (if tool 0 1)
            (ffi:get-slot-value info 'class-creation-info4 'create-instance-func)
            (ffi:callback 'create-instance)
            (ffi:get-slot-value info 'class-creation-info4 'free-instance-func)
            (ffi:callback 'free-instance)
            (ffi:get-slot-value info 'class-creation-info4 'get-virtual-call-data-func)
            (ffi:callback 'get-virtual-call-data)
            (ffi:get-slot-value info 'class-creation-info4 'call-virtual-with-data-func)
            (ffi:callback 'call-virtual-with-data)
            (ffi:get-slot-value info 'class-creation-info4 'class-userdata) class-userdata)
      (classdb-register-extension-class4 *class-library* string-name parent-string-name
                                         info))
    (push string-name *registered-classes*)
    class-name))

(defun unregister-classes ()
  "Unregister the classes registered with REGISTER-CLASS, in the reverse order,
so that subclasses go before the classes they inherit from. A deinitialize hook,
added after DESTROY-PERMANENT-VALUES so that it runs before it, while the class
names are still there, and after the application's hooks."
  (dolist (string-name *registered-classes*)
    (classdb-unregister-extension-class *class-library* string-name))
  (setf *registered-classes* '()))

(add-deinitialize-hook 'unregister-classes)

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
                      (let ((return-value (json-get method "return_value")))
                        (list class-name
                              (if return-value
                                  (api-variant-type (json-get return-value "type"))
                                  +variant-type-nil+)
                              (mapcar (lambda (argument)
                                        (api-variant-type (json-get argument "type")))
                                      (json-get method "arguments"))
                              nil))
                    (unsupported-api-type (e)
                      (list class-name nil nil (princ-to-string e)))))))

(defun bind-virtual-with-signatures (class-name virtual-name function signatures)
  "Bind FUNCTION as the virtual method VIRTUAL-NAME of the class CLASS-NAME, with
the signature from SIGNATURES (see VIRTUAL-SIGNATURES) of the engine class that
CLASS-NAME inherits from."
  (destructuring-bind (&optional defining-class return-type argument-types problem)
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
                                           :argument-types argument-types))))

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
    `(bind-virtual-with-signatures ,class-name ,virtual-name ,function ',signatures)))
