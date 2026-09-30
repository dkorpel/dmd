struct G(T)
{
    static p()
    {
        if (__ctfe)
            cast(void) or!q;
    }
    static q() { }
}

G!P g;

struct P { }

template or(rules...)
{
    P or()
    {
        return or!rules;
    }
}
