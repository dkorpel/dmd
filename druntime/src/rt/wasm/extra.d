/**
 * Extra runtime symbols required to link a full-TypeInfo D program for
 * WebAssembly that this minimal runtime does not otherwise implement.
 *
 * Once data-to-data relocations resolve correctly, a program's TypeInfo /
 * ClassInfo / ModuleInfo instances reference these druntime entry points, so
 * they must be defined or the module fails to instantiate with an undefined
 * import.  The `core.demangle` and `rt.minfo` helpers are only needed for
 * diagnostic strings and module-ctor iteration (both inert here), so they are
 * stubbed; `_d_newclass` does a real allocation.
 *
 * Copyright: Copyright (C) 1999-2026 by The D Language Foundation, All Rights Reserved
 * License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 */
module rt.wasm.extra;

private extern (C) void* gc_calloc(size_t sz, uint ba = 0, const scope TypeInfo ti = null) @nogc nothrow;

// new-expression / Object.factory class allocation: allocate a zero-initialized
// instance and copy the class's initializer (vtable pointer + field defaults).
extern (C) Object _d_newclass(const ClassInfo ci) nothrow
{
    auto init = ci.initializer;
    void* p = gc_calloc(init.length);
    (cast(ubyte*) p)[0 .. init.length] = cast(const(ubyte)[]) init[];
    return cast(Object) p;
}

// core.demangle.demangleType — diagnostic only; return empty.
pragma(mangle, "_D4core8demangle12demangleTypeFNaNbNfAxaAaZQd")
char[] _wasm_demangleType(const(char)[] buf, char[] dst = null) nothrow pure @trusted
{
    return null;
}

// core.demangle.reencodeMangled — diagnostic only; return the input unchanged.
pragma(mangle, "_D4core8demangle15reencodeMangledFNaNbNfNkMAxaZAa")
char[] _wasm_reencodeMangled(return scope const(char)[] mangled) nothrow pure @trusted
{
    return cast(char[]) mangled;
}

// rt.minfo.moduleinfos_apply — module ctors are not iterated in this runtime.
pragma(mangle, "_D2rt5minfo17moduleinfos_applyFMDFyPS6object10ModuleInfoZiZi")
int _wasm_moduleinfos_apply(scope int delegate(immutable(ModuleInfo*)) dg)
{
    return 0;
}
