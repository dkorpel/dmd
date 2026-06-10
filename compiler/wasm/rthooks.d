/**
 * Minimal freestanding druntime ("object" module) for running the DMD frontend
 * as a WebAssembly module compiled with LDC (`-defaultlib=`).
 *
 * Self-contained: depends only on a handful of C library functions (malloc,
 * memcpy, ...) provided by wasi-libc. Allocation is malloc-backed and never
 * freed (the compiler is short-lived). Exceptions abort.
 *
 * Adapted from deepen/source/bops/object.d, stripped of bops dependencies.
 */
module object;

alias string  = immutable(char)[];
alias wstring = immutable(wchar)[];
alias dstring = immutable(dchar)[];
alias size_t  = typeof(int.sizeof);
alias hash_t  = size_t;
alias ptrdiff_t = typeof(cast(void*) 0 - cast(void*) 0);
alias noreturn = typeof(*null);

// The real C symbols are NOT marked pure: doing so makes LLVM treat malloc /
// memcpy as side-effect-free, so -O CSE/DCE collapses distinct allocations and
// drops memory writes (observed: struct `new` corrupting at -Oz). Instead the
// raw impure imports below link to the real libc names, and the friendly pure
// wrappers call through a function pointer cast to pure -- druntime's fake-pure
// trick. The frontend's many pure functions can then allocate/copy, while the
// optimizer still treats the underlying libc calls as having side effects.
private extern (C) nothrow @nogc
{
    pragma(mangle, "malloc")  void* c_malloc(size_t size) @trusted;
    pragma(mangle, "calloc")  void* c_calloc(size_t nmemb, size_t size) @trusted;
    pragma(mangle, "realloc") void* c_realloc(void* p, size_t size) @trusted;
    pragma(mangle, "memcpy")  void* c_memcpy(void* dst, const void* src, size_t n) @system;
    pragma(mangle, "memset")  void* c_memset(void* dst, int c, size_t n) @system;
    pragma(mangle, "memcmp")  int   c_memcmp(const void* a, const void* b, size_t n) @system;
    pragma(mangle, "strlen")  size_t c_strlen(const(char)* s) @system;
    void free(void* p) @trusted;
    noreturn abort() @trusted;
}

private void* malloc(size_t size) @trusted pure nothrow @nogc
    => (cast(void* function(size_t) @trusted pure nothrow @nogc) &c_malloc)(size);
private void* calloc(size_t n, size_t size) @trusted pure nothrow @nogc
    => (cast(void* function(size_t, size_t) @trusted pure nothrow @nogc) &c_calloc)(n, size);
private void* realloc(void* p, size_t size) @trusted pure nothrow @nogc
    => (cast(void* function(void*, size_t) @trusted pure nothrow @nogc) &c_realloc)(p, size);
private void* memcpy(void* dst, const void* src, size_t n) @system pure nothrow @nogc
    => (cast(void* function(void*, const void*, size_t) @system pure nothrow @nogc) &c_memcpy)(dst, src, n);
private void* memset(void* dst, int c, size_t n) @system pure nothrow @nogc
    => (cast(void* function(void*, int, size_t) @system pure nothrow @nogc) &c_memset)(dst, c, n);
private int memcmp(const void* a, const void* b, size_t n) @system pure nothrow @nogc
    => (cast(int function(const void*, const void*, size_t) @system pure nothrow @nogc) &c_memcmp)(a, b, n);
private size_t strlen(const(char)* s) @system pure nothrow @nogc
    => (cast(size_t function(const(char)*) @system pure nothrow @nogc) &c_strlen)(s);

private template Unqual(T)
{
         static if (is(T U ==     const U)) alias Unqual = U;
    else static if (is(T U == immutable U)) alias Unqual = U;
    else static if (is(T U ==    inout U))  alias Unqual = U;
    else static if (is(T U ==   shared U))  alias Unqual = U;
    else                                    alias Unqual = T;
}

private noreturn pabort() @trusted pure nothrow @nogc
    => (cast(noreturn function() @trusted pure nothrow @nogc) &abort)();

private void pfree(void* p) @trusted pure nothrow @nogc
    => (cast(void function(void*) @trusted pure nothrow @nogc) &free)(p);

// core.bitop.bswap is only declared (intrinsic) for this target, so the calls
// from core.internal.hash are left as external imports. Provide bodies so the
// module is self-contained (runnable under wasmtime without env imports).
version (WebAssembly)
{
    pragma(mangle, "_D4core5bitop5bswapFNaNbNiNfkZk")
    uint __bswap32(uint x) pure nothrow @nogc @safe
        => ((x & 0xFF) << 24) | ((x & 0xFF00) << 8) | ((x >> 8) & 0xFF00) | (x >> 24);

    pragma(mangle, "_D4core5bitop5bswapFNaNbNiNfmZm")
    ulong __bswap64(ulong x) pure nothrow @nogc @safe
    {
        uint lo = cast(uint) x;
        uint hi = cast(uint)(x >> 32);
        return (cast(ulong) __bswap32(lo) << 32) | __bswap32(hi);
    }
}

