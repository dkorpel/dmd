// Interface method dispatch on the WASM backend.
// Interface vtable slots hold adjustor thunks that subtract the interface
// offset from `this` before calling the concrete method.  cod3_thunk is
// x86-only, so previously the thunk body was never emitted and the slot
// resolved to table index 0 -> "uninitialized element" trap on the call.
//
// Run via: OS=wasm ./run.d runnable/wasm_interface.d
// DISABLED: linux osx freebsd windows dragonflybsd openbsd netbsd solaris

interface I
{
    int get();
    int add(int x);
}

class C : I
{
    int base;
    this(int b) { base = b; }
    override int get() { return base; }
    override int add(int x) { return base + x; }
}

extern (C) int main()
{
    C c = new C(10);
    assert(c.get() == 10);       // direct class virtual call
    assert(c.add(5) == 15);

    I i = c;                     // upcast to interface (offset adjustment)
    assert(i.get() == 10);       // interface dispatch through thunk
    assert(i.add(7) == 17);
    return 0;
}
