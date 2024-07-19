/*
TEST_OUTPUT:
---
fail_compilation/fail222.d(12): Error: template `fail222.getMixin(TArg..., int i = 0)()` template sequence parameter must be the last one
fail_compilation/fail222.d(19): Error: template instance `getMixin!()` does not match template declaration `getMixin(TArg..., int i = 0)()`
fail_compilation/fail222.d(19):        while evaluating `mixin(getMixin!()())`
fail_compilation/fail222.d(22): Error: template instance `fail222.Thing!()` error instantiating
fail_compilation/fail222.d(24): Error: template `fail222.fooBar(A..., B...)()` template sequence parameter must be the last one
---
*/

string getMixin(TArg..., int i = 0)()
{
    return ``;
}

class Thing(TArg...)
{
    mixin(getMixin!(TArg)());
}

public Thing!() stuff;

void fooBar (A..., B...)() {}
