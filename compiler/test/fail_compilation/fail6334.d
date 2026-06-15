/*
TEST_OUTPUT:
---
fail_compilation/fail6334.d(20): Error: static assert:  `0` is false
fail_compilation/fail6334.d(18):        instantiated from here: `mixin T2!();`
fail_compilation/fail6334.d(25):        instantiated from here: `mixin T1!();`
fail_compilation/fail6334.d(18): Error: mixin `fail6334.main.T1!().T2!()` error instantiating
fail_compilation/fail6334.d(19): Error: undefined identifier `a`
fail_compilation/fail6334.d(19): Error: undefined identifier `bb`
fail_compilation/fail6334.d(19): Error: undefined identifier `ccc`
fail_compilation/fail6334.d(19): Error: undefined identifier `dddd`
fail_compilation/fail6334.d(25): Error: mixin `fail6334.main.T1!()` error instantiating
---
*/

mixin template T1()
{
    mixin T2;                       //compiles if these lines
    mixin T2!(a, bb, ccc, dddd);    //are before T2 declaration
    mixin template T2() { static assert(0); }
}

void main()
{
    mixin T1;
}
