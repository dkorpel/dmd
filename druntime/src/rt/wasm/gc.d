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

import core.attribute : wasmImportModule;
private struct Ciovec { const(void)* buf; size_t len; }
@wasmImportModule("wasi_snapshot_preview1")
private extern(C) int fd_write(int fd, const(Ciovec)* iovs, size_t n, size_t* nw) @nogc nothrow;

private void bump_init() @nogc nothrow {}

private __gshared ulong totalAllocated;

private void* bump_alloc(size_t sz) @nogc nothrow
{
    if (sz == 0) sz = 1;
    void* p = calloc(1, sz); // wasi-libc calloc returns zeroed, aligned storage
    if (!p)
        dbgAllocFail(sz);
    else
        totalAllocated += sz;
    return p;
}

// Diagnostic for the failure path only: print the requested size so a bogus
// huge allocation (usually caused by memory corruption elsewhere) is visible.
private void dbgAllocFail(size_t sz) @nogc nothrow
{
    size_t nw;
    static immutable char[11] pre = "ALLOCFAIL ";
    Ciovec io1 = Ciovec(pre.ptr, 10);
    fd_write(2, &io1, 1, &nw);
    char[32] buf = void;
    size_t i = buf.length;
    buf[--i] = '\n';
    size_t v = sz;
    if (v == 0) buf[--i] = '0';
    else while (v) { buf[--i] = cast(char)('0' + v % 10); v /= 10; }
    Ciovec io2 = Ciovec(buf.ptr + i, buf.length - i);
    fd_write(2, &io2, 1, &nw);
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

GC.BlkInfo gc_qalloc(size_t sz, uint ba = 0, const scope TypeInfo ti = null)
{
    GC.BlkInfo b;
    b.base = bump_alloc(sz);
    b.size = b.base ? sz : 0;
    b.attr = ba;
    return b;
}

// In-place extension is never possible (see gc_expandArrayUsed).
size_t gc_extend(void* p, size_t mx, size_t sz, const TypeInfo ti = null) @nogc { return 0; }
size_t gc_reserve(size_t sz) @nogc { return 0; }

void gc_free(void* p) @nogc { /* intentional leak */ }

void* gc_addrOf(void* p) @nogc { return null; }

void gc_addRoot(void* p) @nogc {}
void gc_addRange(void* p, size_t sz, const TypeInfo ti = null) @nogc {}
void gc_removeRoot(void* p) {}
void gc_removeRange(void* p) {}
void gc_runFinalizers(const scope void[] segment) {}

GC.BlkInfo gc_query(return scope void* p) pure @nogc { return GC.BlkInfo.init; }

// Nothing is ever freed, so usedSize and the per-thread (single-thread)
// allocation total coincide. -profile=gc sizes allocations from deltas of
// allocatedInCurrentThread, so it must track every successful allocation.
GC.Stats gc_stats() @nogc { return GC.Stats(cast(size_t) totalAllocated, 0, totalAllocated); }
ulong gc_allocatedInCurrentThread() @nogc { return totalAllocated; }
GC.ProfileStats gc_profileStats() @nogc { return GC.ProfileStats.init; }

// No capacity tracking: an in-place extension can never be verified, so report
// failure and let append allocate a fresh block and copy. Reporting success
// here makes appends write past the block (or through a null ptr for empty
// arrays), silently corrupting neighbouring allocations.
bool gc_expandArrayUsed(void[] slice, size_t newUsed, bool atomic) @nogc { return false; }

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

// Run a class instance's destructor chain (used by `scope` classes and
// explicit destroy). rt_finalize lives in rt.wasm.extra.
private extern (C) void rt_finalize(void* p, bool det = true) nothrow;
void _d_callfinalizer(void* p) { rt_finalize(p); }
void _d_callinterfacefinalizer(void* p) {}

// `delete` expression hooks (referenced by rt.tracegc): finalize, then leak
// like every other deallocation in this no-collection runtime.
void _d_delclass(Object* p)
{
    if (p && *p)
    {
        rt_finalize(cast(void*) *p);
        *p = null;
    }
}

void _d_delinterface(void** p)
{
    if (p && *p)
    {
        auto pi = **cast(Interface***) *p;
        rt_finalize(*p - pi.offset);
        *p = null;
    }
}

void _d_delmemory(void** p)
{
    if (p)
        *p = null;
}

// Capacity growth helper used by array append operations.
size_t newCapacity(size_t newlength, size_t elemsize) pure nothrow @nogc
{
    // Simple linear growth: 2x requested size to reduce reallocations.
    return newlength * elemsize * 2;
}
