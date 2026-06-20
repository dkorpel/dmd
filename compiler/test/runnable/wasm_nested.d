// Nested functions reading multiple enclosing locals on the WASM backend.
// Each captured variable must get its own shadow-frame slot; a regression
// collapsed every captured auto to frame offset 0 so the 2nd+ variable
// aliased the 1st.
//
// Run via: OS=wasm ./run.d runnable/wasm_nested.d
// DISABLED: linux osx freebsd windows dragonflybsd openbsd netbsd solaris

extern (C) int twoCaptures(int a, int b)
{
    int get() { return a * 100 + b; }
    return get();
}

extern (C) int threeCaptures(int a, int b, int c)
{
    int get() { return a * 10000 + b * 100 + c; }
    return get();
}

extern (C) int captureAndModify(int a, int b)
{
    void bump() { a += b; }
    bump();
    bump();
    return a;
}

extern (C) int main()
{
    assert(twoCaptures(3, 7) == 307);
    assert(threeCaptures(1, 2, 3) == 10203);
    assert(captureAndModify(5, 4) == 13); // 5 + 4 + 4
    return 0;
}
