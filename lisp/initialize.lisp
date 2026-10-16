(in-package :gd-extension-callback)

;;;
;;; Initialization
;;;
;;; INITIALIZE and DEINITIALIZE are called from src/gdecl.c when Godot loads and
;;; unloads the extension: the entry points into Lisp, before there are any
;;; callbacks. Applications add hooks to them, re-exported by GD-EXTENSION.
;;;

;; Functions called at the end of INITIALIZE, see ADD-INITIALIZE-HOOK
(defvar *initialize-hooks* '())

(defun add-initialize-hook (function)
  "Call FUNCTION, a function designator taking no arguments, at the end of
INITIALIZE, once the framework is set up. Hooks run in the order they were
added; adding a hook again doesn't run it twice. This is how an application
registers its entry point: by calling ADD-INITIALIZE-HOOK when it's loaded."
  (setf *initialize-hooks*
        (append (remove function *initialize-hooks*) (list function))))

;; An initialize cell is a cons whose car is computed in INITIALIZE, for
;; things that must be looked up in Godot once, but can't be looked up at load
;; time (see GD-EXTENSION:SNAME).
(defvar *initialize-cells* '())

(defun make-initialize-cell (function)
  "A cons whose car will be the value of FUNCTION, called with no arguments in
INITIALIZE, or now if INITIALIZE has been called (e.g. at a REPL)."
  (let ((cell (cons nil nil)))
    (if *class-library*
        (setf (car cell) (funcall function))
        (push (cons cell function) *initialize-cells*))
    cell))

(defun initialize (get-proc-address class-library)
  "Set up the framework with the GDExtensionInterfaceGetProcAddress and
GDExtensionClassLibraryPtr that Godot gave the extension, fill in the
initialize cells made so far, then run the initialize hooks. Called from
src/gdecl.c."
  (load-interface get-proc-address class-library)
  ;; Without an autorelease pool, so a cell keeps a RefCounted value
  (loop for (cell . function) in (reverse *initialize-cells*)
        do (let ((condition (catching-errors (setf (car cell) (funcall function)))))
             (when condition
               (report-error "initialize" condition))))
  (setf *initialize-cells* '())
  (dolist (hook *initialize-hooks*)
    (with-callback-protection ((format nil "initialize hook ~a" hook))
      (funcall hook)))
  t)

;; Functions called by DEINITIALIZE, see ADD-DEINITIALIZE-HOOK
(defvar *deinitialize-hooks* '())

(defun add-deinitialize-hook (function)
  "Call FUNCTION, a function designator taking no arguments, in DEINITIALIZE,
when Godot unloads the extension, while Godot can still be called. Hooks run in
the reverse order they were added, so that what was set up last is cleaned up
first; adding a hook again doesn't run it twice."
  (setf *deinitialize-hooks*
        (cons function (remove function *deinitialize-hooks*))))

(defun deinitialize ()
  "Clean up when Godot unloads the extension: run the deinitialize hooks, then
stop the callbacks from calling into Lisp. Called from src/gdecl.c, before ECL
is shut down."
  (dolist (hook *deinitialize-hooks*)
    (with-callback-protection ((format nil "deinitialize hook ~a" hook))
      (funcall hook)))
  (stop-entering-lisp)
  t)
