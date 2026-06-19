/**
 * Runtime error hooks for WebAssembly.
 * All failures print a message to stderr then trap via abort().
 *
 * Copyright: Copyright (C) 1999-2026 by The D Language Foundation, All Rights Reserved
 * License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 */
module rt.wasm.errors;

nothrow:
extern (C):

private extern(C) noreturn _wasm_trap(int code) @nogc nothrow;

private noreturn wasm_abort() @nogc nothrow { _wasm_trap(1); }

// ── debug diagnostics (temporary): print "TAG file:line\n" to stderr ──────────
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
private void dbgNum(size_t v) @nogc nothrow
{
    char[20] buf; size_t i = buf.length;
    if (v == 0) { buf[--i] = '0'; }
    else while (v) { buf[--i] = cast(char)('0' + v % 10); v /= 10; }
    dbgWrite(buf[i .. $]);
}
private void dbgAssert(scope const(char)[] tag, scope const(char)[] file, uint line) @nogc nothrow
{
    dbgWrite(tag); dbgWrite(" "); dbgWrite(file); dbgWrite(":"); dbgNum(line); dbgWrite("\n");
}

noreturn _d_assert(string file, uint line) @nogc          { dbgAssert("ASSERT", file, line); wasm_abort(); }
noreturn _d_assertp(immutable(char)* file, uint line) @nogc { dbgWrite("ASSERTP\n"); wasm_abort(); }
noreturn _d_assert_msg(string msg, string file, uint line) @nogc { dbgAssert("ASSERTMSG", file, line); wasm_abort(); }

void _d_unittest(string file, uint line) @nogc          { wasm_abort(); }
void _d_unittestp(immutable(char)* file, uint line) @nogc { wasm_abort(); }
void _d_unittest_msg(string msg, string file, uint line) @nogc { wasm_abort(); }

noreturn _d_arraybounds(string file, uint line) @nogc { dbgAssert("BOUNDS", file, line); wasm_abort(); }
noreturn _d_arrayboundsp(immutable(char)* file, uint line) @nogc { dbgWrite("BOUNDSP\n"); wasm_abort(); }
noreturn _d_arraybounds_slicep(immutable(char)* file, uint line,
    size_t lower, size_t upper, size_t length) @nogc { wasm_abort(); }
noreturn _d_arraybounds_indexp(immutable(char)* file, uint line,
    size_t index, size_t length) @nogc { wasm_abort(); }

noreturn _d_nullpointerp(immutable(char)* file, uint line) @nogc { wasm_abort(); }

noreturn onOutOfMemoryError(void* pretend_sideffect = null, string file = null, size_t line = 0) @trusted @nogc nothrow
{
    wasm_abort();
}

noreturn onOutOfMemoryErrorNoGC(string file = null, size_t line = 0) @trusted @nogc nothrow
{
    wasm_abort();
}

noreturn onInvalidMemoryOperationError(void* pretend_sideffect = null, string file = null, size_t line = 0) @trusted @nogc nothrow
{
    wasm_abort();
}

noreturn __assert(const(char)* file, int line, const(char)* msg) @nogc nothrow { wasm_abort(); }
noreturn __assert_fail(const(char)* msg, const(char)* file, uint line, const(char)* func) @nogc nothrow { wasm_abort(); }

private extern(C) extern __gshared int errno;
ref int __errno_location() @nogc nothrow { return errno; }
