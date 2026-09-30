// LINK:
alias Seq(T...) = T;

struct P
{
    Seq!(string, string) expand;
    alias expand this;
}

struct R
{
    int i;
    P front() { return P("a", "b"); }
    bool empty() { return i >= 2; }
    void popFront() { i++; }
}

struct S
{
    int x;
    string get() const
    {
        static foreach (k, v; R())
            if (x == 3)
                return k ~ v;
        return null;
    }
}

int main()
{
    S s;
    return cast(int) s.get().length;
}
