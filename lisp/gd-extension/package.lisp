;;;; The package GD-EXTENSION, the public, Lisp-style layer, and the code
;;;; generators for GODOT and GODOT-UTILITY. It uses all the layers below.
;;;; See Layers in CLAUDE.md.

(defpackage #:gd-extension
  (:documentation "Lisp-style framework for programming Godot")
  (:nicknames #:gdext)
  (:use #:cl #:gd-extension-ffi #:gd-extension-builtins #:gd-extension-types)
  (:import-from #:gdecl-json
                #:json-get)
  (:import-from #:gd-extension-callback
                #:callback-pointer
                #:method-ptrcall
                #:method-call
                #:create-instance
                #:free-instance
                #:get-virtual-call-data
                #:call-virtual-with-data
                #:add-initialize-hook
                #:add-deinitialize-hook
                #:*framework-initialize*
                #:*framework-deinitialize*
                #:free-bindings
                #:make-initialize-cell
                #:report-error
                #:*wrapper-function*
                #:pointer-lisp-object
                #:register-method
                #:ptrcall-invoker-form
                #:add-extension-class
                #:add-virtual
                #:set-class-notifications
                #:notification-filter-pointer
                #:instance-object
                #:lisp-object)
  ;; Internal, but imported by the layers above that define classes,
  ;; GODOT-DSL and GODOT-CLOS
  (:intern #:add-class-definition
           #:inherits-class-p
           #:engine-object-type
           #:virtual-signatures
           #:godot-property-name
           #:*engine-object-types*)
  (:export #:add-initialize-hook
           #:add-deinitialize-hook
           ;; Helpers
           #:variant-type
           #:with-string-name
           #:with-string
           #:get-method-bind
           ;; From GD-EXTENSION-FFI
           #:clear-foreign-object
           #:cast-pointer
           #:foreign-ref
           ;; From GD-EXTENSION-TYPES
           #:godot-object
           #:godot-object-p
           #:godot-object-pointer
           #:object-pointer
           #:valid-object-p
           ;; Making and freeing objects
           #:make-object
           #:free-object
           ;; Values looked up once
           #:sname
           #:npath
           #:singleton
           ;; Calling engine methods
           #:define-engine-method
           #:define-engine-class
           #:define-utility-functions
           #:define-global-enums
           ;; Signals
           #:connect-signal
           #:after-signal
           ;; References
           #:add-reference
           #:release-reference
           #:with-reference
           #:setf-reference
           ;; Classes
           #:register-class
           #:set-class-notifications
           #:register-singleton
           #:bind-virtual
           #:instance-object
           #:lisp-object
           ;; Binding
           #:bind-method
           #:bind-property
           #:bind-signal)
  ;; Everything GD-EXTENSION-BUILTINS exports, computed when this is read
  #.`(:export ,@(let ((names '()))
                  (do-external-symbols (symbol '#:gd-extension-builtins names)
                    (push (symbol-name symbol) names)))))
