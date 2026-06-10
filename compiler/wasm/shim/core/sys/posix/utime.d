module core.sys.posix.utime;
import core.stdc.time : time_t;
extern (C) nothrow @nogc:

struct utimbuf
{
    time_t actime;
    time_t modtime;
}

int utime(const(char)* path, const(utimbuf)* times);
