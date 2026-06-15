// https://issues.dlang.org/show_bug.cgi?id=2920
// recursive templates blow compiler stack
// template_29_B.
/*
TEST_OUTPUT:
---
fail_compilation/fail281.d(17): Error: template instance `fail281.foo!4294966795u` recursive expansion exceeded allowed nesting limit
fail_compilation/fail281.d(17): Error: template instance `fail281.foo!4294966795u` error instantiating
fail_compilation/fail281.d(26):        501 recursive instantiations from here: `foo!4294967295u`
---
*/

template foo(uint i)
{
    static if (i > 0)
    {
        const uint bar = foo!(i - 1).bar;
    }
    else
    {
        const uint bar = 1;
    }
}
int main()
{
    return foo!(uint.max).bar;
}
