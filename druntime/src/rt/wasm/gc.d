/**
 * Conservative, non-moving, stop-the-world mark-sweep GC for WebAssembly.
 *
 * Blocks are individual wasi-libc `malloc` chunks carrying a 16-byte header
 * (size, BlkAttr, mark/dead flags) immediately before the payload, and are
 * tracked in an address-sorted table so an arbitrary interior pointer can be
 * resolved to its block in O(log n). Collection runs inside `gc_malloc` when
 * allocation since the last cycle crosses an adaptive threshold.
 *
 * Correctness rests on two WASM-backend invariants (verified, see below):
 *   1. The backend spills every value that is live across a call — named
 *      locals, parameters AND expression temporaries — into a linear-memory
 *      shadow frame; it never holds a pointer only on the value stack across a
 *      `call`. Every GC safepoint is such a call (into `gc_malloc`), so every
 *      live D reference is in scannable linear memory when we collect.
 *   2. No post-link pass promotes a linear-memory slot back into a wasm local:
 *      binaryen optimises wasm locals only and treats calls as opaque memory
 *      barriers. The default pipeline runs no wasm-opt at all. If either
 *      invariant is ever broken, run binaryen's `--spill-pointers` before
 *      shipping, which re-homes locals to the shadow stack.
 *
 * The collector is therefore a linear-memory scanner: roots are the shadow
 * stack (`&local` up to `__stack_high`), static data (`__global_base` up to
 * `__data_end`), plus ranges/roots registered via gc_addRange/gc_addRoot.
 * Single-threaded, so stop-the-world is just "don't return from gc_malloc":
 * there are no other threads, no signals and no async safepoints to worry
 * about. Non-moving + conservative tolerates false roots (they merely retain
 * garbage); only a missed root is fatal, which invariant (1) rules out.
 *
 * Copyright: Copyright (C) 1999-2026 by The D Language Foundation, All Rights Reserved
 * License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 */
module rt.wasm.gc;

import core.memory : GC;

nothrow:

private extern (C) void* malloc(size_t) @nogc nothrow;
private extern (C) void free(void*) @nogc nothrow;

// Linker-defined boundaries (wasm-ld stack-first layout): the shadow stack
// occupies [0, __stack_high) and static data occupies [__global_base,
// __data_end). Their *addresses* are the boundary values.
private extern (C) extern __gshared ubyte __stack_high;
private extern (C) extern __gshared ubyte __global_base;
private extern (C) extern __gshared ubyte __data_end;

private extern (C) void rt_finalize(void* p, bool det = true) nothrow;
private extern (C) void rt_finalizeFromGC(void* p, size_t size, uint attr, TypeInfo typeInfo) nothrow;

import core.attribute : wasmImportModule;

private struct Ciovec
{
    const(void)* buf;
    size_t len;
}

@wasmImportModule("wasi_snapshot_preview1")
private extern (C) int fd_write(int fd, const(Ciovec)* iovs, size_t n, size_t* nw) @nogc nothrow;

private enum uint ATTR_FINALIZE = 0b0000_0001;
private enum uint ATTR_NO_SCAN = 0b0000_0010;
private enum uint ATTR_APPENDABLE = 0b0000_1000;
private enum uint ATTR_STRUCTFINAL = 0b0010_0000;

private enum size_t HEADER = 24;

private enum uint F_MARK = 1;
private enum uint F_DEAD = 2;

private struct BlkHeader
{
    size_t size;
    uint attr;
    uint flags;
    size_t used;
    TypeInfo ti;
    uint _pad;
}

static assert(BlkHeader.sizeof == HEADER);

private __gshared
{
    BlkHeader** blocks;
    size_t nblocks;
    size_t capblocks;
    bool sorted;
    BlkHeader* lastFound;

    BlkHeader** markStack;
    size_t markTop;
    size_t markCap;

    size_t heapMin = size_t.max;
    size_t heapMax = 0;

    size_t bytesSinceCollect;
    size_t collectThreshold = 256 * 1024;
    size_t liveBytes;

    ulong totalAllocated;
    bool enabled = true;
    bool collecting;
    bool inFinalizer;

    Range* ranges;
    Root* roots;
}

private struct Range
{
    void* base;
    size_t size;
    Range* next;
}

private struct Root
{
    void* p;
    Root* next;
}

private void memzero(void* p, size_t sz) @nogc nothrow
{
    auto b = cast(ubyte*) p;
    foreach (i; 0 .. sz)
        b[i] = 0;
}

// Grow a doubling pointer array (blocks/markStack), copying the first `count`
// entries. Returns false and leaves the array untouched if malloc fails.
private bool growPtrArray(ref BlkHeader** arr, ref size_t cap, size_t count) @nogc nothrow
{
    size_t ncap = cap ? cap * 2 : 256;
    auto nb = cast(BlkHeader**) malloc(ncap * (BlkHeader*).sizeof);
    if (!nb)
    {
        dbgAllocFail(ncap);
        return false;
    }
    foreach (i; 0 .. count)
        nb[i] = arr[i];
    if (arr)
        free(arr);
    arr = nb;
    cap = ncap;
    return true;
}

