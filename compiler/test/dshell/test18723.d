// https://github.com/dlang/dmd/issues/18723
import dshell;
import std.algorithm : canFind;

int main()
{
    run("$DMD -m$MODEL -od$OUTPUT_BASE -I$EXTRA_FILES -cov -unittest -c $EXTRA_FILES/test18723.d");
    run("$DMD -m$MODEL -od$OUTPUT_BASE -I$EXTRA_FILES -cov -unittest -c $EXTRA_FILES/test18723a.d");
    run("$DMD -m$MODEL -of$OUTPUT_BASE/test18723$EXE $OUTPUT_BASE/test18723$OBJ $OUTPUT_BASE/test18723a$OBJ");
    run("$OUTPUT_BASE/test18723$EXE --DRT-covopt=dstpath:$OUTPUT_BASE");

    const lst = readText(shellExpand("$OUTPUT_BASE/dshell-extra-files-test18723a.lst"));
    assert(lst.canFind("      1|    return t + 1;"), lst);
    return 0;
}
