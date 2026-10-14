(in-package :gd-extension)

;;;
;;; The Lisp-style layer of the framework: initialization, helpers and macros,
;;; and registering classes and binding Lisp functions as methods, properties
;;; and signals. Built on the package GD-EXTENSION-FFI (gd-extension-ffi.lisp),
;;; which maps the C interface, GD-EXTENSION-TYPES (gd-extension-types.lisp),
;;; Godot's builtin types in Lisp, and GD-EXTENSION-CALLBACK
;;; (gd-extension-callback.lisp), which handles Godot's calls into Lisp.
;;;
;;; This file has the helpers and the values looked up once. The rest of the
;;; package is in engine-methods.lisp (calling engine methods), engine-api.lisp
;;; (DEFINE-ENGINE-CLASS, the global enums and the utility functions),
;;; references.lisp, signals.lisp, binding.lisp (registering classes, methods,
;;; properties, signals and virtual methods) and define-class.lisp.
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
  `(with-foreign-memory ((,var 'string-name))
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
  `(with-foreign-memory ((,var 'godot-string))
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
    (string-name-new-with-latin1-chars string-name contents)
    (push string-name *permanent-string-names*)
    string-name))

(defmacro sname (string)
  "A pointer to a StringName with STRING, a literal string. The StringName is
created once, like SNAME() in Godot's C++ code, and kept until Godot unloads the
extension."
  `(initialize-cell-value (new-string-name ,string)))

(defun construct-node-path (pointer path)
  "Construct a NodePath at POINTER, uninitialized memory, from the string PATH.
Destroy it with NODE-PATH-DESTRUCTOR."
  (with-string (string path)
    (with-foreign-memory ((args '(:array :pointer-void 1)))
      (setf (foreign-ref args :pointer-void 0) string)
      ;; Constructor 2 of NodePath takes a String
      (call-ptr-constructor (initialize-cell-value
                             (variant-get-ptr-constructor +variant-type-node-path+ 2))
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
  `(initialize-cell-value (new-node-path ,path)))

(defmacro singleton (name)
  "The Lisp object of the engine singleton NAME, a literal string such as
\"Input\" (see LISP-OBJECT). Looked up once."
  `(initialize-cell-value
    (with-string-name (string-name ,name)
      (lisp-object (global-get-singleton string-name)))))
