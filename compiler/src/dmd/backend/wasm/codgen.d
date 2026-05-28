/**
 * WebAssembly code generator.
 *
 * Translates DMD IR (elem trees + block CFG) to WebAssembly bytecode.
 * Called from dout.d when OBJ_WASM is the target object format.
 *
 * Design notes:
 * - WASM is a typed stack machine with structured control flow.
 * - Parameters and locals are indexed starting at 0.
 * - Results are left on the value stack.
 * - Structured control flow: block/loop/if...end (no arbitrary goto).
 *   Unstructured gotos in the IR are handled by wrapping blocks and
 *   using br_table for switches; truly irreducible CFG falls back to a
 *   block-index dispatch loop (Relooper / Stackifier not yet implemented —
 *   those blocks emit unreachable for now).
 */

module dmd.backend.wasm.codgen;

import std.stdio;
import std.string;
import dmd.backend.debugprint;

import dmd.backend.cc;
import dmd.backend.cdef;
import dmd.backend.el;
import dmd.backend.oper;
import dmd.backend.ty;
import dmd.backend.type;
import dmd.backend.var : globsym;
import dmd.backend.wasm.enums;
import dmd.backend.wasm.util : writeuLEB128_5;
import dmd.backend.wasm.obj;
import dmd.backend.wasm.blocks;

import dmd.common.outbuffer;

nothrow:

/// Returns: WASM type for element `e`
WASM_TYPE wasmType(elem* e)
{
    return wasmType(tybasic(e.Ety));
}

/// Returns: WASM type for backend `ty`
WASM_TYPE wasmType(tym_t ty)
{
    switch (tybasic(ty))
    {
    case TYbool:
    case TYchar:
    case TYschar:
    case TYuchar:
    case TYchar8:
    case TYchar16:
    case TYshort:
    case TYwchar_t:
    case TYushort:
    case TYenum:
    case TYint:
    case TYuint:
    case TYlong:
    case TYulong:
    case TYdchar:
        return WASM_I32;

    case TYnptr:
    case TYptr:
    case TYnullptr:
    case TYref:
    case TYnref:
    case TYsptr:
    case TYcptr:
    case TYf16ptr:
    case TYfptr:
    case TYhptr:
    case TYvptr:
    case TYfgPtr:
    case TYsharePtr:
    case TYimmutPtr:
        return WASM_I32; // I64 for 64-bit

    case TYllong:
    case TYullong:
    case TYcent:
    case TYucent:
        return WASM_I64;

    case TYfloat:
    case TYifloat:
        return WASM_F32;

    case TYdouble:
    case TYdouble_alias:
    case TYidouble:
    case TYreal:
    case TYireal:
        return WASM_F64;

    case TYnoreturn:
        // Noreturn never produces a real value; return i32 as a benign
        // placeholder. Callers that actually consume the value follow
        // OP_UNREACHABLE so this is unused at runtime.
        return WASM_I32;

    default:
        try {
            writeln("ty = ", tym_str(ty).fromStringz, ", tybasic = ", tybasic(ty));
        } catch (Exception e) {}
        assert(0);
        // return WASM_I32; // aggregate / unknown: pass by pointer
    }
}

/// Duplicated: also in dvarstats.d
bool isParameter(Symbol* s)
{
    const sc = s.Sclass;
    return sc == SC.parameter || sc == SC.regpar || sc == SC.fastpar || sc == SC.shadowreg;
}

/// Returns: true if `ty` represents a real value (i.e. NOT void or noreturn).
bool typeHasValue(tym_t ty)
{
    return tybasic(ty) != TYvoid && tybasic(ty) != TYnoreturn;
}

/// Per-call scope used during OPparam tree traversal. The genElem recursion
/// over OPparam consumes one arg per leaf, advancing `nextParam` along the
/// callee's declared param list. Args past the declared list are queued in
/// `varArgs` when the callee is C-variadic (spilled to the shadow frame
/// after the recursion completes).
struct CallCtx
{
    param_t[] remainingParams;  /// remaining declared params (empty when out of declared)
    uint skipCount;             /// number of ABI-prepended leaves (hidden ret ptr, ethis,
                                /// nested-link) consumed before remainingParams advances
    bool isCVariadic;           /// true when callee takes `...`
    elem*[] varArgs;            /// args collected for the variadic shadow-frame spill
}

/// Per-function code-generation state
struct WasmCG
{
    OutBuffer code; /// bytecode being emitted
    WasmLocal[] locals; /// local variable table (params first)
    uint numParams; /// number of parameters (= first numParams locals)
    WasmFuncBody.CodeReloc[] codeRelocs; /// relocations for direct function calls
    WasmFuncBody.DataAddrReloc[] dataAddrRelocs; /// R_WASM.MEMORY_ADDR_LEB relocations

    // Shadow stack frame
    bool hasShadowFrame;

    uint shadowBaseLocal; /// WASM local index holding the shadow frame base address
    uint shadowFrameSize; /// total size in bytes of shadow frame
    Symbol*[] shadowEntries; /// per-symbol shadow frame offsets

    /// Function return: true when this function returns via a hidden pointer
    /// (struct/array/slice/delegate). Set during wasm_codgen2 init so retexp
    /// emission can pick the right local type for the saved return value.
    bool retByHiddenPtr;

    /// Scope for an in-progress call. Pushed on entry to genCall, popped on exit.
    /// Leaves of the OPparam tree consult the top of the stack to decide how to
    /// emit themselves (split slice into two i32s, queue as variadic, plain emit).
    CallCtx[] callCtxStack;

nothrow:

    /// Index of global used for __stack_pointer
    auto stackPtrGlobal() => 0;

    /// Returns: function type index for `x`
    auto internType(WasmFuncType x) => wmod_internType(x);

    /// Allocate an anonymous temp local of the given WASM type
    ///
    /// Returns: index of allocated temp in `locals` array
    uint allocTemp(WASM_TYPE ty)
    {
        const uint result = cast(uint) locals.length;
        locals ~= WasmLocal(ty);
        return result;
    }

    /// Allocate or look up a local for a symbol
    ///
    /// Returns: its index
    uint localFor(Symbol* s)
    {
        foreach (size_t i, ref const WasmLocal l; locals)
            if (l.sym == s)
                return cast(uint) i;

        const uint result = cast(uint) locals.length;
        locals ~= WasmLocal(s);
        return result;
    }

    /// Returns: true if symbol `s` lives in the shadow frame.
    static bool inShadow(Symbol* s) { return (s.Sflags & SFLwasmshadow) != 0; }

    /// Register a symbol in the shadow frame (idempotent).
    void registerShadow(Symbol* s)
    {
        if (inShadow(s))
            return;

        assert(s.Stype);
        const uint sz = cast(uint) type_size(s.Stype);
        const uint al = Symbol_Salignsize(*s);
        const uint off = (shadowFrameSize + al - 1) & ~(al - 1);
        s.Soffset = off;
        s.Sflags |= SFLwasmshadow;
        shadowEntries ~= s;
        shadowFrameSize = off + sz;
    }

    void emit(ubyte b)
    {
        code.writeByte(b);
    }

    void emitULEB(uint v)
    {
        code.writeuLEB128(v);
    }

    void emitSLEB(long v)
    {
        code.writesLEB128(v);
    }

    /// Write constant value `v`
    void emitConst(WASM_OP op, long v)
    {
        emit(op);
        emitSLEB(v);
    }

    /// Access local at index `v`
    void emitLocal(WASM_OP op, long v)
    {
        emit(op);
        emitULEB(cast(uint) v);
    }

    /// 5-byte padded ULEB128 so wasm-ld has room to write a patched value over it
    void emitULEBpadded(uint addr)
    {
        code.writeuLEB128_5(addr);
    }

    // Emit OP_I32_CONST with a data-segment address.
    // Emits a 5-byte padded ULEB128 and records a R_WASM.MEMORY_ADDR_LEB
    // relocation so wasm-ld patches the address after moving the data section
    // to its final location.
    void emitDataAddr(Symbol* sym, uint addend)
    {
        emit(OP_I32_CONST);
        const uint addr = cast(uint)(sym.Soffset + addend);

        // Only relocate symbols in the INITIALIZED data section (FL.data,
        // FL.csdata, FL.datseg). BSS (FL.udata) and TLS (FL.tlsdata) have
        // offsets beyond the active data segment and don't map to valid
        // WASM_SYMTAB.DATA entries in it.
        const bool canRelocate = sym.Sident.ptr != null &&
            sym.Sfl != FL.udata && sym.Sfl != FL.tlsdata;
        if (canRelocate)
        {
            dataAddrRelocs ~= WasmFuncBody.DataAddrReloc(cast(uint) code.length, sym, addend);
            emitULEBpadded(addr);
        }
        else
        {
            emitSLEB(cast(int) addr);
        }
    }

    // Variant of emitDataAddr that records the relocation with addend=0 and
    // leaves the constant offset for the caller to fold into the memarg of a
    // following load/store. Matches LDC's pattern of `i32.const sym;
    // i32.load offset=N` rather than `i32.const sym+N; i32.add; i32.load`.
    void emitDataBase(Symbol* sym)
    {
        emit(OP_I32_CONST);
        const bool canRelocate = sym.Sident.ptr != null &&
            sym.Sfl != FL.udata && sym.Sfl != FL.tlsdata;
        if (canRelocate)
        {
            dataAddrRelocs ~= WasmFuncBody.DataAddrReloc(cast(uint) code.length, sym, 0);
            emitULEBpadded(cast(uint) sym.Soffset);
        }
        else
        {
            emitSLEB(cast(int) sym.Soffset);
        }
    }

    // Emit OP_CALL with a 5-byte padded ULEB128 function index and record a
    // R_WASM.FUNCTION_INDEX_LEB relocation so wasm-ld can patch the index.
    // Symbol* is recorded so that if wmod.funcs is reordered before term time
    // (e.g. additional imports inserted), the relocation still resolves to the
    // intended symbol rather than a stale funcIdx.
    void emitCall(uint fidx, Symbol* sym = null)
    {
        emit(OP_CALL);
        codeRelocs ~= WasmFuncBody.CodeReloc(cast(uint) code.length, R_WASM.FUNCTION_INDEX_LEB, fidx, 0, sym);
        emitULEBpadded(fidx);
    }

