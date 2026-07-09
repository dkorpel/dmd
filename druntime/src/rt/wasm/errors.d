/**
 * Libc-level error hooks for WebAssembly.
 * The D runtime error hooks (assert, bounds, …) live in core.exception and
 * throw catchable Errors; this module only covers the C-side entry points.
 *
 * Copyright: Copyright (C) 1999-2026 by The D Language Foundation, All Rights Reserved
 * License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 */
module rt.wasm.errors;

nothrow:
extern (C):

private extern(C) noreturn _wasm_trap(int code) @nogc nothrow;

// Failure markers go through raw fd_write so they survive even when libc
// state or the heap is unusable.
import core.attribute : wasmImportModule;
struct WasmCiovec { const(void)* buf; size_t len; }
@wasmImportModule("wasi_snapshot_preview1")
private extern(C) int fd_write(int fd, const(WasmCiovec)* iovs, size_t n, size_t* nwritten) @nogc nothrow;

private void dbgWrite(scope const(char)[] s) @nogc nothrow
{
    WasmCiovec io = WasmCiovec(s.ptr, s.length);
    size_t nw;
    fd_write(2, &io, 1, &nw);
}

// __assert_fail is deliberately NOT defined here: wasi-libc's assert.o always
// provides it, and a second strong definition collides when a threads-enabled
// libc.a pulls its assert.c.obj internally (wasm-ld has no weak-def override).
noreturn __assert(const(char)* file, int line, const(char)* msg) @nogc nothrow { dbgWrite("__ASSERT\n"); _wasm_trap(1); }

private extern(C) extern __gshared int errno;
ref int __errno_location() @nogc nothrow { return errno; }
