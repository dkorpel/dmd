// https://github.com/dlang/dmd
//
// Run via: OS=wasm ./run.d runnable/wasm_yl2x.d
// DISABLED: linux osx freebsd windows dragonflybsd openbsd netbsd solaris

import core.math : yl2x, yl2xp1;

bool close(double a, double b) { return a - b < 1e-9 && b - a < 1e-9; }

extern (C) int main()
{
    if (!close(yl2x(1024.0, 1.0), 10.0)) return 1;
    if (!close(yl2x(1024.0, 3.0), 30.0)) return 2;
    if (!close(yl2xp1(1023.0, 1.0), 10.0)) return 3;
    if (!close(yl2xp1(0.0, 5.0), 0.0)) return 4;

    if (!close(yl2x(8.0f, 2.0f), 6.0)) return 5;
    if (!close(yl2xp1(3.0f, 2.0f), 4.0)) return 6;

    return 0;
}
