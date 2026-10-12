;;;; Functions in the package GODOT for the methods of the engine classes that
;;;; most applications use, named <class>-<method>, e.g. NODE-GET-NODE and
;;;; CANVAS-ITEM-HIDE. An application defines functions for other classes with
;;;; GD-EXTENSION:DEFINE-ENGINE-CLASS, which also puts them in GODOT.

(in-package :godot)

(gdext:define-global-enums)

(gdext:define-engine-class "Object")
(gdext:define-engine-class "RefCounted")
(gdext:define-engine-class "Resource")
(gdext:define-engine-class "Node")
(gdext:define-engine-class "CanvasItem")
(gdext:define-engine-class "Node2D")
(gdext:define-engine-class "Node3D")
(gdext:define-engine-class "SceneTree")
(gdext:define-engine-class "Input")
(gdext:define-engine-class "Timer")
(gdext:define-engine-class "PackedScene")
