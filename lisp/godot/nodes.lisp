;;;; Nodes in GODOT: $, for GDScript's $Path. Built on NODE-GET-NODE, generated
;;;; for the engine class Node (godot-engine-classes.lisp).

(in-package :godot)

(defmacro $ (node path)
  "The node at PATH (a NodePath, see GD-EXTENSION:NPATH, or a literal string)
relative to NODE, like $Path in GDScript, where NODE is self: ($ main
\"UserInterface/Retry\"). A macro, so that NODE-GET-NODE's compiler macro makes
a literal path a NodePath once, when the code is compiled."
  `(node-get-node ,node ,path))
