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

// ── Bump-pointer allocator ────────────────────────────────────────────────────
// Avoids importing malloc from "env" (which WASM runtimes don't provide).
// Uses a static heap buffer (BSS — zero-init, no binary size cost).
// Allocations are never freed; the GC is intentionally a leaking allocator.

// Keep within the initial 64 KiB WASM page; the WASM backend doesn't yet
// grow pages for BSS globals, so the buffer must fit alongside the data section.
// TODO: switch to memory.grow-based allocation once the backend supports it.
private enum HEAP_SIZE = 48 * 1024; // 48 KiB — room for data + stack + this heap

// Zero-initialized (BSS): no binary overhead, allocated from WASM linear memory.
private __gshared ubyte[HEAP_SIZE] _heap_buf;
private __gshared ubyte* _heap_ptr;
private __gshared size_t _heap_left;

private void bump_init() @nogc nothrow
{
    _heap_ptr  = _heap_buf.ptr;
    _heap_left = HEAP_SIZE;
}

private void* bump_alloc(size_t sz) @nogc nothrow
{
    if (sz == 0) sz = 1;
    sz = (sz + 7u) & ~7u; // 8-byte alignment
    if (sz > _heap_left) return null; // heap exhausted
    void* p = _heap_ptr;
    _heap_ptr  += sz;
    _heap_left -= sz;
    return p;
}

// Zero-fill [p, p+sz).
private void memzero(void* p, size_t sz) @nogc nothrow
{
    auto b = cast(ubyte*) p;
    foreach (i; 0 .. sz) b[i] = 0;
}

// ── GC extern(C) interface ────────────────────────────────────────────────────

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
    // Simple realloc: alloc new, copy up to sz bytes, leak old.
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
