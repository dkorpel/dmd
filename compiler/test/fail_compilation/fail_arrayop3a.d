/*
REQUIRED_ARGS: -o-
TEST_OUTPUT:
----
$p:druntime/import/core/internal/array/operations.d$($n$): Error: static assert:  "Binary `*` not supported for types `X` and `X`."
$p:druntime/import/core/internal/array/operations.d$($n$):        instantiated from here: `typeCheck!(true, X, X, X, "*", "=")`
$p:druntime/import/object.d$($n$):        instantiated from here: `arrayOp!(X[], X[], X[], "*", "=")`
fail_compilation/fail_arrayop3a.d(32):        instantiated from here: `_arrayOp!(X[], X[], X[], "*", "=")`
$p:druntime/import/core/internal/array/operations.d$-mixin-$n$($n$): Error: operator `*` is not defined for type `X`
fail_compilation/fail_arrayop3a.d(27):        perhaps overload the operator with `auto opBinary(string op : "*")(X rhs) {}`
$p:druntime/import/core/internal/array/operations.d$($n$): Error: static assert:  "Binary op `+=` not supported for types `string` and `string`."
$p:druntime/import/core/internal/array/operations.d$($n$):        instantiated from here: `typeCheck!(true, string, string, "+=")`
$p:druntime/import/object.d$($n$):        instantiated from here: `arrayOp!(string[], string[], "+=")`
fail_compilation/fail_arrayop3a.d(36):        instantiated from here: `_arrayOp!(string[], string[], "+=")`
$p:druntime/import/core/internal/array/operations.d$-mixin-$n$($n$): Error: slice `res[pos]` is not mutable
$p:druntime/import/core/internal/array/operations.d$-mixin-$n$($n$):        did you mean to concatenate (`res[pos] ~= __param_1[pos]`) instead ?
$p:druntime/import/core/internal/array/operations.d$($n$): Error: static assert:  "Binary op `*=` not supported for types `int*` and `int*`."
$p:druntime/import/core/internal/array/operations.d$($n$):        instantiated from here: `typeCheck!(true, int*, int*, "*=")`
$p:druntime/import/object.d$($n$):        instantiated from here: `arrayOp!(int*[], int*[], "*=")`
fail_compilation/fail_arrayop3a.d(40):        instantiated from here: `_arrayOp!(int*[], int*[], "*=")`
$p:druntime/import/core/internal/array/operations.d$-mixin-$n$($n$): Error: illegal operator `*=` for `res[pos]` of type `int*`
----
*/

void test11376()
{
    struct X { }

    auto x1 = [X()];
    auto x2 = [X()];
    auto x3 = [X()];
    x1[] = x2[] * x3[];

    string[] s1;
    string[] s2;
    s2[] += s1[];

    int*[] pa1;
    int*[] pa2;
    pa1[] *= pa2[];
}
