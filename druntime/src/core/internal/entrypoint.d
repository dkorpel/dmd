/**
 This module contains the code for C main and any call(s) to initialize the
 D runtime and call D main.

  Copyright: Copyright Digital Mars 2000 - 2019.
  License: Distributed under the
       $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0).
     (See accompanying file LICENSE)
  Source: $(DRUNTIMESRC core/_internal/_entrypoint.d)
*/
module core.internal.entrypoint;

/**
A template containing C main and any call(s) to initialize druntime and
call D main.  Any module containing a D main function declaration will
cause the compiler to generate a `mixin _d_cmain();` statement to inject
this code into the module.
*/
template _d_cmain()
{
    version (WebAssembly)
    {
        // WASM needs a typed _Dmain wrapper (always `(char[][]) -> int`) because
        // call_indirect requires an exact signature match, and the user's main
        // may have a different one. The compiler mangles the user's main as
        // `__d_user_main` so this wrapper can own the `_Dmain` symbol. We use
        // pragma(mangle) on both wrappers so that `main` inside the template
        // body still refers to the user's function.
        private extern(C) int _d_run_main(int argc, char** argv, void* mainFunc) nothrow;

        pragma(mangle, "main")
        extern(C) int __wasm_c_main(int argc, char** argv) nothrow
        {
            return _d_run_main(argc, argv, &__wasm_Dmain);
        }

        // Avoid wrapping `main` in a lambda — the WASM backend has no closure
        // support yet, so a nested call that captures `args` traps. Inline the
        // dispatch into each static-if branch instead.
        pragma(mangle, "_Dmain")
        extern(C) int __wasm_Dmain(char[][] args)
        {
            static if (is(typeof(main(cast(string[]) args)) == int))
                return main(cast(string[]) args);
            else static if (is(typeof(main(args)) == int))
                return main(args);
            else static if (is(typeof(main()) == int))
                return main();
            else static if (is(typeof(main(cast(string[]) args))))
            { main(cast(string[]) args); return 0; }
            else static if (is(typeof(main(args))))
            { main(args); return 0; }
            else
            { main(); return 0; }
        }
    }
    else
    {
        extern(C)
        {
            int _d_run_main(int argc, char **argv, void* mainFunc);

            int _Dmain(char[][] args);

            int main(int argc, char **argv)
            {
                return _d_run_main(argc, argv, &_Dmain);
            }

            // Solaris, for unknown reasons, requires both a main() and an _main()
            version (Solaris)
            {
                int _main(int argc, char** argv)
                {
                    return main(argc, argv);
                }
            }
        }
    }
}
