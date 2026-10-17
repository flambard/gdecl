(in-package :gd-extension)

;;;
;;; The types of extension_api.json (see EXTENSION-API-JSON, extension-api/) as
;;; gdecl's variant types, for the code generators, and the condition they
;;; signal for a type that gdecl can't convert yet.
;;;

(define-condition unsupported-api-type (simple-error)
  ()
  (:documentation "Signaled while generating code from extension_api.json for a
type that gdecl can't convert yet. DEFINE-ENGINE-CLASS and
DEFINE-UTILITY-FUNCTIONS skip the methods that signal it; any other error is a
real one."))

(defun unsupported-api-type (format-control &rest format-arguments)
  "Signal UNSUPPORTED-API-TYPE with a message made by FORMAT."
  (error 'unsupported-api-type :format-control format-control
                               :format-arguments format-arguments))

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
          (t (unsupported-api-type "Unsupported type in extension_api.json: ~a" type)))))
