string f(T)(T x) { return "x"; }
string f(T)(T y) { return "y"; }

static assert(f(x: 0) == "x");
static assert(f(y: 0) == "y");

string g() { return f(x: 0); }
string h() { return f(y: 0); }

static assert(g() == "x");
static assert(h() == "y");
static assert(g() == "x");
