# TODO

From a review on 2026-10-13, updated on 2026-10-14 after fixing the bugs it found and the performance work (`define-builtin-type`, static FFI calls, cheaper callbacks). File references are in `lisp/` unless shown otherwise. `make bench` measures calls between Lisp and Godot.

## Bugs

- [ ] **D. Any foreign pointer counts as an Object.** `lisp-variant-type` (`gd-extension-types.lisp`) maps any `si:foreign-data` to Object. So an `sname` passed to `object-emit-signal`'s extra arguments becomes an Object Variant of a StringName pointer, which will most likely crash Godot. Now that every object Godot gives Lisp is a `godot-object` (I, step 1), and `singleton` returns one too, raw pointers needn't be Objects in Variants: make `lisp-variant-type` accept only `godot-object`s, and say so in the README (a raw pointer can still be passed to engine methods' Object arguments).

## Performance (measure with `make bench` before and after)

Where things stand: an engine call from Lisp costs 0.5–0.7 µs (GDScript: 50–100 ns), a vararg one (`emit_signal`) 2.1 µs (130 ns), a call into a Lisp method with ptrcall, like `_process`, 0.7–0.9 µs (into a GDScript method: 0.25 µs; an empty callback alone: 0.3 µs), and a Lisp signal handler 1.3–1.7 µs on top of the emit (a GDScript handler: 0.45 µs). Results vary by about 15% from run to run.

- [ ] **L. Engine calls in one piece of C.** What's left of an engine call's cost is mostly allocation: a `malloc` and a Lisp pointer object for each raw value, the argument array and the result (`with-foreign-memory` in `ptrcall-method-form`, `engine-methods.lisp`). For methods whose types are all simple (bool, int, float, Object, StringName/NodePath pointers, and builtin types made of floats), the whole call could be one `ffi:c-inline` with C locals for the argument array and the raw values, returning the result (multiple values for a Vector2). Other types keep today's path.
- [ ] **N. The rest of a call into Lisp.** Of the 0.7–0.9 µs of a ptrcall, about 0.3 µs is the method and instance lookups (`userdata-method`, `instance-object`), boxing a float argument as a Lisp double, and calling the user's function by name, which is what makes redefinition work. A Lisp signal handler (`callable-call`) costs 1.3–1.7 µs on top of the emit, against 0.45 µs for a GDScript handler, of which Godot's dispatch to a custom Callable is 0.4 µs; the rest is spread over small steps (the protection, `set-call-error`, `read-variant` for each argument, `apply`, writing the result as a Variant), each tens of nanoseconds, mostly calls between files (about 50 ns each in ECL). Measure each before changing anything.
- [ ] **O. Variant calls into Lisp have no invokers.** `call-bound-method` (a call through `call()` or an untyped GDScript variable, about 1.9 µs) still builds an argument list and converts each argument through the value-type table. Invokers like `ptrcall-invoker-form`'s would help, but Variant calls are rarely per frame.

## The high-level layer (see "The high-level layer" in `CLAUDE.md`)

- [ ] **P. CLOS or a specialized DSL: measure and prototype.** Before building the high-level layer, measure CLOS in ECL with micro-benchmarks like those for the FFI work: a generic function call with one and two specialized arguments, `slot-value` against an accessor, `make-instance`, and calling an effective method computed once. Then write one real class, such as the game's Player, both with CLOS and with `define-class`, and compare ease of use and `make bench` numbers. Include dropping down: one hot method of the class written at a lower level (no generic dispatch, typed, non-allocating), to see that it can be done cleanly inside a high-level class. That decides between CLOS, a specialized DSL or a hybrid, and shapes I, J and K.

## When the high-level layer or REPL work starts

- [ ] **I. Engine objects as wrappers with identity: the rest.** Step 1 is done: every Godot object has one Lisp object (a `godot-object`, through Godot's instance bindings), so `eq` works, and a freed object's Lisp object signals an error when used (`valid-object-p`). It costs about 60 ns per Object result. What's left:
  - Typed wrappers: a wrapper type per engine class, mirroring Godot's inheritance (e.g. structs with `:include`, or CLOS classes, as P decides), so `typep`, `typecase` and `defmethod` work on engine objects. An object whose class isn't defined in Lisp gets the type of its nearest defined ancestor.
  - Maybe: RefCounted lifetimes tied to Lisp's GC (the binding's `reference_callback`, weak references and finalizers, as C# does), instead of the autorelease pool and `setf-reference`, if those turn out to be a burden.
- [ ] **J. Tables keyed by name, updated in place.** `*bound-methods*`, `*extension-classes*`, `*instances*` and `*callables*` (`gd-extension-callback.lisp`) are hand-written, append-only and keyed by `(1+ index)` pointers. Redefining a class at a REPL adds a duplicate entry, `add-virtual` finds the stale first one, and re-registered methods are never replaced. Use one table abstraction, key classes and methods by name, and update entries in place. Godot caches `get_virtual_call_data`, so a virtual added later isn't picked up. Redefining a struct with changed slots is undefined: an argument for `defclass` in the high-level layer.
- [ ] **K. Shared callers per signature.** Every engine method has its own conversion code. Many methods share a signature, so one shared caller per signature with tiny per-method wrappers would cut library size and build time, for one extra function call per engine call. Re-measure first: the static FFI calls shrank the game's library from 13.6 MB to 7.4 MB, so the "15 KB per method" in `CLAUDE.md` is out of date. Matters before generating all engine classes, or CLOS classes. L would change this code too, so decide K and L together.

## Small things

- [ ] `gd-extension` exports internals: `register-method`, `make-property`, `make-property-full`, `destruct-property` (`packages.lisp`).
- [ ] Variant types are listed in three places: the constants (`gd-extension-ffi.lisp`), their exports (`packages.lisp`) and `*variant-type-names*` (`extension-api.lisp`). One table and a macro could produce all three.
- [ ] Filling C structs repeats `(setf (ffi:get-slot-value …))` slot by slot (`bind-method`, `register-class` and `make-property-full` in `binding.lisp`, `write-callable` in `gd-extension-callback.lisp`): a `set-foreign-slots` macro, which could also write the slots with `foreign-ref` at their offsets instead of `get-slot-value` (about 5 µs a slot). That matters for `write-callable`, about 25 µs for every Callable made, e.g. by `connect-signal`. `make-property` and `destruct-property` aren't protected by `unwind-protect`, so an error during registration leaks the property infos: a `with-property-infos` macro.
- [ ] StringNames are created with latin1 in some places (`with-string-name`, `new-string-name` in `gd-extension.lisp`) and UTF-8 in others (temporary names).
- [ ] Debug `printf`s in `src/gdecl.c` run on every launch.
- [ ] `classdb-register-extension-class2` and `class-creation-info2` are deprecated and unused; `PackedStringArray.size`'s hash is hardcoded in `load-interface` (`gd-extension-ffi.lisp`).

## Suggested order

1. D: the one bug left.
2. L, decided together with K. These are the biggest remaining costs per call.
3. The small things, when touching that code anyway.
4. N and O, if measurements show they matter.
5. P, before starting the high-level layer.
6. I, J and K with the high-level layer or REPL work, which they shape.
