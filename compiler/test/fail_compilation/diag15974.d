/*
TEST_OUTPUT:
---
fail_compilation/diag15974.d(23): Error: variable `f` cannot be read at compile time
fail_compilation/diag15974.d(23):        called from here: `format("%s", f)`
fail_compilation/diag15974.d(23):        while evaluating `mixin(format("%s", f))`
fail_compilation/diag15974.d(28): Error: variable `f` cannot be read at compile time
fail_compilation/diag15974.d(28):        called from here: `format("%s", f)`
fail_compilation/diag15974.d(28):        while evaluating `mixin(format("%s", f))`
---
*/

void test15974()
{
    string format(Args...)(string fmt, Args args)
    {
        return "";
    }

    string f = "vkCreateSampler";

    // CompileStatement
    mixin(format("%s", f));

    struct S
    {
        // CompileDeclaration
        mixin(format("%s", f));
    }
}
