/**
 * WASM runtime entry point and `_d_run_main` implementation.
 *
 * `_start` is a thin WASI shim that calls `main()` and `proc_exit`s its
 * result — it does NOT initialize druntime.  Druntime init lives in
 * `_d_run_main`, which the compiler-generated `main` wrapper (from
 * `core.internal.entrypoint`, for D `main` only) calls.  An `extern(C)`
 * user `main` bypasses druntime init the same way it does on Linux.
 *
 * Both the user's `extern(C) int main()` and the mixin-generated `int main()`
 * use the uniform WASM signature `() -> i32` (WASI has no argc/argv).
 *
 * Copyright: Copyright (C) 1999-2026 by The D Language Foundation, All Rights Reserved
 * License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 */
module rt.wasm.start;

nothrow:
extern (C):

// Provided by rt/wasm/gc.d
void gc_init();
void gc_term();

// wasm-ld synthesizes __wasm_call_ctors from object .init_array / .ctors and
// .Linking custom-section init functions.  wasi-libc relies on it to set up
// stdio buffers (FILE* for stdout/stderr) before any printf can succeed.
private extern(C) void __wasm_call_ctors() @nogc nothrow;
private extern(C) void __wasm_call_dtors() @nogc nothrow;

// `main` is either the user's extern(C) main or the compiler-generated
// mixin wrapper (for D main).  Both have signature `() -> int` on WASM.
private extern(C) int main(int argc, char** argv) nothrow;

// ── WASI _start entry point ───────────────────────────────────────────────────
// wasmtime (WASI command ABI) calls _start, not main.  proc_exit called from
// _start correctly propagates the exit code to the shell; called from main it
// does not (wasmtime exits 0 regardless of the argument).
export void _start() nothrow
{
    __wasm_call_ctors();
    int rc = main(0, null);
    __wasm_call_dtors();
    proc_exit(rc);
    while (true) {}
}

// Module ctor/dtor execution reuses the canonical rt.minfo.ModuleGroup, bridged
// to the wasm-ld "minfo" segment brackets by rt.sections_wasm.  initSections
// populates the single SectionGroup from those brackets before the ctors run.
import rt.sections : initSections;
extern(C) void rt_moduleCtor();
extern(C) void rt_moduleTlsCtor();
extern(C) void rt_moduleUnitTests();
extern(C) void rt_moduleTlsDtor();
extern(C) void rt_moduleDtor();
extern(C) void rt_coverWrite();

// Called by the compiler-generated `main` wrapper (for D main).
private alias MainFunc = extern(C) int function(char[][] args);

private extern(C) void* calloc(size_t, size_t) @nogc nothrow;

// Fetch program arguments from WASI (heap-staged: the buffers must not live
// in static data, where cross-object layout is fragile). Runtime arguments
// (--DRT-*) are consumed here like native druntime does, so user code never
// sees them.
private char[][] wasiArgs() @nogc nothrow
{
    size_t nargs, buflen;
    if (args_sizes_get(&nargs, &buflen) != 0 || nargs == 0)
        return null;
    auto ptrs = cast(char**) calloc(nargs, (char*).sizeof);
    auto buf = cast(char*) calloc(1, buflen ? buflen : 1);
    auto arr = cast(char[]*) calloc(nargs, (char[]).sizeof);
    if (!ptrs || !buf || !arr || args_get(ptrs, buf) != 0)
        return null;
    size_t n = 0;
    foreach (i; 0 .. nargs)
    {
        char* p = ptrs[i];
        size_t len = 0;
        while (p[len]) len++;
        if (len >= 6 && p[0 .. 6] == "--DRT-")
            continue;
        arr[n++] = p[0 .. len];
    }
    return arr[0 .. n];
}

int _d_run_main(int argc, char** argv, MainFunc mainFunc)
{
    gc_init();
    initSections();
    rt_moduleCtor();
    rt_moduleTlsCtor();
    rt_moduleUnitTests();
    int result = mainFunc(wasiArgs());
    rt_moduleTlsDtor();
    rt_moduleDtor();
    rt_coverWrite();
    gc_term();
    return result;
}

void _d_initMonoTime() @nogc {}

import core.attribute : wasmImportModule;

// WASI proc_exit: (i32) -> () — terminates the process, never returns.
// Single declaration avoids duplicate-import linker errors.
@wasmImportModule("wasi_snapshot_preview1")
private extern(C) void proc_exit(int code) @nogc nothrow;

@wasmImportModule("wasi_snapshot_preview1")
private extern(C) int args_sizes_get(size_t* argc, size_t* buflen) @nogc nothrow;

@wasmImportModule("wasi_snapshot_preview1")
private extern(C) int args_get(char** argv, char* buf) @nogc nothrow;

private extern(C) int fflush(void* stream) @nogc nothrow;

noreturn _wasm_trap(int code) @nogc nothrow
{
    // proc_exit skips wasi-libc's atexit flushing; flush explicitly so
    // buffered stdout (printf) isn't lost on the abort path.
    fflush(null);
    proc_exit(code);
    while (true) {} // noreturn: proc_exit never returns
}
