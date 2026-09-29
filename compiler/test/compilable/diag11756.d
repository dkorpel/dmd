struct Ptr
{
    void opAssign(Ptr other)
    {
        (*cnt)--;
        cnt = other.cnt;
        (*cnt)++;
    }
    size_t *cnt;
}

union Foo
{
    size_t *ptr1;
    Ptr ptr2;
}

bool test()
{
    Foo foo;
    size_t cnt = 1;
    foo.ptr1 = &cnt;
    size_t n;
    foo.ptr2 = Ptr(&n);
    assert(cnt == 0);
    assert(n == 1);

    return true;
}
static assert(test());
