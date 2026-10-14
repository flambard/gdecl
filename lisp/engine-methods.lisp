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
        (unsupported-api-type "Unsupported argument type for an engine method: variant type ~s"
                              variant-type))
      `(,writer ,pointer ,value)))

  (defun engine-value-read-form (variant-type pointer)
    "A form that reads the raw value of VARIANT-TYPE at POINTER as a Lisp value."
    (let ((reader (value-type-reader (find-value-type variant-type))))
      (unless reader
        (unsupported-api-type "Unsupported return type for an engine method: variant type ~s"
                              variant-type))
      `(,reader ,pointer)))

  (defun engine-value-destroy-form (variant-type pointer)
    "A form that destroys the raw value of VARIANT-TYPE at POINTER, or NIL if it
needs no destroying."
    (let ((destructor (value-type-destructor (find-value-type variant-type))))
      (when destructor
        `(,destructor ,pointer))))

  (defstruct (engine-argument
              (:conc-name argument-)
              (:constructor make-engine-argument
                  (name variant-type default
                   &aux (ffi-type (engine-value-ffi-type variant-type))
                        (raw (gensym (symbol-name name))))))
    "An argument of an engine method or a utility function, while the code of its
function is generated (only at macroexpansion time)."
    ;; The symbol in the function's lambda list
    name
    ;; The variant type, or :VARIANT for any Variant
    variant-type
    ;; A list of the form for the default value, or NIL if it's required
    default
    ;; The FFI type of the raw value, or NIL for a StringName or NodePath, which
    ;; is passed as the pointer to it
    ffi-type
    ;; The variable for the raw value
    raw)

  (defun raw-value-bindings (arguments)
    "The bindings of FFI:WITH-FOREIGN-OBJECTS for the raw values of ARGUMENTS."
    (loop for argument in arguments
          when (argument-ffi-type argument)
            collect `(,(argument-raw argument) ',(argument-ffi-type argument))))

  (defun argument-pointer-form (argument)
    "A form for the pointer to the raw value of ARGUMENT: the variable for it, or
for a StringName or NodePath, the argument itself."
    (if (argument-ffi-type argument)
        (argument-raw argument)
        (argument-name argument)))

  (defun argument-write-form (argument)
    "A form that stores the Lisp value of ARGUMENT as its raw value."
    (engine-value-write-form (argument-variant-type argument) (argument-raw argument)
                             (argument-name argument)))

  (defun argument-destroy-form (argument)
    "A form that destroys the raw value of ARGUMENT, or NIL if it has none or it
needs no destroying."
    (and (argument-ffi-type argument)
         (engine-value-destroy-form (argument-variant-type argument) (argument-raw argument))))

  (defun ptrcall-method-form (method-bind object arguments return-type &key utility)
    "The code of a DEFINE-ENGINE-METHOD function that calls METHOD-BIND with
ptrcall, with ARGUMENTS, a list of ENGINE-ARGUMENTs. If UTILITY is true,
METHOD-BIND is a utility function (see DEFINE-UTILITY-FUNCTIONS) instead, and
OBJECT isn't used."
    (let* ((has-return-value (not (eql return-type +variant-type-nil+)))
           (args (gensym "ARGS"))
           (r-ret (gensym "R-RET"))
           ;; The arguments whose raw values need destroying, such as Strings
           ;; and Variants
           (destroyed-arguments (remove-if-not #'argument-destroy-form arguments))
           (destroy-forms (append
                           (mapcar #'argument-destroy-form destroyed-arguments)
                           (when has-return-value
                             (let ((form (engine-value-destroy-form return-type r-ret)))
                               (when form (list form))))))
           (body `(,@(loop for argument in arguments
                           for i from 0
                           when (argument-ffi-type argument)
                             collect (argument-write-form argument)
                           collect `(setf (foreign-ref ,args :pointer-void ,i)
                                          ,(argument-pointer-form argument)))
                   ,(let ((r-ret (if has-return-value r-ret '(ffi:make-null-pointer :void))))
                      (if utility
                          `(call-ptr-utility-function ,method-bind ,r-ret ,args
                                                      ,(length arguments))
                          `(object-method-bind-ptrcall ,method-bind ,object ,args ,r-ret)))
                   ,@(when has-return-value
                       (list (engine-value-read-form return-type r-ret))))))
      `(with-foreign-memory ((,args '(:array :pointer-void ,(max 1 (length arguments))))
                             ,@(raw-value-bindings arguments)
                             ,@(when has-return-value
                                 `((,r-ret ',(engine-value-ffi-type return-type)))))
         ;; Empty (all zero) at first, so they can be destroyed also if
         ;; converting an argument fails before they're written. Godot
         ;; assigns the result, e.g. to a Ref or a PackedStringArray, which
         ;; releases the old value, so it must be empty too.
         ,@(loop for argument in destroyed-arguments
                 collect `(clear-foreign-object ,(argument-raw argument)
                                                ',(argument-ffi-type argument)))
         ,@(when has-return-value
             `((clear-foreign-object ,r-ret ',(engine-value-ffi-type return-type))))
         ,(if destroy-forms
              `(unwind-protect (progn ,@body) ,@destroy-forms)
              `(progn ,@body)))))

  (defun variant-call-method-form (method-bind object arguments return-type name rest
                                   &key utility)
    "The code of a DEFINE-ENGINE-METHOD function that calls METHOD-BIND, a vararg
method, with object_method_bind_call, with ARGUMENTS (a list of
ENGINE-ARGUMENTs) and the result as Variants. REST, if not NIL, is the variable with the list of further arguments,
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
      (flet ((array-size (element-type)
               ;; The size of the array in bytes, known when the macro is
               ;; expanded, unless there are REST arguments
               (let ((element-size (ffi:size-of-foreign-type element-type)))
                 (if rest
                     `(* ,element-size (max 1 ,count))
                     (* element-size (max 1 declared-count))))))
        `(let ((,count ,(if rest `(+ ,declared-count (length ,rest)) declared-count)))
           (with-foreign-memory ((,args :size ,(array-size :pointer-void))
                                 (,variants :size ,(array-size 'variant))
                                 ,@(raw-value-bindings arguments)
                                 ,@(unless utility
                                     `((,r-return 'variant)
                                       (,r-error 'call-error)))
                                 ,@(when (and has-return-value
                                              (or utility (not (eql return-type :variant))))
                                     `((,r-ret ',(engine-value-ffi-type return-type)))))
             ;; All Nil, so they can all be destroyed, also if making one fails
             (ffi:c-inline (,variants ,(array-size 'variant)) (:pointer-void :unsigned-long) :void
                           "__builtin_memset(#0, 0, #1)" :one-liner t)
             ;; Godot always initializes r_ret, also when the call fails
             (unwind-protect
                  (progn
                    ,@(loop for argument in arguments
                            for type = (argument-variant-type argument)
                            for i from 0
                            for variant = `(array-element ,variants 'variant ,i)
                            if (eql type :variant)
                              ;; Already any Variant: constructed right in the array
                              collect `(write-variant ,variant ,(argument-name argument))
                            else
                              collect (let ((construct `(call-variant-from-type-constructor
                                                         (aref *variant-from-type-constructors* ,type)
                                                         ,variant
                                                         ,(argument-pointer-form argument)))
                                            (destroy (argument-destroy-form argument)))
                                        (cond ((not (argument-ffi-type argument)) construct)
                                              ;; The Variant gets a copy of the raw value
                                              (destroy `(progn ,(argument-write-form argument)
                                                               (unwind-protect ,construct ,destroy)))
                                              (t `(progn ,(argument-write-form argument)
                                                         ,construct))))
                            end
                            collect `(setf (foreign-ref ,args :pointer-void ,i) ,variant))
                    ,@(when rest
                        `((loop for value in ,rest
                                for i from ,declared-count
                                for variant = (array-element ,variants 'variant i)
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
                            ;; The error, the first member of GDExtensionCallError
                            (let ((,call-error (foreign-ref ,r-error :int)))
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
                 (variant-destroy (array-element ,variants 'variant i)))
               ,@(unless utility
                   `((variant-destroy ,r-return)))))))))

  (defun temporary-names-form (arguments form)
    "FORM, the call of an engine method with ARGUMENTS (ENGINE-ARGUMENTs), wrapped in code that turns each StringName or NodePath
argument that's a Lisp string at runtime into a temporary one, destroyed after
the call."
    (loop for argument in (reverse arguments)
          for arg-name = (argument-name argument)
          for type = (argument-variant-type argument)
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
      (unless (find-value-type variant-type nil)
        (unsupported-api-type "Unsupported type ~a of ~a" type what))
      variant-type))

  (defun engine-method-arguments (method)
    "The arguments of METHOD (a method from extension_api.json), as a list of
ENGINE-ARGUMENTs. Only the last arguments with supported default values become
optional."
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
            collect (make-engine-argument (engine-method-argument-symbol (json-get argument "name"))
                                          type
                                          (and (>= i first-optional) default)))))

  (defun engine-function-lambda-list (object arguments rest)
    "The lambda list of the function of an engine method or a utility function:
OBJECT (a variable, or NIL if it takes no object), then the ARGUMENTS
(ENGINE-ARGUMENTs) without a default, then those with one as &OPTIONAL, then REST
(a variable, or NIL) as &REST."
    `(,@(when object (list object))
      ,@(loop for argument in arguments
              unless (argument-default argument) collect (argument-name argument))
      ,@(when (some #'argument-default arguments) '(&optional))
      ,@(loop for argument in arguments
              for default = (argument-default argument)
              when default collect (list (argument-name argument) (first default)))
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
    (let ((positions (loop for argument in arguments
                           for variant-type = (argument-variant-type argument)
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
          (dolist (argument arguments)
            (setf (argument-default argument) nil))
          (setf arguments (append arguments
                                  (loop for (arg-name type) in extra-arguments
                                        collect (make-engine-argument
                                                 arg-name (variant-type (eval type)) nil)))))
        (let* (;; Further arguments of a vararg method, unless they're declared
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
