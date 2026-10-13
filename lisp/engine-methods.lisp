(in-package :gd-extension)

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

  (defun raw-arguments (arguments)
    "ARGUMENTS, a list of (symbol variant-type default) as from
ENGINE-METHOD-ARGUMENTS, with the FFI type of each argument's raw value and a
variable for it: a list of (symbol variant-type default ffi-type raw), as
PTRCALL-METHOD-FORM and VARIANT-CALL-METHOD-FORM take them."
    (loop for (arg-name variant-type default) in arguments
          collect (list arg-name variant-type default
                        (engine-value-ffi-type variant-type)
                        (gensym (symbol-name arg-name)))))

  (defun engine-function-lambda-list (object arguments rest)
    "The lambda list of the function of an engine method or a utility function:
OBJECT (a variable, or NIL if it takes no object), then the ARGUMENTS (as from
RAW-ARGUMENTS) without a default, then those with one as &OPTIONAL, then REST
(a variable, or NIL) as &REST."
    `(,@(when object (list object))
      ,@(loop for (arg-name nil default) in arguments
              unless default collect arg-name)
      ,@(when (some #'third arguments) '(&optional))
      ,@(loop for (arg-name nil default) in arguments
              when default collect (list arg-name (first default)))
      ,@(when rest `(&rest ,rest))))

  (defun documented-argument-names (function rest)
    "The names of the arguments of FUNCTION (a method or utility function from
extension_api.json) for a docstring, and \"...\" if REST isn't NIL."
    (append (mapcar (lambda (argument) (json-get argument "name"))
                    (json-get function "arguments"))
            (and rest '("..."))))

  (defun literal-names-compiler-macro (name arguments first-position)
    "A list of the DEFINE-COMPILER-MACRO of NAME, the function of an engine method
or a utility function, that wraps a literal string given for one of its
StringName or NodePath ARGUMENTS in SNAME or NPATH (see WRAP-LITERAL-NAMES), or
NIL if it has none. FIRST-POSITION is the position of the first of ARGUMENTS in
a call: 1 after an object argument, otherwise 0."
    (let ((positions (loop for (nil variant-type) in arguments
                           for i from first-position
                           when (eql variant-type +variant-type-string-name+)
                             collect (cons i 'sname)
                           when (eql variant-type +variant-type-node-path+)
                             collect (cons i 'npath))))
      (when positions
        `((define-compiler-macro ,name (&whole form &rest arguments)
            (or (wrap-literal-names ',name arguments ',positions)
                form))))))

  (defun engine-method-defun (name class-name method-name extra-arguments)
    "The DEFUN of NAME for DEFINE-ENGINE-METHOD, with the method's hash and
signature from extension_api.json."
    (multiple-value-bind (method defining-class) (api-method class-name method-name)
      (when (json-get method "is_virtual")
        (error "~a.~a is a virtual method, which can't be called through a method bind"
               class-name method-name))
      (let* ((vararg (json-get method "is_vararg"))
             (static (json-get method "is_static"))
             ;; The result comes with a reference (a Ref<T>), which goes into
             ;; the autorelease pool
             (ref-counted-result (let ((return-value (json-get method "return_value")))
                                   (and return-value
                                        (api-ref-counted-class-p (json-get return-value "type")))))
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
        (let* ((arguments (raw-arguments arguments))
               ;; Further arguments of a vararg method, unless they're declared
               ;; with EXTRA-ARGUMENTS
               (rest (and vararg (not extra-arguments) (intern "ARGUMENTS")))
               (object (gensym "OBJECT"))
               (takes-object (not (or static singleton)))
               (method-bind (gensym "METHOD-BIND")))
          `(progn
            (defun ,name ,(engine-function-lambda-list (and takes-object object) arguments rest)
              ,(format nil "Call ~:[~;the static method ~]~a.~a(~{~a~^, ~})~@[ with ~a~]~
                            ~@[ on the singleton ~a~]."
                       static defining-class method-name
                       (documented-argument-names method rest)
                       (and vararg "Variants")
                       singleton)
              (let ((,object ,(cond (static '(ffi:make-null-pointer :void))
                                    (singleton `(singleton ,singleton))
                                    (t `(object-pointer ,object))))
                    (,method-bind (initialize-cell-value
                                   (lookup-method-bind ,defining-class ,method-name ,hash))))
                (unless ,method-bind
                  (error "The method ~a.~a wasn't found" ,defining-class ,method-name))
                ,(let ((call (temporary-names-form
                              arguments
                              (if vararg
                                  (variant-call-method-form method-bind object arguments
                                                            return-type name rest)
                                  (ptrcall-method-form method-bind object arguments return-type)))))
                   (if ref-counted-result
                       `(autorelease-reference ,call)
                       call))))
            ,@(literal-names-compiler-macro name arguments (if takes-object 1 0))))))))

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
