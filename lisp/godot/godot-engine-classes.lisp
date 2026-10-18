;;;; Functions in the package GODOT for the methods of the engine classes that
;;;; most applications use, named <class>-<method>, e.g. NODE-GET-NODE and
;;;; CANVAS-ITEM-HIDE. An application defines functions for other classes with
;;;; DEFINE-ENGINE-CLASS (engine-api.lisp), which also puts them in GODOT.

(in-package :godot)

(godot-generators:define-global-enums)

(define-engine-class "Object")
(define-engine-class "RefCounted")
(define-engine-class "Resource")
(define-engine-class "Node")
(define-engine-class "CanvasItem")
(define-engine-class "Node2D")
(define-engine-class "Node3D")
(define-engine-class "SceneTree")
(define-engine-class "Input")
(define-engine-class "Timer")
(define-engine-class "PackedScene")