private noreturn unimplemented() @trusted pure nothrow @nogc { pabort(); }

// Needed for ImportC __builtins
template imported(string moduleName) { mixin("import imported = ", moduleName, ";"); }

// Generated for TryFinallyStatement
extern (C) void _Unwind_Resume(void* exception_object) {}

extern (C) bool _xopEquals(const(void)*, const(void)*) pure => unimplemented();
extern (C) bool _xopCmp(const(void)*, const(void)*) pure => unimplemented();

/// cast(TTo[])TFrom[]
TTo[] __ArrayCast(TFrom, TTo)(return scope TFrom[] from) pure @trusted
{
    const fromSize = from.length * TFrom.sizeof;
    const toLength = fromSize / TTo.sizeof;
    assert((fromSize % TTo.sizeof) == 0);
    struct Array { size_t length; void* ptr; }
    auto a = cast(Array*) &from;
    a.length = toLength;
    return *cast(TTo[]*) a;
}

// ---------------------------------------------------------------- asserts
extern (C) noreturn _d_assert_msg(string msg, string file, uint line) @trusted pure nothrow @nogc => pabort();

// These return `noreturn` (like druntime): the AA rvalue-index lowering builds
// `p ? p : _d_arraybounds(...)`, whose type unifies to the pointer only if the
// else branch is noreturn.
extern (C)
{
    noreturn _d_assert(string file, uint line) nothrow @nogc => _d_assert_msg("assert", file, line);
    noreturn _d_assertp(immutable(char)* file, uint line) => pabort();
    noreturn _d_arraybounds(string file, uint line) nothrow @nogc => pabort();
    noreturn _d_arraybounds_index(string file, uint line, size_t i, size_t length) nothrow @nogc => pabort();
    noreturn _d_arraybounds_slice(string file, uint line, size_t l, size_t u, size_t length) nothrow @nogc => pabort();
    noreturn _d_arrayboundsp(immutable(char)* file, uint line) => pabort();
    noreturn _d_arraybounds_slicep(immutable(char)* f, uint line, size_t l, size_t u, size_t len) => pabort();
    noreturn _d_arraybounds_indexp(immutable(char)* f, uint line, size_t i, size_t len) => pabort();
}

void __switch_error(string file, uint line) @safe pure nothrow @nogc => unimplemented();

version (WebAssembly)
noreturn __assert(const(char)* msg, const(char)* file, uint line) @system => abort();

// ---------------------------------------------------------------- memset helpers (DMD only, but harmless)
extern (C) void _d_array_slice_copy(void* dst, size_t dstlen, void* src, size_t srclen, size_t elemsz) @system
{
    assert(srclen == dstlen);
    memcpy(dst, src, dstlen * elemsz);
}

// Array element-wise equality
bool __equals(T1, T2)(scope const T1[] lhs, scope const T2[] rhs)
{
    if (lhs.length != rhs.length)
        return false;
    foreach (i; 0 .. lhs.length)
        if (lhs[i] != rhs[i])
            return false;
    return true;
}

// closure allocation
extern (C) void* _d_allocmemory(size_t sz) => malloc(sz);

// ---------------------------------------------------------------- misc runtime stubs
pragma(mangle, "_D2rt10invariant_12_d_invariantFC6ObjectZv")
void _d_invariant(Object o) {}                          // invariant checks: skip
extern (C) void _d_callfinalizer(void* p) {}           // no GC finalization

extern (C) void* _d_newitemU(const TypeInfo ti) @trusted nothrow
    => malloc(ti.tsize());

extern (C) void[] _d_newarrayiT(const TypeInfo ti, size_t length) @trusted nothrow
{
    auto sz = arrayElemSize(ti);
    auto p = cast(ubyte*) malloc(length * sz);
    auto init = ti.next().initializer();
    if (init.ptr is null)
        memset(p, 0, length * sz);
    else
        foreach (i; 0 .. length)
            memcpy(p + i * sz, init.ptr, sz);
    return (cast(void*) p)[0 .. length];
}

// core.math real-precision intrinsics (x87-only upstream); implement via libm.
private extern (C) nothrow @nogc
{
    pragma(mangle, "sin")   double c_sin(double) @trusted;
    pragma(mangle, "cos")   double c_cos(double) @trusted;
    pragma(mangle, "sqrt")  double c_sqrt(double) @trusted;
    pragma(mangle, "fabs")  double c_fabs(double) @trusted;
    pragma(mangle, "ldexp") double c_ldexp(double, int) @trusted;
    pragma(mangle, "log2")  double c_log2(double) @trusted;
}

