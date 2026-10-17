extends SceneTree

# Runs gdecl's tests: the tests below, which use the Lisp classes of
# ../lisp/classes.lisp from Godot, then the tests written in Lisp, through
# LispTests. Run it with `make test` in the directory above. Quits with exit
# code 1 if a test fails.

var checks := 0
var failures := 0

# Emitted and connected to from Lisp by test_callables_and_signals
signal tested(value: int)


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		printerr("[test] FAIL: ", message)


func _init() -> void:
	# Wait for the root window to be set up
	await process_frame
	for method in get_method_list():
		if method.name.begins_with("test_"):
			await call(method.name)
	print("[test] GDScript: %d checks, %d failures" % [checks, failures])
	await run_lisp_tests()
	quit(1 if failures > 0 else 0)


func run_lisp_tests() -> void:
	var tests := LispTests.new()
	var lisp_root := Node.new()
	root.add_child(tests)
	root.add_child(lisp_root)
	failures += tests.run(lisp_root)
	lisp_root.queue_free()
	tests.queue_free()
	await process_frame


func property_info(object: Object, name: String) -> Dictionary:
	for property in object.get_property_list():
		if property.name == name:
			return property
	return {}


func test_properties() -> void:
	var node := TestNode.new()
	check(node.count == 0, "count's initial value")
	node.count = 5
	check(node.count == 5, "count set to 5")
	node.count = 2.7
	check(node.count == 2, "a float for an int property is truncated")
	node.speed = 3
	check(node.speed == 3.0 and typeof(node.speed) == TYPE_FLOAT, "an int for a float property")
	node.title = "héllo"
	check(node.title == "héllo", "a String property with a non-ASCII character")
	var resource := property_info(node, "resource")
	check(resource.hint == PROPERTY_HINT_RESOURCE_TYPE and resource.class_name == &"TestResource",
			"a property of a Resource class")
	var target := property_info(node, "target")
	check(target.hint == PROPERTY_HINT_NODE_TYPE and target.hint_string == "Node2D",
			"a property of a Node class")
	node.free()


func test_methods() -> void:
	var node := TestNode.new()
	check(node.add(2, 3) == 5, "add(2, 3)")
	check(node.add(2.9, 3) == 5, "a float for an int argument is truncated")
	check(node.scale_vector(Vector2(1, 2), 2) == Vector2(2, 4), "Vector2 and float arguments")
	check(node.scale_vector3(Vector3(1, 2, 3), 2) == Vector3(2, 4, 6), "Vector3 arguments")
	var basis := Basis(Vector3(1, 2, 3), Vector3(4, 5, 6), Vector3(7, 8, 9))
	check(node.basis_column(basis, 0) == basis.x and node.basis_column(basis, 2) == basis.z,
			"a Basis argument has the columns of GDScript")
	check(node.looking_at(Vector3(1, -2, 3)).is_equal_approx(Basis.looking_at(Vector3(1, -2, 3))),
			"basis-looking-at as Basis.looking_at()")
	check(node.echo("åäö") == "åäö", "a String argument and result")
	check(node.echo_name(&"nämn") == &"nämn", "a StringName argument and result")
	check(node.call("echo_name", &"nämn") == &"nämn", "a StringName result of a Variant call")
	check(node.echo_path(^"a/bå") == ^"a/bå", "a NodePath argument and result")
	check(node.call("echo_path", ^"a/bå") == ^"a/bå", "a NodePath result of a Variant call")
	check(node.is_null(null), "null for an Object argument")
	check(not node.is_null(node), "an Object argument")
	check(node.get_self() == node, "a Lisp object as an Object result")
	node.free()


