module core.sys.posix.dirent;
extern (C) nothrow @nogc:

struct DIR;

struct dirent
{
    ulong d_ino;
    long  d_off;
    ushort d_reclen;
    ubyte d_type;
    char[256] d_name;
}

DIR* opendir(const(char)* name);
dirent* readdir(DIR* dirp);
int closedir(DIR* dirp);
