/*
REQUIRED_ARGS: -o-
TEST_OUTPUT:
----
$p:druntime/import/core/internal/array/operations.d$($n$): Error: static assert:  "Binary op `+=` not supported for types `string` and `string`."
$p:druntime/import/core/internal/array/operations.d$($n$):        instantiated from here: `typeCheck!(true, string, string, "+=")`
$p:druntime/import/object.d$($n$):        instantiated from here: `arrayOp!(string[], string[], "+=")`
fail_compilation/fail_arrayop3b.d(17):        instantiated from here: `_arrayOp!(string[], string[], "+=")`
$p:druntime/import/core/internal/array/operations.d$-mixin-$n$($n$): Error: slice `res[pos]` is not mutable
$p:druntime/import/core/internal/array/operations.d$-mixin-$n$($n$):        did you mean to concatenate (`res[pos] ~= __param_1[pos]`) instead ?
---
*/
void test11376()
{
    string[] s1;
    string[] s2;
    s2[] += s1[];
}
