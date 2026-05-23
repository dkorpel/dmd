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
pragma(mangle, "main") private extern(C) int __wasm_user_main() nothrow;

// ── WASI _start entry point ───────────────────────────────────────────────────
// wasmtime (WASI command ABI) calls _start, not main.  proc_exit called from
// _start correctly propagates the exit code to the shell; called from main it
// does not (wasmtime exits 0 regardless of the argument).
export void _start() nothrow
{
    __wasm_call_ctors();
    int rc = __wasm_user_main();
    __wasm_call_dtors();
    proc_exit(rc);
    while (true) {}
}

// ── Module constructor stubs (Phase 5) ────────────────────────────────────────
// Replaced once the minfo section / ModuleInfo iteration is wired up.

void rt_moduleCtor()  {}
void rt_moduleDtor()  {}
void rt_moduleTlsCtor() @nogc {}
void rt_moduleTlsDtor() @nogc {}

// ── _d_run_main ───────────────────────────────────────────────────────────────
// Called by the compiler-generated `main` wrapper (for D main).  Typed
// MainFunc parameter — `mainFunc(args)` lowers to call_indirect with the
// `(char[][]) -> int` signature that &_Dmain was registered with.
private alias MainFunc = extern(C) int function(char[][] args);

int _d_run_main(int argc, char** argv, MainFunc mainFunc)
{
    gc_init();
    rt_moduleCtor();
    char[][] args = null; // empty args for now (no WASI argv yet)
    int result = mainFunc(args);
    rt_moduleDtor();
    gc_term();
    return result;
}

// ── _d_initMonoTime stub ──────────────────────────────────────────────────────
void _d_initMonoTime() @nogc {}

// ── WASI abort helper (single proc_exit import across the whole runtime) ──────

import core.attribute : wasmImportModule;

// WASI proc_exit: (i32) -> () — terminates the process, never returns.
// Single declaration avoids duplicate-import linker errors.
@wasmImportModule("wasi_snapshot_preview1")
private extern(C) void proc_exit(int code) @nogc nothrow;

noreturn _wasm_trap(int code) @nogc nothrow
{
    proc_exit(code);
    while (true) {} // noreturn: proc_exit never returns
}