    // Emit OP_I32_CONST with a function-table index, recording a
    // R_WASM.TABLE_INDEX_SLEB relocation so wasm-ld patches the value to the
    // function's runtime table slot after linker-side table layout is decided.
    // Used for taking the address of a function (function pointer).
    void emitTableIndex(uint fidx, Symbol* sym)
    {
        emit(OP_I32_CONST);
        codeRelocs ~= WasmFuncBody.CodeReloc(cast(uint) code.length, R_WASM.TABLE_INDEX_SLEB, fidx, 0, sym);
        emitULEBpadded(fidx);
    }

    // Emit the type index operand of call_indirect.
    // Emits R_WASM.TYPE_INDEX_LEB with the local typeIdx as its symIdx —
    // wasm-ld remaps local type indices to the merged type table at link time
    // (no function-symbol anchor needed; the reloc target is the type-section
    // index directly).
    void emitCallIndirectType(uint typeIdx)
    {
        codeRelocs ~= WasmFuncBody.CodeReloc(cast(uint) code.length,
            R_WASM.TYPE_INDEX_LEB, typeIdx);
        // 5-byte padded ULEB128 so wasm-ld has room to write the patched index.
        emitULEBpadded(typeIdx);
    }

    void emitMemArg(uint align_, uint offset)
    {
        code.writeuLEB128(align_); // alignment (log2)
        code.writeuLEB128(offset); // byte offset
    }
}

// Emit a typed load from the address already on the stack.
// Per-type (load opcode, store opcode, natural-alignment log2).
// Load variants of narrow ints carry their signedness; stores share one op.
private struct MemOps
{
    ubyte loadOp;
    ubyte storeOp;
    ubyte alignLog2;
}

private MemOps memOpsFor(tym_t ty) @safe
{
    switch (tybasic(ty))
    {
    case TYllong, TYullong:
        return MemOps(OP_I64_LOAD, OP_I64_STORE, 3);
    case TYfloat, TYifloat:
        return MemOps(OP_F32_LOAD, OP_F32_STORE, 2);
    case TYdouble, TYdouble_alias, TYreal, TYireal:
        return MemOps(OP_F64_LOAD, OP_F64_STORE, 3);
    case TYchar, TYschar:
        return MemOps(OP_I32_LOAD8_S, OP_I32_STORE8, 0);
    case TYuchar, TYbool:
        return MemOps(OP_I32_LOAD8_U, OP_I32_STORE8, 0);
    case TYshort:
        return MemOps(OP_I32_LOAD16_S, OP_I32_STORE16, 1);
    case TYwchar_t, TYushort:
        return MemOps(OP_I32_LOAD16_U, OP_I32_STORE16, 1);
    default:
        return MemOps(OP_I32_LOAD, OP_I32_STORE, 2);
    }
}

/// Emit `memory.copy 0 0`
private void emitMemoryCopy(ref WasmCG cg)
{
    cg.emit(OP_FC_PREFIX);
    cg.emitULEB(10); // memory.copy sub-opcode
    cg.emit(0x00); // dst memidx
    cg.emit(0x00); // src memidx
}

/// Emit `memory.fill 0`
private void emitMemoryFill(ref WasmCG cg)
{
    cg.emit(OP_FC_PREFIX);
    cg.emitULEB(11); // memory.fill sub-opcode
    cg.emit(0x00); // memidx
}

private void emitLoad(ref WasmCG cg, tym_t ty, uint offset = 0)
{
    const m = memOpsFor(ty);
    cg.emit(m.loadOp);
    cg.emitMemArg(m.alignLog2, offset);
}

// Emit a typed store (address then value already on stack).
private void emitStore(ref WasmCG cg, tym_t ty, uint offset = 0)
{
    const m = memOpsFor(ty);
    cg.emit(m.storeOp);
    cg.emitMemArg(m.alignLog2, offset);
}

private void emitReinterpret(ref WasmCG cg, WASM_TYPE from, WASM_TYPE to)
{
    // F32 <-> I64 (bit-pun cases like *cast(long*)&y) need two ops; emit
    // them inline before the single-op lookup below.
    if (from == WASM_F32 && to == WASM_I64)
    {
        cg.emit(OP_I32_REINTERPRET_F32);
        cg.emit(OP_I64_EXTEND_I32_U);
        return;
    }
    if (from == WASM_I64 && to == WASM_F32)
    {
        cg.emit(OP_I32_WRAP_I64);
        cg.emit(OP_F32_REINTERPRET_I32);
        return;
    }
}

// Emit a type coercion when a value's actual WASM type differs from what e.Ety expects.
// This handles cases where the optimizer elides explicit cast operators.
private void emitCoerce(ref WasmCG cg, WASM_TYPE from, WASM_TYPE to)
{
    if (from == to)
        return;

    // F32 <-> I64 (bit-pun cases like *cast(long*)&y) need two ops; emit
    // them inline before the single-op lookup below.
    if (from == WASM_F32 && to == WASM_I64)
    {
        cg.emit(OP_I32_REINTERPRET_F32);
        cg.emit(OP_I64_EXTEND_I32_U);
        return;
    }
    if (from == WASM_I64 && to == WASM_F32)
    {
        cg.emit(OP_I32_WRAP_I64);
        cg.emit(OP_F32_REINTERPRET_I32);
        return;
    }

    static ubyte coerceOp(WASM_TYPE from, WASM_TYPE to)
    {
        debug writeln(from, to);
        static int X(WASM_TYPE from, WASM_TYPE to) { return from << 8 | to; }

        switch (X(from, to))
        {
            case X(WASM_I64, WASM_I32): return OP_I32_WRAP_I64;
            case X(WASM_I32, WASM_I64): return OP_I64_EXTEND_I32_S;
            case X(WASM_F32, WASM_F64): return OP_F64_PROMOTE_F32;
            case X(WASM_F64, WASM_F32): return OP_F32_DEMOTE_F64;
            case X(WASM_I32, WASM_F32): return OP_F32_CONVERT_I32_S;
            case X(WASM_I32, WASM_F64): return OP_F64_CONVERT_I32_S;
            case X(WASM_I64, WASM_F64): return OP_F64_CONVERT_I64_S;
            case X(WASM_F32, WASM_I32): return OP_I32_TRUNC_F32_S;
            case X(WASM_F64, WASM_I32): return OP_I32_TRUNC_F64_S;
            case X(WASM_F64, WASM_I64): return OP_I64_TRUNC_F64_S;
            default: assert(0);
        }
    }

    if (auto op = coerceOp(from, to))
    {
        cg.emit(op);
    }
}

/// Returns: true if a storage class indicates a global living in linear memory
private bool isDataSym(FL fl) @safe @nogc nothrow
{
    switch (fl)
    {
    case FL.data:
    case FL.tlsdata:
    case FL.udata:
    case FL.extern_:
    case FL.csdata:
    case FL.datseg:
        return true;
    default:
        return false;
    }
}

/// Returns: true if a symbol's storage class means it needs a WASM local (not global mem).
private bool isLocalSym(Symbol* s)
{
    return !isDataSym(s.Sfl) && s.Sfl != FL.func;
}

private void scanShadow(elem* e, ref WasmCG cg)
{
    if (!e)
        return;
    const op = e.Eoper;
    if (OTleaf(op))
    {
        if (op == OPrelconst && e.Vsym && isLocalSym(e.Vsym))
            cg.registerShadow(e.Vsym);
        return;
    }
    if (OTunary(op))
    {
        if (op == OPaddr && e.E1 && e.E1.Eoper == OPvar && e.E1.Vsym && isLocalSym(e.E1.Vsym))
            cg.registerShadow(e.E1.Vsym);
        scanShadow(e.E1, cg);
        return;
    }
    scanShadow(e.E1, cg);
    scanShadow(e.E2, cg);
}

/// Emit address of a shadow-frame symbol onto the value stack: local.get $base; i32.const offset; i32.add
void emitShadowAddr(ref WasmCG cg, Symbol* s)
{
    cg.emitLocal(OP_LOCAL_GET, cg.shadowBaseLocal);
    if (s.Soffset != 0)
    {
        cg.emitConst(OP_I32_CONST, cast(int) s.Soffset);
        cg.emit(OP_I32_ADD);
    }
}

/// Push the linear-memory address of `s + off` on the value stack.
/// Handles globals (FL.data, .csdata, .tlsdata, .udata, .datseg, .extern_)
/// and shadow-frame locals uniformly.
/// Returns: true if `s` is addressable through linear memory. Functions
/// (FL.func) return false — their "address" is a table index, not a memory
/// address, so callers handle them separately.
bool emitSymAddr(ref WasmCG cg, Symbol* s, uint off)
{
    if (isDataSym(s.Sfl))
    {
        cg.emitDataAddr(s, off);
        return true;
    }
    if (cg.inShadow(s))
    {
        cg.emitShadowAddr(s);
        if (off != 0)
        {
            cg.emitConst(OP_I32_CONST, cast(int) off);
            cg.emit(OP_I32_ADD);
        }
        return true;
    }
    return false;
}

/// Split form of `emitSymAddr`: pushes only the base address and returns the
/// residual constant offset that the caller must fold into the memarg of a
/// following load/store. Used to match LDC's `i32.const sym; i32.load offset=N`
/// pattern instead of materializing the full address with `i32.add`.
bool emitSymBase(ref WasmCG cg, Symbol* s, uint off, out uint memOff)
{
    if (isDataSym(s.Sfl))
    {
        cg.emitDataBase(s);
        memOff = off;
        return true;
    }
    if (cg.inShadow(s))
    {
        cg.emitLocal(OP_LOCAL_GET, cg.shadowBaseLocal);
        memOff = cast(uint) s.Soffset + off;
        return true;
    }
    return false;
}

/// Emit `<addr> ; load.ty` for the symbol value at `s + off`.
/// Returns: true on success.
bool emitSymLoad(ref WasmCG cg, Symbol* s, uint off, tym_t ty)
{
    uint memOff;
    if (!emitSymBase(cg, s, off, memOff))
        return false;
    cg.emitLoad(ty, memOff);
    return true;
}

/// Push the linear-memory address of an lvalue elem on the value stack.
/// Handles OPvar (memory-backed via emitSymAddr) and OPind (recurse on E1).
/// Returns: true on success. False means the lvalue has no memory address
/// (e.g. an OPvar referring to a WASM local), and callers must fall back.
bool emitLValueAddr(ref WasmCG cg, elem* e)
{
    if (!e)
        return false;
    switch (e.Eoper)
    {
    case OPvar:
        return e.Vsym && emitSymAddr(cg, e.Vsym, cast(uint) e.Voffset);
    case OPind:
        cg.genElem(e.E1);
        return true;
    case OPcomma:
        //
    default:
        return false;
    }
}

