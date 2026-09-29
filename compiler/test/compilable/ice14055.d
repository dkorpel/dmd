struct S
{
    static returnsFoo()
    {
        uint[1] foo = void;
        return foo;
    }

    static enum fooEnum = returnsFoo();
    static uint[1] fooArray = fooEnum[];
}

static assert(S.fooEnum == [0]);
