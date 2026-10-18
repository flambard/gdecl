;;;; The packages GODOT and GODOT-UTILITY: Godot's API, generated from
;;;; extension_api.json by GODOT-GENERATORS (engine-api.lisp), with a few
;;;; internals of GD-EXTENSION, listed in its :IMPORT-FROM clause.
;;;; See Layers in CLAUDE.md.

(defpackage #:godot-generators
  (:documentation "The code generators of Godot's API, DEFINE-ENGINE-CLASS,
DEFINE-GLOBAL-ENUMS and DEFINE-UTILITY-FUNCTIONS, which define functions and
constants in GODOT and GODOT-UTILITY from extension_api.json. GODOT exports
DEFINE-ENGINE-CLASS, for the classes applications use.")
  (:use #:cl #:extension-api-json)
  (:import-from #:gd-extension
                #:variant-type
                #:unsupported-api-type
                #:lisp-style-class-name
                #:lisp-style-method-name
                #:engine-method-defun
                #:engine-function-defun
                #:engine-method-variant-type
                #:engine-method-arguments
                #:documented-argument-names
                #:look-up-utility-function
                #:engine-object-type
                #:register-engine-object-type
                #:*engine-object-types*)
  (:export #:define-engine-class
           #:define-global-enums
           #:define-utility-functions))

(defpackage #:godot
  (:documentation "Godot's API in Lisp: the builtin types, such as Vector2 and
Basis (from GD-EXTENSION-BUILTINS), and functions that call the methods of
engine classes, named <class>-<method>, e.g. NODE-GET-NODE. DEFINE-ENGINE-CLASS
defines the functions and exports them from here, both for the classes gdecl
defines (godot-engine-classes.lisp) and those applications define. And
AFTER-SIGNAL, for what GDScript does with await (signals.lisp).")
  (:nicknames #:gd)
  (:use #:cl #:gd-extension-builtins)
  (:import-from #:godot-generators
                #:define-engine-class)
  (:export #:define-engine-class
           #:after-signal)
  ;; Everything GD-EXTENSION-BUILTINS exports, computed when this is read
  #.`(:export ,@(let ((names '()))
                  (do-external-symbols (symbol '#:gd-extension-builtins names)
                    (push (symbol-name symbol) names)))))

(defpackage #:godot-utility
  (:documentation "Godot's utility functions in Lisp: the global functions of
GDScript in @GlobalScope, e.g. RANDF-RANGE and PUSH-ERROR, defined with
GODOT-GENERATORS:DEFINE-UTILITY-FUNCTIONS. Those named like Common Lisp's are left
out; print is GODOT-PRINT.")
  (:nicknames #:gd-util)
  (:use #:cl))
