;;;; The packages GODOT and GODOT-UTILITY: Godot's API, generated from
;;;; extension_api.json by GD-EXTENSION (gd-extension/).
;;;; See Layers in CLAUDE.md.

(defpackage #:godot
  (:documentation "Godot's API in Lisp: the builtin types, such as Vector2 and
Basis (from GD-EXTENSION-BUILTINS), and functions that call the methods of
engine classes, named <class>-<method>, e.g. NODE-GET-NODE. GD-EXTENSION:
DEFINE-ENGINE-CLASS defines the functions and exports them from here, both for the
classes gdecl defines (godot-engine-classes.lisp) and those applications define.")
  (:nicknames #:gd)
  (:use #:cl #:gd-extension-builtins)
  ;; Everything GD-EXTENSION-BUILTINS exports, computed when this is read
  #.`(:export ,@(let ((names '()))
                  (do-external-symbols (symbol '#:gd-extension-builtins names)
                    (push (symbol-name symbol) names)))))

(defpackage #:godot-utility
  (:documentation "Godot's utility functions in Lisp: the global functions of
GDScript in @GlobalScope, e.g. RANDF-RANGE and PUSH-ERROR, defined with
GD-EXTENSION:DEFINE-UTILITY-FUNCTIONS. Those named like Common Lisp's are left
out; print is GODOT-PRINT.")
  (:nicknames #:gd-util)
  (:use #:cl))
