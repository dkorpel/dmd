/**
 * Linear memory for CTFE intermediate values.
 *
 * Instead of representing every intermediate value as a heap-allocated AST
 * node (`IntegerExp`, `StructLiteralExp`, ...), values are stored in flat
 * byte arenas, similar to WebAssembly linear memory. See
 * `compiler/docs/ctfe_linear_memory.md` for the design.
 *
 * Safety model: interpreted code can never corrupt compiler memory. CTFE
 * pointers are fat handles (allocation id + offset) validated against an
 * allocation table on every access; out-of-bounds or dangling accesses fail
 * cleanly and are reported as CTFE errors by the caller. Little endian byte
 * order is assumed.
 *
 * The entry point and result of CTFE remain AST nodes: `encode` serializes a
 * literal `Expression` into linear memory, `decode` rebuilds one. Source
 * locations are dropped for intermediate values; `decode` stamps the
 * caller-provided location (normally the CTFE call site) onto the result.
 *
 * Copyright:   Copyright (C) 1999-2026 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 https://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/compiler/src/dmd/ctfememory.d, _ctfememory.d)
 * Documentation:  https://dlang.org/phobos/dmd_ctfememory.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/compiler/src/dmd/ctfememory.d
 */
module dmd.ctfememory;

import core.stdc.string : memcpy, memset;

import dmd.arraytypes;
import dmd.astenums;
import dmd.ctfeexpr : emplaceExp, UnionExp;
import dmd.declaration;
import dmd.dstruct;
import dmd.expression;
import dmd.expressionsem : toInteger, toReal;
import dmd.location;
import dmd.mtype;
import dmd.root.array;
import dmd.root.ctfloat : real_t;
import dmd.root.rmem;
import dmd.tokens : EXP;
import dmd.typesem : isIntegral, size, toBasetype;

/// Index into `CtfeMemory.allocs`. Id 0 is reserved as the null allocation.
alias AllocId = uint;

/// Which arena an allocation lives in.
enum ArenaKind : ubyte
{
    stack,      /// per-call frames, released on function return
    heap        /// outlives frames, released when the outermost CTFE call ends
}

/**
 * A CTFE pointer: allocation id plus byte offset. This is the only way
 * interpreted code can refer to linear memory; raw host pointers never
 * escape `CtfeMemory`.
 */
struct CtfePtr
{
    AllocId alloc;
    uint offset;

    bool isNull() const @safe
    {
        return alloc == 0;
    }
}

private struct Allocation
{
    uint base;          // byte offset of the allocation in its arena
    uint size;          // size in bytes
    ArenaKind kind;
    bool live;
}

/// Restores stack arena state on function return, see `CtfeMemory.markStack`.
struct StackMark
{
    private uint top;
    private uint firstAlloc;
}

/**
 * The linear memory of one CTFE execution: a stack arena, a heap arena, and
 * the allocation table that all accesses are validated against.
 */
struct CtfeMemory
{
    private
    {
        ubyte* stackBytes;
        uint stackCap;
        uint stackTop;

        ubyte* heapBytes;
        uint heapCap;
        uint heapTop;

        Array!Allocation allocs;
    }

    /// All allocations are aligned to this many bytes, enough for any scalar.
    enum allocAlign = 16;

    /// Largest single allocation; also bounds arena growth per allocation.
    enum maxAllocSize = 0x4000_0000; // 1 GiB

    /**
     * Allocate `size` zeroed bytes in the given arena.
     * Returns: the new allocation's id, or 0 if `size` exceeds `maxAllocSize`.
     */
    AllocId allocate(ArenaKind kind, uint size)
    {
        if (size > maxAllocSize)
            return 0;
        if (allocs.length == 0)
            allocs.push(Allocation.init); // reserve id 0 as null
        auto bytes = kind == ArenaKind.stack ? &stackBytes : &heapBytes;
        auto cap = kind == ArenaKind.stack ? &stackCap : &heapCap;
        auto top = kind == ArenaKind.stack ? &stackTop : &heapTop;

        const base = (*top + allocAlign - 1) & ~(allocAlign - 1);
        const newTop = base + size;
        if (newTop > *cap)
        {
            uint newCap = *cap ? *cap : 4096;
            while (newCap < newTop)
                newCap *= 2;
            *bytes = cast(ubyte*) mem.xrealloc_noscan(*bytes, newCap);
            *cap = newCap;
        }
        memset(*bytes + base, 0, size);
        *top = newTop;

        const id = cast(AllocId) allocs.length;
        allocs.push(Allocation(base, size, kind, true));
        return id;
    }

