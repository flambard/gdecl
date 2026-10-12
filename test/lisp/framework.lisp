(in-package #:gdecl-test)

;;; A small test framework for the tests written in Lisp: DEFTEST defines a
;;; test, CHECK checks something in it, and RUN-TESTS runs them all. The test
;;; runner, run_tests.gd, runs them through the class LispTests (classes.lisp).

(defvar *tests* '()
  "The tests: a list of (name . function), in the order they were defined.")

(defvar *test-name* nil
  "The name of the test that's running.")

(defvar *failures* '()
  "The failure messages of the tests run so far by RUN-TESTS, the last first.")

(defmacro deftest (name &body body)
  "Define the test NAME, a function that runs BODY, which checks things with
CHECK. Defining it again replaces it, keeping its place in the order."
  `(progn
     (defun ,name () ,@body)
     (unless (assoc ',name *tests*)
       (setf *tests* (append *tests* (list (cons ',name ',name)))))
     ',name))

(defun fail (format-control &rest arguments)
  "Record a failure of the running test, with a message made by FORMAT."
  (push (format nil "~(~a~): ~?" *test-name* format-control arguments) *failures*))

(defmacro check (form)
  "Check that FORM is true, or record a failure. If FORM is a function call, its
arguments are evaluated first, so the failure shows their values."
  (if (and (consp form)
           (symbolp (first form))
           (fboundp (first form))
           (not (macro-function (first form)))
           (not (special-operator-p (first form))))
      (let ((arguments (loop repeat (length (rest form)) collect (gensym))))
        `(let ,(mapcar #'list arguments (rest form))
           (unless (,(first form) ,@arguments)
             (fail "~s is false, with the arguments ~{~s~^, ~}" ',form (list ,@arguments)))))
      `(unless ,form
         (fail "~s is false" ',form))))

(defun run-tests ()
  "Run the tests, and return the number of tests and a list of failure messages.
An error in a test is a failure."
  (let ((*failures* '()))
    (loop for (name . function) in *tests*
          do (let ((*test-name* name))
               (handler-case (funcall function)
                 (error (e)
                   (fail "signaled an error: ~a" e)))))
    (values (length *tests*) (reverse *failures*))))