pragma(mangle, "_D4core4math3sinFNaNbNiNfeZe")  real _m_sin(real x)  @trusted nothrow @nogc pure => cast(real) (cast(double function(double) @trusted nothrow @nogc pure) &c_sin)(cast(double) x);
pragma(mangle, "_D4core4math3cosFNaNbNiNfeZe")  real _m_cos(real x)  @trusted nothrow @nogc pure => cast(real) (cast(double function(double) @trusted nothrow @nogc pure) &c_cos)(cast(double) x);
pragma(mangle, "_D4core4math4sqrtFNaNbNiNfeZe") real _m_sqrt(real x) @trusted nothrow @nogc pure => cast(real) (cast(double function(double) @trusted nothrow @nogc pure) &c_sqrt)(cast(double) x);
pragma(mangle, "_D4core4math4fabsFNaNbNiNfeZe") real _m_fabs(real x) @trusted nothrow @nogc pure => cast(real) (cast(double function(double) @trusted nothrow @nogc pure) &c_fabs)(cast(double) x);
pragma(mangle, "_D4core4math5ldexpFNaNbNiNfeiZe") real _m_ldexp(real x, int n) @trusted nothrow @nogc pure => cast(real) (cast(double function(double, int) @trusted nothrow @nogc pure) &c_ldexp)(cast(double) x, n);
pragma(mangle, "_D4core4math4yl2xFNaNbNiNfeeZe")  real _m_yl2x(real x, real y)  @trusted nothrow @nogc pure => y * cast(real) (cast(double function(double) @trusted nothrow @nogc pure) &c_log2)(cast(double) x);
pragma(mangle, "_D4core4math6yl2xp1FNaNbNiNfeeZe") real _m_yl2xp1(real x, real y) @trusted nothrow @nogc pure => y * cast(real) (cast(double function(double) @trusted nothrow @nogc pure) &c_log2)(cast(double) x + 1.0);


// object.destroy: minimal (no GC finalization needed; memory leaks intentionally)
void destroy(bool initialize = true, T)(ref T obj) if (is(T == struct))
{
    static if (__traits(hasMember, T, "__xdtor"))
        obj.__xdtor();
}
void destroy(bool initialize = true, T)(T obj) if (is(T == class) || is(T == interface)) {}
void destroy(bool initialize = true, T)(ref T obj) if (is(T == U[], U) || __traits(isScalar, T))
{
    static if (initialize)
        obj = T.init;
}

// ---------------------------------------------------------------- arrays
// Top-level template (the compiler lowers `arr.length = n` to
// `object._d_arraysetlengthT!(Tarr)(arr, n)`).
size_t _d_arraysetlengthT(Tarr : T[], T)(return ref scope Tarr arr, size_t newlength) pure nothrow @nogc @trusted
{
    auto orig = arr;
    if (newlength <= arr.length)
        arr = arr[0 .. newlength];
    else
    {
        auto ptr = cast(Unqual!T*) malloc(newlength * T.sizeof);
        arr = cast(T[]) ptr[0 .. newlength];
        if (orig !is null)
            cast(Unqual!T[]) arr[0 .. orig.length] = orig[];
    }
    return newlength;
}

// .reserve array property (no-op capacity hint; we never shrink/realloc in place)
size_t reserve(T)(ref T[] arr, size_t newcapacity) pure nothrow @trusted
    => arr.length > newcapacity ? arr.length : newcapacity;

// AA .clear
void clear(Value, Key)(Value[Key] aa) @trusted if (!is(Value == shared))
{
    import core.internal.newaa : _aaClear;
    _aaClear(aa);
}
void clear(Value, Key)(Value[Key]* aa) @trusted if (!is(Value == shared))
{
    import core.internal.newaa : _aaClear;
    if (*aa) _aaClear(*aa);
}

// Copy a type's init symbol, or zero-fill when it is all-zero (ptr is null).
// Copying from a null init pointer is UB the optimizer turns into a trap.
private void initFrom(void* p, const(void)[] init) @trusted pure nothrow @nogc
{
    if (init.ptr is null)
        memset(p, 0, init.length);
    else
        memcpy(p, init.ptr, init.length);
}

T* _d_newitemT(T)() @trusted nothrow @nogc
{
    auto init = __traits(initSymbol, T);
    void* p = malloc(init.length);
    initFrom(p, init);
    return cast(T*) p;
}

T[] _d_newarrayU(T)(size_t length, bool isShared = false) pure nothrow @nogc @trusted
    => (cast(T*) malloc(length * T.sizeof))[0 .. length];

T[] _d_newarrayT(T)(size_t length, bool isShared = false) @trusted nothrow @nogc
{
    T[] result = _d_newarrayU!T(length, isShared);
    memset(result.ptr, 0, length * T.sizeof);
    return result;
}

ref Tarr _d_arrayappendcTX(Tarr : T[], T)(return ref scope Tarr px, size_t n) @trusted nothrow @nogc
{
    version (DigitalMars) pragma(inline, false);
    auto ti = typeid(Tarr);
    auto pxx = (cast(ubyte*) px.ptr)[0 .. px.length];
    ._d_arrayappendcTX(ti, pxx, n);
    px = (cast(T*) pxx.ptr)[0 .. pxx.length];
    return px;
}

ref Tarr _d_arrayappendT(Tarr : T[], T)(return ref scope Tarr x, scope Tarr y) @trusted nothrow @nogc
{
    pragma(inline, false);
    const length = x.length;
    _d_arrayappendcTX!Tarr(x, y.length);
    if (y.length == 0)
        return x;
    memcpy(cast(Unqual!T*) &x[length], cast(Unqual!T*) &y[0], y.length * T.sizeof);
    return x;
}