    /**
     * Validated access: get `len` bytes at `p`.
     * Returns: the byte slice, or null if `p` is null, dangling, or the
     * access is out of bounds. Callers turn null into a CTFE error.
     */
    ubyte[] slice(CtfePtr p, uint len)
    {
        if (p.alloc == 0 || p.alloc >= allocs.length)
            return null;
        const a = allocs[p.alloc]; // copy, table may be reallocated by callers
        if (!a.live)
            return null;
        if (p.offset > a.size || len > a.size - p.offset)
            return null;
        auto bytes = a.kind == ArenaKind.stack ? stackBytes : heapBytes;
        return bytes[a.base + p.offset .. a.base + p.offset + len];
    }

    /// Typed load. Returns: false (leaving `result` untouched) on invalid access.
    bool read(T)(CtfePtr p, ref T result)
        if (__traits(isArithmetic, T))
    {
        auto s = slice(p, T.sizeof);
        if (s is null)
            return false;
        memcpy(&result, s.ptr, T.sizeof);
        return true;
    }

    /// Typed store. Returns: false on invalid access.
    bool write(T)(CtfePtr p, T value)
        if (__traits(isArithmetic, T))
    {
        auto s = slice(p, T.sizeof);
        if (s is null)
            return false;
        memcpy(s.ptr, &value, T.sizeof);
        return true;
    }

    /// Is `p` a live, in-bounds location?
    bool isValid(CtfePtr p)
    {
        return slice(p, 0) !is null;
    }

    /// Copy `n` bytes between validated locations. Returns: false on invalid access.
    bool copy(CtfePtr dst, CtfePtr src, uint n)
    {
        auto d = slice(dst, n);
        auto s = slice(src, n);
        if (d is null || s is null)
            return false;
        memcpy(d.ptr, s.ptr, n);
        return true;
    }

    /**
     * Try to grow heap allocation `id` to `newSize` bytes in place, which is
     * only possible while it is the arena's most recent heap allocation.
     * The added bytes are zeroed. Returns: false if it cannot grow in place
     * (the caller allocates a fresh payload and copies).
     */
    bool extendInPlace(AllocId id, uint newSize)
    {
        if (id == 0 || id >= allocs.length)
            return false;
        const a = allocs[id];
        if (!a.live || a.kind != ArenaKind.heap)
            return false;
        if (newSize <= a.size)
            return true;
        if (newSize > maxAllocSize)
            return false;
        if (a.base + a.size != heapTop)
            return false; // something was allocated after it
        const newTop = a.base + newSize;
        if (newTop > heapCap)
        {
            uint newCap = heapCap ? heapCap : 4096;
            while (newCap < newTop)
                newCap *= 2;
            heapBytes = cast(ubyte*) mem.xrealloc_noscan(heapBytes, newCap);
            heapCap = newCap;
        }
        memset(heapBytes + heapTop, 0, newTop - heapTop);
        heapTop = newTop;
        allocs[id].size = newSize;
        return true;
    }

    /// Remember the stack arena state at function entry.
    StackMark markStack() const @safe
    {
        return StackMark(stackTop, cast(uint) allocs.length);
    }

