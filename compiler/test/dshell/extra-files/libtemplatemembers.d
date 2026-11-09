module libtemplatemembers;

enum isInt(T) = is(T == int);

template Filter(alias pred, args...)
{
    alias Filter = Seq!();
    static foreach (arg; args)
        static if (pred!arg)
            Filter = Seq!(Filter, arg);
}

template Seq(args...)
{
    alias Seq = args;
}

template Count(T...)
{
    import libtemplatemembers : Seq;
    static assert(T.length < 10);
    enum Count = Filter!(isInt, T).length;
}

static if (Count!(int, char, int) == 2)
    enum c = Count!(int);
