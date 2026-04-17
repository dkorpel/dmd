/*
TEST_OUTPUT:
---
fail_compilation/disable_args.d(15): Error: function `disable_args.foo` cannot be used because it is annotated with `@disable`
fail_compilation/disable_args.d(16): Error: function `disable_args.bar` cannot be used because it is annotated with `@disable` - Use baz() instead
---
*/

@disable(true) void foo();
@disable(true, "Use baz() instead") void bar();
@disable(false) void enabled();

void main()
{
    foo();
    bar();
    enabled();
}