Tret _d_arraycatnTX(Tret, Tarr...)(auto ref Tarr froms) @trusted nothrow
{
    Tret res;
    size_t totalLen;
    alias T = typeof(res[0]);
    enum elemSize = T.sizeof;
    static foreach (from; froms)
        static if (is(typeof(from) : T))
            totalLen++;
        else
            totalLen += from.length;
    if (totalLen == 0)
        return res;
    _d_arraysetlengthT!(typeof(res))(res, totalLen);
    auto resptr = cast(Unqual!T*) res;
    foreach (ref from; froms)
    {
        static if (is(typeof(from) : T))
            memcpy(resptr++, cast(Unqual!T*)&from, elemSize);
        else
        {
            const len = from.length;
            if (len)
            {
                memcpy(resptr, cast(Unqual!T*) from, len * elemSize);
                resptr += len;
            }
        }
    }
    return res;
}

void* _d_arrayliteralTX(T)(size_t length) nothrow @nogc => malloc(length * T.sizeof);

// .dup / .idup array properties (mirrors druntime object.d)
@property auto dup(T)(T[] a) if (!is(const(T) : T))
{
    import core.internal.traits : Unconst;
    import core.internal.array.duplication : _dup;
    return _dup!(T, Unconst!T)(a);
}

@property T[] dup(T)(const(T)[] a) if (is(const(T) : T))
{
    import core.internal.array.duplication : _dup;
    return _dup!(const(T), T)(a);
}

@property immutable(T)[] idup(T)(T[] a)
{
    import core.internal.array.duplication : _dup;
    return _dup!(T, immutable(T))(a);
}

int __switch(T, caseLabels...)(/*in*/ const scope T[] condition) pure @safe
{
    foreach (i, label; caseLabels)
        if (condition == label)
            return i;
    return -1;
}

/// for i"" interpolated strings
pragma(mangle, "_D4core13interpolation16__getEmptyStringFNaNbNiNfZAya")
public string __getEmptyString() pure @safe => "";

// ---------------------------------------------------------------- exceptions (abort)
version (D_Exceptions)
extern (C)
{
    void _d_throwdwarf() => unimplemented();
    int  _d_eh_personality(int, int, long, void*, void*) => unimplemented();
    void _d_throw_exception(void*) => unimplemented();
    void* _d_eh_enter_catch(void*) => unimplemented();
}

version (D_TypeInfo):

private size_t arrayElemSize(const TypeInfo ti) pure nothrow @nogc => ti.next().tsize();

extern (C) void[] _d_newarrayU(const TypeInfo ti, size_t length) @trusted
{
    void[] result = malloc(length * arrayElemSize(ti))[0 .. length];
    assert(result.ptr);
    return result;
}

extern (C) void[] _d_newarrayT(const TypeInfo ti, size_t length) @trusted
{
    auto result = cast(ubyte[]) _d_newarrayU(ti, length);
    result[] = 0;
    return cast(void[]) result;
}

extern (C) ubyte[] _d_arraycatT(const TypeInfo ti, ubyte[] x, ubyte[] y) @system nothrow @nogc
{
    const sizeelem = arrayElemSize(ti);
    const xlen = x.length * sizeelem;
    const ylen = y.length * sizeelem;
    size_t len = xlen + ylen;
    if (!len)
        return null;
    auto p = (cast(ubyte*) malloc(len))[0 .. len];
    p.ptr[0 .. xlen] = x[];
    p.ptr[xlen .. len] = y[];
    return p[0 .. x.length + y.length];
}

extern (C) void[] _d_arrayappendT(const TypeInfo ti, ref ubyte[] x, ubyte[] y) @system nothrow @nogc
{
    auto length = x.length;
    const elemSize = arrayElemSize(ti);
    cast(void) _d_arrayappendcTX(ti, x, y.length);
    memcpy(x.ptr + length * elemSize, y.ptr, y.length * elemSize);
    return x;
}

extern (C) ubyte[] _d_arrayappendcTX(const TypeInfo ti, ref ubyte[] px, size_t n) @trusted pure nothrow @nogc
{
    const elemSize = arrayElemSize(ti);
    auto newLength = n + px.length;
    auto newSize = newLength * elemSize;
    auto ptr = cast(ubyte*) malloc(newSize);
    auto ns = ptr[0 .. newSize];
    auto op = px.ptr;
    auto ol = px.length * elemSize;
    foreach (i, b; op[0 .. ol])
        ns[i] = b;
    (cast(size_t*)(&px))[0] = newLength;
    (cast(void**)(&px))[1] = ns.ptr;
    return px;
}

// ---------------------------------------------------------------- classes
alias ClassInfo = TypeInfo_Class;

class Object
{
    string toString() => typeid(this).name;
    size_t toHash() const @trusted
    {
        auto addr = cast(size_t) cast(void*) this;
        return addr ^ (addr >>> 4);
    }
    int opCmp(Object o) const => assert(0);
    bool opEquals(Object o) const => this is o;
}

