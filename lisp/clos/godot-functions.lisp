(in-package :godot-clos)

;;;
;;; Generic functions that Godot calls
;;;
;;; What Godot calls on an instance of a GODOT-CLASS is a generic function, so
;;; it's implemented with DEFMETHOD, and gets inheritance, mixins, method
;;; combination (:BEFORE, :AFTER, :AROUND) and CALL-NEXT-METHOD:
;;;
;;; - Virtual methods of engine classes, such as _process: generic functions
;;;   of the class VIRTUAL-FUNCTION, defined with DEFINE-VIRTUAL-FUNCTION, such
;;;   as PROCESS below. A class implements a virtual method if it has a method
;;;   for it, and only then does Godot call into Lisp for it.
;;;
;;; - Methods that Godot and GDScript call by name, like the funcs of a GDScript
;;;   script: generic functions of the class GODOT-METHOD, defined with
;;;   DEFINE-GODOT-GENERIC, which says the method's name and types in Godot. A
;;;   class gets the method if it has a method for it; its subclasses inherit
;;;   it in Godot.
;;;
;;; - Notifications, like _notification in GDScript: the generic function
;;;   NOTIFICATION. A class gets the notifications its methods specialize the
;;;   notification on with EQL, or all of them if one of its methods doesn't.
;;;
;;; A class "has a method" for a generic function if a method's first
;;; specializer is the class or a standard class it inherits from (a GODOT-CLASS
;;; or a mixin), not a struct of an engine class or T, which may have default
;;; methods. Which ones it has is found when the class is registered, and again
;;; when a method is added or removed, or the class redefined
;;; (godot-registration.lisp).
;;;
;;; Godot calls the generic function by name, through the invokers of
;;; BIND-METHOD and BIND-VIRTUAL, so its dispatch runs at every call: about
;;; 60 ns more than calling a function by name, as DEFINE-CLASS's methods are.
;;;

(defclass godot-function (standard-generic-function)
  ((godot-name :initform nil :reader godot-name
               :documentation "The name of the method in Godot, a string."))
  (:metaclass clos:funcallable-standard-class)
  (:documentation "A generic function that Godot calls."))

