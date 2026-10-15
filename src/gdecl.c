#include <stdbool.h>
#include <stdio.h>
#include <ecl/ecl.h>

#include "gdextension_interface.h"

#if !defined(GDE_EXPORT)
#if defined(_WIN32)
#define GDE_EXPORT __declspec(dllexport)
#elif defined(__GNUC__)
#define GDE_EXPORT __attribute__((visibility("default")))
#else
#define GDE_EXPORT
#endif
#endif // ! GDE_EXPORT

// Given to gdecl_library_init, kept until ECL is booted and they can be
// passed to gd-extension-callback:initialize.
static GDExtensionInterfaceGetProcAddress get_proc_address = NULL;
static GDExtensionClassLibraryPtr class_library = NULL;

static void initialize_gdecl_module(void *p_userdata, GDExtensionInitializationLevel p_level)
{
    if (p_level != GDEXTENSION_INITIALIZATION_SCENE)
    {
        return;
    }

    // Perhaps we don't have to disable all of them?
    ecl_set_option(ECL_OPT_TRAP_SIGSEGV, ecl_fixnum(0));
    ecl_set_option(ECL_OPT_TRAP_SIGFPE, ecl_fixnum(0));
    ecl_set_option(ECL_OPT_TRAP_SIGINT, ecl_fixnum(0));
    ecl_set_option(ECL_OPT_TRAP_SIGILL, ecl_fixnum(0));
    ecl_set_option(ECL_OPT_TRAP_INTERRUPT_SIGNAL, ecl_fixnum(0));
    ecl_set_option(ECL_OPT_SIGNAL_HANDLING_THREAD, ecl_fixnum(0));

    char *argv[] = {"ecl", "--norc"};
    cl_boot(2, argv);

    if (ecl_get_option(ECL_OPT_BOOTED) != 1)
    {
        fprintf(stderr, "gdecl: ECL failed to boot\n");
        return;
    }

    /* Initialize the Lisp library we linked in (application.a, see the Makefile).
     * Loading it lets the application register its initialize hooks.
     */
    extern void init_lib_APPLICATION(cl_object);
    ecl_init_module(NULL, init_lib_APPLICATION);

    // Set up the Lisp side, which then runs the application's initialize hooks:
    // (gd-extension-callback:initialize get-proc-address class-library)
    cl_object initialize = cl_list(3, ecl_read_from_cstring("gd-extension-callback:initialize"),
                                   ecl_make_pointer((void *)get_proc_address),
                                   ecl_make_pointer(class_library));
    si_safe_eval(2, initialize, ECL_NIL);
}

static void deinitialize_gdecl_module(void *p_userdata, GDExtensionInitializationLevel p_level)
{
    if (p_level != GDEXTENSION_INITIALIZATION_SCENE || ecl_get_option(ECL_OPT_BOOTED) != 1)
    {
        return;
    }

    // Let the Lisp side clean up while Godot can still be called:
    // (gd-extension-callback:deinitialize)
    cl_object deinitialize = cl_list(1, ecl_read_from_cstring("gd-extension-callback:deinitialize"));
    si_safe_eval(2, deinitialize, ECL_NIL);

    cl_shutdown();
}

GDExtensionBool GDE_EXPORT gdecl_library_init(GDExtensionInterfaceGetProcAddress p_get_proc_address, GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization)
{
    get_proc_address = p_get_proc_address;
    class_library = p_library;

    r_initialization->initialize = initialize_gdecl_module;
    r_initialization->deinitialize = deinitialize_gdecl_module;
    r_initialization->userdata = NULL;
    r_initialization->minimum_initialization_level = GDEXTENSION_INITIALIZATION_SCENE;

    return true;
}
