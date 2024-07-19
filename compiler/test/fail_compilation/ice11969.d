/*
TEST_OUTPUT:
---
fail_compilation/ice11969.d(12): Error: undefined identifier `index`
fail_compilation/ice11969.d(12):        while evaluating `mixin([index])`
fail_compilation/ice11969.d(13): Error: undefined identifier `cond`
fail_compilation/ice11969.d(13):        while evaluating `mixin(assert(cond))`
fail_compilation/ice11969.d(14): Error: undefined identifier `msg`
fail_compilation/ice11969.d(14):        while evaluating `mixin(assert(0, (__error)))`
---
*/
void test1() { mixin ([index]); }
void test2() { mixin (assert(cond)); }
void test3() { mixin (assert(0, msg)); }
