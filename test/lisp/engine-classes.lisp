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

;; Vararg methods with extra arguments of known types: simple types, called in
;; one piece of C code, and a String, which isn't
(gdext:define-engine-method emit-typed ("Object" "emit_signal")
  :extra-arguments ((number :int) (vector :vector2) (object :object) (flag :bool)))
(gdext:define-engine-method emit-text ("Object" "emit_signal")
  :extra-arguments ((text :string)))
(gdext:define-engine-method emit-int ("Object" "emit_signal")
  :extra-arguments ((value :int)))

;; A static method whose Variant argument comes before a String
(gdext:define-engine-method json-stringify ("JSON" "stringify"))

;; A Callable result (get_spawn_function)
(gdext:define-engine-class "MultiplayerSpawner")

;; Threads of Godot's own, which call Lisp Callables
(gdext:define-engine-class "Thread")
(gdext:define-engine-class "WorkerThreadPool")
