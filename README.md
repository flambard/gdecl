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

**The entry point.** Your code is loaded when Godot loads the extension, but it can't call Godot yet at that point. Register a function to run once gdecl is set up. This is where you register your classes:

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
  - `define-engine-method` defines a Lisp function that calls a Godot method. Its hash and signature are looked up in `extension_api.json` when your code is compiled:
    ```lisp
    (define-engine-method is-action-pressed ("Input" "is_action_pressed"))

    (is-action-pressed (singleton "Input") "ui_up")
    ```
    The function takes the Godot object pointer (unless the method is static) and then the method's arguments, named as in Godot. A StringName or NodePath argument can be a literal string, as `"ui_up"` above: it's turned into `(sname "ui_up")` when the code is compiled, so it's created once. Other values for them must be StringNames and NodePaths, e.g. from `sname`, `npath` or `with-string-name`. Arguments with default values are optional (`exact-match` above), if the default can be written in Lisp. The class can also be one that inherits the method, e.g. `("Sprite2D" "get_position")`. Supported types so far: bool, int (also enums), float, Vector2, String (a Lisp string), StringName, NodePath, Callable and Variant (arguments; a Variant argument is converted from the Lisp value by its type: `t`/`nil`, integer, real or `vector2`), and Rect2, Object and PackedStringArray (results; an Object is a Godot object pointer, a PackedStringArray a list of strings). Other types give an error when the code is compiled. Vararg methods such as `emit_signal` are called with Variants; give the arguments after the declared ones with `:extra-arguments`, e.g. `(define-engine-method emit-hit ("Object" "emit_signal") :extra-arguments ((damage +variant-type-int+)))`.
  - An engine method that returns a RefCounted object, such as a Resource, returns it with a reference you own, like a `Ref<T>` in C++. Give it back with `release-reference`, or use `(with-reference (frames (get-sprite-frames sprite)) ...)`. To keep a RefCounted object you got another way, e.g. as a bound method's argument, take a reference with `add-reference`.
  - `connect-signal` connects a signal to a Lisp function, through a Godot Callable that calls it. `after-signal` runs code once, the next time a signal is emitted, for what GDScript does with `await`:
    ```lisp
    (after-signal ((get-node hud "MessageTimer") "timeout" :target hud)
      (show (get-node hud "StartButton")))
    ```
    The connection is bound to a target object (by default the one emitting the signal), and goes away when that object is freed.
  - `(sname "move_right")` is a StringName created once, like `SNAME()` in Godot's C++ code, `(npath "AnimatedSprite2D")` a NodePath created once, and `(singleton "Input")` an engine singleton, looked up once.
  - `get-method-bind` looks up a Godot method, so you can call it with `object-method-bind-ptrcall`.
  - `register-class` registers a class that inherits from a Godot class, e.g. `(register-class "Player" "Area2D")`. Like a GDScript script without `@tool`, its code doesn't run in the editor, unless you pass `:tool t`. Each instance gets a Lisp object, made by the class's constructor. Bound methods get it as their first argument, `instance-object` gives it from an instance pointer, and `lisp-object` from a Godot object pointer, e.g. a node from `get_node`, so Lisp code can call another class's Lisp functions directly.
  - `bind-virtual` implements a virtual method such as `_ready` or `_process` for your class: ``(bind-virtual "Player" "_process" #'player-process :arguments `(("delta" ,+variant-type-float+)))``, with the argument types from `extension_api.json`.
  - `bind-method`, `bind-property` and `bind-signal` register your class's methods, properties and signals, e.g. `(bind-signal "Player" "hit")` for a signal without arguments. Bound methods can take and return `bool`, `int`, `float`, `vector2`, strings (Godot's String) and Objects (as Godot object pointers; `null` is a NULL pointer). `bind-property` takes `:hint` and `:hint-string`, e.g. `+property-hint-resource-type+` and `"PackedScene"` for a property like `@export var mob_scene: PackedScene`.
  - `cast-pointer`, `foreign-ref` and `clear-foreign-object` help with foreign memory (re-exported from `gd-extension-ffi`).
- **`gd-extension-ffi`** (nickname `gdext-ffi`): the GDExtension C interface, mapped one-to-one. It contains the interface functions (`classdb-register-extension-class2`, `object-method-bind-ptrcall`, …), the enums (`+variant-type-float+`, …) and Lisp mirrors of the C structs. Use it for anything the `gd-extension` package doesn't cover yet.
- **`gd-extension-types`** (nickname `gdext-types`): Godot's builtin types in Lisp, and converting them to and from raw values. `gd-extension` re-exports the parts applications use.
- **`gd-extension-callback`** (nickname `gdext-callback`): what runs when Godot calls into Lisp, such as creating instances of your classes and calling your bound methods. Used by `gd-extension`; applications don't need it.
- **`gdecl-json`**: a small JSON reader, used to read `extension_api.json` when your code is compiled.

## License

MIT, see `LICENSE`.
