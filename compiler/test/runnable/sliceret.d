// Returning a slice/delegate by value into a freshly constructed variable.
// On the WASM backend these are returned through a hidden pointer (sret);
// regression test that the result is actually copied into the destination
// (NRVO) instead of a discarded temporary.

string pick(int x) { return x ? "abcd" : "ef"; }

struct S { int a; int b() { return a; } }
int delegate() makeDg(ref S s) { return &s.b; }

void main()
{
    auto s = pick(1);
    assert(s.length == 4);
    assert(s[0] == 'a');

    auto t = pick(0);
    assert(t.length == 2);
    assert(t[1] == 'f');

    // ternary RHS producing a slice into a fresh variable
    auto u = (1 ? pick(1) : pick(0));
    assert(u.length == 4);

    S obj; obj.a = 42;
    auto d = makeDg(obj);
    assert(d() == 42);
}