/// Split form of `emitLValueAddr`: pushes only the base address and returns
/// the residual constant offset for the caller to fold into the memarg of the
/// following load/store.
bool emitLValueBase(ref WasmCG cg, elem* e, out uint memOff)
{
    if (!e)
        return false;
    switch (e.Eoper)
    {
    case OPvar:
        return e.Vsym && emitSymBase(cg, e.Vsym, cast(uint) e.Voffset, memOff);
    case OPind:
        cg.genElem(e.E1);
        memOff = 0;
        return true;
    default:
        return false;
    }
}

/// A captured lvalue address that can be re-pushed onto the value stack
/// multiple times. For OPvar the address is re-emitted from the symbol
/// (cheap and side-effect free); for OPind the address expression is
/// evaluated once and stashed in an i32 temp.
struct SavedLValue
{
    Symbol* directSym;  /// OPvar: the symbol; null otherwise
    uint directOff;     /// OPvar: byte offset
    uint addrTemp;      /// non-OPvar: temp i32 local index holding the addr
}

/// Evaluate `e`'s address-producing subexpressions once and return a
/// SavedLValue that can be replayed any number of times via `replayAddr`.
SavedLValue saveLValueAddr(ref WasmCG cg, elem* e)
{
    SavedLValue r;
    if (e.Eoper == OPvar && e.Vsym)
    {
        r.directSym = e.Vsym;
        r.directOff = cast(uint) e.Voffset;
        return r;
    }
    const bool ok = emitLValueAddr(cg, e);
    assert(ok);
    r.addrTemp = cg.allocTemp(WASM_I32);
    cg.emitLocal(OP_LOCAL_SET, r.addrTemp);
    return r;
}

/// Re-push the saved lvalue address onto the value stack.
/// Returns the constant offset the caller must pass to the following
/// load/store as the memarg offset (so `sym + Soffset` can be split into
/// `local.get base; i32.load offset=Soffset` etc.).
uint replayAddr(ref WasmCG cg, SavedLValue r)
{
    if (r.directSym)
    {
        uint memOff;
        const bool ok = emitSymBase(cg, r.directSym, r.directOff, memOff);
        assert(ok);
        return memOff;
    }
    cg.emitLocal(OP_LOCAL_GET, r.addrTemp);
    return 0;
}

/// Emit shadow stack frame prologue (called once at function entry).
/// Creates the shadow base local, gets __stack_pointer, subtracts frame size, stores back.
void emitShadowPrologue(ref WasmCG cg)
{
    uint spIdx = cg.stackPtrGlobal();

    // Round frame size up to 16

    // Allocate a new local to hold the shadow base address
    cg.shadowBaseLocal = cg.allocTemp(WASM_I32);

    const uint fsz = (cg.shadowFrameSize + 15) & ~15u;

    // Emit: shadow_base = __stack_pointer - frame_size; __stack_pointer = shadow_base
    cg.emit(OP_GLOBAL_GET);
    cg.emitULEB(spIdx);
    cg.emitConst(OP_I32_CONST, fsz);
    cg.emit(OP_I32_SUB);
    cg.emit(OP_LOCAL_TEE);
    cg.emitULEB(cg.shadowBaseLocal);
    cg.emit(OP_GLOBAL_SET);
    cg.emitULEB(spIdx);
}

/// Emit shadow stack frame epilogue (restore __stack_pointer).
void emitShadowEpilogue(ref WasmCG cg)
{
    uint spIdx = cg.stackPtrGlobal();
    uint fsz = (cg.shadowFrameSize + 15) & ~15u;

    // Emit: __stack_pointer = shadow_base + frame_size
    cg.emitLocal(OP_LOCAL_GET, cg.shadowBaseLocal);
    cg.emitConst(OP_I32_CONST, cast(int) fsz);
    cg.emit(OP_I32_ADD);
    cg.emit(OP_GLOBAL_SET);
    cg.emitULEB(spIdx);
}

/// Mask result of small integer operation, since WASM operations are at least 32-bit
/// For a 16-bit or 8-bit type `ty`, generate code to truncate to that size
private void maskSmallInt(ref WasmCG cg, tym_t ty)
{
    if (tyfloating(ty))
        return;
    switch (tysize(ty))
    {
    case 1:
        cg.emitConst(OP_I32_CONST, 0xFF);
        cg.emit(OP_I32_AND);
        break;
    case 2:
        cg.emitConst(OP_I32_CONST, 0xFFFF);
        cg.emit(OP_I32_AND);
        break;
    default:
        break;
    }
}

private void genVarArgs(ref WasmCG cg, elem*[] varArgs, ref uint spLocal, ref uint vaFrameSize)
{
    vaFrameSize = 0;

    if (varArgs.length == 0)
    {
        // No variadic args: pass null pointer per LDC2 convention.
        cg.emitConst(OP_I32_CONST, 0);
        return;
    }

    struct VaSlot
    {
        elem* e;
        uint off;
        WASM_OP storeOp;
        uint alignLog2;
        bool promoteF32;
    }

    VaSlot[] slots;
    uint offset = 0;
    foreach (va; varArgs)
    {
        ubyte storeOp;
        uint sz, al;
        bool promF32 = false;
        switch (tybasic(va.Ety).wasmType)
        {
        case WASM_I64:
            storeOp = OP_I64_STORE;
            sz = 8;
            al = 3;
            break;
        case WASM_F64:
            storeOp = OP_F64_STORE;
            sz = 8;
            al = 3;
            break;
        case WASM_F32:
            // C promotes float to double in varargs
            storeOp = OP_F64_STORE;
            sz = 8;
            al = 3;
            promF32 = true;
            break;
        case WASM_I32:
            storeOp = OP_I32_STORE;
            sz = 4;
            al = 2;
            break;
        default:
            assert(0);
        }
        uint byteAlign = 1u << al;
        offset = (offset + byteAlign - 1) & ~(byteAlign - 1);
        slots ~= VaSlot(va, offset, storeOp, al, promF32);
        offset += sz;
    }
    vaFrameSize = (offset + 15) & ~15;

    // Allocate shadow stack frame for varargs.
    uint spIdx = cg.stackPtrGlobal();
    spLocal = cg.allocTemp(WASM_I32);
    cg.emit(OP_GLOBAL_GET);
    cg.emitULEB(spIdx);
    cg.emitConst(OP_I32_CONST, cast(int) vaFrameSize);
    cg.emit(OP_I32_SUB);
    cg.emit(OP_LOCAL_TEE);
    cg.emitULEB(spLocal);
    cg.emit(OP_GLOBAL_SET);
    cg.emitULEB(spIdx);

    // Store each variadic arg into the frame.
    foreach (ref sl; slots)
    {
        cg.emitLocal(OP_LOCAL_GET, spLocal); // addr
        cg.genElem(sl.e); // value
        if (sl.promoteF32)
            cg.emit(OP_F64_PROMOTE_F32);
        cg.emit(sl.storeOp);
        cg.emitMemArg(sl.alignLog2, sl.off);
    }

    // Push varargs pointer as the last parameter.
    cg.emitLocal(OP_LOCAL_GET, spLocal);
}

// Drop OPcomma side-effect chains, emitting and dropping each LHS, until we
// land on something that isn't an OPcomma. Returns the remaining value-expr.
private elem* unwrapComma(ref WasmCG cg, elem* e)
{
    while (e && e.Eoper == OPcomma)
    {
        if (cg.genElem(e.E1))
            cg.emit(OP_DROP);
        e = e.E2;
    }
    return e;
}

// Emit one half of a slice/delegate `e` (the i32 at offset 0 or offset 4 of
// its in-memory representation) without going through an i64-packed value.
// `e` must already be OPcomma-unwrapped via unwrapComma.
// Returns: true on success. Returns false when `e` isn't an addressable
// slice/delegate that we can decompose.
private bool emitSliceHalf(ref WasmCG cg, elem* e, bool ptrHalf)
{
    if (!e)
        return false;
    const tym_t ety = tybasic(e.Ety);
    if (ety != TYdarray && ety != TYdelegate)
        return false;
    const uint half = ptrHalf ? 4u : 0u;
    uint memOff;
    if (e.Eoper == OPvar && e.Vsym &&
        emitSymBase(cg, e.Vsym, cast(uint) e.Voffset + half, memOff))
    {
        cg.emit(OP_I32_LOAD);
        cg.emitMemArg(2, memOff);
        return true;
    }
    if (e.Eoper == OPind && e.E1)
    {
        cg.genElem(e.E1);
        cg.emit(OP_I32_LOAD);
        cg.emitMemArg(2, half);
        return true;
    }
    return false;
}

// Returns: true if param_t denotes a D slice/delegate (split into two i32s).
private bool paramIsSlice(const(param_t)* p)
{
    if (!p || !p.Ptype)
        return false;
    return isSliceOrDelegate(cast(type*) p.Ptype);
}

// Emit `arg` as a slice/delegate split into (length, ptr) i32s.
private void emitSliceArg(ref WasmCG cg, elem* arg)
{
    elem* a = unwrapComma(cg, arg);
    // OPconst null slice/delegate → emit (0, 0).
    if (a.Eoper == OPconst)
    {
        cg.emitConst(OP_I32_CONST, 0);
        cg.emitConst(OP_I32_CONST, 0);
        return;
    }
    // OPpair(lo, hi): lo = length (LSW), hi = ptr (MSW). Emit both halves directly.
    if (a.Eoper == OPpair)
    {
        cg.genElem(a.E1);
        cg.genElem(a.E2);
        return;
    }
    if (emitSliceHalf(cg, a, /*ptrHalf*/ false) &&
        emitSliceHalf(cg, a, /*ptrHalf*/ true))
        return;

    elem_print(arg);
    assert(0);
}

