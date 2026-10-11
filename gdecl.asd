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
                 (:file "gd-extension" :depends-on ("gd-extension-ffi"))))
