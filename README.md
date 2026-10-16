# gdecl

gdecl is a framework for programming [Godot](https://godotengine.org) 4 with Common Lisp, using [Embeddable Common Lisp](https://ecl.common-lisp.dev) (ECL). Your Lisp code is compiled into a GDExtension library. A small C bootstrap boots ECL inside Godot, and from then on everything is done from Lisp: it looks up the GDExtension interface functions, registers classes, methods, properties and signals, and handles Godot's callbacks.

gdecl is a proof of concept. Its API is incomplete and will change.

## Goals

GDExtension is a low-level C interface, not meant to be used directly by application developers. gdecl builds higher-level, Lisp-style APIs on top of it, step by step, with the aim of making Godot as easy to program in Lisp as in GDScript or C#, and taking inspiration from both. Since Godot is mostly used for games, the higher-level APIs must stay efficient: work such as looking up methods is done once rather than per call, and code called every frame shouldn't allocate.

The aim is a very high-level way of programming Godot, with the option to drop down to lower-level concepts exactly where a task is performance sensitive: one method of a class, or one hot loop, without giving up the high level elsewhere. The lower layers stay available for that, and for what the higher ones don't cover yet.

The long-term ambition is to program Godot at a high level in Lisp, with Godot's classes, inheritance, virtual methods, properties and signals expressed naturally. CLOS looks like a very good fit: define Godot classes with `defclass`-like forms, implement virtual methods such as `_process` with `defmethod`, and redefine classes in a running game. Whether it fits is still to be found out, though: if CLOS can't be made fast enough for code that runs every frame, a more specialized DSL, or a mix of the two, may fit better. That will be decided by prototyping and measuring.

## Requirements

- Godot ≥ 4.4
- ECL, with `ecl-config` on `PATH`
- GNU Make and a C compiler (clang is used if it's installed)

## Setting up an application

An application is a directory with gdecl in it (for example as a git submodule), its own ASDF system and a Godot project:

```
my-app/
  gdecl/              this framework
  lisp/my-app.asd     your ASDF system
  lisp/*.lisp
  project/            your Godot project
  Makefile
```

**The ASDF system** depends on `gdecl`:

```lisp
(defsystem "my-app"
  :depends-on ("gdecl")
  :components ((:file "packages")
               (:file "my-app" :depends-on ("packages"))))
```

**The package** uses Godot's API, and refers to gdecl's own macros with the prefix `gdext:`:

```lisp
(defpackage #:my-app
  (:use #:cl #:godot #:godot-utility))
```

**The Makefile** names your ASDF system and the GDExtension library to build into your Godot project, and includes gdecl's make rules:

```make
SYSTEM = my-app
LIBRARY = project/bin/libgdecl.so
include gdecl/gdecl.mk
```

`gdecl.mk` also takes `LISP_DIRS`, the directories with your `.asd` and `.lisp` files (default `lisp`), `BUILD_DIR`, where `application.a` and the object files go (default `build`), `GODOT`, the Godot executable (default `godot`), and the usual `CC` and `CFLAGS` (default clang if installed, and `-O0 -g`).

**The `.gdextension` file** in your Godot project points Godot to the library. The entry symbol is always `gdecl_library_init`:

```ini
[configuration]

entry_symbol = "gdecl_library_init"
compatibility_minimum = "4.4"

[libraries]
linux.debug = "res://bin/libgdecl.so"
```

## Building

```sh
make             # Compile the Lisp code into build/application.a and build the GDExtension library
make godot-api   # Regenerate the Godot API files, e.g. after upgrading Godot
make clean
```

The first `make` runs Godot once to dump `gdextension_interface.h` and `extension_api.json` into `gdecl/`.

## Packages

| Package | Nickname | What it is |
|---|---|---|
| `godot` | `gd` | Godot's API: engine methods, enums and constants, and the builtin types such as `vector2` |
| `godot-utility` | `gd-util` | Godot's utility functions, the global functions of GDScript, such as `randf-range` |
| `gd-extension` | `gdext` | gdecl itself: defining classes, signals, references, and the macros that generate Godot's API |
| `gd-extension-ffi` | `gdext-ffi` | The GDExtension C interface, one-to-one, for what the others don't cover yet |
| `godot-clos` | | A prototype: classes as CLOS classes, see [Classes as CLOS classes](#classes-as-clos-classes-a-prototype) |

`gd-extension-builtins`, `gd-extension-types` and `gd-extension-callback` are gdecl's internal layers; applications don't need them. `gdecl-json` reads `extension_api.json` when your code is compiled.

## Defining classes

`define-class` defines a class in one form, like a GDScript script:

```lisp
(gdext:define-class player ("Player" "Area2D")      ; class_name Player extends Area2D
  ((speed 400 :export :int)                          ; @export var speed = 400
   screen-size                                       ; var screen_size
   (sprite nil :onready "AnimatedSprite2D"))         ; @onready var sprite = $AnimatedSprite2D
  (:signal "hit")
  (:method "start" player-start :arguments (("pos" :vector2)))
  (:virtual "_ready" player-ready)
  (:virtual "_process" player-process))

(defun player-process (player delta)
  (when (input-is-action-pressed "move_right")
    ...))
```

`player` is a struct of the instance's Lisp object, with your slots, as in `defstruct`: `(player-speed player)`. Each function is called with it as its first argument, like `self`. Functions are given by name, so redefining one takes effect right away. The classes are registered when Godot loads the extension, in the order they're defined.

Slot options:

| Option | Like in GDScript | |
|---|---|---|
| `:export type` | `@export var` | A property, with the methods `get_<name>` and `set_<name>` (`mob-scene` is `mob_scene`) |
| `:class "PackedScene"` | `@export var x: PackedScene` | With `:export :object`: the class of the value, picked in the editor as a resource or a node. A RefCounted value is kept with a reference, given back when the instance is freed |
| `:setter function` | `set(value):` | Your own setter, called with the instance and the value. It then handles references itself |
| `:onready "Path"` | `@onready var x = $Path` | Set to that node when the instance is ready, before your `_ready` runs |
| `:onready function` | `@onready var x = …` | Set to the result of calling the function with the instance |

Class options:

| Option | |
|---|---|
| `(:signal name (argument type)...)` | A signal, like `signal hit(damage: int)` |
| `(:method name function :arguments ((name type)...) :return-type type)` | A method Godot can call |
| `(:virtual name function)` | A virtual method such as `"_ready"`, `"_process"` or `"_input"`. Its signature comes from the engine class you inherit from, so `_process` gets `delta` as a float |
| `(:destructor function)` | Called with the instance when Godot frees it |
| `(:tool t)` | Run the class's code in the editor too, like `@tool`. Otherwise instances in the editor are placeholders |
| `(:singleton t)` | Make one instance and register it as an engine singleton named like the class, so GDScript uses it by name like `Input`: `GameState.add_score(10)`. `(:singleton "Name")` gives it another name. In Lisp, `(gdext:singleton "GameState")` is the instance. It's freed when Godot unloads the extension. The class can't be RefCounted |

Types are keywords named like Godot's variant types: `:bool`, `:int`, `:float`, `:string`, `:vector2`, `:rect2`, `:vector3`, `:basis` and `:object` can be arguments and results of methods.

**The entry point.** Your code is loaded when Godot loads the extension, but it can't call Godot yet at that point. To run something once gdecl is set up and your classes are registered, add an initialize hook. `add-deinitialize-hook` adds one for when Godot unloads the extension.

```lisp
(gdext:add-initialize-hook 'start)
```

### Classes as CLOS classes (a prototype)

`godot-clos` is a prototype of another way to define classes, with CLOS: a class is a `defclass` with the metaclass `godot-class`, and what Godot calls are generic functions, so they're implemented with `defmethod`, with inheritance, mixins, `:before`/`:after`/`:around` methods and `call-next-method`:

```lisp
(defclass player (area-2d)                           ; extends Area2D (the struct of define-engine-class)
  ((speed :initform 400 :export :int :reader speed)  ; @export var speed = 400
   (sprite :onready "AnimatedSprite2D" :reader sprite))
  (:metaclass godot-class)                           ; class_name Player
  (:signals (hit)))

(define-godot-generic start (self (pos :vector2)))   ; func start(pos: Vector2)

(defmethod start ((player player) pos) ...)
(defmethod ready ((player player)) ...)              ; _ready
(defmethod process ((player player) delta) ...)      ; _process
```

- The class's name in Godot is the class name in Godot style (`player` is `Player`), or `(:godot-name "Name")`. `(:tool t)` is as in `define-class`.
- The slot options `:export`, `:class` and `:onready` are those of `define-class`; the rest of a slot is plain CLOS (`:initform`, `:initarg`, `:accessor`).
- The class inherits from the struct of an engine class (`define-engine-class`) or from another `godot-class`, and may have mixins, standard classes, which come first in the superclasses. Its instances are Godot objects that engine methods take as they are, and `(make-instance 'player)` makes one in Godot.
- `define-godot-generic` defines a method that Godot and GDScript call by name, with its name in Godot (`(:godot-name "_on_body_entered")`) and types (`(:return-type :int)`). A class gets it in Godot if it has a method for it.
- Virtual methods are generic functions too: `ready`, `process`, `physics-process`, `enter-tree`, `exit-tree`, `unhandled-input` and `draw`; `define-virtual-function` defines others. Godot calls one only for the classes that have methods for it.
- Redefining a class, or adding a method, at a REPL updates the instances and registers what's new with Godot. Godot can't remove anything, change a class's parent, or call a virtual method that a class implemented only after Godot first asked (TODO J).

A call from Godot into a generic function costs 150–200 ns more than into a `define-class` function, and an accessor 50–60 ns more than a struct accessor (see TODO P).

## Calling Godot

Engine methods are functions in `godot`, named `<class>-<method>` in Lisp style, with the object first:

```lisp
(node-get-node main "HUD")
(canvas-item-hide player)
(node-2d-set-position player (vector2 100.0 200.0))
(timer-start timer)
(input-is-action-pressed "ui_up")        ; Input is a singleton: no object argument
```

- **Which class.** A method belongs to the class that defines it, not the ones that inherit it: a Sprite2D's position is `node-2d-get-position`.
- **Which classes are there.** gdecl defines Object, RefCounted, Resource, Node, CanvasItem, Node2D, Node3D, SceneTree, Input, Timer and PackedScene. Add the others you use with `(gdext:define-engine-class "AnimatedSprite2D")`; they're added to `godot` too. Each method costs about 70 ms of build time and 15 KB of library, so add only the classes you use.
- **Enums and constants** are Lisp constants in `godot`: `Node.PROCESS_MODE_ALWAYS` is `+node-process-mode-always+`, and the global ones like `OK` and `KEY_ESCAPE` are `+ok+` and `+key-escape+`.
- **Arguments** are named as in Godot. Those with a default value are optional, when the default can be written in Lisp. Static methods and methods of singletons, such as Input, take no object.
- **Vararg methods**, such as `emit_signal` and `call_group`, take any number of further arguments, converted to Variants by their Lisp types: `(object-emit-signal player "hit" damage)`.
- **Utility functions**, the global functions of GDScript, are in `godot-utility`: `(randf-range 150.0 250.0)`, `(push-error "no mob scene")`, `(is-instance-valid node)`. Those named like a Common Lisp function (`sin`, `abs`, `min`, …) are left out, since Lisp has them, except `print`, which is `godot-print`, as it prints to Godot's output.

Supported types, converted between Godot and Lisp:

| Godot | Lisp |
|---|---|
| bool, int (also enums), float | `t`/`nil`, integers, floats |
| String | strings |
| Vector2, Vector2i, Vector3, Vector3i, Vector4, Vector4i, Rect2, Rect2i, Color, Plane, Quaternion, AABB, Basis, Transform2D, Transform3D, Projection | Lisp structs: `vector2`, `vector2i`, …, `transform3d`, `projection` (see Builtin types) |
| RID | `rid`, with the ID as `rid-id` |
| Object | its Lisp object (see Objects); `nil` is null |
| StringName, NodePath | arguments: a string, or `(gdext:sname "x")` and `(gdext:npath "a/b")` (see below); results: strings |
| Callable (arguments only) | a `callable` from `gd-extension-types`: a target object and a Lisp function |
| PackedByteArray, PackedInt32Array, PackedInt64Array, PackedFloat32Array, PackedFloat64Array | specialized vectors, such as `(simple-array single-float (*))`, copied as they are; arguments can be any sequence |
| PackedStringArray, PackedVector2Array, PackedVector3Array, PackedVector4Array, PackedColorArray | simple vectors of strings and structs; arguments can be any sequence |
| Array (also typed, `Array[Node]`) | a simple vector; arguments can be any sequence |
| Dictionary | an `equal` hash table |
| Variant | converted by its type, as above |

Arrays and dictionaries are copies: changing the Lisp vector or hash table doesn't change Godot's. As Variants, a simple vector becomes an Array, a specialized vector the matching packed array, and a hash table a Dictionary. A few methods with other types (Callable results) are skipped for now, and give an error when your code is compiled if you ask for them with `define-engine-method`.

`define-engine-method` defines a function for one method, under a name you choose. Its hash and signature are looked up in `extension_api.json` when your code is compiled. It can also give a vararg method's extra arguments fixed types:

```lisp
(gdext:define-engine-method emit-hit ("Object" "emit_signal")
  :extra-arguments ((damage :int)))
```

## Objects

Every Godot object you get in Lisp has one Lisp object, a `gdext:godot-object`, so the same object is always the same (`eq`) Lisp object. An instance of one of your classes has the struct its class defines (`player` above), which includes `godot-object`, so wherever it comes back, e.g. from `get_node`, you can call your own functions on it. `nil` is null.

Lisp objects have types that mirror Godot's classes: `define-engine-class` defines a struct for each class, named like it (`node-2d`, `canvas-item`, `node`, …), which includes that of the nearest class it inherits from. So `(typep body 'rigid-body-2d)`, `typecase` and `defmethod` work on Godot objects, also on your classes' instances, which have the type of the engine class they inherit from too. An object of a class that isn't defined in Lisp has the type of the nearest class it inherits from that is. Define the engine classes you use after those they inherit from.

When Godot frees an object, its Lisp object becomes invalid: using it signals an error instead of crashing. `(gdext:valid-object-p object)` tells whether it still exists, like `is_instance_valid` in GDScript.

For dropping down: an Object argument of an engine method also takes a Godot object pointer (but a Variant isn't made from one, as it might point to something else, such as a StringName), `gdext:object-pointer` gives the pointer of a Lisp object, and `gdext:lisp-object` the Lisp object of a pointer.

## Builtin types

Godot's builtin types are Lisp structs, made with a function named like the type, which takes the components as in GDScript: `(vector2 1.0 2.0)`, `(color 1.0 0.5 0.0)`, `(transform2d x-axis y-axis origin)`. The components are accessors named like them, such as `vector2-x` and `color-a`; float components are single-floats, and the constructors take any real. Vector2, Vector3 and Basis also have functions named like Godot's methods, computed in Lisp without calls into Godot:

```lisp
(vector2 1.0 2.0)                        ; Vector2(1.0, 2.0)
(vector2-x v)                            ; v.x
(vector2* (vector2-normalized v) speed)  ; v.normalized() * speed
(vector3-cross a b)                      ; a.cross(b)
(basis-looking-at direction)             ; Basis.looking_at(direction)
```

A `basis` is made from its columns, `(basis x y z)`, and `basis-x` etc. are its columns, as `basis.x` in GDScript; so are those of `transform2d` and `projection`. `(basis)`, `(transform2d)`, `(transform3d)`, `(projection)` and `(quaternion)` are the identity. See the package `gd-extension-builtins` for all the functions.

## StringNames and NodePaths

A literal string given for a StringName or NodePath argument, as in `(input-is-action-pressed "ui_up")`, becomes a StringName created once, when the code is compiled. A string that's only known at runtime becomes a temporary one for the call. To make your own, `(gdext:sname "move_right")` is a StringName created once, like `SNAME()` in Godot's C++ code, and `(gdext:npath "AnimatedSprite2D")` a NodePath created once. `(gdext:singleton "Input")` is an engine singleton, looked up the first time it's used.

## Signals

`connect-signal` connects a signal to a Lisp function. `after-signal` runs code once, the next time a signal is emitted, for what GDScript does with `await`:

```lisp
(gdext:connect-signal button "pressed" (lambda () (start-game main)))

(gdext:after-signal ((node-get-node hud "MessageTimer") "timeout" :target hud)
  (canvas-item-show (node-get-node hud "StartButton")))
```

The connection is bound to a target object, by default the one emitting the signal, and goes away when that object is freed.

## References

An engine method that returns a RefCounted object, such as a Resource, returns it with a reference, like a `Ref<T>` in C++.

- In code that Godot calls (your methods, virtual methods, signal handlers and initialize hooks) you needn't care: the reference goes into an autorelease pool and is given back when the call returns.
- To keep the object longer, e.g. in a slot, take a reference of your own with `setf-reference`, which works like assigning a `Ref<T>`: `(gdext:setf-reference (main-mob-scene main) scene)`. An exported slot with a RefCounted `:class` does that by itself.
- `(gdext:with-reference (frames (animated-sprite-2d-get-sprite-frames sprite)) ...)` gives the reference back at the end of its body.
- Outside a call from Godot, e.g. at a REPL, there's no pool: give the reference back with `release-reference` or `with-reference`.

## The lower level

`define-class` is built on functions you can also call yourself, e.g. for classes defined at runtime: `register-class`, `bind-method`, `bind-property`, `bind-signal`, `bind-virtual` and `register-singleton`. Types are given as in `define-class` (see `variant-type`). `with-string-name` and `with-string` create and destroy Godot StringNames and Strings; `get-method-bind` looks up a method to call with `object-method-bind-ptrcall` from `gd-extension-ffi`; and `cast-pointer`, `foreign-ref` and `clear-foreign-object` help with foreign memory. See their docstrings.

## Testing gdecl

```sh
make test        # in gdecl: build the test project in test/ and run the tests in Godot, headless
make bench       # time calls between Lisp and Godot, and the same calls in GDScript
```

The tests are a small gdecl application in `test/`: Lisp classes that the GDScript script `test/project/run_tests.gd` uses from Godot, and tests written in Lisp that call Godot. The run fails if a test fails, Godot crashes, or Godot reports leaks when it exits; the whole output is in `test/build/test.log`.

## License

MIT, see `LICENSE`.