// Consume one leaf of the current call's OPparam tree as a single argument,
// using the CallCtx at top of `cg.callCtxStack` to decide how to emit it.
// `case OPparam` in genElem walks E2 then E1 and dispatches each leaf here.
//
// Walk order: for D linkage (TYjfunc), the OPparam tree is left-folded with
// source-order args plus ethis/ehidden appended last, so E2-first/E1-second
// yields the declared param order [this, line, file, args].
private void consumeCallArg(ref WasmCG cg, elem* e)
{
    if (!e)
        return;
    if (e.Eoper == OPparam)
    {
        cg.genElem(e); // → case OPparam → recurses through here
        return;
    }
    CallCtx* ctx = &cg.callCtxStack[$ - 1];
    if (ctx.skipCount > 0)
    {
        // ABI-prepended leaf (hidden ret ptr, ethis, nested static-link).
        // These come first in stack order but aren't in Tparamtypes — emit
        // them as plain i32s without advancing nextParam.
        ctx.skipCount--;
        cg.genElem(e);
        return;
    }
    if (ctx.remainingParams.length > 0)
    {
        param_t* p = &ctx.remainingParams[0];
        ctx.remainingParams = ctx.remainingParams[1 .. $];
        if (paramIsSlice(p))
        {
            emitSliceArg(cg, e);
            return;
        }
    }
    else if (ctx.isCVariadic)
    {
        // Past declared params: stash for the post-recursion shadow-frame spill.
        ctx.varArgs ~= e;
        return;
    }
    cg.genElem(e);
}

// Expression code generation
private bool genCall(ref WasmCG cg, elem* e)
{
    // E1 is the function. Direct call: E1 is OPvar of a function symbol.
    Symbol* calleeSym = e.E1.Vsym;
    // null;
    // if (e.E1.Eoper == OPvar && e.E1.Vsym && e.E1.Vsym.Sclass != SC.auto_ && e.E1.Vsym.Sclass != SC.parameter && e.E1.Vsym.Sclass != SC.fastpar)
    //    calleeSym = e.E1.Vsym;

    type* fty = calleeSym ? calleeSym.Stype : null;
    // Indirect call: derive the function type from the function-pointer
    // variable's declared type so slice/delegate args still split into
    // (length, ptr) and the call_indirect type signature matches the
    // callee's declared signature. e.ET is only set for TYstruct/TYarray
    // elems, so for function pointers we have to fish the type out of the
    // underlying Symbol (Stype is pointer-to-function; Tnext is the func).
    if (!fty)
    {
        elem* fe = e.E1;
        // Peel an outer OPind: e2ir often emits `*&f` for function calls.
        if (fe && fe.Eoper == OPind && fe.E1)
            fe = fe.E1;
        Symbol* fsym = (fe && (fe.Eoper == OPvar || fe.Eoper == OPrelconst)) ? fe.Vsym : null;
        if (fsym && fsym.Stype)
        {
            type* st = fsym.Stype;
            if (st.Tnext && tyfunc(st.Tnext.Tty))
                fty = st.Tnext;          // pointer-to-function variable
            else if (tyfunc(st.Tty))
                fty = st;                 // direct function symbol via OPrelconst
        }
    }

    // C variadic requires Tparamtypes set (bare TYnfunc/TYjfunc with no
    // params is an unprototyped RTL decl, not a real variadic).
    CallCtx ctx;
    ctx.remainingParams = (fty && fty.Tparamtypes) ? *fty.Tparamtypes : null;
    ctx.isCVariadic = fty !is null && fty.Tparamtypes !is null && variadic(fty);

    // Hidden-ret pointer (struct/array return) and ethis/nested static link
    // are prepended to the WASM signature by buildFuncType, but they don't
    // appear in Tparamtypes. The OPparam tree contains them as leaves walked
    // before the declared args, so let consumeCallArg skip past them.
    if (fty && fty.Tnext && returnByPtr(fty.Tnext))
        ctx.skipCount++;
    if (calleeSym && calleeSym.Sfunc &&
        (calleeSym.Sfunc.Fflags3 & (Fmember | Fnested)))
        ctx.skipCount++;

    // Walk the OPparam tree via genElem natural recursion; consumeCallArg
    // emits each leaf using `ctx`, queueing variadics into ctx.varArgs.
    cg.callCtxStack ~= ctx;
    consumeCallArg(cg, e.E2);
    elem*[] varArgs = cg.callCtxStack[$ - 1].varArgs;
    cg.callCtxStack.length--;

    // For C variadics, spill the queued args to the shadow frame and push
    // the frame pointer as the trailing i32 arg.
    uint spLocal;
    uint vaFrameSize;
    if (ctx.isCVariadic)
        cg.genVarArgs(varArgs, spLocal, vaFrameSize);

    if (calleeSym)
    {
        cg.emitCall(cg.funcIndex(calleeSym), calleeSym);
    }
    else
    {
        // Indirect call. Prefer the declared function type when available so
        // slices/delegates split into (length, ptr) i32 pairs and aggregates
        // pass by hidden pointer — matching what buildFuncType does for
        // direct calls. Fall back to deriving from arg shapes when the
        // function pointer carries no type info.
        uint typeIdx;
        if (fty)
        {
            typeIdx = cg.internType(buildFuncType(fty, null));
        }
        else
        {
            typeIdx = cg.internType(buildFuncType(e.E2));
        }

        // Function pointer source: strip an outer OPind (fptr table index
        // lives at the address) and evaluate the inner expression to push
        // the table index on the value stack.
        elem* fn = (e.E1.Eoper == OPind && e.E1.E1) ? e.E1.E1 : e.E1;
        cg.genElem(fn);
        cg.emit(OP_CALL_INDIRECT);
        cg.emitCallIndirectType(typeIdx);
        cg.emitULEB(0); // table index 0
    }

    // Restore __stack_pointer after a variadic call that spilled args.
    if (ctx.isCVariadic && varArgs.length)
    {
        uint spIdx = cg.stackPtrGlobal();
        cg.emitLocal(OP_LOCAL_GET, spLocal);
        cg.emitConst(OP_I32_CONST, cast(int) vaFrameSize);
        cg.emit(OP_I32_ADD);
        cg.emit(OP_GLOBAL_SET);
        cg.emitULEB(spIdx);
    }

    // Noreturn (SFLexit) functions leave the stack empty. Emit unreachable
    // so WASM's type checker accepts any type expectations after the call.
    if (calleeSym && (calleeSym.Sflags & SFLexit))
        cg.emit(OP_UNREACHABLE);

    // Whether the call left a value on the WASM stack depends on the
    // callee's WASM signature, not e.Ety. For direct calls to a function
    // defined in this module, e.Ety can disagree with the function's
    // actual return type (e.g. a void member call appearing in an
    // OPcomma chain): trust the callee's Stype.Tnext.
    const retTy = tybasic(e.Ety);
    bool pushedValue = typeHasValue(e.Ety);
    if (e.E1.Eoper == OPvar && e.E1.Vsym && e.E1.Vsym.Stype && e.E1.Vsym.Stype.Tnext)
    {
        const tym_t calleeRet = tybasic(e.E1.Vsym.Stype.Tnext.Tty);
        pushedValue = typeHasValue(calleeRet);
    }
    return pushedValue;
}

/// Code generation for an element
/// Returns: true if the expression has a result on the stack after genElem
bool genElem(ref WasmCG cg, elem* e, WASM_TYPE type)
{
    const result = cg.genElem(e);
    if (result && typeHasValue(e.Ety))
        emitCoerce(cg, wasmType(e.Ety), type);
    return result;
}

