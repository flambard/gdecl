;;;; The package GODOT-DSL: DEFINE-CLASS, a small DSL that defines a class in one
;;;; form, like a GDScript script, with a struct for its instances. It uses
;;;; gd-extension/ and godot/ only, with a few internals of GD-EXTENSION, listed
;;;; in its :IMPORT-FROM clause.
;;;; See Layers in CLAUDE.md.

(defpackage #:godot-dsl
  (:documentation "DEFINE-CLASS, a small DSL that defines a Godot extension
class in one form, like a GDScript script: the struct of its instances' Lisp
objects, which includes the struct of the engine class it extends (see
GD-EXTENSION:DEFINE-ENGINE-CLASS), and its properties, :ONREADY slots,
signals, methods and virtual methods, given as functions called with the
instance.")
  (:use #:cl)
  (:import-from #:gd-extension
                #:invoker-form
                #:register-class
                #:register-singleton
                #:bind-method
                #:bind-property
                #:bind-signal
                #:bind-virtual
                #:setf-reference
                #:release-reference
                #:add-class-definition
                #:inherits-class-p
                #:engine-object-type
                #:godot-property-name)
  (:import-from #:godot
                #:node-get-node)
  (:export #:define-class))
