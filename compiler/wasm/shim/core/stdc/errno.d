/**
 * core.stdc.errno for wasm32-wasi (upstream static-asserts: unknown arch).
 * wasi-libc exposes errno via __errno_location.
 */
module core.stdc.errno;

extern (C) private int* __errno_location() nothrow @nogc @trusted;

extern (C) int getErrno() nothrow @nogc @trusted { return *__errno_location(); }
extern (C) int setErrno(int n) nothrow @nogc @trusted { *__errno_location() = n; return n; }

// D-linkage so the getter/setter can overload (mirrors druntime core.stdc.errno).
@property int errno() nothrow @nogc @trusted { return getErrno(); }
@property int errno(int n) nothrow @nogc @trusted { return setErrno(n); }

extern (C):

enum EPERM=1, ENOENT=2, ESRCH=3, EINTR=4, EIO=5, ENXIO=6, E2BIG=7, ENOEXEC=8,
     EBADF=9, ECHILD=10, EAGAIN=11, ENOMEM=12, EACCES=13, EFAULT=14, EBUSY=16,
     EEXIST=17, EXDEV=18, ENODEV=19, ENOTDIR=20, EISDIR=21, EINVAL=22, ENFILE=23,
     EMFILE=24, ENOTTY=25, EFBIG=27, ENOSPC=28, ESPIPE=29, EROFS=30, EMLINK=31,
     EPIPE=32, ERANGE=34, ENAMETOOLONG=36, ENOSYS=38, ENOTEMPTY=39, ELOOP=40,
     EWOULDBLOCK=EAGAIN, EOVERFLOW=75, ECANCELED=125;