bool genElem(ref WasmCG cg, elem* e)
{
    if (!e)
        return false;

    const op = e.Eoper;

    // elem_print(e);

    bool unaryOp(WASM_OP op)
    {
        cg.genElem(e.E1);
        cg.emit(op);
        return true;
    }

    switch (op)
    {
    case OPcall:
    case OPucall:
        return cg.genCall(e);

    case OPparam:
        // OPparam is only valid inside an OPcall's E2 subtree. Walk E2 then E1
        // (call-order: see consumeCallArg comment) and dispatch each leaf via
        // the active CallCtx on top of cg.callCtxStack.
        consumeCallArg(cg, e.E2);
        consumeCallArg(cg, e.E1);
        return false;

    case OPconst:
        // A TYvoid OPconst is the dead "result" of a folded short-circuit
        // expression in statement context (cgelem.d:eloror rewrites
        // `true || noreturnCall` into `OPcomma(1, OPconst(TYvoid, 1))`).
        // The OPcomma already knows not to drop a non-push, so emit nothing.
        if (tybasic(e.Ety) == TYvoid)
            return false;
        switch (e.wasmType)
        {
        case WASM_I64:
            cg.emitConst(OP_I64_CONST, e.Vllong);
            break;
        case WASM_F32:
            cg.emit(OP_F32_CONST);
            float f = e.Vfloat;
            cg.code.write(&f, 4);
            break;
        case WASM_F64:
            cg.emit(OP_F64_CONST);
            double d = e.Vdouble;
            cg.code.write(&d, 8);
            break;
        case WASM_I32:
            cg.emitConst(OP_I32_CONST, cast(int) e.Vlong);
            break;
        default:
            assert(0);
        }
        return true;

    case OPvar:
        if (emitSymLoad(cg, e.Vsym, cast(uint) e.Voffset, e.Ety))
            return true;

        assert(0);
        // cg.emitLocal(OP_LOCAL_GET, cg.localFor(e.Vsym));
        // return true;

    case OPrelconst:
        if (Symbol* rs = e.Vsym)
        {
            // Function address, table-index relocation
            if (rs.Sfl == FL.func)
            {
                cg.emitTableIndex(cg.funcIndex(rs), rs);
                return true;
            }

            cg.emitSymAddr(rs, cast(uint) e.Voffset);
            return true;
        }
        assert(0);

    case OPaddr:
        // Address-of an lvalue. Falls through to genElem(E1) only if E1 isn't
        // a recognised lvalue (e.g. address-of an rvalue computation).
        if (emitLValueAddr(cg, e.E1))
            return true;
        elem_print(e.E1);
        assert(0);

    case OPind:
        cg.genElem(e.E1); // address on stack
        cg.emitLoad(e.Ety);
        return true;

    case OPeq:
        {
            // Slice/delegate assignment where the RHS resolves to a
            // fresh (length, ptr) pair — e.g. `arr = arr[0 .. n]`,
            // `arr = somefunc()` returning a `T[]`, or a delegate
            // literal `&obj.method`. Decompose into two i32 stores
            // rather than treating the 8-byte aggregate as one value.
            // Peek through trailing OPcomma side effects on the RHS.
            const tym_t lty = tybasic(e.E1.Ety);

            // unwrapComma()

            elem* rhsTail = e.E2;
            while (rhsTail && rhsTail.Eoper == OPcomma)
                rhsTail = rhsTail.E2;

            if ((lty == TYdarray || lty == TYdelegate) &&
                rhsTail && (rhsTail.Eoper == OPpair || rhsTail.Eoper == OPrpair) &&
                emitLValueAddr(cg, e.E1))
            {
                // Evaluate any leading OPcomma side effects (everything
                // before the tail pair).
                for (elem* c = e.E2; c !is rhsTail; c = c.E2)
                {
                    if (cg.genElem(c.E1))
                        cg.emit(OP_DROP);
                }
                // Capture base addr in a temp so we can use it twice.
                uint addrTmp = cg.allocTemp(WASM_I32);
                cg.emit(OP_LOCAL_SET);
                cg.emitULEB(addrTmp);
                // OPpair: E1=lo (length), E2=hi (ptr).
                // OPrpair: E1=hi (ptr), E2=lo (length).
                elem* lo = (rhsTail.Eoper == OPpair) ? rhsTail.E1 : rhsTail.E2;
                elem* hi = (rhsTail.Eoper == OPpair) ? rhsTail.E2 : rhsTail.E1;
                cg.emitLocal(OP_LOCAL_GET, addrTmp);
                cg.genElem(lo);
                cg.emit(OP_I32_STORE);
                cg.emitMemArg(2, 0);
                cg.emitLocal(OP_LOCAL_GET, addrTmp);
                cg.genElem(hi);
                cg.emit(OP_I32_STORE);
                cg.emitMemArg(2, 4);
                return false;
            }
            // Store rhs through lvalue E1, leaving the rhs value on stack
            // (unless this assignment is used as a statement, e.Ety == void).
            uint memOff;
            if (cg.emitLValueBase(e.E1, memOff))
            {
                cg.genElem(e.E2);
                if (typeHasValue(e.Ety))
                {
                    // Save value so the store doesn't consume our result.
                    uint valTmp = cg.allocTemp(wasmType(e.E1.Ety));
                    cg.emit(OP_LOCAL_TEE);
                    cg.emitULEB(valTmp);
                    cg.emitStore(e.E1.Ety, memOff);
                    cg.emitLocal(OP_LOCAL_GET, valTmp);
                    return true;
                }
                cg.emitStore(e.E1.Ety, memOff);
                return false;
            }
            elem_print(e);
            assert(0);
            return true;
        }

    case OPaddass:
    case OPminass:
    case OPmulass:
    case OPdivass:
    case OPmodass:
    case OPandass:
    case OPorass:
    case OPxorass:
    case OPshlass:
    case OPshrass:
    case OPashrass:
        {
            // Desugar: lhs op= rhs  =>  lhs = lhs op rhs.
            // Lvalue address is needed twice (load + store) — capture it.
            if (e.E1.Eoper != OPvar && e.E1.Eoper != OPind)
            {
                cg.genElem(e.E2);
                return true;
            }
            auto lv = saveLValueAddr(cg, e.E1);
            uint loadOff = replayAddr(cg, lv);
            cg.emitLoad(e.E1.Ety, loadOff);
            cg.genElem(e.E2, wasmType(e));
            cg.emitBinop(opeqtoop(op), e.Ety);
            cg.maskSmallInt(e.E1.Ety);
            // Save new value, store, leave on stack as result.
            uint vTmp = cg.allocTemp(wasmType(e.E1.Ety));
            cg.emitLocal(OP_LOCAL_SET, vTmp);
            uint storeOff = replayAddr(cg, lv);
            cg.emitLocal(OP_LOCAL_GET, vTmp);
            cg.emitStore(e.E1.Ety, storeOff);
            cg.emitLocal(OP_LOCAL_GET, vTmp);
            return true;
        }

    case OPadd:
    case OPmin:
    case OPmul:
    case OPdiv:
    case OPmod:
    case OPand:
    case OPor:
    case OPxor:
    case OPshl:
    case OPshr:
    case OPashr:
    case OProl: // OProl/OPror are from `core.bitop.rol`/`ror` or recognized patterns
    case OPror:
        {
            const rty = wasmType(e.Ety);
            cg.genElem(e.E1, rty);
            cg.genElem(e.E2, rty);
            cg.emitBinop(op, e.Ety);
            return true;
        }

    case OPframeptr:
        // Push the function's frame pointer (base of shadow frame).
        // Generated by glue for nested-function context pointers and for
        // `va_start` / `alloca` expansions that need the frame base.
        cg.emitLocal(OP_LOCAL_GET, cg.shadowBaseLocal);
        return true;

    case OPpostinc:
    case OPpostdec:
        // D `x++` / `x--`. Result is the original value; the side effect
        // is `x = x +/- E2` (E2 is the step, usually 1).
        {
            // result = old value of E1; then E1 = old +/- E2
            if (e.E1.Eoper != OPvar && e.E1.Eoper != OPind)
            {
                assert(0);
            }

            auto lv = saveLValueAddr(cg, e.E1);
            uint loadOff = replayAddr(cg, lv);
            cg.emitLoad(e.E1.Ety, loadOff);

            // Stash old value as the result.
            uint oldTmp = cg.allocTemp(wasmType(e.E1));
            cg.emit(OP_LOCAL_TEE);
            cg.emitULEB(oldTmp);

            // Compute new value = old +/- E2.
            cg.genElem(e.E2, wasmType(e.E1.Ety));
            cg.emitBinop(op == OPpostinc ? OPadd : OPmin, e.E1.Ety);
            cg.maskSmallInt(e.E1.Ety);

            // Store new value back.
            uint newTmp = cg.allocTemp(wasmType(e.E1));
            cg.emitLocal(OP_LOCAL_SET, newTmp);
            uint storeOff = replayAddr(cg, lv);
            cg.emitLocal(OP_LOCAL_GET, newTmp);
            cg.emitStore(e.E1.Ety, storeOff);

            // Result: old value.
            cg.emitLocal(OP_LOCAL_GET, oldTmp);
            return true;
        }

    case OPeqeq:
    case OPne:
    case OPlt:
    case OPle:
    case OPgt:
    case OPge:
        cg.genElem(e.E1);
        cg.genElem(e.E2, e.E1.wasmType);
        emitRelop(cg, op, e.E1.Ety);
        return true;

    case OPneg:
        switch (e.wasmType)
        {
        case WASM_F32: return unaryOp(OP_F32_NEG);
        case WASM_F64: return unaryOp(OP_F64_NEG);
            // integer negation = 0 - x
        case WASM_I64:
            cg.emitConst(OP_I64_CONST, 0);
            cg.genElem(e.E1);
            cg.emit(OP_I64_SUB);
            return true;
        case WASM_I32:
            cg.emitConst(OP_I32_CONST, 0);
            cg.genElem(e.E1);
            cg.emit(OP_I32_SUB);
            return true;
        default:
            assert(0);
        }

    case OPabs:
        // D `import core.math; abs(x);` and `std.math.abs`. Generated as
        // an intrinsic when the frontend recognises the call.
        final switch (e.wasmType)
        {
        case WASM_F32: return unaryOp(OP_F32_ABS);
        case WASM_F64: return unaryOp(OP_F64_ABS);
        case WASM_I32:
        case WASM_I64:
            // No native integer abs. Compute `(x ^ (x >> N-1)) - (x >> N-1)`,
            // i.e. flip-on-negative-then-subtract-mask. Saves a branch.
            {
                const bool is64 = (e.wasmType == WASM_I64);
                uint t = cg.allocTemp(is64 ? WASM_I64 : WASM_I32);
                cg.genElem(e.E1);
                cg.emitLocal(OP_LOCAL_TEE, t); // stash x
                // Arithmetic shift right to get sign mask.
                if (is64)
                {
                    cg.emitConst(OP_I64_CONST, 63);
                    cg.emit(OP_I64_SHR_S);
                }
                else
                {
                    cg.emitConst(OP_I32_CONST, 31);
                    cg.emit(OP_I32_SHR_S);
                }
                uint m = cg.allocTemp(is64 ? WASM_I64 : WASM_I32);
                cg.emitLocal(OP_LOCAL_TEE, m); // stash mask
                cg.emitLocal(OP_LOCAL_GET, t);
                cg.emit(is64 ? OP_I64_XOR : OP_I32_XOR); // x ^ mask
                cg.emitLocal(OP_LOCAL_GET, m);
                cg.emit(is64 ? OP_I64_SUB : OP_I32_SUB); // - mask
                return true;
            }
        }

    case OPsqrt: // D `import core.math; sqrt(x);`
        final switch (e.wasmType)
        {
        case WASM_F32: return unaryOp(OP_F32_SQRT);
        case WASM_F64: return unaryOp(OP_F64_SQRT);
        case WASM_I32:
        case WASM_I64:
            assert(0);
        }

    case OPnegass:
        // `x = -x;` lowered as a single op (an in-place negation).
        // Reuse the OPneg emitter for the value, then store back.
        {
            if (e.E1.Eoper != OPvar && e.E1.Eoper != OPind)
            {
                assert(0);
                cg.emit(OP_UNREACHABLE);
                return typeHasValue(e.Ety);
            }
            auto lv = saveLValueAddr(cg, e.E1);
            uint loadOff = replayAddr(cg, lv);
            cg.emitLoad(e.E1.Ety, loadOff);
            // Apply negation in-stack using the wasm type of the lhs.
            const wty = e.E1.Ety.wasmType;
            final switch (wty)
            {
            case WASM_F32:
                cg.emit(OP_F32_NEG);
                break;
            case WASM_F64:
                cg.emit(OP_F64_NEG);
                break;
            case WASM_I64:
                {
                    uint t = cg.allocTemp(WASM_I64);
                    cg.emitLocal(OP_LOCAL_SET, t);
                    cg.emitConst(OP_I64_CONST, 0);
                    cg.emitLocal(OP_LOCAL_GET, t);
                    cg.emit(OP_I64_SUB);
                    break;
                }
            case WASM_I32:
                {
                    uint t = cg.allocTemp(WASM_I32);
                    cg.emitLocal(OP_LOCAL_SET, t);
                    cg.emitConst(OP_I32_CONST, 0);
                    cg.emitLocal(OP_LOCAL_GET, t);
                    cg.emit(OP_I32_SUB);
                    break;
                }
            }
            cg.maskSmallInt(e.E1.Ety);
            uint vTmp = cg.allocTemp(wty);
            cg.emitLocal(OP_LOCAL_SET, vTmp);
            uint storeOff = replayAddr(cg, lv);
            cg.emitLocal(OP_LOCAL_GET, vTmp);
            cg.emitStore(e.E1.Ety, storeOff);
            cg.emitLocal(OP_LOCAL_GET, vTmp);
            return true;
        }

    case OPnot:
        cg.genElem(e.E1);
        emitCondInvert(cg, e.E1);
        return true;

    case OPcom:
        // ~x = x ^ 0xFFFFFFFF
        final switch (e.wasmType)
        {
        case WASM_I64:
            cg.genElem(e.E1);
            cg.emitConst(OP_I64_CONST, -1);
            cg.emit(OP_I64_XOR);
            return true;
        case WASM_I32:
            cg.genElem(e.E1);
            cg.emitConst(OP_I32_CONST, -1);
            cg.emit(OP_I32_XOR);
            return true;
        case WASM_F32:
        case WASM_F64:
            assert(0); // operator not defined for float types
        }

    // Unsigned widenings up to i32 are no-ops: small ints already live as
    // i32 with zero-extension (D `ushort x; uint y = x;`).
    case OPu8_16:
    case OPu16_32:
        cg.genElem(e.E1);
        return true;

    // Signed/unsigned integer widening (D `int i = s; long l = i;` and unsigned variants).
    case OPs8_16: return unaryOp(OP_I32_EXTEND8_S);
    case OPs16_32: return unaryOp(OP_I32_EXTEND16_S);
    case OPu32_64: return unaryOp(OP_I64_EXTEND_I32_U);
    case OPs32_64: return unaryOp(OP_I64_EXTEND_I32_S);

    // Integer narrowing (D `long l; int i = cast(int) l;`).
    case OP64_32: return unaryOp(OP_I32_WRAP_I64);

    // Float<->double (D `float f = cast(float) d;` and reverse).
    case OPd_f: return unaryOp(OP_F32_DEMOTE_F64);
    case OPf_d: return unaryOp(OP_F64_PROMOTE_F32);

    // Float to integer (D `int i = cast(int) d;` etc.).
    case OPd_s32: return unaryOp(OP_I32_TRUNC_F64_S);
    case OPd_u32: return unaryOp(OP_I32_TRUNC_F64_U);
    case OPd_s64: return unaryOp(OP_I64_TRUNC_F64_S);
    case OPd_u64: return unaryOp(OP_I64_TRUNC_F64_U);

    // Integer to float (D `double d = cast(double) i;` etc.).
    case OPs32_d: return unaryOp(OP_F64_CONVERT_I32_S);
    case OPu32_d: return unaryOp(OP_F64_CONVERT_I32_U);
    case OPs64_d: return unaryOp(OP_F64_CONVERT_I64_S);
    case OPu64_d: return unaryOp(OP_F64_CONVERT_I64_U);

    // 16-bit converters. WASM has no direct 16-bit instructions; small ints
    // live in i32 slots, so sign/zero-extend the input first, then convert
    // (D `double d = cast(double)cast(short)x;`, `short s = cast(short)d;`).
    case OPs16_d:
        cg.genElem(e.E1);
        cg.emit(OP_I32_EXTEND16_S);
        cg.emit(OP_F64_CONVERT_I32_S);
        return true;
    case OPu16_d:
        cg.genElem(e.E1);
        cg.emitConst(OP_I32_CONST, 0xFFFF);
        cg.emit(OP_I32_AND);
        cg.emit(OP_F64_CONVERT_I32_U);
        return true;
    case OPd_s16:
        cg.genElem(e.E1);
        cg.emit(OP_I32_TRUNC_F64_S);
        cg.emitConst(OP_I32_CONST, 0xFFFF);
        cg.emit(OP_I32_AND);
        return true;
    case OPd_u16:
        cg.genElem(e.E1);
        cg.emit(OP_I32_TRUNC_F64_U);
        cg.emitConst(OP_I32_CONST, 0xFFFF);
        cg.emit(OP_I32_AND);
        return true;

    // Long double conversions. WASM has no 80-bit real, so `real` == `double`
    // in this backend (see wasmType: TYreal -> WASM_F64). All `_ld` / `ld_`
    // conversions degenerate to identity or to the corresponding `_d` form.
    // D `double d = cast(double)r;`, `real r = cast(real)d;`.
    case OPd_ld:
    case OPld_d:
        cg.genElem(e.E1);
        return true;
    case OPld_u64:
        // D `ulong u = cast(ulong)r;` with real==double on WASM.
        return unaryOp(OP_I64_TRUNC_F64_U);

    case OPmsw:
        {
            // Slice/delegate: high 32 bits live at offset +4 of the
            // slice's address. Load them directly — slices/delegates
            // are never packed into a single i64.
            elem* src = unwrapComma(cg, e.E1);
            if (emitSliceHalf(cg, src, /*ptrHalf*/ true))
                return true;
            // Fallback: 64-bit value (non-slice). Extract via shift.
            cg.genElem(src);
            cg.emitConst(OP_I64_CONST, 32);
            cg.emit(OP_I64_SHR_U);
            cg.emit(OP_I32_WRAP_I64);
            return true;
        }

    case OPstrpar:
        // `void f(S s)` callsite: `f(myS)` becomes `OPstrpar(myS)`.
        // The contained E1 is the struct value (typically an lvalue: OPvar
        // for a variable, OPind for a pointer dereference, or a comma chain
        // that ends in one of those).
        if (emitLValueAddr(cg, e.E1))
            return true;

        assert(0);

    case OPpair:
    case OPrpair:
        // Build a 64-bit value from two 32-bit halves. Emitted by glue/optimizer
        // for slice/delegate construction (D `T[] s = arr[0 .. n];` and
        // `auto dg = &obj.method;`) and for elsewhere-disabled struct-pair SROA.
        //   OPpair:  E1 = low  (offset +0), E2 = high (offset +4)
        //   OPrpair: E1 = high (offset +4), E2 = low  (offset +0)
        // Resulting i64 packs as `(hi << 32) | (lo & 0xFFFFFFFF)`. When stored
        // via i64.store the little-endian layout puts `lo` at addr+0 and `hi`
        // at addr+4, matching the in-memory slice/delegate layout. The
        // dedicated OPeq decomposition above already handles the common
        // store path with two i32 stores — this case handles uses that
        // consume the pair as a single 64-bit value (e.g. passed to OPmsw,
        // OP64_32, or stored as a whole via i64).
        {
            elem* lo = (op == OPpair) ? e.E1 : e.E2;
            elem* hi = (op == OPpair) ? e.E2 : e.E1;
            cg.genElem(lo);
            cg.emit(OP_I64_EXTEND_I32_U);
            cg.genElem(hi);
            cg.emit(OP_I64_EXTEND_I32_U);
            cg.emitConst(OP_I64_CONST, 32);
            cg.emit(OP_I64_SHL);
            cg.emit(OP_I64_OR);
            return true;
        }
        // assert(0);

    case OP16_8:
        cg.genElem(e.E1);
        cg.emitConst(OP_I32_CONST, 0xFF);
        cg.emit(OP_I32_AND);
        return true;

    case OP32_16:
        cg.genElem(e.E1);
        cg.emitConst(OP_I32_CONST, 0xFFFF);
        cg.emit(OP_I32_AND);
        return true;

    case OPcomma:
        if (cg.genElem(e.E1))
            cg.emit(OP_DROP); // discard left-hand result
        return cg.genElem(e.E2);

    case OPcond:
        {
            // e.E1 ? e.E2.E1 : e.E2.E2
            cg.genElem(e.E1);
            emitCondToI32(cg, e.E1); // i64 cond → i32 truthiness
            const bool voidCond = !typeHasValue(e.Ety);
            cg.emit(OP_IF);
            if (voidCond)
                cg.emit(WASM_VOID_BLOCK); // void blocktype: discard any branch value
            else
                cg.emit(e.wasmType);

            const bool thenPushed = cg.genElem(e.E2.E1);
            if (voidCond && thenPushed)
                cg.emit(OP_DROP);

            cg.emit(OP_ELSE);
            const bool elsePushed = cg.genElem(e.E2.E2);
            if (voidCond && elsePushed)
                cg.emit(OP_DROP);

            cg.emit(OP_END);
            return !voidCond;
        }

    case OPoror:
        {
            // a || b  =>  if (a) 1 else (b != 0)
            cg.genElem(e.E1);
            emitCondToI32(cg, e.E1);
            cg.emit(OP_IF);
            cg.emit(WASM_I32);
            cg.emitConst(OP_I32_CONST, 1);
            cg.emit(OP_ELSE);
            cg.genElem(e.E2);

            if (!typeHasValue(e.E2.Ety))
            {
                // Void RHS leaves nothing on the stack; synthesise a result so
                // the if-block type checks. Caller will typically drop it.
                cg.emitConst(OP_I32_CONST, 0);
            }
            else
            {
                emitCondToI32(cg, e.E2);
            }
            cg.emit(OP_END);
            return true;
        }

    case OPandand:
        {
            // a && b  =>  if (a) (b != 0) else 0
            cg.genElem(e.E1);
            emitCondToI32(cg, e.E1);
            cg.emit(OP_IF);
            cg.emit(WASM_I32);
            cg.genElem(e.E2);
            if (!typeHasValue(e.E2.Ety))
            {
                cg.emitConst(OP_I32_CONST, 0);
            }
            else
            {
                emitCondToI32(cg, e.E2);
                cg.emitConst(OP_I32_CONST, 0);
                cg.emit(OP_I32_NE);
            }
            cg.emit(OP_ELSE);
            cg.emitConst(OP_I32_CONST, 0);
            cg.emit(OP_END);
            return true;
        }

    case OPbool:
        cg.genElem(e.E1);
        emitCondToI32(cg, e.E1);
        return true;

    case OPb_8:
        cg.genElem(e.E1); // bool is already 0/1 as i32
        return true;

    case OPhalt:
        cg.emit(OP_UNREACHABLE);
        return false;

    case OPvoid:
        return false;

    case OPinfo:
        // Optimizer annotation, no code
        return cg.genElem(e.E2); // only the right child has the value

    case OPddtor:
        // D scope destructor marker (`scope(exit) { ... }` and inferred
        // dtor cleanups). Emitted by glue around the dtor body; treat as
        // a passthrough — the body is in E1.
        if (e.E1)
            return cg.genElem(e.E1);
        return false;

    case OPsizeof:
        // Sizeof (compile-time constant, should be folded)
        cg.emitConst(OP_I32_CONST, cast(int) e.Vlong);
        return true;

    case OPstreq:
        {
            // Struct assignment: copy type_size(e.ET) bytes from E2 to E1.
            // Result: the destination address (i32) for chained assignment.

            uint sz = e.ET ? cast(uint) type_size(e.ET) : 0;
            if (sz == 0)
                return false;

            uint dstTmp = cg.allocTemp(WASM_I32);
            genElemAddr(cg, e.E1);
            cg.emit(OP_LOCAL_TEE);
            cg.emitULEB(dstTmp); // stack: dst
            genElemAddr(cg, e.E2); // stack: dst, src
            cg.emitConst(OP_I32_CONST, sz); // stack: dst, src, n
            emitMemoryCopy(cg);
            cg.emitLocal(OP_LOCAL_GET, dstTmp); // result: dst
            return true;
        }

    case OPmemcpy:
        {
            // IR: OPmemcpy(dst, OPparam(count, src)). Result is dst.
            uint dstTmp = cg.allocTemp(WASM_I32);
            cg.genElem(e.E1);
            cg.emit(OP_LOCAL_TEE);
            cg.emitULEB(dstTmp); // stack: dst
            if (e.E2 && e.E2.Eoper == OPparam)
            {
                cg.genElem(e.E2.E2, WASM_I32); // src
                cg.genElem(e.E2.E1, WASM_I32); // count
            }
            else if (e.E2)
            {
                cg.genElem(e.E2, WASM_I32); // src
                cg.emitConst(OP_I32_CONST, 0); // count = 0
            }
            else
            {
                cg.emitConst(OP_I32_CONST, 0);
                cg.emitConst(OP_I32_CONST, 0);
            }
            emitMemoryCopy(cg);
            cg.emitLocal(OP_LOCAL_GET, dstTmp);
            return true;
        }

    case OPmemset:
        {
            // IR: OPmemset(dst, OPparam(count, val)). Result is dst.
            uint dstTmp = cg.allocTemp(WASM_I32);
            cg.genElem(e.E1);
            cg.emit(OP_LOCAL_TEE);
            cg.emitULEB(dstTmp); // stack: dst
            assert(e.E2.Eoper == OPparam);

            cg.genElem(e.E2.E2, WASM_I32); // val
            cg.genElem(e.E2.E1, WASM_I32); // count

            emitMemoryFill(cg);
            cg.emitLocal(OP_LOCAL_GET, dstTmp);
            return true;
        }

    // bit scan forward = count trailing zeros; result is always i32
    case OPbsf:
        final switch (e.wasmType)
        {
            case WASM_I64:
                cg.genElem(e.E1);
                cg.emit(OP_I64_CTZ);
                cg.emit(OP_I32_WRAP_I64);
                return true;
            case WASM_I32:
                return unaryOp(OP_I32_CTZ);
            case WASM_F32:
            case WASM_F64:
                assert(0);
        }

    case OPbsr:
        final switch (e.wasmType)
        {
            case WASM_I64:
                cg.emitConst(OP_I64_CONST, 63);
                cg.genElem(e.E1);
                cg.emit(OP_I64_CLZ);
                cg.emit(OP_I64_SUB);
                cg.emit(OP_I32_WRAP_I64);
                return true;
            case WASM_I32:
                cg.emitConst(OP_I32_CONST, 31);
                cg.genElem(e.E1);
                cg.emit(OP_I32_CLZ);
                cg.emit(OP_I32_SUB);
                return true;
            case WASM_F32:
            case WASM_F64:
                assert(0);
        }

    case OPpopcnt:
        {
            cg.genElem(e.E1);
            cg.emit(e.wasmType == WASM_I64 ? OP_I64_POPCNT : OP_I32_POPCNT);
            // result matches input width (int for uint, long for ulong)
            return true;
        }

    case OPbswap:
        {
            // No native WASM bswap; implement with shifts.
            const ty = e.wasmType;
            cg.genElem(e.E1);
            if (ty == WASM_I64)
                emitBswap64(cg);
            else
                emitBswap32(cg);
            return true;
        }

    case OPu64_128: // no cent/ucent
    case OPs64_128:
    case OP128_64:
    case OPc_r: // no complex numbers
    case OPc_i:
    case OPvp_fp: //  DOS era near/far
    case OPcvp_fp:
    case OPnp_fp:
    case OPnp_f16p:
    case OPf16p_np:
    case OPvecfill: // No SIMD yet
    case OPoffset: // segmented-address offset extraction, not applicable.
        assert(0);

    default:
        cg.emit(OP_UNREACHABLE);
        try {
            writeln("-----------------\n unimplemented e.Eoper: ", oper_str(e.Eoper).fromStringz);
            elem_print(e);
        } catch (Exception e) {}
        assert(0);
        return tybasic(e.Ety) != TYvoid;
    }
}