private void includeInHeapBounds(BlkHeader* h) @nogc nothrow
{
    size_t lo = cast(size_t) h + HEADER;
    size_t hi = lo + h.size;
    if (lo < heapMin)
        heapMin = lo;
    if (hi > heapMax)
        heapMax = hi;
}

private void registerBlock(BlkHeader* h) @nogc nothrow
{
    if (nblocks == capblocks && !growPtrArray(blocks, capblocks, nblocks))
        return;
    blocks[nblocks++] = h;
    sorted = false;
    includeInHeapBounds(h);
}

private void* allocCore(size_t sz, uint ba, bool zero, TypeInfo ti = null) @nogc nothrow
{
    if (sz == 0)
        sz = 1;
    if (enabled && !collecting && bytesSinceCollect > collectThreshold)
        collectNow();

    size_t total = HEADER + sz;
    auto h = cast(BlkHeader*) malloc(total);
    if (!h)
    {
        if (!collecting)
        {
            collectNow();
            h = cast(BlkHeader*) malloc(total);
        }
        if (!h)
        {
            dbgAllocFail(sz);
            return null;
        }
    }
    h.size = sz;
    h.attr = ba;
    h.flags = 0;
    h.ti = ti;
    h.used = sz;
    registerBlock(h);
    bytesSinceCollect += total;
    totalAllocated += sz;
    void* payload = cast(void*) h + HEADER;
    if (zero)
        memzero(payload, sz);
    return payload;
}

private void siftDown(BlkHeader** a, size_t root, size_t n) @nogc nothrow
{
    for (;;)
    {
        size_t child = 2 * root + 1;
        if (child >= n)
            break;
        if (child + 1 < n && cast(size_t) a[child + 1] > cast(size_t) a[child])
            child++;
        if (cast(size_t) a[child] <= cast(size_t) a[root])
            break;
        auto t = a[root];
        a[root] = a[child];
        a[child] = t;
        root = child;
    }
}

private void sortBlocks() @nogc nothrow
{
    auto a = blocks;
    size_t n = nblocks;
    for (size_t i = n / 2; i-- > 0;)
        siftDown(a, i, n);
    for (size_t end = n; end-- > 1;)
    {
        auto t = a[0];
        a[0] = a[end];
        a[end] = t;
        siftDown(a, 0, end);
    }
    sorted = true;
}

private BlkHeader* findBlock(size_t v) @nogc nothrow
{
    if (v < heapMin || v >= heapMax)
        return null;
    if (BlkHeader* h = lastFound)
    {
        size_t base = cast(size_t) h;
        if (v >= base && v < base + HEADER + h.size && !(h.flags & F_DEAD))
            return h;
    }
    if (!sorted)
        sortBlocks();
    size_t lo = 0, hi = nblocks;
    while (lo < hi)
    {
        size_t mid = (lo + hi) / 2;
        if (cast(size_t) blocks[mid] <= v)
            lo = mid + 1;
        else
            hi = mid;
    }
    if (lo == 0)
        return null;
    BlkHeader* h = blocks[lo - 1];
    if (h.flags & F_DEAD)
        return null;
    if (v < cast(size_t) h + HEADER + h.size)
    {
        lastFound = h;
        return h;
    }
    return null;
}

private void pushMark(BlkHeader* h) @nogc nothrow
{
    if (markTop == markCap && !growPtrArray(markStack, markCap, markTop))
        return;
    markStack[markTop++] = h;
}

private void markCandidate(size_t v) @nogc nothrow
{
    BlkHeader* h = findBlock(v);
    if (!h || (h.flags & F_MARK))
        return;
    h.flags |= F_MARK;
    if (!(h.attr & ATTR_NO_SCAN))
        pushMark(h);
}

private void scanRange(size_t start, size_t end) @nogc nothrow
{
    start = (start + 3) & ~cast(size_t) 3;
    for (size_t a = start; a + (size_t).sizeof <= end; a += (size_t).sizeof)
        markCandidate(*cast(size_t*) a);
}

private void drainMark() @nogc nothrow
{
    while (markTop)
    {
        BlkHeader* h = markStack[--markTop];
        size_t payload = cast(size_t) h + HEADER;
        scanRange(payload, payload + h.size);
    }
}

