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

;; Builtin results stored into a struct the caller gives: a Vector2, a Rect2,
;; which has nested structs, and a Vector3 from a method with an argument
(gdext:define-engine-method get-position-into ("Node2D" "get_position") :into t)
(gdext:define-engine-method get-region-rect-into ("Sprite2D" "get_region_rect") :into t)
(gdext:define-engine-method to-global-into ("Node3D" "to_global") :into t)

;; A signal emitter of a simple type, called in one piece of C code
(gdext:define-signal-emitter emit-pinged-number "pinged" ((number :int)))

;; A static method whose Variant argument comes before a String
(gdext:define-engine-method json-stringify ("JSON" "stringify"))

;; A Callable result (get_spawn_function)
(gdext:define-engine-class "MultiplayerSpawner")

;; Threads of Godot's own, which call Lisp Callables
(gdext:define-engine-class "Thread")
(gdext:define-engine-class "WorkerThreadPool")
