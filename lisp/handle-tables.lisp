(in-package :gd-extension-callback)

;;;
;;; Handle tables
;;;
;;; Godot holds on to Lisp values only through the handles Lisp gives it: the
;;; class_userdata of classes, the method_userdata of methods, instance
;;; pointers, instance bindings and the callable_userdata of Callables. A Lisp
;;; value can't be given to C, so a handle table keeps the values, which also
;;; keeps them reachable for the GC, and a handle is a pointer whose address is
;;; (1+ index) into the table, so that it's never NULL. Removed elements are
;;; reused. All of gdecl's tables are handle tables, so changing how they work,
;;; e.g. keying classes and methods by name (J in TODO.md) or making them
;;; thread-safe (R), is done here.
;;;

(defmacro define-handle-table (name &optional documentation)
  "Define NAME, a special variable, as an empty handle table: an adjustable
vector of the values, NIL where one was removed. The indices of the removed
elements, for reuse, are kept on NAME's property list, as only ADD-HANDLE and
REMOVE-HANDLE need them; a lookup is just an AREF of the variable's vector."
  `(progn
     (defvar ,name (make-array 0 :adjustable t :fill-pointer t) ,@(when documentation
                                                                     (list documentation)))
     (setf (get ',name 'free-handles) '())
     ',name))

;; Macros, not functions: looking up a handle is on the per-call path of every
;; callback, and expands to the AREF of the table's variable, as fast as
;; possible (measured with `make bench`: going through a struct cost 10-30 ns
;; a call)
(defmacro address-handle-value (table address)
  "The value in TABLE (a variable defined with DEFINE-HANDLE-TABLE) of the
handle whose address is ADDRESS, an integer."
  `(aref ,table (1- ,address)))

(defmacro handle-value (table handle)
  "The value in TABLE (a variable defined with DEFINE-HANDLE-TABLE) of HANDLE, a
pointer."
  `(address-handle-value ,table (ffi:pointer-address ,handle)))

(defun add-handle-to (name value)
  (let* ((elements (symbol-value name))
         (index (if (get name 'free-handles)
                    (let ((index (pop (get name 'free-handles))))
                      (setf (aref elements index) value)
                      index)
                    (vector-push-extend value elements))))
    (ffi:make-pointer (1+ index) :void)))

(defmacro add-handle (table value)
  "Keep VALUE in TABLE (a variable defined with DEFINE-HANDLE-TABLE), and return
its handle."
  `(add-handle-to ',table ,value))

(defun remove-handle-from (name handle)
  (let* ((elements (symbol-value name))
         (index (1- (ffi:pointer-address handle)))
         (value (aref elements index)))
    (setf (aref elements index) nil)
    (push index (get name 'free-handles))
    value))

(defmacro remove-handle (table handle)
  "Forget the value of HANDLE in TABLE (a variable defined with
DEFINE-HANDLE-TABLE), and return it. The handle is reused."
  `(remove-handle-from ',table ,handle))

(defun find-handle-value (table predicate)
  "The first value in TABLE (the vector of a handle table) for which PREDICATE
is true, or NIL."
  (find-if (lambda (value) (and value (funcall predicate value))) table))

(defmacro do-handle-values ((variable table) &body body)
  "Evaluate BODY with VARIABLE bound to each value in TABLE (a variable defined
with DEFINE-HANDLE-TABLE)."
  `(loop for ,variable across ,table
         when ,variable
           do (progn ,@body)))
