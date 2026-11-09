module test18723a;

int func(T)(T t)
{
    return t + 1;
}

unittest
{
    func(0);
}
