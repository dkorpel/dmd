/*
REQUIRED_ARGS: -mwasm32 -os=wasm
TEST_OUTPUT:
---
fail_compilation/wasm_complex.d(103): Error: complex type `cdouble` is not supported for the WebAssembly target
fail_compilation/wasm_complex.d(104): Error: complex type `cfloat` is not supported for the WebAssembly target
fail_compilation/wasm_complex.d(105): Error: complex type `creal` is not supported for the WebAssembly target
---
*/

// Complex types are unsupported by the wasm backend; they must fail with a
// diagnostic rather than a codegen ICE.
// https://github.com/dlang/dmd/issues/00000

#line 100

void f()
{
    cdouble a;
    cfloat b;
    creal c;
}
