struct S
{
    int a;
    string s;
}

int f(T)()
{
    static if (is(T == int))
    {
        import core.stdc.stdint;
        enum r = 3;
        return r + 1;
    }
    else
    {
        alias U = T;
        return cast(int) U.sizeof;
    }
}

S g(T)()
{
    if (__ctfe)
        return S(T.sizeof, T.stringof);
    return S(0, null);
}

int[] h(bool b)()
{
    if (b)
        return [1, 2];
    else
        return [3];
}

enum a = f!int();
enum b = f!long();
enum c = g!short();
enum d = h!true();
enum e = h!false();
enum k = (() => 5)();

static assert(a == 4);
static assert(b == 8);
static assert(c == S(2, "short"));
static assert(d == [1, 2]);
static assert(e == [3]);
static assert(k == 5);

int[] m()
{
    auto x = h!true();
    x[0] = 9;
    return x;
}

static assert(m() == [9, 2]);
static assert(h!true() == [1, 2]);
