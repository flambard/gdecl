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

(deftest objects
  (let ((node (new-node "Node2D"))
        (test-node (new-test-node)))
    (check (same-object-p *root* (node-get-parent node)))
    ;; Instances of extension classes come back as their Lisp objects
    (check (test-node-p test-node))
    (check (eq test-node (node-get-child *root* (node-get-index test-node))))
    ;; NIL is null
    (check (null (node-get-node-or-null *root* "Missing")))))

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
