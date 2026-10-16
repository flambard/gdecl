(in-package #:gdecl-test)

;;; The classes defined with GODOT-CLOS that the tests use: run_tests.gd uses
;;; them from Godot, and clos-tests.lisp from Lisp.

;;;
;;; ClosNode: properties, :onready slots, signals, methods and virtual methods
;;;

(defclass clos-node (node-2d)
  ((count :initform 0 :initarg :count :export :int :accessor clos-node-count)
   (speed :initform 1.5d0 :export :float)
   ;; A RefCounted class, so the slot keeps a reference
   (resource :initform nil :export :object :class "TestResource")
   (child :onready "Child" :reader clos-node-child)
   (parent-class :onready clos-node-parent-class-name :reader clos-node-parent-class)
   (ready-calls :initform 0 :accessor clos-node-ready-calls)
   (process-calls :initform 0 :accessor clos-node-process-calls))
  (:metaclass godot-class)
  (:signals (pinged (number :int))))

(defun clos-node-parent-class-name (node)
  (object-get-class (node-get-parent node)))

(defmethod ready ((node clos-node))
  (incf (clos-node-ready-calls node)))

(defmethod process ((node clos-node) delta)
  (declare (ignore delta))
  (incf (clos-node-process-calls node)))

(define-godot-generic clos-add (self (a :int) (b :int))
  (:godot-name "add")
  (:return-type :int))

(defmethod clos-add ((node clos-node) a b)
  (+ a b))

(define-godot-generic scale-vector (self (vector :vector2) (factor :float))
  (:return-type :vector2))

(defmethod scale-vector ((node clos-node) vector factor)
  (vector2* vector factor))

(define-godot-generic get-ready-calls (self)
  (:return-type :int))

(defmethod get-ready-calls ((node clos-node))
  (clos-node-ready-calls node))

(define-godot-generic get-process-calls (self)
  (:return-type :int))

(defmethod get-process-calls ((node clos-node))
  (clos-node-process-calls node))

(define-godot-generic get-child-slot (self)
  (:return-type :object))

(defmethod get-child-slot ((node clos-node))
  (clos-node-child node))

(define-godot-generic get-parent-class (self)
  (:return-type :string))

(defmethod get-parent-class ((node clos-node))
  (clos-node-parent-class node))

(define-godot-generic emit-pinged (self))

(defmethod emit-pinged ((node clos-node))
  (object-emit-signal node "pinged" 5))

;;;
;;; ClosSubNode: a Lisp class that extends a Lisp class, with a mixin
;;;

(defclass clos-greeter ()
  ((greeting :initform "hello" :accessor clos-greeting))
  (:documentation "A mixin, a standard class."))

(define-godot-generic greet (self)
  (:return-type :string))

;; A method of the mixin, so classes with the mixin get greet in Godot
(defmethod greet ((greeter clos-greeter))
  (clos-greeting greeter))

(defclass clos-sub-node (clos-greeter clos-node)
  ((label :initform "sub" :export :string))
  (:metaclass godot-class))

;; Specializes the inherited add, and calls the parent's
(defmethod clos-add ((node clos-sub-node) a b)
  (* 10 (call-next-method)))

;; Method combination on a virtual method that the parent implements
(defmethod process :before ((node clos-sub-node) delta)
  (declare (ignore delta))
  (incf (clos-node-process-calls node) 100))

;;;
;;; ClosRedefinedNode: redefined by a test at runtime, which also adds a method
;;; to LATE-VALUE then
;;;

(defclass clos-redefined-node (node)
  ((a :initform 1 :export :int :accessor clos-redefined-a))
  (:metaclass godot-class))

(define-godot-generic late-value (self)
  (:return-type :int))
