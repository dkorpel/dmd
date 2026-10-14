// REQUIRED_ARGS: -O
// PERMUTE_ARGS: -inline

// https://github.com/dlang/dmd/issues/24037

version (D_SIMD)
{
    import core.simd;

    __gshared int4 g;

    int4 test(int4 b)
    {
        int4 zero = 0;
        g = cast(int4)(cast(short8)b == cast(short8)zero);
        return b;
    }

    void main()
    {
        int4 b = 1;
        int4 r = test(b);
        assert(r.array[0] == 1);
        assert(g.array[0] == -65536);
    }
}
else
{
    void main() {}
}
