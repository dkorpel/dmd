struct P
{
    string name;
    immutable(ubyte)[] data;
}

static immutable ubyte[] t1 = [1, 2, 3];
static immutable ubyte[] t2 = cast(immutable ubyte[]) x"0405";
immutable string digits = "0123456789";
static immutable int[3] sa = [7, 8, 9];

static immutable P[] tab = [P("one", t1), P("two", t2)];
static assert(tab[0].data == [1, 2, 3]);
static assert(tab[1].data == [4, 5]);
static assert(tab[1].name == "two");

enum d8 = digits[0 .. 8];
static assert(d8 == "01234567");
enum d3 = digits[3];
static assert(d3 == '3');
enum s1 = sa[1];
static assert(s1 == 8);

immutable P p = P("p", t1);
static assert(p.data.length == 3);

int mutate()
{
    auto q = tab[0];
    auto d = q.data.dup;
    d[0] = 42;
    return t1[0] + d[0];
}
static assert(mutate() == 43);
