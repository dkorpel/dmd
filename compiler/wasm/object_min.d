/**
 * Minimal `object` module that the in-browser compiler feeds to user snippets
 * (injected into the FileManager). Sufficient for betterC-style code. Embedded
 * into dmd.wasm via -J string import; NOT compiled as part of the wasm itself.
 */
module object;

alias size_t = typeof(int.sizeof);
alias ptrdiff_t = typeof(cast(void*)0 - cast(void*)0);
alias string = immutable(char)[];
alias wstring = immutable(wchar)[];
alias dstring = immutable(dchar)[];
alias noreturn = typeof(*null);
alias hash_t = size_t;
alias equals_t = bool;

class Object
{
    string toString() { return "Object"; }
    size_t toHash() @trusted nothrow { return cast(size_t) cast(void*) this; }
    int opCmp(Object o) { assert(0); }
    bool opEquals(Object o) { return this is o; }
}

bool opEquals(Object lhs, Object rhs)
{
    if (lhs is rhs) return true;
    if (lhs is null || rhs is null) return false;
    return lhs.opEquals(rhs);
}

class Throwable
{
    interface TraceInfo {}
    string msg;
    this(string msg) { this.msg = msg; }
}
class Exception : Throwable { this(string m, string f = __FILE__, size_t l = __LINE__) { super(m); } }
class Error : Throwable { this(string m) { super(m); } }

class TypeInfo
{
    size_t getHash(scope const void* p) const @trusted nothrow { return 0; }
    bool equals(in void* p1, in void* p2) const { return p1 == p2; }
    size_t tsize() const nothrow pure @safe @nogc { return 0; }
    const(void)[] initializer() const @trusted nothrow pure { return null; }
}
class TypeInfo_Class : TypeInfo { ubyte[] m_init; string name; }
alias ClassInfo = TypeInfo_Class;
class TypeInfo_Pointer : TypeInfo { TypeInfo m_next; }
class TypeInfo_Array : TypeInfo { TypeInfo value; }
class TypeInfo_StaticArray : TypeInfo { TypeInfo value; size_t len; }
class TypeInfo_AssociativeArray : TypeInfo { TypeInfo value, key; }
class TypeInfo_Function : TypeInfo { TypeInfo next; string deco; }
class TypeInfo_Delegate : TypeInfo { TypeInfo next; string deco; }
class TypeInfo_Enum : TypeInfo { TypeInfo base; string name; void[] m_init; }
class TypeInfo_Const : TypeInfo { TypeInfo base; }
class TypeInfo_Invariant : TypeInfo_Const {}
class TypeInfo_Shared : TypeInfo_Const {}
class TypeInfo_Inout : TypeInfo_Const {}
class TypeInfo_Struct : TypeInfo
{
    string mangledName;
    void[] m_init;
    size_t function(in void*)           xtoHash;
    bool   function(in void*, in void*) xopEquals;
    int    function(in void*, in void*) xopCmp;
    string function(in void*)           xtoString;
    uint m_flags;
    union
    {
        void function(void*)                              xdtor;
        void function(void*, const TypeInfo_Struct ti)    xdtorti;
    }
    void function(void*)                    xpostblit;
    uint m_align;
    TypeInfo m_arg1;        // WithArgTypes (x86-64 System V)
    TypeInfo m_arg2;
    immutable(void)* m_RTInfo;
}

struct Interface { TypeInfo_Class classinfo; void*[] vtbl; size_t offset; }
struct OffsetTypeInfo { size_t offset; TypeInfo ti; }

// ---- runtime hooks the compiler lowers snippet code to (only need to exist &
// instantiate for semantic analysis; this object module is never executed) ----
extern (C) nothrow @nogc
{
    void* malloc(size_t size);
    void* memcpy(void* dst, const void* src, size_t n);
    void* memset(void* dst, int c, size_t n);
    int   memcmp(const void* a, const void* b, size_t n);
}

