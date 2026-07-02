// A slice returned by a call and passed directly as a slice argument is an
// OPind whose address expression is the call: the two i32 halves must be
// loaded through a temp, not by re-evaluating the call once per half.
//
// Run via: OS=wasm ./run.d runnable/wasm_slicearg.d
// DISABLED: linux osx freebsd windows dragonflybsd openbsd netbsd solaris

__gshared int calls;

string next()
{
    calls++;
    return calls == 1 ? "first" : "later";
}

int classify(string s)
{
    if (s == "first")
        return 1;
    if (s == "later")
        return 2;
    return 0;
}

extern (C) int main()
{
    if (classify(next()) != 1)
        return 1;
    if (calls != 1)
        return 2;
    if (classify(next()) != 2)
        return 3;
    if (calls != 2)
        return 4;
    return 0;
}
