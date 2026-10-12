extends SceneTree

# Runs gdecl's tests: the tests below, which use the Lisp classes of
# ../lisp/classes.lisp from Godot, then the tests written in Lisp, through
# LispTests. Run it with `make test` in the directory above. Quits with exit
# code 1 if a test fails.

var checks := 0
var failures := 0


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
	check(node.is_null(null), "null for an Object argument")
	check(not node.is_null(node), "an Object argument")
	check(node.get_self() == node, "a Lisp object as an Object result")
	node.free()


func test_errors() -> void:
	var node := TestNode.new()
	# The Makefile shows the next error as expected
	print("[test] expect error")
	# Called with Variants: a typed call is a ptrcall, which returns 0 for an int
	check(node.call("fail") == null, "a method that signals an error returns null")
	node.free()


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