private template Unqual(T)
{
         static if (is(T U ==     const U)) alias Unqual = U;
    else static if (is(T U == immutable U)) alias Unqual = U;
    else static if (is(T U ==    inout U))  alias Unqual = U;
    else static if (is(T U ==   shared U))  alias Unqual = U;
    else                                    alias Unqual = T;
}

extern (C) bool _xopEquals(const(void)*, const(void)*) { return false; }
extern (C) bool _xopCmp(const(void)*, const(void)*) { return false; }
extern (C) void* _d_allocmemory(size_t sz) { return malloc(sz); }

void _d_array_slice_copy(void* dst, size_t dstlen, void* src, size_t srclen, size_t elemsz) @system
{
    memcpy(dst, src, dstlen * elemsz);
}

bool __equals(T1, T2)(scope const T1[] lhs, scope const T2[] rhs)
{
    if (lhs.length != rhs.length) return false;
    foreach (i; 0 .. lhs.length) if (lhs[i] != rhs[i]) return false;
    return true;
}

int __switch(T, caseLabels...)(/*in*/ const scope T[] condition) pure @safe @nogc nothrow
{
    foreach (i, label; caseLabels) if (condition == label) return cast(int) i;
    return -1;
}
noreturn __switch_error()(string file = __FILE__, size_t line = __LINE__) { assert(0); }

size_t _d_arraysetlengthT(Tarr : T[], T)(return ref scope Tarr arr, size_t newlength) @trusted
{
    auto p = cast(Unqual!T*) malloc(newlength * T.sizeof);
    if (arr.ptr) memcpy(p, arr.ptr, (arr.length < newlength ? arr.length : newlength) * T.sizeof);
    arr = cast(T[]) p[0 .. newlength];
    return newlength;
}

ref Tarr _d_arrayappendcTX(Tarr : T[], T)(return ref scope Tarr px, size_t n) @trusted
{
    auto p = cast(Unqual!T*) malloc((px.length + n) * T.sizeof);
    if (px.ptr) memcpy(p, px.ptr, px.length * T.sizeof);
    px = cast(Tarr) p[0 .. px.length + n];
    return px;
}

ref Tarr _d_arrayappendT(Tarr : T[], T)(return ref scope Tarr x, scope Tarr y) @trusted
{
    const len = x.length;
    _d_arrayappendcTX!Tarr(x, y.length);
    if (y.length) memcpy(cast(Unqual!T*) &x[len], cast(Unqual!T*) y.ptr, y.length * T.sizeof);
    return x;
}

Tret _d_arraycatnTX(Tret, Tarr...)(auto ref Tarr froms) @trusted
{
    Tret res;
    alias T = typeof(res[0]);
    size_t total;
    static foreach (f; froms) static if (is(typeof(f) : T)) total++; else total += f.length;
    if (!total) return res;
    _d_arraysetlengthT!Tret(res, total);
    auto rp = cast(Unqual!T*) res.ptr;
    foreach (ref f; froms)
        static if (is(typeof(f) : T)) { memcpy(rp, cast(void*) &f, T.sizeof); rp++; }
        else { if (f.length) { memcpy(rp, cast(void*) f.ptr, f.length * T.sizeof); rp += f.length; } }
    return res;
}

void* _d_arrayliteralTX(T)(size_t length) { return malloc(length * T.sizeof); }

T[] _d_newarrayT(T)(size_t length, bool isShared = false) @trusted
{
    auto p = cast(T*) malloc(length * T.sizeof);
    memset(p, 0, length * T.sizeof);
    return p[0 .. length];
}
alias _d_newarrayU(T) = _d_newarrayT!T;

T* _d_newitemT(T)() @trusted
{
    auto p = cast(T*) malloc(T.sizeof);
    memset(p, 0, T.sizeof);
    return p;
}

T _d_newclassT(T)() @trusted if (is(T == class))
{
    auto init = __traits(initSymbol, T);
    void* p = malloc(init.length);
    if (init.ptr) memcpy(p, init.ptr, init.length); else memset(p, 0, init.length);
    return cast(T) p;
}
