(in-package :gd-extension)

;;;
;;; Defining classes
;;;
;;; DEFINE-CLASS defines an extension class in one form: the struct of its
;;; instances' Lisp objects (which includes GODOT-OBJECT), and the registration
;;; of the class, its properties, signals, methods and virtual methods. The
;;; classes are registered when Godot initializes the extension, in the order
;;; they were defined, by an initialize hook that GD-EXTENSION adds when it's
;;; loaded, so it runs before the application's hooks.
;;;

;; The registration functions of the classes defined with DEFINE-CLASS: a list
;; of (class-name . function), in the order they were defined
(defvar *class-definitions* '())

(defun add-class-definition (class-name function)
  "Make FUNCTION, which registers the class CLASS-NAME, run when Godot initializes
the extension, or now if it has (e.g. at a REPL). Defining the class again
replaces the function, keeping its place in the order."
  (let ((definition (assoc class-name *class-definitions* :test #'string=)))
    (if definition
        (setf (cdr definition) function)
        (setf *class-definitions*
              (append *class-definitions* (list (cons class-name function))))))
  (when *class-library*
    (funcall function))
  class-name)

(defun register-defined-classes ()
  "Register the classes defined with DEFINE-CLASS. An initialize hook. A class
that fails to register is reported, and the others are still registered."
  (loop for (class-name . function) in *class-definitions*
        do (handler-case (funcall function)
             (error (e)
               (report-error (format nil "registering the class ~a" class-name) e)))))

(add-initialize-hook 'register-defined-classes)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun function-form (designator)
    "A form for the function DESIGNATOR in DEFINE-CLASS: a symbol, called by name
so that redefining the function takes effect, or a form such as (LAMBDA ...)."
    (if (symbolp designator)
        `',designator
        designator))

  (defun arguments-form (arguments)
    "A form for the list of (name type) ARGUMENTS of DEFINE-CLASS, with the types
evaluated, so they can be keywords or variant type constants."
    `(list ,@(loop for (name type) in arguments
                   collect `(list ,name ,type))))

  (defun godot-property-name (slot-name)
    "The name of the property of the slot SLOT-NAME, a symbol, in Godot style:
mob-scene becomes \"mob_scene\"."
    (substitute #\_ #\- (string-downcase (symbol-name slot-name))))

  (defun define-class-property-forms (class-name accessor slot-name type class setter
                                     ref-counted)
    "The forms that bind the property of the slot SLOT-NAME, with its getter and
setter methods, get_<name> and set_<name>. REF-COUNTED, if not NIL, is a
variable that says whether the values are RefCounted, so the generated setter
takes and gives back references."
    (let* ((property-name (godot-property-name slot-name))
           (getter-name (format nil "get_~a" property-name))
           (setter-name (format nil "set_~a" property-name)))
      `((bind-method ,class-name ,getter-name
                     (lambda (object) (,accessor object))
                     :return-type ,type)
        (bind-method ,class-name ,setter-name
                     ,(cond (setter
                             (function-form setter))
                            (ref-counted
                             `(lambda (object value)
                                (if ,ref-counted
                                    (setf-reference (,accessor object) value)
                                    (setf (,accessor object) value))))
                            (t
                             `(lambda (object value) (setf (,accessor object) value))))
                     :arguments (list (list "value" ,type)))
        (bind-property ,class-name ,property-name ,type ,getter-name ,setter-name
                       ,@(when class `(:class ,class))))))

  (defun define-class-option-forms (class-name option)
    "The forms that bind what the class option OPTION of DEFINE-CLASS defines."
    (destructuring-bind (kind &rest arguments) option
      (ecase kind
        (:signal
         (destructuring-bind (signal-name &rest signal-arguments) arguments
           `((bind-signal ,class-name ,signal-name ,(arguments-form signal-arguments)))))
        (:method
         (destructuring-bind (method-name function &key arguments (return-type :nil))
             arguments
           `((bind-method ,class-name ,method-name ,(function-form function)
                          :arguments ,(arguments-form arguments)
                          :return-type ,return-type))))
        (:virtual
         (destructuring-bind (virtual-name function) arguments
           `((bind-virtual ,class-name ,virtual-name ,(function-form function)))))
        ((:destructor :tool)
         ;; Arguments of REGISTER-CLASS
         '())))))

(defmacro define-class (name (class-name parent-class-name) slots &rest options)
  "Define the extension class CLASS-NAME, which inherits from the class
PARENT-CLASS-NAME (both strings), with NAME as the struct of its instances'
Lisp objects, like extends and the script of a class in GDScript.

The struct includes GODOT-OBJECT, and has the SLOTS, each a symbol or (name
initform &key export class setter onready), as in DEFSTRUCT. A slot with EXPORT, a type
as in VARIANT-TYPE, is a property, like @export var in GDScript: its name in
Godot style (mob-scene becomes mob_scene), with the getter and setter methods
get_<name> and set_<name>. CLASS is as in BIND-PROPERTY. If it's a RefCounted
class, such as a Resource, the slot keeps a reference to its value, like a
Ref<T>: the setter takes one (see SETF-REFERENCE) and it's given back when Godot
frees the instance. SETTER, a function called with the Lisp object and the
value, replaces the generated setter, and then the slot's references are up to
it.

A slot with ONREADY is set when the instance is ready, before the class's
_ready virtual method runs, like @onready var in GDScript: to the node at the
path ONREADY, a string, as with $Path, or to the result of the function ONREADY,
called with the Lisp object.

OPTIONS are:
  (:signal name (argument-name type)...), see BIND-SIGNAL
  (:method name function &key arguments return-type), see BIND-METHOD
  (:virtual name function), see BIND-VIRTUAL
  (:destructor function), called with the Lisp object when Godot frees it
  (:tool t), see REGISTER-CLASS
Functions are symbols, called by name, so redefining them takes effect, or
forms that evaluate to functions. They're called with the Lisp object, like
self in GDScript.

The class is registered when Godot initializes the extension, before the
initialize hooks of the application run."
  (let ((make-name (intern (format nil "MAKE-~a" (symbol-name name))))
        (struct-slots '())
        (property-forms '())
        ;; The forms that set the :ONREADY slots of OBJECT
        (onready-forms '())
        ;; The exported slots with a class whose references are managed here:
        ;; a list of (accessor class variable), where the variable says
        ;; whether the class is RefCounted, found out at registration
        (reference-slots '()))
    (dolist (slot slots)
      (destructuring-bind (slot-name &optional initform &key export class setter onready)
          (if (listp slot) slot (list slot))
        (push `(,slot-name ,initform) struct-slots)
        (when onready
          (push `(setf (,(intern (format nil "~a-~a" (symbol-name name) (symbol-name slot-name)))
                        object)
                       ,(if (stringp onready)
                            `(node-get-node object ,onready)
                            `(funcall ,(function-form onready) object)))
                onready-forms))
        (cond (export
               (let ((accessor (intern (format nil "~a-~a" (symbol-name name)
                                               (symbol-name slot-name))))
                     (ref-counted (and class (not setter)
                                       (gensym (format nil "~a-REF-COUNTED"
                                                       (symbol-name slot-name))))))
                 (when ref-counted
                   (push (list accessor class ref-counted) reference-slots))
                 (setf property-forms
                       (append property-forms
                               (define-class-property-forms class-name accessor slot-name
                                                            export class setter ref-counted)))))
              ((or class setter)
               (error "The slot ~s of ~s has :CLASS or :SETTER, but no :EXPORT" slot-name name)))))
    (when onready-forms
      ;; The slots are set in _ready, before the class's own _ready, if any
      (let ((ready (find-if (lambda (option)
                              (and (eq (first option) :virtual)
                                   (equal (second option) "_ready")))
                            options)))
        (setf options
              (cons `(:virtual "_ready"
                               (lambda (object)
                                 ,@(reverse onready-forms)
                                 ,@(when ready
                                     `((funcall ,(function-form (third ready)) object)))))
                    (remove ready options)))))
    (let* ((destructor (second (assoc :destructor options)))
           (tool (second (assoc :tool options)))
           (release-forms (loop for (accessor nil ref-counted) in (reverse reference-slots)
                                collect `(when ,ref-counted
                                           (release-reference (,accessor object)))))
           (destructor-form
             (cond ((and destructor release-forms)
                    `(lambda (object)
                       (unwind-protect (funcall ,(function-form destructor) object)
                         ,@release-forms)))
                   (destructor (function-form destructor))
                   (release-forms `(lambda (object) ,@release-forms)))))
      `(progn
         (defstruct (,name (:include godot-object) (:constructor ,make-name))
           ,@(reverse struct-slots))
         (add-class-definition
          ,class-name
          (lambda ()
            (let (,@(loop for (nil class ref-counted) in (reverse reference-slots)
                          collect `(,ref-counted (inherits-class-p ,class "RefCounted"))))
              (register-class ,class-name ,parent-class-name
                              :constructor (lambda (pointer) (,make-name :pointer pointer))
                              ,@(when destructor-form `(:destructor ,destructor-form))
                              ,@(when tool `(:tool ,tool)))
              ,@property-forms
              ,@(loop for option in options
                      append (define-class-option-forms class-name option)))))
         ',name))))
