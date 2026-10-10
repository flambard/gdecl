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

# ECL's compiler and linker flags (defines, include and library paths, -lecl
# and its dependencies)
env.ParseConfig("ecl-config --cflags --ldflags")

# Set the compiler and flags.
env.Append(CPPPATH = ["src"])
env.Append(CFLAGS = ["-O0", "-g"])  # Make it a debug build.
# The Lisp code, before -lecl so the linker resolves its references to ECL
env.Prepend(LIBS = [File(application_lib)])

# Use Clang on macOS.
# if sys.platform == "darwin":
#     env["CC"] = "clang"
env["CC"] = "clang"

library = env.SharedLibrary(
    target = target,
    source = Glob("src/*.c")
)

Return("library")
