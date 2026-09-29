// https://issues.dlang.org/show_bug.cgi?id=19123

union U
{
    int i;
    byte[4] b;
}

byte[4] f(int val)
{
    U u;
    u.i = val;
    return u.b;
}

static byte[4] forceCtfe = f(1);
static assert(f(1) == [1, 0, 0, 0]);
