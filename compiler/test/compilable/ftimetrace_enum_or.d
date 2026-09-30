// REQUIRED_ARGS: -ftime-trace -ftime-trace-file=${RESULTS_DIR}/compilable/ftimetrace_enum_or.json -ftime-trace-granularity=0

enum E
{
    a = 1,
    b = 2,
    c = 4,
    d = a | b | c,
}
