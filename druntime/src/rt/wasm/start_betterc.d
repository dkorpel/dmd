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
 * The backend emits every betterC `main` (`int main()`, `void main()`, …) with
 * the uniform WASI signature `(i32, i32) -> i32` (see backend/wasm/obj.d
 * buildFuncType), so the fixed declaration below links against all of them.
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

// The user's betterC `main`.  Uniform WASM ABI: `(i32, i32) -> i32`.
private extern(C) int main(int argc, char** argv) nothrow;

import core.attribute : wasmImportModule;

// WASI proc_exit: (i32) -> () — terminates the process, never returns.
@wasmImportModule("wasi_snapshot_preview1")
private extern(C) void proc_exit(int code) @nogc nothrow;

export void _start() nothrow
{
    __wasm_call_ctors();
    int rc = main(0, null);
    __wasm_call_dtors();
    proc_exit(rc);
    while (true) {}
}

// wasi-libc exposes `errno` as a plain global, but DMD's musl-style
// core.stdc.errno binding references `__errno_location`.  Provide it here so
// betterC programs that touch errno link without pulling in druntime.
private extern(C) extern __gshared int errno;
ref int __errno_location() @nogc nothrow { return errno; }
