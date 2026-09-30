struct S { immutable(void)[] data; }

immutable(void)[] id(immutable(void)[] a) { return a; }
S mk(immutable(void)[] a) { return S(a); }

enum x = id(cast(immutable(void)[]) "abc");
enum y = mk(cast(immutable(void)[]) "hello");
static assert(cast(string) x == "abc");
static assert(y.data.length == 5);