    /**
     * Release everything the frame allocated in the stack arena. Heap
     * allocations made during the frame survive.
     *
     * If the frame made no heap allocations, its table entries are popped
     * entirely so the table does not grow with recursion depth; the freed
     * ids may be reused by later allocations, so the interpreter must not
     * keep a `CtfePtr` beyond its frame's release (slot tables are popped in
     * lockstep). Otherwise stack entries are marked dead individually and
     * dangling pointers into the frame are caught on the next access.
     * Host memory safety never depends on this: every access is bounds
     * checked either way.
     */
    void releaseStack(StackMark m)
    {
        bool hasHeap = false;
        foreach (i; m.firstAlloc .. allocs.length)
        {
            if (allocs[i].kind == ArenaKind.heap)
            {
                hasHeap = true;
                break;
            }
        }
        if (!hasHeap)
            allocs.setDim(m.firstAlloc);
        else
            foreach (i; m.firstAlloc .. allocs.length)
            {
                if (allocs[i].kind == ArenaKind.stack)
                    allocs[i].live = false;
            }
        stackTop = m.top;
    }

    /// Release everything; called when the outermost CTFE invocation ends.
    void reset()
    {
        stackTop = 0;
        heapTop = 0;
        allocs.setDim(0);
    }

    /// Free the arenas themselves.
    void destroy()
    {
        mem.xfree(stackBytes);
        mem.xfree(heapBytes);
        stackBytes = null;
        heapBytes = null;
        stackCap = heapCap = stackTop = heapTop = 0;
        allocs = Array!Allocation.init;
    }
}

/* ============================ Slices ==================================== */

/**
 * A dynamic array value as stored in a variable's 16-byte slot. The payload
 * (the elements) lives in the heap arena, prefixed by a `PayloadHeader`;
 * `offset` is relative to the end of the header. `alloc` 0 is the null array.
 *
 * The interpreter currently maintains a sole-handle invariant: each payload
 * is referenced by exactly one handle, which covers the whole object
 * (`offset` right past the header, `length` equal to the header's `used`).
 * Any operation that would create a second reference (loading the variable,
 * slicing it, binding it to a parameter) instead materializes the array as
 * an AST node and abandons the handle ("flip to AST"), so aliasing keeps
 * the same semantics as sharing one array literal node. Sharing payloads
 * between handles (with `payloadShared` copy-on-append and an
 * escaped-payload redirection map) is a planned extension.
 */
struct LinearSlice
{
    AllocId alloc;      // payload allocation, 0 for the null array
    uint offset;        // byte offset of the first element (past the header)
    uint length;        // number of elements
    uint pad;
}
static assert(LinearSlice.sizeof == 16);

/// Self-describing prefix of every slice payload allocation, so the full
/// array object can be rebuilt from any handle into it.
struct PayloadHeader
{
    uint elemSize;      // size of one element in bytes
    uint used;          // number of elements the array object holds
    uint capacity;      // number of elements the allocation has room for
    uint flags;         // combination of payloadShared / payloadEscaped
}
static assert(PayloadHeader.sizeof == 16);

/// More than one handle may point into the payload; appending must copy
/// (matching the AST representation, where `~=` detaches from aliases).
enum payloadShared = 1u;
/// The payload has been materialized as a canonical AST node; handles must
/// be redirected to that node before their next access.
enum payloadEscaped = 2u;

/// Read/write a slice handle stored at `slot`.
bool readSlice(ref CtfeMemory mem, CtfePtr slot, out LinearSlice s)
{
    auto b = mem.slice(slot, LinearSlice.sizeof);
    if (b is null)
        return false;
    memcpy(&s, b.ptr, LinearSlice.sizeof);
    return true;
}

/// ditto
bool writeSlice(ref CtfeMemory mem, CtfePtr slot, LinearSlice s)
{
    auto b = mem.slice(slot, LinearSlice.sizeof);
    if (b is null)
        return false;
    memcpy(b.ptr, &s, LinearSlice.sizeof);
    return true;
}

/// Read the payload header of allocation `alloc`.
bool readPayloadHeader(ref CtfeMemory mem, AllocId alloc, out PayloadHeader h)
{
    auto b = mem.slice(CtfePtr(alloc, 0), PayloadHeader.sizeof);
    if (b is null)
        return false;
    memcpy(&h, b.ptr, PayloadHeader.sizeof);
    return true;
}