bool opEquals(Object lhs, Object rhs)
{
    if (lhs is rhs) return true;
    if (lhs is null || rhs is null) return false;
    if (!lhs.opEquals(rhs)) return false;
    if (typeid(lhs) is typeid(rhs) || (!__ctfe && typeid(lhs).opEquals(typeid(rhs))))
        return true;
    return rhs.opEquals(lhs);
}

extern (C) int _adEq2(void[] a1, void[] a2, TypeInfo ti) @system
{
    if (a1.length != a2.length) return 0;
    return ti.equals(&a1, &a2) ? 1 : 0;
}

extern (C) Object _d_allocclass(TypeInfo_Class ti) @trusted nothrow @nogc
{
    auto ptr = (cast(ubyte*) malloc(ti.m_init.length))[0 .. ti.m_init.length];
    ptr[] = cast(ubyte[]) ti.m_init[];
    return cast(Object) ptr.ptr;
}

extern (C) void* _d_dynamic_cast(Object o, TypeInfo_Class c) @trusted
{
    void* res = null;
    size_t offset = 0;
    if (o && _d_isbaseof2(typeid(o), c, offset))
        res = cast(void*) o + offset;
    return res;
}

extern (C) int _d_isbaseof2(scope TypeInfo_Class oc, scope const TypeInfo_Class c, scope ref size_t offset) @safe
{
    if (oc is c) return true;
    do
    {
        if (oc.base is c) return true;
        foreach (iface; oc.interfaces)
        {
            if (iface.classinfo is c || _d_isbaseof2(iface.classinfo, c, offset))
            {
                offset += iface.offset;
                return true;
            }
        }
        oc = oc.base;
    }
    while (oc);
    return false;
}

T _d_newclassT(T)() @trusted if (is(T == class))
{
    auto init = __traits(initSymbol, T);
    void* p = malloc(init.length);
    initFrom(p, init);
    return cast(T) p;
}

void* _d_cast(To, From)(From o) @trusted
{
    static if (is(From == To))
        return *cast(void**) &o;
    else static if (is(From == class) && is(To == interface))
        return _d_dynamic_cast(o, typeid(To));
    else static if (is(From == class) && is(To == class))
    {
        static if (is(From FromSupers == super) && is(To ToSupers == super) &&
            __traits(isFinalClass, To) && is(ToSupers[0] == From) &&
            ToSupers.length == 1 && FromSupers.length <= 1)
            return _d_paint_cast!To(o);
        else static if (is(To : From))
            return _d_class_cast!To(o);
        else
            return null;
    }
    else static if (is(From == interface))
        return _d_dynamic_cast(cast(Object) o, typeid(To));
    else
        return null;
}

private void* _d_paint_cast(To)(const return scope Object o) @trusted => cast(void*) o;
private void* _d_class_cast(To)(const return scope Object o) => _d_class_cast_impl(o, typeid(To));

void* _d_class_cast_impl(const return scope Object o, const TypeInfo_Class c) pure @safe
{
    if (!o) return null;
    TypeInfo_Class oc = typeid(o);
    int delta = oc.depth;
    if (delta && c.depth)
    {
        delta -= c.depth;
        if (delta < 0) return null;
        while (delta--) oc = oc.base;
        return areClassInfosEqual(oc, c) ? cast(void*) o : null;
    }
    do
    {
        if (areClassInfosEqual(oc, c)) return cast(void*) o;
        oc = oc.base;
    } while (oc);
    return null;
}

bool areClassInfosEqual(scope const TypeInfo_Class a, scope const TypeInfo_Class b) pure @safe
{
    if (a is b) return true;
    return a.nameSig == b.nameSig;
}

// Real druntime Throwable/Exception/Error shapes, so core.exception and other
// druntime modules that subclass/inspect them compile against this object.d.
class Throwable : Object
{
    interface TraceInfo
    {
        int opApply(scope int delegate(ref const(char[]))) const;
        int opApply(scope int delegate(ref size_t, ref const(char[]))) const;
        string toString() const;
    }

    alias TraceDeallocator = void function(TraceInfo) nothrow;

    string      msg;
    string      file;
    size_t      line;
    TraceInfo   info;
    TraceDeallocator infoDeallocator;

    private void*   _nextInChainPtr;

    private @property bool _nextIsRefcounted() @trusted scope pure nothrow @nogc const
    {
        if (__ctfe)
            return false;
        return (cast(size_t)_nextInChainPtr) & 1;
    }

    private uint _refcount;

    @property inout(Throwable) next() @trusted inout return scope pure nothrow @nogc
    {
        if (__ctfe)
            return cast(inout(Throwable)) _nextInChainPtr;
        return cast(inout(Throwable)) (_nextInChainPtr - _nextIsRefcounted);
    }

    @property void next(Throwable tail) @trusted scope pure nothrow @nogc
    {
        void* newTail = cast(void*)tail;
        if (tail && tail._refcount)
        {
            ++tail._refcount;
            ++newTail;
        }
        auto n = next;
        auto nrc = _nextIsRefcounted;
        _nextInChainPtr = null;
        if (nrc)
            _d_delThrowable(n);
        _nextInChainPtr = newTail;
    }

    @system @nogc final pure nothrow ref uint refcount() return { return _refcount; }

