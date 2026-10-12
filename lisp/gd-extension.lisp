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

(defun construct-node-path (pointer path)
  "Construct a NodePath at POINTER, uninitialized memory, from the string PATH.
Destroy it with NODE-PATH-DESTRUCTOR."
  (with-string (string path)
    (ffi:with-foreign-object (args '(:array :pointer-void 1))
      (setf (foreign-ref args :pointer-void 0) string)
      ;; Constructor 2 of NodePath takes a String
      (call-ptr-constructor (car (load-time-value
                                  (make-initialize-cell
                                   (lambda ()
                                     (variant-get-ptr-constructor +variant-type-node-path+ 2)))))
                            pointer args))))

(defun new-node-path (path)
  "A NodePath created from the string PATH, in memory from MEM-ALLOC. Kept until
Godot unloads the extension."
  (let ((node-path (mem-alloc +node-path-size+)))
    (construct-node-path node-path path)
    (push node-path *permanent-node-paths*)
    node-path))

(defun make-temporary-name (variant-type string)
  "A StringName or NodePath (by VARIANT-TYPE) created from the Lisp STRING, in
memory from MEM-ALLOC, for a call of an engine method with a string that's only
known at runtime. Destroy it with DESTROY-TEMPORARY-NAME."
  (if (= variant-type +variant-type-string-name+)
      (let ((string-name (mem-alloc +string-name-size+)))
        (string-name-new-with-utf8-chars string-name string)
        string-name)
      (let ((node-path (mem-alloc +node-path-size+)))
        (construct-node-path node-path string)
        node-path)))

(defun destroy-temporary-name (variant-type name)
  "Destroy NAME, made by MAKE-TEMPORARY-NAME, and free its memory."
  (if (= variant-type +variant-type-string-name+)
      (string-name-destructor name)
      (node-path-destructor name))
  (mem-free name))

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

  (defun ptrcall-method-form (method-bind object arguments return-type &key utility)
    "The code of a DEFINE-ENGINE-METHOD function that calls METHOD-BIND with
ptrcall, with ARGUMENTS as in DEFINE-ENGINE-METHOD. If UTILITY is true,
METHOD-BIND is a utility function (see DEFINE-UTILITY-FUNCTIONS) instead, and
OBJECT isn't used."
    (let ((has-return-value (not (eql return-type +variant-type-nil+)))
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
                         ,(let ((r-ret (if has-return-value r-ret '(ffi:make-null-pointer :void))))
                            (if utility
                                `(call-ptr-utility-function ,method-bind ,r-ret ,args
                                                            ,(length arguments))
                                `(object-method-bind-ptrcall ,method-bind ,object ,args ,r-ret)))
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

  (defun variant-call-method-form (method-bind object arguments return-type name rest
                                   &key utility)
    "The code of a DEFINE-ENGINE-METHOD function that calls METHOD-BIND, a vararg
method, with object_method_bind_call, with the arguments and the result as
Variants. REST, if not NIL, is the variable with the list of further arguments,
converted to Variants by their Lisp types (see WRITE-VARIANT). If UTILITY is
true, METHOD-BIND is a vararg utility function (see DEFINE-UTILITY-FUNCTIONS)
instead, which takes Variants and returns a raw value of its return type, and
OBJECT isn't used."
    (let ((has-return-value (not (eql return-type +variant-type-nil+)))
          (declared-count (length arguments))
          (count (gensym "COUNT"))
          (args (gensym "ARGS"))
          (variants (gensym "VARIANTS"))
          (r-return (gensym "R-RETURN"))
          (r-error (gensym "R-ERROR"))
          (r-ret (gensym "R-RET"))
          (call-error (gensym "CALL-ERROR")))
      (flet ((array-type (element-type)
               ;; Known when the macro is expanded, unless there are REST
               ;; arguments
               (if rest
                   `(list :array ',element-type (max 1 ,count))
                   `'(:array ,element-type ,(max 1 declared-count)))))
        `(let ((,count ,(if rest `(+ ,declared-count (length ,rest)) declared-count)))
           (ffi:with-foreign-objects ((,args ,(array-type :pointer-void))
                                      (,variants ,(array-type 'variant))
                                      ,@(loop for (nil nil nil ffi-type raw) in arguments
                                              when ffi-type collect `(,raw ',ffi-type))
                                      ,@(unless utility
                                          `((,r-return 'variant)
                                            (,r-error 'call-error)))
                                      ,@(when (and has-return-value
                                                   (or utility (not (eql return-type :variant))))
                                          `((,r-ret ',(engine-value-ffi-type return-type)))))
             ;; All Nil, so they can all be destroyed, also if making one fails
             (clear-foreign-object ,variants ,(array-type 'variant))
             ;; Godot always initializes r_ret, also when the call fails
             (unwind-protect
                  (progn
                    ,@(loop for (arg-name type nil ffi-type raw) in arguments
                            for i from 0
                            for variant = `(element-pointer ,variants 'variant ,i)
                            if (eql type :variant)
                              ;; Already any Variant: constructed right in the array
                              collect `(write-variant ,variant ,arg-name)
                            else
                              collect (let ((construct `(call-variant-from-type-constructor
                                                         (aref *variant-from-type-constructors* ,type)
                                                         ,variant
                                                         ,(if ffi-type raw arg-name)))
                                            (destroy (and ffi-type (engine-value-destroy-form type raw))))
                                        (cond ((not ffi-type) construct)
                                              ;; The Variant gets a copy of the raw value
                                              (destroy `(progn ,(engine-value-write-form type raw arg-name)
                                                               (unwind-protect ,construct ,destroy)))
                                              (t `(progn ,(engine-value-write-form type raw arg-name)
                                                         ,construct))))
                            end
                            collect `(setf (foreign-ref ,args :pointer-void ,i) ,variant))
                    ,@(when rest
                        `((loop for value in ,rest
                                for i from ,declared-count
                                for variant = (element-pointer ,variants 'variant i)
                                do (write-variant variant value)
                                   (setf (foreign-ref ,args :pointer-void i) variant))))
                    ,@(if utility
                          `(,@(when has-return-value
                                `((clear-foreign-object ,r-ret ',(engine-value-ffi-type return-type))))
                            (call-ptr-utility-function ,method-bind
                                                       ,(if has-return-value
                                                            r-ret
                                                            '(ffi:make-null-pointer :void))
                                                       ,args ,count))
                          `((object-method-bind-call ,method-bind ,object ,args ,count
                                                     ,r-return ,r-error)
                            (let ((,call-error (ffi:get-slot-value ,r-error 'call-error 'error)))
                              (unless (= ,call-error +call-ok+)
                                (error "Calling ~a failed with call error ~d" ',name ,call-error)))))
                    ,(flet ((read-raw-result ()
                              ;; The raw value at R-RET, destroyed afterwards
                              (let ((destroy-form (engine-value-destroy-form return-type r-ret)))
                                (if destroy-form
                                    `(unwind-protect ,(engine-value-read-form return-type r-ret)
                                       ,destroy-form)
                                    (engine-value-read-form return-type r-ret)))))
                       (cond ((not has-return-value) nil)
                             (utility (read-raw-result))
                             ((eql return-type :variant) `(read-variant-result ,r-return))
                             (t
                              `(progn
                                 (call-type-from-variant-constructor
                                  (aref *type-from-variant-constructors* ,return-type) ,r-ret ,r-return)
                                 ,(read-raw-result))))))
               (dotimes (i ,count)
                 (variant-destroy (element-pointer ,variants 'variant i)))
               ,@(unless utility
                   `((variant-destroy ,r-return)))))))))

  (defun temporary-names-form (arguments form)
    "FORM, the call of an engine method with ARGUMENTS (as in
ENGINE-METHOD-DEFUN), wrapped in code that turns each StringName or NodePath
argument that's a Lisp string at runtime into a temporary one, destroyed after
the call."
    (loop for (arg-name type) in (reverse arguments)
          when (or (eql type +variant-type-string-name+) (eql type +variant-type-node-path+))
            do (let ((temporary (gensym "TEMPORARY")))
                 (setf form
                       `(let* ((,temporary (and (stringp ,arg-name)
                                                (make-temporary-name ,type ,arg-name)))
                               (,arg-name (or ,temporary ,arg-name)))
                          (unwind-protect ,form
                            (when ,temporary
                              (destroy-temporary-name ,type ,temporary)))))))
    form)

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
             ;; A method of a singleton's class is called on the singleton
             (singleton (and (not static) (api-singleton defining-class)))
             (hash (json-get method "hash"))
             (return-value (json-get method "return_value"))
             (return-type (if return-value
                              (engine-method-variant-type (json-get return-value "type")
                                                          "the result")
                              +variant-type-nil+))
             (arguments (engine-method-arguments method)))
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
              ;; Further arguments of a vararg method, unless they're declared
              ;; with EXTRA-ARGUMENTS
              (rest (and vararg (not extra-arguments) (intern "ARGUMENTS")))
              (object (gensym "OBJECT"))
              (method-bind (gensym "METHOD-BIND"))
              ;; The positions in a call of the StringName and NodePath
              ;; arguments, which can be given as literal strings
              (name-positions (loop for (nil variant-type) in arguments
                                    for i from (if (or static singleton) 0 1)
                                    when (eql variant-type +variant-type-string-name+)
                                      collect (cons i 'sname)
                                    when (eql variant-type +variant-type-node-path+)
                                      collect (cons i 'npath))))
          `(progn
            (defun ,name (,@(unless (or static singleton) (list object))
                          ,@(loop for (arg-name nil default) in arguments
                                  unless default collect arg-name)
                          ,@(when (some #'third arguments) '(&optional))
                          ,@(loop for (arg-name nil default) in arguments
                                  when default collect (list arg-name (first default)))
                          ,@(when rest `(&rest ,rest)))
              ,(format nil "Call ~:[~;the static method ~]~a.~a(~{~a~^, ~})~@[ with ~a~]~
                            ~@[ on the singleton ~a~]."
                       static defining-class method-name
                       (append (mapcar (lambda (argument) (json-get argument "name"))
                                       (json-get method "arguments"))
                               (and rest '("...")))
                       (and vararg "Variants")
                       singleton)
              (let ((,object ,(cond (static '(ffi:make-null-pointer :void))
                                    (singleton `(singleton ,singleton))
                                    (t `(object-pointer ,object))))
                    (,method-bind (car (load-time-value
                                        (make-initialize-cell
                                         (lambda ()
                                           (lookup-method-bind ,defining-class ,method-name ,hash)))))))
                (unless ,method-bind
                  (error "The method ~a.~a wasn't found" ,defining-class ,method-name))
                ,(temporary-names-form
                  arguments
                  (if vararg
                      (variant-call-method-form method-bind object arguments return-type name rest)
                      (ptrcall-method-form method-bind object arguments return-type)))))
            ,@(when name-positions
                `((define-compiler-macro ,name (&whole form &rest arguments)
                    (or (wrap-literal-names ',name arguments ',name-positions)
                        form))))))))))

(defun lookup-method-bind (class-name method-name hash)
  "The method bind of CLASS-NAME.METHOD-NAME with HASH, for an initialize cell.
Signals an error if Godot has no such method, which INITIALIZE reports like
Godot's own errors."
  (let ((method-bind (get-method-bind class-name method-name hash)))
    (when (ffi:null-pointer-p method-bind)
      (error "Godot has no method ~a.~a with hash ~d. Was extension_api.json ~
dumped from another version of Godot? Run make godot-api."
             class-name method-name hash))
    method-bind))

(defmacro define-engine-method (name (class-name method-name) &key extra-arguments)
  "Define NAME as a function that calls the method METHOD-NAME of the Godot class
CLASS-NAME (or a class it inherits from). The method's hash, arguments and
return type are looked up in extension_api.json when the macro is expanded.
The function takes the Godot object (a pointer or a GODOT-OBJECT; none if the
method is static, or if the class is an engine singleton's, such as Input,
whose methods are called on the singleton) and then the method's arguments as
Lisp values, and returns the result as a Lisp value. Arguments with a default
value are optional, if the default can be expressed in Lisp (bool, int, float,
String, StringName, NodePath, Vector2 and null). The arguments are named as in
extension_api.json, in Lisp style.

Supported types: bool, int (also enums and bitfields), float, Vector2, String
(a Lisp string), Callable (a CALLABLE), StringName and NodePath as arguments
(pointers to them, see SNAME and NPATH), Variant (an argument is converted from
the Lisp value by its type, see WRITE-VARIANT, and a result by its type, see
READ-VARIANT), Object (a Godot object pointer or a GODOT-OBJECT; NIL is null),
and Rect2 and PackedStringArray (a list of strings) as results. An Object
result is the Lisp object of an instance of an extension class (see
LISP-OBJECT), and otherwise the Godot object pointer.

A StringName or NodePath argument can also be given as a literal string in a
call, e.g. (OBJECT-EMIT-SIGNAL OBJECT \"hit\"): a compiler macro wraps it in
SNAME or NPATH, so it's created once, not at every call. Any other Lisp string
is turned into a temporary StringName or NodePath for the call.

The method is called with ptrcall, except for vararg methods (such as
emit_signal), which are called with Variants; a failed call signals an error.
The function of a vararg method takes any number of further arguments,
converted to Variants by their Lisp types (see WRITE-VARIANT), e.g.
(OBJECT-EMIT-SIGNAL PLAYER \"hit\" DAMAGE). Or EXTRA-ARGUMENTS declares them
with their types, as a list of (name type), e.g. ((position :vector2)) for
emit_signal(signal, position); TYPE is as in VARIANT-TYPE."
  (handler-case (engine-method-defun name class-name method-name extra-arguments)
    (error (e)
      (error "In (DEFINE-ENGINE-METHOD ~s (~s ~s)): ~a" name class-name method-name e))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun lisp-style-class-name (class-name)
    "The name of the engine class CLASS-NAME in Lisp style, as in the names of the
functions of DEFINE-ENGINE-CLASS: \"Node2D\" becomes \"NODE-2D\",
\"AnimatedSprite2D\" \"ANIMATED-SPRITE-2D\" and \"HTTPRequest\" \"HTTP-REQUEST\"."
    (with-output-to-string (out)
      (loop for i from 0 below (length class-name)
            for char = (char class-name i)
            for previous = (and (> i 0) (char class-name (1- i)))
            for next = (and (< (1+ i) (length class-name)) (char class-name (1+ i)))
            do (when (and previous
                          (or
                           ;; nodeP
                           (and (upper-case-p char) (lower-case-p previous))
                           ;; HTTPRequest
                           (and (upper-case-p char) (upper-case-p previous)
                                next (lower-case-p next))
                           ;; Node2D
                           (and (digit-char-p char) (alpha-char-p previous))))
                 (write-char #\- out))
               (write-char (char-upcase char) out))))

  (defun lisp-style-method-name (method-name)
    "The name of the method METHOD-NAME in Lisp style: \"get_node\" becomes
\"GET-NODE\"."
    (string-upcase (substitute #\- #\_ method-name))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun constant-defconstant (prefix name value documentation)
    "The name of the constant NAME (a string from extension_api.json, such as
\"PROCESS_MODE_ALWAYS\") in Lisp style, with PREFIX (a string such as \"NODE\",
or NIL), interned in the current package, and the DEFCONSTANT of it."
    (let ((symbol (intern (format nil "+~@[~a-~]~a+" prefix (lisp-style-method-name name)))))
      (values symbol `(defconstant ,symbol ,value ,documentation))))

  (defun class-constant-defconstants (class)
    "The names and DEFCONSTANTs of the enum values and constants of CLASS, a JSON
object from extension_api.json, as two lists."
    (let ((class-name (json-get class "name"))
          (prefix (lisp-style-class-name (json-get class "name")))
          (names '())
          (forms '()))
      (flet ((add (name value documentation)
               (multiple-value-bind (symbol form)
                   (constant-defconstant prefix name value documentation)
                 (push symbol names)
                 (push form forms))))
        (dolist (enum (json-get class "enums"))
          (dolist (value (json-get enum "values"))
            (add (json-get value "name") (json-get value "value")
                 (format nil "~a.~a, of the enum ~a." class-name (json-get value "name")
                         (json-get enum "name")))))
        (dolist (constant (json-get class "constants"))
          (add (json-get constant "name") (json-get constant "value")
               (format nil "The constant ~a.~a." class-name (json-get constant "name")))))
      (values (reverse names) (reverse forms)))))

(defmacro define-engine-class (class-name)
  "Define a function for each method of the engine class CLASS-NAME (a string)
that DEFINE-ENGINE-METHOD can call, named after the class and the method in
Lisp style, and exported from the package GODOT: Node2D.get_position becomes
GODOT:NODE-2D-GET-POSITION. Only the methods the class itself defines get
functions, not those it inherits, so call get_position of a Sprite2D with
NODE-2D-GET-POSITION. Methods with types that aren't supported yet, and
virtual methods, are skipped. Also define a constant for each value of the
class's enums and each of its constants, named likewise:
Node.PROCESS_MODE_ALWAYS becomes GODOT:+NODE-PROCESS-MODE-ALWAYS+. GODOT already
has the most used classes; an application defines the others it uses, and
they're added to GODOT too."
  (let* ((class (or (api-class class-name)
                    (error "No engine class ~a in ~a" class-name *extension-api-file*)))
         (prefix (lisp-style-class-name class-name))
         ;; The functions' names, and their arguments' names, are in GODOT
         (*package* (find-package :godot))
         (names '())
         (forms '()))
    (dolist (method (json-get class "methods"))
      (let ((method-name (json-get method "name")))
        (unless (json-get method "is_virtual")
          (let* ((name (intern (format nil "~a-~a" prefix (lisp-style-method-name method-name))))
                 ;; NIL if the method can't be called yet
                 (form (ignore-errors (engine-method-defun name class-name method-name '()))))
            (when form
              (push name names)
              (push form forms))))))
    (multiple-value-bind (constant-names constant-forms) (class-constant-defconstants class)
      `(progn
         (eval-when (:compile-toplevel :load-toplevel :execute)
           (export ',(append constant-names (reverse names)) :godot))
         ,@constant-forms
         ,@(reverse forms)
         ',class-name))))

(defmacro define-global-enums ()
  "Define a constant for each value of Godot's global enums (such as Error, Key
and PropertyHint), named in Lisp style and exported from the package GODOT: OK
becomes GODOT:+OK+ and KEY_ESCAPE GODOT:+KEY-ESCAPE+."
  (let ((*package* (find-package :godot))
        (names '())
        (forms '()))
    (dolist (enum (api-global-enums))
      (dolist (value (json-get enum "values"))
        (multiple-value-bind (symbol form)
            (constant-defconstant nil (json-get value "name") (json-get value "value")
                                  (format nil "~a, of the global enum ~a."
                                          (json-get value "name") (json-get enum "name")))
          (push symbol names)
          (push form forms))))
    `(progn
       (eval-when (:compile-toplevel :load-toplevel :execute)
         (export ',(reverse names) :godot))
       ,@(reverse forms)
       nil)))

;;;
;;; Utility functions
;;;
;;; DEFINE-UTILITY-FUNCTIONS defines a function for each of Godot's utility
;;; functions, the global functions of GDScript in @GlobalScope, such as
;;; randf_range and push_error. They're called through a function pointer from
;;; variant_get_ptr_utility_function, with raw values like ptrcall, or with
;;; Variants if they're vararg (such as print), so their code is generated like
;;; that of engine methods.
;;;

(defun lookup-utility-function (function-name hash)
  "The function pointer of the utility function FUNCTION-NAME with HASH, for an
initialize cell. Signals an error if Godot has no such function."
  (let ((function (with-string-name (string-name function-name)
                    (variant-get-ptr-utility-function string-name hash))))
    (when (ffi:null-pointer-p function)
      (error "Godot has no utility function ~a with hash ~d. Was extension_api.json ~
dumped from another version of Godot? Run make godot-api."
             function-name hash))
    function))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun utility-function-defun (name function)
    "The DEFUN of NAME, a function that calls the utility function FUNCTION, a
JSON object from extension_api.json, like those of DEFINE-ENGINE-METHOD."
    (let* ((function-name (json-get function "name"))
           (vararg (json-get function "is_vararg"))
           (hash (json-get function "hash"))
           (return-type (let ((type (json-get function "return_type")))
                          (if type
                              (engine-method-variant-type type "the result")
                              +variant-type-nil+)))
           (arguments (loop for (arg-name variant-type default) in (engine-method-arguments function)
                            collect (list arg-name variant-type default
                                          (engine-value-ffi-type variant-type)
                                          (gensym (symbol-name arg-name)))))
           (rest (and vararg (intern "ARGUMENTS")))
           (function-pointer (gensym "FUNCTION"))
           (name-positions (loop for (nil variant-type) in arguments
                                 for i from 0
                                 when (eql variant-type +variant-type-string-name+)
                                   collect (cons i 'sname)
                                 when (eql variant-type +variant-type-node-path+)
                                   collect (cons i 'npath))))
      `(progn
         (defun ,name (,@(loop for (arg-name nil default) in arguments
                               unless default collect arg-name)
                       ,@(when (some #'third arguments) '(&optional))
                       ,@(loop for (arg-name nil default) in arguments
                               when default collect (list arg-name (first default)))
                       ,@(when rest `(&rest ,rest)))
           ,(format nil "Call the utility function ~a(~{~a~^, ~}) of @GlobalScope~@[ with ~a~]."
                    function-name
                    (append (mapcar (lambda (argument) (json-get argument "name"))
                                    (json-get function "arguments"))
                            (and rest '("...")))
                    (and vararg "Variants"))
           (let ((,function-pointer (car (load-time-value
                                          (make-initialize-cell
                                           (lambda ()
                                             (lookup-utility-function ,function-name ,hash)))))))
             (unless ,function-pointer
               (error "The utility function ~a wasn't found" ,function-name))
             ,(temporary-names-form
               arguments
               (if vararg
                   (variant-call-method-form function-pointer nil arguments return-type name rest
                                             :utility t)
                   (ptrcall-method-form function-pointer nil arguments return-type :utility t)))))
         ,@(when name-positions
             `((define-compiler-macro ,name (&whole form &rest arguments)
                 (or (wrap-literal-names ',name arguments ',name-positions)
                     form))))))))

(defmacro define-utility-functions ()
  "Define a function for each of Godot's utility functions (the global functions
of GDScript in @GlobalScope, such as randf_range) that can be called yet, named
in Lisp style and exported from the package GODOT-UTILITY:
GODOT-UTILITY:RANDF-RANGE. They're
called like engine methods (see DEFINE-ENGINE-METHOD); vararg ones, such as
print, take any number of arguments, converted to Variants. Those named like a
symbol of Common Lisp, such as sin, abs and max, are left out, as Common Lisp
has them too, except print, which is GODOT-UTILITY:GODOT-PRINT, as it prints
to Godot's output, also in the editor."
  (let ((*package* (find-package :godot-utility))
        (names '())
        (forms '()))
    (dolist (function (api-utility-functions))
      (let* ((function-name (json-get function "name"))
             (lisp-name (cond ((string= function-name "print") "GODOT-PRINT")
                              ((find-symbol (lisp-style-method-name function-name)
                                            :common-lisp)
                               nil)
                              (t (lisp-style-method-name function-name))))
             (name (and lisp-name (intern lisp-name)))
             ;; NIL if the function can't be called yet
             (form (and name (ignore-errors (utility-function-defun name function)))))
        (when form
          (push name names)
          (push form forms))))
    `(progn
       (eval-when (:compile-toplevel :load-toplevel :execute)
         (export ',(reverse names) :godot-utility))
       ,@(reverse forms)
       nil)))

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
  "Take a reference to the RefCounted OBJECT (a Godot object pointer, a
GODOT-OBJECT, or NIL), to keep it alive while Lisp holds on to it. Give it back
with RELEASE-REFERENCE. Returns OBJECT."
  (unless (ffi:null-pointer-p (object-pointer object))
    (ref-counted-reference object))
  object)

(defun release-reference (object)
  "Give back a reference to the RefCounted OBJECT (a Godot object pointer, a
GODOT-OBJECT, or NIL), and destroy the object if it was the last one, like the
destructor of Ref<T>."
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

(defmacro setf-reference (place value)
  "Set PLACE, where Lisp keeps a RefCounted object, to the RefCounted VALUE (or
NIL): take a reference to VALUE, and give back the one to the old value of
PLACE, like assigning a Ref<T>. Returns VALUE."
  (multiple-value-bind (vars vals stores setter getter) (get-setf-expansion place)
    (let ((new (gensym "NEW"))
          (old (gensym "OLD")))
      `(let* (,@(mapcar #'list vars vals)
              (,new (add-reference ,value))
              (,old ,getter)
              (,(first stores) ,new))
         ,setter
         ;; After taking the new reference, in case it's the same object
         (release-reference ,old)
         ,new))))

;;;
;;; Signals
;;;
;;; CONNECT-SIGNAL connects a signal to a Lisp function, through a custom
;;; Callable (see GD-EXTENSION-TYPES:CALLABLE). AFTER-SIGNAL does it once, for
;;; what GDScript does with await.
;;;

;; Object.ConnectFlags.CONNECT_ONE_SHOT, for AFTER-SIGNAL. Applications use
;; GODOT:+OBJECT-CONNECT-ONE-SHOT+, generated from extension_api.json, which
;; GD-EXTENSION can't depend on.
(defconstant +connect-one-shot+ 4)

(define-engine-method object-connect ("Object" "connect"))

(defun connect-signal (object signal-name function &key (target object) (flags 0))
  "Connect the signal SIGNAL-NAME (a StringName, see SNAME, or a literal string)
of OBJECT to the Lisp FUNCTION, which is called with the signal's arguments as
Lisp values, like signal.connect(callable, flags) in GDScript. The connection
is bound to TARGET (a Godot object or its Lisp object, by default OBJECT): it's
removed when TARGET is freed. FLAGS are Object.ConnectFlags, such as
GODOT:+OBJECT-CONNECT-DEFERRED+. Returns Godot's error code, such as GODOT:+OK+."
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
;;;
;;; Defining classes
;;;
;;; DEFINE-CLASS defines an extension class in one form: the struct of its
;;; instances' Lisp objects (which includes GODOT-OBJECT), and the registration
;;; of the class, its properties, signals, methods and virtual methods. The
;;; classes are registered when Godot initializes the extension, in the order
;;; they were defined, by an initialize hook that GD-EXTENSION adds when it's
;;; loaded, so it runs before the application's hooks.
;;;

;; The registration functions of the classes defined with DEFINE-CLASS: a list
;; of (class-name . function), in the order they were defined
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
  "Register the classes defined with DEFINE-CLASS. An initialize hook. A class
that fails to register is reported, and the others are still registered."
  (loop for (class-name . function) in *class-definitions*
        do (handler-case (funcall function)
             (error (e)
               (report-error (format nil "registering the class ~a" class-name) e)))))

(add-initialize-hook 'register-defined-classes)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun function-form (designator)
    "A form for the function DESIGNATOR in DEFINE-CLASS: a symbol, called by name
so that redefining the function takes effect, or a form such as (LAMBDA ...)."
    (if (symbolp designator)
        `',designator
        designator))

  (defun arguments-form (arguments)
    "A form for the list of (name type) ARGUMENTS of DEFINE-CLASS, with the types
evaluated, so they can be keywords or variant type constants."
    `(list ,@(loop for (name type) in arguments
                   collect `(list ,name ,type))))

  (defun godot-property-name (slot-name)
    "The name of the property of the slot SLOT-NAME, a symbol, in Godot style:
mob-scene becomes \"mob_scene\"."
    (substitute #\_ #\- (string-downcase (symbol-name slot-name))))

  (defun define-class-property-forms (class-name accessor slot-name type class setter
                                     ref-counted)
    "The forms that bind the property of the slot SLOT-NAME, with its getter and
setter methods, get_<name> and set_<name>. REF-COUNTED, if not NIL, is a
variable that says whether the values are RefCounted, so the generated setter
takes and gives back references."
    (let* ((property-name (godot-property-name slot-name))
           (getter-name (format nil "get_~a" property-name))
           (setter-name (format nil "set_~a" property-name)))
      `((bind-method ,class-name ,getter-name
                     (lambda (object) (,accessor object))
                     :return-type ,type)
        (bind-method ,class-name ,setter-name
                     ,(cond (setter
                             (function-form setter))
                            (ref-counted
                             `(lambda (object value)
                                (if ,ref-counted
                                    (setf-reference (,accessor object) value)
                                    (setf (,accessor object) value))))
                            (t
                             `(lambda (object value) (setf (,accessor object) value))))
                     :arguments (list (list "value" ,type)))
        (bind-property ,class-name ,property-name ,type ,getter-name ,setter-name
                       ,@(when class `(:class ,class))))))

  (defun define-class-option-forms (class-name option)
    "The forms that bind what the class option OPTION of DEFINE-CLASS defines."
    (destructuring-bind (kind &rest arguments) option
      (ecase kind
        (:signal
         (destructuring-bind (signal-name &rest signal-arguments) arguments
           `((bind-signal ,class-name ,signal-name ,(arguments-form signal-arguments)))))
        (:method
         (destructuring-bind (method-name function &key arguments (return-type :nil))
             arguments
           `((bind-method ,class-name ,method-name ,(function-form function)
                          :arguments ,(arguments-form arguments)
                          :return-type ,return-type))))
        (:virtual
         (destructuring-bind (virtual-name function) arguments
           `((bind-virtual ,class-name ,virtual-name ,(function-form function)))))
        ((:destructor :tool)
         ;; Arguments of REGISTER-CLASS
         '())))))

(defmacro define-class (name (class-name parent-class-name) slots &rest options)
  "Define the extension class CLASS-NAME, which inherits from the class
PARENT-CLASS-NAME (both strings), with NAME as the struct of its instances'
Lisp objects, like extends and the script of a class in GDScript.

The struct includes GODOT-OBJECT, and has the SLOTS, each a symbol or (name
initform &key export class setter onready), as in DEFSTRUCT. A slot with EXPORT, a type
as in VARIANT-TYPE, is a property, like @export var in GDScript: its name in
Godot style (mob-scene becomes mob_scene), with the getter and setter methods
get_<name> and set_<name>. CLASS is as in BIND-PROPERTY. If it's a RefCounted
class, such as a Resource, the slot keeps a reference to its value, like a
Ref<T>: the setter takes one (see SETF-REFERENCE) and it's given back when Godot
frees the instance. SETTER, a function called with the Lisp object and the
value, replaces the generated setter, and then the slot's references are up to
it.

A slot with ONREADY is set when the instance is ready, before the class's
_ready virtual method runs, like @onready var in GDScript: to the node at the
path ONREADY, a string, as with $Path, or to the result of the function ONREADY,
called with the Lisp object.

OPTIONS are:
  (:signal name (argument-name type)...), see BIND-SIGNAL
  (:method name function &key arguments return-type), see BIND-METHOD
  (:virtual name function), see BIND-VIRTUAL
  (:destructor function), called with the Lisp object when Godot frees it
  (:tool t), see REGISTER-CLASS
Functions are symbols, called by name, so redefining them takes effect, or
forms that evaluate to functions. They're called with the Lisp object, like
self in GDScript.

The class is registered when Godot initializes the extension, before the
initialize hooks of the application run."
  (let ((make-name (intern (format nil "MAKE-~a" (symbol-name name))))
        (struct-slots '())
        (property-forms '())
        ;; The forms that set the :ONREADY slots of OBJECT
        (onready-forms '())
        ;; The exported slots with a class whose references are managed here:
        ;; a list of (accessor class variable), where the variable says
        ;; whether the class is RefCounted, found out at registration
        (reference-slots '()))
    (dolist (slot slots)
      (destructuring-bind (slot-name &optional initform &key export class setter onready)
          (if (listp slot) slot (list slot))
        (push `(,slot-name ,initform) struct-slots)
        (when onready
          (push `(setf (,(intern (format nil "~a-~a" (symbol-name name) (symbol-name slot-name)))
                        object)
                       ,(if (stringp onready)
                            `(node-get-node object ,onready)
                            `(funcall ,(function-form onready) object)))
                onready-forms))
        (cond (export
               (let ((accessor (intern (format nil "~a-~a" (symbol-name name)
                                               (symbol-name slot-name))))
                     (ref-counted (and class (not setter)
                                       (gensym (format nil "~a-REF-COUNTED"
                                                       (symbol-name slot-name))))))
                 (when ref-counted
                   (push (list accessor class ref-counted) reference-slots))
                 (setf property-forms
                       (append property-forms
                               (define-class-property-forms class-name accessor slot-name
                                                            export class setter ref-counted)))))
              ((or class setter)
               (error "The slot ~s of ~s has :CLASS or :SETTER, but no :EXPORT" slot-name name)))))
    (when onready-forms
      ;; The slots are set in _ready, before the class's own _ready, if any
      (let ((ready (find-if (lambda (option)
                              (and (eq (first option) :virtual)
                                   (equal (second option) "_ready")))
                            options)))
        (setf options
              (cons `(:virtual "_ready"
                               (lambda (object)
                                 ,@(reverse onready-forms)
                                 ,@(when ready
                                     `((funcall ,(function-form (third ready)) object)))))
                    (remove ready options)))))
    (let* ((destructor (second (assoc :destructor options)))
           (tool (second (assoc :tool options)))
           (release-forms (loop for (accessor nil ref-counted) in (reverse reference-slots)
                                collect `(when ,ref-counted
                                           (release-reference (,accessor object)))))
           (destructor-form
             (cond ((and destructor release-forms)
                    `(lambda (object)
                       (unwind-protect (funcall ,(function-form destructor) object)
                         ,@release-forms)))
                   (destructor (function-form destructor))
                   (release-forms `(lambda (object) ,@release-forms)))))
      `(progn
         (defstruct (,name (:include godot-object) (:constructor ,make-name))
           ,@(reverse struct-slots))
         (add-class-definition
          ,class-name
          (lambda ()
            (let (,@(loop for (nil class ref-counted) in (reverse reference-slots)
                          collect `(,ref-counted (inherits-class-p ,class "RefCounted"))))
              (register-class ,class-name ,parent-class-name
                              :constructor (lambda (pointer) (,make-name :pointer pointer))
                              ,@(when destructor-form `(:destructor ,destructor-form))
                              ,@(when tool `(:tool ,tool)))
              ,@property-forms
              ,@(loop for option in options
                      append (define-class-option-forms class-name option)))))
         ',name))))
