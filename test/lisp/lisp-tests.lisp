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

(deftest freed-objects
  ;; The Lisp object of a freed Godot object is no longer valid: using it
  ;; signals an error instead of passing Godot a dangling pointer
  (let ((node (class-db-instantiate "Node")))
    (check (gdext:valid-object-p node))
    (gdext-ffi:object-destroy (gdext:object-pointer node))
    (check (not (gdext:valid-object-p node)))
    (check (eq :error (handler-case (node-get-name node)
                        (error () :error))))))

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
    (check (eq t (node-is-in-group node #.(format nil "g~c" (code-char 228)))))))

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
             (handler-case (gdext::engine-method-variant-type "PackedVector3Array" "points")
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
