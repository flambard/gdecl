# gdecl

gdecl is a framework for programming [Godot](https://godotengine.org) 4 with Common Lisp, using [Embeddable Common Lisp](https://ecl.common-lisp.dev) (ECL). Your Lisp code is compiled into a GDExtension library. A small C bootstrap boots ECL inside Godot, and from then on everything is done from Lisp: it looks up the GDExtension interface functions, registers classes, methods, properties and signals, and handles Godot's callbacks.

gdecl is a proof of concept. Its API is incomplete and will change.

## Goals

GDExtension is a low-level C interface, not meant to be used directly by application developers. gdecl builds higher-level, Lisp-style APIs on top of it, step by step, with the aim of making Godot as easy to program in Lisp as in GDScript or C#, and taking inspiration from both. Since Godot is mostly used for games, the higher-level APIs must stay efficient: work such as looking up methods is done once rather than per call, and code called every frame shouldn't allocate.

The lower layers stay available, so you can drop down to them for what the higher ones don't cover yet, or for performance-critical code.

The long-term idea is to integrate Godot's classes with CLOS: define Godot classes with `defclass`-like forms, implement virtual methods such as `_process` with `defmethod`, and use generated Lisp classes for Godot's own classes. This would probably be a third package, built on `gd-extension`.

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

**Classes.** Define your classes with `define-class`, which registers them when Godot loads the extension:

```lisp
(gdext:define-class player ("Player" "Area2D")
  ((speed 400 :export :int)            ; @export var speed = 400
   screen-size)                        ; var screen_size
  (:signal "hit")
  (:method "start" player-start :arguments (("pos" :vector2)))
  (:virtual "_process" player-process))

(defun player-process (player delta)
  ...)
```

**The entry point.** Your code is loaded when Godot loads the extension, but it can't call Godot yet at that point. If you need to run something once gdecl is set up and your classes are registered, register a function for it:

```lisp
(defun start ()
  ...)

(gdext:add-initialize-hook 'start)
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

- **`gd-extension`** (nickname `gdext`): the Lisp-style API.
  - `add-initialize-hook` registers your entry point, and `add-deinitialize-hook` a function to run when Godot unloads the extension.
  - `with-string-name` and `with-string` create Godot StringNames and Strings, and destroy them again.
  - `vector2` and `rect2` (re-exported from `gd-extension-types`) are Lisp versions of Godot's Vector2 and Rect2: `(vector2 1.0 2.0)`, `(vector2-x v)`, `(rect2-size r)`, with `vector2+`, `vector2*`, `vector2-length`, `vector2-normalized`, `vector2-rotated` and `vector2-clamp`.
  - `define-engine-class` defines a function for each method of an engine class, named `<class>-<method>` in Lisp style, in the package `godot` (see below): `(define-engine-class "AnimatedSprite2D")` defines `godot:animated-sprite-2d-play`, `animated-sprite-2d-set-animation`, and so on. Only the methods the class itself defines get functions, so a Sprite2D's position is `node-2d-get-position`, as Node2D defines `get_position`. Methods with types that aren't supported yet are skipped (see `define-engine-method`). The most used classes are already defined; define the others your application uses, and they're added to `godot`. Each class adds to the build time and the size of the library (about 70 ms and 15 KB per method), so define those you use.
  - `define-engine-method` defines a Lisp function that calls a Godot method. Its hash and signature are looked up in `extension_api.json` when your code is compiled:
    ```lisp
    (define-engine-method is-action-pressed ("Input" "is_action_pressed"))

    (is-action-pressed "ui_up")
    ```
    The function takes the Godot object, as a pointer or the Lisp object of an instance, and then the method's arguments, named as in Godot. A static method has no object argument, and neither has a method of an engine singleton's class, such as Input above: it's called on the singleton. A StringName or NodePath argument can be a literal string, as `"ui_up"` above: it's turned into `(sname "ui_up")` when the code is compiled, so it's created once. A string that's only known at runtime, e.g. an animation name you picked, is turned into a temporary StringName or NodePath for that call. Otherwise, pass StringNames and NodePaths, e.g. from `sname` or `npath`, or ones Godot gave you. Arguments with default values are optional (`exact-match` above), if the default can be written in Lisp. The class can also be one that inherits the method, e.g. `("Sprite2D" "get_position")`. Supported types so far: bool, int (also enums), float, Vector2, String (a Lisp string), Object, StringName, NodePath and Callable (arguments), Rect2 and PackedStringArray (results; a PackedStringArray is a list of strings), and Variant. An Object is a Godot object pointer or the Lisp object of an instance, and `nil` is null. A Variant argument is made from the Lisp value by its type: `t`/`nil` (bool), integer, real, string, `vector2`, `rect2`, an object, or a `callable`; a Variant result is converted by its type. Other types give an error when the code is compiled. Vararg methods such as `emit_signal` and `call_group` are called with Variants, and their functions take any number of further arguments, converted the same way: `(object-emit-signal player "hit" damage)`. To give them fixed types instead, declare them with `:extra-arguments`, e.g. `(define-engine-method emit-hit ("Object" "emit_signal") :extra-arguments ((damage :int)))`.
  - An engine method that returns a RefCounted object, such as a Resource, returns it with a reference you own, like a `Ref<T>` in C++. Give it back with `release-reference`, or use `(with-reference (frames (get-sprite-frames sprite)) ...)`. To keep a RefCounted object you got another way, e.g. as a bound method's argument, take a reference with `add-reference`. `(setf-reference (main-mob-scene main) scene)` sets a place that keeps a reference, like assigning a `Ref<T>`: it takes a reference to the new value and gives back the old one.
  - `connect-signal` connects a signal to a Lisp function, through a Godot Callable that calls it. `after-signal` runs code once, the next time a signal is emitted, for what GDScript does with `await`:
    ```lisp
    (after-signal ((node-get-node hud "MessageTimer") "timeout" :target hud)
      (canvas-item-show (node-get-node hud "StartButton")))
    ```
    The connection is bound to a target object (by default the one emitting the signal), and goes away when that object is freed.
  - `(sname "move_right")` is a StringName created once, like `SNAME()` in Godot's C++ code, `(npath "AnimatedSprite2D")` a NodePath created once, and `(singleton "Input")` an engine singleton, looked up once, e.g. for the methods it inherits from Object.
  - `get-method-bind` looks up a Godot method, so you can call it with `object-method-bind-ptrcall`.
  - `define-class` defines a class in one form: `(define-class player ("Player" "Area2D") slots options...)` is the class `Player`, which inherits from `Area2D`, and `player` the struct of its instances' Lisp objects (see `register-class`), with the slots, as in `defstruct`. A slot `(speed 400 :export :int)` is also a property, like `@export var speed = 400`, with the methods `get_speed` and `set_speed`; `:class` is as in `bind-property`; if it's a RefCounted class, such as `"PackedScene"`, the slot keeps a reference to its value, like a `Ref<T>`, given back when the instance is freed. `:setter` is a function of your own for setting it, which then handles references itself. The options are `(:signal name (argument type)...)`, `(:method name function :arguments ((name type)...) :return-type type)`, `(:virtual name function)`, `(:destructor function)` and `(:tool t)`, as in the functions below. Functions are given by name, and called with the instance's Lisp object; redefining one takes effect right away. The classes are registered when Godot loads the extension, in the order they're defined, before your initialize hooks run.
  - `register-class` registers a class that inherits from a Godot class, e.g. `(register-class "Player" "Area2D")`. Like a GDScript script without `@tool`, its code doesn't run in the editor, unless you pass `:tool t`. Each instance gets a Lisp object, a `godot-object`, made by the class's constructor: usually a struct of your own that includes it, e.g. `(defstruct (player (:include godot-object)) speed)` and `:constructor (lambda (pointer) (make-player :pointer pointer))`; without a constructor, a plain `godot-object`. Bound methods get it as their first argument, like `self`, and Godot gives you it instead of the object pointer wherever an instance of your class comes back, e.g. from `get_node`, so you can call another class's Lisp functions on it directly. Engine methods and anything else that takes a Godot object take either a `godot-object` or a pointer (`object-pointer` gives the pointer), so you can write `(hide player)`. `lisp-object` gives the Lisp object of a pointer, and `instance-object` that of an instance pointer.
  - `bind-virtual` implements a virtual method such as `_ready` or `_process` for your class: `(bind-virtual "Player" "_process" #'player-process)`. Its signature is looked up in `extension_api.json` when your code is compiled, in the engine class your class inherits from, so `player-process` gets `delta` as a float.
  - `bind-method`, `bind-property` and `bind-signal` register your class's methods, properties and signals, e.g. `(bind-signal "Player" "hit")` for a signal without arguments, or `(bind-method "Player" "start" #'player-start :arguments '(("pos" :vector2)))`. Types are keywords named like Godot's variant types (`:int`, `:float`, `:vector2`, `:string-name`, `:object`, …, see `variant-type`). Bound methods can take and return `bool`, `int`, `float`, `vector2`, strings (Godot's String) and Objects (as Godot object pointers, or the Lisp objects of your classes' instances; `null` is `nil`). For an Object property, `bind-property` takes the class of its value, e.g. `(bind-property "Main" "mob_scene" :object "get_mob_scene" "set_mob_scene" :class "PackedScene")` for a property like `@export var mob_scene: PackedScene`; the editor then lets you pick a resource of that class, or a node if it's a Node class. For other hints, it takes `:hint` and `:hint-string`, as in Godot's PropertyHint.
  - `cast-pointer`, `foreign-ref` and `clear-foreign-object` help with foreign memory (re-exported from `gd-extension-ffi`).
- **`godot`** (nickname `gd`): Godot's API in Lisp: the builtin types `vector2` and `rect2` with their functions (the same as in `gd-extension`), and functions for the methods of engine classes, made with `define-engine-class`. gdecl defines the classes most applications use: Object, RefCounted, Resource, Node, CanvasItem, Node2D, SceneTree, Input, Timer and PackedScene; the classes your application defines are added to it. E.g. `(node-get-node main "HUD")`, `(canvas-item-hide player)`, `(object-emit-signal player "hit")`, `(timer-start timer)`. Use it in your package: `(defpackage #:my-app (:use #:cl #:godot))`, or write `gd:node-get-node`.
- **`gd-extension-ffi`** (nickname `gdext-ffi`): the GDExtension C interface, mapped one-to-one. It contains the interface functions (`classdb-register-extension-class2`, `object-method-bind-ptrcall`, …), the enums (`+variant-type-float+`, …) and Lisp mirrors of the C structs. Use it for anything the `gd-extension` package doesn't cover yet.
- **`gd-extension-types`** (nickname `gdext-types`): Godot's builtin types in Lisp, and converting them to and from raw values. `gd-extension` re-exports the parts applications use.
- **`gd-extension-callback`** (nickname `gdext-callback`): what runs when Godot calls into Lisp, such as creating instances of your classes and calling your bound methods. Used by `gd-extension`; applications don't need it.
- **`gdecl-json`**: a small JSON reader, used to read `extension_api.json` when your code is compiled.

## License

MIT, see `LICENSE`.
