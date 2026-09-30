extern (C) extern __gshared int someExternGlobal;

class C
{
    int f() { return someExternGlobal; }
    int* p() { return &someExternGlobal; }
    int g() { return 1; }
}

void test()
{
    static assert((new C).g() == 1);
    static assert((new C).p() !is null);
    static assert(!__traits(compiles, { enum x = (new C).f(); }));
}