func test_callables_and_signals() -> void:
	var node := TestNode.new()
	# A Callable from GDScript is an ENGINE-CALLABLE in Lisp, which can call it
	check(node.call_callable(func(x): return x * 3, 5) == 15, "Lisp calls a GDScript lambda")
	check(node.call_callable(node.add.bind(10), 5) == 15, "Lisp calls a bound method")
	check(node.callables_equal(node.add, node.add), "equal method Callables")
	check(not node.callables_equal(node.add, node.echo), "different method Callables")
	check(node.count_engine_callables([func(): pass, 1, node.add]) == 2, "Callables in an Array")
	check(node.echo_callable(node.add) == node.add, "an ENGINE-CALLABLE back to Godot")
	check(node.call("echo_callable", node.add) == node.add, "and as a Variant")
	# A Lisp callable comes back to Lisp as itself
	var own: Callable = node.make_lisp_callable()
	check(own.call(4) == 40, "GDScript calls a Lisp callable")
	check(node.is_own_callable(own), "a Lisp callable comes back as itself")
	# Called with each number of arguments, of simple types and others
	var arguments: Callable = node.make_arguments_callable()
	check(arguments.call() == [], "a Lisp callable without arguments")
	check(arguments.call(true) == [true], "a Lisp callable with a bool")
	check(arguments.call(1, 2.5) == [1, 2.5], "a Lisp callable with an int and a float")
	check(arguments.call("a", false, Vector2(1, 2)) == ["a", false, Vector2(1, 2)],
			"a Lisp callable with three arguments")
	check(arguments.call(1, 2, 3, 4) == [1, 2, 3, 4], "a Lisp callable with four arguments")
	# Its result, of each simple type and others; one that can't be a Variant is null
	var echo: Callable = node.make_echo_callable()
	check(echo.call(true) == true and echo.call(7) == 7 and echo.call(2.5) == 2.5,
			"a Lisp callable's bool, int and float results")
	check(echo.call("text") == "text" and echo.call(Vector2(1, 2)) == Vector2(1, 2),
			"a Lisp callable's other results")
	check(echo.call() == null, "a Lisp callable's result that can't be a Variant")
	# Valid until the call from Godot returns, unless kept
	node.store_callable(func(x): return x)
	# Fails, so a Variant call returns null
	print("[test] expect error")
	check(node.call("call_stored", 1) == null, "a Callable used after the call it came in")
	node.keep_callable(func(x): return x + 1)
	check(node.call_kept(1) == 2, "a kept Callable")
	node.free_kept()
	# A Signal is an ENGINE-SIGNAL in Lisp
	var heard := []
	var listener := func(value): heard.append(value)
	tested.connect(listener)
	node.emit_signal_value(tested, 7)
	check(heard == [7], "Lisp emits a Signal")
	check(node.signal_name(tested) == "tested" and node.signal_object(tested) == self,
			"a Signal's name and object")
	check(node.own_signal() == node.pinged, "a Signal from Lisp")
	node.connect_signal_value(tested)
	tested.emit(9)
	check(node.heard_value() == 9, "Lisp connects to a Signal")
	tested.disconnect(listener)
	node.free()


func test_errors() -> void:
	var node := TestNode.new()
	# The Makefile shows the next error as expected
	print("[test] expect error")
	# Called with Variants: a typed call is a ptrcall, which returns 0 for an int
	check(node.call("fail") == null, "a method that signals an error returns null")
	# A typed call is a ptrcall: a failing method returns its type's default
	# value, not what an earlier call left where the caller keeps the result
	check(node.add(2, 3) == 5, "an int result before a failing method")
	print("[test] expect error")
	check(node.fail() == 0, "a failing method returns 0 for an int with ptrcall")
	check(node.scale_vector(Vector2(1, 2), 2) == Vector2(2, 4), "a Vector2 result before")
	print("[test] expect error")
	check(node.fail_vector() == Vector2(), "and Vector2(0, 0) for a Vector2")
	check(node.is_null(null), "a bool result before")
	print("[test] expect error")
	check(node.fail_bool() == false, "and false for a bool")
	check(node.get_self() == node, "an Object result before")
	print("[test] expect error")
	check(node.fail_object() == null, "and null for an Object")
	# Call errors, which Godot reports with the expected count or type
	print("[test] expect error")
	check(node.callv("add", [1]) == null, "too few arguments")
	print("[test] expect error")
	check(node.callv("add", [1, 2, 3]) == null, "too many arguments")
	print("[test] expect error")
	check(node.callv("add", ["one", 2]) == null, "an argument of the wrong type")
	# Variant calls convert as Godot does for its own methods
	check(node.call("add", 2.9, 3) == 5, "a float for an int argument of a Variant call is truncated")
	check(node.call("describe", true, 2, 3.5, null) == "T 2 3.5d0 T",
			"a Variant call with four arguments")
	check(node.call("describe", false, 2.5, 3, node) == "NIL 2 3.0d0 NIL",
			"a Variant call with an int for a float and a float for an int")
	check(node.call("is_null", null) == true and node.call("is_null", node) == false,
			"a bool result of a Variant call")
	var speed = node.call("get_speed")
	check(typeof(speed) == TYPE_FLOAT and speed == node.speed, "a float result of a Variant call")
	node.free()


