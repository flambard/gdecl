# SCons build of the gdecl GDExtension library. Call it from the
# application's SConstruct, e.g.:
#
#   library = SConscript("gdecl/SConscript", variant_dir="build/gdecl", duplicate=0,
#                        exports={"target": "#demo/bin/libgdecl",
#                                 "application_lib": "#application.a"})
#
#   target           The shared library to build, without extension
#   application_lib  The static library with the Lisp code, from gdecl.mk
#
# Paths starting with # are relative to the application's SConstruct.
# Returns the library node.
Import("target", "application_lib")

env = Environment()

## ECL
# output from: ecl-config --cflags
ecl_cflags = ["-Dlinux", "-I/usr/include"]
# output from: ecl-config --ldflags
ecl_ldflags = ["-L/usr/lib/x86_64-linux-gnu", "-lecl", "-Wl,-z,relro", "-lgc", "-lgc", "-lgc", "-lpthread", "-ldl", "-lm"]

# Set the compiler and flags.
env.Append(CPPPATH = ["src"])
env.Append(CFLAGS = ["-O0", "-g"] + ecl_cflags)  # Make it a debug build.
env.Append(LINKFLAGS = ecl_ldflags)

# Use Clang on macOS.
# if sys.platform == "darwin":
#     env["CC"] = "clang"
env["CC"] = "clang"

library = env.SharedLibrary(
    target = target,
    source = Glob("src/*.c"),
    LIBS = [File(application_lib)]
)

Return("library")