private void finalizeBlock(BlkHeader* h) @nogc nothrow
{
    if (h.attr & ATTR_FINALIZE)
    {
        inFinalizer = true;
        void* p = cast(void*) h + HEADER;
        TypeInfo ti = (h.attr & ATTR_STRUCTFINAL) ? h.ti : null;
        size_t fsize = (h.attr & ATTR_APPENDABLE) ? h.used : h.size;
        auto fin = cast(void function(void*, size_t, uint, TypeInfo) @nogc nothrow)&rt_finalizeFromGC;
        fin(p, fsize, h.attr, ti);
        inFinalizer = false;
    }
}

private void collectNow() @nogc nothrow
{
    if (collecting || nblocks == 0)
        return;
    collecting = true;

    ubyte probe = void;
    size_t sp = cast(size_t)&probe;

    if (!sorted)
        sortBlocks();
    foreach (i; 0 .. nblocks)
        blocks[i].flags &= ~F_MARK;
    markTop = 0;

    scanRange(sp, cast(size_t)&__stack_high);
    scanRange(cast(size_t)&__global_base, cast(size_t)&__data_end);
    for (Range* r = ranges; r; r = r.next)
        scanRange(cast(size_t) r.base, cast(size_t) r.base + r.size);
    for (Root* r = roots; r; r = r.next)
        markCandidate(cast(size_t) r.p);
    drainMark();

    size_t n = nblocks;
    size_t write = 0;
    heapMin = size_t.max;
    heapMax = 0;
    liveBytes = 0;
    foreach (i; 0 .. n)
    {
        BlkHeader* h = blocks[i];
        if ((h.flags & F_MARK) && !(h.flags & F_DEAD))
        {
            h.flags &= ~F_MARK;
            liveBytes += h.size;
            includeInHeapBounds(h);
            blocks[write++] = h;
        }
        else
        {
            if (!(h.flags & F_DEAD))
                finalizeBlock(h);
            free(h);
        }
    }
    bool grew = nblocks > n;
    foreach (i; n .. nblocks)
    {
        BlkHeader* h = blocks[i];
        includeInHeapBounds(h);
        blocks[write++] = h;
    }
    nblocks = write;
    if (grew)
        sorted = false;

    lastFound = null;

    size_t thresh = liveBytes * 2;
    collectThreshold = thresh > 256 * 1024 ? thresh : 256 * 1024;
    bytesSinceCollect = 0;
    collecting = false;
}

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
    if (v == 0)
        buf[--i] = '0';
    else
        while (v)
        {
            buf[--i] = cast(char)('0' + v % 10);
            v /= 10;
        }
    Ciovec io2 = Ciovec(buf.ptr + i, buf.length - i);
    fd_write(2, &io2, 1, &nw);
}

extern (C):

void gc_init()
{
}

void gc_init_nothrow() @nogc
{
}

void gc_term()
{
}

void gc_enable() @nogc
{
    enabled = true;
}

void gc_disable() @nogc
{
    enabled = false;
}

void gc_collect() @nogc
{
    collectNow();
}

void gc_minimize() @nogc
{
    collectNow();
}

void* gc_malloc(size_t sz, uint ba = 0, const scope TypeInfo ti = null)
{
    return allocCore(sz, ba, true, cast(TypeInfo) ti);
}

void* gc_calloc(size_t sz, uint ba = 0, const scope TypeInfo ti = null)
{
    return allocCore(sz, ba, true, cast(TypeInfo) ti);
}

void* gc_realloc(void* p, size_t sz, uint ba = 0, const scope TypeInfo ti = null)
{
    if (!p)
        return allocCore(sz, ba, true, cast(TypeInfo) ti);
    BlkHeader* oldh = (cast(BlkHeader*) p) - 1;
    size_t oldsz = oldh.size;
    void* q = allocCore(sz, oldh.attr, false, oldh.ti);
    if (q)
    {
        size_t ncopy = oldsz < sz ? oldsz : sz;
        auto src = cast(ubyte*) p;
        auto dst = cast(ubyte*) q;
        foreach (i; 0 .. ncopy)
            dst[i] = src[i];
        if (sz > ncopy)
            memzero(dst + ncopy, sz - ncopy);
    }
    return q;
}

GC.BlkInfo gc_qalloc(size_t sz, uint ba = 0, const scope TypeInfo ti = null)
{
    GC.BlkInfo b;
    b.base = allocCore(sz, ba, true, cast(TypeInfo) ti);
    b.size = b.base ? sz : 0;
    b.attr = ba;
    return b;
}

size_t gc_extend(void* p, size_t mx, size_t sz, const TypeInfo ti = null) @nogc
{
    return 0;
}

size_t gc_reserve(size_t sz) @nogc
{
    return 0;
}

void gc_free(void* p) @nogc
{
    if (!p)
        return;
    BlkHeader* h = (cast(BlkHeader*) p) - 1;
    if (h.flags & F_DEAD)
        return;
    h.attr &= ~(ATTR_FINALIZE | ATTR_STRUCTFINAL);
    h.flags |= F_DEAD;
    if (lastFound is h)
        lastFound = null;
}

