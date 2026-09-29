struct T
{
    short a = void;
}

T foo()
{
    auto t = T.init;
    return t;
}

enum i = foo().a;
static assert(i == 0);

struct T2
{
    short a = void;
}
enum i2 = T2.init.a;
static assert(i2 == 0);
