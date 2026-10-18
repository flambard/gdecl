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

;;; Vararg calls (see VARIANT-CALL-METHOD-FORM) keep their argument array, the
;;; argument Variants, the result Variant and the call error in one block of
;;; foreign memory, laid out in that order, allocated (with calloc, so the
;;; Variants are Nil and can all be destroyed, also if making one fails) and
;;; freed in one piece of C each, and handled by its address, an integer: a
;;; MALLOC and a Lisp pointer object for each of them, and one for each Variant,
;;; were most of what such a call cost (measured: emit_signal with a further
;;; argument 780 ns and 336 bytes before). The macros expand into C code, so
;;; the generated functions make no calls between files for them.

(defmacro with-variant-call ((call count) &body body)
  "Evaluate BODY with CALL bound to the address of a new block for a vararg call
with COUNT (a variable) argument Variants, all Nil, with the argument array
pointing to them. The Variants and the result are destroyed and the block freed
when BODY exits, also on a non-local exit."
  `(let ((,call (ffi:c-inline (,count) (:long) :uint64-t
                              ,(format nil "{ long n = #0; char *b = __builtin_calloc(1, n * ~d + ~d); ~
if (b) for (long i = 0; i < n; i++) ((void **)b)[i] = b + n * 8 + i * ~d; ~
@(return 0) = (uint64_t)b; }"
                                       (+ 8 +variant-size+) (+ +variant-size+ 16) +variant-size+))))
     (when (zerop ,call)
       (error "Out of memory for a call with ~d arguments" ,count))
     (unwind-protect (progn ,@body)
       ;; The argument Variants and the result Variant right after them
       (ffi:c-inline (*variant-destroy* ,call ,count) (:pointer-void :uint64-t :long) :void
                     ,(format nil "{ char *b = (char *)#1; long n = #2; ~
for (long i = 0; i <= n; i++) ((void (*)(void *))#0)(b + n * 8 + i * ~d); ~
__builtin_free(b); }"
                              +variant-size+)))))

(defmacro variant-call-argument (call count index)
  "The address of argument Variant INDEX in the block of a vararg call, CALL."
  `(ffi:c-inline (,call ,count ,index) (:uint64-t :long :long) :uint64-t
                 ,(format nil "#0 + #1 * 8 + #2 * ~d" +variant-size+) :one-liner t))

(defmacro variant-call-result (call count)
  "The address of the result Variant in the block of a vararg call, CALL."
  `(ffi:c-inline (,call ,count) (:uint64-t :long) :uint64-t
                 ,(format nil "#0 + #1 * ~d" (+ 8 +variant-size+)) :one-liner t))

(defmacro construct-variant-at (address variant-type pointer)
  "Construct a Variant of VARIANT-TYPE at ADDRESS, an integer, from the raw value
at POINTER, with Godot's constructor."
  `(ffi:c-inline ((aref *variant-from-type-constructors* ,variant-type) ,address ,pointer)
                 (:pointer-void :uint64-t :pointer-void) :void
                 "((void (*)(void *, void *))#0)((void *)#1, #2)" :one-liner t))