/// ditto
bool writePayloadHeader(ref CtfeMemory mem, AllocId alloc, PayloadHeader h)
{
    auto b = mem.slice(CtfePtr(alloc, 0), PayloadHeader.sizeof);
    if (b is null)
        return false;
    memcpy(b.ptr, &h, PayloadHeader.sizeof);
    return true;
}

/**
 * Allocate a slice payload in the heap arena for `used` elements of
 * `elemSize` bytes, with room for `capacity` elements.
 * Returns: handle to the elements, or a null handle on overflow.
 */
LinearSlice allocatePayload(ref CtfeMemory mem, uint elemSize, uint used, uint capacity)
{
    if (capacity < used)
        capacity = used;
    const bytes = ulong(elemSize) * capacity + PayloadHeader.sizeof;
    if (bytes > CtfeMemory.maxAllocSize)
        return LinearSlice.init;
    const id = mem.allocate(ArenaKind.heap, cast(uint) bytes);
    if (id == 0)
        return LinearSlice.init;
    writePayloadHeader(mem, id, PayloadHeader(elemSize, used, capacity));
    return LinearSlice(id, PayloadHeader.sizeof, used);
}

/**
 * Can a value of type `t` be stored as raw bytes in linear memory by the
 * scalar tier? Matches what `encodeInto`/`decodeScalar` support: integrals
 * (including bool, chars, enums) up to 8 bytes and floating point types
 * (excluding imaginary/complex).
 */
bool isLinearScalarType(Type t)
{
    // a ty switch: this is on the per-argument/per-access hot path, and the
    // generic isIntegral()/size() dispatch shows up in profiles
    switch (t.toBasetype().ty)
    {
    case Tbool, Tint8, Tuns8, Tchar, Tint16, Tuns16, Twchar,
         Tint32, Tuns32, Tdchar, Tint64, Tuns64:
        return true;
    case Tfloat32, Tfloat64:
        return true;
    case Tfloat80:
        static if (is(real_t == real))
            return t.toBasetype().size() == real.sizeof; // host real must match target real
        else
            return false;
    default:
        return false;
    }
}

/**
 * Is `t` a struct or union type whose values are plain bytes: linear-typed
 * fields only (scalars, nested POD structs/unions, fixed arrays of those) and
 * no postblit/copy constructor/destructor (the interpreter must run those on
 * element copies)? Overlapping fields are fine: the bytes are the value, so
 * reading any union member just reinterprets them (assumes little endian).
 */
bool isLinearPodStruct(Type t)
{
    auto ts = t.toBasetype().isTypeStruct();
    if (!ts)
        return false;
    auto sd = ts.sym;
    if (sd.sizeok != Sizeok.done)
        return false;
    if (sd.postblit || sd.dtor || sd.hasCopyConstruction())
        return false;
    foreach (field; sd.fields[])
    {
        if (field.isBitFieldDeclaration())
            return false;
        if (!isLinearFieldType(field.type))
            return false;
    }
    return true;
}

/// Can a struct field (or fixed-array element) of type `t` live as raw bytes?
private bool isLinearFieldType(Type t)
{
    if (isLinearScalarType(t) || isLinearPodStruct(t))
        return true;
    if (auto tsa = t.toBasetype().isTypeSArray())
        return isLinearFieldType(tsa.next);
    return false;
}

/// Can elements of type `t` be stored as raw bytes in a slice payload?
bool isLinearElemType(Type t)
{
    return isLinearScalarType(t) || isLinearPodStruct(t);
}

/// Is `t` a dynamic array type whose values can be linear slice handles?
bool isLinearSliceType(Type t)
{
    auto ta = t.toBasetype().isTypeDArray();
    if (!ta)
        return false;
    const esz = ta.next.size();
    if (esz == SIZE_INVALID || esz == 0 || esz > CtfeMemory.maxAllocSize)
        return false;
    return isLinearElemType(ta.next);
}