// Emit byte-swap for an i32 value on top of the wasm stack.
// Result: 0xAABBCCDD → 0xDDCCBBAA
private void emitBswap32(ref WasmCG cg)
{
    uint t = cg.allocTemp(WASM_I32);
    cg.emitLocal(OP_LOCAL_TEE, t); // save v

    cg.emitConst(OP_I32_CONST, 24);
    cg.emit(OP_I32_SHR_U); // v >> 24

    cg.emitLocal(OP_LOCAL_GET, t);
    cg.emitConst(OP_I32_CONST, 8);
    cg.emit(OP_I32_SHR_U);
    cg.emitConst(OP_I32_CONST, 0x0000_FF00);
    cg.emit(OP_I32_AND); // (v >> 8) & 0xFF00
    cg.emit(OP_I32_OR);

    cg.emitLocal(OP_LOCAL_GET, t);
    cg.emitConst(OP_I32_CONST, 8);
    cg.emit(OP_I32_SHL);
    cg.emitConst(OP_I32_CONST, 0x00FF_0000);
    cg.emit(OP_I32_AND); // (v << 8) & 0xFF0000
    cg.emit(OP_I32_OR);

    cg.emitLocal(OP_LOCAL_GET, t);
    cg.emitConst(OP_I32_CONST, 24);
    cg.emit(OP_I32_SHL); // v << 24
    cg.emit(OP_I32_OR);
}

