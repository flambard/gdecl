(defsystem "gdecl"
    :description "Framework for programming Godot with Common Lisp (ECL)"
    :pathname "lisp/"
    :components ((:file "packages")
                 (:file "gd-extension-ffi" :depends-on ("packages"))
                 (:file "gd-extension" :depends-on ("gd-extension-ffi"))))
