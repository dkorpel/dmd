// https://issues.dlang.org/show_bug.cgi?id=23781

struct Bar { int i; }
ref const(Bar) func1 (const return ref Bar b) { return b; }
immutable E1 = Bar();
enum ok = __traits(compiles, { enum E2 = &E1.func1(); });
