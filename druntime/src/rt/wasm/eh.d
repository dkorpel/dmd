/**
 * Exception-handling stub for WebAssembly.
 * Exceptions are not supported: any throw prints the message and traps.
 *
 * Copyright: Copyright (C) 1999-2026 by The D Language Foundation, All Rights Reserved
 * License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 */
module rt.wasm.eh;

nothrow:
extern (C):

private extern(C) noreturn _wasm_trap(int code) @nogc nothrow;

import core.attribute : wasmImportModule;
private struct Ciovec { const(void)* buf; size_t len; }
@wasmImportModule("wasi_snapshot_preview1")
private extern(C) int fd_write(int fd, const(Ciovec)* iovs, size_t n, size_t* nw) @nogc nothrow;

// Called by the compiler for every `throw expr` on POSIX targets.
// Print a marker first so the resulting exit(1) is traceable.
noreturn _d_throwdwarf(Throwable o) @nogc
{
    __gshared immutable char[6] msg = "THROW\n";
    Ciovec io = Ciovec(msg.ptr, msg.length);
    size_t nw;
    fd_write(2, &io, 1, &nw);
    _wasm_trap(1);
}

// No-op: stack trace capture unsupported on WASM.
Throwable.TraceInfo _d_traceContext(void* ptr = null) @nogc
{
    return null;
}

// No-op: Throwable deallocation (GC leak is acceptable on WASM).
void _d_delThrowable(scope Throwable) @nogc {}
