/**
 * Minimal GC for WebAssembly: bump-pointer allocator backed by wasi-libc malloc.
 * No scanning, no collection — allocations leak intentionally.
 *
 * Copyright: Copyright (C) 1999-2026 by The D Language Foundation, All Rights Reserved
 * License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 */
module rt.wasm.gc;

import core.memory : GC;

nothrow:


private extern(C) void* calloc(size_t, size_t) @nogc nothrow;

private void bump_init() @nogc nothrow {}

private void* bump_alloc(size_t sz) @nogc nothrow
{
    if (sz == 0) sz = 1;
    return calloc(1, sz); // wasi-libc calloc returns zeroed, aligned storage
}

// Zero-fill [p, p+sz).
private void memzero(void* p, size_t sz) @nogc nothrow
{
    auto b = cast(ubyte*) p;
    foreach (i; 0 .. sz) b[i] = 0;
}

extern (C):

void gc_init() { bump_init(); }
void gc_init_nothrow() @nogc { bump_init(); }
void gc_term() {}
void gc_enable() @nogc {}
void gc_disable() @nogc {}
void gc_collect() @nogc {}
void gc_minimize() @nogc {}

void* gc_malloc(size_t sz, uint ba = 0, const scope TypeInfo ti = null)
{
    return bump_alloc(sz);
}

void* gc_calloc(size_t sz, uint ba = 0, const scope TypeInfo ti = null)
{
    void* p = bump_alloc(sz);
    if (p) memzero(p, sz);
    return p;
}

void* gc_realloc(void* p, size_t sz, uint ba = 0, const scope TypeInfo ti = null)
{
    void* q = bump_alloc(sz);
    if (q && p)
    {
        auto src = cast(ubyte*) p;
        auto dst = cast(ubyte*) q;
        foreach (i; 0 .. sz) dst[i] = src[i];
    }
    return q;
}

void gc_free(void* p) @nogc { /* intentional leak */ }

void* gc_addrOf(void* p) @nogc { return null; }

void gc_addRoot(void* p) @nogc {}
void gc_addRange(void* p, size_t sz, const TypeInfo ti = null) @nogc {}
void gc_removeRoot(void* p) {}
void gc_removeRange(void* p) {}
void gc_runFinalizers(const scope void[] segment) {}

GC.BlkInfo gc_query(return scope void* p) pure @nogc { return GC.BlkInfo.init; }

// No statistics tracked by the bump allocator.
GC.Stats gc_stats() @nogc { return GC.Stats.init; }
GC.ProfileStats gc_profileStats() @nogc { return GC.ProfileStats.init; }

// Stub: in a leaking GC, "expanding used" always succeeds (no real capacity tracking).
bool gc_expandArrayUsed(void[] slice, size_t newUsed, bool atomic) @nogc { return true; }

// This GC tracks no per-block capacity, so report none reserved: callers then
// reallocate rather than write past the exact bump-allocated size.
size_t gc_reserveArrayCapacity(void[] slice, size_t request, bool atomic) @nogc { return 0; }

// No capacity tracking, so shrinking the "used" length is a no-op that reports
// failure; the array simply keeps its current block.
bool gc_shrinkArrayUsed(void[] slice, size_t existingUsed, bool atomic) @nogc { return false; }

// No per-block size tracking in the bump allocator.
size_t gc_sizeOf(void* p) @nogc { return 0; }

// Single-threaded, no finalizers run: never inside one.
bool gc_inFinalizer() @nogc { return false; }

uint gc_getAttr(void* p) @nogc { return 0; }
uint gc_setAttr(void* p, uint a) @nogc { return 0; }
uint gc_clrAttr(void* p, uint a) @nogc { return 0; }

void* _d_allocmemory(size_t sz) { return gc_malloc(sz, 0, null); }
void _d_callfinalizer(void* p) {}
void _d_callinterfacefinalizer(void* p) {}

// Capacity growth helper used by array append operations.
size_t newCapacity(size_t newlength, size_t elemsize) pure nothrow @nogc
{
    // Simple linear growth: 2x requested size to reduce reallocations.
    return newlength * elemsize * 2;
}
