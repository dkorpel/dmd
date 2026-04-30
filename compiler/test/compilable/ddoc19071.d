// PERMUTE_ARGS:
// REQUIRED_ARGS: -D -Dd${RESULTS_DIR}/compilable -o-
// POST_SCRIPT: compilable/extra-files/ddocAny-postscript.sh
// EXTRA_SOURCES: extra-files/ddoc_minimal.ddoc

// https://github.com/dlang/dmd/issues/19071
module ddoc19071;

template case1(T)
{
    /++ Case1 comment +/
    void case1() {}
}

template case2(fun...)
{
    /++ Blah
    Params:
        r = a value
    +/
    void case2(R)(R r){}
}
