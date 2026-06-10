module core.sys.posix.fcntl;

public import core.sys.posix.sys.stat;  // druntime's fcntl re-exports stat (mode_t/stat_t)

extern (C) nothrow @nogc:

enum O_RDONLY = 0;
enum O_WRONLY = 1;
enum O_RDWR   = 2;
enum O_CREAT  = 0x40;
enum O_TRUNC  = 0x200;

int open(const(char)* path, int flags, ...);
