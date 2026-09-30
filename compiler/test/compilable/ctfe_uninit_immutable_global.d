struct A
{
    static immutable size_t pageSize;
    shared static this() { pageSize = 4096; }
}

int f(int x)
{
    if (x > 10)
        return cast(int) A.pageSize;
    return x;
}

static assert(f(3) == 3);
