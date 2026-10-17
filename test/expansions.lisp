;;; The code generated for every engine method in extension_api.json, every
;;; utility function, a vararg method with :EXTRA-ARGUMENTS, and the invokers
;;; of bound methods (GD-EXTENSION-CALLBACK::PTRCALL-INVOKER-FORM) with each
;;; type as an argument and as the result, written to a file, for checking that a change to the code generators doesn't change the
;;; code they generate: `make expansions-baseline` before the change, `make
;;; expansions-check` after it (see the Makefile in the directory above). Run
;;; in that directory, as ecl --norc --load test/expansions.lisp -- --out FILE.
;;;
;;; *GENSYM-COUNTER* is reset before each one, and uninterned symbols are
;;; renamed in the order they first appear, so making the same gensyms in
;;; another order doesn't count as a change.

(require :asdf)
(push (truename "./") asdf:*central-registry*)
(asdf:load-system :gdecl)

(in-package :gd-extension)

(defun canonical-form (form)
  "FORM with its uninterned symbols renamed in the order they first appear."
  (let ((names (make-hash-table :test #'eq))
        (count 0))
    (labels ((walk (x)
               (cond ((and x (symbolp x) (null (symbol-package x)))
                      (or (gethash x names)
                          (setf (gethash x names)
                                (make-symbol
                                 (format nil "~a-~d"
                                         (string-right-trim "0123456789" (symbol-name x))
                                         (incf count))))))
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
                         (lambda () (utility-function-defun 'f function))))
      (incf count)
      (write-expansion out "extra-arguments Object.emit_signal"
                       (lambda ()
                         (engine-method-defun 'f "Object" "emit_signal"
                                              '((damage :int) (where :vector2)))))
      (let ((types (append (loop for type below +variant-type-variant-max+
                                 when (find-value-type type nil) collect type)
                           '(:variant))))
        (dolist (type types)
          (incf count 2)
          (write-expansion out (format nil "invoker argument ~a" type)
                           (lambda ()
                             (gd-extension-callback::ptrcall-invoker-form
                              +variant-type-nil+ (list type +variant-type-int+))))
          (write-expansion out (format nil "invoker result ~a" type)
                           (lambda ()
                             (gd-extension-callback::ptrcall-invoker-form type '())))))
      (format t "~&~d expansions written to ~a~%" count file))))

(write-expansions (second (member "--out" ext:*command-args* :test #'string=)))
(ext:quit)
