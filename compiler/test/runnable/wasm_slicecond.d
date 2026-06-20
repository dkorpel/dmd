// Passing a conditional-expression slice (`cond ? a : b`) as a call argument
// on the WASM backend. The slice is passed as a (length, ptr) pair; a
// regression ICE'd in emitSliceArg because it only handled the direct pair
// shapes, not the OPcond/OPcolon produced by the ternary.
//
// Run via: OS=wasm ./run.d runnable/wasm_slicecond.d
// DISABLED: linux osx freebsd windows dragonflybsd openbsd netbsd solaris

__gshared int lastLen;

int sink(const(char)[] s)
{
    lastLen = cast(int) s.length;
    return lastLen;
}

const(char)[] other() => "longer";

void pick(bool b, const(char)[] a)
{
    sink(b ? a : other());
}

extern (C) int main()
{
    pick(true, "ab");
    assert(lastLen == 2);
    pick(false, "ab");
    assert(lastLen == 6); // "longer"
    return 0;
}