    int opApply(scope int delegate(Throwable) dg)
    {
        int result = 0;
        for (Throwable t = this; t; t = t.next)
        {
            result = dg(t);
            if (result)
                break;
        }
        return result;
    }

    static @system @nogc pure nothrow Throwable chainTogether(return scope Throwable e1, return scope Throwable e2)
    {
        if (!e1)
            return e2;
        if (!e2)
            return e1;
        for (auto e = e1; 1; e = e.next)
        {
            if (!e.next)
            {
                e.next = e2;
                break;
            }
        }
        return e1;
    }

    @nogc @safe pure nothrow this(string msg, Throwable nextInChain = null)
    {
        this.msg = msg;
        this.next = nextInChain;
    }

    @nogc @safe pure nothrow this(string msg, string file, size_t line, Throwable nextInChain = null)
    {
        this(msg, nextInChain);
        this.file = file;
        this.line = line;
    }

    @trusted nothrow ~this()
    {
        if (_nextIsRefcounted)
            _d_delThrowable(next);
        if (infoDeallocator !is null)
        {
            infoDeallocator(info);
            info = null;
        }
    }

    override string toString()
    {
        string s;
        toString((in buf) { s ~= buf; });
        return s;
    }

    void toString(scope void delegate(in char[]) sink) const
    {
        import core.internal.string : unsignedToTempString;
        char[20] tmpBuff = void;
        sink(typeid(this).name);
        sink("@"); sink(file);
        sink("("); sink(unsignedToTempString(line, tmpBuff)); sink(")");
        if (msg.length)
        {
            sink(": "); sink(msg);
        }
    }

    const(char)[] message() const @safe nothrow
    {
        return this.msg;
    }
}

class Exception : Throwable
{
    @nogc @safe pure nothrow this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null)
    {
        super(msg, file, line, nextInChain);
    }

    @nogc @safe pure nothrow this(string msg, Throwable nextInChain, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line, nextInChain);
    }
}

class Error : Throwable
{
    @nogc @safe pure nothrow this(string msg, Throwable nextInChain = null)
    {
        super(msg, nextInChain);
        bypassedException = null;
    }

    @nogc @safe pure nothrow this(string msg, string file, size_t line, Throwable nextInChain = null)
    {
        super(msg, file, line, nextInChain);
        bypassedException = null;
    }

    Throwable   bypassedException;
}

extern (C) void _d_delThrowable(Throwable t) @trusted @nogc nothrow pure { pfree(cast(void*) t); }

extern (C) Throwable _d_newThrowable(const TypeInfo_Class ti) @trusted nothrow
{
    auto p = cast(Throwable) _d_allocclass(cast(TypeInfo_Class) ti);
    p._refcount = 1;
    return p;
}

// ---------------------------------------------------------------- TypeInfo
version (X86_64) version = WithArgTypes;

private immutable ubyte[16] initZero = 0;

class TypeInfo
{
    override string toString() const @trusted => typeid(cast() this).name;
    bool opEquals(const TypeInfo ti) @safe const => this is ti;
    size_t getHash(scope const(void)* p) @trusted nothrow const => 0;
    bool equals(void* p1, void* p2) => p1 == p2;
    int compare(const void* p1, const void* p2) const => _xopCmp(p1, p2);
    size_t tsize() pure nothrow @nogc const => 1;
    void swap(void* p1, void* p2) const {}
    const(TypeInfo) next() pure nothrow @nogc const => null;
    abstract const(void)[] initializer() nothrow @nogc const pure @safe;
    uint flags() pure const @safe => 0;
    const(OffsetTypeInfo)[] offTi() const => null;
    void destroy(void* p) const {}
    void postblit(void* p) const {}
    size_t talign() const => tsize;
    version (WithArgTypes)
    int argTypes(ref TypeInfo arg1, ref TypeInfo arg2) @safe nothrow { arg1 = this; return 0; }
    immutable(void)* rtInfo() pure const @safe => null;
}

class TypeInfo_Class : TypeInfo
{
    byte[]      m_init;
    string      name;
    void*[]     vtbl;
    Interface[] interfaces;
    TypeInfo_Class base;
    void*       destructor;
    void function(Object) classInvariant;
    enum ClassFlags : ushort
    {
        isCOMclass = 0x1,
        noPointers = 0x2,
        hasOffTi = 0x4,
        hasCtor = 0x8,
        hasGetMembers = 0x10,
        hasTypeInfo = 0x20,
        isAbstract = 0x40,
        isCPPclass = 0x80,
        hasDtor = 0x100,
        hasNameSig = 0x200,
    }
    ClassFlags  m_flags;
    ushort      depth;
    void*       deallocator;
    OffsetTypeInfo[] m_offTi;
    void function(Object) defaultConstructor;
    immutable(void)* m_RTInfo;
    static if (__VERSION__ >= 2108)
        uint[4] nameSig;

    override uint flags() pure const @safe => 1;
    override const(OffsetTypeInfo)[] offTi() const => m_offTi;
    override immutable(void)* rtInfo() pure const @safe => m_RTInfo;

