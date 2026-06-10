module core.sys.posix.sys.stat;
extern (C) nothrow @nogc:

// Simplified wasi-libc-ish struct stat; only st_mode/st_size are read by the
// frontend, and disk stat is not exercised in the wasm in-memory flow.
struct stat_t
{
    ulong  st_dev;
    ulong  st_ino;
    uint   st_mode;
    ulong  st_nlink;
    uint   st_uid;
    uint   st_gid;
    ulong  st_rdev;
    long   st_size;
    long   st_blksize;
    long   st_blocks;
    long   st_atime;
    long   st_mtime;
    long   st_ctime;
    long[3] __reserved;
}

enum S_IFMT  = 0xF000;
enum S_IFDIR = 0x4000;
enum S_IFREG = 0x8000;
enum S_IRUSR = 0x100, S_IWUSR = 0x80, S_IRGRP = 0x20, S_IROTH = 0x4;

extern (D) bool S_ISDIR(uint mode) => (mode & S_IFMT) == S_IFDIR;
extern (D) bool S_ISREG(uint mode) => (mode & S_IFMT) == S_IFREG;

int fstat(int fd, stat_t* buf);
int stat(const(char)* path, stat_t* buf);
int lstat(const(char)* path, stat_t* buf);
int mkdir(const(char)* path, uint mode);
