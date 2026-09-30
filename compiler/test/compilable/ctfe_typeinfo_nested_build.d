string gen()
{
    string s = "int ";
    s ~= "x;";
    return s;
}

struct W(T) { mixin(gen()); }

struct S(T)
{
    string toString() const { W!T w; return "S"; }
}

size_t h(T)() { return typeid(T).tsize; }

enum x = h!(S!int)();
