(in-package :godot-clos)

;;;
;;; Godot classes as CLOS classes, the high-level layer (see TODO P)
;;;
;;; GODOT-CLASS is the metaclass of Lisp classes that are Godot extension
;;; classes:
;;;
;;;   (defclass player (godot:area-2d)
;;;     ((speed :initform 400 :export :int :accessor speed)
;;;      (sprite :onready "AnimatedSprite2D" :reader sprite))
;;;     (:metaclass godot-class)
;;;     (:signals (hit)))
;;;
;;; A class inherits from the struct of the engine class it extends (see
;;; GD-EXTENSION:DEFINE-ENGINE-CLASS), or from another GODOT-CLASS, and may
;;; have mixins, standard classes, besides. So its instances are GODOT-OBJECTs,
;;; which the layers below take as they are: engine methods, the Object value
;;; type, instance bindings. That rests on two things ECL does: a standard
;;; class may inherit from structure classes when VALIDATE-SUPERCLASS allows
;;; it, and the structs' slots come first, so the pointer is at
;;; +GODOT-OBJECT-POINTER-LOCATION+, where the structs' accessors read it
;;; (checked when a class is finalized).
;;; STANDARD-OBJECT is added to the superclasses, as the CPL otherwise ends
;;; with STRUCTURE-OBJECT, and redefining a class needs the methods on
;;; STANDARD-OBJECT that update its instances.
;;;
;;; ECL keeps the fast slot access of STANDARD-CLASS (a table of the slots'
;;; locations, and optimized accessor methods) for that metaclass alone, and
;;; reads slots of other metaclasses through SLOT-VALUE-USING-CLASS, about ten
;;; times as slow (measured: an accessor 426 ns against 29 ns). GODOT-CLASS
;;; defines no SLOT-VALUE-USING-CLASS methods, so it can have the same fast
;;; access, which FINALIZE-INHERITANCE, READER-METHOD-CLASS and
;;; WRITER-METHOD-CLASS below give it.
;;;
;;; This file has the metaclass, its slot options and the Lisp objects of its
;;; instances; godot-functions.lisp the generic functions that Godot calls; and
;;; godot-registration.lisp registering the classes with Godot, also when
;;; they're redefined.
;;;

