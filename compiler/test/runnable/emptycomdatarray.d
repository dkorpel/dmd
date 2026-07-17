int[] make(T)() { return []; }

template arr(T)
{
    static immutable int[] arr = make!T();
}

__gshared const(void)* pa, pb;

void main()
{
    pa = &arr!float;
    pb = &arr!double;
    assert(pa !is null);
    assert(pb !is null);
    assert(pa !is pb);
}
