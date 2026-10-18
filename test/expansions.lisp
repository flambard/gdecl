;;; The code generated for every engine method in extension_api.json, every
;;; utility function, every engine class, the global enums and the utility
;;; functions as a whole, a vararg method with :EXTRA-ARGUMENTS, and the invokers
;;; of bound methods (GD-EXTENSION-CALLBACK::PTRCALL-INVOKER-FORM and
;;; VARIANT-INVOKER-FORM) with each type as an argument and as the result,
;;; written to a file, for checking that a change to the code generators
;;; doesn't change the code they generate: `make expansions-baseline` before
;;; the change, `make expansions-check` after it (see the Makefile in the
;;; directory above). Run in that directory, as ecl --norc --load
;;; test/expansions.lisp -- --out FILE.
;;;
;;; *GENSYM-COUNTER* is reset before each one, and uninterned symbols are
;;; renamed in the order they first appear, so making the same gensyms in
;;; another order doesn't count as a change. Symbols other than those of
;;; COMMON-LISP and keywords are written with their home package, as
;;; PACKAGE::NAME, so a change to what a package exports doesn't count as one
;;; either, but moving a symbol to another package does.

(require :asdf)
(push (truename "./") asdf:*central-registry*)
(asdf:load-system :gdecl)

(in-package :gd-extension)

(defstruct (qualified-symbol (:constructor qualified-symbol (symbol)))
  "A symbol, written as PACKAGE::NAME with its home package, whatever package
is current and whether it's exported."
  symbol)

(defmethod print-object ((qualified qualified-symbol) stream)
  (let ((symbol (qualified-symbol-symbol qualified)))
    (format stream "~a::~a" (package-name (symbol-package symbol)) (symbol-name symbol))))

(defun canonical-form (form)
  "FORM with its uninterned symbols renamed in the order they first appear, and
the symbols of packages other than COMMON-LISP and KEYWORD as QUALIFIED-SYMBOLs."
  (let ((names (make-hash-table :test #'eq))
        (count 0)
        (common-lisp (find-package :common-lisp)))
    (labels ((walk (x)
               (cond ((and x (symbolp x) (null (symbol-package x)))
                      (or (gethash x names)
                          (setf (gethash x names)
                                (make-symbol
                                 (format nil "~a-~d"
                                         (string-right-trim "0123456789" (symbol-name x))
                                         (incf count))))))
                     ((and x (symbolp x) (not (keywordp x))
                           (not (eq (symbol-package x) common-lisp)))
                      (qualified-symbol x))
                     ((consp x) (cons (walk (car x)) (walk (cdr x))))
                     (t x))))
      (walk form))))

(defun write-expansion (out label function)
  "Write LABEL and the form FUNCTION returns, or the error it signals, to OUT."
  (setf *gensym-counter* 0)
  (let ((form (handler-case (funcall function)
                (unsupported-api-type (e) (list :unsupported (princ-to-string e)))
                (error (e) (list :error (princ-to-string e)))))
        (*print-circle* nil)
        (*print-pretty* nil)
        (*package* (find-package :gd-extension)))
    (format out "~a ~s~%" label (canonical-form form))))

(defun write-expansions (file)
  (with-open-file (out file :direction :output :if-exists :supersede)
    (let ((count 0))
      (dolist (class-name (sort (api-class-names) #'string<))
        (dolist (method (api-class-methods (api-class class-name)))
          (unless (api-method-virtual-p method)
            (incf count)
            (write-expansion out (format nil "~a.~a" class-name (api-method-name method))
                             (lambda ()
                               (engine-method-defun 'f class-name (api-method-name method)
                                                    nil))))))
      (dolist (function (api-utility-functions))
        (incf count)
        (write-expansion out (format nil "utility ~a" (api-method-name function))
                         (lambda () (godot-generators::utility-function-defun 'f function))))
      ;; The whole expansions of the generators of GODOT and GODOT-UTILITY: for
      ;; the structs, constants and exports around the functions above
      (dolist (class-name (sort (copy-list (api-class-names)) #'string<))
        (incf count)
        (write-expansion out (format nil "define-engine-class ~a" class-name)
                         (lambda () (macroexpand-1 `(godot:define-engine-class ,class-name)))))
      (incf count 2)
      (write-expansion out "define-global-enums"
                       (lambda () (macroexpand-1 '(godot-generators:define-global-enums))))
      (write-expansion out "define-utility-functions"
                       (lambda () (macroexpand-1 '(godot-generators:define-utility-functions))))
      (incf count)
      (write-expansion out "extra-arguments Object.emit_signal"
                       (lambda ()
                         (engine-method-defun 'f "Object" "emit_signal"
                                              '((damage :int) (where :vector2)))))
      (let ((types (append (loop for type below +variant-type-variant-max+
                                 when (find-value-type type nil) collect type)
                           '(:variant))))
        (dolist (type types)
          (incf count 4)
          (write-expansion out (format nil "invoker argument ~a" type)
                           (lambda ()
                             (gd-extension-callback::ptrcall-invoker-form
                              +variant-type-nil+ (list type +variant-type-int+))))
          (write-expansion out (format nil "invoker result ~a" type)
                           (lambda ()
                             (gd-extension-callback::ptrcall-invoker-form type '())))
          (write-expansion out (format nil "Variant invoker argument ~a" type)
                           (lambda ()
                             (gd-extension-callback::variant-invoker-form
                              +variant-type-nil+ (list type +variant-type-int+))))
          (write-expansion out (format nil "Variant invoker result ~a" type)
                           (lambda ()
                             (gd-extension-callback::variant-invoker-form type '())))))
      (format t "~&~d expansions written to ~a~%" count file))))

(write-expansions (second (member "--out" ext:*command-args* :test #'string=)))
(ext:quit)