func test_failing_constructor() -> void:
	# The Godot object made for the instance must be freed again, or Godot
	# reports it as leaked at exit
	print("[test] expect error")
	check(ClassDB.instantiate("TestFailingNode") == null,
		"a class whose Lisp object can't be made isn't instantiated")


func test_ready_and_process() -> void:
	var node := TestNode.new()
	var child := Node.new()
	child.name = "Child"
	node.add_child(child)
	root.add_child(node)
	check(node.get_child_slot() == child, "an :onready slot with a path")
	check(node.get_parent_class() == "Window", "an :onready slot with a function")
	check(node.saw_child_in_ready(), "the :onready slots are set before _ready")
	await process_frame
	await process_frame
	check(node.get_process_calls() > 0, "_process is called")
	node.queue_free()

	var bare := TestBareNode.new()
	var bare_child := Node.new()
	bare_child.name = "Child"
	bare.add_child(bare_child)
	root.add_child(bare)
	check(bare.get_child_slot() == bare_child, "an :onready slot without a _ready of the class")
	bare.queue_free()
	await process_frame


func test_signals() -> void:
	var emitter := TestNode.new()
	var listener := TestNode.new()
	# A lambda captures local variables by value, so it fills the array
	var heard := []
	emitter.pinged.connect(func(a, b, c, d, e): heard.append_array([a, b, c, d, e]))
	listener.listen(emitter)
	emitter.emit_pinged()
	check(heard == [42, "text", Vector2(1, 2), emitter, true], "a signal with arguments from Lisp")
	check(listener.heard_pinged(), "a Lisp function connected to a signal")
	for connection in emitter.pinged.get_connections():
		# The Lisp function's Callable is bound to listener (the GDScript lambda
		# is a custom Callable too)
		if connection.callable.get_object() == listener:
			check(connection.callable.call(1, "a", Vector2(), null, false) == 5,
					"the result of a Lisp callable")
	emitter.free()
	listener.free()


func test_singleton() -> void:
	check(Engine.has_singleton("TestSingleton"), "TestSingleton is a singleton")
	var first: int = TestSingleton.next()
	check(Engine.get_singleton("TestSingleton").next() == first + 1,
			"TestSingleton by name and from Engine is the same object")


func test_references() -> void:
	var node := TestNode.new()
	var tests := LispTests.new()
	var resource := TestResource.new()
	check(resource.get_reference_count() == 1, "a new TestResource")
	node.resource = resource
	check(resource.get_reference_count() == 2, "an exported RefCounted slot keeps a reference")
	node.resource = null
	check(resource.get_reference_count() == 1, "setting it to null gives the reference back")
	node.resource = resource
	node.free()
	check(resource.get_reference_count() == 1, "freeing the instance gives the reference back")
	tests.keep_resource(resource)
	check(resource.get_reference_count() == 2, "setf-reference keeps a reference")
	tests.keep_resource(null)
	check(resource.get_reference_count() == 1, "setf-reference gives the old reference back")
	var destroyed: int = tests.resources_destroyed()
	resource = null
	check(tests.resources_destroyed() == destroyed + 1, "the :destructor runs when Godot frees it")
	tests.free()


