/*
TEST_OUTPUT:
---
fail_compilation/ice1144.d(15): Error: undefined identifier `a`
fail_compilation/ice1144.d(24): Error: template instance `ice1144.testHelper!("hello", "world")` error instantiating
fail_compilation/ice1144.d(24):        while evaluating `mixin(testHelper!("hello", "world")())`
---
*/

// https://issues.dlang.org/show_bug.cgi?id=1144
// ICE(template.c) template mixin causes DMD crash
char[] testHelper(A ...)()
{
    char[] result;
    foreach (t; a)
    {
        result ~= "int " ~ t ~ ";\n";
    }
    return result;
}

void main()
{
    mixin(testHelper!("hello", "world")());
}
