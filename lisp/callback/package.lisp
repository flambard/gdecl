;;;; The package GD-EXTENSION-CALLBACK: what Godot calls into. It uses ffi/ and
;;;; types/.
;;;; See Layers in CLAUDE.md.

(defpackage #:gd-extension-callback
  (:documentation "What runs when Godot calls into Lisp: the callbacks, and the
tables and dispatchers behind them")
  (:nicknames #:gdext-callback)
  (:use #:cl #:gd-extension-ffi #:gd-extension-types)
  (:export ;; Callbacks
           #:callback-pointer
           #:method-ptrcall
           #:method-call
           #:create-instance
           #:free-instance
           #:get-virtual-call-data
           #:call-virtual-with-data
           ;; Initialization, called from src/gdecl.c
           #:initialize
           #:deinitialize
           #:add-initialize-hook
           #:add-deinitialize-hook
           #:*framework-initialize*
           #:*framework-deinitialize*
           #:free-bindings
           #:make-initialize-cell
           ;; Errors
           #:report-error
           #:*wrapper-function*
           ;; Tables
           #:register-method
           #:ptrcall-invoker-form
           #:add-extension-class
           #:add-virtual
           #:set-class-notifications
           #:notification-filter-pointer
           #:lisp-object))
