// core.wasm memoryGrow/memorySize intrinsics lower to the memory.grow and
// memory.size instructions.
//
// Run via: OS=wasm ./run.d runnable/wasm_memgrow.d
// DISABLED: linux osx freebsd windows dragonflybsd openbsd netbsd solaris

import core.wasm;

extern (C) int main()
{
    const size0 = memorySize();
    if (size0 <= 0)
        return 1;

    const prev = memoryGrow(2);
    if (prev != size0)
        return 2;
    if (memorySize() != size0 + 2)
        return 3;

    // The grown pages start zeroed and are writable
    ubyte* p = cast(ubyte*)(prev * 65536);
    if (p[0] != 0 || p[2 * 65536 - 1] != 0)
        return 4;
    p[0] = 42;
    p[2 * 65536 - 1] = 43;
    if (p[0] + p[2 * 65536 - 1] != 85)
        return 5;

    return 0;
}
