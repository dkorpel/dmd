/**
 * Misc symbols required for WASM
 *
 * Copyright: Copyright (C) 1999-2026 by The D Language Foundation, All Rights Reserved
 * License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 */
module rt.wasm.extra;

private extern (C) void* gc_calloc(size_t sz, uint ba = 0, const scope TypeInfo ti = null) @nogc nothrow;

extern (C) Object _d_newclass(const ClassInfo ci) nothrow
{
    auto init = ci.initializer;
    void* p = gc_calloc(init.length);
    (cast(ubyte*) p)[0 .. init.length] = cast(const(ubyte)[]) init[];
    return cast(Object) p;
}

extern (C) void rt_finalize2(void* p, bool det = true, bool resetMemory = true) nothrow
{
    alias fp_t = void function(Object);
    auto ppv = cast(void**) p;
    if (!p || !*ppv)
        return;

    auto pc = cast(TypeInfo_Class*) *ppv;
    try
    {
        auto c = *pc;
        do
        {
            if (c.destructor)
                (cast(fp_t) c.destructor)(cast(Object) p);
        }
        while ((c = c.base) !is null);

        if (resetMemory)
        {
            auto w = (*pc).initializer;
            p[0 .. w.length] = cast(void[]) w[];
        }
    }
    catch (Exception e)
    {
        import core.exception : onFinalizeError;
        onFinalizeError(*pc, e);
    }
    finally
    {
        *ppv = null;
    }
}

extern (C) void rt_finalize(void* p, bool det = true) nothrow
{
    rt_finalize2(p, det, true);
}

extern (C) void rt_finalizeFromGC(void* p, size_t size, uint attr, TypeInfo typeInfo) nothrow
{
    enum uint ATTR_APPENDABLE = 0b0000_1000; // core.memory.BlkAttr.APPENDABLE
    if (typeInfo is null)
    {
        rt_finalize2(p, false, false);
        return;
    }
    auto si = cast(TypeInfo_Struct) cast(void*) typeInfo;
    try
    {
        if (attr & ATTR_APPENDABLE)
        {
            const tsize = si.tsize;
            if (tsize)
                for (auto curP = p + size - tsize; curP >= p; curP -= tsize)
                    si.destroy(curP);
        }
        else
            si.destroy(p);
    }
    catch (Exception e)
    {
        import core.exception : onFinalizeError;
        onFinalizeError(si, e);
    }
}

// Only for &alloca, the wasm backend lowers direct alloca() calls to a dynamic
// shadow-stack bump
extern (C) void* alloca(size_t size) nothrow
{
    return gc_calloc(size);
}

extern (C) void[] _d_arrayappendcd(ref byte[] x, dchar c)
{
    char[4] buf = void;
    char[] appendthis;
    if (c <= 0x7F)
    {
        buf[0] = cast(char) c;
        appendthis = buf[0 .. 1];
    }
    else if (c <= 0x7FF)
    {
        buf[0] = cast(char)(0xC0 | (c >> 6));
        buf[1] = cast(char)(0x80 | (c & 0x3F));
        appendthis = buf[0 .. 2];
    }
    else if (c <= 0xFFFF)
    {
        buf[0] = cast(char)(0xE0 | (c >> 12));
        buf[1] = cast(char)(0x80 | ((c >> 6) & 0x3F));
        buf[2] = cast(char)(0x80 | (c & 0x3F));
        appendthis = buf[0 .. 3];
    }
    else if (c <= 0x10FFFF)
    {
        buf[0] = cast(char)(0xF0 | (c >> 18));
        buf[1] = cast(char)(0x80 | ((c >> 12) & 0x3F));
        buf[2] = cast(char)(0x80 | ((c >> 6) & 0x3F));
        buf[3] = cast(char)(0x80 | (c & 0x3F));
        appendthis = buf[0 .. 4];
    }
    else
        assert(0, "Invalid UTF-8 sequence");

    auto xx = cast(char[]) x;
    xx ~= appendthis;
    x = cast(byte[]) xx;
    return x;
}

