@disable(false) void foo();
@disable(true) void bar();

static assert(!__traits(isDisabled, foo));
static assert(__traits(isDisabled, bar));

void main()
{
    foo();
}
