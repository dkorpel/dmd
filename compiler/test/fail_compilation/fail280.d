// https://issues.dlang.org/show_bug.cgi?id=2920
// recursive templates blow compiler stack
// template_17_A.
/*
TEST_OUTPUT:
---
fail_compilation/fail280.d(15): Error: template instance `fail280.t!500` recursive expansion exceeded allowed nesting limit
fail_compilation/fail280.d(15): Error: template instance `fail280.t!500` error instantiating
fail_compilation/fail280.d(20):        501 recursive instantiations from here: `t!0`
---
*/

template t(int i)
{
    const int x = t!(i + 1).x;
}

void main()
{
    int i = t!(0).x;
}
