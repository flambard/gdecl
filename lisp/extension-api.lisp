(in-package :gd-extension)

;;;
;;; Reading extension_api.json, Godot's description of its API (generated with
;;; `make godot-api`), so that macros such as DEFINE-ENGINE-METHOD can look up a
;;; method's hash and signature when they're expanded instead of having them
;;; given by hand. Only used at compile time: the file is read the first time a
;;; macro needs it, in the image that compiles the code, and nothing from it is
;;; looked up at runtime.
;;;

;; extension_api.json is next to gdecl.asd, one directory up from this file.
;; The path is taken when this file is compiled, since the library loaded into
;; Godot has no source files.
(defvar *extension-api-file*
  (let ((this-file #.(or *compile-file-truename* *load-truename*)))
    (make-pathname :name "extension_api" :type "json"
                   :directory (butlast (pathname-directory this-file))
                   :defaults this-file)))

;;;
;;; The API
;;;

(defstruct extension-api
  ;; The classes (JSON objects) by name
  (classes (make-hash-table :test #'equal)))

(defparameter *variant-type-names*
  `(("Nil" . ,+variant-type-nil+)
    ("bool" . ,+variant-type-bool+)
    ("int" . ,+variant-type-int+)
    ("float" . ,+variant-type-float+)
    ("String" . ,+variant-type-string+)
    ("Vector2" . ,+variant-type-vector2+)
    ("Vector2i" . ,+variant-type-vector2i+)
    ("Rect2" . ,+variant-type-rect2+)
    ("Rect2i" . ,+variant-type-rect2i+)
    ("Vector3" . ,+variant-type-vector3+)
    ("Vector3i" . ,+variant-type-vector3i+)
    ("Transform2D" . ,+variant-type-transform2d+)
    ("Vector4" . ,+variant-type-vector4+)
    ("Vector4i" . ,+variant-type-vector4i+)
    ("Plane" . ,+variant-type-plane+)
    ("Quaternion" . ,+variant-type-quaternion+)
    ("AABB" . ,+variant-type-aabb+)
    ("Basis" . ,+variant-type-basis+)
    ("Transform3D" . ,+variant-type-transform3d+)
    ("Projection" . ,+variant-type-projection+)
    ("Color" . ,+variant-type-color+)
    ("StringName" . ,+variant-type-string-name+)
    ("NodePath" . ,+variant-type-node-path+)
    ("RID" . ,+variant-type-rid+)
    ("Object" . ,+variant-type-object+)
    ("Callable" . ,+variant-type-callable+)
    ("Signal" . ,+variant-type-signal+)
    ("Dictionary" . ,+variant-type-dictionary+)
    ("Array" . ,+variant-type-array+)
    ("PackedByteArray" . ,+variant-type-packed-byte-array+)
    ("PackedInt32Array" . ,+variant-type-packed-int32-array+)
    ("PackedInt64Array" . ,+variant-type-packed-int64-array+)
    ("PackedFloat32Array" . ,+variant-type-packed-float32-array+)
    ("PackedFloat64Array" . ,+variant-type-packed-float64-array+)
    ("PackedStringArray" . ,+variant-type-packed-string-array+)
    ("PackedVector2Array" . ,+variant-type-packed-vector2-array+)
    ("PackedVector3Array" . ,+variant-type-packed-vector3-array+)
    ("PackedColorArray" . ,+variant-type-packed-color-array+)
    ("PackedVector4Array" . ,+variant-type-packed-vector4-array+))
  "The variant types by their names in extension_api.json.")

(defvar *extension-api* nil
  "The EXTENSION-API, read from *EXTENSION-API-FILE* when first needed.")

(defun extension-api ()
  (or *extension-api*
      (let ((json (read-json-file *extension-api-file*))
            (api (make-extension-api)))
        (dolist (class (json-get json "classes"))
          (setf (gethash (json-get class "name") (extension-api-classes api)) class))
        (setf *extension-api* api))))

(defun api-class (class-name)
  "The engine class CLASS-NAME (a string) as a JSON object, or NIL."
  (values (gethash class-name (extension-api-classes (extension-api)))))

(defun api-method (class-name method-name)
  "The method METHOD-NAME of the engine class CLASS-NAME (both strings) as a JSON
object, looked up in the class and then in the classes it inherits from. The
second value is the name of the class that defines it."
  (loop for name = class-name then (json-get class "inherits")
        for class = (and name (api-class name))
        while class
        do (let ((method (find method-name (json-get class "methods")
                               :key (lambda (method) (json-get method "name"))
                               :test #'string=)))
             (when method
               (return (values method name))))
        finally (error "No method ~a in the engine class ~a or the classes it inherits from (~a)"
                       method-name class-name *extension-api-file*)))

(defun api-virtual-methods (method-name)
  "The virtual methods named METHOD-NAME (a string) of all engine classes, as a
list of (class-name . method), with the method as a JSON object, sorted by
class name."
  (sort (loop for class being the hash-values of (extension-api-classes (extension-api))
              for method = (find method-name (json-get class "methods")
                                 :key (lambda (method) (json-get method "name"))
                                 :test #'string=)
              when (and method (json-get method "is_virtual"))
                collect (cons (json-get class "name") method))
        #'string< :key #'car))

(defun api-variant-type (type)
  "The variant type of TYPE, a type name from extension_api.json: an int for an
enum or bitfield, Object for an engine class, :VARIANT for Variant."
  (let ((builtin (assoc type *variant-type-names* :test #'string=)))
    (cond (builtin (cdr builtin))
          ((string= type "Variant") :variant)
          ((or (eql 0 (search "enum::" type))
               (eql 0 (search "bitfield::" type)))
           +variant-type-int+)
          ((eql 0 (search "typedarray::" type)) +variant-type-array+)
          ((api-class type) +variant-type-object+)
          (t (error "Unsupported type in extension_api.json: ~a" type)))))

(defun api-default-form (default variant-type)
  "A list of one form for the default value DEFAULT of an argument of
VARIANT-TYPE, a string in GDScript syntax from extension_api.json, or NIL if
it's not supported (yet)."
  (flet ((number-or-nil (string)
           (let ((*read-default-float-format* 'double-float)
                 (*read-eval* nil))
             (let ((number (ignore-errors (read-from-string string))))
               (and (realp number) number))))
         (string-literal (string start)
           ;; "..." without escapes
           (let ((end (1- (length string))))
             (and (> end start)
                  (char= (char string start) #\")
                  (char= (char string end) #\")
                  (not (find #\\ string))
                  (subseq string (1+ start) end))))
         (prefixp (prefix)
           (eql 0 (search prefix default))))
    (cond ((eql variant-type :variant) nil)
          ((= variant-type +variant-type-bool+)
           (cond ((string= default "true") (list t))
                 ((string= default "false") (list nil))))
          ((= variant-type +variant-type-int+)
           (let ((number (number-or-nil default)))
             (and (integerp number) (list number))))
          ((= variant-type +variant-type-float+)
           (let ((number (number-or-nil default)))
             (and number (list (float number 1d0)))))
          ((= variant-type +variant-type-object+)
           (and (string= default "null") (list '(ffi:make-null-pointer :void))))
          ((= variant-type +variant-type-string+)
           (let ((contents (string-literal default 0)))
             (and contents (list contents))))
          ((= variant-type +variant-type-string-name+)
           (let ((contents (and (prefixp "&") (string-literal default 1))))
             (and contents (list `(sname ,contents)))))
          ((= variant-type +variant-type-node-path+)
           (let ((contents (and (prefixp "NodePath(")
                                (string= default ")" :start1 (1- (length default)))
                                (string-literal (subseq default 0 (1- (length default))) 9))))
             (and contents (list `(npath ,contents)))))
          ((= variant-type +variant-type-vector2+)
           (let ((x-y (and (prefixp "Vector2(")
                           (ignore-errors
                            (let ((*read-default-float-format* 'single-float)
                                  (*read-eval* nil))
                              (read-from-string (substitute #\Space #\, (subseq default 7))))))))
             (and (listp x-y)
                  (= (length x-y) 2)
                  (every #'realp x-y)
                  (list `(vector2 ,(float (first x-y) 1.0) ,(float (second x-y) 1.0))))))
          (t nil))))
