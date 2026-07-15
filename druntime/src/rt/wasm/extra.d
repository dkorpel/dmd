/**
 * Misc symbols required for WASM
 *
 * Copyright: Copyright (C) 1999-2026 by The D Language Foundation, All Rights Reserved
 * License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 */
module rt.wasm.extra;

private extern (C) void* gc_calloc(size_t sz, uint ba = 0, const scope TypeInfo ti = null) @nogc nothrow;

// Only for &alloca, the wasm backend lowers direct alloca() calls to a dynamic
// shadow-stack bump
extern (C) void* alloca(size_t size) nothrow
{
    return gc_calloc(size);
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

// Registers the static data segment with the GC. rt.memory.initStaticDataGC is
// not nothrow, but the wasm _start shim (rt.wasm.start) is -betterC and cannot
// catch, so wrap it here where try/catch is available.
extern (C) void _d_wasm_initStaticDataGC() nothrow
{
    import rt.memory : initStaticDataGC;
    try
        initStaticDataGC();
    catch (Throwable)
        assert(0, "initStaticDataGC failed");
}

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
