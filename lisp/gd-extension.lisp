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
;;; Helpers
;;;

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun variant-type (designator)
    "The variant type designated by DESIGNATOR: a variant type (an integer, such
as +VARIANT-TYPE-FLOAT+), or a keyword named like one, such as :FLOAT, :VECTOR2,
:STRING-NAME or :PACKED-STRING-ARRAY."
    (etypecase designator
      (integer designator)
      (keyword
       (let ((symbol (find-symbol (format nil "+VARIANT-TYPE-~a+" (symbol-name designator))
                                  :gd-extension-ffi)))
         (if (and symbol
                  (not (eq designator :variant-max))
                  (eq (nth-value 1 (find-symbol (symbol-name symbol) :gd-extension-ffi))
                      :external))
             (symbol-value symbol)
             (error "No variant type ~s" designator)))))))

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
;;; time, since there's no Godot then. They're kept in initialize cells (see
;;; GD-EXTENSION-CALLBACK:MAKE-INITIALIZE-CELL), conses whose car is computed
;;; when Godot initializes the extension; code gets the cons with
;;; LOAD-TIME-VALUE, so it's made when the code is loaded, and the car is ready
;;; when the code runs.
;;;

;; The StringNames and NodePaths made by NEW-STRING-NAME and NEW-NODE-PATH,
;; destroyed by DESTROY-PERMANENT-VALUES when Godot unloads the extension
(defvar *permanent-string-names* '())
(defvar *permanent-node-paths* '())

(defun new-string-name (contents)
  "A StringName created from the string CONTENTS, in memory from MEM-ALLOC. Kept
until Godot unloads the extension."
  (let ((string-name (mem-alloc +string-name-size+)))
    (string-name-new-with-latin1-chars string-name contents)
    (push string-name *permanent-string-names*)
    string-name))

(defmacro sname (string)
  "A pointer to a StringName with STRING, a literal string. The StringName is
created once, like SNAME() in Godot's C++ code, and kept until Godot unloads the
extension."
  `(car (load-time-value (make-initialize-cell (lambda () (new-string-name ,string))))))

(defun new-node-path (path)
  "A NodePath created from the string PATH, in memory from MEM-ALLOC. Kept until
Godot unloads the extension."
  (let ((node-path (mem-alloc +node-path-size+)))
    (with-string (string path)
      (ffi:with-foreign-object (args '(:array :pointer-void 1))
        (setf (foreign-ref args :pointer-void 0) string)
        ;; Constructor 2 of NodePath takes a String
        (call-ptr-constructor (variant-get-ptr-constructor +variant-type-node-path+ 2)
                              node-path args)))
    (push node-path *permanent-node-paths*)
    node-path))

(defun destroy-permanent-values ()
  "Destroy the StringNames and NodePaths made by NEW-STRING-NAME and
NEW-NODE-PATH, and free their memory, so that Godot doesn't report them as
leaked. A deinitialize hook: it's added when this file is loaded, before the
application adds its hooks, so it runs after them. Afterwards, SNAME and NPATH
values must not be used any more."
  (dolist (string-name *permanent-string-names*)
    (string-name-destructor string-name)
    (mem-free string-name))
  (dolist (node-path *permanent-node-paths*)
    (node-path-destructor node-path)
    (mem-free node-path))
  (setf *permanent-string-names* '()
        *permanent-node-paths* '()))

(add-deinitialize-hook 'destroy-permanent-values)

(defmacro npath (path)
  "A pointer to a NodePath with PATH, a literal string, like ^\"path\" in GDScript.
The NodePath is created once and kept until Godot unloads the extension."
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
;;; class with ptrcall (or with Variants, for a vararg method). The method's hash
;;; and signature are looked up in extension_api.json (see extension-api.lisp)
;;; when the macro is expanded. The method bind is looked up once, in an
;;; initialize cell, and the code that converts the arguments and the result is
;;; generated for each type when the macro is expanded.
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

  (defun wrap-literal-names (name arguments positions)
    "The call of the engine method NAME with ARGUMENTS (forms), for its compiler
macro: each literal string at one of POSITIONS, a list of (index . macro), is
wrapped in the macro (SNAME or NPATH), so the StringName or NodePath is created
once. NIL if there's nothing to wrap, so the call is left as it is."
    (when (loop for (i) in positions
                thereis (stringp (nth i arguments)))
      `(,name ,@(loop for argument in arguments
                      for i from 0
                      for macro = (cdr (assoc i positions))
                      collect (if (and macro (stringp argument))
                                  `(,macro ,argument)
                                  argument)))))

  (defun engine-method-argument-symbol (name)
    "The symbol for the argument NAME, a string from extension_api.json, in the
lambda list of an engine method: NAME in Lisp style, in the current package."
    (let ((symbol (intern (string-upcase (substitute #\- #\_ name)))))
      ;; Such as T
      (if (constantp symbol)
          (intern (concatenate 'string (symbol-name symbol) "-ARGUMENT"))
          symbol)))

  (defun engine-method-variant-type (type what)
    "The variant type of TYPE (a type name from extension_api.json) of WHAT, the
name of an argument or \"the result\", if engine methods support it."
    (let ((variant-type (api-variant-type type)))
      (unless (ignore-errors (find-value-type variant-type))
        (error "Unsupported type ~a of ~a" type what))
      variant-type))

  (defun engine-method-arguments (method)
    "The arguments of METHOD (a method from extension_api.json), as a list of
(symbol variant-type default), where DEFAULT is a list of the form for the
default value, or NIL if the argument is required. Only the last arguments with
supported default values become optional."
    (let* ((arguments (json-get method "arguments"))
           (types (mapcar (lambda (argument)
                            (engine-method-variant-type (json-get argument "type")
                                                        (json-get argument "name")))
                          arguments))
           (defaults (mapcar (lambda (argument type)
                               (let ((default (json-get argument "default_value")))
                                 (and default (api-default-form default type))))
                             arguments types))
           (first-optional (1+ (or (position nil defaults :from-end t) -1))))
      (loop for argument in arguments
            for type in types
            for default in defaults
            for i from 0
            collect (list (engine-method-argument-symbol (json-get argument "name"))
                          type
                          (and (>= i first-optional) default)))))

  (defun engine-method-defun (name class-name method-name extra-arguments)
    "The DEFUN of NAME for DEFINE-ENGINE-METHOD, with the method's hash and
signature from extension_api.json."
    (multiple-value-bind (method defining-class) (api-method class-name method-name)
      (when (json-get method "is_virtual")
        (error "~a.~a is a virtual method, which can't be called through a method bind"
               class-name method-name))
      (let* ((vararg (json-get method "is_vararg"))
             (static (json-get method "is_static"))
             (hash (json-get method "hash"))
             (return-value (json-get method "return_value"))
             (return-type (if return-value
                              (engine-method-variant-type (json-get return-value "type")
                                                          "the result")
                              +variant-type-nil+))
             (arguments (engine-method-arguments method)))
        (when (eql return-type :variant)
          (error "Variant results aren't supported yet"))
        (when extra-arguments
          (unless vararg
            (error "~a.~a isn't a vararg method, so it takes no extra arguments"
                   class-name method-name))
          ;; The extra arguments come after the declared ones, which are then
          ;; all required
          (setf arguments (append (loop for (arg-name type nil) in arguments
                                        collect (list arg-name type nil))
                                  (loop for (arg-name type) in extra-arguments
                                        collect (list arg-name (variant-type (eval type)) nil)))))
        (let ((arguments (loop for (arg-name variant-type default) in arguments
                               collect (list arg-name variant-type default
                                             (engine-value-ffi-type variant-type)
                                             (gensym (symbol-name arg-name)))))
              (object (gensym "OBJECT"))
              (method-bind (gensym "METHOD-BIND"))
              ;; The positions in a call of the StringName and NodePath
              ;; arguments, which can be given as literal strings
              (name-positions (loop for (nil variant-type) in arguments
                                    for i from (if static 0 1)
                                    when (eql variant-type +variant-type-string-name+)
                                      collect (cons i 'sname)
                                    when (eql variant-type +variant-type-node-path+)
                                      collect (cons i 'npath))))
          `(progn
            (defun ,name (,@(unless static (list object))
                          ,@(loop for (arg-name nil default) in arguments
                                  unless default collect arg-name)
                          ,@(when (some #'third arguments) '(&optional))
                          ,@(loop for (arg-name nil default) in arguments
                                  when default collect (list arg-name (first default))))
              ,(format nil "Call ~:[~;the static method ~]~a.~a(~{~a~^, ~})~@[ with ~a~]."
                       static defining-class method-name
                       (mapcar (lambda (argument) (json-get argument "name"))
                               (json-get method "arguments"))
                       (and vararg "Variants"))
              (let ((,object ,(if static
                                 '(ffi:make-null-pointer :void)
                                 `(object-pointer ,object)))
                    (,method-bind (car (load-time-value
                                        (make-initialize-cell
                                         (lambda ()
                                           (lookup-method-bind ,defining-class ,method-name ,hash)))))))
                (unless ,method-bind
                  (error "The method ~a.~a wasn't found" ,defining-class ,method-name))
                ,(if vararg
                     (variant-call-method-form method-bind object arguments return-type name)
                     (ptrcall-method-form method-bind object arguments return-type))))
            ,@(when name-positions
                `((define-compiler-macro ,name (&whole form &rest arguments)
                    (or (wrap-literal-names ',name arguments ',name-positions)
                        form))))))))))

(defun lookup-method-bind (class-name method-name hash)
  (let ((method-bind (get-method-bind class-name method-name hash)))
    (if (ffi:null-pointer-p method-bind)
        (progn (format t "~&Error: no method ~a.~a with hash ~d~%" class-name method-name hash)
               nil)
        method-bind)))

(defmacro define-engine-method (name (class-name method-name) &key extra-arguments)
  "Define NAME as a function that calls the method METHOD-NAME of the Godot class
CLASS-NAME (or a class it inherits from). The method's hash, arguments and
return type are looked up in extension_api.json when the macro is expanded.
The function takes the Godot object (a pointer or a GODOT-OBJECT; none if the
method is static) and then the method's arguments as Lisp values, and returns the result as a Lisp
value. Arguments with a default value are optional, if the default can be
expressed in Lisp (bool, int, float, String, StringName, NodePath, Vector2 and
null). The arguments are named as in extension_api.json, in Lisp style.

Supported types: bool, int (also enums and bitfields), float, Vector2, String
(a Lisp string), Callable (a CALLABLE), StringName and NodePath as arguments
(pointers to them, see SNAME and NPATH), Variant as an argument (converted from
the Lisp value by its type, see WRITE-VARIANT), Object (a Godot object pointer
or a GODOT-OBJECT), and Rect2 and PackedStringArray (a list of strings) as
results. An Object result is the Lisp object of an instance of an extension
class (see LISP-OBJECT), and otherwise the Godot object pointer.

A StringName or NodePath argument can also be given as a literal string in a
call, e.g. (EMIT-SIGNAL OBJECT \"hit\"): a compiler macro wraps it in SNAME or
NPATH, so it's created once, not at every call.

The method is called with ptrcall, except for vararg methods (such as
emit_signal), which are called with Variants; a failed call signals an error.
EXTRA-ARGUMENTS, for a vararg method, is a list of (name type) for
arguments after the declared ones, e.g. ((position :vector2)) for
emit_signal(signal, position); TYPE is as in VARIANT-TYPE."
  (handler-case (engine-method-defun name class-name method-name extra-arguments)
    (error (e)
      (error "In (DEFINE-ENGINE-METHOD ~s (~s ~s)): ~a" name class-name method-name e))))

;;;
;;; References
;;;
;;; An engine method that returns a RefCounted object, such as a Resource,
;;; returns it with a reference that the caller owns, like a Ref<T> in C++.
;;; Give it back with RELEASE-REFERENCE, or use WITH-REFERENCE. To keep a
;;; RefCounted object that Lisp didn't get from an engine method, e.g. one passed
;;; to a bound method, take a reference with ADD-REFERENCE.
;;;

(define-engine-method ref-counted-reference ("RefCounted" "reference"))

(define-engine-method ref-counted-unreference ("RefCounted" "unreference"))

(defun add-reference (object)
  "Take a reference to the RefCounted OBJECT (a Godot object pointer, or NULL), to
keep it alive while Lisp holds on to it. Give it back with RELEASE-REFERENCE.
Returns OBJECT."
  (unless (ffi:null-pointer-p (object-pointer object))
    (ref-counted-reference object))
  object)

(defun release-reference (object)
  "Give back a reference to the RefCounted OBJECT (a Godot object pointer, or
NULL), and destroy the object if it was the last one, like the destructor of
Ref<T>."
  (let ((pointer (object-pointer object)))
    (unless (ffi:null-pointer-p pointer)
      (when (ref-counted-unreference pointer)
        (object-destroy pointer)))))

(defmacro with-reference ((var form) &body body)
  "Evaluate BODY with VAR bound to the RefCounted object (a Godot object pointer)
returned by FORM, a call of an engine method, and give the reference back when
BODY exits, also on a non-local exit."
  `(let ((,var ,form))
     (unwind-protect (progn ,@body)
       (release-reference ,var))))

;;;
;;; Signals
;;;
;;; CONNECT-SIGNAL connects a signal to a Lisp function, through a custom
;;; Callable (see GD-EXTENSION-TYPES:CALLABLE). AFTER-SIGNAL does it once, for
;;; what GDScript does with await.
;;;

;; Object.ConnectFlags
(defconstant +connect-deferred+ 1)
(defconstant +connect-one-shot+ 4)

(define-engine-method object-connect ("Object" "connect"))

(defun connect-signal (object signal-name function &key (target object) (flags 0))
  "Connect the signal SIGNAL-NAME (a StringName, see SNAME, or a literal string)
of OBJECT to the Lisp FUNCTION, which is called with the signal's arguments as
Lisp values, like signal.connect(callable, flags) in GDScript. The connection
is bound to TARGET (a Godot object or its Lisp object, by default OBJECT): it's
removed when TARGET is freed. FLAGS are Object.ConnectFlags, such as
+CONNECT-ONE-SHOT+. Returns Godot's error code."
  (object-connect object signal-name (callable target function) flags))

;; A literal string as SIGNAL-NAME becomes (SNAME string), as for engine methods
(define-compiler-macro connect-signal (&whole form &rest arguments)
  (or (wrap-literal-names 'connect-signal arguments '((1 . sname)))
      form))

(defmacro after-signal ((object signal-name &key target) &body body)
  "Evaluate BODY once, the next time OBJECT emits the signal SIGNAL-NAME (a
StringName, see SNAME, or a literal string), like the code after await object.signal_name in GDScript.
Returns right away. TARGET is as in CONNECT-SIGNAL; with TARGET the object that
the code belongs to, BODY isn't run if that object has been freed by then."
  (let ((object-var (gensym "OBJECT")))
    `(let ((,object-var ,object))
       (connect-signal ,object-var ,signal-name
                       (lambda (&rest arguments)
                         (declare (ignore arguments))
                         ,@body)
                       :target ,(or target object-var)
                       :flags +connect-one-shot+))))

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

(defun inherits-class-p (class-name parent-class-name)
  "True if the class CLASS-NAME is PARENT-CLASS-NAME or inherits from it (both
strings)."
  (with-string-name (class-string-name class-name)
    (with-string-name (parent-string-name parent-class-name)
      (class-db-is-parent-class (singleton "ClassDB") class-string-name parent-string-name))))

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
                    (error (e)
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
