/**
 * Minimal core.stdc.time for wasm32-wasi (upstream static-asserts on non-Posix/
 * Windows). Only the symbols the DMD frontend uses. Shadows druntime via the
 * wasm build's -Icompiler/wasm/shim ahead of -Idruntime/src.
 */
module core.stdc.time;

extern (C) nothrow @nogc:

alias time_t = long;        // wasi-libc: 64-bit
alias clock_t = long;

struct tm
{
    int tm_sec, tm_min, tm_hour, tm_mday, tm_mon, tm_year, tm_wday, tm_yday, tm_isdst;
    int tm_gmtoff;             // C `long` is 32-bit on wasm32
    const(char)* tm_zone;
}

time_t time(scope time_t* t);
char* ctime(scope const time_t* t);
tm* localtime(scope const time_t* t);
tm* gmtime(scope const time_t* t);
char* asctime(scope const tm* t);
size_t strftime(scope char* s, size_t max, scope const char* fmt, scope const tm* t);
clock_t clock() => 0;   // stub: not in base wasi-libc; time-tracing unused
double difftime(time_t t1, time_t t0);
time_t mktime(scope tm* t);

enum clock_t CLOCKS_PER_SEC = 1_000_000;
