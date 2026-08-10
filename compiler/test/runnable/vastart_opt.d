// PERMUTE_ARGS: -O
import core.stdc.stdarg;
import core.stdc.stdio;

extern (C) void format(ref char[64] buf, const(char)* fmt, ...) nothrow @system
{
    va_list ap;
    va_start(ap, fmt);
    va_list va;
    va_copy(va, ap);
    vsnprintf(buf.ptr, buf.length, fmt, va);
    va_end(va);
    va_end(ap);
}

void main()
{
    char[64] buf = void;
    format(buf, "%d", 1);
    assert(buf[0] == '1' && buf[1] == 0);
    format(buf, "%d %d", 42, -7);
    assert(buf[0] == '4' && buf[1] == '2' && buf[2] == ' ' && buf[3] == '-');
}
