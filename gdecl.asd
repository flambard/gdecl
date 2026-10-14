(defsystem "gdecl"
    :description "Framework for programming Godot with Common Lisp (ECL)"
    :author "Markus Flambard"
    :license "MIT"
    :version "0.1.0"
    :homepage "https://github.com/flambard/gdecl"
    :source-control (:git "https://github.com/flambard/gdecl.git")
    :pathname "lisp/"
    :components ((:file "packages")
                 (:file "gd-extension-ffi" :depends-on ("packages"))
                 (:file "builtin-types" :depends-on ("packages"))
                 (:file "gd-extension-types" :depends-on ("gd-extension-ffi" "builtin-types"))
                 (:file "gd-extension-callback" :depends-on ("gd-extension-ffi" "gd-extension-types"))
                 (:file "json" :depends-on ("packages"))
                 (:file "extension-api" :depends-on ("gd-extension-ffi" "json"))
                 ;; The package GD-EXTENSION. The order matters: each file adds
                 ;; its deinitialize hooks after those of the files before it,
                 ;; so they run before them.
                 (:file "gd-extension" :depends-on ("gd-extension-ffi" "gd-extension-types"
                                                    "gd-extension-callback" "extension-api"))
                 (:file "engine-methods" :depends-on ("gd-extension"))
                 (:file "engine-objects" :depends-on ("gd-extension"))
                 (:file "engine-api" :depends-on ("engine-methods" "engine-objects"))
                 (:file "references" :depends-on ("engine-methods"))
                 (:file "signals" :depends-on ("engine-methods"))
                 (:file "binding" :depends-on ("gd-extension" "engine-methods"))
                 (:file "define-class" :depends-on ("binding" "references" "engine-objects"))
                 (:file "godot-engine-classes" :depends-on ("engine-api"))
                 (:file "godot-utility" :depends-on ("engine-api"))))
