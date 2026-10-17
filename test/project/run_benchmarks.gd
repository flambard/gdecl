extends SceneTree

# Benchmarks of what's called every frame, in Lisp and in GDScript for
# comparison: calls into Lisp (a bound method, through the same dispatcher as
# virtual methods such as _process), and the same engine calls from GDScript
# as LispBenchmarks makes from Lisp (../lisp/benchmarks.lisp). Run it with
# `make bench` in the directory above.

const COUNT := 100000


class Ticker:
	var ticks := 0

	func tick(_delta: float) -> void:
		ticks += 1


# An empty _process in GDScript, for comparing virtual methods
class Processor extends Node2D:
	func _process(_delta: float) -> void:
		pass


# The best time of three runs of f, which runs something COUNT times, after a
# warm-up run
func best_usec(f: Callable) -> int:
	f.call()
	var best := 0
	for i in 3:
		var start := Time.get_ticks_usec()
		f.call()
		var usec := Time.get_ticks_usec() - start
		if i == 0 or usec < best:
			best = usec
	return best


func report(name: String, f: Callable) -> void:
	print("[bench] GDScript %s: %.1f ns/call" % [name, best_usec(f) * 1000.0 / COUNT])


func _init() -> void:
	# Wait for the root window to be set up
	await process_frame
	var lisp: LispBenchmarks = LispBenchmarks.new()
	root.add_child(lisp)
	var ticker := Ticker.new()
	var node: Node2D = lisp
	var position := Vector2(1.0, 2.0)

	# Calls into Lisp, and into GDScript for comparison
	report("empty loop", func(): for i in COUNT: pass)
	report("ticker.tick(delta) (GDScript method)", func(): for i in COUNT: ticker.tick(0.016))
	report("lisp.tick(delta) (Lisp method, ptrcall)", func(): for i in COUNT: lisp.tick(0.016))
	report("lisp.noop() (empty Lisp method, ptrcall)", func(): for i in COUNT: lisp.noop())
	report("lisp.call(\"tick\", delta) (Lisp method, Variant call)",
		func(): for i in COUNT: lisp.call("tick", 0.016))
	report("lisp.call(\"get_ticks\") (Lisp method, Variant call, int result)",
		func(): for i in COUNT: lisp.call("get_ticks"))

	# The engine calls of LispBenchmarks.run
	report("get_child_count()", func(): for i in COUNT: node.get_child_count())
	report("is_visible()", func(): for i in COUNT: node.is_visible())
	report("get_parent() (Object result)", func(): for i in COUNT: node.get_parent())
	report("get_position()", func(): for i in COUNT: node.get_position())
	report("set_position(v)", func(): for i in COUNT: node.set_position(position))
	report("Input.is_action_pressed(\"ui_up\")",
		func(): for i in COUNT: Input.is_action_pressed("ui_up"))
	report("emit_signal(\"pinged\", 1) (vararg)", func(): for i in COUNT: lisp.emit_signal("pinged", 1))

	# Signal handlers, emitted from GDScript: none, a GDScript one and a Lisp one
	report("handled.emit(1), no handler", func(): for i in COUNT: lisp.handled.emit(1))
	var handler := func(_value: int) -> void: ticker.ticks += 1
	lisp.handled.connect(handler)
	report("handled.emit(1), GDScript handler", func(): for i in COUNT: lisp.handled.emit(1))
	lisp.handled.disconnect(handler)
	lisp.connect_lisp_handler()
	report("handled.emit(1), Lisp handler", func(): for i in COUNT: lisp.handled.emit(1))

	# A property's getter and setter
	report("lisp.get_speed() (define-class property)", func(): for i in COUNT: lisp.get_speed())
	report("lisp.set_speed(x) (define-class property)", func(): for i in COUNT: lisp.set_speed(2.0))

	lisp.run(COUNT)
	lisp.free()

	# The same with a class defined with GODOT-CLOS
	var clos: ClosBenchmarks = ClosBenchmarks.new()
	report("clos.tick(delta) (CLOS generic function, ptrcall)", func(): for i in COUNT: clos.tick(0.016))
	report("clos.call(\"tick\", delta) (CLOS generic function, Variant call)",
		func(): for i in COUNT: clos.call("tick", 0.016))
	report("clos.get_speed() (CLOS property)", func(): for i in COUNT: clos.get_speed())
	report("clos.set_speed(x) (CLOS property)", func(): for i in COUNT: clos.set_speed(2.0))
	clos.run(COUNT)

	# Notifications: to an engine class, to a CLOS class without a method for
	# it (filtered out before Lisp), and with a method for it
	var engine_node := Node2D.new()
	report("node.notification(3900) (engine class)",
		func(): for i in COUNT: engine_node.notification(3900))
	engine_node.free()
	report("clos.notification(3900) (no method)", func(): for i in COUNT: clos.notification(3900))
	report("clos.notification(3901) (CLOS method)", func(): for i in COUNT: clos.notification(3901))

	# An empty _process, called as Godot calls it every frame, through
	# NOTIFICATION_PROCESS: none, in GDScript, with DEFINE-CLASS, and with
	# GODOT-CLOS through the generic function and through a direct function
	var plain := Node2D.new()
	var processor := Processor.new()
	var lisp_process: LispBenchmarks = LispBenchmarks.new()
	var direct: ClosDirectBenchmarks = ClosDirectBenchmarks.new()
	report("_process: none (Node2D)",
		func(): for i in COUNT: plain.notification(Node.NOTIFICATION_PROCESS))
	report("_process: GDScript",
		func(): for i in COUNT: processor.notification(Node.NOTIFICATION_PROCESS))
	report("_process: define-class",
		func(): for i in COUNT: lisp_process.notification(Node.NOTIFICATION_PROCESS))
	report("_process: CLOS generic function",
		func(): for i in COUNT: clos.notification(Node.NOTIFICATION_PROCESS))
	report("_process: CLOS direct function",
		func(): for i in COUNT: direct.notification(Node.NOTIFICATION_PROCESS))
	plain.free()
	processor.free()
	lisp_process.free()
	direct.free()
	clos.free()

	# Making and freeing objects: an engine class, a Lisp class defined with
	# DEFINE-CLASS, and one defined with GODOT-CLOS
	report("Node2D.new().free()", func(): for i in COUNT: Node2D.new().free())
	report("LispBenchmarks.new().free() (define-class)",
		func(): for i in COUNT: LispBenchmarks.new().free())
	report("ClosBenchmarks.new().free() (godot-class)",
		func(): for i in COUNT: ClosBenchmarks.new().free())
	quit()