func test_autorelease_pool() -> void:
	var tests := LispTests.new()
	var id: int = tests.new_resource_id()
	check(instance_from_id(id) == null, "a result is freed when the call from Godot returns")
	id = tests.keep_new_resource()
	check(instance_from_id(id) != null, "a result kept with setf-reference stays")
	tests.keep_resource(null)
	check(instance_from_id(id) == null, "and is freed when it's given back")
	# A typed call is a ptrcall, which gets the result as an object pointer
	var resource: TestResource = tests.new_resource()
	check(resource != null and resource.get_reference_count() == 1,
			"a result returned to Godot with ptrcall stays, with Godot's reference")
	resource = tests.call("new_resource")
	check(resource != null and resource.get_reference_count() == 1,
			"a result returned to Godot with a Variant call stays, with Godot's reference")
	resource = null
	# A RefCounted object that Lisp keeps, returned to Godot
	var holder := TestNode.new()
	var kept := TestResource.new()
	holder.resource = kept
	var got: TestResource = holder.get_resource()
	check(kept.get_reference_count() == 3, "a kept object returned with ptrcall gets Godot's reference")
	got = holder.call("get_resource")
	check(kept.get_reference_count() == 3, "a kept object returned with a Variant call gets Godot's reference")
	got = null
	holder.free()
	check(kept.get_reference_count() == 1, "and they're all given back")
	tests.free()


# Classes defined with GODOT-CLOS (../lisp/clos-classes.lisp)

func test_clos_properties_and_methods() -> void:
	var node := ClosNode.new()
	check(node.count == 0, "CLOS: an exported slot's initform")
	node.count = 5
	check(node.count == 5, "CLOS: an exported slot set")
	check(node.speed == 1.5, "CLOS: a float property")
	var resource := property_info(node, "resource")
	check(resource.hint == PROPERTY_HINT_RESOURCE_TYPE and resource.class_name == &"TestResource",
			"CLOS: a property of a Resource class")
	var kept := TestResource.new()
	node.resource = kept
	check(kept.get_reference_count() == 2, "CLOS: a RefCounted property keeps a reference")
	check(node.add(2, 3) == 5, "CLOS: a method")
	check(node.call("add", 2, 3) == 5, "CLOS: a method called with Variants")
	check(node.scale_vector(Vector2(1, 2), 2) == Vector2(2, 4), "CLOS: Vector2 and float arguments")
	check(node.has_signal("pinged"), "CLOS: a signal")
	var heard := []
	node.pinged.connect(func(number: int) -> void: heard.append(number))
	node.emit_pinged()
	check(heard == [5], "CLOS: a signal emitted from Lisp")
	node.free()
	check(kept.get_reference_count() == 1, "CLOS: the reference is given back when it's freed")


func test_clos_ready_and_process() -> void:
	var node := ClosNode.new()
	var child := Node.new()
	child.name = "Child"
	node.add_child(child)
	root.add_child(node)
	check(node.get_ready_calls() == 1, "CLOS: ready")
	check(node.get_child_slot() == child, "CLOS: an :onready slot with a path")
	check(node.get_parent_class() == "Window", "CLOS: an :onready slot with a function")
	await process_frame
	await process_frame
	check(node.get_process_calls() > 0, "CLOS: process")
	node.queue_free()
	await process_frame


func test_clos_inheritance() -> void:
	var node := ClosSubNode.new()
	check(node is ClosNode, "CLOS: a Lisp class that extends a Lisp class")
	check(node.count == 0 and node.label == "sub", "CLOS: inherited and own properties")
	check(node.add(2, 3) == 50, "CLOS: a method that calls the inherited one")
	check(node.greet() == "hello", "CLOS: a method of a mixin")
	check(node.has_signal("pinged"), "CLOS: an inherited signal")
	var child := Node.new()
	child.name = "Child"
	node.add_child(child)
	root.add_child(node)
	check(node.get_ready_calls() == 1, "CLOS: an inherited virtual method")
	await process_frame
	await process_frame
	check(node.get_process_calls() > 100, "CLOS: a :before method on an inherited virtual method")
	node.queue_free()
	await process_frame
