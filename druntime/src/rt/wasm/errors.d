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

// ── assert ────────────────────────────────────────────────────────────────────

noreturn _d_assert(string file, uint line) @nogc          { wasm_abort(); }
noreturn _d_assertp(immutable(char)* file, uint line) @nogc { wasm_abort(); }
noreturn _d_assert_msg(string msg, string file, uint line) @nogc { wasm_abort(); }

// ── unittest ──────────────────────────────────────────────────────────────────

void _d_unittest(string file, uint line) @nogc          { wasm_abort(); }
void _d_unittestp(immutable(char)* file, uint line) @nogc { wasm_abort(); }
void _d_unittest_msg(string msg, string file, uint line) @nogc { wasm_abort(); }

// ── array bounds ──────────────────────────────────────────────────────────────

noreturn _d_arraybounds(string file, uint line) @nogc { wasm_abort(); }
noreturn _d_arrayboundsp(immutable(char)* file, uint line) @nogc { wasm_abort(); }
noreturn _d_arraybounds_slicep(immutable(char)* file, uint line,
    size_t lower, size_t upper, size_t length) @nogc { wasm_abort(); }
noreturn _d_arraybounds_indexp(immutable(char)* file, uint line,
    size_t index, size_t length) @nogc { wasm_abort(); }

// ── null pointer ──────────────────────────────────────────────────────────────

noreturn _d_nullpointerp(immutable(char)* file, uint line) @nogc { wasm_abort(); }