extern (C) void[] _d_arrayappendwd(ref byte[] x, dchar c)
{
    wchar[2] buf = void;
    wchar[] appendthis;
    if (c <= 0xFFFF)
    {
        buf[0] = cast(wchar) c;
        appendthis = buf[0 .. 1];
    }
    else
    {
        const n = c - 0x10000;
        buf[0] = cast(wchar)((n >> 10) + 0xD800);
        buf[1] = cast(wchar)((n & 0x3FF) + 0xDC00);
        appendthis = buf[0 .. 2];
    }

    auto xx = cast(wchar[]) x;
    xx ~= appendthis;
    x = cast(byte[]) xx;
    return x;
}

import core.attribute : wasmImportModule;

@wasmImportModule("wasi_snapshot_preview1")
private extern (C) int clock_time_get(uint clockId, ulong precision, ulong* timestamp) @nogc nothrow;

extern (C) long clock() @nogc nothrow
{
    ulong t;
    if (clock_time_get(2, 1, &t) != 0 && clock_time_get(1, 1, &t) != 0)
        return -1;
    return cast(long) t;
}

extern (C) string[] rt_args() @nogc nothrow @system { return null; }

private extern(C) extern __gshared void* __start_minfo;
private extern(C) extern __gshared void* __stop_minfo;

extern (C) void rt_moduleUnitTests() nothrow
{
    auto b = cast(immutable(ModuleInfo)**) &__start_minfo;
    auto e = cast(immutable(ModuleInfo)**) &__stop_minfo;
    foreach (m; b[0 .. e - b])
        if (m !is null)
            if (auto f = m.unitTest)
                (cast(void function() nothrow) f)();
}

// wasi-libc emits these for 128 bit multiply (strtod/scanf long double paths)
extern (C) void __multi3(ulong* res, ulong alo, ulong ahi, ulong blo, ulong bhi)
{
    const ulong a0 = alo & 0xFFFF_FFFF, a1 = alo >> 32;
    const ulong b0 = blo & 0xFFFF_FFFF, b1 = blo >> 32;
    const ulong p00 = a0 * b0;
    const ulong mid = a0 * b1 + (p00 >> 32);
    const ulong mid2 = a1 * b0 + (mid & 0xFFFF_FFFF);
    res[0] = (mid2 << 32) | (p00 & 0xFFFF_FFFF);
    res[1] = a1 * b1 + (mid >> 32) + (mid2 >> 32) + alo * bhi + ahi * blo;
}

extern (C) void __muloti4(ulong* res, ulong alo, ulong ahi, ulong blo, ulong bhi, int* overflow)
{
    __multi3(res, alo, ahi, blo, bhi);

    static void mul64(ulong a, ulong b, out ulong lo, out ulong hi)
    {
        const ulong a0 = a & 0xFFFF_FFFF, a1 = a >> 32;
        const ulong b0 = b & 0xFFFF_FFFF, b1 = b >> 32;
        const ulong p00 = a0 * b0;
        const ulong mid = a0 * b1 + (p00 >> 32);
        const ulong mid2 = a1 * b0 + (mid & 0xFFFF_FFFF);
        lo = (mid2 << 32) | (p00 & 0xFFFF_FFFF);
        hi = a1 * b1 + (mid >> 32) + (mid2 >> 32);
    }
    static void neg128(ref ulong lo, ref ulong hi)
    {
        hi = ~hi + (lo == 0 ? 1 : 0);
        lo = 0 - lo;
    }

    const bool negA = (ahi >> 63) != 0;
    const bool negB = (bhi >> 63) != 0;
    if (negA)
        neg128(alo, ahi);
    if (negB)
        neg128(blo, bhi);

    ulong p0lo, p0hi, qlo, qhi, rlo, rhi;
    mul64(alo, blo, p0lo, p0hi);
    mul64(alo, bhi, qlo, qhi);
    mul64(ahi, blo, rlo, rhi);
    const bool anyTop = (ahi && bhi) || qhi || rhi;

    ulong mid = p0hi + qlo;
    bool carry = mid < p0hi;
    const ulong mid2 = mid + rlo;
    carry = carry || (mid2 < mid);

    const bool negResult = negA != negB;
    bool ovf = anyTop || carry;
    if (!ovf && (mid2 >> 63))
        ovf = !negResult || mid2 != 0x8000_0000_0000_0000UL || p0lo != 0;
    *overflow = ovf ? 1 : 0;
}
