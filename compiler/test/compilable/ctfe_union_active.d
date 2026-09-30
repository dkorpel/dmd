union IF { int i; float f; }

struct V
{
    union U { typeof(null) n; double d; string s; }
    U u;
    uint kind;
    this(double x) { u.d = x; kind = 1; }
    this(string x) { u.s = x; kind = 2; }
}

V pass(V v) { return v; }

V[] build()
{
    V[] a;
    foreach (i; 0 .. 20)
        a ~= i % 2 ? V(i * 0.5) : V("x");
    V[] b = a.dup;
    b[0] = pass(a[1]);
    return b;
}

IF mkf() { IF u; u.f = 1.5; return u; }
IF mki() { IF u; u.f = 1.5; u.i = 3; return u; }

struct N
{
    union { IF inner; long l; }
    int tag;
}

N mkn() { N n; n.inner = mkf(); n.tag = 7; return n; }
N mkl() { N n; n.l = 42; return n; }

enum a = V(1.9);
static assert(a.kind == 1 && a.u.d == 1.9);
enum b = V("hi");
static assert(b.u.s == "hi");
enum c = build();
static assert(c[0].u.d == 0.5 && c[2].u.s == "x" && c[19].u.d == 9.5);
static assert(mkf().f == 1.5);
static assert(mki().i == 3);
static assert(mkn().inner.f == 1.5 && mkn().tag == 7);
static assert(mkl().l == 42);
enum IF d = { f: 2.5 };
static assert(pass2(d).f == 2.5);
IF pass2(IF x) { IF y = x; return y; }
enum IF e = IF.init;
static assert(pass2(e).i == 0);
enum IF g = mkf();
static assert(g.f == 1.5);
enum N h = mkn();
static assert(h.inner.f == 1.5);
enum N k = mkl();
static assert(k.l == 42);

struct D
{
    union
    {
        bool function(string) fp;
        bool[string] aa;
    }
    size_t sel = -1;
}

D passD(D v) { return v; }
D pick(bool c, D x, D y) { D r = c ? x : y; return r; }

D mkd()
{
    D v;
    v.aa = ["a": true];
    D w;
    w.fp = (string s) => s.length > 0;
    return pick(true, passD(v), w);
}

enum D m = mkd();
static assert("a" in m.aa);
