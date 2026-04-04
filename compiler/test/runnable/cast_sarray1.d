// https://github.com/dlang/dmd/issues/22269
// Casting a primitive to a length-1 static array of the same size is allowed.

void main()
{
    // int --> int[1]
    {
        int x = 42;
        auto y = cast(int[1]) x;
        assert(y[0] == 42);
    }

    // cast to T[1] is an lvalue when the source is an lvalue
    {
        int x = 42;
        int[1]* p = &cast(int[1]) x;
        assert((*p)[0] == 42);
    }

    // cast of rvalue to T[1] works and produces an rvalue
    {
        auto y = cast(int[1]) 42;
        assert(y[0] == 42);
        static assert(!__traits(compiles, &cast(int[1]) 42));
    }

    // int --> float[1]
    {
        int x = 0x3F800000; // bit pattern of 1.0f
        auto y = cast(float[1]) x;
        assert(y[0] == 1);
    }

    // long --> ulong[1]
    {
        long x = -1L;
        auto y = cast(ulong[1]) x;
        assert(y[0] == ulong.max);
    }
}
