/*
REQUIRED_ARGS: -preview=dip1000
TEST_OUTPUT:
---
fail_compilation/escape_closure_vars.d(14): Error: assigning reference to local `r` to non-scope `dg` is not allowed in a `@safe` function
---
*/

int delegate() @safe dg;

void f(ref int r) @safe
{
    int x;
    dg = () => x + r;
}