/**
 * Serialize a dynamic array value `e` (null, string or array literal, with
 * elements resolved) of type `t` into a fresh payload in the heap arena.
 *
 * To preserve read-only semantics, literals not owned by CTFE are only
 * copied for immutable/const element types; a mutable view of a code
 * literal must keep the AST representation so that write attempts still
 * error.
 *
 * Returns: false if unsupported (caller keeps the AST node).
 */
bool encodeSlice(ref CtfeMemory mem, Expression e, Type t, out LinearSlice s)
{
    auto ta = t.toBasetype().isTypeDArray();
    if (!ta)
        return false;
    auto telem = ta.next;
    const eszl = telem.size();
    if (eszl == SIZE_INVALID || eszl == 0)
        return false;
    const esz = cast(uint) eszl;
    const elemMutable = telem.isMutable();

    switch (e.op)
    {
    case EXP.null_:
        s = LinearSlice.init;
        return true;

    case EXP.string_:
        auto se = e.isStringExp();
        if (se.sz != esz)
            return false;
        if (elemMutable && se.ownedByCtfe == OwnedBy.code)
            return false; // keep read-only diagnostics
        const n = cast(uint) se.len;
        s = allocatePayload(mem, esz, n, n);
        if (s.alloc == 0)
            return false;
        auto b = mem.slice(CtfePtr(s.alloc, s.offset), n * esz);
        if (b is null)
            return false;
        se.writeTo(b.ptr, false);
        return true;

    case EXP.arrayLiteral:
        auto ale = e.isArrayLiteralExp();
        if (elemMutable && ale.ownedByCtfe == OwnedBy.code)
            return false;
        const n = cast(uint)(ale.elements ? ale.elements.length : 0);
        s = allocatePayload(mem, esz, n, n);
        if (s.alloc == 0)
            return false;
        foreach (i; 0 .. n)
        {
            Expression el = (*ale.elements)[i];
            if (el is null)
                el = ale.basis;
            if (el is null ||
                !encodeInto(mem, el, telem, CtfePtr(s.alloc, s.offset + i * esz)))
                return false;
        }
        return true;

    default:
        return false;
    }
}

/**
 * Materialize an AST node for the elements `[s.offset, s.offset+s.length)`
 * of a slice handle of dynamic array type `t`. The result is a fresh
 * CTFE-owned literal (or NullExp for the null handle).
 *
 * Returns: null on invalid access or unsupported element type.
 */
Expression decodeSlice(ref CtfeMemory mem, LinearSlice s, Type t, Loc loc)
{
    auto ta = t.toBasetype().isTypeDArray();
    if (!ta)
        return null;
    if (s.alloc == 0)
    {
        auto ne = new NullExp(loc, t);
        return ne;
    }
    auto telem = ta.next;
    auto telemb = telem.toBasetype();
    const eszl = telem.size();
    if (eszl == SIZE_INVALID || eszl == 0)
        return null;
    const esz = cast(uint) eszl;

    if (telemb.ty == Tchar || telemb.ty == Twchar || telemb.ty == Tdchar)
    {
        const total = s.length * esz;
        auto b = mem.slice(CtfePtr(s.alloc, s.offset), total);
        if (b is null)
            return null;
        auto buf = cast(ubyte*) dmd.root.rmem.mem.xmalloc_noscan(total + esz);
        memcpy(buf, b.ptr, total);
        memset(buf + total, 0, esz); // zero terminator, as StringExp expects
        auto se = new StringExp(loc, buf[0 .. total], s.length, cast(ubyte) esz);
        se.type = t;
        se.ownedByCtfe = OwnedBy.ctfe;
        return se;
    }

    auto elements = new Expressions(s.length);
    foreach (i; 0 .. s.length)
    {
        auto el = decode(mem, CtfePtr(s.alloc, s.offset + cast(uint) i * esz), telem, loc);
        if (el is null)
            return null;
        (*elements)[i] = el;
    }
    auto ale = new ArrayLiteralExp(loc, t, elements);
    ale.ownedByCtfe = OwnedBy.ctfe;
    return ale;
}

