(in-package #:gdecl-test)

;;; The classes the tests use. The tests in run_tests.gd use them from Godot,
;;; and LispTests runs the tests written in Lisp (lisp-tests.lisp).

;;;
;;; TestResource: a RefCounted extension class, with a destructor
;;;

(defvar *resources-destroyed* 0
  "The number of TestResources Godot has freed.")

(gdext:define-class test-resource ("TestResource" "Resource")
  ((value 0 :export :int))
  (:destructor test-resource-destroyed))

(defun test-resource-destroyed (resource)
  (declare (ignore resource))
  (incf *resources-destroyed*))

;;;
;;; TestNode: properties, methods, signals, :onready slots and virtual methods
;;;

(gdext:define-class test-node ("TestNode" "Node2D")
  ((count 0 :export :int)
   (speed 1.5d0 :export :float)
   (title "" :export :string)
   ;; A RefCounted class, so the slot keeps a reference
   (resource nil :export :object :class "TestResource")
   ;; A Node class
   (target nil :export :object :class "Node2D")
   (child nil :onready "Child")
   (parent-class nil :onready test-node-parent-class-name)
   (child-seen-in-ready nil)
   (process-calls 0)
   ;; The arguments of the last pinged signal heard with LISTEN, and the object
   ;; that emitted it
   heard
   emitter)
  (:signal "pinged" ("number" :int) ("text" :string) ("vector" :vector2) ("object" :object)
           ("flag" :bool))
  (:method "add" test-node-add :arguments (("a" :int) ("b" :int)) :return-type :int)
  (:method "scale_vector" test-node-scale-vector
           :arguments (("vector" :vector2) ("factor" :float)) :return-type :vector2)
  (:method "scale_vector3" test-node-scale-vector3
           :arguments (("vector" :vector3) ("factor" :float)) :return-type :vector3)
  (:method "looking_at" test-node-looking-at
           :arguments (("target" :vector3)) :return-type :basis)
  (:method "basis_column" test-node-basis-column
           :arguments (("basis" :basis) ("index" :int)) :return-type :vector3)
  (:method "echo" test-node-echo :arguments (("text" :string)) :return-type :string)
  (:method "is_null" test-node-is-null :arguments (("object" :object)) :return-type :bool)
  (:method "get_self" identity :return-type :object)
  (:method "get_child_slot" test-node-child :return-type :object)
  (:method "get_parent_class" test-node-parent-class :return-type :string)
  (:method "saw_child_in_ready" test-node-child-seen-in-ready :return-type :bool)
  (:method "get_process_calls" test-node-process-calls :return-type :int)
  (:method "emit_pinged" test-node-emit-pinged)
  (:method "listen" test-node-listen :arguments (("emitter" :object)))
  (:method "heard_pinged" test-node-heard-pinged-p :return-type :bool)
  (:method "fail" test-node-fail :return-type :int)
  (:virtual "_ready" test-node-ready)
  (:virtual "_process" test-node-process))

(defun test-node-parent-class-name (node)
  (object-get-class (node-get-parent node)))

(defun test-node-add (node a b)
  (declare (ignore node))
  (+ a b))

(defun test-node-scale-vector (node vector factor)
  (declare (ignore node))
  (vector2* vector factor))

(defun test-node-scale-vector3 (node vector factor)
  (declare (ignore node))
  (vector3* vector factor))

(defun test-node-looking-at (node target)
  (declare (ignore node))
  (basis-looking-at target))

(defun test-node-basis-column (node basis index)
  (declare (ignore node))
  (ecase index
    (0 (basis-x basis))
    (1 (basis-y basis))
    (2 (basis-z basis))))

(defun test-node-echo (node text)
  (declare (ignore node))
  text)

(defun test-node-is-null (node object)
  (declare (ignore node))
  (null object))

(defun test-node-emit-pinged (node)
  (object-emit-signal node "pinged" 42 "text" (vector2 1.0 2.0) node t))

(defun test-node-listen (node emitter)
  "Connect the pinged signal of EMITTER to a Lisp function, which keeps the
arguments and returns how many there were."
  (setf (test-node-emitter node) emitter)
  (gdext:connect-signal emitter "pinged"
                        (lambda (&rest arguments)
                          (setf (test-node-heard node) arguments)
                          (length arguments))
                        :target node))

(defun test-node-heard-pinged-p (node)
  "True if the arguments heard are those TEST-NODE-EMIT-PINGED emits."
  (equalp (test-node-heard node)
          (list 42 "text" (vector2 1.0 2.0) (test-node-emitter node) t)))

(defun test-node-fail (node)
  (declare (ignore node))
  (error "An error in a bound method, expected by the tests"))

(defun test-node-ready (node)
  (setf (test-node-child-seen-in-ready node) (and (test-node-child node) t)))

(defun test-node-process (node delta)
  (declare (ignore delta))
  (incf (test-node-process-calls node)))

;;;
;;; TestBareNode: :onready slots without a _ready of its own
;;;

(gdext:define-class test-bare-node ("TestBareNode" "Node")
  ((child nil :onready "Child"))
  (:method "get_child_slot" test-bare-node-child :return-type :object))

;;;
;;; TestFailingNode: its Lisp object can't be made, as a slot's initform
;;; signals an error
;;;

(gdext:define-class test-failing-node ("TestFailingNode" "Node")
  ((broken (error "A constructor error, expected by the tests"))))

;;;
;;; TestSingleton: an engine singleton, which GDScript uses by name like Input
;;;

(gdext:define-class test-singleton ("TestSingleton" "Object")
  ((count 0))
  (:singleton t)
  (:method "next" test-singleton-next :return-type :int))

(defun test-singleton-next (singleton)
  "Count the calls, and return the count."
  (incf (test-singleton-count singleton)))

;;;
;;; LispTests: runs the tests written in Lisp
;;;

(defvar *root* nil
  "The node the Lisp tests add their nodes to, freed by run_tests.gd afterwards.")

(defvar *kept-resource* nil
  "A RefCounted object kept with SETF-REFERENCE by keep_resource.")

(gdext:define-class lisp-tests ("LispTests" "Node")
  ()
  (:method "run" lisp-tests-run :arguments (("root" :object)) :return-type :int)
  (:method "resources_destroyed" (lambda (tests)
                                   (declare (ignore tests))
                                   *resources-destroyed*)
           :return-type :int)
  (:method "keep_resource" (lambda (tests resource)
                             (declare (ignore tests))
                             (gdext:setf-reference *kept-resource* resource))
           :arguments (("resource" :object)))
  (:method "new_resource_id" lisp-tests-new-resource-id :return-type :int)
  (:method "keep_new_resource" lisp-tests-keep-new-resource :return-type :int)
  (:method "new_resource" lisp-tests-new-resource :return-type :object))

(defun lisp-tests-new-resource-id (tests)
  "The instance ID of a new TestResource, which is in the autorelease pool, so
it's freed when this method returns."
  (declare (ignore tests))
  (object-get-instance-id (class-db-instantiate "TestResource")))

(defun lisp-tests-keep-new-resource (tests)
  "Keep a new TestResource in *KEPT-RESOURCE*, and return its instance ID."
  (declare (ignore tests))
  (gdext:setf-reference *kept-resource* (class-db-instantiate "TestResource"))
  (object-get-instance-id *kept-resource*))

(defun lisp-tests-new-resource (tests)
  "A new TestResource, which is in the autorelease pool when it's returned."
  (declare (ignore tests))
  (class-db-instantiate "TestResource"))

(defun lisp-tests-run (tests root)
  "Run the Lisp tests with ROOT as *ROOT*, print the failures, and return how
many there were."
  (declare (ignore tests))
  (multiple-value-bind (count failures) (let ((*root* root)) (run-tests))
    (dolist (failure failures)
      (printerr "[test] FAIL: " failure))
    (godot-print (format nil "[test] Lisp: ~d tests, ~d failures" count (length failures)))
    (length failures)))
