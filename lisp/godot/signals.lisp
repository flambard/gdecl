;;;; Signals in GODOT: AFTER-SIGNAL, for what GDScript does with await. Built on
;;;; GD-EXTENSION:CONNECT-SIGNAL, which connects a signal to a Lisp function.

(in-package :godot)

(defmacro after-signal ((object signal-name &key target) &body body)
  "Evaluate BODY once, the next time OBJECT emits the signal SIGNAL-NAME (a
StringName, see GD-EXTENSION:SNAME, or a literal string), like the code after
await object.signal_name in GDScript. Returns right away. TARGET is as in
GD-EXTENSION:CONNECT-SIGNAL; with TARGET the object that the code belongs to,
BODY isn't run if that object has been freed by then."
  (let ((object-var (gensym "OBJECT")))
    `(let ((,object-var ,object))
       (gdext:connect-signal ,object-var ,signal-name
                             (lambda (&rest arguments)
                               (declare (ignore arguments))
                               ,@body)
                             :target ,(or target object-var)
                             :flags +object-connect-one-shot+))))
