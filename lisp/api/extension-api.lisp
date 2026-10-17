;;;; extension_api.json, Godot's description of its API (generated with
;;;; `make godot-api`), read when the code is compiled, so that the layers above
;;;; can look up what they need in it instead of having it given by hand: the
;;;; sizes of Godot's builtin types for GD-EXTENSION-FFI (API-BUILTIN-SIZE), and
;;;; the classes, methods, enums and utility functions for the code generators
;;;; of GD-EXTENSION, such as DEFINE-ENGINE-METHOD. Only used at compile time:
;;;; the file is read the first time a macro needs it, in the image that
;;;; compiles the code, and nothing from it is looked up at runtime. The API's
;;;; types as gdecl's variant types are in api-types.lisp in GD-EXTENSION, as
;;;; they need the variant types of GD-EXTENSION-FFI.

(in-package :gd-extension-api)

;;;
;;; The file
;;;

(eval-when (:compile-toplevel :load-toplevel :execute)
  ;; extension_api.json is next to gdecl.asd, two directories up from this file
  ;; (lisp/api/). The path is taken when this file is compiled, since the
  ;; library loaded into Godot has no source files.
  (defvar *extension-api-file*
    (let ((this-file #.(or *compile-file-truename* *load-truename*)))
      (make-pathname :name "extension_api" :type "json"
                     :directory (butlast (pathname-directory this-file) 2)
                     :defaults this-file)))

  (defvar *extension-api-json* nil
    "extension_api.json as JSON, read the first time it's needed.")

  (defun extension-api-json ()
    "extension_api.json as JSON, read once (about half a second). Only for code
generation: the library loaded into Godot never reads it."
    (or *extension-api-json*
        (setf *extension-api-json* (read-json-file *extension-api-file*)))))

(defmacro api-builtin-size (class-name)
  "The size in bytes of the builtin class CLASS-NAME, a literal string such as
\"StringName\" or \"Variant\", from builtin_class_sizes in extension_api.json
(build configuration float_64, where real_t is float), when the code is
compiled."
  (let* ((configuration (find "float_64" (json-get (extension-api-json)
                                                   "builtin_class_sizes")
                              :key (lambda (sizes)
                                     (json-get sizes "build_configuration"))
                              :test #'string=))
         (size (find class-name (json-get configuration "sizes")
                     :key (lambda (size) (json-get size "name"))
                     :test #'string=)))
    (if size
        (json-get size "size")
        (error "No size of the builtin class ~a in ~a" class-name *extension-api-file*))))

;;;
;;; The API
;;;

(defstruct extension-api
  ;; The classes (JSON objects) by name
  (classes (make-hash-table :test #'equal))
  ;; The names of the engine singletons by the names of their classes
  (singletons (make-hash-table :test #'equal))
  ;; The utility functions (JSON objects), such as randf_range
  (utility-functions '())
  ;; The global enums (JSON objects), such as Error and Key
  (global-enums '())
  ;; The builtin classes (JSON objects), such as Vector2 and PackedByteArray,
  ;; by name
  (builtin-classes (make-hash-table :test #'equal)))

(defvar *extension-api* nil
  "The EXTENSION-API, read from *EXTENSION-API-FILE* when first needed.")

(defun extension-api ()
  (or *extension-api*
      (let ((json (extension-api-json))
            (api (make-extension-api)))
        (dolist (class (json-get json "classes"))
          (setf (gethash (json-get class "name") (extension-api-classes api)) class))
        (dolist (class (json-get json "builtin_classes"))
          (setf (gethash (json-get class "name") (extension-api-builtin-classes api)) class))
        (setf (extension-api-utility-functions api) (json-get json "utility_functions")
              (extension-api-global-enums api) (json-get json "global_enums"))
        (dolist (singleton (json-get json "singletons"))
          (setf (gethash (json-get singleton "type") (extension-api-singletons api))
                (json-get singleton "name")))
        (setf *extension-api* api))))

(defun api-class (class-name)
  "The engine class CLASS-NAME (a string) as a JSON object, or NIL."
  (values (gethash class-name (extension-api-classes (extension-api)))))

(defun api-singleton (class-name)
  "The name of the engine singleton whose class is CLASS-NAME, such as \"Input\",
or NIL if the class has no singleton."
  (values (gethash class-name (extension-api-singletons (extension-api)))))

(defun api-class-parents ()
  "The engine classes and the classes they inherit from, as an alist of
(class-name . parent-class-name), where PARENT-CLASS-NAME is NIL for Object."
  (loop for class being the hash-values of (extension-api-classes (extension-api))
        collect (cons (json-get class "name") (json-get class "inherits"))))

(defun json-class-method (class method-name)
  "The method METHOD-NAME (a string) of CLASS, a class from extension_api.json,
as a JSON object, or NIL if the class itself has none."
  (find method-name (json-get class "methods")
        :key (lambda (method) (json-get method "name"))
        :test #'string=))

(defun api-builtin-method-hash (class-name method-name)
  "The hash of the method METHOD-NAME of the builtin class CLASS-NAME (strings),
such as \"PackedByteArray\" and \"size\"."
  (let* ((class (or (gethash class-name (extension-api-builtin-classes (extension-api)))
                    (error "No builtin class ~a in ~a" class-name *extension-api-file*)))
         (method (or (json-class-method class method-name)
                     (error "No method ~a in the builtin class ~a" method-name class-name))))
    (json-get method "hash")))

(defun api-ref-counted-class-p (type)
  "True if TYPE, a type name from extension_api.json, is an engine class that's
RefCounted, such as a Resource."
  (let ((class (api-class type)))
    (and class (json-get class "is_refcounted"))))

(defun api-utility-functions ()
  "The utility functions of @GlobalScope, such as randf_range, as JSON objects."
  (extension-api-utility-functions (extension-api)))

(defun api-global-enums ()
  "The global enums, such as Error and Key, as JSON objects."
  (extension-api-global-enums (extension-api)))

(defun api-constant-value (name &optional class-name)
  "The value of NAME (a string, e.g. \"PROPERTY_HINT_NONE\"), a value of a
global enum, or with CLASS-NAME a value of an enum or a constant of that engine
class, or NIL if there's none."
  (flet ((find-value (values)
           (let ((value (find name values
                              :key (lambda (value) (json-get value "name"))
                              :test #'string=)))
             (and value (list (json-get value "value"))))))
    (first (if class-name
               (let ((class (or (api-class class-name)
                                (error "No engine class ~a in ~a"
                                       class-name *extension-api-file*))))
                 (or (some (lambda (enum) (find-value (json-get enum "values")))
                           (json-get class "enums"))
                     (find-value (json-get class "constants"))))
               (some (lambda (enum) (find-value (json-get enum "values")))
                     (api-global-enums))))))

(defmacro api-constant (name &optional class-name)
  "The value of NAME, a literal string, as in API-CONSTANT-VALUE, looked up in
extension_api.json when the code is compiled: for constants that the lower
layers need, which can't use those that DEFINE-GLOBAL-ENUMS and
DEFINE-ENGINE-CLASS define in GODOT."
  (or (api-constant-value name class-name)
      (error "No constant ~a~@[ in the class ~a~] in ~a" name class-name
             *extension-api-file*)))

(defun api-method (class-name method-name)
  "The method METHOD-NAME of the engine class CLASS-NAME (both strings) as a JSON
object, looked up in the class and then in the classes it inherits from. The
second value is the name of the class that defines it."
  (loop for name = class-name then (json-get class "inherits")
        for class = (and name (api-class name))
        while class
        do (let ((method (json-class-method class method-name)))
             (when method
               (return (values method name))))
        finally (error "No method ~a in the engine class ~a or the classes it inherits from (~a)"
                       method-name class-name *extension-api-file*)))

(defun api-virtual-methods (method-name)
  "The virtual methods named METHOD-NAME (a string) of all engine classes, as a
list of (class-name . method), with the method as a JSON object, sorted by
class name."
  (sort (loop for class being the hash-values of (extension-api-classes (extension-api))
              for method = (json-class-method class method-name)
              when (and method (json-get method "is_virtual"))
                collect (cons (json-get class "name") method))
        #'string< :key #'car))
