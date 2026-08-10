// https://github.com/dlang/dmd
//
// Run via: OS=wasm ./run.d runnable/wasm_uns_divmod.d
// REQUIRED_ARGS: -betterC
// DISABLED: linux osx freebsd windows dragonflybsd openbsd netbsd solaris

uint mask = 0x9CE3D2F1;

extern (C) int main()
{
    if (mask % 16001 != 0x9CE3D2F1U % 16001)
        return 1;
    if (mask / 3 != 0x9CE3D2F1U / 3)
        return 2;
    uint u = mask;
    u %= 16001;
    if (u != 0x9CE3D2F1U % 16001)
        return 3;
    return 0;
}
