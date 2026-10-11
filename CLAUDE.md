# gdecl

Guidance for working on the gdecl framework: Godot 4 GDExtension programming in Common Lisp with ECL, without godot-cpp. User-facing documentation is in `README.md`. This is its own repository (github.com/flambard/gdecl), used by applications as a git submodule, so keep it free of anything specific to an application.

## Goal and direction

GDExtension is a low-level C interface, not meant to be used directly by application developers. gdecl's goal is to raise the level of abstraction step by step until writing a Godot application in Lisp is at least as easy as with GDScript or C#, while staying efficient. Godot is mostly used for games, which are performance sensitive, so ease of use must not cost per-frame overhead.

Principles:

- **Build up gradually.** Each layer is built on the one below it: `gd-extension-ffi` (the C interface, one-to-one), then `gd-extension-types` (builtin types in Lisp), then `gd-extension-callback` (Godot's calls into Lisp), then `gd-extension` (Lisp-style helpers), then probably a third layer on top of `gd-extension` for the highest-level concepts, such as the CLOS integration below (not decided yet). Grow the framework from what the applications built on it need, and move code from an application into gdecl once the pattern is clear.
- **Keep the lower layers usable.** An application can always use a lower layer for what the higher ones don't cover yet, or for a hot path.
- **Do the work up front, not per call.** Look up method binds, StringNames and constructors once (at initialization or registration) and cache them. Prefer `ptrcall` to Variant calls. Avoid allocating in calls that happen every frame (`_process`, `_physics_process`), e.g. by not boxing floats or creating temporary Strings. Prefer compile-time expansion (macros, code generated from `extension_api.json`) to runtime lookup and dispatch.
- **Improve gdecl as you go.** When working on an application and gdecl is missing something, or something in it could be better, add or improve it in gdecl rather than working around it in the application. Keep such changes general, not specific to the application.
- **Measure.** Before choosing a convenient but slower design for something called often, check what it costs.

Where to look for inspiration:

- **GDScript**: the API application developers know. `extends`, `@export` properties, `signal`, virtual methods such as `_ready` and `_process` that you just define, `$Node` paths, `@onready`.
- **Godot C# (`GodotSharp`)**: the closest model, a garbage-collected language binding. Engine classes are generated from `extension_api.json` as wrapper classes, with method binds cached in static fields. Builtin types such as `Vector2` are value types implemented in C#, not calls into the engine. User classes are ordinary C# classes with attributes (`[Export]`, `[Signal]`), and a source generator writes the registration code. Godot objects and managed objects are linked through a GC handle, and `RefCounted` lifetimes are tied to the managed object.

### CLOS integration (idea, not yet decided)

It would be good if Godot classes were CLOS classes, so that an application writes something like:

```lisp
(define-godot-class player (sprite-2d)
  ((speed :initform 400.0 :type float :export t))
  (:signals (hit)))

(defmethod process ((self player) delta) ...)
```

Things to find out:

- **Defining classes**: a macro over `defclass`, or a metaclass (`godot-class`) through the MOP, that also registers the class with `classdb_register_extension_class`. Exported slots become properties.
- **Instances**: `create_instance_func` creates the Lisp instance next to the Godot object. Godot only holds a pointer, so the link must keep the Lisp object reachable for the GC (an index into a table, like `*bound-methods*`) and be removed when Godot frees the object.
- **Virtual methods**: generic functions (`process`, `ready`, `input`, …) whose methods are found once, in `get_virtual_call_data`, not at every call. Only report a virtual as implemented when the class has a method for it, so Godot doesn't call into Lisp for nothing.
- **Engine classes**: generate a CLOS class and functions for each Godot class from `extension_api.json`, with method binds cached. Plain (inlinable) functions are cheaper than generic functions; use generic dispatch only where the application can override something.
- **Wrapping engine objects**: the same Godot object should map to the same Lisp wrapper (instance bindings, `object_set_instance_binding`). `RefCounted` objects need reference counting tied to the wrapper's lifetime (finalizers).
- **Builtin types**: `Vector2`, `Color`, etc. as Lisp structs or specialized arrays with arithmetic in Lisp, without calls into Godot. Mind `real_t` (single precision in the `float_64` build configuration).
- **Cost of CLOS dispatch in ECL** for methods called every frame, and whether caching the effective method is enough.

Lisp can also offer what GDScript and C# can't easily: redefining functions and classes in a running game, and a REPL connected to Godot.

## Layout

- `gdecl.asd`: the ASDF system `gdecl`, with its Lisp code in `lisp/`.
- `LICENSE`: MIT.
- `lisp/packages.lisp`: the packages `gd-extension-ffi` (nickname `gdext-ffi`), `gd-extension-types` (nickname `gdext-types`), `gd-extension-callback` (nickname `gdext-callback`) and `gd-extension` (nickname `gdext`).
- `lisp/gd-extension-ffi.lisp`, `lisp/gd-extension-types.lisp`, `lisp/gd-extension-callback.lisp` and `lisp/gd-extension.lisp`: the four layers, see below.
- `src/gdecl.c`: the C bootstrap, the extension's entry point.
- `gdecl.mk`: the make rules for the whole build (Lisp and C), included by an application's Makefile.
- `src/gdextension_interface.h` and `extension_api.json`: generated by Godot, see Build.
- `package-ffi-symbols.txt` and `package-si-symbols.txt`: the symbols exported by ECL's `FFI` and `SI` packages, for reference while writing FFI code.

## Build

- `gdecl.mk` builds the application's ASDF system (`SYSTEM`) with `:monolithic t`, so its dependencies, including `gdecl`, are compiled into the same library. The output is always `$(BUILD_DIR)/application.a` with the init function `init_lib_APPLICATION` (`:init-name`), whatever the application is called. `src/gdecl.c` calls `init_lib_APPLICATION` by name; keep the two in sync.
- `gdecl.mk` finds its own directory through `MAKEFILE_LIST`, so gdecl can live at any path. It puts its own directory and the application's `LISP_DIRS` on `asdf:*central-registry*`.
- Changing `SYSTEM` doesn't make `application.a` out of date; use `make -B`.
- `gdecl.mk` then compiles `src/*.c` into `BUILD_DIR` (default `build`) and links the objects and `application.a` into `LIBRARY`. ECL's flags come from `ecl-config --cflags` and `--ldflags`; `application.a` goes before them, so before `-lecl`. The library depends on `application.a`, so Lisp changes relink it. The compiler is `CC` if set on the command line or in the environment, otherwise clang if installed, otherwise `cc`. `CFLAGS` defaults to a debug build (`-O0 -g`).
- `src/gdextension_interface.h` and `extension_api.json` are generated with `godot --dump-gdextension-interface` and `--dump-extension-api-with-docs` (`make godot-api`). They're ignored by `.gitignore`; don't edit them by hand. The `EditorSettings not instantiated yet` error Godot prints while dumping is harmless.

## Startup flow

1. Godot calls `gdecl_library_init` (`src/gdecl.c`). It keeps `get_proc_address` and the class library in static variables until ECL is booted.
2. At `GDEXTENSION_INITIALIZATION_SCENE`, `initialize_gdecl_module`:
   - disables ECL's signal trapping (SIGSEGV etc.) so it doesn't conflict with Godot's handlers,
   - calls `cl_boot`, then `ecl_init_module(NULL, init_lib_APPLICATION)`. This loads the Lisp code, and the application's top-level forms register its entry point with `gd-extension:add-initialize-hook`,
   - evaluates `(gd-extension:initialize get-proc-address class-library)` with `si_safe_eval`, passing the pointers as foreign-pointer objects (`ecl_make_pointer`). This is the only Lisp function the C side calls; it knows nothing about the application.
3. `gd-extension:initialize` calls `gd-extension-ffi:load-interface`, which stores `*get-proc-address*` and `*class-library*` and looks up the interface functions. It then caches the Variant constructors and runs the initialize hooks.
4. Deinit calls `cl_shutdown`.

## The four layers

- `gd-extension-ffi` (`lisp/gd-extension-ffi.lisp`) maps the GDExtension C interface one-to-one: interface function wrappers, enums and struct mirrors. Keep it free of Lisp conveniences.
  - Each interface function is kept in a variable named after the C function (`*string-name-new-with-latin1-chars*`), and called through a Lisp function with the same name without earmuffs. The variable is set in `load-interface`.
  - Function pointers returned by Godot (constructors, operator evaluators) are called with `call-*` functions. Those looked up once for every type, such as the destructors and the Variant constructors, are cached in `load-interface` too.
  - It also has the helpers for ECL's foreign memory (`cast-pointer`, `foreign-ref`, `clear-foreign-object`), since every layer needs them.
- `gd-extension-types` (`lisp/gd-extension-types.lisp`, uses `gd-extension-ffi`) has Godot's builtin types in Lisp, see below. Both layers above it convert values with it.
- `gd-extension-callback` (`lisp/gd-extension-callback.lisp`, uses `gd-extension-ffi` and `gd-extension-types`) is what runs when Godot calls into Lisp: all the callbacks (`ffi:defcallback`), and the tables and dispatchers behind them (the method dispatcher, and the class and instance tables). The callbacks themselves only convert between C and Lisp, catch errors and call the dispatchers.
- `gd-extension` (`lisp/gd-extension.lisp`, uses `gd-extension-ffi` and `gd-extension-types`, and imports from `gd-extension-callback`) is the public, Lisp-style layer: initialization and hooks, `with-` macros, and registering classes, methods, properties and signals. It fills in Godot's info structs with the callbacks' addresses (`(ffi:callback 'name)`) and adds entries to `gd-extension-callback`'s tables. It re-exports what applications need from the layers below, such as `cast-pointer` and `instance-object`.
- The dependencies only go downwards; keep it that way.
- Don't look anything up in Godot at load time, only in `load-interface`/`initialize` or later. ASDF loads the framework into the build image to compile what depends on it, and there's no Godot there.

## FFI notes

- Interface functions are looked up with `get-proc-address` and called with `si:call-cfun`. Godot structs are mirrored with `ffi:def-struct`. Sizes such as `+string-name-size+` come from `builtin_class_sizes` in `extension_api.json`, build configuration `float_64`. Check new struct mirrors against C with `sizeof`/`offsetof`.
- A `:pointer-void` returned by a foreign function has no size in ECL, so its slots can't be accessed until it's cast: use `cast-pointer`, or `foreign-ref` for `((TYPE *)p)[i]`.
- Godot → Lisp callbacks use `ffi:defcallback`, and `(ffi:callback 'name)` gives the C function pointer. `defcallback` accepts fewer types than `si:call-cfun`: `:uint8-t` is rejected, so declare `GDExtensionBool` as `:unsigned-byte`.
- Wrap every callback body in `handler-case`. A Lisp error must never unwind through Godot's C frames.
- With `ptrcall`, an `Object` argument is passed as a pointer to the object pointer, and every argument must be given, including those with default values.
- Method binds need the method's hash from `extension_api.json`. `classdb_get_method_bind` returns NULL if the hash doesn't match.

## Method dispatcher

All methods bound with `bind-method` share one pair of callbacks, `method-call` (Variants) and `method-ptrcall` (raw values). `method_userdata` is an index into `*bound-methods*`, a table of `bound-method` descriptors (function, return type and argument types, see `register-method`). `register-method` looks up the `value-type` of each argument and the return value once (see Builtin types), and the dispatcher converts with them. It handles the types with a raw value that can also be a Variant: currently `bool`, `int`, `float`, Vector2, Rect2 and Object (the object pointer; in a ptrcall, Godot passes a pointer to it). Bound functions get the instance's Lisp object (`instance-object`), like `self` in GDScript. In a Variant call, an Object argument also accepts Nil (GDScript's `null`), as a NULL pointer.