// Emit byte-swap for an i64 value on top of the wasm stack.
// Strategy: split into lo/hi i32 halves, bswap each, then swap halves.
private void emitBswap64(ref WasmCG cg)
{
    uint t = cg.allocTemp(WASM_I64);
    uint lo = cg.allocTemp(WASM_I32);
    uint hi = cg.allocTemp(WASM_I32);
    cg.emitLocal(OP_LOCAL_TEE, t);

    // lo = bswap32((uint)(v))
    cg.emit(OP_I32_WRAP_I64);
    emitBswap32(cg);
    cg.emitLocal(OP_LOCAL_SET, lo);

    // hi = bswap32((uint)(v >> 32))
    cg.emitLocal(OP_LOCAL_GET, t);
    cg.emitConst(OP_I64_CONST, 32);
    cg.emit(OP_I64_SHR_U);
    cg.emit(OP_I32_WRAP_I64);
    emitBswap32(cg);
    cg.emitLocal(OP_LOCAL_SET, hi);

    // result = ((i64)lo << 32) | (i64)hi
    cg.emitLocal(OP_LOCAL_GET, lo);
    cg.emit(OP_I64_EXTEND_I32_U);
    cg.emitConst(OP_I64_CONST, 32);
    cg.emit(OP_I64_SHL);
    cg.emitLocal(OP_LOCAL_GET, hi);
    cg.emit(OP_I64_EXTEND_I32_U);
    cg.emit(OP_I64_OR);
}

// Get the address of an lvalue expression
// OPind → its pointer;
// OPvar in shadow/data → its memory address;
// else genElem (expected to push an address itself)
private void genElemAddr(ref WasmCG cg, elem* e)
{
    if (!e)
    {
        cg.emitConst(OP_I32_CONST, 0);
        return;
    }
    if (e.Eoper == OPind)
    {
        cg.genElem(e.E1);
        return;
    }
    if (e.Eoper == OPvar && e.Vsym &&
        emitSymAddr(cg, e.Vsym, cast(uint) e.Voffset))
        return;
    cg.genElem(e);
}


private bool paramIsAggregate(const(param_t)* p)
{
    if (!p || !p.Ptype)
        return false;
    const tym_t tb = tybasic(p.Ptype.Tty);
    return tb == TYstruct || tb == TYarray;
}


// Pick the WASM opcode variant matching the IR operand's numeric kind.
// Order: f32, f64, i64, i32. Pass OP_UNREACHABLE for kinds that don't apply.
private ubyte pickByKind(tym_t ty, ubyte f32, ubyte f64, ubyte i64, ubyte i32)
{
    final switch (tybasic(ty).wasmType)
    {
    case WASM_F32: return f32;
    case WASM_F64: return f64;
    case WASM_I64: return i64;
    case WASM_I32: return i32;
    }
}

private ubyte pickByKindSigned(tym_t ty, ubyte f32, ubyte f64, ubyte i64, ubyte s64, ubyte i32, ubyte s32)
{
    const bool isUns = tyuns(ty) != 0;
    final switch (tybasic(ty).wasmType)
    {
    case WASM_F32: return f32;
    case WASM_F64: return f64;
    case WASM_I64: return isUns ? i64 : s64;
    case WASM_I32: return isUns ? i32 : s32;
    }
}

