;;; gdecl's layers, from the bottom up, one module per directory of lisp/, each
;;; with its packages in its package.lisp. A module's :DEPENDS-ON lists the
;;; layers it uses; see Layers in CLAUDE.md.

(defsystem "gdecl"
    :description "Framework for programming Godot with Common Lisp (ECL)"
    :author "Markus Flambard"
    :license "MIT"
    :version "0.1.0"
    :homepage "https://github.com/flambard/gdecl"
    :source-control (:git "https://github.com/flambard/gdecl.git")
    :pathname "lisp/"
    :components (;; extension_api.json, read when the code is compiled
                 (:module "extension-api"
                  :components ((:file "package")
                               (:file "json" :depends-on ("package"))
                               (:file "extension-api" :depends-on ("package" "json"))))
                 ;; The GDExtension C interface
                 (:module "ffi"
                  :depends-on ("extension-api")
                  :components ((:file "package")
                               (:file "gd-extension-ffi" :depends-on ("package"))))
                 ;; Godot's builtin types in plain Lisp, and converting values
                 ;; between Godot and Lisp
                 (:module "types"
                  :depends-on ("ffi")
                  :components ((:file "package")
                               (:file "builtin-types" :depends-on ("package"))
                               (:file "gd-extension-types" :depends-on ("package" "builtin-types"))
                               (:file "strings" :depends-on ("gd-extension-types"))
                               (:file "autorelease-pool" :depends-on ("gd-extension-types"))))
                 ;; What Godot calls into
                 (:module "callback"
                  :depends-on ("ffi" "types")
                  :components ((:file "package")
                               (:file "gd-extension-callback" :depends-on ("package"))
                               (:file "handle-tables" :depends-on ("gd-extension-callback"))
                               (:file "initialize" :depends-on ("gd-extension-callback"))
                               (:file "instance-bindings" :depends-on ("initialize" "handle-tables"))
                               (:file "extension-classes" :depends-on ("instance-bindings"))
                               (:file "bound-methods" :depends-on ("extension-classes"))
                               (:file "callables" :depends-on ("bound-methods"))))
                 ;; The public, Lisp-style layer, and the code generators of
                 ;; Godot's API
                 (:module "gd-extension"
                  :depends-on ("extension-api" "ffi" "types" "callback")
                  :components ((:file "package")
                               (:file "api-types" :depends-on ("package"))
                               (:file "gd-extension" :depends-on ("package" "api-types"))
                               (:file "engine-methods" :depends-on ("gd-extension"))
                               (:file "engine-objects" :depends-on ("gd-extension"))
                               (:file "engine-api" :depends-on ("engine-methods" "engine-objects"))
                               (:file "containers" :depends-on ("gd-extension" "engine-api"))
                               (:file "references" :depends-on ("engine-methods"))
                               (:file "signals" :depends-on ("engine-methods"))
                               (:file "registration" :depends-on ("gd-extension" "engine-methods"
                                                                  "engine-objects"))
                               (:file "objects" :depends-on ("registration" "references"
                                                             "engine-objects"))
                               ;; The order of the framework's startup and
                               ;; shutdown steps
                               (:file "lifecycle" :depends-on ("registration" "gd-extension"))))
                 ;; Godot's API, generated from extension_api.json
                 (:module "godot"
                  :depends-on ("types" "gd-extension")
                  :components ((:file "package")
                               (:file "godot-engine-classes" :depends-on ("package"))
                               (:file "godot-utility" :depends-on ("package"))))
                 ;; DEFINE-CLASS, a small DSL that defines a class in one form
                 (:module "dsl"
                  :depends-on ("callback" "gd-extension" "godot")
                  :components ((:file "package")
                               (:file "define-class" :depends-on ("package"))))
                 ;; A prototype of the high-level layer: classes as CLOS classes
                 (:module "clos"
                  :depends-on ("types" "callback" "gd-extension" "godot")
                  :components ((:file "package")
                               (:file "godot-class" :depends-on ("package"))
                               (:file "godot-functions" :depends-on ("godot-class"))
                               (:file "godot-registration" :depends-on ("godot-functions"))))))
