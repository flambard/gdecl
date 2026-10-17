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
  ;; (lisp/extension-api/). The path is taken when this file is compiled, since
  ;; the library loaded into Godot has no source files.
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
;;; The API, as Lisp data
;;;
;;; The parts of the API that the layers above use are read into the structs
;;; below when the file is first read, so that nothing outside this file
;;; depends on how extension_api.json is laid out: an engine class is an
;;; API-CLASS, its methods and the utility functions are API-METHODs, their
;;; arguments API-ARGUMENTs, and enums API-ENUMs. The values of enums and the
;;; constants of classes are (name . value). Types are named as Godot names
;;; them, such as "int", "Vector2", "Node" or "enum::Node.ProcessMode".
;;;

(defstruct (api-argument (:copier nil))
  "An argument of an API-METHOD."
  ;; The name, a string
  name
  ;; The name of the type
  type
  ;; The default value, a string in GDScript syntax, or NIL if it has none
  default-value)

(defstruct (api-method (:copier nil))
  "A method of an engine or builtin class, or a utility function."
  ;; The name, a string, such as "get_node"
  name
  ;; The hash that Godot looks it up with
  hash
  ;; The API-ARGUMENTs
  arguments
  ;; The name of the type of the result, or NIL if there's none
  return-type
  vararg-p
  static-p
  virtual-p)

(defstruct (api-enum (:copier nil))
  "An enum of an engine class, or a global enum."
  ;; The name, a string, such as "ProcessMode"
  name
  ;; (name . value) for each of its values, in order
  values)

(defstruct (api-class (:copier nil))
  "An engine class."
  ;; The name, a string, such as "Node2D"
  name
  ;; The name of the class it inherits from, or NIL for Object
  parent-name
  ref-counted-p
  ;; The API-METHODs the class itself defines, not those it inherits
  methods
  ;; The API-ENUMs
  enums
  ;; (name . value) for each of its constants
  constants)

;;;
;;; Reading the JSON into the structs, the only place that knows its layout
;;;

(defun read-named-values (values)
  "VALUES, JSON objects of enum values or constants, as a list of (name . value)."
  (loop for value in values
        collect (cons (json-get value "name") (json-get value "value"))))

(defun read-api-enum (enum)
  (make-api-enum :name (json-get enum "name")
                 :values (read-named-values (json-get enum "values"))))

(defun read-api-method (method)
  "METHOD, the JSON object of a method or utility function, as an API-METHOD.
Methods of engine classes have their result's type in return_value, those of
builtin classes and utility functions in return_type."
  (make-api-method
   :name (json-get method "name")
   :hash (json-get method "hash")
   :arguments (loop for argument in (json-get method "arguments")
                    collect (make-api-argument
                             :name (json-get argument "name")
                             :type (json-get argument "type")
                             :default-value (json-get argument "default_value")))
   :return-type (let ((return-value (json-get method "return_value")))
                  (if return-value
                      (json-get return-value "type")
                      (json-get method "return_type")))
   :vararg-p (json-get method "is_vararg")
   :static-p (json-get method "is_static")
   :virtual-p (json-get method "is_virtual")))

