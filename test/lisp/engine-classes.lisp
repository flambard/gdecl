(in-package #:gdecl-test)

;;; The engine classes the tests use, besides those in GODOT

;; A singleton class, with Variant results
(gdext:define-engine-class "ClassDB")

;; Rect2 arguments and results (region_rect)
(gdext:define-engine-class "Sprite2D")

;; A static method whose Variant argument comes before a String
(gdext:define-engine-method json-stringify ("JSON" "stringify"))
