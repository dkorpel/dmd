struct P { int line; }

struct T
{
    P p;
    int opCmp(R)(R rhs) const if (is(typeof(P.init < P.init))) { return 0; }
}

T[] make()
{
    T[] a;
    a ~= T(P(1));
    return a;
}

enum e = make();
