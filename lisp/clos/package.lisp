;;;; The package GODOT-CLOS, a prototype of the high-level layer: Godot classes
;;;; as CLOS classes. It uses gd-extension/ and godot/, with a few internals of
;;;; GD-EXTENSION, listed in its :IMPORT-FROM clause, and of types/ only the
;;;; layout of GODOT-OBJECT (GD-EXTENSION-TYPES::POINTER, in godot-class.lisp).
;;;; See Layers in CLAUDE.md.

(defpackage #:godot-clos
  (:documentation "A prototype of the high-level layer (TODO P): Godot classes
as CLOS classes. The metaclass GODOT-CLASS registers a DEFCLASS with Godot,
with slots exported as properties, :ONREADY slots and signals, and generic
functions are what Godot calls: virtual methods such as _process, defined with
DEFINE-VIRTUAL-FUNCTION, methods that GDScript can call, defined with
DEFINE-GODOT-GENERIC, and NOTIFICATION. The classes inherit from the structs of engine classes
(DEFINE-ENGINE-CLASS), so their instances are GODOT-OBJECTs to the layers
below.")
  (:use #:cl)
  (:import-from #:gd-extension
                #:godot-object
                #:godot-object-pointer
                #:invoker-form
                #:report-error
                #:add-class-definition
                #:inherits-class-p
                #:virtual-signatures
                #:variant-type
                #:godot-property-name
                #:*engine-object-types*)
  (:export ;; Classes
           #:godot-class
           #:godot-name
           ;; Generic functions that Godot calls
           #:virtual-function
           #:define-virtual-function
           #:godot-method
           #:define-godot-generic
           ;; Virtual methods of engine classes
           #:ready
           #:process
           #:physics-process
           #:enter-tree
           #:exit-tree
           #:unhandled-input
           #:draw
           ;; Notifications
           #:notification))
