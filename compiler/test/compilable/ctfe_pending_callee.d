struct V
{
    V[] kids;
    string dump() const
    {
        enum e = check!V();
        string s = e;
        foreach (k; kids)
            s ~= k.dump();
        return s;
    }
}

string check(T)()
{
    T[] a;
    foreach (x; a)
        x.dump();
    return "ok";
}
