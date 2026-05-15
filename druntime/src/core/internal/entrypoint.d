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
        // On WASM the compiler mangles the user's D main() to __d_user_main so
        // it doesn't collide with the _Dmain wrapper we generate here.
        // We use pragma(mangle) for the C main wrapper so it exports the name
        // "main" at ABI level without introducing a D-level symbol named "main"
        // — keeping the D name 'main' unambiguous (it refers to the user's
        // function) inside __wasm_Dmain's static-if.

        private extern(C) int _d_run_main(int argc, char** argv, void* mainFunc) nothrow;

        // C entry point — exported as "main" for WASI / wasmtime.
        pragma(mangle, "main")
        extern(C) int __wasm_c_main(int argc, char** argv) nothrow
        {
            return _d_run_main(argc, argv, &__wasm_Dmain);
        }

        // Typed _Dmain wrapper: always (char[][] args) -> int so _d_run_main
        // can call it via call_indirect with the correct WASM type.
        // 'main' inside this body unambiguously names the user's D main because
        // our C wrapper uses a different D identifier (__wasm_c_main).
        pragma(mangle, "_Dmain")
        extern(C) int __wasm_Dmain(char[][] args)
        {
            static if (is(typeof(main(cast(string[]) args)) == int))
                return main(cast(string[]) args); // int main(string[] args)
            else static if (is(typeof(main(args)) == int))
                return main(args);                // int main(char[][] args)
            else static if (is(typeof(main()) == int))
                return main();                    // int main()
            else static if (is(typeof(main(cast(string[]) args)) == void))
            {
                main(cast(string[]) args); return 0; // void main(string[] args)
            }
            else static if (is(typeof(main(args)) == void))
            {
                main(args); return 0;             // void main(char[][] args)
            }
            else
            {
                main();                           // void main()
                return 0;
            }
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
