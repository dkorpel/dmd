/**
 * WASM runtime entry point and `_d_run_main` implementation.
 *
 * Copyright: Copyright (C) 1999-2026 by The D Language Foundation, All Rights Reserved
 * License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 */
module rt.wasm.start;

nothrow:
extern (C):

void gc_init();
void gc_term();

private extern(C) void __wasm_call_ctors() @nogc nothrow;
private extern(C) void __wasm_call_dtors() @nogc nothrow;

private extern(C) int __main_void() nothrow;

export void _start() nothrow
{
    __wasm_call_ctors();
    int rc = __main_void();
    __wasm_call_dtors();
    proc_exit(rc);
    while (true) {}
}

import rt.sections : initSections;
extern(C) void rt_moduleCtor();
extern(C) void rt_moduleTlsCtor();
extern(C) void rt_moduleUnitTests();
extern(C) void rt_moduleTlsDtor();
extern(C) void rt_moduleDtor();
extern(C) void rt_coverWrite();

private alias MainFunc = extern(C) int function(char[][] args);

private extern(C) void* calloc(size_t, size_t) @nogc nothrow;

private char[][] wasiArgs() @nogc nothrow
{
    size_t nargs, buflen;
    if (args_sizes_get(&nargs, &buflen) != 0 || nargs == 0)
        return null;
    auto ptrs = cast(char**) calloc(nargs, (char*).sizeof);
    auto buf = cast(char*) calloc(1, buflen ? buflen : 1);
    auto arr = cast(char[]*) calloc(nargs, (char[]).sizeof);
    if (!ptrs || !buf || !arr || args_get(ptrs, buf) != 0)
        return null;
    size_t n = 0;
    foreach (i; 0 .. nargs)
    {
        char* p = ptrs[i];
        size_t len = 0;
        while (p[len]) len++;
        if (len >= 6 && p[0 .. 6] == "--DRT-")
            continue;
        arr[n++] = p[0 .. len];
    }
    return arr[0 .. n];
}

private extern(C) int _d_eh_wasm_runMain(MainFunc mainFunc, char[][] args);

int _d_run_main(int argc, char** argv, MainFunc mainFunc)
{
    gc_init();
    initSections();
    rt_moduleCtor();
    rt_moduleTlsCtor();
    rt_moduleUnitTests();
    int result = _d_eh_wasm_runMain(mainFunc, wasiArgs());
    rt_moduleTlsDtor();
    rt_moduleDtor();
    rt_coverWrite();
    gc_term();
    return result;
}

void _d_initMonoTime() @nogc {}

import core.attribute : wasmImportModule;

@wasmImportModule("wasi_snapshot_preview1")
private extern(C) void proc_exit(int code) @nogc nothrow;

@wasmImportModule("wasi_snapshot_preview1")
private extern(C) int args_sizes_get(size_t* argc, size_t* buflen) @nogc nothrow;

@wasmImportModule("wasi_snapshot_preview1")
private extern(C) int args_get(char** argv, char* buf) @nogc nothrow;

private extern(C) int fflush(void* stream) @nogc nothrow;

noreturn _wasm_trap(int code) @nogc nothrow
{
    fflush(null);
    proc_exit(code);
    while (true) {}
}