    override size_t tsize() pure nothrow @nogc const => Object.sizeof;
    override bool equals(const void* p1, const void* p2) const @trusted
    {
        Object o1 = *cast(Object*) p1;
        Object o2 = *cast(Object*) p2;
        return (o1 is o2) || (o1 && o1.opEquals(o2));
    }
    override const(void)[] initializer() nothrow @nogc pure const @safe => m_init;
}

class TypeInfo_Pointer : TypeInfo
{
    TypeInfo m_next;
    override bool equals(void* p1, void* p2) @system => *cast(void**) p1 == *cast(void**) p2;
    override size_t tsize() pure nothrow @nogc const => (void*).sizeof;
    override const(void)[] initializer() nothrow @nogc const @trusted => initZero[0 .. size_t.sizeof];
    override const(TypeInfo) next() pure nothrow @nogc const => m_next;
}

class TypeInfo_Array : TypeInfo
{
    TypeInfo value;
    override size_t tsize() pure nothrow @nogc const => 2 * size_t.sizeof;
    override const(TypeInfo) next() pure nothrow @nogc const => value;
    override const(void)[] initializer() nothrow @nogc const @trusted => initZero[0 .. size_t.sizeof * 2];
    override bool equals(void* p1, void* p2) @system
    {
        void[] a1 = *cast(void[]*) p1;
        void[] a2 = *cast(void[]*) p2;
        if (a1.length != a2.length) return false;
        size_t sz = value.tsize;
        foreach (i; 0 .. a1.length)
            if (!value.equals(a1.ptr + i * sz, a2.ptr + i * sz))
                return false;
        return true;
    }
}

class TypeInfo_StaticArray : TypeInfo
{
    TypeInfo value;
    size_t len;
    override size_t tsize() pure nothrow @nogc const => value.tsize * len;
    override const(TypeInfo) next() pure nothrow @nogc const => value;
    override const(void)[] initializer() nothrow @nogc const @trusted => null;
    override bool equals(void* p1, void* p2) @system
    {
        size_t sz = value.tsize;
        foreach (u; 0 .. len)
            if (!value.equals(p1 + u * sz, p2 + u * sz))
                return false;
        return true;
    }
}

class TypeInfo_Enum : TypeInfo
{
    TypeInfo base;
    string name;
    void[] m_init;
    override size_t tsize() pure nothrow @nogc const => base.tsize;
    override const(TypeInfo) next() pure nothrow @nogc const => base.next;
    override bool equals(void* p1, void* p2) => base.equals(p1, p2);
    override const(void)[] initializer() nothrow @nogc const @trusted => m_init;
}

class TypeInfo_h : TypeInfoGeneric!ubyte {}
class TypeInfo_b : TypeInfoGeneric!(bool, ubyte) {}
class TypeInfo_g : TypeInfoGeneric!(byte, ubyte) {}
class TypeInfo_a : TypeInfoGeneric!(char, ubyte) {}
class TypeInfo_t : TypeInfoGeneric!ushort {}
class TypeInfo_s : TypeInfoGeneric!(short, ushort) {}
class TypeInfo_u : TypeInfoGeneric!(wchar, ushort) {}
class TypeInfo_w : TypeInfoGeneric!(dchar, uint) {}
class TypeInfo_k : TypeInfoGeneric!uint {}
class TypeInfo_i : TypeInfoGeneric!(int, uint) {}
class TypeInfo_m : TypeInfoGeneric!ulong {}
class TypeInfo_l : TypeInfoGeneric!(long, ulong) {}
class TypeInfo_f : TypeInfoGeneric!float {}
class TypeInfo_d : TypeInfoGeneric!double {}
class TypeInfo_e : TypeInfoGeneric!real {}

class TypeInfoGeneric(T, Base = T) : TypeInfo
{
    override size_t tsize() pure nothrow @nogc const => T.sizeof;
    // byte compare avoids pulling in soft-float compare builtins (e.g. __eqtf2)
    override bool equals(void* p1, void* p2) @system => memcmp(p1, p2, T.sizeof) == 0;
    override const(void)[] initializer() nothrow @nogc const @trusted => initZero[0 .. T.sizeof <= 16 ? T.sizeof : 16];
}

class TypeInfoGenericArray(T) : TypeInfo_Array
{
    override const(TypeInfo) next() pure nothrow @nogc const => typeid(T);
}

class TypeInfo_v : TypeInfo
{
    override size_t tsize() pure nothrow @nogc const => void.sizeof;
    override const(void)[] initializer() nothrow @nogc const @trusted => initZero[0 .. 1];
    override bool equals(void* a, void* b) => false;
}

class TypeInfo_Av : TypeInfoGenericArray!(void) {}
class TypeInfo_Aa : TypeInfoGenericArray!(char) {}
class TypeInfo_Aya : TypeInfo_Aa {}
class TypeInfo_Axa : TypeInfo_Aa {}
class TypeInfo_Ai : TypeInfoGenericArray!(int) {}
class TypeInfo_Ak : TypeInfoGenericArray!(uint) {}
class TypeInfo_Ah : TypeInfoGenericArray!(ubyte) {}
class TypeInfo_Am : TypeInfoGenericArray!(ulong) {}