/**
 * Serialize literal expression `e` of type `t` into a fresh allocation.
 *
 * Supported: integrals (including bool, chars, enums), floats, struct
 * literals, static arrays, string literals of static array type. Anything
 * else (reference types, dynamic arrays — later phases) fails, and the
 * caller falls back to the AST-node representation.
 *
 * Returns: pointer to the value, or a null `CtfePtr` if unsupported.
 */
CtfePtr encode(ref CtfeMemory mem, Expression e, Type t, ArenaKind kind)
{
    const sz = t.size();
    if (sz == SIZE_INVALID || sz > CtfeMemory.maxAllocSize)
        return CtfePtr.init;
    const id = mem.allocate(kind, cast(uint) sz);
    if (id == 0)
        return CtfePtr.init;
    const p = CtfePtr(id, 0);
    // on failure the bytes are wasted, but arenas are released wholesale
    return encodeInto(mem, e, t, p) ? p : CtfePtr.init;
}

/// Serialize `e` at an existing location (e.g. a struct field). Returns: false if unsupported.
bool encodeInto(ref CtfeMemory mem, Expression e, Type t, CtfePtr dest)
{
    auto tb = t.toBasetype();
    switch (e.op)
    {
    case EXP.int64:
        if (!tb.isIntegral())
            return false;
        const isz = cast(uint) tb.size();
        if (isz > 8) // cent/ucent: not yet
            return false;
        const val = e.toInteger();
        auto s = mem.slice(dest, isz);
        if (s is null)
            return false;
        memcpy(s.ptr, &val, isz); // little endian: low-order bytes
        return true;

    case EXP.float64:
        const r = e.toReal();
        switch (tb.ty)
        {
        case Tfloat32:
            return mem.write(dest, cast(float) r);
        case Tfloat64:
            return mem.write(dest, cast(double) r);
        case Tfloat80:
            static if (is(real_t == real))
            {
                const rsz = cast(uint) tb.size();
                if (rsz != real.sizeof) // host real must match target real
                    return false;
                auto s = mem.slice(dest, rsz);
                if (s is null)
                    return false;
                const real hr = r;
                memcpy(s.ptr, &hr, rsz);
                return true;
            }
            else
                return false;
        default:
            return false;
        }

    case EXP.structLiteral:
        auto sle = e.isStructLiteralExp();
        auto sd = sle.sd;
        if (sd.type.toBasetype() !is tb && sle.stype && sle.stype.toBasetype() !is tb)
            return false;
        {
            // padding and union holes are readable through a larger
            // overlapping member, so define them as zero up front
            const total = cast(uint) tb.size();
            auto whole = mem.slice(dest, total);
            if (whole is null)
                return false;
            memset(whole.ptr, 0, total);
        }
        foreach (i, field; sd.fields[])
        {
            // null/void entries are skipped fields (e.g. shadowed union members);
            // their bytes stay zeroed or get overwritten by an overlapping field
            Expression el = sle.elements && i < sle.elements.length ? (*sle.elements)[i] : null;
            if (el is null || el.isVoidInitExp())
                continue;
            if (!encodeInto(mem, el, field.type, CtfePtr(dest.alloc, dest.offset + field.offset)))
                return false;
        }
        return true;

    case EXP.arrayLiteral:
        auto tsa = tb.isTypeSArray();
        if (!tsa) // dynamic arrays are a later phase
            return false;
        auto ale = e.isArrayLiteralExp();
        const dim = cast(size_t) tsa.dim.toInteger();
        auto telem = tsa.next;
        const esz = telem.size();
        if (esz == SIZE_INVALID)
            return false;
        foreach (i; 0 .. dim)
        {
            Expression el = ale.elements && i < ale.elements.length ? (*ale.elements)[i] : null;
            if (el is null)
                el = ale.basis;
            if (el is null)
                return false;
            if (!encodeInto(mem, el, telem, CtfePtr(dest.alloc, cast(uint)(dest.offset + i * esz))))
                return false;
        }
        return true;

    case EXP.string_:
        auto tsa = tb.isTypeSArray();
        if (!tsa)
            return false;
        auto se = e.isStringExp();
        const total = cast(uint) tb.size();
        const n = se.len * se.sz;
        if (n > total)
            return false;
        auto s = mem.slice(dest, total);
        if (s is null)
            return false;
        se.writeTo(s.ptr, false);
        return true;

    default:
        return false;
    }
}

