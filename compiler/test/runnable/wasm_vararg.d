// C-style variadic functions (core.stdc.stdarg) on the WASM backend.
// The caller spills the variadic args into a shadow-stack block and passes a
// pointer to it as a trailing implicit parameter; va_start records that pointer
// and va_arg walks it (promoting float to double).
//
// Run via: OS=wasm ./run.d runnable/wasm_vararg.d
// DISABLED: linux osx freebsd windows dragonflybsd openbsd netbsd solaris

import core.stdc.stdarg;

extern (C) int sumi(int n, ...)
{
    va_list ap;
    va_start(ap, n);
    int total = 0;
    foreach (_; 0 .. n)
        total += va_arg!int(ap);
    va_end(ap);
    return total;
}

extern (C) long suml(int n, ...)
{
    va_list ap;
    va_start(ap, n);
    long total = 0;
    foreach (_; 0 .. n)
        total += va_arg!long(ap);
    va_end(ap);
    return total;
}

extern (C) double sumd(int n, ...)
{
    va_list ap;
    va_start(ap, n);
    double total = 0;
    foreach (_; 0 .. n)
        total += va_arg!double(ap);
    va_end(ap);
    return total;
}

// Mixed types, including a promoted float, read back in order.
extern (C) long mixed(int n, ...)
{
    va_list ap;
    va_start(ap, n);
    int a = va_arg!int(ap);
    long b = va_arg!long(ap);
    double c = va_arg!double(ap);
    float d = va_arg!float(ap);
    va_end(ap);
    return a + b + cast(long) c + cast(long) d;
}

extern (C) int main()
{
    assert(sumi(4, 1, 2, 3, 4) == 10);
    assert(suml(3, 10L, 20L, 30L) == 60);
    assert(sumd(3, 1.5, 2.25, 0.25) == 4.0);
    assert(mixed(0, 1, 2L, 3.0, 4.0f) == 10);
    return 0;
}
