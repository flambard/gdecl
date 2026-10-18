(in-package :gd-extension-callback)

;;;
;;; Initialization
;;;
;;; INITIALIZE and DEINITIALIZE are called from src/gdecl.c when Godot loads and
;;; unloads the extension: the entry points into Lisp, before there are any
;;; callbacks. Applications add hooks to them, re-exported by GD-EXTENSION.
;;;

;; The framework's own steps at startup and shutdown, function names in the
;; order they run: at startup before the application's initialize hooks, at
;; shutdown after its deinitialize hooks. Set in one place, lifecycle.lisp in
;; GD-EXTENSION, where the order is explained, so it doesn't depend on the
;; order the files are loaded in.
(defvar *framework-initialize* '())
(defvar *framework-deinitialize* '())

;; Functions called at the end of INITIALIZE, see ADD-INITIALIZE-HOOK
(defvar *initialize-hooks* '())

(defun run-hooks (hooks what)
  "Call each of HOOKS, function designators, in order, each with its own
autorelease pool. An error in one is reported, as happening in WHAT and the
hook, and the others still run."
  (dolist (hook hooks)
    (with-callback-protection ((format nil "~a ~a" what hook))
      (funcall hook))))

(defun add-initialize-hook (function)
  "Call FUNCTION, a function designator taking no arguments, at the end of
INITIALIZE, once the framework is set up (see *FRAMEWORK-INITIALIZE*): the
classes defined with DEFINE-CLASS and GODOT-CLOS are registered. Hooks run in
the order they were added; adding a hook again doesn't run it twice. This is how
an application registers its entry point: by calling ADD-INITIALIZE-HOOK when
it's loaded."
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
initialize cells made so far, run the framework's steps, then the application's
initialize hooks. Called from src/gdecl.c."
  (load-interface get-proc-address class-library)
  ;; Without an autorelease pool, so a cell keeps a RefCounted value
  (loop for (cell . function) in (reverse *initialize-cells*)
        do (let ((condition (catching-errors (setf (car cell) (funcall function)))))
             (when condition
               (report-error "initialize" condition))))
  (setf *initialize-cells* '())
  (run-hooks *framework-initialize* "initialize")
  (run-hooks *initialize-hooks* "initialize hook")
  t)

;; Functions called by DEINITIALIZE, see ADD-DEINITIALIZE-HOOK
(defvar *deinitialize-hooks* '())

(defun add-deinitialize-hook (function)
  "Call FUNCTION, a function designator taking no arguments, in DEINITIALIZE,
when Godot unloads the extension, while Godot can still be called. Hooks run in
the reverse order they were added, so that what was set up last is cleaned up
first, and before the framework cleans up (see *FRAMEWORK-DEINITIALIZE*);
adding a hook again doesn't run it twice."
  (setf *deinitialize-hooks*
        (cons function (remove function *deinitialize-hooks*))))

(defun deinitialize ()
  "Clean up when Godot unloads the extension: run the application's deinitialize
hooks, then the framework's steps, then stop the callbacks from calling into
Lisp. Called from src/gdecl.c, before ECL is shut down."
  (run-hooks *deinitialize-hooks* "deinitialize hook")
  (run-hooks *framework-deinitialize* "deinitialize")
  (stop-entering-lisp)
  t)
