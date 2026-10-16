(in-package :gd-extension-types)

;;;
;;; Strings, StringNames and NodePaths: creating, reading and destroying them.
;;; Godot's three string types are all made from Lisp strings, and read as
;;; Lisp strings. The StringNames and NodePaths that are made once and kept,
;;; GD-EXTENSION:SNAME and NPATH, are in gd-extension.lisp.
;;;

(defun read-godot-string (pointer)
  "The Godot String at POINTER as a Lisp string."
  (let* ((length (string-to-utf8-chars pointer (ffi:make-null-pointer :void) 0))
         (octets (make-array length :element-type '(unsigned-byte 8))))
    (string-to-utf8-chars pointer (si:make-foreign-data-from-array octets) length)
    (ext:octets-to-string octets :external-format :utf-8)))

(defun write-godot-string (pointer string)
  "Construct a Godot String at POINTER, uninitialized memory, from the Lisp
STRING. Destroy it with STRING-DESTRUCTOR."
  (string-new-with-utf8-chars pointer string))

(defmacro with-string ((var contents) &body body)
  "Evaluate BODY with VAR bound to a pointer to a Godot String created from the
Lisp string CONTENTS. The String is destroyed when BODY exits, also on a
non-local exit."
  `(with-foreign-memory ((,var 'godot-string))
     (write-godot-string ,var ,contents)
     (unwind-protect (progn ,@body)
       (string-destructor ,var))))

(defun read-string-from (constructor pointer)
  "The Godot String that CONSTRUCTOR, a String constructor, makes from the value
at POINTER, as a Lisp string."
  (with-foreign-memory ((string 'godot-string)
                        (args '(:array :pointer-void 1)))
    (setf (foreign-ref args :pointer-void 0) pointer)
    (call-ptr-constructor constructor string args)
    (unwind-protect (read-godot-string string)
      (string-destructor string))))

(defun read-string-name (pointer)
  "The StringName at POINTER as a Lisp string."
  (read-string-from *string-from-string-name-constructor* pointer))

(defun write-string-name (pointer string)
  "Construct a StringName at POINTER, uninitialized memory, from the Lisp
STRING. Destroy it with STRING-NAME-DESTRUCTOR."
  (string-name-new-with-utf8-chars pointer string))

(defmacro with-string-name ((var contents) &body body)
  "Evaluate BODY with VAR bound to a pointer to a StringName created from the
string CONTENTS. The StringName is destroyed when BODY exits, also on a
non-local exit."
  `(with-foreign-memory ((,var 'string-name))
     (write-string-name ,var ,contents)
     (unwind-protect (progn ,@body)
       (string-name-destructor ,var))))

(defun string-name-equal (a b)
  "True if the StringNames at A and B are equal."
  (with-foreign-memory ((result :uint8-t))
    (call-ptr-operator-evaluator *string-name-equal-evaluator* a b result)
    (/= (foreign-ref result :uint8-t) 0)))

(defun read-node-path (pointer)
  "The NodePath at POINTER as a Lisp string."
  (read-string-from *string-from-node-path-constructor* pointer))

(defun write-node-path (pointer path)
  "Construct a NodePath at POINTER, uninitialized memory, from the Lisp string
PATH. Destroy it with NODE-PATH-DESTRUCTOR."
  (with-string (string path)
    (with-foreign-memory ((args '(:array :pointer-void 1)))
      (setf (foreign-ref args :pointer-void 0) string)
      (call-ptr-constructor *node-path-from-string-constructor* pointer args))))

;;;
;;; Temporary names, for engine methods called with a StringName or NodePath
;;; argument that's a Lisp string only known at runtime (see
;;; GD-EXTENSION::TEMPORARY-NAMES-FORM)
;;;

(defun make-temporary-name (variant-type string)
  "A StringName or NodePath (by VARIANT-TYPE) created from the Lisp STRING, in
memory from MEM-ALLOC. Destroy it with DESTROY-TEMPORARY-NAME."
  (if (= variant-type +variant-type-string-name+)
      (let ((string-name (mem-alloc +string-name-size+)))
        (write-string-name string-name string)
        string-name)
      (let ((node-path (mem-alloc +node-path-size+)))
        (write-node-path node-path string)
        node-path)))

(defun destroy-temporary-name (variant-type name)
  "Destroy NAME, made by MAKE-TEMPORARY-NAME, and free its memory."
  (if (= variant-type +variant-type-string-name+)
      (string-name-destructor name)
      (node-path-destructor name))
  (mem-free name))