struct Interface
{
    TypeInfo_Class classinfo;
    void*[] vtbl;
    size_t offset;
}

struct OffsetTypeInfo
{
    size_t offset;
    TypeInfo ti;
}

class TypeInfo_Delegate : TypeInfo
{
    TypeInfo next;
    string deco;
    override size_t tsize() pure nothrow @nogc const => size_t.sizeof * 2;
    override const(void)[] initializer() nothrow @nogc const @trusted => initZero[0 .. size_t.sizeof * 2];
}

class TypeInfo_Interface : TypeInfo
{
    TypeInfo_Class info;
    override const(void)[] initializer() nothrow @nogc const @trusted => initZero[0 .. size_t.sizeof];
    override size_t tsize() pure nothrow @nogc const => Object.sizeof;
}

class TypeInfo_Const : TypeInfo
{
    TypeInfo base;
    override size_t tsize() pure nothrow @nogc const => base.tsize;
    override const(TypeInfo) next() pure nothrow @nogc const => base.next;
    override bool equals(void* p1, void* p2) => base.equals(p1, p2);
    override const(void)[] initializer() nothrow @nogc const @trusted => base.initializer();
}

class TypeInfo_Invariant : TypeInfo_Const {}
class TypeInfo_Shared : TypeInfo_Const {}
class TypeInfo_Inout : TypeInfo_Const {}

class TypeInfo_AssociativeArray : TypeInfo
{
    override size_t tsize() pure nothrow @nogc const => (char[int]).sizeof;
    override const(void)[] initializer() nothrow @nogc const @trusted => (cast(void*) null)[0 .. (char[int]).sizeof];
    override const(TypeInfo) next() pure nothrow @nogc const => value;
    override uint flags() pure const @safe => 1;
    override bool equals(void* p1, void* p2) @trusted => xopEquals(p1, p2);
    override size_t getHash(scope const(void)* p) nothrow @trusted const => xtoHash(p);

    // referenced by compiler-generated AA TypeInfo (see druntime object.d)
    private static import core.internal.newaa;
    alias Entry(K, V) = core.internal.newaa.Entry!(K, V);

    TypeInfo value;
    TypeInfo key;
    TypeInfo entry;
    bool function(scope const void* p1, scope const void* p2) nothrow @safe xopEquals;
    hash_t function(scope const void*) nothrow @safe xtoHash;

    alias aaOpEqual(K, V) = core.internal.newaa._aaOpEqual!(K, V);
    alias aaGetHash(K, V) = core.internal.newaa._aaGetHash!(K, V);

    override size_t talign() pure const => (char[int]).alignof;
}

// AA runtime entry points the compiler lowers to
public import core.internal.newaa : _d_aaIn, _d_aaDel, _d_aaNew, _d_aaEqual, _d_assocarrayliteralTX,
    _d_aaLen, _d_aaGetY, _d_aaGetRvalueX, _d_aaApply, _d_aaApply2;
public import core.internal.hash : hashOf;

class TypeInfo_Struct : TypeInfo
{
    string mangledName;
    void[] m_init;
    size_t function(const void*) xtohash;
    bool function(const void*, const void*) xopEquals;
    int function(const void*, const void*) xopCmp;
    string function(const void*) xtostring;
    uint flags;
    union
    {
        void function(void*) xdtor;
        void function(void*, const TypeInfo_Struct) xdtori;
    }
    void function(void*) xpostblit;
    uint align_;
    version (WithArgTypes)
    {
        override int argTypes(ref TypeInfo arg1, ref TypeInfo arg2) { arg1 = m_arg1; arg2 = m_arg2; return 0; }
        TypeInfo m_arg1;
        TypeInfo m_arg2;
    }
    immutable(void)* m_RTInfo;

    final string name() pure const @trusted => mangledName;
    override string toString() const => mangledName;
    override size_t tsize() pure nothrow @nogc const => m_init.length;
    override const(void)[] initializer() nothrow @nogc const pure @safe => m_init;
    override bool equals(const void* p1, const void* p2) @trusted
    {
        if (!p1 || !p2) return false;
        if (xopEquals) return (*xopEquals)(p1, p2);
        if (p1 == p2) return true;
        return memcmp(p1, p2, m_init.length) == 0;
    }
}

class TypeInfo_Function : TypeInfo
{
    override string toString() const => deco;
    override size_t tsize() pure nothrow @nogc const => 0;
    override const(void)[] initializer() nothrow @nogc const @safe => null;
    TypeInfo _next;
    override const(TypeInfo) next() pure nothrow @nogc const => _next;
    string deco;
}

class TypeInfo_Vector : TypeInfo
{
    TypeInfo base;
    override size_t tsize() pure nothrow @nogc const => base.tsize;
    override const(TypeInfo) next() pure nothrow @nogc const => base.next;
    override const(void)[] initializer() nothrow @nogc const @trusted => base.initializer();
}

class TypeInfo_Tuple : TypeInfo
{
    TypeInfo[] elements;
    override const(void)[] initializer() nothrow @nogc const @trusted => unimplemented();
}
