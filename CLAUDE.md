# gdecl

Guidance for working on the gdecl framework: Godot 4 GDExtension programming in Common Lisp with ECL, without godot-cpp. User-facing documentation is in `README.md`; what each function does is in its docstring. This is its own repository (github.com/flambard/gdecl), used by applications as a git submodule, so keep it free of anything specific to an application.

## Goal and direction

GDExtension is a low-level C interface, not meant to be used directly by application developers. gdecl's goal is to raise the level of abstraction step by step until writing a Godot application in Lisp is at least as easy as with GDScript or C#, while staying efficient. Godot is mostly used for games, which are performance sensitive, so ease of use must not cost per-frame overhead.

Principles:

- **Build up gradually.** Each layer is built on the ones below it (see Layers), probably with one more layer on top of `gd-extension` later for the highest-level concepts, such as the CLOS integration below. Grow the framework from what the applications built on it need, and move code from an application into gdecl once the pattern is clear.
- **Keep the lower layers usable.** An application can always use a lower layer for what the higher ones don't cover yet, or for a hot path.
- **Do the work up front, not per call.** Look up method binds, StringNames and constructors once (at initialization or registration) and cache them. Prefer `ptrcall` to Variant calls. Avoid allocating in calls that happen every frame (`_process`, `_physics_process`), e.g. by not boxing floats or creating temporary Strings. Prefer compile-time expansion (macros, code generated from `extension_api.json`) to runtime lookup and dispatch.
- **Improve gdecl as you go.** When an application needs something gdecl lacks, or something in it could be better, improve gdecl rather than working around it in the application. Keep such changes general.
- **Measure.** Before choosing a convenient but slower design for something called often, check what it costs.

Where to look for inspiration:

- **GDScript**: the API application developers know: `extends`, `@export`, `signal`, virtual methods such as `_ready` that you just define, `$Node` paths, `@onready`.
- **Godot C# (`GodotSharp`)**: the closest model, a garbage-collected binding. Engine classes are generated from `extension_api.json` with method binds cached in static fields, builtin types such as `Vector2` are implemented in C#, user classes use attributes and a source generator writes the registration code, and `RefCounted` lifetimes are tied to the managed object.

### CLOS integration (idea, not yet decided)

`define-class` uses structs, with a syntax meant to be able to expand into `defclass` and methods later without changing applications much:

```lisp
(define-godot-class player (sprite-2d)
  ((speed :initform 400.0 :type float :export t))
  (:signals (hit)))

(defmethod process ((self player) delta) ...)
```

Open questions: a macro over `defclass` or a metaclass through the MOP; virtual methods as generic functions whose methods are found once, in `get_virtual_call_data`, and only reported when the class has one; the cost of CLOS dispatch in ECL every frame; generated CLOS classes for engine classes (plain inlinable functions are cheaper; use generic dispatch only where applications override); mapping each Godot object to one Lisp wrapper (instance bindings), with RefCounted lifetimes tied to the wrapper (finalizers). Lisp can also offer what GDScript and C# can't easily: redefining code in a running game, and a REPL connected to Godot.

## Layers

From the bottom up; dependencies only go downwards. Packages are in `lisp/packages.lisp`, files in `gdecl.asd`.

