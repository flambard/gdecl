(defsystem "gdecl"
    :description "Framework for programming Godot with Common Lisp (ECL)"
    :author "Markus Flambard"
    :license "MIT"
    :version "0.1.0"
    :homepage "https://github.com/flambard/gdecl"
    :source-control (:git "https://github.com/flambard/gdecl.git")
    :pathname "lisp/"
    :components ((:file "packages")
                 (:file "gd-extension-ffi" :depends-on ("packages" "json"))
                 (:file "builtin-types" :depends-on ("packages"))
                 (:file "gd-extension-types" :depends-on ("gd-extension-ffi" "builtin-types"))
                 (:file "strings" :depends-on ("gd-extension-types"))
                 (:file "autorelease-pool" :depends-on ("gd-extension-types"))
                 ;; The package GD-EXTENSION-CALLBACK
                 (:file "gd-extension-callback" :depends-on ("gd-extension-ffi" "strings" "autorelease-pool"))
                 (:file "handle-tables" :depends-on ("gd-extension-callback"))
                 (:file "initialize" :depends-on ("gd-extension-callback"))
                 (:file "instance-bindings" :depends-on ("initialize" "handle-tables"))
                 (:file "extension-classes" :depends-on ("instance-bindings"))
                 (:file "bound-methods" :depends-on ("extension-classes"))
                 (:file "callables" :depends-on ("bound-methods"))
                 (:file "json" :depends-on ("packages"))
                 (:file "extension-api" :depends-on ("gd-extension-ffi" "json"))
                 ;; The package GD-EXTENSION
                 (:file "gd-extension" :depends-on ("gd-extension-ffi" "gd-extension-types"
                                                    "callables" "extension-api"))
                 (:file "engine-methods" :depends-on ("gd-extension"))
                 (:file "engine-objects" :depends-on ("gd-extension"))
                 (:file "engine-api" :depends-on ("engine-methods" "engine-objects"))
                 (:file "containers" :depends-on ("gd-extension" "engine-api"))
                 (:file "references" :depends-on ("engine-methods"))
                 (:file "signals" :depends-on ("engine-methods"))
                 (:file "registration" :depends-on ("gd-extension" "engine-methods" "engine-objects"))
                 (:file "define-class" :depends-on ("registration" "references" "engine-objects"))
                 ;; The order of the framework's startup and shutdown steps
                 (:file "lifecycle" :depends-on ("define-class" "registration" "gd-extension"))
                 (:file "godot-engine-classes" :depends-on ("engine-api" "containers"))
                 (:file "godot-utility" :depends-on ("engine-api" "containers"))
                 ;; The package GODOT-CLOS, a prototype of the high-level layer
                 (:file "godot-class" :depends-on ("define-class" "godot-engine-classes"))
                 (:file "godot-functions" :depends-on ("godot-class" "registration"))
                 (:file "godot-registration" :depends-on ("godot-functions"))))