(defmacro call-with-variants (method-bind object call count)
  "Call METHOD-BIND on OBJECT with object_method_bind_call, with the arguments
and the result in the block of a vararg call, CALL, and return the error of the
call error."
  `(ffi:c-inline (*object-method-bind-call* ,method-bind ,object ,call ,count)
                 (:pointer-void :pointer-void :pointer-void :uint64-t :long) :int
                 ,(format nil "{ char *b = (char *)#3; long n = #4; char *ret = b + n * ~d; ~
int *err = (int *)(ret + ~d); ~
((void (*)(void *, void *, const void **, long long, void *, void *))#0)(#1, #2, (const void **)b, n, ret, err); ~
@(return 0) = err[0]; }"
                          (+ 8 +variant-size+) +variant-size+)))

(defmacro raw-variant-call-result (call count variant-type ffi-type)
  "The raw value of FFI-TYPE of the result Variant, of VARIANT-TYPE, in the block
of a vararg call, CALL, with Godot's constructor."
  `(ffi:c-inline ((aref *type-from-variant-constructors* ,variant-type) ,call ,count)
                 (:pointer-void :uint64-t :long) ,ffi-type
                 ,(format nil "{ ~a r = 0; ((void (*)(void *, void *))#0)(&r, (char *)#1 + #2 * ~d); ~
@(return 0) = r; }"
                          (c-type-name ffi-type) (+ 8 +variant-size+))))

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

  (defun by-pointer-type-p (variant-type)
    "True if an argument of VARIANT-TYPE is passed as the pointer to its value,
such as a StringName (see VALUE-TYPE-BY-POINTER)."
    (value-type-by-pointer (find-value-type variant-type)))

  (defun argument-ffi-type-of (variant-type)
    "The FFI type of the raw value of an argument of VARIANT-TYPE, or NIL for a
type passed as the pointer to its value, such as a StringName."
    (unless (by-pointer-type-p variant-type)
      (engine-value-ffi-type variant-type)))

  (defstruct (engine-argument
              (:conc-name argument-)
              (:constructor make-engine-argument
                  (name variant-type default
                   &aux (ffi-type (argument-ffi-type-of variant-type))
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
    "The bindings of WITH-FOREIGN-MEMORY for the raw values of ARGUMENTS."
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

  (defun c-inline-argument-reference (index)
    "How C code in FFI:C-INLINE refers to argument INDEX: #0 to #9, then #a to #z."
    (format nil "#~a" (if (< index 10)
                          index
                          (code-char (+ (char-code #\a) (- index 10))))))

  (defstruct (call-target (:constructor make-call-target (function &optional object)))
    "What the code of the generators below calls: an engine method, or a utility
function (see DEFINE-UTILITY-FUNCTIONS), which takes no object."
    ;; A form for the method bind, or for the utility function's pointer
    function
    ;; A form for the object pointer, or NIL for a utility function
    object)

  (defun utility-target-p (target)
    "True if TARGET, a CALL-TARGET, is a utility function."
    (null (call-target-object target)))

  (defun float-layout (variant-type)
    "The accessors of the components of a builtin type whose components are all
floats, such as Vector2, from BUILTIN-LAYOUT, if VARIANT-TYPE is one; else NIL."
    (let* ((value-type (find-value-type variant-type nil))
           (name (and value-type (value-type-lisp-type value-type)))
           (layout (and name (builtin-layout name))))
      (when (and layout (every (lambda (component) (eq (first component) :float)) layout))
        (mapcar #'second layout))))

  (defun inline-call-code (target declarations pointers count result-declaration
                           result-pointer returns)
    "The C code of INLINE-PTRCALL-FORM: DECLARATIONS of the raw values, the
argument array of POINTERS, RESULT-DECLARATION, the call of TARGET (a
CALL-TARGET), and RETURNS."
    (format nil "{ ~{~a ~}const void *args[~d] = { ~{~a~^, ~} }; ~a~a~a }"
            (reverse declarations)
            (max 1 count)
            (if pointers (reverse pointers) '("0"))
            result-declaration
            (if (utility-target-p target)
                (format nil "((void (*)(void *, const void **, int))#0)(~a, args, ~d);"
                        result-pointer count)
                (format nil "((void (*)(void *, void *, const void **, void *))#0)(#1, #2, args, ~a);"
                        result-pointer))
            returns))

  (defun inline-builtin-result-form (target inputs declarations pointers arguments
                                     return-type into)
    "The rest of INLINE-PTRCALL-FORM for a result of a builtin type made of
floats: returned as multiple values, one per component, made into the Lisp
value, or stored into INTO, if it isn't NIL, the variable with the Lisp value
to store them in, which is returned."
    (let* ((count (length (float-layout return-type)))
           (variables (loop repeat count collect (gensym "COMPONENT")))
           (code (inline-call-code target declarations pointers (length arguments)
                                   (format nil "float r[~d] = { 0 }; " count)
                                   "r"
                                   (format nil " ~{~a~}"
                                           (loop for i below count
                                                 collect (format nil "@(return ~d) = r[~d]; " i i))))))
      `(multiple-value-bind ,variables
           (ffi:c-inline ,(mapcar #'first (reverse inputs))
                         ,(mapcar #'second (reverse inputs))
                         (values ,@(loop repeat count collect :float))
                         ,code)
         ,(if into
              `(progn
                 (setf ,@(loop for accessors in (float-layout return-type)
                               for variable in variables
                               ;; The outermost accessor applies first
                               append (list (reduce (lambda (form accessor)
                                                      `(,accessor ,form))
                                                    accessors
                                                    :initial-value into)
                                            variable)))
                 ,into)
              (builtin-construct-form (value-type-lisp-type (find-value-type return-type))
                                      variables)))))

  (defun inline-ptrcall-form (target arguments return-type &optional into)
    "The code of a DEFINE-ENGINE-METHOD function that calls TARGET (a
CALL-TARGET) with ptrcall in one piece of C code (FFI:C-INLINE), with the raw
values and the argument array in C variables, so nothing is allocated for them:
for methods whose ARGUMENTS (ENGINE-ARGUMENTs) and RETURN-TYPE are all simple
types (bool, int, float, Object, and StringName and NodePath arguments, which
are pointers already). NIL for other methods. INTO is as in
INLINE-BUILTIN-RESULT-FORM."
    (let ((inputs '())                  ; (form ffi-type), in order
          (declarations '())            ; C declarations of the raw values
          (pointers '()))               ; the elements of the argument array
      (flet ((input (form ffi-type)
               ;; The reference to a new input of the C code
               (push (list form ffi-type) inputs)
               (c-inline-argument-reference (1- (length inputs)))))
        (if (utility-target-p target)
            (input (call-target-function target) :pointer-void)
            (progn (input '*object-method-bind-ptrcall* :pointer-void)
                   (input (call-target-function target) :pointer-void)
                   (input (call-target-object target) :pointer-void)))
        (loop for argument in arguments
              for i from 0
              for name = (argument-name argument)
              for type = (argument-variant-type argument)
              for value-type = (find-value-type type)
              do (cond ((value-type-to-raw value-type)
                        ;; A simple type: the raw value in a C variable. An
                        ;; Object argument is a pointer to the object pointer.
                        (let ((ffi-type (value-type-ffi-type value-type)))
                          (push (format nil "~a a~d = ~a;" (c-type-name ffi-type) i
                                        (input (funcall (value-type-to-raw value-type) name)
                                               ffi-type))
                                declarations)
                          (push (format nil "&a~d" i) pointers)))
                       ;; Pointers to the StringName or NodePath already
                       ((value-type-by-pointer value-type)
                        (push (input name :pointer-void) pointers))
                       ;; A builtin type made of floats, such as Vector2: an
                       ;; array of its components
                       ((float-layout type)
                        (push (format nil "float a~d[] = { ~{~a~^, ~} };" i
                                      (loop for accessors in (float-layout type)
                                            ;; The outermost accessor applies first
                                            collect (input (reduce (lambda (form accessor)
                                                                     `(,accessor ,form))
                                                                   accessors
                                                                   :initial-value name)
                                                           :float)))
                              declarations)
                        (push (format nil "a~d" i) pointers))
                       (t (return-from inline-ptrcall-form nil))))
        (when (float-layout return-type)
          (return-from inline-ptrcall-form
            (inline-builtin-result-form target inputs declarations pointers arguments
                                        return-type into)))
        (let* ((result-type (and (not (eql return-type +variant-type-nil+))
                                 (find-value-type return-type)))
               (c-type (and result-type (value-type-from-raw result-type)
                            (c-type-name (value-type-ffi-type result-type)))))
          ;; A result of a simple type, or none
          (when (and result-type (not c-type))
            (return-from inline-ptrcall-form nil))
          ;; An Object is returned as an integer, its address (see
          ;; RAW-RESULT-CONVERSION)
          (multiple-value-bind (ffi-type cast from-raw)
              (if result-type (raw-result-conversion result-type) (values :void "" nil))
            (let* ((count (length arguments))
                   ;; Zero, as Godot assigns the result, e.g. to a Ref
                   (result (if c-type (format nil "~a r = 0; " c-type) ""))
                   (result-pointer (if c-type "&r" "0"))
                   (code (inline-call-code target declarations pointers count result
                                           result-pointer
                                           (if c-type (format nil " @(return 0) = ~ar;" cast) "")))
                   (form `(ffi:c-inline ,(mapcar #'first (reverse inputs))
                                        ,(mapcar #'second (reverse inputs))
                                        ,ffi-type
                                        ,code)))
              (if from-raw
                  (funcall from-raw form)
                  form)))))))

  (defun inline-variant-call-form (target arguments return-type name)
    "The code of a DEFINE-ENGINE-METHOD function that calls TARGET (a
CALL-TARGET), a vararg method, with object_method_bind_call in one piece of C
code (FFI:C-INLINE), like INLINE-PTRCALL-FORM: the Variants of the arguments
are made from their raw values on the C stack, with the constructors in
*VARIANT-FROM-TYPE-CONSTRUCTORS*, and destroyed there, so nothing is allocated
for them. For calls whose ARGUMENTS (ENGINE-ARGUMENTs) are all of simple types
(bool, int, float, Object), StringNames and NodePaths, or builtin types made of
floats, such as the extra arguments of DEFINE-ENGINE-METHOD, and whose
RETURN-TYPE is none, bool, int or float. NIL for other calls, and for utility
functions. NAME, the function's name, is for the error when the call fails."
    (when (utility-target-p target)
      (return-from inline-variant-call-form nil))
    (let ((inputs '())                  ; (form ffi-type), in order
          (declarations '())            ; C code before the call
          (count (length arguments))
          (variant-words (/ +variant-size+ 8)))
      (labels ((input (form ffi-type)
                 (push (list form ffi-type) inputs)
                 (c-inline-argument-reference (1- (length inputs))))
               (construct (i variant-type pointer)
                 ;; Variant I from the raw value at POINTER, with the constructor
                 ;; for VARIANT-TYPE
                 (format nil "((void (*)(void *, void *))~a)(v[~d], ~a);"
                         (input `(aref *variant-from-type-constructors* ,variant-type)
                                :pointer-void)
                         i pointer)))
        (let ((call (format nil "((void (*)(void *, void *, const void **, long long, void *, void *))~a)(~a, ~a, args, ~d, ret, err);"
                            (input '*object-method-bind-call* :pointer-void)
                            (input (call-target-function target) :pointer-void)
                            (input (call-target-object target) :pointer-void)
                            count))
              (destroy (input '*variant-destroy* :pointer-void)))
          (loop for argument in arguments
                for i from 0
                for argument-name = (argument-name argument)
                for type = (argument-variant-type argument)
                for value-type = (and (integerp type) (find-value-type type nil))
                do (cond ((null value-type)
                          (return-from inline-variant-call-form nil))
                         ;; A simple type: the raw value in a C variable
                         ((value-type-to-raw value-type)
                          (let ((ffi-type (value-type-ffi-type value-type)))
                            (push (format nil "~a a~d = ~a;" (c-type-name ffi-type) i
                                          (input (funcall (value-type-to-raw value-type)
                                                          argument-name)
                                                 ffi-type))
                                  declarations)
                            (push (construct i type (format nil "&a~d" i)) declarations)))
                         ;; Pointers to the StringName or NodePath already
                         ((value-type-by-pointer value-type)
                          (push (construct i type (input argument-name :pointer-void))
                                declarations))
                         ;; A builtin type made of floats: an array of its
                         ;; components
                         ((float-layout type)
                          (push (format nil "float a~d[] = { ~{~a~^, ~} };" i
                                        (loop for accessors in (float-layout type)
                                              collect (input (reduce (lambda (form accessor)
                                                                       `(,accessor ,form))
                                                                     accessors
                                                                     :initial-value argument-name)
                                                             :float)))
                                declarations)
                          (push (construct i type (format nil "a~d" i)) declarations))
                         (t (return-from inline-variant-call-form nil))))
          (let* ((result-type (and (not (eql return-type +variant-type-nil+))
                                   (integerp return-type)
                                   (find-value-type return-type nil)))
                 (ffi-type (and result-type (value-type-ffi-type result-type)))
                 (from-raw (and result-type (value-type-from-raw result-type))))
            ;; A result of type none, bool, int or float (not an Object, whose
            ;; reference the Variant would give back)
            (when (or (and result-type (not from-raw))
                      (eql return-type +variant-type-object+)
                      (eql return-type :variant))
              (return-from inline-variant-call-form nil))
            (let* ((c-type (and ffi-type (c-type-name ffi-type)))
                   (code (format nil "{ long long v[~d][~d]; long long ret[~d] = { 0 }; int err[3] = { 0, 0, 0 }; ~{~a ~}const void *args[~d] = { ~{~a~^, ~} }; ~a ~@[~a ~]~{((void (*)(void *))~a)(~a); ~}@(return 0) = err[0];~@[ @(return 1) = r;~] }"
                                 (max 1 count) variant-words variant-words
                                 (reverse declarations)
                                 (max 1 count)
                                 (if (plusp count)
                                     (loop for i below count collect (format nil "v[~d]" i))
                                     '("0"))
                                 call
                                 (and c-type
                                      (format nil "~a r = 0; if (err[0] == 0) ((void (*)(void *, void *))~a)(&r, ret);"
                                              c-type
                                              (input `(aref *type-from-variant-constructors*
                                                            ,return-type)
                                                     :pointer-void)))
                                 (loop for variant in (append (loop for i below count
                                                                    collect (format nil "v[~d]" i))
                                                              '("ret"))
                                       append (list destroy variant))
                                 c-type))
                   (call-error (gensym "CALL-ERROR"))
                   (result (gensym "RESULT")))
              `(multiple-value-bind (,call-error ,@(when c-type (list result)))
                   (ffi:c-inline ,(mapcar #'first (reverse inputs))
                                 ,(mapcar #'second (reverse inputs))
                                 ,(if c-type `(values :int ,ffi-type) :int)
                                 ,code)
                 (unless (= ,call-error +call-ok+)
                   (error "Calling ~a failed with call error ~d" ',name ,call-error))
                 ,(when c-type (funcall from-raw result)))))))))

  (defun ptrcall-method-form (target arguments return-type &optional into)
    "The code of a DEFINE-ENGINE-METHOD function that calls TARGET (a
CALL-TARGET) with ptrcall, with ARGUMENTS, a list of ENGINE-ARGUMENTs. Methods
with only simple types are called in one piece of C code (see
INLINE-PTRCALL-FORM). INTO, if not NIL, is the variable with the Lisp value to
store a builtin result in, which only that code does."
    (or (inline-ptrcall-form target arguments return-type into)
        (if into
            (error ":INTO needs a method whose arguments are all of simple types, so ~
                    that it's called in one piece of C code")
            (general-ptrcall-method-form target arguments return-type))))

  (defun general-ptrcall-method-form (target arguments return-type)
    "The code of PTRCALL-METHOD-FORM for methods with types that INLINE-PTRCALL-FORM
doesn't handle: the raw values and the argument array are in foreign memory."
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
                   ,(let ((r-ret (if has-return-value r-ret '(ffi:make-null-pointer :void)))
                          (function (call-target-function target)))
                      (if (utility-target-p target)
                          `(call-ptr-utility-function ,function ,r-ret ,args
                                                      ,(length arguments))
                          `(object-method-bind-ptrcall ,function ,(call-target-object target)
                                                       ,args ,r-ret)))
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

  (defun variant-call-method-form (target arguments return-type &key rest name)
    "The code of a DEFINE-ENGINE-METHOD function that calls TARGET (a
CALL-TARGET), a vararg method, with object_method_bind_call, with ARGUMENTS (a
list of ENGINE-ARGUMENTs) and the result as Variants. REST, if not NIL, is the
variable with the list of further arguments, converted to Variants by their
Lisp types (see WRITE-VARIANT). A vararg utility function takes Variants too,
but returns a raw value of its return type. NAME, the function's name, is for
the error when the call fails. The argument array, the Variants, the result
and the call error are in one block (see WITH-VARIANT-CALL)."
    (let* ((utility (utility-target-p target))
           (method-bind (call-target-function target))
           (object (call-target-object target))
           (has-return-value (not (eql return-type +variant-type-nil+)))
           (declared-count (length arguments))
           ;; A bool, int or float result, read from the result Variant in C
           (result-value-type (and has-return-value (not utility) (integerp return-type)
                                   (not (eql return-type +variant-type-object+))
                                   (find-value-type return-type nil)))
           (from-raw (and result-value-type (value-type-from-raw result-value-type)))
           (count (gensym "COUNT"))
           (call (gensym "CALL"))
           (r-ret (gensym "R-RET"))
           (call-error (gensym "CALL-ERROR")))
      (flet ((read-raw-result ()
               ;; The raw value at R-RET, destroyed afterwards
               (let ((destroy-form (engine-value-destroy-form return-type r-ret)))
                 (if destroy-form
                     `(unwind-protect ,(engine-value-read-form return-type r-ret)
                        ,destroy-form)
                     (engine-value-read-form return-type r-ret)))))
        `(let ((,count ,(if rest `(+ ,declared-count (length ,rest)) declared-count)))
           (with-variant-call (,call ,count)
             (with-foreign-memory (,@(raw-value-bindings arguments)
                                   ,@(when (and has-return-value (not from-raw)
                                                (or utility (not (eql return-type :variant))))
                                       `((,r-ret ',(engine-value-ffi-type return-type)))))
               ,@(loop for argument in arguments
                       for type = (argument-variant-type argument)
                       for i from 0
                       for variant = `(variant-call-argument ,call ,count ,i)
                       collect (if (eql type :variant)
                                   ;; Already any Variant
                                   `(write-variant-at ,variant ,(argument-name argument))
                                   (let ((construct `(construct-variant-at
                                                      ,variant ,type
                                                      ,(argument-pointer-form argument)))
                                         (destroy (argument-destroy-form argument)))
                                     (cond ((not (argument-ffi-type argument)) construct)
                                           ;; The Variant gets a copy of the raw value
                                           (destroy `(progn ,(argument-write-form argument)
                                                            (unwind-protect ,construct ,destroy)))
                                           (t `(progn ,(argument-write-form argument)
                                                      ,construct))))))
               ,@(when rest
                   `((loop for value in ,rest
                           for i from ,declared-count
                           do (write-variant-at (variant-call-argument ,call ,count i) value))))
               ,@(if utility
                     `(,@(when has-return-value
                           `((clear-foreign-object ,r-ret ',(engine-value-ffi-type return-type))))
                       (call-ptr-utility-function ,method-bind
                                                  ,(if has-return-value
                                                       r-ret
                                                       '(ffi:make-null-pointer :void))
                                                  (address-pointer ,call) ,count))
                     `((let ((,call-error (call-with-variants ,method-bind ,object ,call ,count)))
                         (unless (= ,call-error +call-ok+)
                           (error "Calling ~a failed with call error ~d" ',name ,call-error)))))
               ,(cond ((not has-return-value) nil)
                      (utility (read-raw-result))
                      ((eql return-type :variant)
                       `(read-variant-result (address-pointer (variant-call-result ,call ,count))))
                      (from-raw
                       (funcall from-raw `(raw-variant-call-result ,call ,count ,return-type
                                                                   ,(value-type-ffi-type
                                                                     result-value-type))))
                      (t
                       `(progn
                          (call-type-from-variant-constructor
                           (aref *type-from-variant-constructors* ,return-type) ,r-ret
                           (address-pointer (variant-call-result ,call ,count)))
                          ,(read-raw-result))))))))))

  (defun temporary-names-form (arguments form)
    "FORM, the call of an engine method with ARGUMENTS (ENGINE-ARGUMENTs),
wrapped in code that turns each StringName or NodePath argument that's a Lisp
string at runtime into a temporary one, destroyed after the call."
    (loop for argument in (reverse arguments)
          for arg-name = (argument-name argument)
          for type = (argument-variant-type argument)
          when (by-pointer-type-p type)
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

  (defun api-default-form (default variant-type)
    "A list of one form for the default value DEFAULT of an argument of
VARIANT-TYPE, a string in GDScript syntax from extension_api.json, or NIL if
it's not supported (yet): parsed by the value type's DEFAULT-PARSER."
    (let* ((value-type (find-value-type variant-type nil))
           (parser (and value-type (value-type-default-parser value-type))))
      (and parser (funcall parser default value-type))))

  (defun engine-method-arguments (method)
    "The arguments of METHOD (an API-METHOD), as a list of ENGINE-ARGUMENTs. Only
the last arguments with supported default values become optional."
    (let* ((arguments (api-method-arguments method))
           (types (mapcar (lambda (argument)
                            (engine-method-variant-type (api-argument-type argument)
                                                        (api-argument-name argument)))
                          arguments))
           (defaults (mapcar (lambda (argument type)
                               (let ((default (api-argument-default-value argument)))
                                 (and default (api-default-form default type))))
                             arguments types))
           (first-optional (1+ (or (position nil defaults :from-end t) -1))))
      (loop for argument in arguments
            for type in types
            for default in defaults
            for i from 0
            collect (make-engine-argument (engine-method-argument-symbol (api-argument-name argument))
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
    "The names of the arguments of FUNCTION (an API-METHOD, a method or utility
function) for a docstring, and \"...\" if REST isn't NIL."
    (append (mapcar #'api-argument-name (api-method-arguments function))
            (and rest '("..."))))

  (defun literal-names-compiler-macro (name arguments first-position)
    "A list of the DEFINE-COMPILER-MACRO of NAME, the function of an engine method
or a utility function, that wraps a literal string given for one of its
StringName or NodePath ARGUMENTS in SNAME or NPATH (see WRAP-LITERAL-NAMES), or
NIL if it has none. FIRST-POSITION is the position of the first of ARGUMENTS in
a call: 1 after an object argument, otherwise 0."
    (let ((positions (loop for argument in arguments
                           for value-type = (find-value-type (argument-variant-type argument))
                           for i from first-position
                           when (value-type-literal-macro value-type)
                             collect (cons i (value-type-literal-macro value-type)))))
      (when positions
        `((define-compiler-macro ,name (&whole form &rest arguments)
            (or (wrap-literal-names ',name arguments ',positions)
                form))))))

  (defun engine-function-defun (name documentation arguments return-type
                                &key function look-up-form not-found-error
                                     object object-form takes-object vararg rest
                                     ref-counted-result fixed-arguments into)
    "The DEFUN of NAME, the function of an engine method or a utility function,
and its compiler macro (see LITERAL-NAMES-COMPILER-MACRO), shared by
DEFINE-ENGINE-METHOD and DEFINE-UTILITY-FUNCTIONS. FUNCTION is the variable for
the method bind or the utility function's pointer, looked up once with
LOOK-UP-FORM; NOT-FOUND-ERROR, the arguments of ERROR when it's NULL. OBJECT
is the variable for the object pointer, bound to OBJECT-FORM, or NIL for a
utility function; TAKES-OBJECT, true if the function takes the object as its
first argument. A VARARG function takes REST, a variable or NIL, and is called
with Variants. A REF-COUNTED-RESULT goes into the autorelease pool.
FIXED-ARGUMENTS, an alist of (ENGINE-ARGUMENT . form), are arguments the
function doesn't take, bound to the forms instead. INTO, if not NIL, is the
variable of a first argument, the Lisp value to store the builtin result in."
    (let ((taken-arguments (remove-if (lambda (argument) (assoc argument fixed-arguments))
                                      arguments)))
      `(progn
         (defun ,name (,@(when into (list into))
                       ,@(engine-function-lambda-list (and takes-object object)
                                                      taken-arguments rest))
           ,documentation
           (let (,@(when object `((,object ,object-form)))
                 (,function (initialize-cell-value ,look-up-form))
                 ,@(loop for (argument . form) in fixed-arguments
                         collect `(,(argument-name argument) ,form)))
             (unless ,function
               (error ,@not-found-error))
             ,(let* ((target (make-call-target function object))
                     (call (temporary-names-form
                            taken-arguments
                            (if vararg
                                (or (and (not rest)
                                         (inline-variant-call-form target arguments return-type
                                                                   name))
                                    (variant-call-method-form target arguments return-type
                                                              :rest rest :name name))
                                (ptrcall-method-form target arguments return-type into)))))
                (if ref-counted-result
                    `(autorelease-reference ,call)
                    call))))
         ,@(literal-names-compiler-macro name taken-arguments
                                         (+ (if into 1 0) (if takes-object 1 0))))))

  (defun engine-method-defun (name class-name method-name extra-arguments
                              &key fixed-arguments documentation into)
    "The DEFUN of NAME for DEFINE-ENGINE-METHOD, with the method's hash and
signature from extension_api.json. FIXED-ARGUMENTS, an alist of (argument-name
. form), with the names as in extension_api.json, are arguments of the method
that the function doesn't take, bound to the forms instead (see
DEFINE-SIGNAL-EMITTER). DOCUMENTATION, if given, replaces the docstring. INTO
is as in DEFINE-ENGINE-METHOD."
    (multiple-value-bind (method defining-class) (api-method class-name method-name)
      (when (api-method-virtual-p method)
        (error "~a.~a is a virtual method, which can't be called through a method bind"
               class-name method-name))
      (let* ((vararg (api-method-vararg-p method))
             (static (api-method-static-p method))
             ;; The result comes with a reference (a Ref<T>), which goes into
             ;; the autorelease pool
             (ref-counted-result (let ((type (api-method-return-type method)))
                                   (and type (api-ref-counted-class-p type))))
             ;; A method of a singleton's class is called on the singleton
             (singleton (and (not static) (api-singleton defining-class)))
             (hash (api-method-hash method))
             (return-type (let ((type (api-method-return-type method)))
                            (if type
                                (engine-method-variant-type type "the result")
                                +variant-type-nil+)))
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
        (when (and into vararg)
          (error ":INTO needs a method called with ptrcall, but ~a.~a is a vararg method"
                 class-name method-name))
        (when (and into (not (float-layout return-type)))
          (error ":INTO needs a method whose result is a builtin type made of floats, ~
                  such as Vector2, but ~a.~a returns ~a"
                 class-name method-name (or (api-method-return-type method) "nothing")))
        (let* (;; Further arguments of a vararg method, unless they're declared
               ;; with EXTRA-ARGUMENTS
               (rest (and vararg (not extra-arguments) (intern "ARGUMENTS")))
               (object (gensym "OBJECT"))
               (takes-object (not (or static singleton)))
               (method-bind (gensym "METHOD-BIND")))
          (engine-function-defun
           name
           (or documentation
               (format nil "Call ~:[~;the static method ~]~a.~a(~{~a~^, ~})~@[ with ~a~]~
                            ~@[ on the singleton ~a~]~:[~;, and store the result in INTO, ~
                            which is returned~]."
                       static defining-class method-name
                       (documented-argument-names method rest)
                       (and vararg "Variants")
                       singleton
                       into))
           arguments return-type
           :function method-bind
           :look-up-form `(look-up-method-bind ,defining-class ,method-name ,hash)
           :not-found-error `("The method ~a.~a wasn't found" ,defining-class ,method-name)
           :object object
           :object-form (cond (static '(ffi:make-null-pointer :void))
                              (singleton `(object-pointer (singleton ,singleton)))
                              (t `(object-pointer ,object)))
           :takes-object takes-object
           :vararg vararg
           :rest rest
           :ref-counted-result ref-counted-result
           :into (and into (intern "INTO"))
           :fixed-arguments (loop for (argument-name . form) in fixed-arguments
                                  for symbol = (engine-method-argument-symbol argument-name)
                                  collect (cons (or (find symbol arguments :key #'argument-name)
                                                    (error "~a.~a has no argument ~a"
                                                           class-name method-name argument-name))
                                                form))))))))

(defun look-up-method-bind (class-name method-name hash)
  "The method bind of CLASS-NAME.METHOD-NAME with HASH, for an initialize cell.
Signals an error if Godot has no such method, which INITIALIZE reports like
Godot's own errors."
  (let ((method-bind (get-method-bind class-name method-name hash)))
    (when (ffi:null-pointer-p method-bind)
      (error "Godot has no method ~a.~a with hash ~d. Was extension_api.json ~
dumped from another version of Godot? Run make godot-api."
             class-name method-name hash))
    method-bind))

(defun look-up-utility-function (function-name hash)
  "The function pointer of the utility function FUNCTION-NAME with HASH, for an
initialize cell. Signals an error if Godot has no such function."
  (let ((function (with-string-name (string-name function-name)
                    (variant-get-ptr-utility-function string-name hash))))
    (when (ffi:null-pointer-p function)
      (error "Godot has no utility function ~a with hash ~d. Was extension_api.json ~
dumped from another version of Godot? Run make godot-api."
             function-name hash))
    function))

(defmacro define-engine-method (name (class-name method-name) &key extra-arguments into)
  "Define NAME as a function that calls the method METHOD-NAME of the Godot class
CLASS-NAME (or a class it inherits from). The method's hash, arguments and
return type are looked up in extension_api.json when the macro is expanded.
The function takes the Godot object (a GODOT-OBJECT, or a Godot object pointer;
none if the method is static, or if the class is an engine singleton's, such as
Input, whose methods are called on the singleton) and then the method's
arguments as Lisp values, and returns the result as a Lisp value. Arguments
with a default value are optional, if the default can be expressed in Lisp
(see API-DEFAULT-FORM): bool, int, float, String, StringName, NodePath, null,
empty arrays and dictionaries, and builtin types made of floats, such as
Vector2(0, 0). The arguments are named as in extension_api.json, in Lisp style.

The types are converted as *VALUE-TYPES* says: e.g. a String is a Lisp string,
a Vector2 a VECTOR2, a packed array a vector, an Array a simple vector and a
Dictionary a hash table. A StringName or NodePath argument is a pointer to one
(see SNAME and NPATH) or a string, and a result a string. An Object is its Lisp
object (see LISP-OBJECT), and NIL is null. A Variant argument is converted from
the Lisp value by its type (see WRITE-VARIANT), and a result by the Variant's
type (see READ-VARIANT). A Callable can only be an argument (a CALLABLE). A
method with a type that can't be converted yet signals UNSUPPORTED-API-TYPE.

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
emit_signal(signal, position); TYPE is as in VARIANT-TYPE.

With INTO true, for a method whose result is a builtin type made of floats, such
as Vector2, and whose arguments are all of simple types, the function takes
the Lisp value to store the result in as its first argument, a struct such as a
VECTOR2, and returns it: (NAME into object argument...), like MAP-INTO. For hot
code, as it doesn't make a new struct for the result (80 bytes for a VECTOR2);
the components are still boxed floats. A nested struct, such as the ORIGIN of
a TRANSFORM2D, is changed in place, so it shouldn't be shared."
  (handler-case (engine-method-defun name class-name method-name extra-arguments :into into)
    (error (e)
      (error "In (DEFINE-ENGINE-METHOD ~s (~s ~s)): ~a" name class-name method-name e))))

(defmacro define-signal-emitter (name signal-name arguments)
  "Define NAME as a function that emits the signal SIGNAL-NAME (a string) of an
object with ARGUMENTS, a list of (argument-name type), with TYPE as in
VARIANT-TYPE: (NAME object argument...) is (OBJECT-EMIT-SIGNAL object
SIGNAL-NAME argument...), and returns the Error of emit_signal, but the types are
known when the code is compiled, so if they're all simple (bool, int, float,
Object, StringName, NodePath, or a builtin type made of floats, such as Vector2),
the call is made in one piece of C code that allocates nothing (see
:EXTRA-ARGUMENTS of DEFINE-ENGINE-METHOD), and the signal's StringName is made
once. E.g. (DEFINE-SIGNAL-EMITTER EMIT-HIT \"hit\" ((DAMAGE :INT))) for (EMIT-HIT
PLAYER 5)."
  (handler-case (engine-method-defun
                 name "Object" "emit_signal" arguments
                 :fixed-arguments `(("signal" . (sname ,signal-name)))
                 :documentation (format nil "Emit the signal ~a of OBJECT~@[ with ~{~a~^, ~}~]."
                                        signal-name
                                        (mapcar (lambda (argument)
                                                  (string-upcase (first argument)))
                                                arguments)))
    (error (e)
      (error "In (DEFINE-SIGNAL-EMITTER ~s ~s): ~a" name signal-name e))))
