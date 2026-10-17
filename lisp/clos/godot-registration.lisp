(in-package :godot-clos)

;;;
;;; Registering GODOT-CLASSes with Godot
;;;
;;; Defining a GODOT-CLASS adds its registration to those of DEFINE-CLASS
;;; (ADD-CLASS-DEFINITION), so it's registered when Godot initializes the
;;; extension, in the order the classes were defined, or right away at a REPL.
;;; Registering a class registers it with REGISTER-CLASS, and then what it has
;;; that Godot needs to know about (UPDATE-GODOT-CLASS): its exported slots as
;;; properties, its signals, its methods for GODOT-METHODs, its virtual
;;; methods, and the notifications it gets. Each is registered on the first
;;; class that has it, as Godot's subclasses inherit them, except virtual
;;; methods, which Godot looks up in the class of the instance only, so each
;;; class binds those it implements, inherited ones too, and notifications,
;;; which Godot sends only to the class of the instance.
;;;
;;; The class is updated again when it's redefined, and all registered classes
;;; when a method is added to or removed from a GODOT-FUNCTION, so that what's
;;; new at a REPL reaches Godot. Only new things can be added: Godot can't
;;; unregister methods, properties or signals, or change the class's parent.
;;; And Godot asks for a virtual method once per class (TODO J), so one that a
;;; class implements only later isn't called. Notifications are filtered in
;;; Lisp, so those can also be removed.
;;;

(defvar *godot-classes* '()
  "The GODOT-CLASSes registered with Godot, in the order they were registered.")

(defun engine-class-name (struct-name)
  "The name of the engine class whose struct is STRUCT-NAME (see
DEFINE-ENGINE-CLASS), or NIL."
  (if (eq struct-name 'godot-object)
      "Object"
      (loop for class-name being the hash-keys of *engine-object-types*
              using (hash-value type)
            when (eq type struct-name)
              return class-name)))

