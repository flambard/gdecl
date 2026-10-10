# gdecl

gdecl is a framework for programming [Godot](https://godotengine.org) 4 with Common Lisp, using [Embeddable Common Lisp](https://ecl.common-lisp.dev) (ECL). Your Lisp code is compiled into a GDExtension library. A small C bootstrap boots ECL inside Godot, and from then on everything is done from Lisp: it looks up the GDExtension interface functions, registers classes, methods, properties and signals, and handles Godot's callbacks.

gdecl is a proof of concept. Its API is incomplete and will change.

## Requirements

- Godot ≥ 4.4
- ECL, with `ecl-config` on `PATH`
- GNU Make, SCons and a C compiler (clang is used if it's installed)

## Setting up an application

An application is a directory with gdecl in it (for example as a git submodule), its own ASDF system and a Godot project:

```
my-app/
  gdecl/              this framework
  lisp/my-app.asd     your ASDF system
  lisp/*.lisp
  project/            your Godot project
  Makefile
  SConstruct
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

**The Makefile** names your ASDF system and includes gdecl's make rules:

```make
SYSTEM = my-app
include gdecl/gdecl.mk
```

`gdecl.mk` also takes `LISP_DIRS`, the directories with your `.asd` and `.lisp` files (default `lisp`), and `GODOT`, the Godot executable (default `godot`).

**The SConstruct** builds the GDExtension library into your Godot project:

```python
from SCons.Script import SConscript, Default

library = SConscript("gdecl/SConscript", variant_dir="build/gdecl", duplicate=0,
                     exports={"target": "#project/bin/libgdecl",
                              "application_lib": "#application.a"})
Default(library)
```

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
make             # Compile the Lisp code into application.a
scons            # Build the GDExtension library and link application.a
make godot-api   # Regenerate the Godot API files, e.g. after upgrading Godot
make clean
```

Run `make` before `scons`, and again after changing any Lisp code. SCons doesn't track the Lisp sources. The first `make` runs Godot once to dump `gdextension_interface.h` and `extension_api.json` into `gdecl/`.

## Packages

- **`gd-extension`** (nickname `gdext`): the Lisp-style API.
  - `add-initialize-hook` registers your entry point.
  - `with-string-name` and `with-string` create Godot StringNames and Strings, and destroy them again.
  - `get-method-bind` looks up a Godot method, so you can call it with `object-method-bind-ptrcall`.
  - `bind-method`, `bind-property` and `bind-signal-1` register your class's methods, properties and signals. Bound methods can take and return `bool`, `int` and `float`.
  - `cast-pointer`, `foreign-ref` and `clear-foreign-object` help with foreign memory.
- **`gd-extension-ffi`** (nickname `gdext-ffi`): the GDExtension C interface, mapped one-to-one. It contains the interface functions (`classdb-register-extension-class2`, `object-method-bind-ptrcall`, …), the enums (`+variant-type-float+`, …) and Lisp mirrors of the C structs. Use it for anything the `gd-extension` package doesn't cover yet.