/**
 * Rebuild a scalar literal of type `t` from the value at `p`, in caller
 * storage `*pue` — no heap allocation.
 *
 * Intermediate values carry no source location; `loc` is stamped on the
 * result.
 *
 * Returns: the expression (in `*pue`), or null if `t` is not a supported
 * scalar type or the access is invalid.
 */
Expression decodeScalar(ref CtfeMemory mem, CtfePtr p, Type t, Loc loc, UnionExp* pue)
{
    auto tb = t.toBasetype();

    if (tb.isIntegral())
    {
        const sz = cast(uint) tb.size();
        if (sz > 8)
            return null;
        auto s = mem.slice(p, sz);
        if (s is null)
            return null;
        ulong val = 0;
        memcpy(&val, s.ptr, sz); // zero-extend; IntegerExp normalizes signedness
        emplaceExp!IntegerExp(pue, loc, val, t);
        return pue.exp();
    }

    switch (tb.ty)
    {
    case Tfloat32:
        float f;
        if (!mem.read(p, f))
            return null;
        emplaceExp!RealExp(pue, loc, real_t(f), t);
        return pue.exp();
    case Tfloat64:
        double d;
        if (!mem.read(p, d))
            return null;
        emplaceExp!RealExp(pue, loc, real_t(d), t);
        return pue.exp();
    case Tfloat80:
        static if (is(real_t == real))
        {
            const rsz = cast(uint) tb.size();
            if (rsz != real.sizeof)
                return null;
            auto s = mem.slice(p, rsz);
            if (s is null)
                return null;
            real hr;
            memcpy(&hr, s.ptr, rsz);
            emplaceExp!RealExp(pue, loc, hr, t);
            return pue.exp();
        }
        else
            return null;
    default:
        return null;
    }
}

/**
 * Rebuild a literal expression of type `t` from the value at `p`.
 *
 * Intermediate values carry no source location; `loc` (normally the CTFE
 * call site) is stamped on the result.
 *
 * Returns: the expression, or null if the type is unsupported or the
 * access is invalid.
 */
Expression decode(ref CtfeMemory mem, CtfePtr p, Type t, Loc loc)
{
    auto tb = t.toBasetype();

    {
        UnionExp ue = void;
        if (auto e = decodeScalar(mem, p, t, loc, &ue))
            return e == ue.exp() ? ue.copy() : e;
    }

    if (auto ts = tb.isTypeStruct())
    {
        auto sd = ts.sym;
        auto elements = new Expressions(sd.fields.length);
        foreach (i, field; sd.fields[])
        {
            auto el = decode(mem, CtfePtr(p.alloc, p.offset + field.offset), field.type, loc);
            if (el is null)
                return null;
            (*elements)[i] = el;
        }
        auto sle = new StructLiteralExp(loc, sd, elements, t);
        sle.type = t; // the constructor only sets the requested type `stype`
        sle.ownedByCtfe = OwnedBy.ctfe;
        return sle;
    }

    if (auto tsa = tb.isTypeSArray())
    {
        auto telem = tsa.next;
        auto telemb = telem.toBasetype();
        const dim = cast(size_t) tsa.dim.toInteger();

        if (telemb.ty == Tchar || telemb.ty == Twchar || telemb.ty == Tdchar)
        {
            const esz = cast(ubyte) telemb.size();
            const total = cast(uint)(dim * esz);
            auto s = mem.slice(p, total);
            if (s is null)
                return null;
            auto buf = cast(ubyte*) dmd.root.rmem.mem.xmalloc_noscan(total);
            memcpy(buf, s.ptr, total);
            auto se = new StringExp(loc, buf[0 .. total], dim, esz);
            se.type = t;
            se.ownedByCtfe = OwnedBy.ctfe;
            return se;
        }

        const esz = telem.size();
        if (esz == SIZE_INVALID)
            return null;
        auto elements = new Expressions(dim);
        foreach (i; 0 .. dim)
        {
            auto el = decode(mem, CtfePtr(p.alloc, cast(uint)(p.offset + i * esz)), telem, loc);
            if (el is null)
                return null;
            (*elements)[i] = el;
        }
        auto ale = new ArrayLiteralExp(loc, t, elements);
        ale.ownedByCtfe = OwnedBy.ctfe;
        return ale;
    }

    // pointers, dynamic arrays, classes, delegates, AAs: later phases
    return null;
}

