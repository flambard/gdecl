(defsystem "gdecl"
    :description "Framework for programming Godot with Common Lisp (ECL)"
    :pathname "lisp/"
    :components ((:file "packages")
                 (:file "gdextension-ffi" :depends-on ("packages"))
                 (:file "godot" :depends-on ("gdextension-ffi"))))
