// https://github.com/dlang/dmd
//
// Run via: OS=wasm ./run.d runnable/wasm_selflink.d
// REQUIRED_ARGS: -betterC -mwasm-selflink -i
// DISABLED: linux osx freebsd windows dragonflybsd openbsd netbsd solaris
/*
RUN_OUTPUT:
---
self-linked
---
*/

import core.attribute : wasmImportModule;

@wasmImportModule("wasi_snapshot_preview1")
extern (C) int fd_write(int fd, const(void)* iovs, int iovsLen, int* nwritten);

@wasmImportModule("wasi_snapshot_preview1")
extern (C) void proc_exit(int code);

struct IOVec { const(char)* buf; uint len; }

__gshared int[4] table = [3, 1, 4, 1];

int sum()
{
    int s;
    foreach (x; table)
        s += x;
    return s;
}

export extern (C) void _start()
{
    static immutable string msg = "self-linked\n";
    IOVec iov = IOVec(msg.ptr, cast(uint) msg.length);
    int n;
    if (sum() == 9)
        fd_write(1, &iov, 1, &n);
    proc_exit(0);
}
