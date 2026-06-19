// Minimal repro: virtual call through an inherited (two-level) class hierarchy.
// On the WASM backend `new Bar()` currently produces an instance whose __vptr
// is 0, so the virtual call traps with "uninitialized element".
// A direct Object subclass (Foo here) works; the bug needs the extra level.
//
// Run via: OS=wasm ./run.d runnable/wasm_inherit_vcall.d
// DISABLED: linux osx freebsd windows dragonflybsd openbsd netbsd solaris

class Foo
{
    int foo() { return 1; }
}

class Bar : Foo
{
    override int foo() { return 2; }
}

extern (C) int main()
{
    Foo f = new Foo();
    assert(f.foo() == 1);   // direct Object subclass: works

    Bar b = new Bar();      // inherited class: instance.__vptr == 0  <-- bug
    assert(b.foo() == 2);   // virtual call -> "uninitialized element" trap
    return 0;
}
