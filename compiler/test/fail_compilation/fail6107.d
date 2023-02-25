/*
TEST_OUTPUT:
---
fail_compilation/fail6107.d(10): Error: cannot name symbol `__ctor`; identifiers starting with `__` are reserved for the implementation
fail_compilation/fail6107.d(14): Error: cannot name symbol `__ctor`; identifiers starting with `__` are reserved for the implementation
---
*/
struct Foo
{
    enum __ctor = 4;
}
class Bar
{
    int __ctor = 4;
}
