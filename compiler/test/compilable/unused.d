// REQUIRED_ARGS: -o- -transition=unused -verrors=simple

// Unused module-level declarations are reported.
int unusedGlobal;
enum UnusedEnum { a, b }
enum unusedManifest = 5;
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
}

// Exception: symbols meant for export.
export void exportedFunc() {}
extern(C) void cFunc() {}
pragma(mangle, "mangled") void mangledFunc() {}

// Exception: parameters (must honor an API). The function itself is still
// reported as unused, but `unusedParam` is not.
void takesParamUsed(int unusedParam) { unusedParam++; }

// Exception: struct padding fields by naming convention.
struct S
{
    int _reserved;
    int padding0;
    int unusedField;
}
int useS(S s) { return s._reserved + s.padding0; }

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
compilable/unused.d(6): Warning: unused variable `unused.unusedManifest`
compilable/unused.d(7): Warning: unused function `unused.unusedFunc`
compilable/unused.d(15): Warning: unused function `unused.consumer`
compilable/unused.d(24): Warning: unused variable `unused.consumer.unusedLocal`
compilable/unused.d(38): Warning: unused function `unused.takesParamUsed`
compilable/unused.d(45): Warning: unused variable `unused.S.unusedField`
compilable/unused.d(47): Warning: unused function `unused.useS`
---
*/
