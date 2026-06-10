/**
 * core.memory for wasm32-wasi. Upstream core.memory._initialize is unimplemented
 * for this platform. The wasm build has no GC: allocation is malloc-backed and
 * never collected (the compiler is short-lived). Shadows druntime via
 * -Icompiler/wasm/shim. Only the GC surface used by rmem/newaa/timetrace.
 */
module core.memory;

private extern (C) nothrow @nogc
{
    pragma(mangle, "malloc")  void* c_malloc(size_t);
    pragma(mangle, "calloc")  void* c_calloc(size_t, size_t);
    pragma(mangle, "realloc") void* c_realloc(void*, size_t);
    pragma(mangle, "free")    void  c_free(void*);
}

struct GCStats
{
    size_t usedSize;
    size_t freeSize;
    size_t allocatedInCurrentThread;
}

struct ProfileStats
{
    size_t numCollections;
    size_t totalCollectionTime;
    size_t totalPauseTime;
    size_t maxCollectionTime;
    size_t maxPauseTime;
}

struct GC
{
  nothrow @nogc:
    enum BlkAttr : uint
    {
        NONE       = 0,
        FINALIZE   = 1,
        NO_SCAN    = 2,
        NO_MOVE    = 4,
        APPENDABLE = 8,
        NO_INTERIOR = 16,
        STRUCTFINAL = 32,
    }

    // fake-pure (see rthooks.d): rmem's pure xmalloc/xfree call these.
    static void* malloc(size_t sz, uint ba = 0, const TypeInfo ti = null) @trusted pure
        => (cast(void* function(size_t) @trusted pure nothrow @nogc) &c_malloc)(sz);
    static void* calloc(size_t sz, uint ba = 0, const TypeInfo ti = null) @trusted pure
        => (cast(void* function(size_t, size_t) @trusted pure nothrow @nogc) &c_calloc)(1, sz);
    static void* realloc(void* p, size_t sz, uint ba = 0, const TypeInfo ti = null) @trusted pure
        => (cast(void* function(void*, size_t) @trusted pure nothrow @nogc) &c_realloc)(p, sz);
    static void free(void* p) @trusted pure
        => (cast(void function(void*) @trusted pure nothrow @nogc) &c_free)(p);

    static void addRange(const void* p, size_t sz, const TypeInfo ti = null) @trusted {}
    static void removeRange(const void* p) @trusted {}
    static void runFinalizers(const scope void[] segment) @trusted {}

    static GCStats stats() @trusted { return GCStats.init; }
    static ProfileStats profileStats() @trusted { return ProfileStats.init; }
}

extern (C) bool gc_inFinalizer() nothrow @nogc @safe => false;