(defun godot-ancestors (class)
  "The classes in Godot that CLASS inherits from, from its precedence list: the
GODOT-CLASSes, then the structs of engine classes, the nearest first."
  (remove-if-not (lambda (superclass)
                   (or (typep superclass 'godot-class)
                       (and (typep superclass 'structure-class)
                            (subtypep superclass (find-class 'godot-object)))))
                 (rest (clos:class-precedence-list class))))

(defun godot-parent-name (class)
  "The name of the class in Godot that CLASS inherits from. Signals an error if
CLASS inherits from classes in Godot that aren't one line of inheritance, which
Godot's single inheritance can't have."
  (let ((ancestors (godot-ancestors class)))
    (loop for (subclass superclass) on ancestors
          while superclass
          unless (subtypep subclass superclass)
            do (error "~s inherits from both ~s and ~s, which aren't one line of inheritance ~
                       in Godot" (class-name class) (class-name subclass) (class-name superclass)))
    (let ((parent (first ancestors)))
      (if (typep parent 'godot-class)
          (godot-name parent)
          (or (engine-class-name (class-name parent))
              (error "No engine class has the struct ~s" (class-name parent)))))))

(defun registered-on-ancestor-p (class reader name)
  "True if a GODOT-CLASS that CLASS inherits from has registered NAME, in the
list READER gives."
  (some (lambda (ancestor)
          (and (typep ancestor 'godot-class)
               (member name (funcall reader ancestor) :test #'equal)))
        (godot-ancestors class)))

(defvar *reference-slot-changes* 0
  "The number of exported slots that keep references registered so far.")

(defun all-reference-slots (class)
  "The exported slots of CLASS and the classes it inherits from that keep
references, found once for each change of *REFERENCE-SLOT-CHANGES*, as this is
called whenever Godot frees an instance."
  (let ((found (slot-value class 'all-reference-slots)))
    (if (and found (= (car found) *reference-slot-changes*))
        (cdr found)
        (cdr (setf (slot-value class 'all-reference-slots)
                   (cons *reference-slot-changes*
                         (loop for superclass in (clos:class-precedence-list class)
                               when (typep superclass 'godot-class)
                                 append (class-reference-slots superclass))))))))

(defun release-slot-references (object)
  "Give back the references the exported slots of OBJECT keep, when Godot frees
it."
  (dolist (slot-name (all-reference-slots (class-of object)))
    (when (slot-boundp object slot-name)
      (gdext:release-reference (slot-value object slot-name)))))

(defun register-godot-class (class)
  "Register CLASS with Godot, and what it has that Godot needs to know about."
  (unless (clos:class-finalized-p class)
    (clos:finalize-inheritance class))
  ;; Before anything is registered with Godot
  (check-direct-functions class)
  (let ((parent-name (godot-parent-name class)))
    (gdext:register-class (godot-name class) parent-name
                          :constructor (lambda (pointer) (make-lisp-object class pointer))
                          :destructor 'release-slot-references
                          ;; Set by UPDATE-NOTIFICATIONS
                          :notification 'call-notification
                          :notifications '()
                          :tool (class-tool-p class))
    (setf (class-registered-p class) t
          (class-godot-parent-name class) parent-name)
    (setf *godot-classes* (append *godot-classes* (list class)))
    (update-godot-class class)))

(defun register-properties (class)
  "Register the exported slots of CLASS as properties, as DEFINE-CLASS does."
  (dolist (slot (clos:class-slots class))
    (let ((slot-name (clos:slot-definition-name slot))
          (type (and (typep slot 'godot-effective-slot-definition)
                     (slot-definition-export slot))))
      (when type
        (let ((name (godot-style-name slot-name)))
          (unless (or (member name (class-registered-properties class) :test #'string=)
                      (registered-on-ancestor-p class #'class-registered-properties name))
            (let* ((property-class (slot-definition-property-class slot))
                   (ref-counted (and property-class
                                     (inherits-class-p property-class "RefCounted")))
                   (getter (format nil "get_~a" name))
                   (setter (format nil "set_~a" name)))
              (gdext:bind-method (godot-name class) getter
                                 (lambda (object) (slot-value object slot-name))
                                 :return-type type)
              (gdext:bind-method (godot-name class) setter
                                 (if ref-counted
                                     (lambda (object value)
                                       (unless (slot-boundp object slot-name)
                                         (setf (slot-value object slot-name) nil))
                                       (gdext:setf-reference (slot-value object slot-name) value))
                                     (lambda (object value)
                                       (setf (slot-value object slot-name) value)))
                                 :arguments `(("value" ,type)))
              (apply #'gdext:bind-property (godot-name class) name type getter setter
                     (and property-class `(:class ,property-class)))
              (when ref-counted
                (push slot-name (class-reference-slots class))
                (incf *reference-slot-changes*))
              (push name (class-registered-properties class)))))))))

(defun register-signals (class)
  "Register the signals of CLASS."
  (loop for (name . arguments) in (class-signals class)
        unless (or (member name (class-registered-signals class) :test #'string=)
                   (registered-on-ancestor-p class #'class-registered-signals name))
          do (gdext:bind-signal (godot-name class) name arguments)
             (push name (class-registered-signals class))))

(defun register-methods (class)
  "Register the GODOT-METHODs that CLASS has methods for."
  (dolist (function-name *godot-methods*)
    (let* ((function (fdefinition function-name))
           (name (godot-name function)))
      (when (and (class-methods function class)
                 (not (member name (class-registered-methods class) :test #'string=))
                 (not (registered-on-ancestor-p class #'class-registered-methods name)))
        (gdext:bind-method (godot-name class) name function-name
                           :return-type (method-return-type function)
                           :arguments (method-arguments function)
                           :invoker (method-invoker function))
        (push name (class-registered-methods class))))))

(defun check-direct-functions (class)
  "Signal an error if one of CLASS's own :DIRECT-FUNCTIONS isn't for a
VIRTUAL-FUNCTION of an engine class that CLASS inherits from, which would
otherwise be ignored."
  (loop for (function-name) in (class-direct-functions class)
        do (unless (member function-name *virtual-functions*)
             (error "~s, in the :DIRECT-FUNCTIONS of ~s, isn't a virtual function (see ~
                     DEFINE-VIRTUAL-FUNCTION)" function-name (class-name class)))
           (let ((engine-class (virtual-engine-class (fdefinition function-name))))
             (unless (inherits-class-p (godot-parent-name class) engine-class)
               (error "~s, in the :DIRECT-FUNCTIONS of ~s, is a virtual method of ~a, which ~
                       ~a doesn't inherit from" function-name (class-name class) engine-class
                       (godot-name class))))))

(defun class-direct-function (class function-name)
  "The function that Godot calls directly for the VIRTUAL-FUNCTION FUNCTION-NAME
of CLASS's instances, from the :DIRECT-FUNCTIONS of CLASS or the nearest
GODOT-CLASS it inherits from that has one for it, or NIL."
  (loop for ancestor in (cons class (godot-ancestors class))
        for entry = (and (typep ancestor 'godot-class)
                         (assoc function-name (class-direct-functions ancestor)))
        when entry
          return (cdr entry)))

(defun bind-virtuals (class)
  "Bind the VIRTUAL-FUNCTIONs that CLASS implements as its virtual methods: the
generic function, or its direct function (see CLASS-DIRECT-FUNCTION)."
  (dolist (function-name *virtual-functions*)
    (let* ((function (fdefinition function-name))
           (name (godot-name function))
           (direct (class-direct-function class function-name)))
      (when (and (not (member name (class-bound-virtuals class) :test #'string=))
                 (inherits-class-p (godot-name class) (virtual-engine-class function))
                 (or direct (funcall (virtual-implemented-p function) function class)))
        (funcall (virtual-binder function) (godot-name class)
                 (or direct (virtual-function-name function)))
        (push name (class-bound-virtuals class))))))

(defun update-notifications (class)
  "Make CLASS get the notifications it has methods of NOTIFICATION for."
  (let ((notifications (class-notifications class))
        (registered (class-registered-notifications class)))
    (unless (if (or (eq notifications t) (eq registered t))
                (eq notifications registered)
                (null (set-exclusive-or notifications registered)))
      (gdext:set-class-notifications (godot-name class) notifications)
      (setf (class-registered-notifications class) notifications))))

(defun update-godot-class (class)
  "Register with Godot what CLASS, a registered GODOT-CLASS, has that isn't
registered yet."
  (check-direct-functions class)
  (register-properties class)
  (register-signals class)
  (register-methods class)
  (bind-virtuals class)
  (update-notifications class))

(defmethod initialize-instance :after ((class godot-class) &key)
  (add-class-definition (godot-name class) (lambda () (register-godot-class class))))

(defmethod reinitialize-instance :after ((class godot-class) &key)
  (when (class-registered-p class)
    (handler-case
        (progn
          (unless (clos:class-finalized-p class)
            (clos:finalize-inheritance class))
          (unless (equal (godot-parent-name class) (class-godot-parent-name class))
            (error "Godot can't change the class that ~a inherits from (~a), until it's restarted"
                   (godot-name class) (class-godot-parent-name class)))
          (update-godot-class class))
      (error (e)
        (report-error (format nil "updating the class ~a" (godot-name class)) e)))))

(defun update-godot-classes ()
  "Update all registered GODOT-CLASSes, see UPDATE-GODOT-CLASS."
  (dolist (class *godot-classes*)
    (handler-case (update-godot-class class)
      (error (e)
        (report-error (format nil "updating the class ~a" (godot-name class)) e)))))

(defmethod add-method :after ((function godot-function) method)
  (declare (ignore method))
  (update-godot-classes))

(defmethod remove-method :after ((function godot-function) method)
  (declare (ignore method))
  (update-godot-classes))