(defun read-api-class (class)
  (make-api-class :name (json-get class "name")
                  :parent-name (json-get class "inherits")
                  :ref-counted-p (json-get class "is_refcounted")
                  :methods (mapcar #'read-api-method (json-get class "methods"))
                  :enums (mapcar #'read-api-enum (json-get class "enums"))
                  :constants (read-named-values (json-get class "constants"))))

(defstruct extension-api
  ;; The API-CLASSes by name
  (classes (make-hash-table :test #'equal))
  ;; The names of the engine singletons by the names of their classes
  (singletons (make-hash-table :test #'equal))
  ;; The utility functions, such as randf_range, as API-METHODs
  (utility-functions '())
  ;; The global enums, such as Error and Key, as API-ENUMs
  (global-enums '())
  ;; The methods of the builtin classes, such as Vector2 and PackedByteArray,
  ;; as lists of API-METHODs by the classes' names
  (builtin-class-methods (make-hash-table :test #'equal)))

(defvar *extension-api* nil
  "The EXTENSION-API, read from *EXTENSION-API-FILE* when first needed.")

(defun extension-api ()
  (or *extension-api*
      (let ((json (extension-api-json))
            (api (make-extension-api)))
        (dolist (class (json-get json "classes"))
          (setf (gethash (json-get class "name") (extension-api-classes api))
                (read-api-class class)))
        (dolist (class (json-get json "builtin_classes"))
          (setf (gethash (json-get class "name") (extension-api-builtin-class-methods api))
                (mapcar #'read-api-method (json-get class "methods"))))
        (setf (extension-api-utility-functions api)
              (mapcar #'read-api-method (json-get json "utility_functions"))
              (extension-api-global-enums api)
              (mapcar #'read-api-enum (json-get json "global_enums")))
        (dolist (singleton (json-get json "singletons"))
          (setf (gethash (json-get singleton "type") (extension-api-singletons api))
                (json-get singleton "name")))
        (setf *extension-api* api))))

;;;
;;; Looking things up
;;;

(defun api-class (class-name)
  "The engine class CLASS-NAME (a string) as an API-CLASS, or NIL."
  (values (gethash class-name (extension-api-classes (extension-api)))))

(defun api-class-names ()
  "The names of all engine classes, in no particular order."
  (loop for class-name being the hash-keys of (extension-api-classes (extension-api))
        collect class-name))

(defun api-singleton (class-name)
  "The name of the engine singleton whose class is CLASS-NAME, such as \"Input\",
or NIL if the class has no singleton."
  (values (gethash class-name (extension-api-singletons (extension-api)))))

(defun api-class-parents ()
  "The engine classes and the classes they inherit from, as an alist of
(class-name . parent-class-name), where PARENT-CLASS-NAME is NIL for Object."
  (loop for class being the hash-values of (extension-api-classes (extension-api))
        collect (cons (api-class-name class) (api-class-parent-name class))))

(defun find-api-method (method-name methods)
  "The API-METHOD named METHOD-NAME (a string) in METHODS, or NIL."
  (find method-name methods :key #'api-method-name :test #'string=))

(defun api-builtin-method-hash (class-name method-name)
  "The hash of the method METHOD-NAME of the builtin class CLASS-NAME (strings),
such as \"PackedByteArray\" and \"size\"."
  (multiple-value-bind (methods found)
      (gethash class-name (extension-api-builtin-class-methods (extension-api)))
    (unless found
      (error "No builtin class ~a in ~a" class-name *extension-api-file*))
    (api-method-hash (or (find-api-method method-name methods)
                         (error "No method ~a in the builtin class ~a" method-name class-name)))))

(defun api-ref-counted-class-p (type)
  "True if TYPE, a type name, is an engine class that's RefCounted, such as a
Resource."
  (let ((class (api-class type)))
    (and class (api-class-ref-counted-p class))))

(defun api-utility-functions ()
  "The utility functions of @GlobalScope, such as randf_range, as API-METHODs."
  (extension-api-utility-functions (extension-api)))

(defun api-global-enums ()
  "The global enums, such as Error and Key, as API-ENUMs."
  (extension-api-global-enums (extension-api)))

(defun api-constant-value (name &optional class-name)
  "The value of NAME (a string, e.g. \"PROPERTY_HINT_NONE\"), a value of a
global enum, or with CLASS-NAME a value of an enum or a constant of that engine
class, or NIL if there's none."
  (flet ((find-value (values)
           (let ((value (assoc name values :test #'string=)))
             (and value (list (cdr value))))))
    (first (if class-name
               (let ((class (or (api-class class-name)
                                (error "No engine class ~a in ~a"
                                       class-name *extension-api-file*))))
                 (or (some (lambda (enum) (find-value (api-enum-values enum)))
                           (api-class-enums class))
                     (find-value (api-class-constants class))))
               (some (lambda (enum) (find-value (api-enum-values enum)))
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
  "The method METHOD-NAME of the engine class CLASS-NAME (both strings) as an
API-METHOD, looked up in the class and then in the classes it inherits from.
The second value is the name of the class that defines it."
  (loop for name = class-name then (api-class-parent-name class)
        for class = (and name (api-class name))
        while class
        do (let ((method (find-api-method method-name (api-class-methods class))))
             (when method
               (return (values method name))))
        finally (error "No method ~a in the engine class ~a or the classes it inherits from (~a)"
                       method-name class-name *extension-api-file*)))

(defun api-virtual-methods (method-name)
  "The virtual methods named METHOD-NAME (a string) of all engine classes, as a
list of (class-name . api-method), sorted by class name."
  (sort (loop for class being the hash-values of (extension-api-classes (extension-api))
              for method = (find-api-method method-name (api-class-methods class))
              when (and method (api-method-virtual-p method))
                collect (cons (api-class-name class) method))
        #'string< :key #'car))
