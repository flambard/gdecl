# TODO

Started from a review on 2026-10-13. Done since: the bugs it found, the performance work (`define-builtin-type`, static FFI calls, cheaper callbacks, faster Variant conversion, engine calls in one piece of C for simple types), and Lisp objects for all Godot objects (identity, invalidation when freed, struct types mirroring Godot's classes). File references are in `lisp/` unless shown otherwise. `make bench` measures calls between Lisp and Godot. gdecl's first principle applies to all of it: performance first, and shift work from run time to compile time (`CLAUDE.md`).

## Performance (measure with `make bench` before and after)

Where things stand: an engine call from Lisp with only simple types costs 140–160 ns and allocates nothing (GDScript: 50–100 ns), with a Vector2 result 360–400 ns, with other types (String, Variant, …) 0.5–0.8 µs, a vararg one (`emit_signal`) 1.7 µs (130 ns), a call into a Lisp method with ptrcall, like `_process`, 0.7–0.9 µs (into a GDScript method: 0.25 µs; an empty callback alone: 0.3 µs), and a Lisp signal handler 1.3–1.7 µs on top of the emit (a GDScript handler: 0.45 µs). Results vary by about 15% from run to run.

- [ ] **N. The rest of a call into Lisp.** Of the 0.7–0.9 µs of a ptrcall, about 0.3 µs is the method and instance lookups (`userdata-method`, `instance-object`), boxing a float argument as a Lisp double, and calling the user's function by name, which is what makes redefinition work. A Lisp signal handler (`callable-call`) costs 1.3–1.7 µs on top of the emit, of which Godot's dispatch to a custom Callable is 0.4 µs; the rest is spread over small steps (the protection, `set-call-error`, `read-variant` for each argument, `apply`, writing the result as a Variant), each tens of nanoseconds, mostly calls between files (about 50 ns each in ECL). Measure each before changing anything.
- [ ] **O. Variant calls into Lisp have no invokers.** `call-bound-method` (a call through `call()` or an untyped GDScript variable, about 1.5 µs) still builds an argument list and converts each argument through the value-type table. Invokers like `ptrcall-invoker-form`'s would help, but Variant calls are rarely per frame.

## The high-level layer (see "The high-level layer" in `CLAUDE.md`)

- [ ] **P. CLOS or a specialized DSL: measure and prototype.** Before building more on `define-class`, measure CLOS in ECL with micro-benchmarks like those for the FFI work: a generic function call with one and two specialized arguments, `slot-value` against an accessor, `make-instance`, and calling an effective method computed once. Then write one real class, such as the game's Player, both with CLOS and with `define-class`, and compare ease of use and `make bench` numbers. Include dropping down: one hot method of the class written at a lower level (no generic dispatch, typed, non-allocating), to see that it can be done cleanly inside a high-level class. That decides between CLOS, a specialized DSL or a hybrid, and whether the structs of engine objects (`engine-objects.lisp`, which `defmethod` can already dispatch on) should become CLOS classes. It shapes J too.
- [ ] **J. Tables keyed by name, updated in place (with the REPL work).** `*bound-methods*`, `*extension-classes*`, `*instances*`, `*callables*` and `*bindings*` (`gd-extension-callback.lisp`) are hand-written, append-only and keyed by `(1+ index)` pointers. Redefining a class at a REPL adds a duplicate entry, `add-virtual` finds the stale first one, and re-registered methods are never replaced. Use one table abstraction, key classes and methods by name, and update entries in place. Godot caches `get_virtual_call_data`, so a virtual added later isn't picked up. Redefining a struct with changed slots is undefined: an argument for `defclass` in the high-level layer.

## Gaps

- [ ] **Q. Unsupported types.** Engine methods with types gdecl can't convert yet are skipped, so they have no functions. Most noticeable: StringName and NodePath results (e.g. `Node.get_name`, `AnimatedSprite2D.get_animation`); `string-name-string` (`engine-objects.lisp`) could be the reader. Also Color and Transform2D (builtin types made of floats: add them with `define-builtin-type`), Array, Dictionary, RID, and the packed arrays (only PackedStringArray results are supported). Add them as applications need them.
- [ ] **R. Calls from other threads.** Godot can call into Lisp from threads other than the main one (e.g. with physics on a separate thread, or `WorkerThreadPool`). ECL needs such threads registered (`ecl_import_current_thread`), which gdecl doesn't do, and its tables aren't thread-safe. Add it when an application needs it.

## Small things

- [ ] `gd-extension` exports internals: `register-method`, `make-property`, `make-property-full`, `destruct-property` (`packages.lisp`).
- [ ] Variant types are listed in three places: the constants (`gd-extension-ffi.lisp`), their exports (`packages.lisp`) and `*variant-type-names*` (`extension-api.lisp`). One table and a macro could produce all three.
- [ ] Filling C structs repeats `(setf (ffi:get-slot-value …))` slot by slot (`bind-method`, `register-class` and `make-property-full` in `binding.lisp`, `write-callable` in `gd-extension-callback.lisp`): a `set-foreign-slots` macro, which could also write the slots with `foreign-ref` at their offsets instead of `get-slot-value` (about 5 µs a slot). That matters for `write-callable`, about 25 µs for every Callable made, e.g. by `connect-signal`. `make-property` and `destruct-property` aren't protected by `unwind-protect`, so an error during registration leaks the property infos: a `with-property-infos` macro.
- [ ] StringNames are created with latin1 in some places (`with-string-name`, `new-string-name` in `gd-extension.lisp`, `make-property-full` in `binding.lisp`) and UTF-8 in others (temporary names).
- [ ] Debug `printf`s in `src/gdecl.c` run on every launch.
- [ ] `classdb-register-extension-class2` and `class-creation-info2` are deprecated and unused; `PackedStringArray.size`'s hash is hardcoded in `load-interface` (`gd-extension-ffi.lisp`).

## Suggested order

1. P: the high-level layer is gdecl's ambition, so decide its direction before building more on `define-class`. Its measurements are cheap.
2. Q, as the game needs the types.
3. N: calls into Lisp (0.7–0.9 µs) are now the biggest cost per frame left.
4. The small things, when touching that code anyway.
5. O, if measurements show it matters.
6. J with the REPL work, and R when an application uses threads.
