/*
REQUIRED_ARGS: -mwasm32 -os=wasm
TEST_OUTPUT:
---
fail_compilation/wasm_simd.d(103): Error: incompatible types for `(a) / (b)`: both operands are of type `__vector(int[4])`
fail_compilation/wasm_simd.d(104): Error: incompatible types for `(a) % (b)`: both operands are of type `__vector(int[4])`
fail_compilation/wasm_simd.d(105): Error: incompatible types for `(a) << (b)`: both operands are of type `__vector(int[4])`
fail_compilation/wasm_simd.d(106): Error: incompatible types for `(x) * (y)`: both operands are of type `__vector(byte[16])`
---
*/

// WebAssembly SIMD is 128-bit only and, like x86, has no integer lane division,
// remainder, generic shift, or `i8x16` multiply.
// https://github.com/dlang/dmd/pull/00000

import core.simd;

#line 100

void f(int4 a, int4 b, byte16 x, byte16 y)
{
    int4 q = a / b;
    int4 r = a % b;
    int4 s = a << b;
    byte16 m = x * y;
}
