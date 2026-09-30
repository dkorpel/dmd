// REQUIRED_ARGS: -inline

struct D
{
    long x;
    this(long x) { this.x = x; }
}

pragma(inline, false) D mul(long a) { return D(a * 3); }

enum e = mul(2).x;

void main()
{
    assert(e == 6);
    assert(mul(4).x == 12);
}
