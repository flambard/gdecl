(defsystem "gdecl-test"
    :description "The tests of gdecl that run in Godot"
    :author "Markus Flambard"
    :license "MIT"
    :depends-on ("gdecl")
    :components ((:file "packages")
                 (:file "framework" :depends-on ("packages"))
                 (:file "engine-classes" :depends-on ("packages"))
                 (:file "classes" :depends-on ("packages" "framework" "engine-classes"))
                 (:file "lisp-tests" :depends-on ("packages" "framework" "engine-classes" "classes"))))
