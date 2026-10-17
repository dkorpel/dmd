// REQUIRED_ARGS: -preview=dip1000

auto ref f(int[] a...) @safe
{
    return a[0];
}

auto ref g(scope int* p)
{
    int x;
    p = &x;
    return *p;
}

void main() @safe
{
    int x = f(1, 2);
}
