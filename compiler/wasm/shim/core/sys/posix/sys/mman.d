module core.sys.posix.sys.mman;
import core.sys.posix.unistd : off_t;
extern (C) nothrow @nogc:

enum PROT_READ  = 1;
enum PROT_WRITE = 2;
enum MAP_SHARED = 1;
enum MAP_PRIVATE = 2;
void* MAP_FAILED() @trusted { return cast(void*) -1; }

// Stub bodies: base wasi-libc lacks mmap; the in-memory file flow never calls these.
void* mmap(void* addr, size_t length, int prot, int flags, int fd, off_t offset) => cast(void*) -1;
int munmap(void* addr, size_t length) => 0;
int msync(void* addr, size_t length, int flags) => 0;
