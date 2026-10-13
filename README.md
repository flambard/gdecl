# gdecl

gdecl is a framework for programming [Godot](https://godotengine.org) 4 with Common Lisp, using [Embeddable Common Lisp](https://ecl.common-lisp.dev) (ECL). Your Lisp code is compiled into a GDExtension library. A small C bootstrap boots ECL inside Godot, and from then on everything is done from Lisp: it looks up the GDExtension interface functions, registers classes, methods, properties and signals, and handles Godot's callbacks.

gdecl is a proof of concept. Its API is incomplete and will change.

## Goals

GDExtension is a low-level C interface, not meant to be used directly by application developers. gdecl builds higher-level, Lisp-style APIs on top of it, step by step, with the aim of making Godot as easy to program in Lisp as in GDScript or C#, and taking inspiration from both. Since Godot is mostly used for games, the higher-level APIs must stay efficient: work such as looking up methods is done once rather than per call, and code called every frame shouldn't allocate.

The lower layers stay available, so you can drop down to them for what the higher ones don't cover yet, or for performance-critical code.

The long-term idea is to integrate Godot's classes with CLOS: define Godot classes with `defclass`-like forms, implement virtual methods such as `_process` with `defmethod`, and use generated Lisp classes for Godot's own classes.

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

Types are keywords named like Godot's variant types: `:bool`, `:int`, `:float`, `:string`, `:vector2`, `:rect2`, `:vector3`, `:basis` and `:object` can be arguments and results of methods.

**The entry point.** Your code is loaded when Godot loads the extension, but it can't call Godot yet at that point. To run something once gdecl is set up and your classes are registered, add an initialize hook. `add-deinitialize-hook` adds one for when Godot unloads the extension.

```lisp
(gdext:add-initialize-hook 'start)
```

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
| Vector2, Rect2, Vector3, Basis | `vector2`, `rect2`, `vector3`, `basis` |
| Object | the Lisp object of your class's instance, or a Godot object pointer; `nil` is null |
| StringName, NodePath (arguments only) | a string, or `(gdext:sname "x")` and `(gdext:npath "a/b")` (see below) |
| Callable (arguments only) | a `callable` from `gd-extension-types`: a target object and a Lisp function |
| PackedStringArray (results only) | a list of strings |
| Variant | converted by its type, as above |

Methods with other types are skipped for now, and give an error when your code is compiled if you ask for them with `define-engine-method`.

`define-engine-method` defines a function for one method, under a name you choose. Its hash and signature are looked up in `extension_api.json` when your code is compiled. It can also give a vararg method's extra arguments fixed types:

```lisp
(gdext:define-engine-method emit-hit ("Object" "emit_signal")
  :extra-arguments ((damage :int)))
```

## Objects

An instance of one of your classes has a Lisp object (`player` above), a struct that includes `gdext:godot-object`. Godot gives you that Lisp object wherever an instance of your class comes back, e.g. from `get_node`, so you can call your own functions on it. Other objects are Godot object pointers. Anything that takes an object takes either one, and `nil` is null. `gdext:object-pointer` gives the pointer of either, and `gdext:lisp-object` the Lisp object of a pointer.

## Builtin types

`vector2`, `rect2`, `vector3` and `basis` are Lisp structs, with functions named like Godot's methods, computed in Lisp without calls into Godot:

```lisp
(vector2 1.0 2.0)                        ; Vector2(1.0, 2.0)
(vector2-x v)                            ; v.x
(vector2* (vector2-normalized v) speed)  ; v.normalized() * speed
(vector3-cross a b)                      ; a.cross(b)
(basis-looking-at direction)             ; Basis.looking_at(direction)
```

A `basis` is made from its columns, `(basis x y z)`, and `basis-x` etc. are its columns, as `basis.x` in GDScript. `(basis)` is the identity. See the package `gd-extension-builtins` for all the functions.

## StringNames and NodePaths

A literal string given for a StringName or NodePath argument, as in `(input-is-action-pressed "ui_up")`, becomes a StringName created once, when the code is compiled. A string that's only known at runtime becomes a temporary one for the call. To make your own, `(gdext:sname "move_right")` is a StringName created once, like `SNAME()` in Godot's C++ code, and `(gdext:npath "AnimatedSprite2D")` a NodePath created once. `(gdext:singleton "Input")` is an engine singleton, looked up once.

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

`define-class` is built on functions you can also call yourself, e.g. for classes defined at runtime: `register-class`, `bind-method`, `bind-property`, `bind-signal` and `bind-virtual`. Types are given as in `define-class` (see `variant-type`). `with-string-name` and `with-string` create and destroy Godot StringNames and Strings; `get-method-bind` looks up a method to call with `object-method-bind-ptrcall` from `gd-extension-ffi`; and `cast-pointer`, `foreign-ref` and `clear-foreign-object` help with foreign memory. See their docstrings.

## Testing gdecl

```sh
make test        # in gdecl: build the test project in test/ and run the tests in Godot, headless
```

The tests are a small gdecl application in `test/`: Lisp classes that the GDScript script `test/project/run_tests.gd` uses from Godot, and tests written in Lisp that call Godot. The run fails if a test fails, Godot crashes, or Godot reports leaks when it exits; the whole output is in `test/build/test.log`.

## License

MIT, see `LICENSE`.
