/**
 * WASI entry-point shim for `-betterC` WebAssembly programs.
 *
 * It is built as a standalone `.wasm` object (NOT part of libdruntime-wasm.a)
 * and linked by `dmd.link` only in betterC mode.
 *
 * Copyright: Copyright (C) 1999-2026 by The D Language Foundation, All Rights Reserved
 * License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 */
module rt.wasm.start_betterc;

nothrow:
extern (C):

private extern(C) void __wasm_call_ctors() @nogc nothrow;
private extern(C) void __wasm_call_dtors() @nogc nothrow;

private extern(C) int __main_void() nothrow;

import core.attribute : wasmImportModule;

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

private extern(C) extern __gshared int errno;
ref int __errno_location() @nogc nothrow { return errno; }
