(in-package :gd-extension)

;;;
;;; The Lisp-style layer of the framework, the package GD-EXTENSION. Built on
;;; EXTENSION-API-JSON (extension-api.lisp), which reads extension_api.json,
;;; GD-EXTENSION-FFI (gd-extension-ffi.lisp), which maps the C interface,
;;; GD-EXTENSION-BUILTINS (builtin-types.lisp), Godot's builtin types in Lisp,
;;; GD-EXTENSION-TYPES (gd-extension-types.lisp), which converts values between
;;; Godot and Lisp, and GD-EXTENSION-CALLBACK (gd-extension-callback.lisp and
;;; the files after it in gdecl.asd), which handles Godot's calls into Lisp.
;;;
;;; This file has the helpers and the values looked up once (SNAME, NPATH,
;;; SINGLETON). The rest of the package is in
;;; api-types.lisp (the types of extension_api.json), engine-methods.lisp
;;; (calling engine methods, and the code generated for each, which the
;;; generators of GODOT build on), engine-objects.lisp (the structs of engine
;;; objects), containers.lisp (packed arrays, Arrays and
;;; Dictionaries), references.lisp, signals.lisp (also Signals as values),
;;; callables.lisp (Callables as values), registration.lisp
;;; (registering classes, methods, properties, signals, virtual methods and
;;; singletons, and the classes registered when Godot initializes the
;;; extension) and objects.lisp (making and freeing objects). DEFINE-CLASS is
;;; a layer of its own above, GODOT-DSL (dsl/).
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

;; The names of engine classes and methods in Lisp style, for the functions that
;; DEFINE-ENGINE-CLASS (GODOT-GENERATORS, godot/) defines, and the readers and
;; writers of packed arrays (containers.lisp)
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

(defun get-method-bind (class-name method-name hash)
  "The GDExtensionMethodBindPtr of the method METHOD-NAME of the class
CLASS-NAME (both strings). HASH is the hash of the method's signature, from
extension_api.json; the result is NULL if it doesn't match."
  (with-string-name (class-string-name class-name)
    (with-string-name (method-string-name method-name)
      (classdb-get-method-bind class-string-name method-string-name hash))))

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

(defmacro initialize-cell-value (form)
  "The value of FORM, computed once, in an initialize cell (see
GD-EXTENSION-CALLBACK:MAKE-INITIALIZE-CELL): when Godot initializes the
extension, or when the code is loaded if it already has (e.g. at a REPL)."
  `(car (load-time-value (make-initialize-cell (lambda () ,form)))))

;; The StringNames and NodePaths made by NEW-STRING-NAME and NEW-NODE-PATH,
;; destroyed by DESTROY-PERMANENT-VALUES when Godot unloads the extension
(defvar *permanent-string-names* '())
(defvar *permanent-node-paths* '())

(defun new-string-name (contents)
  "A StringName created from the string CONTENTS, in memory from MEM-ALLOC. Kept
until Godot unloads the extension."
  (let ((string-name (mem-alloc +string-name-size+)))
    (write-string-name string-name contents)
    (push string-name *permanent-string-names*)
    string-name))

(defmacro sname (string)
  "A pointer to a StringName with STRING, a literal string. The StringName is
created once, like SNAME() in Godot's C++ code, and kept until Godot unloads the
extension."
  `(initialize-cell-value (new-string-name ,string)))

(defun new-node-path (path)
  "A NodePath created from the string PATH, in memory from MEM-ALLOC. Kept until
Godot unloads the extension."
  (let ((node-path (mem-alloc +node-path-size+)))
    (write-node-path node-path path)
    (push node-path *permanent-node-paths*)
    node-path))

(defun destroy-permanent-values ()
  "Destroy the StringNames and NodePaths made by NEW-STRING-NAME and
NEW-NODE-PATH, and free their memory, so that Godot doesn't report them as
leaked. A step of the framework's shutdown (see lifecycle.lisp). Afterwards,
SNAME and NPATH values must not be used any more."
  (dolist (string-name *permanent-string-names*)
    (string-name-destructor string-name)
    (mem-free string-name))
  (dolist (node-path *permanent-node-paths*)
    (node-path-destructor node-path)
    (mem-free node-path))
  (setf *permanent-string-names* '()
        *permanent-node-paths* '()))

(defmacro npath (path)
  "A pointer to a NodePath with PATH, a literal string, like ^\"path\" in GDScript.
The NodePath is created once and kept until Godot unloads the extension."
  `(initialize-cell-value (new-node-path ,path)))

;; A literal string given for a StringName or NodePath, as an argument of an
;; engine method or a default value, becomes an SNAME or NPATH (see
;; GD-EXTENSION::LITERAL-NAMES-COMPILER-MACRO)
(setf (value-type-literal-macro (find-value-type +variant-type-string-name+)) 'sname
      (value-type-literal-macro (find-value-type +variant-type-node-path+)) 'npath)

(defun look-up-singleton (name)
  "The Lisp object of the engine singleton NAME, a string, or NIL."
  (with-string-name (string-name name)
    (lisp-object (global-get-singleton string-name))))

(defmacro singleton (name)
  "The Lisp object of the engine singleton NAME, a literal string such as
\"Input\" (see LISP-OBJECT). Looked up the first time it's used, not when Godot
initializes the extension, so that it also finds singletons that the extension
registers itself (see REGISTER-SINGLETON)."
  (let ((cell (gensym "CELL")))
    `(let ((,cell (load-time-value (list nil))))
       (or (car ,cell)
           (setf (car ,cell) (look-up-singleton ,name))))))
