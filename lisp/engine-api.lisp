(in-package :gd-extension)

;;;
;;; Defining Godot's API in Lisp from extension_api.json: functions for the
;;; methods of engine classes and constants for their enums and constants
;;; (DEFINE-ENGINE-CLASS), the global enums (DEFINE-GLOBAL-ENUMS) and the
;;; utility functions (DEFINE-UTILITY-FUNCTIONS). Used by the packages GODOT
;;; and GODOT-UTILITY, and by applications for the classes they use.
;;;

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
