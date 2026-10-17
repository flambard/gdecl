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
    "The names and DEFCONSTANTs of the enum values and constants of CLASS, an
API-CLASS, as two lists."
    (let ((class-name (api-class-name class))
          (prefix (lisp-style-class-name (api-class-name class)))
          (names '())
          (forms '()))
      (flet ((add (name value documentation)
               (multiple-value-bind (symbol form)
                   (constant-defconstant prefix name value documentation)
                 (push symbol names)
                 (push form forms))))
        (dolist (enum (api-class-enums class))
          (loop for (name . value) in (api-enum-values enum)
                do (add name value
                        (format nil "~a.~a, of the enum ~a." class-name name
                                (api-enum-name enum)))))
        (loop for (name . value) in (api-class-constants class)
              do (add name value (format nil "The constant ~a.~a." class-name name))))
      (values (reverse names) (reverse forms))))

  (defun exporting-progn (package names forms result)
    "The expansion of a macro that defines NAMES with FORMS: a PROGN that exports
NAMES from PACKAGE, also when it's compiled, then has FORMS, and returns
RESULT, a form."
    `(progn
       (eval-when (:compile-toplevel :load-toplevel :execute)
         (export ',names ,package))
       ,@forms
       ,result)))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun engine-object-type-name (class-name)
    "The name of the struct of the objects of the engine class CLASS-NAME, in the
current package: the class name in Lisp style (Node2D is NODE-2D), or with
-OBJECT added if that's a symbol of Common Lisp."
    (let ((name (lisp-style-class-name class-name)))
      (intern (if (find-symbol name :common-lisp)
                  (concatenate 'string name "-OBJECT")
                  name))))

  (defun engine-object-type-form (class-name class)
    "The names to export, and the forms that define the struct of the objects of
the engine class CLASS-NAME (CLASS is its API-CLASS), see engine-objects.lisp."
    (let* ((type (engine-object-type-name class-name))
           (constructor (intern (format nil "%MAKE-~a" (symbol-name type)))))
      (values (list type)
              `((defstruct (,type (:include ,(engine-object-type (api-class-parent-name class)))
                                  (:constructor ,constructor)
                                  (:copier nil)
                                  (:predicate nil)
                                  (:conc-name ,(intern (format nil "%~a-" (symbol-name type)))))
                  ,(format nil "The Lisp object of a Godot object of the class ~a, or of a class ~
                                that inherits from it and isn't defined in Lisp."
                           class-name))
                (eval-when (:compile-toplevel :load-toplevel :execute)
                  (setf (gethash ,class-name *engine-object-types*) ',type))
                (register-engine-object-type ,class-name #',constructor))))))

(defmacro define-engine-class (class-name)
  "Define a function for each method of the engine class CLASS-NAME (a string)
that DEFINE-ENGINE-METHOD can call, named after the class and the method in
Lisp style, and exported from the package GODOT: Node2D.get_position becomes
GODOT:NODE-2D-GET-POSITION. Only the methods the class itself defines get
functions, not those it inherits, so call get_position of a Sprite2D with
NODE-2D-GET-POSITION. Methods with types that aren't supported yet, and
virtual methods, are skipped. Also define a constant for each value of the
class's enums and each of its constants, named likewise:
Node.PROCESS_MODE_ALWAYS becomes GODOT:+NODE-PROCESS-MODE-ALWAYS+. And define
a struct for the Lisp objects of the class's objects, named like the class,
GODOT:NODE-2D, which includes that of the nearest class it inherits from that's
defined, so they mirror Godot's inheritance: (TYPEP OBJECT 'NODE-2D),
TYPECASE and DEFMETHOD work. Define the classes an application uses after
those they inherit from. GODOT already has the most used classes; an
application defines the others it uses, and they're added to GODOT too."
  (let* ((class (or (api-class class-name)
                    (error "No engine class ~a in ~a" class-name *extension-api-file*)))
         (prefix (lisp-style-class-name class-name))
         ;; The functions' names, and their arguments' names, are in GODOT
         (*package* (find-package :godot))
         (names '())
         (forms '()))
    (dolist (method (api-class-methods class))
      (let ((method-name (api-method-name method)))
        (unless (api-method-virtual-p method)
          (let* ((name (intern (format nil "~a-~a" prefix (lisp-style-method-name method-name))))
                 ;; NIL if the method has types that can't be converted yet
                 (form (handler-case (engine-method-defun name class-name method-name '())
                         (unsupported-api-type () nil))))
            (when form
              (push name names)
              (push form forms))))))
    (multiple-value-bind (constant-names constant-forms) (class-constant-defconstants class)
      (multiple-value-bind (type-names type-forms) (engine-object-type-form class-name class)
        (exporting-progn :godot (append type-names constant-names (reverse names))
                         (append type-forms constant-forms (reverse forms))
                         `',class-name)))))

(defmacro define-global-enums ()
  "Define a constant for each value of Godot's global enums (such as Error, Key
and PropertyHint), named in Lisp style and exported from the package GODOT: OK
becomes GODOT:+OK+ and KEY_ESCAPE GODOT:+KEY-ESCAPE+."
  (let ((*package* (find-package :godot))
        (names '())
        (forms '()))
    (dolist (enum (api-global-enums))
      (loop for (name . value) in (api-enum-values enum)
            do (multiple-value-bind (symbol form)
                   (constant-defconstant nil name value
                                         (format nil "~a, of the global enum ~a."
                                                 name (api-enum-name enum)))
                 (push symbol names)
                 (push form forms))))
    (exporting-progn :godot (reverse names) (reverse forms) nil)))

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

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun utility-function-defun (name function)
    "The DEFUN of NAME, a function that calls the utility function FUNCTION, an
API-METHOD, like those of DEFINE-ENGINE-METHOD."
    (let* ((function-name (api-method-name function))
           (vararg (api-method-vararg-p function))
           (hash (api-method-hash function))
           (return-type (let ((type (api-method-return-type function)))
                          (if type
                              (engine-method-variant-type type "the result")
                              +variant-type-nil+)))
           (arguments (engine-method-arguments function))
           (rest (and vararg (intern "ARGUMENTS"))))
      (engine-function-defun
       name
       (format nil "Call the utility function ~a(~{~a~^, ~}) of @GlobalScope~@[ with ~a~]."
               function-name
               (documented-argument-names function rest)
               (and vararg "Variants"))
       arguments return-type
       :function (gensym "FUNCTION")
       :look-up-form `(look-up-utility-function ,function-name ,hash)
       :not-found-error `("The utility function ~a wasn't found" ,function-name)
       :vararg vararg
       :rest rest))))

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
      (let* ((function-name (api-method-name function))
             (lisp-name (cond ((string= function-name "print") "GODOT-PRINT")
                              ((find-symbol (lisp-style-method-name function-name)
                                            :common-lisp)
                               nil)
                              (t (lisp-style-method-name function-name))))
             (name (and lisp-name (intern lisp-name)))
             ;; NIL if the function has types that can't be converted yet
             (form (and name
                        (handler-case (utility-function-defun name function)
                          (unsupported-api-type () nil)))))
        (when form
          (push name names)
          (push form forms))))
    (exporting-progn :godot-utility (reverse names) (reverse forms) nil)))
