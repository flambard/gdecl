# gdecl

Guidance for working on gdecl: Godot 4 GDExtension programming in Common Lisp with ECL, without godot-cpp. User documentation is in `README.md`, what each function does in its docstring, known gaps and planned work in `TODO.md`. This is its own repository (github.com/flambard/gdecl), used by applications as a git submodule, so keep it free of anything specific to an application.

## Goal and direction

GDExtension is a low-level C interface. gdecl raises the level of abstraction step by step until writing a Godot application in Lisp is at least as easy as with GDScript or C#, without costing per-frame overhead, since Godot is mostly used for games.

Principles:

- **Build up gradually.** Each layer is built on those below it (see Layers). Grow the framework from what applications need, and move code from an application into gdecl once the pattern is clear.
- **High level by default, drop down where it matters.** One method of a class, or one hot loop, can use a lower layer without giving up the high level elsewhere. So the layers must work together: high-level objects can be passed to every layer below (they're `godot-object`s), a high-level class can have methods bound the low-level way, and the lower layers stay usable and documented.
- **Performance first: shift work from run time to compile time.** Every design is judged by what it costs per frame. Do at compile time (macros, code generated from `extension_api.json`) what can be done then, at initialization or registration what has to wait for Godot (method binds, StringNames, constructors, cached once), and at run time only what must happen per call. Prefer ptrcall to Variant calls, don't allocate in calls made every frame, and prefer deterministic resource handling (the autorelease pool) to run-time machinery such as GC finalizers.
- **Measure** before choosing a convenient but slower design for something called often (see Benchmarks).
- **Improve gdecl as you go**, rather than working around it in an application, and keep such changes general.
- **High cohesion, a consistent style and consistent names:**
  - One place per concern, and each file about one concern, with a header comment that says what's in it and where the related code is (`*value-types*`, `handle-tables.lisp`, `lifecycle.lisp`).
  - Don't copy knowledge: when the same code, or the same knowledge about a type, is about to appear in a second place, move it into one. Code that only works because of the order files load in belongs somewhere else.
  - No knowledge from a layer above: a lower layer gets what it needs through a hook the higher layer sets (`literal-macro`, `*release-reference-function*`).
  - Write like the code around it, with docstrings and comments filled to 80 columns.
  - One name for one concept: `look-up-…` for the verb; "binding" only for instance bindings, "registration" for classes, methods, properties and signals; `godot-<type>` for FFI mirrors, `read-`/`write-` for converters. When a name stops fitting, rename it everywhere, docs and `TODO.md` included.
  - When the cohesive form costs time on a per-call path, measure, keep the fast form, and say why in a comment.

Inspiration: **GDScript** for the API developers know (`extends`, `@export`, `signal`, virtual methods you just define, `$Node`, `@onready`); **Godot C#** as the closest model of a garbage-collected binding (engine classes generated from `extension_api.json` with cached method binds, builtin types implemented in C#, user classes from attributes and a source generator, RefCounted lifetimes tied to the managed object).

### The high-level layer: CLOS, with a fast path (decided on 2026-10-17)

`godot-clos` is the high-level layer: a class is a `defclass` with the metaclass `godot-class`, and what Godot calls are generic functions. That gives inheritance, mixins, method combination (e.g. `:before` methods on `_ready`) and redefinition in a running game, probably Lisp's strongest selling point here. `define-class` (`godot-dsl`) stays as a faster, lower layer for dropping down, but gets no new high-level features.

Why: generic dispatch costs about 0.2 µs more per call from Godot than a plain function, about 0.2 ms a frame for 1,000 objects with `_process` (about 1%), small next to what entering Lisp costs at all. Hot code drops down: a virtual method bound to a plain function with `:direct-functions` costs what `define-class` does, and hot data goes into a struct held in one slot, so hot code pays for one generic accessor (faster CLOS accessors are TODO AM).

What it rests on:

- **A CLOS class can inherit from structs** in ECL when `validate-superclass` allows it, so a `godot-class` inherits from its engine class's struct and its instances are `godot-object`s to every layer below. The structs' slots come first, so `pointer` is at location 0 (`+godot-object-pointer-location+`, checked by `types` when it's loaded), provided mixins come before the struct in the superclasses (checked when the class is finalized). `standard-object` is added to the superclasses, since redefinition needs its methods.
- **ECL gives fast slot access only to `standard-class`**, so `godot-class` sets up the location table and optimized accessors itself.
- **Dispatch can't be resolved once:** ECL's method functions take their arguments as a list, so calling an effective method computed once is no faster than the generic function, and it conses.
- **Signal emitters** (decided on 2026-10-17): the `:signals` option is read only when the class is created, so a fast emitter is a `define-signal-emitter` next to the class, giving the signal's types a second time.

Open questions: generated classes for the engine classes used, instead of the structs of `define-engine-class`; RefCounted lifetimes tied to their Lisp objects (finalizers), now that every Godot object has one Lisp object.

## Layers

From the bottom up; dependencies only go downwards. Each layer is a directory of `lisp/`, with its packages in its own `package.lisp`, and a module in `gdecl.asd` whose `:depends-on` lists exactly the layers its code uses (in `:use`, `:import-from` and package-qualified symbols), shortcuts included; keep it in step. A package is defined only once the layers below it are loaded, so a lower layer can't even read a symbol of a higher one.

| Directory | Package | |
|---|---|---|
| `extension-api/` | `gdecl-json`, `extension-api-json` | `extension_api.json`, read with a small JSON reader when the code is compiled |
| `ffi/` | `gd-extension-ffi` | The GDExtension C interface |
| `types/` | `gd-extension-builtins`, `gd-extension-types` | Godot's builtin types in plain Lisp, foreign memory for Godot's opaque values, and converting values between Godot and Lisp |
| `callback/` | `gd-extension-callback` | What Godot calls into |
| `gd-extension/` | `gd-extension` | The public, Lisp-style layer, and the code generator of engine methods |
| `godot/` | `godot`, `godot-utility`, `godot-generators` | Godot's API, generated, and its code generators |
| `dsl/` | `godot-dsl` | `define-class`: a class in one form, with a struct for its instances; faster and lower-level than `godot-clos` |
| `clos/` | `godot-clos` | The high-level layer: classes as CLOS classes |

```
   dsl/     clos/
      \      /
      godot/
        │
   gd-extension/
        │
     callback/
        │
      types/
      /     \
   ffi/   extension-api/
```

Layers also use those further down directly: `gd-extension` uses all below it, `godot` uses `types` and `extension-api`, `callback` uses `ffi`. The class layers, `dsl` and `clos`, use only the public layers, `gd-extension` and `godot`; what they need from further down, `gd-extension` exports (`report-error`, `invokers-form`, `godot-object`, `+godot-object-pointer-slot+`, `+godot-object-pointer-location+`), and they import a few of its internals in their `:import-from` clauses.

- `extension-api/`: the one place that knows `extension_api.json`: where it is (`*extension-api-file*`), reading it once (the function `extension-api-json`, with gdecl's JSON reader in `gdecl-json`), and compile-time lookups: `api-builtin-size`, `api-constant`, and the classes, methods, enums and utility functions as Lisp structs (`api-class`, `api-method`, `api-argument`, `api-enum`; enum values and constants as `(name . value)`). Types keep Godot's names (`"Vector2"`, `"enum::Node.ProcessMode"`). When a generator needs more of the API, extend the structs and their readers (`read-api-class` etc.) rather than reading JSON elsewhere.
- `ffi/`: the GDExtension C interface, one-to-one: each interface function is a variable named after the C function (`*string-name-new-with-utf8-chars*`), set in `load-interface`, and a wrapper of the same name without earmuffs; also ECL foreign-memory helpers. It depends on nothing in gdecl.
- `types/`:
  - `gd-extension-builtins` (`builtin-types.lisp`): Godot's builtin types (`vector2`, `basis`, …) in plain Lisp, all for applications; `godot` re-exports all of it (computed in `godot/package.lisp`).
  - `gd-extension-types`: converting between raw values, Lisp values and Variants. `*value-types*` (by variant type) is the one table of how each type converts; the code generators look types up there. A value type has its FFI type (the C type follows, `c-type-name`), its readers and writers, and optionally: `to-raw`/`from-raw` for simple types converted in C (`define-simple-value-type`: bool, int, float, Object); `from-address` for a pointer type that C code returns as an integer (Object's `address-lisp-object`, used through `raw-result-conversion`); `by-pointer` for StringName and NodePath, with `literal-macro`; `default-parser` for defaults in `extension_api.json`; and `lisp-type`, for `write-variant` to find a value's variant type (`lisp-variant-type`).
  - Godot's opaque values (`variant`, `string-name`, `godot-string`, `packed-array`, sizes such as `+variant-size+`; `opaque-values.lisp`), Strings, StringNames and NodePaths (`strings.lisp`), and the autorelease pool (`autorelease-pool.lisp`).
- `callback/`: everything Godot calls into, in files loaded in this order: `gd-extension-callback.lisp` (`define-callback`, threads, `with-callback-protection`), `handle-tables.lisp`, `initialize.lisp` (`initialize`, `deinitialize`, their hooks, initialize cells), `instance-bindings.lisp` (`lisp-object`, the Object value type), `extension-classes.lisp` (classes, instances, which virtuals a class implements, notifications), `bound-methods.lisp` (methods, virtual methods, invokers, `call-virtual-with-data`), `callables.lisp`.
- `gd-extension/`: the public, Lisp-style layer (see the header of `gd-extension.lisp`), with the code generator of engine methods, `define-engine-method` (`engine-methods.lisp`), and `api-types.lisp`, which turns API types into variant types and signals `unsupported-api-type` for those gdecl can't convert yet.
- `godot/`: Godot's API, generated by `godot-generators` (`engine-api.lisp`: `define-engine-class`, `define-global-enums`, `define-utility-functions`), a package of its own so the names it interns in `godot` can't clash with the `gd-extension` internals it imports. Applications add the engine classes they use with `define-engine-class`.
- `dsl/`: `define-class`, which expands into `gd-extension`'s registration functions and a struct that includes the engine class's.
- `clos/`: the metaclass (`godot-class.lisp`), the generic functions Godot calls, virtual methods and `notification` (`godot-functions.lisp`), and registration (`godot-registration.lisp`).

Consequences of the layering that aren't obvious:

- `types` can't refer to `callback`, so `callback` adds the value types of Object and Callable.
- Releasing a reference needs an engine method, so `gd-extension` sets `*release-reference-function*` for the autorelease pool; likewise the `literal-macro` of StringName and NodePath.
- `gd-extension` can't use `godot`, so it defines the few engine methods it needs with `define-engine-method` next to their use (as `class-db-is-parent-class` in `registration.lisp`), and its constants with `api-constant`. That's also why `define-engine-method`, what generated functions call at run time (`look-up-method-bind`, `look-up-utility-function`) and the structs of engine objects (`engine-objects.lisp`) are there. What can be built on `gd-extension` and the generated API, such as `after-signal`, goes into `godot/`.
- `dsl` and `clos` give each class to `add-class-definition` (`registration.lisp`), and `register-defined-classes`, a startup step, registers them in the order they were defined.

## Startup and shutdown

- `src/gdecl.c` boots ECL at `GDEXTENSION_INITIALIZATION_SCENE`, with ECL's signal trapping (SIGSEGV etc.) disabled so it doesn't fight Godot's handlers. Loading the Lisp code runs the application's top-level forms, which may add initialize hooks. C then calls `gd-extension-callback:initialize`, the only Lisp function it knows: it loads the interface, fills in the initialize cells, runs the framework's startup steps (`*framework-initialize*`), then the application's initialize hooks.
- `deinitialize` runs the application's deinitialize hooks in reverse order while Godot can still be called, then the framework's shutdown steps (`*framework-deinitialize*`), then shuts down ECL. The framework's steps, their order and why are in one place, `lifecycle.lisp`: `unregister-singletons`, `unregister-classes` (subclasses first), `destroy-permanent-values`, and `free-bindings` last. Godot then reports no leaks at exit; the one orphan `Node` the editor reports is Godot's own.

## Adding things

- **A builtin type** (Color, Transform2D, …), all in `types/`: the struct, with a constructor that converts its components (`real_t` is single-float, Lisp computes with doubles), and its functions in `builtin-types.lisp`; their exports in `package.lisp`; and a `define-builtin-type` form in `gd-extension-types.lisp`, which generates the FFI mirror, `read-`/`write-` and the value type. Defaults such as `Vector2(0, 0)` then work too, for types made of floats.
- **Another type:** `add-value-type`, or `define-simple-value-type` if its raw value is a C number or pointer, in the lowest layer that has what its conversion needs (as `containers.lisp` for Arrays and Dictionaries). Give it a `lisp-type` if `write-variant` should make Variants of it, and a `default-parser` if arguments of it have defaults.
- **A file** goes into its layer's directory and module in `gdecl.asd`; if it needs a layer above, it belongs there or gets a hook. **A layer** is a directory with its `package.lisp` and a module in `gdecl.asd`.
- **A framework startup or shutdown step** goes into `lifecycle.lisp`, not into `add-initialize-hook` or `add-deinitialize-hook`, which are for applications.

## Performance in ECL

The measured costs behind the design; check them with `make bench` before relying on new ones.

- **Calls between files go through the symbol**, about 50 ns each. On per-call paths, declare small helpers `inline` (`find-value-type`, `instance-object`, `set-call-error`), and keep lookups a plain `aref` of a variable (the handle tables' lookups are macros for that reason).
- **An `inline` function with `&key` arguments is slower than not inlining it**, as ECL parses the keywords at run time. Use `&optional`.
- **No closures in per-call code**, not even on a rare path inside it: ECL boxes the variables they capture (one in `with-callback-protection` slowed every callback by 10–60 ns).
- **`handler-bind` (and `handler-case`) conses a handler cluster at every entry**, about 250 ns. On per-call paths use `catching-errors`: it binds `si:*handler-clusters*` to a cluster made once, reuses the cons that puts it in front of the others while they're the same (`handler-clusters-with`), and exits with `catch`. `with-callback-protection` is built on it (about 38 ns, allocating nothing) and needs no `unwind-protect`, since only an error can leave a callback.
- **ECL's FFI does at run time what could be done at compile time** (`get-slot-value` about 5 µs, a struct type's size 4 µs, `si:call-cfun` and `with-foreign-object` 0.6 µs). On per-call paths use gdecl's replacements, which generate C with `ffi:c-inline`: `call-foreign-pointer` (and `define-interface-function`) for `si:call-cfun`, `with-foreign-memory` for `ffi:with-foreign-object(s)`, `set-foreign-slots` for `(setf (ffi:get-slot-value …))` (it also works on pointers without a size), and `foreign-ref`, `clear-foreign-object` and `array-element` with a constant type (compiler macros, so not inside `gd-extension-ffi.lisp`). Avoid `get-slot-value`, `element-pointer`, `cast-pointer` and `size-of-foreign-type` there; registration code can use them.
- **Engine calls in one piece of C:**
  - Methods whose types are all simple (bool, int, float, Object, StringName, NodePath, and builtin types made of floats; about 80% of them) are called in one `c-inline` (`inline-ptrcall-form`) and allocate only the result's Lisp value. An Object result is returned as an integer and looked up with `address-lisp-object`. A builtin result made of floats is a new struct (112 bytes for a Vector2, as ECL boxes every float in a struct slot), or, with `:into` (`define-engine-method`; opt-in, decided on 2026-10-18), stored into one the caller gives.
  - Vararg methods with arguments of known simple types and a result that's none, bool, int or float (`:extra-arguments`, signal emitters from `define-signal-emitter`) make their Variants on the C stack (`inline-variant-call-form`), allocating nothing.
  - Other ptrcalls go through foreign memory (`general-ptrcall-method-form`): a `malloc` and a pointer object per raw value. Other vararg calls (`variant-call-method-form`: a `&rest` list, `object-call`, vararg utility functions such as `str` and `print`) keep everything in one `calloc`'d block handled by its address (`with-variant-call`) and write the further arguments with `write-variant-at`.
  - `read-variant` and `write-variant` convert bools, ints and floats in C, without calling a type's reader or writer by name (`read-simple-variant`, `write-simple-variant`, shared with `read-variant-at` and `write-variant-at`, which take an address as an integer).
- **Callbacks take pointers as integers.** `method-ptrcall`, `call-virtual-with-data`, `method-call` and `callable-call` declare their pointer arguments `:uint64-t`: a `:pointer-void` makes a pointer object each time (22 ns, 32 bytes), and `ffi:pointer-address` costs 30 ns. Handles are looked up with `address-handle-value`, and a pointer object is made (`address-pointer`, `argument-pointer`) only for readers and writers that need one. `callable-call` and `method-call` call a function of up to three arguments without a list to `apply`. `callable-call` reads null, bool, int, float and Object arguments inline (`inline-read-variant-at`, in `instance-bindings.lisp` as only the callback layer can find an Object's Lisp object; also used by `call-bound-method`'s generic path) and writes bool, int and float results inline. Callables have no invokers: their functions declare no types, and generated code would gain at most 6 ns.
- **Invokers.** Bound and virtual methods whose types are known at compile time (`bind-virtual`, `define-class` with constant types, `define-godot-generic`) get invokers for their signature, so the dispatchers build no argument list and call no converter by name: `ptrcall-invoker-form`, and for bound methods also `variant-invoker-form`, which checks each argument's type once (virtual methods are only ptrcalled). Macros above `gd-extension` get both with `invokers-form` and give them to `bind-method` as `:invokers`. `bind-method` with types given at run time, as for `godot-clos`'s properties, uses invokers compiled in advance for getters and setters (`signature-invokers`, `registration.lisp`), and the generic path otherwise. The user's function is still called by name, so redefining it takes effect.
- **Where the time of a call into Lisp goes** (measured on 2026-10-17; it's at its floor, and what's left is mostly Godot's own part and ECL's boxed floats). A ptrcall into an empty Lisp method, 0.15–0.16 µs (GDScript 90 ns): Godot's part about 35 ns, `gdecl_enter_lisp` 8 ns, `with-callback-protection` 30–40 ns, and calling the user's function by name 20 ns, which is what makes redefinition work; a float argument adds 25 ns and 16 bytes. A signal to a Lisp handler, 0.34–0.35 µs: Godot's dispatch to the custom Callable about 150 ns, `callable-call` the rest. Not worth trying again: removing a special binding from `with-callback-protection` (a binding costs 1.5 ns).
- **CLOS** (standalone): a generic function call 90–95 ns (a call by name 30 ns), with dispatch cached per thread; an accessor 29 ns (a struct accessor 20 ns); `make-instance` 2.3–2.9 µs, `si:allocate-raw-instance` 72 ns. ECL builds the slots' location table and uses optimized accessors only for `standard-class` itself (compared with `eq`), so under another metaclass an accessor takes 426 ns through `slot-value-using-class`, unless the metaclass sets them up itself, as `godot-class` does. Sealed classes get inlined accessors only at `(safety 0)`; at `(safety 1)` ECL 24.5.10 fails to compile them.
- **Per-method code.** Each engine method is its own compiled function: about 55 ms of build time and 10 KB of object code (the game's library is 8.2 MB). Shared callers per signature would be smaller but add a call between files to every engine call, so per-method code stays; if size becomes a problem, predefine fewer classes.

## Rules and pitfalls

- **Nothing is looked up in Godot at load time:** ASDF loads gdecl into the build image to compile what depends on it, and there's no Godot there. Lookups go into initialize cells (`initialize-cell-value`), filled in by `initialize` (or right away at a REPL) before the framework's startup steps, so a lookup of something the extension registers itself waits until it's used, as `singleton` does.
- **A Lisp error must never unwind through Godot's C frames.** Wrap every callback body in `with-callback-protection`, which reports errors with `report-error` (Godot's `print_error`). A failing bound method returns null with `CALL_OK`, like a failing GDScript method (`CALL_ERROR_INVALID_METHOD` would say the method doesn't exist). Called with ptrcall, or as a virtual method, it returns its type's default value, or null for an Object (`write-failed-result`), as Godot doesn't clear the result; a type with a destructor, such as String, keeps the empty value Godot passes.
- **Godot calls into Lisp from any thread.** Define callbacks with `define-callback`, not `ffi:defcallback`, and give Godot `callback-pointer`: its C function imports the thread into ECL the first time (otherwise ECL aborts) and releases it when the thread exits (otherwise the next GC aborts). The handle tables behind the callbacks aren't thread-safe yet (TODO R).
- **ECL FFI:**
  - A `:pointer-void` from a foreign function, and pointers from `with-foreign-memory` and `c-inline`, have no size: cast them (`cast-pointer`) before `get-slot-value`, or use `foreign-ref` and `set-foreign-slots`.
  - `defcallback` rejects `:uint8-t`, so `GDExtensionBool` is `:unsigned-byte`.
  - Check new struct mirrors against C with `sizeof`/`offsetof`. `define-builtin-type` checks those of builtin types against `extension_api.json` when the code is compiled.
  - C code in `c-inline` can't rely on headers: use `__builtin_memset` and the like.
  - C code in `ffi:clines` belongs to its file, as ASDF compiles each file into a library of its own for the build image: another file can't use its functions or variables, not even non-static ones. Pass an address through Lisp instead, as `define-callback` does with `enter-lisp-address`.
  - `array-element-type` gives ECL's names for upgraded types (`ext:byte8`); compare with `upgraded-array-element-type`.
  - `doc/package-ffi-symbols.txt` and `doc/package-si-symbols.txt` list what ECL's `FFI` and `SI` export.
- **Sizes and layouts** come from the `float_64` build configuration: `real_t` is `float`. Don't copy sizes or enum values by hand; use `api-builtin-size` and `api-constant`, which expand to the value at compile time. The FFI mirrors are named `godot-vector2` etc., so the plain names are free for the Lisp types.
- **Basis:** Godot stores the rows, the Lisp `basis` the columns (as `basis.x` and `Basis(x, y, z)` in GDScript); `read-basis` and `write-basis` transpose.
- **ptrcall:** every argument must be given, defaults too. An Object argument is a pointer to the object pointer. A float is always a double and an int an `int64_t`, whatever the `meta`. Zero the return slot first: Godot assigns into it (`Ref<T>`, `PackedStringArray`), releasing the old value. Vararg methods can't be ptrcalled.
- **One Lisp object per Godot object**, through Godot's instance bindings (`lisp-object`, `instance-bindings.lisp`):
  - An instance of an extension class maps to the object its constructor made (set in `create-class-instance`); any other object to one made on first sight (`create-binding`, calling `*wrapper-function*`), a struct of its class's type (`engine-objects.lisp`).
  - `define-engine-class` defines a struct per class, including that of the nearest defined class it inherits from, so `typep`, `typecase` and `defmethod` follow Godot's inheritance. A new object's type is found by walking Godot's class parents (a table from `extension_api.json`) to the nearest class with a struct, cached by the address of the class name's StringName data, which stays the same while the class is registered.
  - Godot calls `free-binding` when it frees the object, which clears the Lisp object's pointer, so `object-pointer` then signals an error. `free-bindings`, the last shutdown step, frees the remaining bindings before ECL shuts down; otherwise Godot would call `free-binding` after it, e.g. for engine singletons.
  - Code that passes an object to Godot goes through `object-pointer`. Raw pointers are accepted wherever an Object is passed, for dropping down, but not where a Variant is made from a Lisp value (`lisp-variant-type`), as a raw pointer might point to something else, such as a StringName.
- **Arrays and dictionaries are copies** (`containers.lisp`): packed arrays of numbers are specialized vectors copied with `memcpy`; other packed arrays and Arrays are simple vectors converted element by element; Dictionaries are `equal` hash tables. Their conversions need Godot's builtin methods (`builtin-method`), so they're added to `*value-types*` from `gd-extension`. Writers take any sequence, so `#()` is the default of an empty array argument.
- **Unsupported types:** the code generator signals `unsupported-api-type` for a type it can't convert yet. `define-engine-class`, `define-utility-functions` and `bind-virtual` skip only that condition, so any other error stops the build instead of methods silently disappearing.
- **Method hashes** come from `extension_api.json`; `classdb_get_method_bind` returns NULL on a mismatch, which usually means the JSON is from another Godot version.
- **Notifications:** Godot calls a class's `notification_func` for every notification, some every frame (`NOTIFICATION_PROCESS`), without the class userdata. So `*instances*` holds each instance's class with its Lisp object, and Godot calls a C function, `gdecl_notification`, that passes on only the notifications some class wants (a table of flags); the callback then checks the instance's own class. Only classes with a notification function get a `notification_func`. `free_instance` runs from `Object`'s destructor, after the engine classes' destructors, so cleanup that calls Godot belongs at `NOTIFICATION_PREDELETE`.
- **Virtual methods** use `get_virtual_call_data_func`, which returns NULL for those a class doesn't implement, so Godot never calls into Lisp for nothing. Godot looks a virtual method up in the instance's class only, so a `godot-clos` class also binds those it inherits from Lisp classes. Several engine classes have virtuals with the same name but different signatures (`_process`), and the parent class isn't known when `bind-virtual` expands, so the expansion carries all of them and the right one is picked at registration.
- **Godot can't register a class twice**, so evaluating a `define-class` again doesn't work yet (TODO J); its functions are called by name, so redefining those does. `godot-clos` registers only what's new when a class is redefined (`godot-registration.lisp`); a `:singleton` added at a REPL is registered then, and one removed stays until Godot unloads the extension.
- **Literal names:** a compiler macro wraps literal strings given for StringName and NodePath arguments in `sname`/`npath`. Through `funcall`/`apply`, in calls compiled before the definition, and in the file that defines the function (ECL doesn't use a compiler macro there), each call makes a temporary one instead, more than twice as slow. So define engine methods with `define-engine-method` in a file of their own, as `test/lisp/engine-classes.lisp` does.
- **Callables:** `object_id` must be set, or Godot skips the connection. Godot doesn't initialize `r_error` for custom Callables, so it's always set. A result that can't be a Variant becomes null, not an error, since Godot ignores signal handlers' results. A Callable read from Godot is the `callable` it was made from if it's one of gdecl's (found with `callable_custom_get_userdata` and gdecl's token, `*class-library*`), so `*callables*` keeps the `callable`, not only its function; any other is an `engine-callable` with a copy of it (`callback/callables.lisp`), which `gd-extension/callables.lisp` calls and compares.
- **Object arguments and results of bound methods have the class name `Object`** (`method-property-info`, `registration.lisp`): GDScript makes a validated call (a ptrcall) only if every argument's class matches the parameter's or inherits from it, so without it every typed call with an Object argument was a Variant call. An untyped argument, such as a literal `null`, still makes one.
- **Variant calls into bound methods** accept null for an Object, and a float for an int (truncated) or an int for a float, as Godot does for its own methods.

## References (RefCounted ownership)

- An engine method's RefCounted result comes with a reference (a `Ref<T>`). During a call from Godot (every callback, initialize/deinitialize hook and framework step) it goes into the autorelease pool and is given back when the call returns; outside one, e.g. at a REPL, the caller owns it.
- An Object Variant result is copied, and the copy kept until the pool goes, which keeps the reference without asking Godot whether the object is RefCounted.
- An Object a bound or virtual method returns with ptrcall needs a reference for Godot (`reference-for-caller`), which puts the pointer into a Variant or `Ref<T>` without taking one and gives one back later.
- Arguments never take a reference: the caller owns those Variants.
- An `engine-callable`'s copy of a Godot Callable goes into the pool too (`autorelease-callable`), so it's valid until the call returns; destroying it clears the struct's pointer, so later use signals an error instead of reading freed memory. `keep-callable` makes a copy outside the pool.
- `setf-reference` takes the new reference before giving back the old one, in case they're the same object.
- An exported slot of a RefCounted `:class` owns a reference to its value, given back when Godot frees the instance. Every way gdecl puts a value there takes one: the property's setter (`setf-reference`), the constructor for initforms (in both class layers), `godot-clos`'s `make-instance` for initargs, and an instance updated after its class is redefined with such a slot (`godot-registration.lisp`). Writing the slot directly is the application's to handle, with `setf-reference`.

## Build

- `gdecl.mk` builds the application's ASDF system monolithically into `$(BUILD_DIR)/application.a`, always with the init function `init_lib_APPLICATION`, which `src/gdecl.c` calls by name; keep the two in sync. `application.a` must come before ECL's flags (`-lecl`) when linking.
- Changing `SYSTEM` doesn't make `application.a` out of date; use `make -B`.
- `src/gdextension_interface.h` and `extension_api.json` are generated by Godot (`make godot-api`) and ignored by git; don't edit them. The `EditorSettings not instantiated yet` error while dumping is harmless. Reading `extension_api.json` takes about half a second per build.

## Tests

- Run `make test` after changing gdecl, and build an application that uses it too. `test/` is a gdecl application; `test/project/run_tests.gd` runs headless, first GDScript tests of Godot calling Lisp (classes in `test/lisp/classes.lisp`), then Lisp tests of Lisp calling Godot (`test/lisp/lisp-tests.lisp`, with `deftest` and `check`).
- The run fails if Godot reports leaked instances, resources in use or orphan StringNames at exit, so tests must free what they make (Lisp tests add their nodes to `*root*`), and if Godot reports an error no test expected. A test that causes one on purpose prints `[test] expect error` just before. The full log is `test/build/test.log`.
- `check` evaluates a call's arguments first, to show them on failure, so a literal string there is a runtime value, not an `sname`: wrap such a call in another (`(check (eq t (f "literal")))`).
- In GDScript, calling a method on a typed variable is a ptrcall (a failing method returns its type's default value, not null; `call` makes a Variant call, which returns null), and lambdas capture locals by value.
- A test should fail without the change it tests: when fixing a bug, check that the new test fails on the old code.
- When refactoring a code generator, show the generated code is unchanged: `make expansions-baseline` before and `make expansions-check` after compare the macroexpansions (with `*gensym-counter*` reset) of all engine methods and utility functions, `define-engine-class` for every class, `define-global-enums`, `define-utility-functions`, and the invokers of each type (`test/expansions.lisp`); extend it to cover other generators you change. Symbols are written with their home package, so changing exports doesn't show as a change but moving a symbol to another package does. A change to its output format needs a new baseline from the code before the change.

## Benchmarks

- `make bench` times calls between Lisp and Godot, and the same calls in GDScript (`test/lisp/benchmarks.lisp`, `test/project/run_benchmarks.gd`).
- Results vary by about 15% from run to run and 25% or more between sessions. To see what a change costs, compare with a build of `HEAD` in alternating runs: `git worktree add --detach <dir> HEAD` outside the repository, copy `extension_api.json` and `src/gdextension_interface.h` into it, run `make bench` in each tree in turn four times or more, and remove the worktree afterwards. Put the before and after numbers in the commit message.
- To see where the time of a call goes, add temporary probes (time a part on its own, or call a callback directly from C) and leave them out of the commit.

Typical times, in quiet runs on this machine:

| Call | gdecl | GDScript |
|---|---|---|
| Engine method from Lisp, simple types | 60–80 ns, allocating nothing | 17–30 ns |
| … with a Vector2 argument | 110–120 ns | |
| … with a Vector2 result | 160 ns, 112 bytes (90 ns, 32 bytes with `:into`) | |
| … with an Object result | 115 ns | |
| `emit_signal`, further arguments as a `&rest` list | 0.27–0.28 µs | 35 ns |
| … with `:extra-arguments` of simple types | 0.16 µs | |
| … with `define-signal-emitter` | 0.12 µs | |
| Ptrcall into a Lisp method (like `_process`) | 0.15–0.16 µs empty, 0.2 µs with a float | 90 ns |
| Variant call, or through an untyped variable | 0.26–0.27 µs (0.22 µs without arguments, returning an int) | 90 ns |
| Signal to a Lisp handler, with an int | 0.31–0.32 µs (no handler: 65 ns) | 230 ns |
| … with an Object | 0.38–0.4 µs | 260 ns |
| Signal to a Lisp method connected by name | 0.39–0.4 µs | 200 ns |
| Notification to a `notification` method | 0.43–0.48 µs; 31–33 ns if no class wants it | |
| Empty `_process`, through `NOTIFICATION_PROCESS` | 0.19–0.2 µs with `define-class` or a direct function; 0.44–0.45 µs through a generic function (measured before the callbacks took integers) | 91–95 ns (none: 31–33 ns) |
