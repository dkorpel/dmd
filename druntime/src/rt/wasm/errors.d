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

// Declared in rt/wasm/start.d (single import site avoids duplicate-import issues).
private extern(C) noreturn _wasm_trap(int code) @nogc nothrow;

private noreturn wasm_abort() @nogc nothrow { _wasm_trap(1); }

noreturn _d_assert(string file, uint line) @nogc          { wasm_abort(); }
noreturn _d_assertp(immutable(char)* file, uint line) @nogc { wasm_abort(); }
noreturn _d_assert_msg(string msg, string file, uint line) @nogc { wasm_abort(); }

void _d_unittest(string file, uint line) @nogc          { wasm_abort(); }
void _d_unittestp(immutable(char)* file, uint line) @nogc { wasm_abort(); }
void _d_unittest_msg(string msg, string file, uint line) @nogc { wasm_abort(); }

noreturn _d_arraybounds(string file, uint line) @nogc { wasm_abort(); }
noreturn _d_arrayboundsp(immutable(char)* file, uint line) @nogc { wasm_abort(); }
noreturn _d_arraybounds_slicep(immutable(char)* file, uint line,
    size_t lower, size_t upper, size_t length) @nogc { wasm_abort(); }
noreturn _d_arraybounds_indexp(immutable(char)* file, uint line,
    size_t index, size_t length) @nogc { wasm_abort(); }

noreturn _d_nullpointerp(immutable(char)* file, uint line) @nogc { wasm_abort(); }

// ── out of memory ─────────────────────────────────────────────────────────────
// signature must match the extern(C) declaration in core.exception:
//   onOutOfMemoryError(void* pretend_sideffect, string file, size_t line)
// D string = (ptr: i32, len: i32) in WASM32, so 4 i32 params total.

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

// ── C assert ─────────────────────────────────────────────────────────────────
// musl libc may call __assert(file, line, msg) when an assert fires.

noreturn __assert(const(char)* file, int line, const(char)* msg) @nogc nothrow { wasm_abort(); }
noreturn __assert_fail(const(char)* msg, const(char)* file, uint line, const(char)* func) @nogc nothrow { wasm_abort(); }

// ── errno ──────────────────────────────────────────────────────────────────────
// wasi-libc exposes errno as a plain global; the rest of druntime (core.stdc.errno)
// expects a __errno_location() accessor, which wasi-libc does not provide.
private extern(C) extern __gshared int errno;
ref int __errno_location() @nogc nothrow { return errno; }