(defclass godot-class (standard-class)
  ((godot-name :initform nil :reader godot-name
               :documentation "The name of the class in Godot, a string.")
   (signals :initform '() :reader class-signals
            :documentation "The signals, a list of (name (argument-name type)...), with the
names as strings, as BIND-SIGNAL takes them.")
   (tool :initform nil :reader class-tool-p
         :documentation "True if the class runs in the editor, see REGISTER-CLASS.")
   (direct-functions :initform '() :reader class-direct-functions
                     :documentation "The functions Godot calls directly for virtual methods of the
class, from the :DIRECT-FUNCTIONS option: an alist of (virtual-function-name .
function-name).")
   (onready-slots :initform '() :reader class-onready-slots
                  :documentation "The slots with :ONREADY, a list of (slot-name . onready),
found when the class is finalized.")
   (constructor :initform nil
                :documentation "The constructor of MAKE-LISP-OBJECT and the
*INITIALIZATION-CHANGES* it was made for, as a cons, or NIL.")
   ;; What's registered with Godot, see godot-registration.lisp
   (registered-p :initform nil :accessor class-registered-p)
   (godot-parent-name :initform nil :accessor class-godot-parent-name)
   (registered-properties :initform '() :accessor class-registered-properties)
   (registered-signals :initform '() :accessor class-registered-signals)
   (registered-methods :initform '() :accessor class-registered-methods)
   (bound-virtuals :initform '() :accessor class-bound-virtuals)
   (registered-notifications :initform '() :accessor class-registered-notifications)
   ;; The exported slots of RefCounted classes that keep references, whose
   ;; references are given back when Godot frees an instance, and those of the
   ;; classes it inherits from too, with the *REFERENCE-SLOT-CHANGES* they were
   ;; found for, as a cons
   (reference-slots :initform '() :accessor class-reference-slots)
   (all-reference-slots :initform nil))
  (:documentation "The metaclass of classes that are Godot extension classes,
see godot-class.lisp. Class options:
  (:godot-name name), the name in Godot, by default the class name in Godot
    style (test-node becomes \"TestNode\")
  (:signals (name (argument-name type)...)...), the signals, like signal in
    GDScript, with names as symbols in Lisp style or strings, and types as in
    VARIANT-TYPE
  (:tool t), see REGISTER-CLASS
  (:direct-functions (virtual-function function)...), for dropping down: Godot
    calls FUNCTION, a plain function, by name, for the VIRTUAL-FUNCTION (such
    as PHYSICS-PROCESS) of the class's instances, instead of the generic
    function, so without generic dispatch, as fast as DEFINE-CLASS. The class's
    methods for the virtual function aren't called from Godot then. Subclasses
    inherit it, unless they give their own. Not for READY, which sets the
    :ONREADY slots first.
Slot options:
  :export type, a property, like @export var in GDScript, see DEFINE-CLASS
  :class class-name, of an :OBJECT property, see BIND-PROPERTY
  :onready path-or-function, set when the instance is ready, see DEFINE-CLASS"))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun godot-class-name (name)
    "The default name in Godot of the class NAME, a symbol: test-node becomes
\"TestNode\"."
    (remove #\- (string-capitalize (symbol-name name))))

  (defun godot-style-name (designator)
    "The name in Godot of DESIGNATOR, a string, or a symbol in Lisp style:
mob-scene becomes \"mob_scene\"."
    (if (stringp designator)
        designator
        (godot-property-name designator))))

(defun parse-signal (signal)
  "SIGNAL, from the :SIGNALS option, as a list of the name and the arguments,
as BIND-SIGNAL takes them."
  (destructuring-bind (name &rest arguments) signal
    (cons (godot-style-name name)
          (loop for (argument-name type) in arguments
                ;; Signals an error for a type that doesn't exist
                do (variant-type type)
                collect (list (godot-style-name argument-name) type)))))

;;;
;;; Superclasses and class options
;;;

(defmethod clos:validate-superclass ((class godot-class) (superclass standard-class))
  t)

(defmethod clos:validate-superclass ((class godot-class) (superclass structure-class))
  ;; The structs of engine classes
  (subtypep superclass (find-class 'godot-object)))

(defun with-standard-object (initargs)
  "INITARGS of a GODOT-CLASS, with STANDARD-OBJECT added last to its direct
superclasses, if they're given and it isn't there."
  (destructuring-bind (&key (direct-superclasses nil direct-superclasses-p) &allow-other-keys)
      initargs
    (if (and direct-superclasses-p
             (not (member (find-class 'standard-object) direct-superclasses)))
        (list* :direct-superclasses (append direct-superclasses
                                            (list (find-class 'standard-object)))
               initargs)
        initargs)))

;; ECL's REINITIALIZE-INSTANCE of a class sets its direct superclasses itself,
;; not through SHARED-INITIALIZE, so they're added to in both
(defmethod initialize-instance :around ((class godot-class) &rest initargs)
  (apply #'call-next-method class (with-standard-object initargs)))

(defmethod reinitialize-instance :around ((class godot-class) &rest initargs)
  (apply #'call-next-method class (with-standard-object initargs)))

(defun parse-direct-functions (direct-functions class-name)
  "DIRECT-FUNCTIONS, from the :DIRECT-FUNCTIONS option of the class CLASS-NAME, as
an alist of (virtual-function-name . function-name)."
  (loop for entry in direct-functions
        collect (destructuring-bind (virtual-function function) entry
                  (unless (and (symbolp virtual-function) (symbolp function))
                    (error "A direct function of ~s is (virtual-function function), with both ~
                            named by symbols: ~s" class-name entry))
                  (when (eq virtual-function 'ready)
                    (error "READY can't have a direct function in ~s: it sets the :ONREADY ~
                            slots first" class-name))
                  (cons virtual-function function))))

(defmethod shared-initialize :after ((class godot-class) slot-names
                                     &key (godot-name nil godot-name-p) (signals nil signals-p)
                                       (tool nil tool-p) (direct-functions nil direct-functions-p)
                                       (direct-slots nil direct-slots-p)
                                     &allow-other-keys)
  (declare (ignore slot-names direct-slots))
  ;; DEFCLASS gives an option as the list of what follows its name, e.g.
  ;; (:godot-name "Player") as :GODOT-NAME ("Player"). An option left out when
  ;; the class is redefined (DEFCLASS gives :DIRECT-SLOTS) gets its default.
  (when (or godot-name-p direct-slots-p)
    (setf (slot-value class 'godot-name)
          (or (first godot-name) (godot-class-name (class-name class)))))
  (when (or signals-p direct-slots-p)
    (setf (slot-value class 'signals) (mapcar #'parse-signal signals)))
  (when (or tool-p direct-slots-p)
    (setf (slot-value class 'tool) (first tool)))
  (when (or direct-functions-p direct-slots-p)
    (setf (slot-value class 'direct-functions)
          (parse-direct-functions direct-functions (class-name class)))))

;;;
;;; Slot options
;;;

(defclass godot-slot-definition ()
  ((export :initarg :export :initform nil :reader slot-definition-export)
   (property-class :initarg :class :initform nil :reader slot-definition-property-class)
   (onready :initarg :onready :initform nil :reader slot-definition-onready))
  (:documentation "The slot options of GODOT-CLASS."))

(defclass godot-direct-slot-definition (godot-slot-definition
                                        clos:standard-direct-slot-definition)
  ())

(defclass godot-effective-slot-definition (godot-slot-definition
                                           clos:standard-effective-slot-definition)
  ())

(defmethod initialize-instance :after ((slot godot-direct-slot-definition) &key)
  (let ((export (slot-definition-export slot)))
    ;; Signals an error for a type that doesn't exist
    (when export
      (variant-type export))
    (when (and (slot-definition-property-class slot) (not export))
      (error "The slot ~s has :CLASS, but no :EXPORT" (clos:slot-definition-name slot)))))

(defmethod clos:direct-slot-definition-class ((class godot-class) &rest initargs)
  (declare (ignore initargs))
  (find-class 'godot-direct-slot-definition))

(defmethod clos:effective-slot-definition-class ((class godot-class) &rest initargs)
  (declare (ignore initargs))
  (find-class 'godot-effective-slot-definition))

(defmethod clos:compute-effective-slot-definition ((class godot-class) name direct-slots)
  (declare (ignore name))
  (let ((slot (call-next-method))
        ;; The most specific one has the options
        (direct (find-if (lambda (direct) (typep direct 'godot-direct-slot-definition))
                         direct-slots)))
    (when direct
      (setf (slot-value slot 'export) (slot-definition-export direct)
            (slot-value slot 'property-class) (slot-definition-property-class direct)
            (slot-value slot 'onready) (slot-definition-onready direct)))
    slot))

;;;
;;; Fast slot access, and what's found when the class is finalized
;;;

(defmethod clos:reader-method-class ((class godot-class) direct-slot &rest initargs)
  (declare (ignore direct-slot initargs))
  (find-class 'clos::standard-optimized-reader-method))

(defmethod clos:writer-method-class ((class godot-class) direct-slot &rest initargs)
  (declare (ignore direct-slot initargs))
  (find-class 'clos::standard-optimized-writer-method))

(defmethod clos:finalize-inheritance :after ((class godot-class))
  (let ((slots (clos:class-slots class)))
    ;; The table of the slots' locations, which ECL makes only for
    ;; STANDARD-CLASS, and SLOT-VALUE and the optimized accessors use
    (let ((table (make-hash-table :size (max 32 (* 2 (length slots))))))
      (dolist (slot slots)
        (setf (gethash (clos:slot-definition-name slot) table)
              (clos:slot-definition-location slot)))
      (setf (clos::class-location-table class) table))
    ;; The accessors of the structs, such as GODOT-OBJECT-POINTER, read the
    ;; location the slot has in the struct. ECL puts the slots of mixins that
    ;; come after the struct in the superclasses before it.
    (let ((pointer (find +godot-object-pointer-slot+ slots :key #'clos:slot-definition-name)))
      (unless (and pointer (eql (clos:slot-definition-location pointer)
                                +godot-object-pointer-location+))
        (error "The mixins of ~s must come before the class it inherits from in Godot, in ~
                its superclasses" (class-name class))))
    (setf (slot-value class 'constructor) nil)
    (setf (slot-value class 'onready-slots)
          (loop for slot in slots
                for onready = (and (typep slot 'godot-effective-slot-definition)
                                   (slot-definition-onready slot))
                when onready
                  collect (cons (clos:slot-definition-name slot) onready)))))

;;;
;;; Instances
;;;
;;; The Lisp object of an instance is made when Godot creates it, by a
;;; constructor made for the class. MAKE-INSTANCE's ALLOCATE-INSTANCE and
;;; INITIALIZE-INSTANCE take about 2.5 us in ECL, more than the rest of making
;;; a Godot object, so if only the standard methods of INITIALIZE-INSTANCE and
;;; SHARED-INITIALIZE apply to the class's instances, the constructor allocates
;;; the instance and calls the slots' initforms itself, as they would. Adding or
;;; removing a method of either (a dependent of them, in the MOP) makes the
;;; constructors be made again, as does finalizing the class again.
;;;

(defvar *initialization-changes* 0
  "The number of times methods of INITIALIZE-INSTANCE or SHARED-INITIALIZE have
been added or removed since the constructors were made.")

(defclass initialization-dependent () ()
  (:documentation "A dependent of INITIALIZE-INSTANCE and SHARED-INITIALIZE that
counts their changes in *INITIALIZATION-CHANGES*."))

(defmethod clos:update-dependent ((function generic-function)
                                  (dependent initialization-dependent) &rest initargs)
  (declare (ignore initargs))
  (incf *initialization-changes*))

(let ((dependent (make-instance 'initialization-dependent)))
  (clos:add-dependent #'initialize-instance dependent)
  (clos:add-dependent #'shared-initialize dependent))

(defun standard-initialization-p (class)
  "True if only the standard methods of INITIALIZE-INSTANCE and SHARED-INITIALIZE
apply to the instances of CLASS."
  (let ((prototype (clos:class-prototype class))
        (standard-classes (list (find-class t)
                                (find-class 'standard-object)
                                (find-class 'structure-object))))
    (flet ((standard-p (methods)
             (every (lambda (method)
                      (subsetp (clos:method-specializers method) standard-classes))
                    methods)))
      (and (standard-p (compute-applicable-methods #'initialize-instance (list prototype)))
           (standard-p (compute-applicable-methods #'shared-initialize (list prototype t)))))))

(defun make-constructor (class)
  "A function of the Godot object pointer that makes the Lisp object of a new
instance of CLASS."
  (if (standard-initialization-p class)
      (let ((size (clos::class-size class))
            ;; (location . initfunction) of the slots with initforms, except
            ;; the pointer's
            (initializers (loop for slot in (clos:class-slots class)
                                for location = (clos:slot-definition-location slot)
                                for initfunction = (clos:slot-definition-initfunction slot)
                                when (and initfunction (typep location 'fixnum)
                                          (/= location +godot-object-pointer-location+))
                                  collect (cons location initfunction))))
        (lambda (pointer)
          (let ((object (si:allocate-raw-instance nil class size)))
            ;; So redefining the class updates it
            (si::instance-sig-set object)
            (setf (clos:standard-instance-access object +godot-object-pointer-location+)
                  pointer)
            (loop for (location . initfunction) in initializers
                  do (setf (clos:standard-instance-access object location)
                           (funcall initfunction)))
            object)))
      (lambda (pointer)
        (let ((object (allocate-instance class)))
          (setf (godot-object-pointer object) pointer)
          (initialize-instance object)
          object))))

(defun make-lisp-object (class pointer)
  "The Lisp object of a new instance of CLASS, whose Godot object is POINTER, for
REGISTER-CLASS."
  (let ((constructor (slot-value class 'constructor)))
    (unless (and constructor (= (car constructor) *initialization-changes*))
      (setf constructor (cons *initialization-changes* (make-constructor class))
            (slot-value class 'constructor) constructor))
    (funcall (cdr constructor) pointer)))

(defmethod make-instance ((class godot-class) &rest initargs)
  "Make a Godot object of CLASS, which must be registered with Godot, and return
its Lisp object, with its slots set from INITARGS, like CLASS.new() in
GDScript. Not for RefCounted classes yet."
  (unless (class-registered-p class)
    (error "~s isn't registered with Godot yet" (class-name class)))
  (when (subtypep class 'godot:ref-counted)
    (error "MAKE-INSTANCE doesn't make RefCounted objects yet: ~s" (class-name class)))
  (let ((object (gdext:make-object (godot-name class))))
    (when initargs
      (apply #'shared-initialize object '() initargs))
    object))