## Classes

`register-class` registers an extension class with `classdb_register_extension_class4`. All classes share the callbacks `create-instance` and `free-instance`; `class_userdata` is an index into `*extension-classes*` (see `add-extension-class`). `create-instance` constructs an object of the parent class with `classdb_construct_object` and makes it an instance of the extension class with `object_set_instance`. The class's constructor makes the instance's Lisp object, kept in `*instances*` so the GC can reach it; the `GDExtensionClassInstancePtr` is an index into that table (`instance-object`). Virtual methods (`bind-virtual`) use `get_virtual_call_data_func` and `call_virtual_with_data_func`, not `get_virtual_func`. A virtual method is registered like a bound method (`register-method`), and its `method_userdata` is the call data; Godot calls it with raw values, as with `ptrcall`, so `call-virtual-with-data` uses `ptrcall-bound-method`. `get-virtual-call-data` compares the name with each of the class's virtuals with Godot's StringName `==` (`*string-name-equal-evaluator*`), and returns NULL for virtuals the class doesn't implement, so Godot doesn't call into Lisp for them. Godot asks once per object and virtual method, the first time it would call it. The argument and return types of a virtual method are given by the application for now; they could be generated from `extension_api.json`.

## Builtin types and engine methods

- `gd-extension-types` has Lisp structs for Godot's builtin types (`vector2`, `rect2`), with `read-` and `write-` functions for raw values and `write-variant`; `gd-extension` re-exports what applications use.
- `*value-types*` in `gd-extension-types` is the one table of how each type converts between raw values and Lisp values (`value-type`: FFI type, reader, writer, destructor; `find-value-type`). Both the method dispatcher and `define-engine-method` use it; add a type there. The readers and writers take untyped pointers, as Godot passes them, and cast them themselves. StringName and NodePath have no FFI type: they're passed as the pointer to them. `:variant` stands for any Variant. The FFI mirrors of the raw values are named `godot-vector2` and `godot-rect2`, like `godot-string`, so the plain names are free for the Lisp types. Their layouts come from `builtin_class_member_offsets` in `extension_api.json` (`float_64`: `real_t` is `float`).
- Things looked up in Godot once, such as method binds, StringNames (`sname`), NodePaths (`npath`) and singletons (`singleton`), are kept in initialize cells (`make-initialize-cell`): a cons whose car `initialize` computes before running the initialize hooks (or `make-initialize-cell` right away, if `initialize` has run, e.g. at a REPL). Code gets the cons with `load-time-value`, so there is no lookup per call, and nothing is looked up at load time.
- `define-engine-method` expands into a `defun` that calls a Godot method with `object_method_bind_ptrcall`, with its method bind in an initialize cell. The generated code converts each argument and the result with the readers and writers in `*value-types*`, called directly, and destroys raw values that have a destructor after the call. The return slot is zeroed before a ptrcall: Godot assigns the result into it (e.g. `Ref<T>` and `PackedStringArray` assignment), which releases the old value first.
- A RefCounted result comes with a reference the caller owns (Godot encodes it as a `Ref<T>` in the return slot); `add-reference` takes a reference (`RefCounted.reference()`), for RefCounted objects Lisp keeps, e.g. in a property's slot; `release-reference` gives one back with `RefCounted.unreference()` and `object_destroy`s the object if that was the last one, and `with-reference` does it around a body. Engine methods don't do this themselves yet, since they don't know which classes are RefCounted; generating them from `extension_api.json` could. A Variant argument has the type `:variant` (Godot's variant types have no "any Variant"); it's made from the Lisp value by its Lisp type with `write-variant`. A StringName or NodePath argument is passed as the pointer to it, and an Object as the object pointer. In a ptrcall, a float is always a double and an int an `int64_t`, whatever the `meta` in `extension_api.json`. Arguments with a default value become `&optional`. Vararg methods can't be called with ptrcall, so they have their own macro, `define-engine-vararg-method`. They go through `object_method_bind_call` with every argument converted to a Variant (`variant-call-method-form`), a call error becomes a Lisp error, and the Variants are destroyed afterwards. Extra arguments beyond the declared ones aren't supported yet; they'd need converting Lisp values to Variants by their Lisp type. The method's hash and signature are given by hand for now, and could be generated from `extension_api.json`.
- Calls allocate a little (the argument list of `si:call-cfun`, and Lisp structs for Vector2 results). Measure before optimizing.
- `register-class` makes runtime classes (`is_runtime`) unless given `:tool t`: in the editor, instances are placeholders that keep their properties but run no code, like GDScript without `@tool`.
