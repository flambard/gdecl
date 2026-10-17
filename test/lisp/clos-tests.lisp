(in-package #:gdecl-test)

;;; The tests of the classes defined with GODOT-CLOS (clos-classes.lisp) from
;;; Lisp. run_tests.gd tests them from Godot.

(defun new-clos-node (class-name &rest initargs)
  "A new node of the GODOT-CLASS CLASS-NAME, made with MAKE-INSTANCE and
INITARGS, with the child its :onready slot needs, added to *ROOT*."
  (let ((node (apply #'make-instance class-name initargs))
        (child (class-db-instantiate "Node")))
    (node-set-name child "Child")
    (node-add-child node child)
    (node-add-child *root* node)
    node))

(deftest clos-make-instance
  (let ((node (new-clos-node 'clos-node :count 3)))
    (check (typep node 'clos-node))
    (check (typep node 'node-2d))
    (check (gdext:godot-object-p node))
    (check (= 3 (clos-node-count node)))
    (check (= 3 (object-get node "count")))
    ;; The same Lisp object for the Godot object
    (check (eq node (gdext:lisp-object (gdext:object-pointer node))))
    (check (string= "ClosNode" (object-get-class node)))
    ;; Engine methods take the instance as it is
    (node-2d-set-position node (vector2 3.0 4.0))
    (check (equalp (vector2 3.0 4.0) (node-2d-get-position node)))
    ;; Ready when it was added to *ROOT*
    (check (= 1 (clos-node-ready-calls node)))
    (check (same-object-p (node-get-node node "Child") (clos-node-child node)))))

(deftest clos-generic-functions
  (let ((node (new-clos-node 'clos-node))
        (sub (new-clos-node 'clos-sub-node)))
    (check (= 5 (clos-add node 2 3)))
    (check (= 50 (clos-add sub 2 3)))
    (check (= 50 (object-call sub "add" 2 3)))
    (check (string= "hello" (greet sub)))
    (check (not (object-has-method node "greet")))))

(deftest clos-redefinition
  (let ((node (new-clos-node 'clos-redefined-node)))
    (setf (clos-redefined-a node) 5)
    ;; A new exported slot, in the instance and in Godot
    (eval '(defclass clos-redefined-node (node)
            ((a :initform 1 :export :int :accessor clos-redefined-a)
             (b :initform 2 :export :int :accessor clos-redefined-b))
            (:metaclass godot-class)))
    (check (= 5 (clos-redefined-a node)))
    (check (= 2 (clos-redefined-b node)))
    (check (= 2 (object-get node "b")))
    (object-set node "b" 7)
    (check (= 7 (clos-redefined-b node)))
    ;; A method added to a GODOT-METHOD is registered with Godot
    (check (not (object-has-method node "late_value")))
    (eval '(defmethod late-value ((node clos-redefined-node))
            (* 10 (clos-redefined-b node))))
    (check (object-has-method node "late_value"))
    (check (= 70 (object-call node "late_value")))))

(deftest clos-notifications
  (let ((node (new-clos-node 'clos-node))
        (sub (new-clos-node 'clos-sub-node)))
    ;; Parented when added to *ROOT*, once, also for SUB, whose method is
    ;; inherited from another Lisp class
    (check (equal '(:parented) (clos-node-notifications node)))
    (check (equal '(:parented :before-parented) (clos-node-notifications sub)))
    ;; A method of a mixin
    (node-remove-child *root* sub)
    (check (string= "goodbye" (clos-greeting sub)))
    (node-add-child *root* sub)
    ;; Before Godot frees it
    (let ((predeletes *clos-node-predeletes*))
      (node-remove-child *root* node)
      (gdext-ffi:object-destroy (gdext:object-pointer node))
      (check (= (1+ predeletes) *clos-node-predeletes*)))))

(defvar *clos-redefined-notifications* '()
  "The notifications the method added by CLOS-NOTIFICATIONS-AT-RUNTIME got.")

(deftest clos-notifications-at-runtime
  (let ((node (new-clos-node 'clos-redefined-node)))
    ;; A method for all notifications, added as at a REPL
    (eval '(defmethod notification ((node clos-redefined-node) what)
            (push what *clos-redefined-notifications*)))
    (node-remove-child *root* node)
    (check (member +node-notification-exit-tree+ *clos-redefined-notifications*))
    (check (member +node-notification-unparented+ *clos-redefined-notifications*))
    ;; And removed again
    (remove-method #'notification
                   (find-method #'notification '()
                                (list (find-class 'clos-redefined-node) (find-class t))))
    (setf *clos-redefined-notifications* '())
    (node-add-child *root* node)
    (check (null *clos-redefined-notifications*))))

(defclass clos-misplaced-mixin ()
  ((misplaced :initform 1))
  (:documentation "A mixin that CLOS-MIXIN-ORDER puts after an engine class."))

(deftest clos-mixin-order
  ;; A mixin after the engine class in the superclasses would move the Godot
  ;; object pointer from where the structs' accessors read it, so the class is
  ;; rejected when it's defined, before it's registered with Godot. (Mixins
  ;; first, as in CLOS-SUB-NODE, is the right order.)
  (check (eq :rejected
             (handler-case (eval '(defclass clos-misordered-node (node clos-misplaced-mixin) ()
                                   (:metaclass godot-class)))
               (error () :rejected))))
  (check (not (class-db-class-exists "ClosMisorderedNode"))))
