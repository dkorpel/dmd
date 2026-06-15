// REQUIRED_ARGS: -o- -transition=unused -verrors=simple

// Unused module-level declarations are reported.
int unusedGlobal;
enum UnusedEnum { a, b }
void unusedFunc() {}

// Used declarations are silent.
int usedGlobal;
enum UsedEnum { x, y }
enum usedManifest = 6;
void usedFunc() {}

void consumer()
{
    usedGlobal = usedManifest;
    usedFunc();
    UsedEnum e = UsedEnum.x;
    cast(void) e;

    int usedLocal = 3;
    cast(void) usedLocal;
    int unusedLocal;

    // Exception: foreach loop variables are not flagged even if unused.
    foreach (i; 0 .. 2) {}
    foreach (j, c; "ab") {}

    // Exception: a struct local with a destructor is an RAII scope guard,
    // declared for its destructor's side effect rather than to be referenced.
    Guard g;
}

// Exception: manifest constants behave like C `#define`s and are commonly
// declared in named groups (e.g. translated headers) where not all are used.
enum unusedManifest = 5;

// Exception: symbols meant for export.
export void exportedFunc() {}
extern(C) void cFunc() {}
pragma(mangle, "mangled") void mangledFunc() {}

// Exception: parameters (must honor an API). The function itself is still
// reported as unused, but `unusedParam` is not.
void takesParamUsed(int unusedParam) { unusedParam++; }

// Unused aggregate fields are reported, just like other variables.
struct S
{
    int usedField;
    int unusedField;
}
int useS(S s) { return s.usedField; }

// Accessing fields through `.tupleof` counts as a reference, so none of
// `T`'s fields are flagged.
struct T
{
    int a;
    int b;
}
int useTupleof(T t) { return t.tupleof[0] + t.tupleof[1]; }

struct Guard { ~this() {} }

// Exception: generic / documentation symbols.
template Tmpl(T)
{
    int unusedInTemplate;
    void unusedTemplateFunc() {}
}

unittest
{
    int unusedInUnittest;
}

mixin template Mix()
{
    int unusedInMixin;
}

/*
TEST_OUTPUT:
---
compilable/unused.d(4): Warning: unused variable `unused.unusedGlobal`
compilable/unused.d(5): Warning: unused enum `unused.UnusedEnum`
compilable/unused.d(6): Warning: unused function `unused.unusedFunc`
compilable/unused.d(14): Warning: unused function `unused.consumer`
compilable/unused.d(23): Warning: unused variable `unused.consumer.unusedLocal`
compilable/unused.d(45): Warning: unused function `unused.takesParamUsed`
compilable/unused.d(51): Warning: unused variable `unused.S.unusedField`
compilable/unused.d(53): Warning: unused function `unused.useS`
compilable/unused.d(62): Warning: unused function `unused.useTupleof`
---
*/
