// REQUIRED_ARGS: -d
enum EF : real { a = 1.5, b = 2.5 }

const(EF) constA() { return EF.a; }

int main()
{
    assert(constA() == EF.a);
    assert(constA() != EF.b);

    const(double) cd = 1.5;
    float f = 1.5f;
    assert(cd == f);
    assert(cd != 2.5f);

    real r = 1.5;
    assert(r == 1.5L);

    version (WebAssembly) {}
    else
    {
        ireal i = 1.5i;
        assert(r != i);
        assert(i == 1.5i);

        creal c = 1.5L + 0.0Li;
        assert(c == r);
        assert(c != i);
    }

    assert(1.5f < 2.5);
    assert(!(cd > f));

    return 0;
}
