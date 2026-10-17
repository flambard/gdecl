;;;; The package GD-EXTENSION-BUILTINS: Godot's builtin types in plain Lisp. It
;;;; depends on nothing else in gdecl.
;;;; See Layers in CLAUDE.md.

(defpackage #:gd-extension-builtins
  (:documentation "Lisp versions of Godot's builtin types, such as Vector2 and
Basis, with their functions. Everything exported from here is for applications:
GD-EXTENSION and GODOT re-export all of it, so a symbol is added here only.")
  (:nicknames #:gdext-builtins)
  (:use #:cl)
  (:export #:vector2
           #:vector2-p
           #:vector2-x
           #:vector2-y
           #:vector2+
           #:vector2*
           #:vector2-length
           #:vector2-normalized
           #:vector2-rotated
           #:vector2-clamp
           #:rect2
           #:rect2-p
           #:rect2-position
           #:rect2-size
           #:vector3
           #:vector3-p
           #:vector3-x
           #:vector3-y
           #:vector3-z
           #:vector3+
           #:vector3-
           #:vector3*
           #:vector3-length
           #:vector3-normalized
           #:vector3-dot
           #:vector3-cross
           #:vector3-rotated
           #:vector3-is-zero-approx
           #:basis
           #:basis-p
           #:basis-x
           #:basis-y
           #:basis-z
           #:basis-looking-at
           #:color
           #:color-p
           #:color-r
           #:color-g
           #:color-b
           #:color-a
           #:vector2i
           #:vector2i-p
           #:vector2i-x
           #:vector2i-y
           #:vector3i
           #:vector3i-p
           #:vector3i-x
           #:vector3i-y
           #:vector3i-z
           #:vector4
           #:vector4-p
           #:vector4-x
           #:vector4-y
           #:vector4-z
           #:vector4-w
           #:vector4i
           #:vector4i-p
           #:vector4i-x
           #:vector4i-y
           #:vector4i-z
           #:vector4i-w
           #:rect2i
           #:rect2i-p
           #:rect2i-position
           #:rect2i-size
           #:plane
           #:plane-p
           #:plane-normal
           #:plane-d
           #:quaternion
           #:quaternion-p
           #:quaternion-x
           #:quaternion-y
           #:quaternion-z
           #:quaternion-w
           #:aabb
           #:aabb-p
           #:aabb-position
           #:aabb-size
           #:transform2d
           #:transform2d-p
           #:transform2d-x
           #:transform2d-y
           #:transform2d-origin
           #:transform3d
           #:transform3d-p
           #:transform3d-basis
           #:transform3d-origin
           #:projection
           #:projection-p
           #:projection-x
           #:projection-y
           #:projection-z
           #:projection-w
           #:rid
           #:rid-p
           #:rid-id))