- `gd-extension-ffi`: the GDExtension C interface, one-to-one, without Lisp conveniences. Each interface function is a variable named after the C function (`*string-name-destructor*`), set in `load-interface`, and a wrapper function of the same name without earmuffs. Also ECL foreign-memory helpers.
- `gd-extension-builtins` (`builtin-types.lisp`): Godot's builtin types (`vector2`, `basis`, …) in plain Lisp. Everything it exports is for applications: `gd-extension` and `godot` re-export all of it through an export list computed when `packages.lisp` is read, so a new symbol is exported in one place only.
- `gd-extension-types`: converting between raw values, Lisp values and Variants. `*value-types*` (by variant type) is the one table of how each type converts; add new types there, with `add-value-type`. A value type's `lisp-type` is how `write-variant` finds the variant type of a struct such as `vector2` or `callable`.
- **Adding a builtin type** (Color, Transform2D, …) takes three things: the struct, with a constructor that converts its components (Godot's `real_t` is single-float, but Lisp code computes with doubles), and its functions in `builtin-types.lisp`; their exports in `packages.lisp`; and a `define-builtin-type` form in `gd-extension-types.lisp`, which generates the FFI mirror of Godot's layout, `read-`/`write-` and the value type. Defaults such as `Vector2(0, 0)` in `extension_api.json` then work too, for types whose components are all floats.
- `gd-extension-callback`: everything Godot calls into (`ffi:defcallback`), and the tables behind the callbacks. `initialize` and `deinitialize`, called from `src/gdecl.c`, live here.
- `gd-extension`: the public, Lisp-style layer, in several files whose load order in `gdecl.asd` matters (see Startup and shutdown). `extension-api.lisp` reads `extension_api.json` at compile time with gdecl's own small JSON reader (`gdecl-json`).
- `godot` and `godot-utility`: Godot's API generated from `extension_api.json` (`define-engine-class`, `define-global-enums`, `define-utility-functions`). Applications add the engine classes they use to `godot`.

Consequences of the layering that aren't obvious:

- The types layer can't refer to the callback layer, so `gd-extension-callback` installs the Object reader (which maps instances to their Lisp objects) and the Callable writer with `add-value-type`.
- Releasing a reference needs an engine method, so `gd-extension` sets `*release-reference-function*` for the autorelease pool in the types layer.
- `gd-extension` can't depend on `godot`, so it defines the few engine methods it needs itself, and keeps its own `+connect-one-shot+`.

## Startup and shutdown

- `src/gdecl.c` boots ECL at `GDEXTENSION_INITIALIZATION_SCENE`, with ECL's signal trapping (SIGSEGV etc.) disabled so it doesn't fight Godot's handlers. Loading the Lisp code runs the application's top-level forms, which register its entry point with `add-initialize-hook`. The C side then calls `gd-extension-callback:initialize`, the only Lisp function it knows, which loads the interface, fills in the initialize cells, and runs the initialize hooks. gdecl's own hook, which registers the classes from `define-class`, is added first, so the classes are registered before the application's hooks run.
- At deinit, `deinitialize` runs the deinitialize hooks in reverse order while Godot can still be called, then ECL is shut down. gdecl's own hooks are added before the application's, so they run last: `unregister-classes` (`binding.lisp`, subclasses first), then `destroy-permanent-values` (`gd-extension.lisp`, the StringNames and NodePaths from `sname`, `npath` and class names). That order depends on the load order in `gdecl.asd`. With both, Godot reports no leaks at exit; the one orphan `Node` the editor reports is Godot's own.

## Rules and pitfalls

- **Nothing is looked up in Godot at load time.** ASDF loads gdecl into the build image to compile what depends on it, and there's no Godot there. Lookups go into initialize cells (`initialize-cell-value`), filled in by `initialize`, or right away at a REPL.
- **A Lisp error must never unwind through Godot's C frames.** Wrap every callback body in `with-callback-protection`, which catches errors, reports them with `report-error` (Godot's `print_error`, so it shows in the editor). A bound method that fails returns null with `CALL_OK`, like a failing GDScript method; `CALL_ERROR_INVALID_METHOD` would make Godot say the method doesn't exist.
- **ECL FFI:** a `:pointer-void` returned by a foreign function has no size, so cast it before accessing slots (`cast-pointer`, `foreign-ref`). `defcallback` rejects `:uint8-t`, so declare `GDExtensionBool` as `:unsigned-byte`. Check new struct mirrors against C with `sizeof`/`offsetof`. `package-ffi-symbols.txt` and `package-si-symbols.txt` list what ECL's `FFI` and `SI` export.
- **ECL's FFI does at runtime what can be done at compile time, and it's slow** (measured: `get-slot-value` about 5 µs, the size of a struct type about 4 µs, `si:call-cfun` 0.6 µs, `with-foreign-object` 0.6 µs plus the size). On paths that run per call, use gdecl's replacements, which generate C code with `ffi:c-inline`: `call-foreign-pointer` (and `define-interface-function`) instead of `si:call-cfun`, `with-foreign-memory` instead of `ffi:with-foreign-object(s)`, and `foreign-ref`, `clear-foreign-object` and `array-element` with a constant type, which compiler macros turn into C (compiler macros only apply in files other than the one defining the function, so not inside `gd-extension-ffi.lisp`). Avoid `get-slot-value`, `element-pointer`, `cast-pointer` and `size-of-foreign-type` there; registration code can use them. Pointers from `with-foreign-memory` and `c-inline` have no size, so `cast-pointer` them before `get-slot-value`. C code in `c-inline` can't rely on headers, so use `__builtin_memset` and the like.
- **Sizes and layouts** come from the `float_64` build configuration in `extension_api.json`: `real_t` is `float`. The FFI mirrors, generated by `define-builtin-type`, are named `godot-vector2` etc., so the plain names are free for the Lisp types.
- **Basis:** Godot stores the rows, but the Lisp `basis` has the columns, as `basis.x` and `Basis(x, y, z)` in GDScript; `read-basis` and `write-basis` transpose.
- **ptrcall:** every argument must be given, defaults too. An Object argument is a pointer to the object pointer. A float is always a double and an int an `int64_t`, whatever the `meta` in `extension_api.json`. Zero the return slot first: Godot assigns into it (`Ref<T>`, `PackedStringArray`), releasing the old value. Vararg methods can't be ptrcalled.
- **Callbacks are on the per-frame path.** `with-callback-protection` replaces `handler-case` and `with-autorelease-pool` there: ECL's `handler-bind` conses a handler cluster at every entry (about 250 ns), so it binds ECL's internal `si:*handler-clusters*` to a cluster made once, and exits with `catch`. It needs no `unwind-protect`, since nothing but an error can leave a callback. Bound and virtual methods whose types are known when the code is compiled (`bind-virtual`, and `define-class` with constant types) get an invoker generated for their signature (`ptrcall-invoker-form`), so `ptrcall-bound-method` doesn't build an argument list, `apply`, or call converters by name; `bind-method` called with types at runtime uses the generic path. The user's function is still called by name, so redefining it takes effect.
- **Unsupported types:** when the code generator meets a type it can't convert yet, it signals `unsupported-api-type`. `define-engine-class`, `define-utility-functions` and `bind-virtual` skip only that condition, so any other error, such as a bug in the generator, stops the build instead of making methods silently disappear.
- **Method hashes** come from `extension_api.json`; `classdb_get_method_bind` returns NULL on a mismatch, which usually means the JSON was dumped from another Godot version.
- **Virtual methods** use `get_virtual_call_data_func`, which returns NULL for those the class doesn't implement, so Godot never calls into Lisp for nothing. Several engine classes have virtuals with the same name but different signatures (`_process`), and the parent class isn't known when `bind-virtual` expands, so the expansion carries all of them and the right one is picked at registration.
- **Godot can't register a class twice**, so redefining a class at a REPL doesn't work yet. Functions given to `define-class` as symbols are called by name, so redefining those does.
- **Literal names:** a compiler macro wraps literal strings given for StringName and NodePath arguments in `sname`/`npath`. That doesn't apply through `funcall`/`apply`, or to calls compiled before the definition; then each call makes a temporary one.
- **Callables:** `object_id` must be set, since Godot skips connections without an object. Godot doesn't initialize `r_error` for custom Callables, so it's always set. A result that can't be a Variant becomes null, not an error, since Godot ignores signal handlers' results.
- **Variant calls into bound methods** accept null for an Object, and a float for an int (truncated) or an int for a float, as Godot does for its own methods.