///
unittest
{
    CtfeMemory mem;
    scope (exit) mem.destroy();

    // round trip
    const a = mem.allocate(ArenaKind.stack, 12);
    assert(a != 0);
    assert(mem.write(CtfePtr(a, 0), 0x1122_3344U));
    assert(mem.write(CtfePtr(a, 4), 3.5f));
    uint u;
    float f;
    assert(mem.read(CtfePtr(a, 0), u) && u == 0x1122_3344U);
    assert(mem.read(CtfePtr(a, 4), f) && f == 3.5f);

    // allocations are zeroed and aligned
    ulong zero = 0xAA;
    const b = mem.allocate(ArenaKind.heap, 8);
    assert(mem.read(CtfePtr(b, 0), zero) && zero == 0);

    // out of bounds: offset + size crosses the end, or offset past the end
    assert(!mem.write(CtfePtr(a, 9), 0x1234U));
    assert(!mem.read(CtfePtr(a, 0xFFFF_FFFF), u)); // offset overflow attempt
    assert(mem.write(CtfePtr(a, 8), 0x1234U));     // last valid uint slot

    // null and bogus ids
    assert(!mem.read(CtfePtr(0, 0), u));
    assert(!mem.read(CtfePtr(9999, 0), u));
}

unittest
{
    CtfeMemory mem;
    scope (exit) mem.destroy();

    const outer = mem.allocate(ArenaKind.stack, 4);
    const m = mem.markStack();
    const local = mem.allocate(ArenaKind.stack, 4);
    const escapee = mem.allocate(ArenaKind.heap, 4);
    assert(mem.write(CtfePtr(local, 0), 7));
    assert(mem.write(CtfePtr(escapee, 0), 8));

    mem.releaseStack(m);

    int v;
    assert(!mem.read(CtfePtr(local, 0), v));          // dangling: caught
    assert(mem.read(CtfePtr(escapee, 0), v) && v == 8); // heap survives
    assert(mem.write(CtfePtr(outer, 0), 9));            // outer frame intact

    // stack bytes are reused after release, but stale ids stay dead
    const local2 = mem.allocate(ArenaKind.stack, 4);
    assert(mem.write(CtfePtr(local2, 0), 10));
    assert(!mem.read(CtfePtr(local, 0), v));

    mem.reset();
    assert(!mem.read(CtfePtr(outer, 0), v));
}

unittest
{
    CtfeMemory mem;
    scope (exit) mem.destroy();

    // a frame with only stack allocations is popped from the table entirely
    const m = mem.markStack();
    const tmp = mem.allocate(ArenaKind.stack, 8);
    assert(mem.write(CtfePtr(tmp, 0), 1));
    mem.releaseStack(m);
    int v;
    assert(!mem.read(CtfePtr(tmp, 0), v)); // id past the end: caught

    // the id may be reused by a later allocation
    const tmp2 = mem.allocate(ArenaKind.stack, 8);
    assert(mem.isValid(CtfePtr(tmp2, 0)));
    assert(!mem.isValid(CtfePtr(tmp2, 9)));
    assert(!mem.isValid(CtfePtr.init));
}
