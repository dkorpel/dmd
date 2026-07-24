/*
TEST_OUTPUT:
---
fail_compilation/fail196.d(26): Error: delimited string must end in `)"`
fail_compilation/fail196.d(26): Error: implicit string concatenation is error-prone and disallowed in D
fail_compilation/fail196.d(26):        Use the explicit syntax instead (concatenating literals is `@nogc`): "foo(xxx)" ~ ";\n    assert(s == "
fail_compilation/fail196.d(27): Error: semicolon needed to end declaration of `s`, instead of `foo`
fail_compilation/fail196.d(26):        `s` declared here
fail_compilation/fail196.d(27): Error: found `");\n\n    s = q"` when expecting `;` following expression
fail_compilation/fail196.d(27):        expression: `foo(xxx)`
fail_compilation/fail196.d(29): Error: found `";\n    assert(s == "` when expecting `;` following expression
fail_compilation/fail196.d(29):        expression: `[foo[xxx]]`
fail_compilation/fail196.d(30): Error: found `");\n\n    s = q"` when expecting `;` following expression
fail_compilation/fail196.d(30):        expression: `foo[xxx]`
fail_compilation/fail196.d(32): Error: found `{` when expecting `;` following expression
fail_compilation/fail196.d(32):        expression: `foo`
fail_compilation/fail196.d(32): Error: found `}` when expecting `;` following expression
fail_compilation/fail196.d(32):        expression: `xxx`
fail_compilation/fail196.d(32): Error: declaration expected, not `";\n    assert(s == "`
fail_compilation/fail196.d(42): Error: unterminated string constant starting at fail_compilation/fail196.d(42)
---
*/

void main()
{
    string s = q"(foo(xxx)) ";
    assert(s == "foo(xxx)");

    s = q"[foo[xxx]]";
    assert(s == "foo[xxx]");

    s = q"{foo{xxx}}";
    assert(s == "foo{xxx}");

    s = q"<foo<xxx>>";
    assert(s == "foo<xxx>");

    s = q"[foo(]";
    assert(s == "foo(");

    s = q"/foo]/";
    assert(s == "foo]");
}