## References (RefCounted ownership)

- An engine method's RefCounted result comes with a reference (a `Ref<T>`). During a call from Godot (every callback and every initialize/deinitialize hook) it goes into the autorelease pool and is given back when the call returns. Outside a call, e.g. at a REPL, there's no pool and the caller owns it.
- An Object Variant result: the Variant is copied and the copy is kept until the pool goes, which keeps the reference without having to ask Godot whether the object is RefCounted.
- An Object a bound or virtual method returns with ptrcall needs a reference for Godot (`reference-for-caller`): Godot puts the pointer into a Variant or `Ref<T>` without taking one, and gives one back later. Without it, a typed GDScript call of a RefCounted getter released a reference it never got.
- Arguments never take a reference: the caller owns those Variants.
- `setf-reference` takes the new reference before giving back the old one, in case they're the same object.

## Build

- `gdecl.mk` builds the application's ASDF system monolithically into `$(BUILD_DIR)/application.a`, always with the init function `init_lib_APPLICATION`, which `src/gdecl.c` calls by name; keep the two in sync. `application.a` must come before ECL's flags (`-lecl`) when linking.
- Changing `SYSTEM` doesn't make `application.a` out of date; use `make -B`.
- `src/gdextension_interface.h` and `extension_api.json` are generated by Godot (`make godot-api`) and ignored by git; don't edit them. The `EditorSettings not instantiated yet` error while dumping is harmless.

## Tests

- Run `make test` after changing gdecl. `test/` is a gdecl application of its own; `test/project/run_tests.gd` runs headless, first GDScript tests of Godot calling Lisp (classes in `test/lisp/classes.lisp`), then Lisp tests of Lisp calling Godot (`test/lisp/lisp-tests.lisp`, with `deftest` and `check`).
- The run fails if Godot reports leaked instances, resources in use or orphan StringNames at exit, so tests must free what they make (Lisp tests add their nodes to `*root*`). A test that causes a Godot error on purpose prints `[test] expect error` just before it. The full log is `test/build/test.log`.
- `check` evaluates a call's arguments first, to show them on failure, so a literal string there is a runtime value, not an `sname`: wrap such a call in another (`(check (eq t (f "literal")))`).
- In GDScript, calling a method on a typed variable is a ptrcall (a failing method returns 0 for an int, not null; use `call` for a Variant call), and lambdas capture locals by value.
- When refactoring a code generator (`define-engine-class`, `define-class`, …), compare the macroexpansions before and after, with `*gensym-counter*` reset before each, to show the generated code is unchanged.

## Measured costs

- Each engine method is a compiled function with its own conversion code: about 70 ms of build time and 15 KB of library per method. The ~360 functions in `godot` take about 25 s and 5.5 MB; the 88 utility functions about 12 s and 2 MB. If this grows too much, the per-method code could call shared conversion functions instead, or fewer classes could be predefined.
- Reading `extension_api.json` takes about half a second per build.
- `make bench` times calls between Lisp and Godot, and the same calls in GDScript (`test/lisp/benchmarks.lisp`, `test/project/run_benchmarks.gd`). On this machine, after the FFI work: an engine method call from Lisp about 0.5–0.8 µs (GDScript 50–110 ns), a vararg one (`emit_signal`) 2.6 µs (GDScript 150 ns), a call into a Lisp method with ptrcall (like `_process`) 0.7–0.9 µs (into a GDScript method 0.3 µs; an empty callback alone costs 0.3 µs). What remains per engine call is mostly allocation: a `malloc` and a Lisp pointer object for each raw value, the argument array and the result. Measure with `make bench` before and after optimizing.
