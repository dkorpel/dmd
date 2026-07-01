// If/else where the then-arm spans multiple backend blocks: the merge-point
// detection must peek at the LAST block of the then-range, or the branch over
// the else-arm is lost and the else executes on both paths.
//
// Run via: OS=wasm ./run.d runnable/wasm_ifelse.d
// DISABLED: linux osx freebsd windows dragonflybsd openbsd netbsd solaris

extern (C) uint absWithFlag(int n)
{
    uint r;
    bool neg = false;
    if (n < 0)
    {
        r = cast(uint) -n; // two assignments → then-arm is two blocks
        neg = true;
    }
    else
        r = cast(uint) n;
    return r + (neg ? 100 : 0);
}

extern (C) int three(int n)
{
    int a, b, c;
    if (n > 10)
    {
        a = 1;
        b = 2;
        c = 3;
    }
    else
    {
        a = 4;
        b = 5;
    }
    return a * 100 + b * 10 + c;
}

extern (C) int main()
{
    if (absWithFlag(-1) != 101)
        return 1;
    if (absWithFlag(7) != 7)
        return 2;
    if (three(11) != 123)
        return 3;
    if (three(0) != 450)
        return 4;
    return 0;
}
