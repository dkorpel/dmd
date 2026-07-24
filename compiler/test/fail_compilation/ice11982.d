/*
TEST_OUTPUT:
---
fail_compilation/ice11982.d(20): Error: basic type expected, not `scope`
fail_compilation/ice11982.d(20): Error: found `scope` when expecting `;` following expression
fail_compilation/ice11982.d(20):        expression: `new _error_`
fail_compilation/ice11982.d(20): Error: basic type expected, not `}`
fail_compilation/ice11982.d(20): Error: missing `{ ... }` for function literal
fail_compilation/ice11982.d(20): Error: C style cast illegal, use `cast(funk)function _error_()
{
}
`
fail_compilation/ice11982.d(20): Error: found `}` when expecting `;` following expression
fail_compilation/ice11982.d(20):        expression: `cast(funk)function _error_()
{
}
`
---
*/
void main() { new scope ( funk ) function }
