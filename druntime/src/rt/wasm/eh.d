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

// Called by the compiler for every `throw expr` on POSIX targets.
noreturn _d_throwdwarf(Throwable o) @nogc { _wasm_trap(1); }

// No-op: stack trace capture unsupported on WASM.
Throwable.TraceInfo _d_traceContext(void* ptr = null) @nogc
{
    return null;
}

// No-op: Throwable deallocation (GC leak is acceptable on WASM).
void _d_delThrowable(scope Throwable) @nogc {}
