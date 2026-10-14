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
	report("lisp.call(\"tick\", delta) (Lisp method, Variant call)",
		func(): for i in COUNT: lisp.call("tick", 0.016))

	# The engine calls of LispBenchmarks.run
	report("get_child_count()", func(): for i in COUNT: node.get_child_count())
	report("is_visible()", func(): for i in COUNT: node.is_visible())
	report("get_position()", func(): for i in COUNT: node.get_position())
	report("set_position(v)", func(): for i in COUNT: node.set_position(position))
	report("Input.is_action_pressed(\"ui_up\")",
		func(): for i in COUNT: Input.is_action_pressed("ui_up"))

	lisp.run(COUNT)
	lisp.free()
	quit()
