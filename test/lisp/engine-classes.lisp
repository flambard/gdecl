(in-package #:gdecl-test)

;;; The engine classes the tests use, besides those in GODOT

;; A singleton class, with Variant results
(gdext:define-engine-class "ClassDB")

;; Rect2 arguments and results (region_rect)
(gdext:define-engine-class "Sprite2D")

;; PackedVector2Array arguments and results (points)
(gdext:define-engine-class "Line2D")

;; A singleton with a Dictionary result (get_version_info)
(gdext:define-engine-class "Engine")

;; A static method whose Variant argument comes before a String
(gdext:define-engine-method json-stringify ("JSON" "stringify"))

;; Threads of Godot's own, which call Lisp Callables
(gdext:define-engine-class "Thread")
(gdext:define-engine-class "WorkerThreadPool")
