// https://github.com/dlang/dmd
//
// Run via: OS=wasm ./run.d runnable/wasm_zerosize_ret.d
// DISABLED: linux osx freebsd windows dragonflybsd openbsd netbsd solaris

alias Empty = void[0];

__gshared int calls;

Empty make() { ++calls; return Empty.init; }

struct Box
{
    int tag;
    Empty get() { ++calls; return Empty.init; }
}

extern (C) int main()
{
    Empty a = make();
    if (calls != 1) return 1;
    if (a.length != 0) return 2;

    Box b = Box(42);
    Empty c = b.get();
    if (calls != 2) return 3;
    if (c.length != 0) return 4;
    if (b.tag != 42) return 5;

    return 0;
}
