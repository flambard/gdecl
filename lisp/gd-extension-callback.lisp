(in-package :gd-extension-callback)

;;;
;;; What runs when Godot calls into Lisp (C -> Lisp): the callbacks, and the
;;; tables and dispatchers behind them. Each callback is a C function made with
;;; DEFINE-CALLBACK, whose address (CALLBACK-POINTER 'NAME) the package
;;; GD-EXTENSION (registration.lisp) gives to Godot when it registers methods
;;; and classes.
;;;
;;; A Lisp error must never unwind through Godot's C frames, so every callback
;;; body is wrapped in WITH-CALLBACK-PROTECTION.
;;;
;;; This file has the machinery: DEFINE-CALLBACK, the threads, and errors. The
;;; rest of the package GD-EXTENSION-CALLBACK, in the order it's loaded:
;;; initialize.lisp (INITIALIZE and DEINITIALIZE, their hooks, and initialize
;;; cells), instance-bindings.lisp (the Lisp object of every Godot object, and
;;; the Object value type), extension-classes.lisp (classes, their instances
;;; and which virtual methods they implement), bound-methods.lisp (methods and
;;; virtual methods, and their invokers) and callables.lisp (custom Callables
;;; that call Lisp functions).
;;;

;;;
;;; Threads
;;;
;;; Godot calls into Lisp from any of its threads: Callables run by Thread and
;;; WorkerThreadPool, _process of nodes in a thread group, instances created by
;;; threaded resource loading, objects freed on another thread. ECL can only
;;; run Lisp in a thread it knows, and in any other aborts the whole process as
;;; soon as a callback starts, before WITH-CALLBACK-PROTECTION can do anything.
;;; So DEFINE-CALLBACK puts a C function in front of each callback, which
;;; imports the thread into ECL the first time it calls into Lisp
;;; (ecl_import_current_thread, about 0.1 ms) and only checks a thread-local
;;; flag after that. ECL must be told when an imported thread exits
;;; (ecl_release_current_thread): otherwise the GC keeps it among the threads it
;;; stops for a collection, waits for it, and aborts. Godot doesn't say when its
;;; threads exit, so a pthread key's destructor, which runs at exit in the
;;; threads that imported themselves, releases them.
;;;
;;; Once DEINITIALIZE has run, ECL is about to be shut down, and the callbacks
;;; return without calling into Lisp. A thread that is already in Lisp then
;;; isn't waited for.
;;;
;;; This only makes calls from other threads possible: the tables behind the
;;; callbacks aren't thread-safe yet (see R in TODO.md).
;;;

(ffi:clines "
/* True in a thread that ECL knows, once checked */
static __thread int gdecl_lisp_thread = 0;
/* False once DEINITIALIZE has run */
static int gdecl_lisp_running = 1;

/* Set in the threads that imported themselves, so that its destructor releases
   them when they exit */
static pthread_key_t gdecl_imported_thread_key;
static pthread_once_t gdecl_imported_thread_key_once = PTHREAD_ONCE_INIT;

static void gdecl_release_imported_thread(void *value)
{
    if (__atomic_load_n(&gdecl_lisp_running, __ATOMIC_ACQUIRE))
        ecl_release_current_thread();
}

static void gdecl_make_imported_thread_key(void)
{
    pthread_key_create(&gdecl_imported_thread_key, gdecl_release_imported_thread);
}

/* Whether the calling thread can run Lisp: imports it into ECL the first time.
   The callbacks of other files call it through a pointer (ENTER-LISP-ADDRESS),
   as ASDF compiles each file into a library of its own */
static int gdecl_enter_lisp(void)
{
    if (!__atomic_load_n(&gdecl_lisp_running, __ATOMIC_ACQUIRE))
        return 0;
    if (gdecl_lisp_thread)
        return 1;
    if (ecl_process_env_unsafe() == NULL) {
        if (!ecl_import_current_thread(ECL_NIL, ECL_NIL))
            return 0;
        pthread_once(&gdecl_imported_thread_key_once, gdecl_make_imported_thread_key);
        pthread_setspecific(gdecl_imported_thread_key, (void *)1);
    }
    gdecl_lisp_thread = 1;
    return 1;
}")

(defun enter-lisp-address ()
  "The address of gdecl_enter_lisp, for the callbacks' C functions."
  (ffi:c-inline () () :pointer-void "(void *)gdecl_enter_lisp" :one-liner t))

(defun stop-entering-lisp ()
  "Make the callbacks return without calling into Lisp from now on, as ECL is
about to be shut down."
  (ffi:c-inline () () :void "__atomic_store_n(&gdecl_lisp_running, 0, __ATOMIC_RELEASE)"
                :one-liner t))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun callback-c-name (name)
    "The name of the C function in front of the callback NAME, a symbol."
    (format nil "gdecl_callback_~a"
            (substitute-if #\_ (lambda (c) (not (alphanumericp c)))
                           (string-downcase name)))))

