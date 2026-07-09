/**
 * Exception handling for WebAssembly using the exnref proposal.
 *
 * `throw` statements lower to `_d_throwc`, which pins the object (the
 * in-flight exception reference lives in host state the GC cannot scan)
 * and executes the wasm `throw` instruction via `core.wasm.throwException`.
 * Catch dispatch calls `_d_eh_wasm_match` per catch clause; a match unpins
 * the object and enters the handler.
 *
 * Copyright: Copyright (C) 1999-2026 by The D Language Foundation, All Rights Reserved
 * License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 */
module rt.wasm.eh;

import core.wasm : throwException;
import core.internal.cast_ : areClassInfosEqual;

extern (C):

private __gshared Throwable[16] inFlight;
private __gshared size_t inFlightDepth;

/**
 * Throw `o` as a wasm exception.
 *
 * Params:
 *      o = the object to throw
 */
noreturn _d_throwc(Throwable o) @trusted
{
    if (o !is null)
    {
        if (inFlightDepth < inFlight.length)
            inFlight[inFlightDepth++] = o;
        const rc = o.refcount();
        if (rc) // non-zero means it's a refcounted (-preview=dip1008) Throwable
            o.refcount() = rc + 1;
    }
    throwException(cast(void*) o);
}

/// ditto
noreturn _d_throwdwarf(Throwable o) @trusted
{
    _d_throwc(o);
}

/**
 * Test whether the caught object `o` matches a catch clause of type `ci`.
 * On a match the object is unpinned from the in-flight root stack.
 *
 * Params:
 *      o  = the caught object
 *      ci = the catch clause's class
 * Returns:
 *      true if `o` is an instance of `ci` (directly or via a base class)
 */
bool _d_eh_wasm_match(Object o, TypeInfo_Class ci) nothrow @nogc @trusted
{
    if (o is null)
        return false;
    for (TypeInfo_Class oc = typeid(o); oc !is null; oc = oc.base)
    {
        if (areClassInfosEqual(oc, ci))
        {
            if (inFlightDepth > 0 && inFlight[inFlightDepth - 1] is o)
                inFlight[--inFlightDepth] = null;
            return true;
        }
    }
    return false;
}

import core.attribute : wasmImportModule;
private struct Ciovec { const(void)* buf; size_t len; }
@wasmImportModule("wasi_snapshot_preview1")
private extern(C) int fd_write(int fd, const(Ciovec)* iovs, size_t n, size_t* nw) @nogc nothrow;

private void errWrite(scope const(char)[] s) @nogc nothrow
{
    Ciovec io = Ciovec(s.ptr, s.length);
    size_t nw;
    fd_write(2, &io, 1, &nw);
}

/**
 * Run the program's main function with a top-level Throwable handler, giving
 * uncaught exceptions the native "type@file(line): msg" diagnostic and a
 * failure exit code instead of a bare wasm trap. Called by
 * `rt.wasm.start._d_run_main`, which is -betterC and cannot catch.
 *
 * Params:
 *      mainFunc = the compiler-generated D main wrapper
 *      args     = program arguments
 * Returns:
 *      main's return value, or 1 if a Throwable escaped it
 */
private alias CMainFunc = extern(C) int function(char[][] args);

int _d_eh_wasm_runMain(CMainFunc mainFunc, char[][] args)
{
    try
        return mainFunc(args);
    catch (Throwable t)
    {
        for (Throwable u = t; u !is null; u = u.next)
        {
            try
                errWrite(u.toString());
            catch (Throwable)
                errWrite("Throwable.toString() failed");
            errWrite("\n");
        }
        return 1;
    }
}

/// Stack trace capture is unsupported on WASM.
Throwable.TraceInfo _d_traceContext(void* ptr = null) @nogc nothrow
{
    return null;
}

