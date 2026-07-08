/**
 * WASI entry-point shim for `-betterC` WebAssembly programs.
 *
 * A betterC program links no druntime, so the `_start` provided by
 * `rt/wasm/start.d` (which lives in libdruntime-wasm.a) is unavailable.  This
 * tiny object supplies an equivalent: wasmtime's WASI command ABI calls
 * `_start`, which initializes the C runtime (wasi-libc stdio buffers via
 * `__wasm_call_ctors`), calls the user's `main`, runs C destructors, then
 * `proc_exit`s the result so the shell sees the correct exit code.
 *
 * It is built as a standalone `.wasm` object (NOT part of libdruntime-wasm.a)
 * and linked by `dmd.link` only in betterC mode.
 *
 * The front end mangles a betterC `extern(C)` main into the wasi-libc crt entry
 * names `__main_void` / `__main_argc_argv` (by arity, see dmd.mangle); `_start`
 * calls `__main_void`, which wasi-libc's weak wrapper bridges to
 * `__main_argc_argv` after fetching WASI argc/argv when main declared params.
 *
 * Copyright: Copyright (C) 1999-2026 by The D Language Foundation, All Rights Reserved
 * License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 */
module rt.wasm.start_betterc;

nothrow:
extern (C):

// Synthesized by wasm-ld from object .init_array / .ctors; wasi-libc relies on
// it to set up stdio FILE buffers before any printf can succeed.
private extern(C) void __wasm_call_ctors() @nogc nothrow;
private extern(C) void __wasm_call_dtors() @nogc nothrow;

// wasi-libc's crt entry: the app's `int main(void)` (`__main_void`), or the
// weak libc.a wrapper bridging to the app's `__main_argc_argv`.
private extern(C) int __main_void() nothrow;

import core.attribute : wasmImportModule;

// WASI proc_exit: (i32) -> () — terminates the process, never returns.
@wasmImportModule("wasi_snapshot_preview1")
private extern(C) void proc_exit(int code) @nogc nothrow;

export void _start() nothrow
{
    __wasm_call_ctors();
    int rc = __main_void();
    __wasm_call_dtors();
    proc_exit(rc);
    while (true) {}
}

// wasi-libc exposes `errno` as a plain global, but DMD's musl-style
// core.stdc.errno binding references `__errno_location`.  Provide it here so
// betterC programs that touch errno link without pulling in druntime.
private extern(C) extern __gshared int errno;
ref int __errno_location() @nogc nothrow { return errno; }
