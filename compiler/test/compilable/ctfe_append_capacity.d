int[] f()
{
    int[] a;
    a ~= 1;
    a ~= 2;
    int[] b = a[0 .. 1];
    b ~= 5;
    a ~= 3;
    int[] c = a;
    c.length = 2;
    c ~= 7;
    return a ~ b ~ c;
}
static assert(f() == [1, 2, 3, 1, 5, 1, 2, 7]);

int sum(int[] a...)
{
    int s;
    foreach (x; a)
        s += x;
    return s;
}

string gen()
{
    string s = "enum total = sum(";
    foreach (i; 0 .. 4000)
        s ~= "1,";
    return s ~ ");";
}
mixin(gen());
static assert(total == 4000);

string h()
{
    string a = "x";
    a ~= cast(dchar) 0x20AC;
    string b = a;
    a ~= cast(dchar) 'y';
    b ~= cast(dchar) 'z';
    wstring w;
    foreach (i; 0 .. 3)
        w ~= cast(dchar) 0x1F600;
    return a ~ "|" ~ b ~ (w.length == 6 ? "" : "?");
}
static assert(h() == "x\u20ACy|x\u20ACz");
