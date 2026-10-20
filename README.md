# gdecl

gdecl lets you program [Godot](https://godotengine.org) 4 games in Common Lisp. Your Lisp code runs in [Embeddable Common Lisp](https://ecl.common-lisp.dev) (ECL), compiled into a GDExtension library that Godot loads. A small C bootstrap starts ECL inside Godot; everything else, from registering classes to handling Godot's callbacks, is done in Lisp.

```lisp
(defclass player (area-2d)                           ; extends Area2D
  ((speed :initform 400 :export :int :reader speed)  ; @export var speed = 400
   (sprite :onready "AnimatedSprite2D" :reader sprite))
  (:metaclass godot-class)                           ; class_name Player
  (:signals (hit)))                                  ; signal hit

(defmethod ready ((player player))                   ; func _ready():
  (canvas-item-hide player))                         ;     hide()

(defmethod process ((player player) delta)           ; func _process(delta):
  (when (input-is-action-pressed "move_right")
    ...))
```

gdecl is a proof of concept. Its API is incomplete and will change. For a complete game, see [Dodge the Creeps in Common Lisp](https://github.com/flambard/gdecl_first_2d_game), Godot's "Your first 2D game" tutorial written with gdecl.

## Goals

- **As easy as GDScript or C#.** Godot's classes, inheritance, virtual methods, properties and signals should feel natural in Lisp. That's what CLOS gives: classes are `defclass`es, the methods Godot calls are `defmethod`s, and you can redefine classes in a running game.
- **Fast enough for games.** Work such as looking up methods is done once, when your code is compiled or loaded, not on every call, and code that runs every frame shouldn't allocate.
- **High level by default, low level where it matters.** When one method or one loop is too slow, you can drop down to a faster, lower-level way of writing just that part and keep the rest high-level.

## Requirements

- Godot 4.4 or later
- ECL, with `ecl-config` on your `PATH`
- GNU Make and a C compiler (clang is used if it's installed)

## Getting started

An application is a directory with gdecl in it (for example as a git submodule), its own ASDF system and a Godot project:

```
my-app/
  gdecl/              this framework
  lisp/my-app.asd     your ASDF system
  lisp/*.lisp         your code
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

**The package** uses Godot's API and `godot-clos`, gdecl's way of defining classes:

```lisp
(defpackage #:my-app
  (:use #:cl #:godot #:godot-utility #:godot-clos))
```

gdecl's own functions and macros are in `gd-extension`; refer to them with the prefix `gdext:`, as in `gdext:connect-signal`.

**The Makefile** names your ASDF system and where to put the library, and includes gdecl's rules:

```make
SYSTEM = my-app
LIBRARY = project/bin/libgdecl.so
include gdecl/gdecl.mk
```

You can also set `LISP_DIRS` (where your `.asd` and `.lisp` files are, default `lisp`), `BUILD_DIR` (default `build`), `GODOT` (the Godot executable, default `godot`), and the usual `CC` and `CFLAGS`.

**The `.gdextension` file** in your Godot project tells Godot where the library is. The entry symbol is always `gdecl_library_init`:

```ini
[configuration]

entry_symbol = "gdecl_library_init"
compatibility_minimum = "4.4"

[libraries]
linux.debug = "res://bin/libgdecl.so"
```

**Build** with `make`. The first time, it also runs Godot to generate `gdextension_interface.h` and `extension_api.json` in `gdecl/`, which gdecl needs.

```sh
make             # compile your Lisp code and gdecl into the library
make godot-api   # generate Godot's API files again, e.g. after upgrading Godot
make clean
```

Restart Godot to load a new build of the library.

## Defining classes

A Godot class is a `defclass` with the metaclass `godot-class`. It inherits from an engine class such as `area-2d`, or from another of your classes:

```lisp
(defclass player (area-2d)
  ((speed :initform 400 :export :int :reader speed)
   (screen-size :accessor screen-size)
   (sprite :onready "AnimatedSprite2D" :reader sprite))
  (:metaclass godot-class)
  (:signals (hit)))
```

The class is registered with Godot when Godot loads your library, as `Player`: the class name in Godot style. Its instances are Godot objects, so engine methods take them as they are, and `(make-instance 'player)` makes one in Godot.

Your classes can use everything CLOS has: inheritance, mixins (standard classes, listed before the engine class in the superclasses), `:before`, `:after` and `:around` methods, and `call-next-method`.

### Slots

A slot is plain CLOS (`:initform`, `:initarg`, `:accessor`), with three options of its own:

| Option | Like in GDScript | What it does |
|---|---|---|
| `:export type` | `@export var` | Makes the slot a property, which you can set in the editor. It gets the methods `get_<name>` and `set_<name>` (`mob-scene` is `mob_scene`) |
| `:class "PackedScene"` | `@export var x: PackedScene` | With `:export :object`: the class of the value, picked in the editor as a resource or a node |
| `:onready "Path"` | `@onready var x = $Path` | Sets the slot to that node when the instance is ready, before your `ready` method runs |
| `:onready function` | `@onready var x = …` | Sets the slot to the result of calling the function with the instance |

An exported slot whose `:class` is RefCounted, such as a `PackedScene`, holds a reference to its value (see References).

### Class options

| Option | What it does |
|---|---|
| `(:signals (hit) (damaged (amount :int)))` | Signals, like `signal hit` and `signal damaged(amount: int)` |
| `(:godot-name "Name")` | The class's name in Godot, if not the default (`player` is `Player`) |
| `(:tool t)` | Runs the class's code in the editor too, like `@tool`. Otherwise its instances in the editor are placeholders |
| `(:singleton t)` | Makes one instance and registers it as an engine singleton (see Singletons). `(:singleton "Name")` gives it another name |
| `(:direct-functions (process player-process))` | Makes Godot call a plain function for a virtual method, for speed (see Making hot code fast) |

### Methods that Godot calls

**Virtual methods**, such as `_ready` and `_process`, are generic functions you add methods to:

```lisp
(defmethod ready ((player player)) ...)          ; _ready
(defmethod process ((player player) delta) ...)  ; _process
```

gdecl defines `ready`, `process`, `physics-process`, `enter-tree`, `exit-tree`, `unhandled-input` and `draw`. Define others with `define-virtual-function`. Godot calls a virtual method only for the classes that have a method for it.

**Your own methods**, which GDScript and the editor's signal connections call by name, are declared with `define-godot-generic`, with their argument types:

```lisp
(define-godot-generic start (self (pos :vector2)))   ; func start(pos: Vector2)

(define-godot-generic on-body-entered (self (body :object))
  (:godot-name "_on_body_entered"))                  ; the name the editor connected

(defmethod start ((player player) pos) ...)
```

The method's name in Godot is its name in Godot style (`start`), unless you give `:godot-name`. `(:return-type :int)` gives it a result. A class gets the method in Godot if it has a method for it.

Types are keywords named like Godot's types, such as `:bool`, `:int`, `:float`, `:string`, `:vector2`, `:rect2`, `:vector3`, `:basis` and `:object`.

**Notifications** go to the generic function `notification`, like `_notification`. A class gets only the notifications its methods specialize on with `eql`, so the others cost nothing. To clean up before an object is freed:

```lisp
(defmethod notification ((player player) (what (eql +object-notification-predelete+)))
  ...)
```

A method that doesn't specialize `what` gets every notification, including those Godot sends every frame.

### Singletons and startup code

A class with `(:singleton t)` gets one instance, registered as an engine singleton named like the class. GDScript uses it by name, like `Input`, and in Lisp `(gdext:singleton "Game")` returns it.

The instance is made when Godot loads your library, after the classes defined before it are registered. So its `initialize-instance` method is the place for code that runs once at startup:

```lisp
(defclass game (object)
  ((score :initform 0 :accessor score))
  (:metaclass godot-class)
  (:singleton t))                                    ; Game, by name in GDScript

(defmethod initialize-instance :after ((game game) &key)
  (godot-print "Game loaded"))
```

A singleton class can't be RefCounted, and its subclasses aren't singletons. An engine singleton isn't in the scene tree, so it gets no `ready` or `process`. For that, make an autoload instead: a scene whose root node is of one of your classes, added under Autoload in the project settings.

Instead of a singleton, you can add a function to run at startup with `(gdext:add-initialize-hook 'start)`, and one to run when Godot unloads your library with `add-deinitialize-hook`. Your code can't call Godot while it's being loaded, only from then on.

### Redefining classes in a running game

Redefining a class, or adding a method, at a REPL updates the existing instances and registers what's new with Godot. Godot can't remove anything from a class or change its parent, though, and it won't call a virtual method that a class gets only after Godot first asked for it.

### Making hot code fast

Generic functions and CLOS accessors cost a little more than plain functions and struct accessors (see Performance). For code that runs every frame on many objects, you can drop down in two ways, for just that code.

**Call a plain function for a virtual method** with `:direct-functions`. Godot then calls the function directly, by name, instead of the generic function:

```lisp
(defclass mob (character-body-3d)
  (...)
  (:metaclass godot-class)
  (:direct-functions (physics-process mob-physics-process)))

(defun mob-physics-process (mob delta) ...)
```

The class's methods for `physics-process` are then not called from Godot. Subclasses inherit the option unless they give their own. It doesn't work for `ready`, which has to set the `:onready` slots first.

**Keep hot data in a struct**, in one slot of the object. Hot code then makes one generic accessor call to get the struct, and uses the struct's faster accessors from there:

```lisp
(defstruct motion
  (velocity (vector3))
  (distance 0d0))

(defclass mob (character-body-3d)
  ((motion :initform (make-motion) :reader mob-motion))
  (:metaclass godot-class)
  (:direct-functions (physics-process mob-physics-process)))

(defun mob-physics-process (mob delta)
  (let ((motion (mob-motion mob)))           ; one generic accessor
    (incf (motion-distance motion) delta)    ; struct accessors from here
    ...))
```

Exported slots, the properties Godot sees, stay slots of the class.

### `define-class`: the lower-level way

`define-class`, in the package `godot-dsl`, is an older, smaller way to define a class in one form, like a GDScript script. It's faster than CLOS, but has no inheritance between your classes and can't be redefined in a running game, and it gets no new features. Use `godot-clos` unless you need it.

```lisp
(define-class player ("Player" "Area2D")             ; class_name Player extends Area2D
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

`player` is a struct, as with `defstruct`: `(player-speed player)`. Each function is called with the instance first, like `self`. Functions are called by name, so redefining one takes effect right away.

Slots have the options of `godot-clos` slots, and also `:setter function`, like `set(value):` in GDScript, a setter of your own called with the instance and the value, which then handles references itself. Class options:

| Option | What it does |
|---|---|
| `(:signal name (argument type)... :emitter emitter)` | A signal. `:emitter emit-hit` also defines a fast emitter (see Signals) |
| `(:method name function :arguments ((name type)...) :return-type type)` | A method Godot can call |
| `(:virtual name function)` | A virtual method such as `"_ready"` or `"_process"`. Its signature comes from the engine class, so `_process` gets `delta` as a float |
| `(:destructor function)` | Called with the instance when Godot frees it. The Godot object is being destroyed then, so don't call Godot with it |
| `(:tool t)`, `(:singleton t)` | As for `godot-clos` |

## Calling Godot

Engine methods are functions in `godot`, named `<class>-<method>`, with the object first:

```lisp
(node-get-node main "HUD")                   ; $HUD
(canvas-item-hide player)                    ; hide()
(node-2d-set-position player (vector2 100.0 200.0))
(timer-start timer)
(input-is-action-pressed "ui_up")            ; Input is a singleton: no object
```

- **The class in the name is the one that defines the method**, not one that inherits it: a Sprite2D's position is `node-2d-get-position`.
- **Add the engine classes you use** with `(define-engine-class "AnimatedSprite2D")`. gdecl defines only Object, RefCounted, Resource, Node, CanvasItem, Node2D, Node3D, SceneTree, Input, Timer and PackedScene. Every method adds to build time and library size, so add only what you use, and add a class after the classes it inherits from.
- **Arguments** are named as in Godot. Those with a default value are optional, when the default can be written in Lisp. Static methods and methods of singletons, such as Input's, take no object.
- **Vararg methods**, such as `emit_signal` and `call_group`, take any number of further arguments, converted by their Lisp types: `(object-emit-signal player "hit" damage)`.
- **Enums and constants** are Lisp constants: `Node.PROCESS_MODE_ALWAYS` is `+node-process-mode-always+`, `OK` is `+ok+`, `KEY_ESCAPE` is `+key-escape+`.
- **Utility functions**, GDScript's global functions, are in `godot-utility`: `(randf-range 150.0 250.0)`, `(push-error "no mob scene")`, `(is-instance-valid node)`. Those Lisp already has (`sin`, `abs`, `min`, …) are left out. `print` is `godot-print`, since it prints to Godot's output.

### Types

Values are converted between Godot and Lisp like this:

| Godot | Lisp |
|---|---|
| null | `nil` (as a Variant, write `:null`, since `nil` is false) |
| bool, int (also enums), float | `t`/`nil`, integers, floats |
| String | strings |
| StringName, NodePath | strings (see StringNames and NodePaths) |
| Vector2, Vector3, Color, Transform2D, Basis, … | structs: `vector2`, `vector3`, `color`, `transform2d`, `basis`, … (see Builtin types) |
| RID | `rid`, with the ID as `rid-id` |
| Object | its Lisp object, or `nil` for null (see Objects) |
| Callable | a `gdext:callable` or `gdext:engine-callable` (see Callables) |
| Signal | a `gdext:engine-signal` (see Callables) |
| Packed arrays of numbers | specialized vectors, such as `(simple-array single-float (*))` |
| Other packed arrays, and Arrays (also typed) | simple vectors |
| Dictionary | an `equal` hash table |
| Variant | converted by its type, as above |

The builtin structs are Vector2, Vector2i, Vector3, Vector3i, Vector4, Vector4i, Rect2, Rect2i, Color, Plane, Quaternion, AABB, Basis, Transform2D, Transform3D and Projection, each named like its type in Lisp style.

Arrays and Dictionaries are copies: changing the Lisp vector or hash table doesn't change Godot's. Where Godot takes an array, you can pass any sequence. As Variants, a simple vector becomes an Array, a specialized vector the matching packed array, and a hash table a Dictionary.

A few methods have types gdecl can't convert yet, such as raw pointers. They're left out, and `define-engine-method` (see Faster engine calls) signals an error for them when your code is compiled.

## Objects

Every Godot object has exactly one Lisp object, so you get the same (`eq`) Lisp object each time. An instance of one of your classes is the instance you defined, so wherever it comes back from, such as `get_node`, you can call your own methods on it.

The Lisp objects' types follow Godot's classes: `define-engine-class` defines a struct named like the class (`node-2d`, `canvas-item`, …) that includes the struct of its parent class. So `typep`, `typecase` and `defmethod` work on Godot objects: `(typep body 'rigid-body-2d)`. An object of a class you haven't defined has the type of its nearest defined parent class.

- `(gdext:make-object "Sprite2D")` makes an object, like `Sprite2D.new()`, of an engine class or one of yours.
- `(gdext:free-object sprite)` frees it, like `free()`. RefCounted objects are freed when their last reference is given back instead (see References).
- `(gdext:valid-object-p object)` tells whether the object still exists, like `is_instance_valid`. Using an object that Godot has freed signals an error instead of crashing.

`(gdext:singleton "Input")` returns an engine singleton, looked up the first time it's used.

For dropping down, `gdext:object-pointer` gives a Lisp object's Godot pointer, and `gdext:lisp-object` the Lisp object of a pointer. Engine methods also accept raw pointers for Object arguments.

## Builtin types

Godot's builtin types are Lisp structs, made with a function named like the type, with the same arguments as in GDScript:

```lisp
(vector2 1.0 2.0)                        ; Vector2(1.0, 2.0)
(vector2-x v)                            ; v.x
(vector2* (vector2-normalized v) speed)  ; v.normalized() * speed
(vector3-cross a b)                      ; a.cross(b)
(basis-looking-at direction)             ; Basis.looking_at(direction)
(color 1.0 0.5 0.0)                      ; Color(1.0, 0.5, 0.0)
```

- Components are accessors named like them, such as `vector2-x` and `color-a`. They're single-floats, but the constructors take any real.
- Vector2, Vector3 and Basis also have functions named like Godot's methods, computed in Lisp without calling Godot. The other types have only their constructors and accessors so far. See the package `gd-extension-builtins` for everything there is.
- A `basis` is made from its columns, `(basis x y z)`, and `basis-x` etc. are its columns, as `basis.x` in GDScript. The same goes for `transform2d` and `projection`.
- `(basis)`, `(transform2d)`, `(transform3d)`, `(projection)` and `(quaternion)` are the identity.

## StringNames and NodePaths

You pass StringNames and NodePaths as strings: `(input-is-action-pressed "ui_up")`. A literal string like that is turned into a StringName once, when your code is compiled. A string that's only known at run time becomes a temporary StringName for each call, which is slower.

To make your own, `(gdext:sname "move_right")` is a StringName created once, like `SNAME()` in Godot's C++ code, and `(gdext:npath "AnimatedSprite2D")` a NodePath created once.

## Signals

Declare a class's signals with `:signals`, and emit one with `object-emit-signal`:

```lisp
(object-emit-signal player "hit")
(object-emit-signal player "damaged" 5)
```

For a signal emitted often, define an emitter. It knows the argument types when your code is compiled, so it's about twice as fast and allocates nothing:

```lisp
(gdext:define-signal-emitter emit-damaged "damaged" ((amount :int)))

(emit-damaged player 5)
```

Emitters return the `Error` of `emit_signal`.

Connect a signal to a Lisp function with `gdext:connect-signal`. `after-signal` runs code once, the next time a signal is emitted, which is what GDScript does with `await`:

```lisp
(gdext:connect-signal button "pressed" (lambda () (start-game main)))

;; await $MessageTimer.timeout
(after-signal ((node-get-node hud "MessageTimer") "timeout" :target hud)
  (canvas-item-show (node-get-node hud "StartButton")))
```

A connection belongs to a target object, by default the one emitting the signal, and goes away when that object is freed.

## Callables

A Callable you make in Lisp, `(gdext:callable target function)`, comes back from Godot as the same `callable`. Any other Callable, such as a GDScript lambda passed to your method, is an `engine-callable`. Call either with `call-callable`, and compare them with `callable=`:

```lisp
(define-godot-generic apply-twice (self (function :callable) (value :int))
  (:return-type :int))

;; From GDScript: node.apply_twice(func(x): return x * 2, 3) is 12
(defmethod apply-twice ((node my-node) function value)
  (gdext:call-callable function (gdext:call-callable function value)))
```

An `engine-callable` is valid only until the call from Godot it came in returns. To keep it longer, for example in a slot, make your own copy with `keep-callable`, and free that with `free-callable` when you're done. At a REPL, outside a call from Godot, free them yourself.

A Signal value is an `engine-signal`: an object and a signal name (`engine-signal-object`, `engine-signal-name`). Make one with `(gdext:engine-signal object "name")`, emit it with `emit-engine-signal`, and connect it with `connect-engine-signal`.

## References

An engine method that returns a RefCounted object, such as a Resource, returns it with a reference, like a `Ref<T>` in C++.

- **In code that Godot calls** (your methods, signal handlers, startup code), you don't need to do anything. The reference is given back when the call returns.
- **To keep the object longer**, for example in a slot, take a reference of your own with `setf-reference`, which works like assigning a `Ref<T>`: `(gdext:setf-reference (main-mob-scene main) scene)`.
- **An exported slot with a RefCounted `:class`** does that for you when its value is set through the property, its initform or an initarg. If you `setf` the slot yourself, use `setf-reference` instead.
- **For a short while**, `(gdext:with-reference (frames (animated-sprite-2d-get-sprite-frames sprite)) ...)` gives the reference back at the end of its body.
- **At a REPL**, outside a call from Godot, give references back yourself, with `release-reference` or `with-reference`.

RefCounted objects you make with `make-object` or `make-instance` come with a reference in the same way.

## Faster engine calls

`define-engine-method` defines a function for one engine method, under a name you choose. It can give a vararg method's further arguments fixed types:

```lisp
(gdext:define-engine-method emit-with-int ("Object" "emit_signal")
  :extra-arguments ((value :int)))
```

That's faster for a call made every frame. When the arguments are simple types (bool, int, float, an object, a StringName or NodePath, or a builtin type such as `Vector2`) and the result is nothing, a bool, an int or a float, the call allocates nothing.

`:into` makes a method that returns a builtin type, such as `Vector2`, store the result into a struct you pass, instead of making a new one on every call:

```lisp
(gdext:define-engine-method get-position-into ("Node2D" "get_position") :into t)

(let ((position (vector2)))
  ;; every frame
  (get-position-into position node))   ; returns POSITION
```

The struct comes first, like the result sequence of `map-into`. A nested struct, such as the `position` of a `rect2`, is changed in place, so don't share it. All the method's arguments must be simple types.

Put such definitions in a file of their own, loaded before the code that calls them. Otherwise literal names, such as `"hit"`, become a new StringName on every call.

## Performance

Calls between Lisp and Godot cost more than within GDScript, but not much more. Some typical times, from `make bench`:

| Call | gdecl | GDScript |
|---|---|---|
| An engine method from Lisp, with simple types | 60–80 ns | 17–30 ns |
| Godot calling an empty method of yours | 0.15 µs | 90 ns |
| An empty `_process`, with `:direct-functions` | 0.2 µs | 90 ns |
| A signal to a Lisp handler | 0.3–0.4 µs | 0.23–0.26 µs |
| `object-emit-signal` | 0.27 µs | 35 ns |
| `define-signal-emitter` | 0.12 µs | |

A generic function adds about 0.2 µs to a call from Godot, about 0.2 ms a frame for 1,000 objects with `process`. An `incf` through a CLOS accessor takes about 80 ns, against 25 ns through a struct accessor. When that matters, drop down (see Making hot code fast).

## Packages

| Package | Nickname | What it is |
|---|---|---|
| `godot` | `gd` | Godot's API: engine methods, enums and constants, builtin types, and `define-engine-class` |
| `godot-utility` | `gd-util` | Godot's utility functions, such as `randf-range` |
| `godot-clos` | | Classes as CLOS classes |
| `gd-extension` | `gdext` | gdecl itself: signals, references, objects, `define-engine-method`, and registering classes by hand |
| `godot-dsl` | | `define-class`, the lower-level way to define classes |
| `gd-extension-ffi` | `gdext-ffi` | The GDExtension C interface, for what the others don't cover yet |

The other packages are gdecl's internals. Each package is a layer, in a directory of its own in `lisp/`, built on the layers below it (see `CLAUDE.md`).

## The lower level

The class layers are built on functions you can also call yourself, for example to define classes at run time: `register-class` (with notifications, see `set-class-notifications`), `bind-method`, `bind-property`, `bind-signal`, `bind-virtual` and `register-singleton`. Types are given as in `variant-type`. `with-string-name` and `with-string` make Godot StringNames and Strings for the length of their body. `get-method-bind` looks up a method to call with `object-method-bind-ptrcall` from `gd-extension-ffi`, and `cast-pointer`, `foreign-ref` and `clear-foreign-object` help with foreign memory. See their docstrings.

## Testing gdecl

```sh
make test        # build the test project in test/ and run the tests in Godot, headless
make bench       # time calls between Lisp and Godot, and the same calls in GDScript
```

The tests are a small gdecl application in `test/`. A GDScript script, `test/project/run_tests.gd`, tests Lisp classes from Godot, and tests written in Lisp call Godot. The run fails if a test fails, Godot crashes, or Godot reports leaks when it exits. The whole output is in `test/build/test.log`.

## License

MIT, see `LICENSE`.
