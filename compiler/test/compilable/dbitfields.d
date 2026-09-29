#line 100

union U
{
    uint a:3;
    uint b:1;
    ulong c:64;

    int d:3;
    int e:1;
    long f:64;

    int i;
}

int testu()
{
    U u;
    u.d = 9;
    return u.e;
}

static assert(testu() == -1);
