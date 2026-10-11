(in-package :gd-extension)

;;;
;;; The Lisp-style layer of the framework: initialization, helpers and macros,
;;; and registering classes and binding Lisp functions as methods, properties
;;; and signals. Built on the package GD-EXTENSION-FFI (gd-extension-ffi.lisp),
;;; which maps the C interface, and GD-EXTENSION-CALLBACK
;;; (gd-extension-callback.lisp), which handles Godot's calls into Lisp.
;;;

;;;
;;; Initialization
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

(defun initialize (get-proc-address class-library)
  "Set up the framework with the GDExtensionInterfaceGetProcAddress and
GDExtensionClassLibraryPtr that Godot gave the extension, then run the
initialize hooks. Called from src/gdecl.c."
  (load-interface get-proc-address class-library)
  (dolist (hook *initialize-hooks*)
    (handler-case (funcall hook)
      (error (e)
        (format t "~&Error in initialize hook ~a: ~a~%" hook e))))
  t)

;;;
;;; Helpers
;;;

(defmacro with-string-name ((var contents) &body body)
  "Evaluate BODY with VAR bound to a pointer to a StringName created from the
string CONTENTS. The StringName is destroyed when BODY exits, also on a
non-local exit."
  `(ffi:with-foreign-object (,var 'string-name)
     (string-name-new-with-latin1-chars ,var ,contents)
     (unwind-protect (progn ,@body)
       (string-name-destructor ,var))))

(defun get-method-bind (class-name method-name hash)
  "The GDExtensionMethodBindPtr of the method METHOD-NAME of the class
CLASS-NAME (both strings). HASH is the hash of the method's signature, from
extension_api.json; the result is NULL if it doesn't match."
  (with-string-name (class-string-name class-name)
    (with-string-name (method-string-name method-name)
      (classdb-get-method-bind class-string-name method-string-name hash))))

(defmacro with-string ((var contents) &body body)
  "Evaluate BODY with VAR bound to a pointer to a Godot String created from the
Lisp string CONTENTS. The String is destroyed when BODY exits, also on a
non-local exit."
  `(ffi:with-foreign-object (,var 'godot-string)
     (string-new-with-utf8-chars ,var ,contents)
     (unwind-protect (progn ,@body)
       (string-destructor ,var))))

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
ARGUMENTS is a list of (name variant-type), and RETURN-TYPE the variant type of
the return value (+VARIANT-TYPE-NIL+ for none). FUNCTION is called with the
instance's Lisp object (see REGISTER-CLASS) and the arguments as Lisp values."
  (let ((argument-count (length arguments))
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
              (register-method function :return-type return-type
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

(defun bind-property (class-name name type getter setter)
  (with-string-name (class-string-name class-name)
    (ffi:with-foreign-object (info 'property-info)
      (make-property info type name)
      (with-string-name (getter-name getter)
        (with-string-name (setter-name setter)
          (classdb-register-extension-class-property *class-library* class-string-name
                                                     info setter-name getter-name)))
      (destruct-property info))))

(defun bind-signal-1 (class-name signal-name arg1-name arg1-type)
  (with-string-name (class-string-name class-name)
    (with-string-name (signal-string-name signal-name)
      (ffi:with-foreign-object (args-info 'property-info)
        (make-property args-info arg1-type arg1-name)
        (classdb-register-extension-class-signal *class-library* class-string-name
                                                 signal-string-name args-info 1)
        (destruct-property args-info)))))

(defun new-string-name (contents)
  "A StringName created from the string CONTENTS, in memory from MEM-ALLOC.
Never destroyed."
  (let ((string-name (mem-alloc +string-name-size+)))
    (string-name-new-with-latin1-chars string-name contents)
    string-name))

(defun register-class (class-name parent-class-name
                       &key (constructor #'identity) destructor)
  "Register the class CLASS-NAME, which inherits from the class
PARENT-CLASS-NAME (both strings). When Godot creates an instance, CONSTRUCTOR
is called with the Godot object pointer, and returns the instance's Lisp object
(see INSTANCE-OBJECT); the default is the object pointer itself. When Godot
frees the instance, DESTRUCTOR, if given, is called with the Lisp object."
  (let* ((string-name (new-string-name class-name))
         (parent-string-name (new-string-name parent-class-name))
         (class-userdata (add-extension-class string-name parent-string-name
                                              constructor destructor)))
    (ffi:with-foreign-object (info 'class-creation-info4)
      ;; All slots not set below are NULL/0
      (clear-foreign-object info 'class-creation-info4)
      (setf (ffi:get-slot-value info 'class-creation-info4 'is-exposed) 1
            (ffi:get-slot-value info 'class-creation-info4 'create-instance-func)
            (ffi:callback 'create-instance)
            (ffi:get-slot-value info 'class-creation-info4 'free-instance-func)
            (ffi:callback 'free-instance)
            (ffi:get-slot-value info 'class-creation-info4 'class-userdata) class-userdata)
      (classdb-register-extension-class4 *class-library* string-name parent-string-name
                                         info))
    class-name))
