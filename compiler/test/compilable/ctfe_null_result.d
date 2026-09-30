typeof(null) f() { return null; }

struct S { typeof(null) n; int x; }
S g() { return S(null, 3); }

enum a = f();
enum b = (function () => null)();
enum s = g();
static assert(a is null && b is null && s.x == 3);
