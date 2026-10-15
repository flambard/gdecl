(in-package #:gdecl-test)

;;; The tests written in Lisp: calls from Lisp into Godot. LispTests runs them
;;; with *ROOT*, a node in the scene tree.

(defun same-object-p (a b)
  "True if A and B are the same Godot object, as pointers or Lisp objects."
  (= (ffi:pointer-address (gdext:object-pointer a))
     (ffi:pointer-address (gdext:object-pointer b))))

(defun new-node (class-name)
  "A new node of the class CLASS-NAME, added to *ROOT*."
  (let ((node (class-db-instantiate class-name)))
    (node-add-child *root* node)
    node))

(defun new-test-node ()
  "A new TestNode, with the child its :onready slot needs, added to *ROOT*."
  (let ((node (class-db-instantiate "TestNode"))
        (child (class-db-instantiate "Node")))
    (node-set-name child "Child")
    (node-add-child node child)
    (node-add-child *root* node)
    node))

(deftest engine-method-values
  (let ((node (new-node "Node2D")))
    (node-2d-set-position node (vector2 3.0 4.0))
    (check (equalp (vector2 3.0 4.0) (node-2d-get-position node)))
    (node-2d-set-rotation node 0.5)
    (check (< (abs (- (node-2d-get-rotation node) 0.5)) 1d-6))
    (check (canvas-item-is-visible node))
    (canvas-item-hide node)
    (check (not (canvas-item-is-visible node)))))

(deftest engine-method-rect2
  ;; A builtin type with nested builtin types, as an argument and a result
  (let ((sprite (new-node "Sprite2D"))
        (rect (rect2 (vector2 1.0 2.0) (vector2 3.0 4.0))))
    (sprite-2d-set-region-rect sprite rect)
    (check (equalp rect (sprite-2d-get-region-rect sprite)))))

(deftest engine-method-values-3d
  (let ((node (new-node "Node3D")))
    (node-3d-set-position node (vector3 1.0 2.0 3.0))
    (check (equalp (vector3 1.0 2.0 3.0) (node-3d-get-position node)))
    (let ((basis (basis (vector3 0.0 0.0 -1.0) (vector3 0.0 1.0 0.0) (vector3 1.0 0.0 0.0))))
      (node-3d-set-basis node basis)
      (check (equalp basis (node-3d-get-basis node))))
    ;; The default of up, Vector3(0, 1, 0)
    (node-3d-look-at node (vector3+ (vector3 1.0 2.0 3.0) (vector3 2.0 -1.0 0.5)))
    (let ((expected (basis-looking-at (vector3 2.0 -1.0 0.5)))
          (actual (node-3d-get-basis node)))
      (flet ((close-p (a b)
               (< (vector3-length (vector3- a b)) 1e-5)))
        (check (close-p (basis-x expected) (basis-x actual)))
        (check (close-p (basis-y expected) (basis-y actual)))
        (check (close-p (basis-z expected) (basis-z actual)))))))

(deftest vector3-functions
  (check (equalp (vector3 -3.0 6.0 -3.0) (vector3-cross (vector3 1.0 2.0 3.0) (vector3 4.0 5.0 6.0))))
  (check (= 32 (vector3-dot (vector3 1.0 2.0 3.0) (vector3 4.0 5.0 6.0))))
  (check (equalp (vector3 0.0 0.6 0.8) (vector3-normalized (vector3 0.0 3.0 4.0))))
  (check (equalp (vector3) (vector3-normalized (vector3))))
  (check (equalp (vector3 -1.0 -2.0 -3.0) (vector3- (vector3 1.0 2.0 3.0))))
  ;; A quarter turn around Y, as Vector3(0, 0, -1).rotated(Vector3.UP, PI / 2)
  (check (< (vector3-length (vector3- (vector3 -1.0 0.0 0.0)
                                      (vector3-rotated (vector3 0.0 0.0 -1.0)
                                                       (vector3 0.0 1.0 0.0)
                                                       (/ pi 2))))
            1e-6)))

;; Godot's real_t is single-float, but Lisp code computes with doubles (delta
;; is one) and integers, so the constructors take any real
(deftest builtin-constructors
  (check (equalp (vector2 1.0 2.0) (vector2 1d0 2)))
  (check (typep (vector2-x (vector2 (* 2 0.5d0))) 'single-float))
  (check (equalp (vector3 1.0 2.0 3.0) (vector3 1d0 2 3.0)))
  (check (typep (vector3-z (vector3 0 0 1d0)) 'single-float))
  (check (equalp (vector2 0.0 0.0) (vector2)))
  (check (equalp (vector3 0.0 0.0 0.0) (vector3))))

(deftest objects
  (let ((node (new-node "Node2D"))
        (test-node (new-test-node)))
    (check (same-object-p *root* (node-get-parent node)))
    ;; Instances of extension classes come back as their Lisp objects
    (check (test-node-p test-node))
    (check (eq test-node (node-get-child *root* (node-get-index test-node))))
    ;; NIL is null
    (check (null (node-get-node-or-null *root* "Missing")))))

(deftest object-identity
  ;; Every Godot object has one Lisp object, also an engine object: the same
  ;; object comes back as the same (EQ) Lisp object
  (let ((node (new-node "Node")))
    (check (eq *root* (node-get-parent node)))
    (check (eq (node-get-parent node) (node-get-parent node)))
    (check (gdext:godot-object-p (node-get-parent node)))))

(deftest typed-objects
  ;; A Godot object's Lisp object has the Lisp type of its class, which
  ;; mirrors Godot's inheritance, or of the nearest class it inherits from
  ;; that's defined in Lisp (see DEFINE-ENGINE-CLASS)
  (let ((node (new-node "Node2D")))
    (check (typep node 'node-2d))
    (check (typep node 'canvas-item))
    (check (typep node 'node))
    (check (not (typep node 'node-3d))))
  ;; Button isn't defined in Lisp: its nearest class that is is CanvasItem
  (let ((button (new-node "Button")))
    (check (typep button 'canvas-item))
    (check (not (typep button 'node-2d))))
  (check (typep *root* 'node))
  (check (typep (gdext:singleton "Input") 'input))
  ;; An instance of a class defined with DEFINE-CLASS has the type of the
  ;; class it inherits from too
  (check (typep (new-test-node) 'node-2d)))

(defgeneric object-kind (object)
  (:documentation "For TYPED-OBJECTS: generic functions dispatch on the Lisp
types of Godot objects.")
  (:method ((object node-2d)) :node-2d)
  (:method ((object node)) :node)
  (:method ((object ref-counted)) :ref-counted)
  (:method ((object t)) :other))

(deftest dispatch-on-objects
  (check (eq :node-2d (object-kind (new-node "Node2D"))))
  (check (eq :node (object-kind (new-node "Timer"))))
  (check (eq :node-2d (object-kind (new-test-node))))
  (gdext:with-reference (object (class-db-instantiate "RefCounted"))
    (check (eq :ref-counted (object-kind object))))
  (check (eq :other (object-kind 42))))

(deftest freed-objects
  ;; The Lisp object of a freed Godot object is no longer valid: using it
  ;; signals an error instead of passing Godot a dangling pointer
  (let ((node (class-db-instantiate "Node")))
    (check (gdext:valid-object-p node))
    (gdext-ffi:object-destroy (gdext:object-pointer node))
    (check (not (gdext:valid-object-p node)))
    ;; The error is about the freed object, not anything else
    (check (search "freed"
                   (handler-case (progn (node-get-child-count node) "no error")
                     (error (e) (princ-to-string e)))))))

(deftest raw-pointers-in-variants
  ;; Only Lisp objects of Godot objects become Object Variants, not raw
  ;; pointers, which might point to something else, such as a StringName
  (check (gd-extension-types:variant-value-p *root*))
  (check (not (gd-extension-types:variant-value-p (gdext:sname "pinged"))))
  ;; So passing one where a Variant is made from it is an error, before Godot
  ;; gets it
  (check (eq :error (handler-case (object-emit-signal *root* "ready" (gdext:sname "x"))
                      (error () :error)))))

(deftest strings-for-names
  (let ((node (new-node "Node")))
    (node-set-name node "Named")
    ;; A literal NodePath, and one made at runtime
    (check (same-object-p node (node-get-node *root* "Named")))
    (check (same-object-p node (node-get-node *root* (concatenate 'string "Na" "med"))))
    ;; A StringName made at runtime from a string with a non-ASCII character,
    ;; and the same as a literal (read with #. so it doesn't depend on the
    ;; encoding the file is read with), which becomes an SNAME
    (node-add-to-group node (format nil "g~c" (code-char 228)))
    (check (node-is-in-group node (format nil "g~c" (code-char 228))))
    ;; Inside another call, so CHECK doesn't make the literal string a value
    (check (eq t (node-is-in-group node #.(format nil "g~c" (code-char 228)))))
    ;; The same with a character outside Latin-1 (the euro sign)
    (node-add-to-group node (format nil "g~c" (code-char 8364)))
    (check (eq t (node-is-in-group node #.(format nil "g~c" (code-char 8364)))))))

(deftest variant-values
  (let ((node (new-node "Node")))
    (flet ((round-trip (value)
             (object-set-meta node "value" value)
             (object-get-meta node "value" nil)))
      (check (eql 7 (round-trip 7)))
      (check (eql 2.5d0 (round-trip 2.5d0)))
      (check (equal "text" (round-trip "text")))
      (check (eq t (round-trip t)))
      (check (eq nil (round-trip nil)))
      (check (equalp (vector2 1.0 2.0) (round-trip (vector2 1.0 2.0))))
      (check (equalp (rect2 (vector2 1.0 2.0) (vector2 3.0 4.0))
                     (round-trip (rect2 (vector2 1.0 2.0) (vector2 3.0 4.0)))))
      (check (equalp (vector3 1.0 2.0 3.0) (round-trip (vector3 1.0 2.0 3.0))))
      (let ((basis (basis (vector3 1.0 2.0 3.0) (vector3 4.0 5.0 6.0) (vector3 7.0 8.0 9.0))))
        (check (equalp basis (round-trip basis))))
      (check (same-object-p *root* (round-trip *root*))))))

(deftest more-builtin-types
  ;; Through Variants
  (let ((node (new-node "Node")))
    (flet ((round-trip (value)
             (object-set-meta node "value" value)
             (object-get-meta node "value" nil)))
      (dolist (value (list (color 0.25 0.5 0.75 1.0)
                           (vector2i 1 -2)
                           (vector3i 1 -2 3)
                           (vector4 1.0 2.0 3.0 4.0)
                           (vector4i 1 2 3 4)
                           (rect2i (vector2i 1 2) (vector2i 3 4))
                           (plane (vector3 0.0 1.0 0.0) 2.0)
                           (quaternion 0.0 0.0 0.0 1.0)
                           (aabb (vector3 1.0 2.0 3.0) (vector3 4.0 5.0 6.0))
                           (transform2d (vector2 1.0 2.0) (vector2 3.0 4.0) (vector2 5.0 6.0))
                           (transform3d (basis (vector3 1.0 2.0 3.0) (vector3 4.0 5.0 6.0)
                                               (vector3 7.0 8.0 9.0))
                                        (vector3 10.0 11.0 12.0))
                           (projection (vector4 1.0 2.0 3.0 4.0) (vector4 5.0 6.0 7.0 8.0)
                                       (vector4 9.0 10.0 11.0 12.0) (vector4 13.0 14.0 15.0 16.0))))
        (check (equalp value (round-trip value))))))
  ;; Through engine methods
  (let ((node (new-node "Node2D"))
        (color (color 0.25 0.5 0.75 1.0))
        (transform (transform2d (vector2 2.0 0.0) (vector2 0.0 3.0) (vector2 4.0 5.0))))
    (canvas-item-set-modulate node color)
    (check (equalp color (canvas-item-get-modulate node)))
    (node-2d-set-transform node transform)
    (check (equalp transform (canvas-item-get-transform node)))
    (check (/= 0 (rid-id (canvas-item-get-canvas-item node)))))
  (let ((node (new-node "Node3D"))
        (transform (transform3d (basis (vector3 2.0 0.0 0.0) (vector3 0.0 3.0 0.0)
                                       (vector3 0.0 0.0 4.0))
                                (vector3 1.0 2.0 3.0))))
    (node-3d-set-transform node transform)
    (check (equalp transform (node-3d-get-transform node))))
  (let ((sprite (new-node "Sprite2D")))
    (sprite-2d-set-hframes sprite 4)
    (sprite-2d-set-vframes sprite 4)
    (sprite-2d-set-frame-coords sprite (vector2i 1 2))
    (check (equalp (vector2i 1 2) (sprite-2d-get-frame-coords sprite)))))

(deftest name-results
  ;; StringName and NodePath results are Lisp strings
  (let ((node (new-node "Node")))
    (node-set-name node "NameResults")
    (check (equal "NameResults" (node-get-name node)))
    (let ((path (node-get-path node)))
      (check (eql (- (length path) (length "/NameResults")) (search "/NameResults" path))))))

(deftest packed-arrays
  ;; Packed arrays of numbers are specialized Lisp vectors
  (let ((node (new-node "Node")))
    (flet ((round-trip (value)
             (object-set-meta node "value" value)
             (object-get-meta node "value" nil)))
      (dolist (value (list (make-array 3 :element-type '(unsigned-byte 8)
                                         :initial-contents '(1 2 255))
                           (make-array 2 :element-type '(signed-byte 32)
                                         :initial-contents '(-1 7))
                           (make-array 2 :element-type '(signed-byte 64)
                                         :initial-contents (list (expt 2 40) -3))
                           (make-array 2 :element-type 'single-float
                                         :initial-contents '(1.5 -2.0))
                           (make-array 2 :element-type 'double-float
                                         :initial-contents '(1.5d0 -2d0))
                           (make-array 0 :element-type 'single-float)))
        (let ((result (round-trip value)))
          (check (equalp value result))
          (check (equal (array-element-type value) (array-element-type result))))))))

(deftest packed-arrays-of-builtin-types
  ;; Packed arrays of other types are simple vectors
  (let ((line (new-node "Line2D"))
        (points (vector (vector2 1.0 2.0) (vector2 3.0 4.0))))
    (line-2d-set-points line points)
    (check (equalp points (line-2d-get-points line)))
    ;; Any sequence will do as an argument
    (line-2d-set-points line (list (vector2 5.0 6.0)))
    (check (equalp (vector (vector2 5.0 6.0)) (line-2d-get-points line))))
  (let ((classes (class-db-get-class-list)))
    (check (simple-vector-p classes))
    (check (find "Node2D" classes :test #'equal))))

(deftest arrays-and-dictionaries
  ;; An Array is a simple vector, a Dictionary a hash table
  (let ((node (new-node "Node")))
    (flet ((round-trip (value)
             (object-set-meta node "value" value)
             (object-get-meta node "value" nil)))
      (let ((vector (vector 1 "two" (vector2 3.0 4.0) (vector 5))))
        (check (equalp vector (round-trip vector))))
      (let ((table (make-hash-table :test #'equal)))
        (setf (gethash "one" table) 1
              (gethash 2 table) "two")
        (let ((result (round-trip table)))
          (check (hash-table-p result))
          (check (= 2 (hash-table-count result)))
          (check (eql 1 (gethash "one" result)))
          (check (equal "two" (gethash 2 result)))))))
  ;; A typed array result
  (let ((parent (new-node "Node"))
        (a (class-db-instantiate "Node"))
        (b (class-db-instantiate "Node")))
    (node-add-child parent a)
    (node-add-child parent b)
    (check (equalp (vector a b) (node-get-children parent))))
  ;; A Dictionary result
  (check (eql 4 (gethash "major" (engine-get-version-info)))))

(deftest vararg-methods
  (let ((node (new-node "Node2D"))
        (test-node (new-test-node))
        (heard nil))
    ;; Further arguments, and a Variant result
    (object-call node "set_position" (vector2 5.0 6.0))
    (check (equalp (vector2 5.0 6.0) (object-call node "get_position")))
    ;; A signal with arguments
    (gdext:connect-signal test-node "pinged" (lambda (&rest arguments) (setf heard arguments)))
    (object-emit-signal test-node "pinged" 1 "one" (vector2 1.0 1.0) node nil)
    (check (= 5 (length heard)))
    (check (equal '(1 "one") (subseq heard 0 2)))
    (check (same-object-p node (fourth heard)))))

(deftest static-and-singleton-methods
  (check (plusp (length (resource-generate-scene-unique-id))))
  (check (class-db-class-exists "Node2D"))
  (check (not (class-db-class-exists "NoSuchClass")))
  (check (not (input-is-action-pressed "ui_accept"))))

(deftest utility-functions
  (check (equal "1a(1.0, 2.0)" (str 1 "a" (vector2 1.0 2.0))))
  (check (= 1 (clampf 5.0 0.0 1.0)))
  (check (= 5 (lerpf 0 10 0.5)))
  (check (<= 1 (randi-range 1 3) 3))
  (check (is-instance-valid *root*))
  (check (not (is-instance-valid nil))))

(deftest enums-and-constants
  (check (= 0 +ok+))
  (check (= 4 +object-connect-one-shot+))
  (check (= 13 +node-notification-ready+))
  (let ((node (new-test-node)))
    (check (= +ok+ (gdext:connect-signal node "pinged" (lambda (&rest arguments) arguments))))))

(deftest after-signal
  (let ((node (new-test-node))
        (runs 0))
    (gdext:after-signal (node "pinged" :target node)
      (incf runs))
    (object-emit-signal node "pinged" 1 "a" (vector2) nil nil)
    (check (= 1 runs))
    ;; Only once
    (object-emit-signal node "pinged" 1 "a" (vector2) nil nil)
    (check (= 1 runs))))

(deftest references
  (let ((tree (node-get-tree *root*)))
    ;; The SceneTree keeps a reference to its timers too
    (gdext:with-reference (timer (scene-tree-create-timer tree 10.0))
      (check (= 2 (ref-counted-get-reference-count timer)))
      (let ((kept nil))
        (gdext:setf-reference kept timer)
        (check (= 3 (ref-counted-get-reference-count timer)))
        (gdext:setf-reference kept nil)
        (check (null kept))
        (check (= 2 (ref-counted-get-reference-count timer)))))))

(deftest refcounted-variant-results
  ;; A RefCounted object as a Variant result comes with a reference, in the
  ;; autorelease pool, like a Ref<T> result, also from a vararg method and a
  ;; utility function
  (let ((id nil))
    (gdext:with-reference (object (class-db-instantiate "RefCounted"))
      (setf id (object-get-instance-id object))
      (check (= 1 (ref-counted-get-reference-count object)))
      (gdext:with-reference (same (type-convert object +type-object+))
        (check (same-object-p same object))
        (check (= 2 (ref-counted-get-reference-count object))))
      (check (= 1 (ref-counted-get-reference-count object))))
    ;; WITH-REFERENCE gives the reference back from the pool, before the call
    ;; returns
    (check (null (instance-from-id id))))
  (gdext:with-reference (object (object-call (gdext:singleton "ClassDB") "instantiate" "RefCounted"))
    (check (= 1 (ref-counted-get-reference-count object))))
  ;; Another object as a Variant result
  (let ((node (new-node "Node")))
    (check (same-object-p node (object-call *root* "get_child" (node-get-index node))))))

(deftest argument-conversion-errors
  ;; If an argument can't be converted, the raw values of those converted
  ;; before it are destroyed: here a Variant with a reference to a RefCounted
  ;; object, which would otherwise keep it alive
  (let ((id nil))
    (gdext:with-reference (object (class-db-instantiate "RefCounted"))
      (setf id (object-get-instance-id object))
      ;; The indent, a String, can't be made from 42
      (check (null (ignore-errors (json-stringify object 42)))))
    (check (null (instance-from-id id)))))

(deftest unsupported-api-types
  ;; DEFINE-ENGINE-CLASS skips the methods with types gdecl can't convert yet,
  ;; which signal UNSUPPORTED-API-TYPE, but not other errors, such as bugs in
  ;; the code generator
  (check (eq :unsupported
             (handler-case (gdext::engine-method-variant-type "Signal" "signal")
               (gdext::unsupported-api-type () :unsupported))))
  (check (eq :other
             (handler-case (gdext::engine-method-variant-type 42 "points")
               (gdext::unsupported-api-type () :unsupported)
               (error () :other)))))

(deftest autorelease-pool
  ;; RefCounted results stay alive until the call from Godot returns
  (let* ((tree (node-get-tree *root*))
         (timer (scene-tree-create-timer tree 10.0))
         (object (class-db-instantiate "RefCounted")))
    (check (= 2 (ref-counted-get-reference-count timer)))
    (check (= 1 (ref-counted-get-reference-count object)))))

(deftest callable-on-thread
  ;; Godot calls a Lisp Callable on a new thread, which Lisp hasn't seen before
  (let ((thread (class-db-instantiate "Thread"))
        (ran-in nil))
    (check (= +ok+ (thread-start thread (gd-extension-types:callable
                                         *root*
                                         (lambda ()
                                           (setf ran-in mp:*current-process*)
                                           42)))))
    (check (eql 42 (thread-wait-to-finish thread)))
    (check ran-in)
    (check (not (eq ran-in mp:*current-process*)))))

(deftest callables-on-worker-thread-pool
  ;; Several Callables at once, on the threads of WorkerThreadPool
  (let* ((lock (mp:make-lock :name "callables-on-worker-thread-pool"))
         (count 0)
         (tasks (loop repeat 8
                      collect (worker-thread-pool-add-task
                               (gd-extension-types:callable
                                *root*
                                (lambda ()
                                  (mp:with-lock (lock)
                                    (incf count))))))))
    (dolist (task tasks)
      (check (= +ok+ (worker-thread-pool-wait-for-task-completion task))))
    (check (= 8 count))))

(deftest singletons
  ;; A singleton the extension registers itself (define-class with :singleton)
  (let ((singleton (gdext:singleton "TestSingleton")))
    (check (typep singleton 'test-singleton))
    (check (eq singleton (engine-get-singleton "TestSingleton")))
    (let ((count (test-singleton-count singleton)))
      (object-call singleton "next")
      (check (eql (1+ count) (test-singleton-count singleton))))))
