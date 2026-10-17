(in-package :godot-dsl)

;;;
;;; Defining classes
;;;
;;; DEFINE-CLASS defines an extension class in one form: the struct of its
;;; instances' Lisp objects (which includes GODOT-OBJECT), and the registration
;;; of the class, its properties, signals, methods and virtual methods, with
;;; the functions of GD-EXTENSION (registration.lisp). The classes are
;;; registered when Godot initializes the extension, in the order they were
;;; defined (see ADD-CLASS-DEFINITION), before the application's initialize
;;; hooks.
;;;

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun invoker-arguments (return-type-form argument-type-forms)
    "The arguments :INVOKER and the invoker's form (see INVOKER-FORM) for
BIND-METHOD, for a method whose types are given as forms, as in VARIANT-TYPE, if
they're all constants. Otherwise NIL, and the method's calls go through the
generic dispatcher."
    (when (every #'constantp (cons return-type-form argument-type-forms))
      (let ((form (invoker-form (eval return-type-form)
                                (mapcar #'eval argument-type-forms))))
        (when form
          `(:invoker ,form)))))

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

  (defstruct (class-slot (:conc-name class-slot-))
    "A slot of DEFINE-CLASS, while its expansion is generated (only at
macroexpansion time). See DEFINE-CLASS for the options."
    name
    initform
    export
    class
    setter
    onready
    ;; The accessor of the slot in the struct, <struct>-<slot>
    accessor
    ;; For an exported slot with a class whose references are managed here: a
    ;; variable that says whether the class is RefCounted, found out at
    ;; registration. Otherwise NIL.
    ref-counted)

  (defun parse-class-slot (struct-name slot)
    "SLOT, a slot of DEFINE-CLASS (a symbol, or a list of the name, initform and
options), of the struct STRUCT-NAME, as a CLASS-SLOT."
    (destructuring-bind (slot-name &optional initform &key export class setter onready)
        (if (listp slot) slot (list slot))
      (when (and (not export) (or class setter))
        (error "The slot ~s of ~s has :CLASS or :SETTER, but no :EXPORT" slot-name struct-name))
      (make-class-slot :name slot-name
                       :initform initform
                       :export export
                       :class class
                       :setter setter
                       :onready onready
                       :accessor (intern (format nil "~a-~a" (symbol-name struct-name)
                                                 (symbol-name slot-name)))
                       :ref-counted (and export class (not setter)
                                         (gensym (format nil "~a-REF-COUNTED"
                                                         (symbol-name slot-name)))))))

  (defun define-class-property-forms (class-name slot)
    "The forms that bind the property of SLOT, an exported CLASS-SLOT, with its
getter and setter methods, get_<name> and set_<name>. If the slot has a
REF-COUNTED variable, the generated setter takes and gives back references when
the values are RefCounted."
    (let* ((property-name (godot-property-name (class-slot-name slot)))
           (getter-name (format nil "get_~a" property-name))
           (setter-name (format nil "set_~a" property-name))
           (accessor (class-slot-accessor slot))
           (type (class-slot-export slot))
           (class (class-slot-class slot))
           (setter (class-slot-setter slot))
           (ref-counted (class-slot-ref-counted slot)))
      `((bind-method ,class-name ,getter-name
                     (lambda (object) (,accessor object))
                     :return-type ,type
                     ,@(invoker-arguments type '()))
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
                     :arguments (list (list "value" ,type))
                     ,@(invoker-arguments :nil (list type)))
        (bind-property ,class-name ,property-name ,type ,getter-name ,setter-name
                       ,@(when class `(:class ,class))))))

  (defun onready-options (slots options)
    "OPTIONS of DEFINE-CLASS, with a (:VIRTUAL \"_ready\" ...) that sets the
:ONREADY SLOTS first, and then calls the class's own _ready, if any, which it
replaces. OPTIONS as they are if no slot has :ONREADY."
    (let ((onready-forms
            (loop for slot in slots
                  for onready = (class-slot-onready slot)
                  when onready
                    collect `(setf (,(class-slot-accessor slot) object)
                                   ,(if (stringp onready)
                                        `(node-get-node object ,onready)
                                        `(funcall ,(function-form onready) object))))))
      (if onready-forms
          (let ((ready (find-if (lambda (option)
                                  (and (eq (first option) :virtual)
                                       (equal (second option) "_ready")))
                                options)))
            (cons `(:virtual "_ready"
                             (lambda (object)
                               ,@onready-forms
                               ,@(when ready
                                   `((funcall ,(function-form (third ready)) object)))))
                  (remove ready options)))
          options)))

  (defun define-class-destructor-form (slots destructor)
    "The form for the destructor of DEFINE-CLASS, a function called with the Lisp
object: the class's DESTRUCTOR option, then giving back the references of the
SLOTS that keep them. NIL if there's neither."
    (let ((release-forms (loop for slot in slots
                               for ref-counted = (class-slot-ref-counted slot)
                               when ref-counted
                                 collect `(when ,ref-counted
                                            (release-reference (,(class-slot-accessor slot) object))))))
      (cond ((and destructor release-forms)
             `(lambda (object)
                (unwind-protect (funcall ,(function-form destructor) object)
                  ,@release-forms)))
            (destructor (function-form destructor))
            (release-forms `(lambda (object) ,@release-forms)))))

  (defun parse-signal-option (arguments)
    "The name, the arguments and the :EMITTER of the ARGUMENTS of a :SIGNAL option
of DEFINE-CLASS: (name (argument-name type)... [:emitter emitter])."
    (destructuring-bind (signal-name &rest rest) arguments
      (let ((emitter-position (position :emitter rest)))
        (values signal-name
                (subseq rest 0 emitter-position)
                (and emitter-position (nth (1+ emitter-position) rest))))))

  (defun define-class-emitter-forms (option)
    "The DEFINE-SIGNAL-EMITTER of the :SIGNAL option OPTION of DEFINE-CLASS, as a
list, if it has an :EMITTER."
    (when (eq (first option) :signal)
      (multiple-value-bind (signal-name signal-arguments emitter)
          (parse-signal-option (rest option))
        (when emitter
          `((define-signal-emitter ,emitter ,signal-name
              ,(loop for (argument-name type) in signal-arguments
                     collect (list (engine-method-argument-symbol argument-name) type))))))))

  (defun define-class-option-forms (class-name option)
    "The forms that bind what the class option OPTION of DEFINE-CLASS defines."
    (destructuring-bind (kind &rest arguments) option
      (ecase kind
        (:signal
         (multiple-value-bind (signal-name signal-arguments) (parse-signal-option arguments)
           `((bind-signal ,class-name ,signal-name ,(arguments-form signal-arguments)))))
        (:method
         (destructuring-bind (method-name function &key arguments (return-type :nil))
             arguments
           `((bind-method ,class-name ,method-name ,(function-form function)
                          :arguments ,(arguments-form arguments)
                          :return-type ,return-type
                          ,@(invoker-arguments return-type (mapcar #'second arguments))))))
        (:virtual
         (destructuring-bind (virtual-name function) arguments
           `((bind-virtual ,class-name ,virtual-name ,(function-form function)))))
        ((:destructor :tool :singleton)
         ;; Arguments of REGISTER-CLASS, and the singleton, made after the rest
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
  (:signal name (argument-name type)... [:emitter emitter]), see BIND-SIGNAL;
    EMITTER, a symbol, is defined as a function that emits the signal, fast
    for arguments of simple types, see DEFINE-SIGNAL-EMITTER
  (:method name function &key arguments return-type), see BIND-METHOD
  (:virtual name function), see BIND-VIRTUAL
  (:destructor function), called with the Lisp object when Godot frees it
  (:tool t), see REGISTER-CLASS
  (:singleton t) or (:singleton name), an instance registered as the engine
    singleton with the class's name or NAME, see REGISTER-SINGLETON
Functions are symbols, called by name, so redefining them takes effect, or
forms that evaluate to functions. They're called with the Lisp object, like
self in GDScript.

The class is registered when Godot initializes the extension, before the
initialize hooks of the application run."
  (let* ((make-name (intern (format nil "MAKE-~a" (symbol-name name))))
         (slots (mapcar (lambda (slot) (parse-class-slot name slot)) slots))
         (options (onready-options slots options))
         (destructor-form (define-class-destructor-form slots
                                                        (second (assoc :destructor options))))
         (tool (second (assoc :tool options)))
         (singleton (second (assoc :singleton options))))
    `(progn
       (defstruct (,name (:include ,(engine-object-type parent-class-name))
                         (:constructor ,make-name))
         ,@(loop for slot in slots
                 collect `(,(class-slot-name slot) ,(class-slot-initform slot))))
       (add-class-definition
        ,class-name
        (lambda ()
          (let (,@(loop for slot in slots
                        for ref-counted = (class-slot-ref-counted slot)
                        when ref-counted
                          collect `(,ref-counted (inherits-class-p ,(class-slot-class slot)
                                                                   "RefCounted"))))
            (register-class ,class-name ,parent-class-name
                            ;; The slots that keep references take them for the
                            ;; values of their initforms too, made in Godot's
                            ;; create_instance callback, whose autorelease pool
                            ;; gives back the first reference
                            :constructor (lambda (pointer)
                                           (let ((object (,make-name :pointer pointer)))
                                             ,@(loop for slot in slots
                                                     for ref-counted = (class-slot-ref-counted slot)
                                                     when ref-counted
                                                       collect `(when ,ref-counted
                                                                  (let ((value (,(class-slot-accessor slot)
                                                                                object)))
                                                                    (when value
                                                                      (add-reference value)))))
                                             object))
                            ,@(when destructor-form `(:destructor ,destructor-form))
                            ,@(when tool `(:tool ,tool)))
            ,@(loop for slot in slots
                    when (class-slot-export slot)
                      append (define-class-property-forms class-name slot))
            ,@(loop for option in options
                    append (define-class-option-forms class-name option))
            ,@(when singleton
                `((register-singleton ,class-name
                                      ,@(when (stringp singleton) `(,singleton))))))))
       ,@(loop for option in options
               append (define-class-emitter-forms option))
       ',name)))