(defun class-methods (function class)
  "The methods of the generic function FUNCTION that CLASS has: those whose
first specializer is CLASS or a standard class it inherits from."
  (let ((precedence-list (clos:class-precedence-list class)))
    (remove-if-not (lambda (method)
                     (let ((specializer (first (clos:method-specializers method))))
                       (and (typep specializer 'standard-class)
                            (member specializer precedence-list))))
                   (clos:generic-function-methods function))))

;;;
;;; Virtual methods
;;;

(defvar *virtual-functions* '()
  "The names of the VIRTUAL-FUNCTIONs, the last defined first.")

(defclass virtual-function (godot-function)
  ((engine-class :reader virtual-engine-class
                 :documentation "The engine class with the virtual method, a string.")
   (binder :reader virtual-binder
           :documentation "A function of a class name and a function, which binds the
function as the class's virtual method, with BIND-VIRTUAL.")
   (function-name :reader virtual-function-name
                  :documentation "The function Godot calls, by name: the generic function, or
one that calls it.")
   (implemented-p :reader virtual-implemented-p
                  :documentation "A function of the generic function and a GODOT-CLASS that's
true if the class implements the virtual method."))
  (:metaclass clos:funcallable-standard-class)
  (:documentation "A generic function that's a virtual method of an engine class,
such as _process, see DEFINE-VIRTUAL-FUNCTION."))

(defun class-has-methods-p (function class)
  "True if CLASS has methods for the generic function FUNCTION (see
CLASS-METHODS), the default for VIRTUAL-IMPLEMENTED-P."
  (and (class-methods function class) t))

(defun initialize-virtual-function (name engine-class virtual-name binder function-name
                                    implemented-p)
  (let ((function (fdefinition name)))
    (setf (slot-value function 'godot-name) virtual-name
          (slot-value function 'engine-class) engine-class
          (slot-value function 'binder) binder
          (slot-value function 'function-name) function-name
          (slot-value function 'implemented-p) implemented-p)
    (pushnew name *virtual-functions*)
    name))

(defmacro define-virtual-function (name (engine-class virtual-name) lambda-list &rest options)
  "Define the generic function NAME, with LAMBDA-LIST, as the virtual method
VIRTUAL-NAME of the engine class ENGINE-CLASS (both literal strings), e.g.
(define-virtual-function process (\"Node\" \"_process\") (self delta)). Godot
calls it for an instance of a GODOT-CLASS that inherits from ENGINE-CLASS and
has a method for it, with the instance's Lisp object and the arguments as Lisp
values. The signature is looked up in extension_api.json, and LAMBDA-LIST must
have one more argument than the virtual method has. Engine classes can have
virtual methods of the same name with other arguments (_process of
AnimationNode), which need generic functions of their own.

OPTIONS are those of DEFGENERIC, and:
  (:function name), the function Godot calls, by name, if not NAME itself
  (:implemented-p name), the function of the generic function and the class
    that's true if the class implements it, by default if it has methods for it"
  (let* ((signature (or (find engine-class (virtual-signatures virtual-name)
                              :key #'first :test #'string=)
                        (error "The engine class ~a has no virtual method ~a" engine-class
                               virtual-name)))
         (argument-count (length (third signature))))
    (unless (= (length lambda-list) (1+ argument-count))
      (error "~a.~a has ~d arguments, so the lambda list of ~s must have ~d: ~s"
             engine-class virtual-name argument-count name (1+ argument-count) lambda-list))
    `(progn
       (defgeneric ,name ,lambda-list
         (:generic-function-class virtual-function)
         ,@(remove-if (lambda (option) (member (first option) '(:function :implemented-p)))
                      options))
       (initialize-virtual-function ',name ,engine-class ,virtual-name
                                    (lambda (class-name function)
                                      (gdext:bind-virtual class-name ,virtual-name function))
                                    ',(or (second (assoc :function options)) name)
                                    ',(or (second (assoc :implemented-p options))
                                          'class-has-methods-p)))))

;;;
;;; Methods that Godot and GDScript call by name
;;;

(defvar *godot-methods* '()
  "The names of the GODOT-METHODs, the last defined first.")

(defclass godot-method (godot-function)
  ((return-type :reader method-return-type
                :documentation "The type of the return value, as in VARIANT-TYPE.")
   (arguments :reader method-arguments
              :documentation "The arguments after the instance, a list of (name type), as
BIND-METHOD takes them.")
   (invoker :reader method-invoker
            :documentation "The invoker for the signature, see REGISTER-METHOD, or NIL."))
  (:metaclass clos:funcallable-standard-class)
  (:documentation "A generic function that's a method that Godot and GDScript
call by name, see DEFINE-GODOT-GENERIC."))

(defun initialize-godot-method (name godot-name return-type arguments invoker)
  (let ((function (fdefinition name)))
    (setf (slot-value function 'godot-name) godot-name
          (slot-value function 'return-type) return-type
          (slot-value function 'arguments) arguments
          (slot-value function 'invoker) invoker)
    (pushnew name *godot-methods*)
    name))

(defmacro define-godot-generic (name (self &rest arguments) &rest options)
  "Define the generic function NAME as a method that Godot and GDScript can call
by name, like a func of a GDScript script, e.g.
(define-godot-generic start (self (pos :vector2))). SELF is the instance, and
ARGUMENTS are (name type), with types as in VARIANT-TYPE. A GODOT-CLASS that
has a method for it gets the method in Godot, which calls it with the
instance's Lisp object and the arguments as Lisp values.

OPTIONS are those of DEFGENERIC, and:
  (:godot-name name), the method's name in Godot, by default NAME in Godot
    style (on-hit becomes \"on_hit\")
  (:return-type type), the type of the return value, by default none (:NIL)"
  (let ((godot-name (or (second (assoc :godot-name options)) (godot-style-name name)))
        (return-type (or (second (assoc :return-type options)) :nil)))
    `(progn
       (defgeneric ,name (,self ,@(mapcar #'first arguments))
         (:generic-function-class godot-method)
         ,@(remove-if (lambda (option) (member (first option) '(:godot-name :return-type)))
                      options))
       (initialize-godot-method ',name ,godot-name ,return-type
                                (list ,@(loop for (argument type) in arguments
                                              collect `(list ,(godot-style-name argument) ,type)))
                                ,(invoker-form return-type (mapcar #'second arguments))))))

;;;
;;; The virtual methods of engine classes that most classes use. An
;;; application defines others with DEFINE-VIRTUAL-FUNCTION. _input isn't one
;;; of them, as INPUT is the struct of the engine class Input in GODOT.
;;;

(defun ready-with-onready-slots (self)
  "Set the :ONREADY slots of SELF, then call READY, for _ready."
  (loop for (slot-name . onready) in (class-onready-slots (class-of self))
        do (setf (slot-value self slot-name)
                 (if (stringp onready)
                     (godot:node-get-node self onready)
                     (funcall onready self))))
  (ready self))

(defun ready-implemented-p (function class)
  "True if CLASS has :ONREADY slots or methods for READY."
  (or (class-onready-slots class) (class-has-methods-p function class)))

(define-virtual-function ready ("Node" "_ready") (self)
  (:documentation "Called when the node and its children have entered the scene
tree, after the :ONREADY slots are set, like _ready in GDScript.")
  (:function ready-with-onready-slots)
  (:implemented-p ready-implemented-p))

;; For a class with :ONREADY slots and no methods of its own
(defmethod ready ((self godot-object))
  nil)

(define-virtual-function process ("Node" "_process") (self delta)
  (:documentation "Called every frame, with the time since the last one in seconds,
like _process in GDScript."))

(define-virtual-function physics-process ("Node" "_physics_process") (self delta)
  (:documentation "Called every physics frame, like _physics_process in GDScript."))

(define-virtual-function enter-tree ("Node" "_enter_tree") (self)
  (:documentation "Called when the node enters the scene tree, like _enter_tree in
GDScript."))

(define-virtual-function exit-tree ("Node" "_exit_tree") (self)
  (:documentation "Called when the node is about to leave the scene tree, like
_exit_tree in GDScript."))

(define-virtual-function unhandled-input ("Node" "_unhandled_input") (self event)
  (:documentation "Called with an InputEvent that nothing else handled, like
_unhandled_input in GDScript."))

(define-virtual-function draw ("CanvasItem" "_draw") (self)
  (:documentation "Called to draw the canvas item, like _draw in GDScript."))

;;;
;;; Notifications
;;;
;;; Godot sends every notification of an object to its class's
;;; notification_func, including some every frame, such as
;;; NOTIFICATION_PROCESS, and only those a class has methods for reach Lisp
;;; (see Notifications in extension-classes.lisp).
;;;

(defgeneric notification (self what)
  (:generic-function-class godot-function)
  (:documentation "Called with a notification WHAT (an integer) that Godot sends
SELF, like _notification in GDScript, e.g.

  (defmethod notification ((self player) (what (eql +object-notification-predelete+)))
    ...)

for cleaning up before Godot frees the object. The notifications are constants
in GODOT, such as +NODE-NOTIFICATION-PARENTED+. A class gets the notifications
that its methods (see CLASS-METHODS) specialize WHAT on with EQL, or all of
them if one of its methods doesn't specialize WHAT, which costs a call into
Lisp for every notification, also those sent every frame."))

;; For notifications that a class's methods don't handle, such as a mixin's
;; :BEFORE method alone
(defmethod notification ((self godot-object) what)
  (declare (ignore what))
  nil)

(defun call-notification (object what reversed)
  "Call NOTIFICATION, for REGISTER-CLASS's notification function. REVERSED isn't
used: the methods' order is that of the method combination."
  (declare (ignore reversed))
  (notification object what))

(defun class-notifications (class)
  "The notifications CLASS gets, from the methods of NOTIFICATION it has: a list,
or T for all."
  (let ((notifications '()))
    (dolist (method (class-methods #'notification class) notifications)
      (let ((specializer (second (clos:method-specializers method))))
        (if (typep specializer 'clos:eql-specializer)
            (pushnew (clos:eql-specializer-object specializer) notifications)
            (return t))))))
