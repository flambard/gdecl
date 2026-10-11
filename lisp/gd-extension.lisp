(in-package :gd-extension)

;;;
;;; The Lisp-style layer of the framework: initialization, helpers and macros,
;;; and registering classes and binding Lisp functions as methods, properties
;;; and signals. Built on the package GD-EXTENSION-FFI (gd-extension-ffi.lisp),
;;; which maps the C interface, GD-EXTENSION-TYPES (gd-extension-types.lisp),
;;; Godot's builtin types in Lisp, and GD-EXTENSION-CALLBACK
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

;; Values to compute in INITIALIZE, see MAKE-INITIALIZE-CELL
(defvar *initialize-cells* '())

(defun initialize (get-proc-address class-library)
  "Set up the framework with the GDExtensionInterfaceGetProcAddress and
GDExtensionClassLibraryPtr that Godot gave the extension, fill in the
initialize cells made so far, then run the initialize hooks. Called from
src/gdecl.c."
  (load-interface get-proc-address class-library)
  (loop for (cell . function) in (reverse *initialize-cells*)
        do (handler-case (setf (car cell) (funcall function))
             (error (e)
               (format t "~&Error in initialize cell ~a: ~a~%" function e))))
  (setf *initialize-cells* '())
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
;;; Values looked up once
;;;
;;; Things looked up in Godot, such as method binds, StringNames and
;;; singletons, should be looked up once and not at every call. But not at load
;;; time, since there's no Godot then. An initialize cell is a cons whose car is
;;; computed in INITIALIZE; code gets the cons with LOAD-TIME-VALUE, so it's made
;;; when the code is loaded, and the car is ready when the code runs.
;;;

(defun make-initialize-cell (function)
  "A cons whose car will be the value of FUNCTION, called with no arguments in
INITIALIZE, or now if INITIALIZE has been called (e.g. at a REPL)."
  (let ((cell (cons nil nil)))
    (if *class-library*
        (setf (car cell) (funcall function))
        (push (cons cell function) *initialize-cells*))
    cell))

(defun new-string-name (contents)
  "A StringName created from the string CONTENTS, in memory from MEM-ALLOC.
Never destroyed."
  (let ((string-name (mem-alloc +string-name-size+)))
    (string-name-new-with-latin1-chars string-name contents)
    string-name))

(defmacro sname (string)
  "A pointer to a StringName with STRING, a literal string. The StringName is
created once, like SNAME() in Godot's C++ code, and never destroyed."
  `(car (load-time-value (make-initialize-cell (lambda () (new-string-name ,string))))))

(defun new-node-path (path)
  "A NodePath created from the string PATH, in memory from MEM-ALLOC. Never
destroyed."
  (let ((node-path (mem-alloc +node-path-size+)))
    (with-string (string path)
      (ffi:with-foreign-object (args '(:array :pointer-void 1))
        (setf (foreign-ref args :pointer-void 0) string)
        ;; Constructor 2 of NodePath takes a String
        (call-ptr-constructor (variant-get-ptr-constructor +variant-type-node-path+ 2)
                              node-path args)))
    node-path))

(defmacro npath (path)
  "A pointer to a NodePath with PATH, a literal string, like ^\"path\" in GDScript.
The NodePath is created once and never destroyed."
  `(car (load-time-value (make-initialize-cell (lambda () (new-node-path ,path))))))

(defmacro singleton (name)
  "The Godot object pointer of the engine singleton NAME, a literal string such
as \"Input\". Looked up once."
  `(car (load-time-value
         (make-initialize-cell (lambda ()
                                 (with-string-name (string-name ,name)
                                   (global-get-singleton string-name)))))))

;;;
;;; Calling engine methods
;;;
;;; DEFINE-ENGINE-METHOD defines a Lisp function that calls a method of a Godot
;;; class with ptrcall. The method bind is looked up once, in an initialize
;;; cell, and the code that converts the arguments and the result is generated
;;; for each type when the macro is expanded.
;;;

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun engine-value-ffi-type (variant-type)
    "The FFI type of the raw value of VARIANT-TYPE (or :VARIANT for any Variant),
or NIL for a StringName or NodePath, which is passed as the pointer to it."
    (value-type-ffi-type (find-value-type variant-type)))

  (defun engine-value-write-form (variant-type pointer value)
    "A form that stores the Lisp VALUE as a raw value of VARIANT-TYPE at POINTER."
    (let ((writer (value-type-writer (find-value-type variant-type))))
      (unless writer
        (error "Unsupported argument type for an engine method: variant type ~s" variant-type))
      `(,writer ,pointer ,value)))

  (defun engine-value-read-form (variant-type pointer)
    "A form that reads the raw value of VARIANT-TYPE at POINTER as a Lisp value."
    (let ((reader (value-type-reader (find-value-type variant-type))))
      (unless reader
        (error "Unsupported return type for an engine method: variant type ~s" variant-type))
      `(,reader ,pointer)))

  (defun engine-value-destroy-form (variant-type pointer)
    "A form that destroys the raw value of VARIANT-TYPE at POINTER, or NIL if it
needs no destroying."
    (let ((destructor (value-type-destructor (find-value-type variant-type))))
      (when destructor
        `(,destructor ,pointer))))

  (defun ptrcall-method-form (method-bind object arguments return-type)
    "The code of a DEFINE-ENGINE-METHOD function that calls METHOD-BIND with
ptrcall, with ARGUMENTS as in DEFINE-ENGINE-METHOD."
    (let ((has-return-value (/= return-type +variant-type-nil+))
          (args (gensym "ARGS"))
          (r-ret (gensym "R-RET")))
      `(ffi:with-foreign-objects ((,args '(:array :pointer-void ,(max 1 (length arguments))))
                                  ,@(loop for (nil nil nil ffi-type raw) in arguments
                                          when ffi-type collect `(,raw ',ffi-type))
                                  ,@(when has-return-value
                                      `((,r-ret ',(engine-value-ffi-type return-type)))))
         ,@(loop for (arg-name type nil ffi-type raw) in arguments
                 for i from 0
                 if ffi-type
                   collect (engine-value-write-form type raw arg-name)
                   and collect `(setf (foreign-ref ,args :pointer-void ,i) ,raw)
                 else
                   collect `(setf (foreign-ref ,args :pointer-void ,i) ,arg-name))
         ,(let ((call `(progn
                         ;; Godot assigns the result, e.g. to a Ref or a
                         ;; PackedStringArray, so the old value must be empty
                         ,@(when has-return-value
                             `((clear-foreign-object ,r-ret ',(engine-value-ffi-type return-type))))
                         (object-method-bind-ptrcall ,method-bind ,object ,args
                                                     ,(if has-return-value
                                                          r-ret
                                                          '(ffi:make-null-pointer :void)))
                         ,(when has-return-value
                            (engine-value-read-form return-type r-ret))))
                ;; Raw values that need it, such as Variants, are destroyed
                ;; after the call
                (destroy-forms (append
                                (loop for (nil type nil ffi-type raw) in arguments
                                      for form = (and ffi-type (engine-value-destroy-form type raw))
                                      when form collect form)
                                (when has-return-value
                                  (let ((form (engine-value-destroy-form return-type r-ret)))
                                    (when form (list form)))))))
            (if destroy-forms
                `(unwind-protect ,call ,@destroy-forms)
                call)))))

  (defun variant-call-method-form (method-bind object arguments return-type name)
    "The code of a DEFINE-ENGINE-VARARG-METHOD function that calls METHOD-BIND
with object_method_bind_call, with the arguments and the result as Variants."
    (let ((has-return-value (/= return-type +variant-type-nil+))
          (argument-count (length arguments))
          (args (gensym "ARGS"))
          (variants (gensym "VARIANTS"))
          (r-return (gensym "R-RETURN"))
          (r-error (gensym "R-ERROR"))
          (r-ret (gensym "R-RET"))
          (call-error (gensym "CALL-ERROR")))
      `(ffi:with-foreign-objects ((,args '(:array :pointer-void ,(max 1 argument-count)))
                                  (,variants '(:array variant ,(max 1 argument-count)))
                                  ,@(loop for (nil nil nil ffi-type raw) in arguments
                                          when ffi-type collect `(,raw ',ffi-type))
                                  (,r-return 'variant)
                                  (,r-error 'call-error)
                                  ,@(when has-return-value
                                      `((,r-ret ',(engine-value-ffi-type return-type)))))
         ,@(loop for (arg-name type nil ffi-type raw) in arguments
                 for i from 0
                 for variant = `(element-pointer ,variants 'variant ,i)
                 if (eql type :variant)
                   ;; Already any Variant: constructed right in the array
                   collect `(write-variant ,variant ,arg-name)
                 else
                   when ffi-type
                     collect (engine-value-write-form type raw arg-name)
                   end
                   and collect `(call-variant-from-type-constructor
                                 (aref *variant-from-type-constructors* ,type)
                                 ,variant
                                 ,(if ffi-type raw arg-name))
                 end
                 collect `(setf (foreign-ref ,args :pointer-void ,i) ,variant))
         ;; Godot always initializes r_ret, also when the call fails
         (unwind-protect
              (progn
                (object-method-bind-call ,method-bind ,object ,args ,argument-count
                                         ,r-return ,r-error)
                (let ((,call-error (ffi:get-slot-value ,r-error 'call-error 'error)))
                  (unless (= ,call-error +call-ok+)
                    (error "Calling ~a failed with call error ~d" ',name ,call-error)))
                ,(when has-return-value
                   `(progn
                      (call-type-from-variant-constructor
                       (aref *type-from-variant-constructors* ,return-type) ,r-ret ,r-return)
                      ,(let ((destroy-form (engine-value-destroy-form return-type r-ret)))
                         (if destroy-form
                             `(unwind-protect ,(engine-value-read-form return-type r-ret)
                                ,destroy-form)
                             (engine-value-read-form return-type r-ret))))))
           (dotimes (i ,argument-count)
             (variant-destroy (element-pointer ,variants 'variant i)))
           (variant-destroy ,r-return)))))

  (defun engine-method-defun (name class-name method-name hash arguments return-type
                              body-form-function)
    "The DEFUN of NAME for DEFINE-ENGINE-METHOD and DEFINE-ENGINE-VARARG-METHOD.
BODY-FORM-FUNCTION makes the code that calls the method, given the variables
with the method bind and the object, the parsed arguments and the return type."
    (let ((return-type (eval return-type))
          (arguments (loop for (arg-name type . default) in arguments
                           for variant-type = (eval type)
                           collect (list arg-name variant-type default
                                         (engine-value-ffi-type variant-type)
                                         (gensym (symbol-name arg-name)))))
          (object (gensym "OBJECT"))
          (method-bind (gensym "METHOD-BIND")))
      `(defun ,name (,object
                     ,@(loop for (arg-name nil default) in arguments
                             unless default collect arg-name)
                     ,@(when (some #'third arguments) '(&optional))
                     ,@(loop for (arg-name nil default) in arguments
                             when default collect (list arg-name (first default))))
         (let ((,method-bind (car (load-time-value
                                   (make-initialize-cell
                                    (lambda () (lookup-method-bind ,class-name ,method-name ,hash)))))))
           (unless ,method-bind
             (error "The method ~a.~a wasn't found" ,class-name ,method-name))
           ,(funcall body-form-function method-bind object arguments return-type))))))

(defun lookup-method-bind (class-name method-name hash)
  (let ((method-bind (get-method-bind class-name method-name hash)))
    (if (ffi:null-pointer-p method-bind)
        (progn (format t "~&Error: no method ~a.~a with hash ~d~%" class-name method-name hash)
               nil)
        method-bind)))

(defmacro define-engine-method (name (class-name method-name hash)
                                &key arguments (return-type '+variant-type-nil+))
  "Define NAME as a function that calls the method METHOD-NAME of the Godot class
CLASS-NAME with ptrcall. The function takes the Godot object pointer and then
the method's arguments as Lisp values, and returns the result as a Lisp value.
HASH is the hash of the method from extension_api.json. ARGUMENTS is a list of
(name variant-type) or (name variant-type default); arguments with a default
are optional. RETURN-TYPE is the variant type of the result (+VARIANT-TYPE-NIL+
for none; int for an enum). Supported types: bool, int, float, Vector2;
StringName and NodePath as arguments (pointers to them, see SNAME and NPATH);
:VARIANT as an argument for a Variant, converted from the Lisp value by its
type (see WRITE-VARIANT); Rect2 and Object (a Godot object pointer) as results.

For vararg methods, use DEFINE-ENGINE-VARARG-METHOD."
  (engine-method-defun name class-name method-name hash arguments return-type
                       (lambda (method-bind object arguments return-type)
                         (ptrcall-method-form method-bind object arguments return-type))))

(defmacro define-engine-vararg-method (name (class-name method-name hash)
                                       &key arguments (return-type '+variant-type-nil+))
  "Like DEFINE-ENGINE-METHOD, for a vararg method (is_vararg in
extension_api.json), such as emit_signal. Vararg methods can't be called with
ptrcall; the function converts the arguments and the result to and from
Variants, and signals an error if the call fails. Only the arguments in
ARGUMENTS can be passed so far, no extra ones."
  (engine-method-defun name class-name method-name hash arguments return-type
                       (lambda (method-bind object arguments return-type)
                         (variant-call-method-form method-bind object arguments return-type
                                                   name))))

;;;
;;; References
;;;
;;; An engine method that returns a RefCounted object, such as a Resource,
;;; returns it with a reference that the caller owns, like a Ref<T> in C++.
;;; Give it back with RELEASE-REFERENCE, or use WITH-REFERENCE. To keep a
;;; RefCounted object that Lisp didn't get from an engine method, e.g. one passed
;;; to a bound method, take a reference with ADD-REFERENCE.
;;;

(define-engine-method ref-counted-reference ("RefCounted" "reference" 2240911060)
  :return-type +variant-type-bool+)

(define-engine-method ref-counted-unreference ("RefCounted" "unreference" 2240911060)
  :return-type +variant-type-bool+)

(defun add-reference (object)
  "Take a reference to the RefCounted OBJECT (a Godot object pointer, or NULL), to
keep it alive while Lisp holds on to it. Give it back with RELEASE-REFERENCE.
Returns OBJECT."
  (unless (ffi:null-pointer-p object)
    (ref-counted-reference object))
  object)

(defun release-reference (object)
  "Give back a reference to the RefCounted OBJECT (a Godot object pointer, or
NULL), and destroy the object if it was the last one, like the destructor of
Ref<T>."
  (unless (ffi:null-pointer-p object)
    (when (ref-counted-unreference object)
      (object-destroy object))))

(defmacro with-reference ((var form) &body body)
  "Evaluate BODY with VAR bound to the RefCounted object (a Godot object pointer)
returned by FORM, a call of an engine method, and give the reference back when
BODY exits, also on a non-local exit."
  `(let ((,var ,form))
     (unwind-protect (progn ,@body)
       (release-reference ,var))))

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

(defun bind-property (class-name name type getter setter
                      &key (hint +property-hint-none+) (hint-string "") (property-class-name ""))
  "Register the property NAME of the class CLASS-NAME, of the variant type TYPE,
with the bound methods GETTER and SETTER (method names). HINT and HINT-STRING
tell the editor how to edit it, e.g. +PROPERTY-HINT-RESOURCE-TYPE+ and
\"PackedScene\" for a resource of that class, like @export var x: PackedScene
in GDScript; PROPERTY-CLASS-NAME is then the class name too."
  (with-string-name (class-string-name class-name)
    (ffi:with-foreign-object (info 'property-info)
      (make-property-full info type name hint hint-string property-class-name
                          +property-usage-default+)
      (with-string-name (getter-name getter)
        (with-string-name (setter-name setter)
          (classdb-register-extension-class-property *class-library* class-string-name
                                                     info setter-name getter-name)))
      (destruct-property info))))

(defun bind-signal (class-name signal-name &optional arguments)
  "Register the signal SIGNAL-NAME of the class CLASS-NAME, like signal in
GDScript. ARGUMENTS is a list of (name variant-type), as in BIND-METHOD; a
signal without arguments has none."
  (let ((argument-count (length arguments)))
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

(defun register-class (class-name parent-class-name
                       &key (constructor #'identity) destructor tool)
  "Register the class CLASS-NAME, which inherits from the class
PARENT-CLASS-NAME (both strings). When Godot creates an instance, CONSTRUCTOR
is called with the Godot object pointer, and returns the instance's Lisp object
(see INSTANCE-OBJECT); the default is the object pointer itself. When Godot
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
    class-name))

(defun bind-virtual (class-name virtual-name function
                     &key (return-type +variant-type-nil+) arguments)
  "Make FUNCTION the class CLASS-NAME's implementation of the virtual method
VIRTUAL-NAME, such as \"_ready\" or \"_process\". ARGUMENTS and RETURN-TYPE
must match the virtual method's signature (see extension_api.json), and are
given as in BIND-METHOD. FUNCTION is called with the instance's Lisp object and
the arguments as Lisp values. Call it after REGISTER-CLASS, before Godot
creates any instances of the class."
  (add-virtual class-name
               (new-string-name virtual-name)
               (register-method function :return-type return-type
                                         :argument-types (mapcar #'second arguments))))
