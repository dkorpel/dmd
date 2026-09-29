int use(T)(T v) { return v.a + 1; }
enum check(Args...) = { try { return use(Args.init); } catch (Exception e) { return 0; } }();
void test()
{
    struct S
    {
        int a;
        int get() { return a; }
    }
    S s = S(1);
    auto r = () { return s.a + check!S; }();
}
