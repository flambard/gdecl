(in-package #:gdecl-test)

;;; Benchmarks of what's called every frame: calls from Lisp into Godot (engine
;;; methods), timed here, and calls from Godot into Lisp (bound methods, and
;;; virtual methods such as _process, which go through the same dispatcher),
;;; timed by run_benchmarks.gd, which also times the same calls in GDScript
;;; for comparison. Run them with `make bench`.

(defun bytes-consed ()
  "The number of bytes allocated so far, from the statistics of ECL's GC."
  (values (si:gc-stats t)))

(defun report-benchmark (name count function)
  "Call FUNCTION, which runs something COUNT times, once to warm up and then
three times, and print the best time and the bytes allocated per run."
  (funcall function)
  (let ((best-time nil)
        (best-bytes nil))
    (dotimes (round 3)
      (let ((start-bytes (bytes-consed))
            (start-time (get-internal-real-time)))
        (funcall function)
        (let ((time (- (get-internal-real-time) start-time))
              (bytes (- (bytes-consed) start-bytes)))
          (when (or (null best-time) (< time best-time))
            (setf best-time time
                  best-bytes bytes)))))
    (godot-print (format nil "[bench] Lisp ~a: ~,1f ns/call, ~,1f bytes/call"
                         name
                         (/ (* best-time 1d9) internal-time-units-per-second count)
                         (/ best-bytes count 1d0)))))

(defmacro benchmark (name count &body body)
  "Time BODY, run COUNT times, see REPORT-BENCHMARK."
  `(report-benchmark ,name ,count
                     (lambda ()
                       (dotimes (i ,count)
                         (declare (ignorable i))
                         ,@body))))

;;;
;;; LispBenchmarks: run_benchmarks.gd calls tick to time calls into Lisp, and
;;; run to time calls from Lisp into Godot
;;;

(gdext:define-class lisp-benchmarks ("LispBenchmarks" "Node2D")
  ((ticks 0))
  ;; Without connections, for timing emit_signal, a vararg method
  (:signal "pinged" ("value" :int))
  ;; For timing signal handlers, in GDScript and in Lisp (connect_lisp_handler)
  (:signal "handled" ("value" :int))
  (:method "connect_lisp_handler" lisp-benchmarks-connect-lisp-handler)
  ;; Like _process(delta)
  (:method "tick" lisp-benchmarks-tick :arguments (("delta" :float)))
  (:method "run" lisp-benchmarks-run :arguments (("count" :int))))

(defun lisp-benchmarks-tick (benchmarks delta)
  (declare (ignore delta))
  (incf (lisp-benchmarks-ticks benchmarks)))

(defun lisp-benchmarks-connect-lisp-handler (benchmarks)
  "Connect the signal handled to a Lisp function, a signal handler."
  (gdext:connect-signal benchmarks "handled"
                        (lambda (value)
                          (declare (ignore value))
                          (incf (lisp-benchmarks-ticks benchmarks)))))

(defun lisp-benchmarks-run (benchmarks count)
  (let ((position (vector2 1.0 2.0)))
    (benchmark "empty loop" count)
    (benchmark "get_child_count()" count
      (node-get-child-count benchmarks))
    (benchmark "is_visible()" count
      (canvas-item-is-visible benchmarks))
    (benchmark "get_position()" count
      (node-2d-get-position benchmarks))
    (benchmark "set_position(v)" count
      (node-2d-set-position benchmarks position))
    (benchmark "Input.is_action_pressed(\"ui_up\")" count
      (input-is-action-pressed "ui_up"))
    (benchmark "emit_signal(\"pinged\", 1) (vararg)" count
      (object-emit-signal benchmarks "pinged" 1))))
