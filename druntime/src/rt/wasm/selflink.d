/**
 * Definitions wasm-ld normally synthesizes, for `-mwasm-selflink` builds.
 *
 * A self-linked module has no linker to generate the constructor thunks, and no
 * wasi-libc to supply the `main` wrapper `rt.wasm.start._start` calls.  The
 * backend fills in the `__wasm_call_ctors` body here with the
 * `pragma(crt_constructor)` functions of the program (`dmd.backend.wasm.selflink`),
 * and the `__main_void` bridge forwards to the `__main_argc_argv` entry that
 * druntime's `_d_cmain` mixin generates.
 *
 * Copyright: Copyright (C) 1999-2026 by The D Language Foundation, All Rights Reserved
 * License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 */
module rt.wasm.selflink;

private extern (C) int __main_argc_argv(int argc, char** argv);

extern (C) void __wasm_call_ctors() @nogc nothrow {}
extern (C) void __wasm_call_dtors() @nogc nothrow {}

extern (C) int __main_void()
{
    return __main_argc_argv(0, null);
}

// core.thread.osthread declares these for the Posix exception-context swap;
// rt.dwarfeh and rt.deh_win64_posix both gate themselves out on WebAssembly,
// where exceptions are exnref and carry no context to swap.
extern (C) void* _d_eh_swapContext(void* newContext) @nogc nothrow { return null; }
extern (C) void* _d_eh_swapContextDwarf(void* newContext) @nogc nothrow { return null; }