// Binary operation opcode selection by IR operator
private void emitBinop(ref WasmCG cg, int op, tym_t ty)
{
    static ubyte binOp(int op, tym_t ty)
    {
        alias U = OP_UNREACHABLE;
        const bool isUns = tyuns(ty) != 0;
        switch (op)
        {
        case OPadd: return pickByKind(ty, OP_F32_ADD, OP_F64_ADD, OP_I64_ADD, OP_I32_ADD);
        case OPmin: return pickByKind(ty, OP_F32_SUB, OP_F64_SUB, OP_I64_SUB, OP_I32_SUB);
        case OPmul: return pickByKind(ty, OP_F32_MUL, OP_F64_MUL, OP_I64_MUL, OP_I32_MUL);
        case OPdiv:
            return pickByKind(ty, OP_F32_DIV, OP_F64_DIV,
                isUns ? OP_I64_DIV_U : OP_I64_DIV_S,
                isUns ? OP_I32_DIV_U : OP_I32_DIV_S);
        case OPmod:
            return pickByKind(ty, U, U,
                isUns ? OP_I64_REM_U : OP_I64_REM_S,
                isUns ? OP_I32_REM_U : OP_I32_REM_S);
        case OPand:  return pickByKind(ty, U, U, OP_I64_AND, OP_I32_AND);
        case OPor:   return pickByKind(ty, U, U, OP_I64_OR, OP_I32_OR);
        case OPxor:  return pickByKind(ty, U, U, OP_I64_XOR, OP_I32_XOR);
        case OPshl:  return pickByKind(ty, U, U, OP_I64_SHL, OP_I32_SHL);
        case OPshr:  return pickByKind(ty, U, U, OP_I64_SHR_U, OP_I32_SHR_U);
        case OPashr: return pickByKind(ty, U, U, OP_I64_SHR_S, OP_I32_SHR_S);
        case OProl:  return pickByKind(ty, U, U, OP_I64_ROTL, OP_I32_ROTL);
        case OPror:  return pickByKind(ty, U, U, OP_I64_ROTR, OP_I32_ROTR);
        default:
            assert(0);
        }
    }

    cg.emit(binOp(op, ty));
}

// Emit a relational/comparison opcode
private void emitRelop(ref WasmCG cg, int op, tym_t ty)
{
    static ubyte relOp(int op, tym_t ty)
    {
        const bool isUns = tyuns(ty) != 0;
        switch (op)
        {
        case OPeqeq: return pickByKind(ty, OP_F32_EQ, OP_F64_EQ, OP_I64_EQ, OP_I32_EQ);
        case OPne:   return pickByKind(ty, OP_F32_NE, OP_F64_NE, OP_I64_NE, OP_I32_NE);
        case OPlt:
            return pickByKind(ty, OP_F32_LT, OP_F64_LT,
                isUns ? OP_I64_LT_U : OP_I64_LT_S,
                isUns ? OP_I32_LT_U : OP_I32_LT_S);
        case OPle:
            return pickByKind(ty, OP_F32_LE, OP_F64_LE,
                isUns ? OP_I64_LE_U : OP_I64_LE_S,
                isUns ? OP_I32_LE_U : OP_I32_LE_S);
        case OPgt:
            return pickByKind(ty, OP_F32_GT, OP_F64_GT,
                isUns ? OP_I64_GT_U : OP_I64_GT_S,
                isUns ? OP_I32_GT_U : OP_I32_GT_S);
            break;
        case OPge:
            return pickByKind(ty, OP_F32_GE, OP_F64_GE,
                isUns ? OP_I64_GE_U : OP_I64_GE_S,
                isUns ? OP_I32_GE_U : OP_I32_GE_S);
            break;
        default:
            assert(0);
        }
    }
    cg.emit(relOp(op, ty));
}

/// Function index lookup
///
/// Returns: index of `sfunc`
uint funcIndex(ref WasmCG cg, Symbol* sfunc)
{
    return funcIndex(sfunc);
}

uint funcIndex(Symbol* sfunc)
{
    // Imports come first in wmod.funcs; defined functions come after.
    // Check imports (registered via WasmObj_external).
    uint nimports = wmod_numImports();
    foreach (size_t i; 0 .. nimports)
    {
        if (wmod_funcs(i) == sfunc)
            return cast(uint) i;
    }

    // Defined functions follow imports.
    foreach (size_t i, ref const fb; wasmFuncBodies)
        if (fb.sym == sfunc)
            return nimports + cast(uint) i;

    if (sfunc && sfunc.Stype)
    {
        int idx = WasmObj_external(sfunc);
        return cast(uint) idx;
    }
    return 0;
}

// Ensure a condition value on the WASM stack is an i32 suitable for br_if.
void emitCondToI32(ref WasmCG cg, elem* condElem, bool invert = false)
{
    assert(condElem);

    switch (condElem.wasmType)
    {
    case WASM_I64:
        cg.emit(OP_I64_EQZ); // i64 → i32: 1 if zero, 0 if nonzero

        if (!invert)
            cg.emit(OP_I32_EQZ); // invert again, `cast(bool) i = !!i`
        return;

    case WASM_F32:
        // f32 truthiness: nonzero (NaN is truthy under WASM's NE semantics).
        cg.emit(OP_F32_CONST);
        float fz = 0.0f;
        cg.code.write(&fz, 4);
        cg.emit(invert ? OP_F32_EQ : OP_F32_NE);
        return;

    case WASM_F64:
        cg.emit(OP_F64_CONST);
        double dz = 0.0;
        cg.code.write(&dz, 8);
        cg.emit(invert ? OP_F64_EQ : OP_F64_NE);
        return;

    case WASM_I32:
        cg.emitConst(OP_I32_CONST, 0);
        cg.emit(invert ? OP_I32_EQ : OP_I32_NE);
        return;

    default:
        assert(0);
    }
}

// Emit the inversion of a condition for "branch if FALSE" patterns (cond; eqz; br_if).
void emitCondInvert(ref WasmCG cg, elem* condElem)
{
    return emitCondToI32(cg, condElem, true);
}

/// Main entry point generating code for a function - called from dout.d
void wasm_codgen(Symbol* sfunc)
{
    import dmd.backend.wasm.obj : wasmFuncBodies, WasmFuncBody;

    // Find this function's entry in wasmFuncBodies
    WasmFuncBody* fb = null;
    foreach (ref WasmFuncBody f; wasmFuncBodies)
    {
        if (f.sym == sfunc)
        {
            fb = &f;
            break;
        }
    }
    assert(fb);
    wasm_codgen2(sfunc, *fb);
}

// Describes how one WASM-level param slot maps into a shadow-frame slot.
private struct ParamSpill
{
    uint wasmLocalIdx; // index of incoming WASM param
    Symbol* sym;       // symbol whose shadow slot this fills
    uint byteOffset;   // offset within the symbol's shadow slot
    tym_t ty;          // backend type of the param (used to pick store op + alignment)
}

void wasm_codgen2(Symbol* sfunc, ref WasmFuncBody fb)
{
    WasmCG cg;

    // All params and locals live in the shadow stack frame; WASM locals
    // hold only the incoming param values (to be spilled into the frame)
    // and anonymous temporaries allocated via allocTemp.
    ParamSpill[] paramSpills;

    foreach (s; globsym[])
    {
        if (!s.isParameter)
            continue;
        cg.registerShadow(s);
        const tym_t pty = tybasic(s.ty());
        if (isSliceOrDelegate(s.Stype))
        {
            // Slice/delegate: 2 i32 WASM params (len/context, ptr/funcptr).
            const uint i0 = cast(uint) cg.locals.length;
            cg.locals ~= WasmLocal(WASM_I32);
            cg.locals ~= WasmLocal(WASM_I32);
            paramSpills ~= ParamSpill(i0, s, 0, TYuint);
            paramSpills ~= ParamSpill(i0 + 1, s, 4, TYuint);
        }
        else if (pty == TYstruct || pty == TYarray)
        {
            // Aggregate param: passed by pointer (i32).
            const uint i0 = cast(uint) cg.locals.length;
            cg.locals ~= WasmLocal(WASM_I32);
            paramSpills ~= ParamSpill(i0, s, 0, TYuint);
        }
        else
        {
            const uint i0 = cast(uint) cg.locals.length;
            cg.locals ~= WasmLocal(wasmType(pty));
            paramSpills ~= ParamSpill(i0, s, 0, pty);
        }
    }
    // buildFuncType may force-extend a function's WASM signature beyond what
    // the D source declared (e.g. `_Dmain` is normalised to (i32, i32) -> i32
    // regardless of the user's source).  Pad cg.locals with placeholder params
    // so the implicit WASM locals 0..numParams-1 don't get clobbered by
    // subsequent allocTemp() calls.
    {
        WasmFuncType ft = buildFuncType(sfunc.Stype, sfunc);
        while (cg.locals.length < ft.params.length)
        {
            ubyte v = ft.params[cg.locals.length];
            cg.locals ~= WasmLocal(cast(WASM_TYPE) v);
        }
    }
    cg.numParams = cast(uint) cg.locals.length;

    // Register every non-param local in the shadow frame.
    foreach (s; globsym[])
    {
        if (s.isParameter)
            continue;
        if (s.Sclass == SC.auto_ || s.Sclass == SC.register || s.Sclass == SC.stack)
            cg.registerShadow(s);
    }

    type* retType = sfunc.Stype.Tnext;
    assert(retType);
    const bool hasReturn = tybasic(retType.Tty) != TYvoid;
    {
        const tym_t rb = tybasic(retType.Tty);
        cg.retByHiddenPtr = (rb == TYstruct || rb == TYarray);
    }

    // Always allocate a shadow frame, even when empty — keeps code paths uniform.
    cg.hasShadowFrame = true;
    emitShadowPrologue(cg);

    // Spill incoming WASM params into their shadow-frame slots.
    foreach (ref sp; paramSpills)
    {
        cg.emitLocal(OP_LOCAL_GET, cg.shadowBaseLocal);
        cg.emitLocal(OP_LOCAL_GET, sp.wasmLocalIdx);
        const uint off = cast(uint) sp.sym.Soffset + sp.byteOffset;
        const m = memOpsFor(sp.ty);
        cg.emit(m.storeOp);
        cg.emitMemArg(m.alignLog2, off);
    }

    block* startblock = sfunc.Sfunc.Fstartblock;
    if (startblock)
        genBlocksProper(cg, startblock, hasReturn);

    if (cg.hasShadowFrame)
        emitShadowEpilogue(cg);

    // If the function returns a value but the body falls through (e.g. an
    // infinite loop), the implicit return at function end would underflow
    // the value stack.  Emit `unreachable` to mark the path as dead — the
    // WASM validator then accepts the missing return value.
    if (hasReturn)
        cg.emit(OP_UNREACHABLE);

    fb.locals = cg.locals;
    fb.numParams = cg.numParams;
    fb.codeRelocs = cg.codeRelocs;
    fb.dataAddrRelocs = cg.dataAddrRelocs;
    fb.code.reset();
    fb.code.write(cg.code.peekSlice());
}
