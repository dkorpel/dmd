// REQUIRED_ARGS: -unittest
/*
TEST_OUTPUT:
---
fail_compilation/fail308.d(26): Error: template instance `object.RTInfo!(TestType)` recursive expansion
fail_compilation/fail308.d(26): Error: template instance `object.RTInfo!(TestType)` error instantiating
fail_compilation/fail308.d(19):        503 recursive instantiations from here: `MinHeap!int`
fail_compilation/fail308.d(27): Error: template instance `fail308.MinHeap!(TestType)` recursive expansion
fail_compilation/fail308.d(27): Error: template instance `fail308.MinHeap!(TestType)` error instantiating
fail_compilation/fail308.d(19):        503 recursive instantiations from here: `MinHeap!int`
fail_compilation/fail308.d(22): Error: template instance `object.RTInfo!(MinHeap!(TestType))` recursive expansion
fail_compilation/fail308.d(22): Error: template instance `object.RTInfo!(MinHeap!(TestType))` error instantiating
fail_compilation/fail308.d(19):        503 recursive instantiations from here: `MinHeap!int`
---
*/

void main()
{
    MinHeap!(int) foo = new MinHeap!(int)();
}

class MinHeap(NodeType)
{
    unittest
    {
        struct TestType {}
        MinHeap!(TestType) foo;
    }
}
