/*
TEST_OUTPUT:
---
x"11111111111111112222222222222222"
---
*/
struct E
{
    immutable(size_t)[] data;
}

immutable E entries = E(cast(immutable size_t[]) x"1111111111111111 2222222222222222");

E pass(const E e)
{
    return E(e.data);
}

static immutable res = pass(entries);
pragma(msg, res.data);

immutable(uint)[] id(immutable(uint)[] a)
{
    return a;
}

static immutable r2 = id(cast(immutable uint[]) x"33333333 44444444");
static assert(r2 == [0x33333333, 0x44444444]);
static assert(r2[1] == 0x44444444 && r2.length == 2);
