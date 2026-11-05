;;;; Short names in GODOT (see Short names in engine-api.lisp): the error of a
;;;; call that no class's method takes, DEFINE-GODOT-PACKAGE for the packages
;;;; that use GODOT, and a check at startup that nothing else redefined one.

(in-package :godot)

(defun no-engine-method (name object)
  (error "~s has no engine method ~s that takes these arguments" object name))

(defmacro define-godot-package (name &rest options)
  "DEFPACKAGE NAME with OPTIONS, for a package that uses both GODOT and
COMMON-LISP: it gets the names that GODOT shadows for engine methods and
properties, such as POSITION, instead of Common Lisp's, which are then written
CL:POSITION."
  `(defpackage ,name
     (:shadowing-import-from #:godot ,@(mapcar #'symbol-name (package-shadowing-symbols :godot)))
     ,@options))

(defun check-short-names ()
  "Signal an error naming the short names that something else has redefined,
such as a function of the application with the same name, which it should
shadow in its package instead."
  (let ((redefined (loop for name being the hash-keys of godot-generators::*short-names*
                         when (godot-generators::short-name-redefined-p name)
                           collect name)))
    (when redefined
      (error "GODOT defines these names for engine methods and properties, but something ~
              else redefined them: ~{~s~^, ~}. Shadow them in the package that does, with ~
              (:shadow ...)."
             redefined))))

;; Once the application is loaded. GODOT is above GD-EXTENSION, so this can't be
;; one of the framework's steps (lifecycle.lisp); as GODOT is loaded before the
;; application, it's the first initialize hook.
(gdext:add-initialize-hook 'check-short-names)