(defmacro define-callback (name return-type arguments &body body)
  "Define the callback NAME, as FFI:DEFCALLBACK, behind a C function that makes
sure the calling thread can run Lisp (see Threads above); CALLBACK-POINTER
gives that function's address. If the thread can't, the C function returns
0 (NULL), or nothing if RETURN-TYPE is :VOID."
  (let* ((c-name (callback-c-name name))
         (target (format nil "~a_target" c-name))
         (c-return-type (c-type-name return-type))
         (c-argument-types (mapcar (lambda (argument) (c-type-name (second argument)))
                                   arguments))
         (parameters (loop for type in c-argument-types
                           for i from 0
                           collect (format nil "~a a~d" type i)))
         (call (format nil "((~a (*)(~{~a~^, ~}))~a)(~{a~d~^, ~})"
                       c-return-type (or c-argument-types '("void")) target
                       (loop for i below (length arguments) collect i))))
    `(progn
       (ffi:defcallback ,name ,return-type ,arguments ,@body)
       ;; Once in each file: the pointer to gdecl_enter_lisp, set below
       (ffi:clines "
#ifndef GDECL_ENTER_LISP_FUNCTION
#define GDECL_ENTER_LISP_FUNCTION
static int (*gdecl_enter_lisp_function)(void);
#endif")
       (ffi:clines ,(format nil "
static void *~a;
static ~a ~a(~{~a~^, ~})
{
    if (!gdecl_enter_lisp_function())
        return~:[ 0~;~];
    ~:[return ~;~]~a;
}"
                            target
                            c-return-type c-name (or parameters '("void"))
                            (eq return-type :void)
                            (eq return-type :void) call))
       (ffi:c-inline ((enter-lisp-address)) (:pointer-void) :void
                     "gdecl_enter_lisp_function = (int (*)(void))#0" :one-liner t)
       (ffi:c-inline ((ffi:callback ',name)) (:pointer-void) :void
                     ,(format nil "~a = #0" target) :one-liner t)
       (setf (get ',name 'callback-pointer)
             (ffi:c-inline () () :pointer-void ,(format nil "(void *)~a" c-name)
                           :one-liner t))
       ',name)))

(defun callback-pointer (name)
  "The address of the callback NAME, defined with DEFINE-CALLBACK, to give to
Godot."
  (or (get name 'callback-pointer)
      (error "No callback named ~s" name)))

;;;
;;; Errors
;;;

(defun report-error (where condition)
  "Report the Lisp error CONDITION that happened in WHERE (a string, e.g. the
name of a method) with Godot's print_error, so that it shows up like Godot's
own errors, also in the editor. Called from the callbacks' error handlers, so
it must not fail itself: if print_error can't be used, it prints to standard
output."
  (let ((description (or (ignore-errors (princ-to-string condition)) "(unprintable error)"))
        (where (or where "Lisp code")))
    (unless (and *print-error*
                 (ignore-errors (print-error description where "Lisp" 0) t))
      (format t "~&ERROR: ~a~%   at: ~a~%" description where))))

;; WITH-CALLBACK-PROTECTION catches errors with a handler made once: ECL's
;; HANDLER-BIND (and so HANDLER-CASE) conses a new handler cluster at every
;; entry, which is most of what a callback cost (measured with `make bench`).
;; It binds ECL's internal SI:*HANDLER-CLUSTERS* the way HANDLER-BIND does.

(defun throw-callback-error (condition)
  (throw 'callback-error condition))

(defmacro catching-errors (&body body)
  "Evaluate BODY and return NIL, or, if BODY signals an error, the condition,
after unwinding BODY. Like HANDLER-CASE, but cheaper."
  `(catch 'callback-error
     (let ((si:*handler-clusters*
             (cons (load-time-value (list (cons 'error #'throw-callback-error)))
                   si:*handler-clusters*)))
       ,@body
       nil)))

(defmacro with-callback-protection ((where &optional error-value) &body body)
  "Evaluate BODY, the work of a callback, with an autorelease pool of its own
(see GD-EXTENSION-TYPES:*AUTORELEASE-POOL*), and return its value. If BODY
signals an error, it's reported with REPORT-ERROR as happening in WHERE (a form
evaluated only then), and ERROR-VALUE is returned, as a Lisp error must never
unwind through Godot's C frames. The references in the pool are given back
afterwards, also after an error; no other non-local exit can leave a callback,
so this needs no UNWIND-PROTECT."
  (let ((result (gensym "RESULT"))
        (condition (gensym "CONDITION"))
        (release-condition (gensym "RELEASE-CONDITION")))
    `(let ((*autorelease-pool* '())
           (,result nil))
       (let ((,condition (catching-errors (setf ,result (progn ,@body)))))
         ;; Give back the references, going on after one that fails. Measured
         ;; with `make bench`: this form costs nothing on the per-frame path,
         ;; unlike a closure for reporting (which makes ECL box the variables
         ;; WHERE refers to) or a list of conditions.
         (loop while (consp *autorelease-pool*)
               do (let ((,release-condition (catching-errors (release-autorelease-pool))))
                    (when ,release-condition
                      (report-error ,where ,release-condition))))
         (cond (,condition
                (report-error ,where ,condition)
                ,error-value)
               (t ,result))))))