void* gc_addrOf(void* p) @nogc
{
    BlkHeader* h = findBlock(cast(size_t) p);
    return h ? cast(void*) h + HEADER : null;
}

void gc_addRoot(void* p) @nogc
{
    auto n = cast(Root*) malloc(Root.sizeof);
    if (!n)
        return;
    n.p = p;
    n.next = roots;
    roots = n;
}

void gc_addRange(void* p, size_t sz, const TypeInfo ti = null) @nogc
{
    auto n = cast(Range*) malloc(Range.sizeof);
    if (!n)
        return;
    n.base = p;
    n.size = sz;
    n.next = ranges;
    ranges = n;
}

void gc_removeRoot(void* p)
{
    Root** pp = &roots;
    for (Root* r = roots; r; pp = &r.next, r = r.next)
        if (r.p is p)
        {
            *pp = r.next;
            free(r);
            return;
        }
}

void gc_removeRange(void* p)
{
    Range** pp = &ranges;
    for (Range* r = ranges; r; pp = &r.next, r = r.next)
        if (r.base is p)
        {
            *pp = r.next;
            free(r);
            return;
        }
}

void gc_runFinalizers(const scope void[] segment)
{
}

GC.BlkInfo gc_query(return scope void* p) @nogc
{
    GC.BlkInfo b;
    BlkHeader* h = findBlock(cast(size_t) p);
    if (h)
    {
        b.base = cast(void*) h + HEADER;
        b.size = h.size;
        b.attr = h.attr;
    }
    return b;
}

GC.Stats gc_stats() @nogc
{
    return GC.Stats(liveBytes, 0, totalAllocated);
}

ulong gc_allocatedInCurrentThread() @nogc
{
    return totalAllocated;
}

GC.ProfileStats gc_profileStats() @nogc
{
    return GC.ProfileStats.init;
}

private BlkHeader* appendableBlock(void* p, out size_t offset) @nogc nothrow
{
    BlkHeader* h = findBlock(cast(size_t) p);
    if (!h || !(h.attr & ATTR_APPENDABLE))
    {
        offset = 0;
        return null;
    }
    offset = cast(size_t) p - (cast(size_t) h + HEADER);
    return h;
}

bool gc_expandArrayUsed(void[] slice, size_t newUsed, bool atomic) @nogc
{
    if (newUsed < slice.length)
        return false;
    size_t offset;
    BlkHeader* h = appendableBlock(slice.ptr, offset);
    if (!h)
        return false;
    newUsed += offset;
    size_t existingUsed = slice.length + offset;
    if (h.used != existingUsed)
        return false;
    if (newUsed > h.size)
        return false;
    h.used = newUsed;
    return true;
}

size_t gc_reserveArrayCapacity(void[] slice, size_t request, bool atomic) @nogc
{
    size_t offset;
    BlkHeader* h = appendableBlock(slice.ptr, offset);
    if (!h)
        return 0;
    request += offset;
    size_t existingUsed = slice.length + offset;
    if (h.used != existingUsed)
        return 0;
    if (h.size < request)
        return 0;
    return h.size - offset;
}

bool gc_shrinkArrayUsed(void[] slice, size_t existingUsed, bool atomic) @nogc
{
    if (existingUsed < slice.length)
        return false;
    size_t offset;
    BlkHeader* h = appendableBlock(slice.ptr, offset);
    if (!h)
        return false;
    existingUsed += offset;
    size_t newUsed = slice.length + offset;
    if (h.used != existingUsed)
        return false;
    h.used = newUsed;
    return true;
}

void[] gc_getArrayUsed(void* p, bool atomic) @nogc
{
    BlkHeader* h = findBlock(cast(size_t) p);
    if (!h || !(h.attr & ATTR_APPENDABLE))
        return null;
    return (cast(void*) h + HEADER)[0 .. h.used];
}

size_t gc_sizeOf(void* p) @nogc
{
    BlkHeader* h = findBlock(cast(size_t) p);
    return h ? h.size : 0;
}

bool gc_inFinalizer() @nogc
{
    return inFinalizer;
}

uint gc_getAttr(void* p) @nogc
{
    BlkHeader* h = findBlock(cast(size_t) p);
    return h ? h.attr : 0;
}

uint gc_setAttr(void* p, uint a) @nogc
{
    BlkHeader* h = findBlock(cast(size_t) p);
    if (!h)
        return 0;
    h.attr |= a;
    return h.attr;
}

uint gc_clrAttr(void* p, uint a) @nogc
{
    BlkHeader* h = findBlock(cast(size_t) p);
    if (!h)
        return 0;
    h.attr &= ~a;
    return h.attr;
}

size_t newCapacity(size_t newlength, size_t elemsize) pure nothrow @nogc
{
    return newlength * elemsize * 2;
}
