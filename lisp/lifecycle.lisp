(in-package :gd-extension)

;;;
;;; The framework's startup and shutdown, in one place
;;;
;;; GD-EXTENSION-CALLBACK:INITIALIZE runs *FRAMEWORK-INITIALIZE* after the
;;; initialize cells are filled in and before the application's initialize
;;; hooks, and DEINITIALIZE runs *FRAMEWORK-DEINITIALIZE* after the
;;; application's deinitialize hooks, while Godot can still be called. Each
;;; step runs even if one before it fails. The order of the steps matters, and
;;; a wrong one shows up only as leaks reported by Godot, or a crash, at exit.
;;;

(setf *framework-initialize*
      '(;; Before the application's hooks, which make instances of the classes
        register-defined-classes)       ; define-class.lisp

      *framework-deinitialize*
      '(;; While their classes are still registered, as freeing an instance
        ;; calls into its class
        unregister-singletons           ; registration.lisp
        ;; Subclasses first, and while the class names, StringNames that
        ;; DESTROY-PERMANENT-VALUES destroys, are still there
        unregister-classes              ; registration.lisp
        ;; The StringNames and NodePaths of SNAME and NPATH, and the class
        ;; names; nothing may use them afterwards
        destroy-permanent-values        ; gd-extension.lisp
        ;; Last: the bindings of the objects that still exist, such as engine
        ;; singletons, so Godot doesn't call FREE-BINDING once Lisp is shut
        ;; down
        free-bindings))                 ; instance-bindings.lisp
