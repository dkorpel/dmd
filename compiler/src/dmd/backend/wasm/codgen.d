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
 *
 * Copyright:   Copyright (C) 1999-2026 by The D Language Foundation, All Rights Reserved
 * License:     $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/compiler/src/dmd/backend/wasm/codgen.d, _wasm/codgen.d)
 */

module dmd.backend.wasm.codgen;

import core.stdc.string : strlen;

import dmd.backend.cc;
import dmd.backend.cdef;
import dmd.backend.el;
import dmd.backend.oper;
import dmd.backend.ty;
import dmd.backend.type;
import dmd.backend.var : globsym;
import dmd.backend.wasm : R_WASM_FUNCTION_INDEX_LEB, R_WASM_TYPE_INDEX_LEB;
import dmd.backend.wasmobj : WasmFuncBody, wasmFuncBodies, WasmLocal;

import dmd.common.outbuffer;

nothrow:

/// WASM instruction opcodes (subset used by the codegen)
enum : ubyte
{
    // Control
    OP_UNREACHABLE = 0x00,
    OP_NOP = 0x01,
    OP_BLOCK = 0x02,
    OP_LOOP = 0x03,
    OP_IF = 0x04,
    OP_ELSE = 0x05,
    OP_END = 0x0B,
    OP_BR = 0x0C,
    OP_BR_IF = 0x0D,
    OP_BR_TABLE = 0x0E,
    OP_RETURN = 0x0F,
    // Call
    OP_CALL = 0x10,
    OP_CALL_INDIRECT = 0x11,
    OP_DROP = 0x1A,
    OP_SELECT = 0x1B,
    // Locals
    OP_LOCAL_GET = 0x20,
    OP_LOCAL_SET = 0x21,
    OP_LOCAL_TEE = 0x22,
    // Globals
    OP_GLOBAL_GET = 0x23,
    OP_GLOBAL_SET = 0x24,
    // Memory
    OP_I32_LOAD = 0x28,
    OP_I64_LOAD = 0x29,
    OP_F32_LOAD = 0x2A,
    OP_F64_LOAD = 0x2B,
    OP_I32_LOAD8_S = 0x2C,
    OP_I32_LOAD8_U = 0x2D,
    OP_I32_LOAD16_S = 0x2E,
    OP_I32_LOAD16_U = 0x2F,
    OP_I32_STORE = 0x36,
    OP_I64_STORE = 0x37,
    OP_F32_STORE = 0x38,
    OP_F64_STORE = 0x39,
    OP_I32_STORE8 = 0x3A,
    OP_I32_STORE16 = 0x3B,
    // Constants
    OP_I32_CONST = 0x41,
    OP_I64_CONST = 0x42,
    OP_F32_CONST = 0x43,
    OP_F64_CONST = 0x44,
    // i32 comparisons
    OP_I32_EQZ = 0x45,
    OP_I32_EQ = 0x46,
    OP_I32_NE = 0x47,
    OP_I32_LT_S = 0x48,
    OP_I32_LT_U = 0x49,
    OP_I32_GT_S = 0x4A,
    OP_I32_GT_U = 0x4B,
    OP_I32_LE_S = 0x4C,
    OP_I32_LE_U = 0x4D,
    OP_I32_GE_S = 0x4E,
    OP_I32_GE_U = 0x4F,
    // i64 comparisons
    OP_I64_EQZ = 0x50,
    OP_I64_EQ = 0x51,
    OP_I64_NE = 0x52,
    OP_I64_LT_S = 0x53,
    OP_I64_LT_U = 0x54,
    OP_I64_GT_S = 0x55,
    OP_I64_GT_U = 0x56,
    OP_I64_LE_S = 0x57,
    OP_I64_LE_U = 0x58,
    OP_I64_GE_S = 0x59,
    OP_I64_GE_U = 0x5A,
    // f32/f64 comparisons
    OP_F32_EQ = 0x5B,
    OP_F32_NE = 0x5C,
    OP_F32_LT = 0x5D,
    OP_F32_GT = 0x5E,
    OP_F32_LE = 0x5F,
    OP_F32_GE = 0x60,
    OP_F64_EQ = 0x61,
    OP_F64_NE = 0x62,
    OP_F64_LT = 0x63,
    OP_F64_GT = 0x64,
    OP_F64_LE = 0x65,
    OP_F64_GE = 0x66,
    // i32 arithmetic
    OP_I32_CLZ = 0x67,
    OP_I32_CTZ = 0x68,
    OP_I32_ADD = 0x6A,
    OP_I32_SUB = 0x6B,
    OP_I32_MUL = 0x6C,
    OP_I32_DIV_S = 0x6D,
    OP_I32_DIV_U = 0x6E,
    OP_I32_REM_S = 0x6F,
    OP_I32_REM_U = 0x70,
    OP_I32_AND = 0x71,
    OP_I32_OR = 0x72,
    OP_I32_XOR = 0x73,
    OP_I32_SHL = 0x74,
    OP_I32_SHR_S = 0x75,
    OP_I32_SHR_U = 0x76,
    OP_I32_ROTL = 0x77,
    OP_I32_ROTR = 0x78,
    // i64 arithmetic
    OP_I64_CLZ = 0x79,
    OP_I64_CTZ = 0x7A,
    OP_I64_ADD = 0x7C,
    OP_I64_SUB = 0x7D,
    OP_I64_MUL = 0x7E,
    OP_I64_DIV_S = 0x7F,
    OP_I64_DIV_U = 0x80,
    OP_I64_REM_S = 0x81,
    OP_I64_REM_U = 0x82,
    OP_I64_AND = 0x83,
    OP_I64_OR = 0x84,
    OP_I64_XOR = 0x85,
    OP_I64_SHL = 0x86,
    OP_I64_SHR_S = 0x87,
    OP_I64_SHR_U = 0x88,
    // f32 arithmetic
    OP_F32_ABS = 0x8B,
    OP_F32_NEG = 0x8C,
    OP_F32_SQRT = 0x91,
    OP_F32_ADD = 0x92,
    OP_F32_SUB = 0x93,
    OP_F32_MUL = 0x94,
    OP_F32_DIV = 0x95,
    // f64 arithmetic
    OP_F64_ABS = 0x99,
    OP_F64_NEG = 0x9A,
    OP_F64_SQRT = 0x9F,
    OP_F64_ADD = 0xA0,
    OP_F64_SUB = 0xA1,
    OP_F64_MUL = 0xA2,
    OP_F64_DIV = 0xA3,
    // Conversions
    OP_I32_WRAP_I64 = 0xA7,
    OP_I32_TRUNC_F32_S = 0xA8,
    OP_I32_TRUNC_F64_S = 0xAA,
    OP_I64_EXTEND_I32_S = 0xAC,
    OP_I64_EXTEND_I32_U = 0xAD,
    OP_I64_TRUNC_F32_S = 0xAE,
    OP_I64_TRUNC_F64_S = 0xB0,
    OP_F32_CONVERT_I32_S = 0xB2,
    OP_F32_CONVERT_I32_U = 0xB3,
    OP_F32_CONVERT_I64_S = 0xB4,
    OP_F32_DEMOTE_F64 = 0xB6,
    OP_F64_CONVERT_I32_S = 0xB7,
    OP_F64_CONVERT_I32_U = 0xB8,
    OP_F64_CONVERT_I64_S = 0xB9,
    OP_F64_PROMOTE_F32 = 0xBB,
    OP_I32_REINTERPRET_F32 = 0xBC,
    OP_I64_REINTERPRET_F64 = 0xBD,
    OP_F32_REINTERPRET_I32 = 0xBE,
    OP_F64_REINTERPRET_I64 = 0xBF,
    // Bulk-memory prefix (sub-opcode follows as ULEB128)
    OP_FC_PREFIX = 0xFC,
    // Sign extension (MVP extension)
    OP_I32_EXTEND8_S = 0xC0,
    OP_I32_EXTEND16_S = 0xC1,
    OP_I64_EXTEND8_S = 0xC2,
    OP_I64_EXTEND16_S = 0xC3,
    OP_I64_EXTEND32_S = 0xC4,
}

/// Value type bytes
enum : ubyte
{
    WASM_I32 = 0x7F,
    WASM_I64 = 0x7E,
    WASM_F32 = 0x7D,
    WASM_F64 = 0x7C
}

/// Block type for void blocks
enum ubyte WASM_VOID_BLOCK = 0x40;

// ---------------------------------------------------------------------------
// LEB128 helpers
// ---------------------------------------------------------------------------

private void uleb(OutBuffer* b, uint v) @trusted
{
    do
    {
        ubyte bt = v & 0x7F;
        v >>= 7;
        if (v)
            bt |= 0x80;
        b.writeByte(bt);
    }
    while (v);
}

private void sleb(OutBuffer* b, long v) @trusted
{
    bool more = true;
    while (more)
    {
        ubyte bt = v & 0x7F;
        v >>= 7;
        more = !((v == 0 && !(bt & 0x40)) || (v == -1 && (bt & 0x40)));
        if (more)
            bt |= 0x80;
        b.writeByte(bt);
    }
}

// ---------------------------------------------------------------------------
// WASM value type for a backend type
// ---------------------------------------------------------------------------

ubyte wasmType(tym_t ty) @trusted
{
    switch (tybasic(ty))
    {
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
    default:
        return WASM_I32; // int, pointer, bool, etc.
    }
}

// Shadow frame entry: maps a symbol to its byte offset in the shadow frame.
private struct ShadowEntry
{
    Symbol* sym;
    uint offset;
}

/// Per-function code-generation state
struct WasmCG
{
    OutBuffer code; /// bytecode being emitted
    WasmLocal[] locals; /// local variable table (params first)
    uint numParams; /// number of parameters (= first numParams locals)
    WasmFuncBody.CodeReloc[]    codeRelocs;     /// relocations for direct function calls
    WasmFuncBody.DataAddrReloc[] dataAddrRelocs; /// R_WASM_MEMORY_ADDR_LEB relocations

    // Shadow stack frame (for locals whose address is taken)
    bool hasShadowFrame;
    uint shadowBaseLocal; /// WASM local index holding the shadow frame base address
    uint shadowFrameSize; /// total size in bytes of shadow frame
    ShadowEntry[] shadowEntries; /// per-symbol shadow frame offsets

nothrow:

    // Allocate an anonymous temp local of the given WASM type
    uint allocTemp(ubyte ty) @trusted
    {
        WasmLocal l;
        l.sym = null;
        l.ty = ty;
        locals ~= l;
        return cast(uint)(locals.length - 1);
    }

    // Allocate or look up a local for a symbol; return its index
    uint localFor(Symbol* s) @trusted
    {
        foreach (size_t i, ref const WasmLocal l; locals)
            if (l.sym == s)
                return cast(uint) i;
        WasmLocal nl;
        nl.sym = s;
        nl.ty = wasmType(s.ty());
        locals ~= nl;
        return cast(uint)(locals.length - 1);
    }

    // Returns true if symbol s lives in the shadow frame.
    bool inShadow(Symbol* s) const @trusted
    {
        foreach (ref const ShadowEntry e; shadowEntries)
            if (e.sym == s)
                return true;
        return false;
    }

    // Returns the byte offset of s in the shadow frame (assumes inShadow).
    uint shadowOffset(Symbol* s) const @trusted
    {
        foreach (ref const ShadowEntry e; shadowEntries)
            if (e.sym == s)
                return e.offset;
        return 0;
    }

    // Register a symbol in the shadow frame (idempotent).
    void registerShadow(Symbol* s) @trusted
    {
        if (inShadow(s))
            return;
        // Compute size and alignment for the type.
        uint sz = 4, al = 4;
        if (s.Stype)
        {
            import dmd.backend.type : type_size, type_alignsize;

            targ_size_t ts = type_size(s.Stype);
            if (ts != targ_size_t.max && ts > 0)
                sz = cast(uint) ts;
            uint ta = type_alignsize(s.Stype);
            if (ta > 0 && ta <= 16)
                al = ta;
        }
        uint off = (shadowFrameSize + al - 1) & ~(al - 1);
        ShadowEntry se;
        se.sym = s;
        se.offset = off;
        shadowEntries ~= se;
        shadowFrameSize = off + sz;
    }

    void emit(ubyte b) @trusted
    {
        code.writeByte(b);
    }

    void emitULEB(uint v) @trusted
    {
        uleb(&code, v);
    }

    void emitSLEB(long v) @trusted
    {
        sleb(&code, v);
    }

    // Emit OP_I32_CONST with a data-segment address.
    // In relocatable mode, emits a 5-byte padded ULEB128 and records a
    // R_WASM_MEMORY_ADDR_LEB relocation so wasm-ld patches the address after
    // moving the data section to its final location.
    // In non-relocatable (final) mode, emits a compact SLEB128 — the data
    // section is already at its final address in that case.
    void emitDataAddr(Symbol* sym, uint addend) @trusted
    {
        import dmd.backend.wasmobj : wasm_relocatable;
        emit(OP_I32_CONST);
        const uint addr = cast(uint)(sym.Soffset + addend);
        // Only relocate symbols in the INITIALIZED data section (FL.data, FL.csdata,
        // FL.datseg).  BSS (FL.udata) variables have offsets relative to the BSS
        // region which is handled differently by wasm-ld; they don't map to a
        // valid offset in the single initialized data segment.
        // Only relocate symbols in the INITIALIZED data section.
        // BSS (FL.udata) and TLS (FL.tlsdata) have offsets beyond the active
        // data segment and don't map to valid WASM_SYMTAB_DATA entries in it.
        const bool canRelocate = wasm_relocatable && sym.Sident.ptr != null &&
            sym.Sfl != FL.udata && sym.Sfl != FL.tlsdata;
        if (canRelocate)
        {
            // 5-byte padded ULEB128 for wasm-ld relocation patching.
            dataAddrRelocs ~= WasmFuncBody.DataAddrReloc(cast(uint) code.length, sym, addend);
            code.writeByte(cast(ubyte)((addr & 0x7F) | 0x80));
            code.writeByte(cast(ubyte)(((addr >> 7) & 0x7F) | 0x80));
            code.writeByte(cast(ubyte)(((addr >> 14) & 0x7F) | 0x80));
            code.writeByte(cast(ubyte)(((addr >> 21) & 0x7F) | 0x80));
            code.writeByte(cast(ubyte)((addr >> 28) & 0x0F));
        }
        else
        {
            emitSLEB(cast(int) addr);
        }
    }

    // Emit OP_CALL with a 5-byte padded ULEB128 function index and record a
    // R_WASM_FUNCTION_INDEX_LEB relocation so wasm-ld can patch the index.
    // Symbol* is recorded so that if wmod.funcs is reordered before term time
    // (e.g. additional imports inserted), the relocation still resolves to the
    // intended symbol rather than a stale funcIdx.
    void emitCall(uint fidx, Symbol* sym = null) @trusted
    {
        emit(OP_CALL);
        codeRelocs ~= WasmFuncBody.CodeReloc(cast(uint) code.length,
            R_WASM_FUNCTION_INDEX_LEB, fidx, 0, sym);
        code.writeByte(cast(ubyte)((fidx & 0x7F) | 0x80));
        code.writeByte(cast(ubyte)(((fidx >> 7) & 0x7F) | 0x80));
        code.writeByte(cast(ubyte)(((fidx >> 14) & 0x7F) | 0x80));
        code.writeByte(cast(ubyte)(((fidx >> 21) & 0x7F) | 0x80));
        code.writeByte(cast(ubyte)((fidx >> 28) & 0x0F));
    }

    // Emit the type index operand of call_indirect.
    // In relocatable mode, emit R_WASM_TYPE_INDEX_LEB so wasm-ld can patch the
    // type index when merging type tables from multiple objects.  The relocation
    // references a named function whose type matches, preferring imports to avoid
    // a wasm-ld 22 crash on locally-defined symbol targets.  If no suitable
    // function is found yet (rare), fall back to compact ULEB without relocation
    // (type indices are stable for single-file linking via reorderImportTypesFirst).
    void emitCallIndirectType(uint typeIdx) @trusted
    {
        import dmd.backend.wasmobj : wmod_findFuncForType, wasm_relocatable;
        if (wasm_relocatable)
        {
            uint fidx = wmod_findFuncForType(typeIdx);
            if (fidx != uint.max)
            {
                codeRelocs ~= WasmFuncBody.CodeReloc(cast(uint) code.length,
                    R_WASM_TYPE_INDEX_LEB, fidx);
                // 5-byte padded ULEB128 so wasm-ld has room to write the patched index.
                code.writeByte(cast(ubyte)((typeIdx & 0x7F) | 0x80));
                code.writeByte(cast(ubyte)(((typeIdx >> 7) & 0x7F) | 0x80));
                code.writeByte(cast(ubyte)(((typeIdx >> 14) & 0x7F) | 0x80));
                code.writeByte(cast(ubyte)(((typeIdx >> 21) & 0x7F) | 0x80));
                code.writeByte(cast(ubyte)((typeIdx >> 28) & 0x0F));
                return;
            }
        }
        emitULEB(typeIdx); // single-file / no matching symbol: compact ULEB
    }

    void emitMemArg(uint align_, uint offset) @trusted
    {
        uleb(&code, align_); // alignment (log2)
        uleb(&code, offset); // byte offset
    }
}

// Emit a typed load from the address already on the stack.
// Per-type (load opcode, store opcode, natural-alignment log2).
// Load variants of narrow ints carry their signedness; stores share one op.
private struct MemOps { ubyte loadOp, storeOp, alignLog2; }
private MemOps memOpsFor(tym_t ty) @safe
{
    switch (tybasic(ty))
    {
        case TYllong, TYullong:                  return MemOps(OP_I64_LOAD,     OP_I64_STORE,   3);
        case TYfloat, TYifloat:                  return MemOps(OP_F32_LOAD,     OP_F32_STORE,   2);
        case TYdouble, TYdouble_alias,
             TYreal,   TYireal:                  return MemOps(OP_F64_LOAD,     OP_F64_STORE,   3);
        case TYchar, TYschar:                    return MemOps(OP_I32_LOAD8_S,  OP_I32_STORE8,  0);
        case TYuchar, TYbool:                    return MemOps(OP_I32_LOAD8_U,  OP_I32_STORE8,  0);
        case TYshort:                            return MemOps(OP_I32_LOAD16_S, OP_I32_STORE16, 1);
        case TYwchar_t, TYushort:                return MemOps(OP_I32_LOAD16_U, OP_I32_STORE16, 1);
        default:                                 return MemOps(OP_I32_LOAD,     OP_I32_STORE,   2);
    }
}

// Emit `memory.copy 0 0` (stack: dst, src, n → empty).
// Bulk-memory proposal — supported by every current wasm runtime.
private void emitMemoryCopy(ref WasmCG cg) @trusted
{
    cg.emit(OP_FC_PREFIX);
    cg.emitULEB(10); // memory.copy sub-opcode
    cg.emit(0x00);   // dst memidx
    cg.emit(0x00);   // src memidx
}

// Emit `memory.fill 0` (stack: dst, val, n → empty).
private void emitMemoryFill(ref WasmCG cg) @trusted
{
    cg.emit(OP_FC_PREFIX);
    cg.emitULEB(11); // memory.fill sub-opcode
    cg.emit(0x00);   // memidx
}

private void emitLoad(ref WasmCG cg, tym_t ty) @trusted
{
    const m = memOpsFor(ty);
    cg.emit(m.loadOp);
    cg.emitMemArg(m.alignLog2, 0);
}

// Emit a typed store (address then value already on stack).
private void emitStore(ref WasmCG cg, tym_t ty) @trusted
{
    const m = memOpsFor(ty);
    cg.emit(m.storeOp);
    cg.emitMemArg(m.alignLog2, 0);
}

// Emit a type coercion when a value's actual WASM type differs from what e.Ety expects.
// This handles cases where the optimizer elides explicit cast operators.
private void emitCoerce(ref WasmCG cg, ubyte from, ubyte to) @trusted
{
    if (from == to)
        return;
    if (from == WASM_I64 && to == WASM_I32)
    {
        cg.emit(OP_I32_WRAP_I64);
        return;
    }
    if (from == WASM_I32 && to == WASM_I64)
    {
        cg.emit(OP_I64_EXTEND_I32_S);
        return;
    }
    if (from == WASM_F32 && to == WASM_F64)
    {
        cg.emit(OP_F64_PROMOTE_F32);
        return;
    }
    if (from == WASM_F64 && to == WASM_F32)
    {
        cg.emit(OP_F32_DEMOTE_F64);
        return;
    }
    if (from == WASM_I32 && to == WASM_F32)
    {
        cg.emit(OP_F32_CONVERT_I32_S);
        return;
    }
    if (from == WASM_I32 && to == WASM_F64)
    {
        cg.emit(OP_F64_CONVERT_I32_S);
        return;
    }
    if (from == WASM_I64 && to == WASM_F64)
    {
        cg.emit(OP_F64_CONVERT_I64_S);
        return;
    }
    if (from == WASM_F32 && to == WASM_I32)
    {
        cg.emit(OP_I32_TRUNC_F32_S);
        return;
    }
    if (from == WASM_F64 && to == WASM_I32)
    {
        cg.emit(OP_I32_TRUNC_F64_S);
        return;
    }
    if (from == WASM_F64 && to == WASM_I64)
    {
        cg.emit(OP_I64_TRUNC_F64_S);
        return;
    }
    // Other combos: no-op (best effort)
}

// Returns true if a storage class indicates a global living in linear memory
// (initialized data, BSS, TLS, external, or a constant data segment).
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

// Returns true if a symbol's storage class means it needs a WASM local (not global mem).
private bool isLocalSym(Symbol* s) @trusted
{
    return !isDataSym(s.Sfl) && s.Sfl != FL.func;
}

// Walk the IR tree and pre-register any external function calls as imports.
// Must run before code generation so that import indices are stable across
// the whole module (call_indirect type indices are encoded as fixed-width
// LEBs, so they cannot grow after the fact).
void preRegisterExternals(elem* e) @trusted
{
    if (!e)
        return;
    const op = e.Eoper;
    if (OTleaf(op))
        return;
    if (op == OPcall || op == OPucall)
    {
        if (e.E1 && e.E1.Eoper == OPvar)
        {
            Symbol* s = e.E1.Vsym;
            if (s && s.Sclass != SC.auto_ && s.Sclass != SC.parameter &&
                s.Sclass != SC.fastpar)
                funcIndex(s); // side-effect: registers as import if not defined
        }
        if (e.E1) preRegisterExternals(e.E1);
        if (e.E2) preRegisterExternals(e.E2);
        return;
    }
    if (OTunary(op))
    {
        preRegisterExternals(e.E1);
        return;
    }
    preRegisterExternals(e.E1);
    preRegisterExternals(e.E2);
}

private void scanShadow(elem* e, ref WasmCG cg) @trusted
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

// Emit address of a shadow-frame symbol onto the value stack: local.get $base; i32.const offset; i32.add
private void emitShadowAddr(ref WasmCG cg, Symbol* s) @trusted
{
    cg.emit(OP_LOCAL_GET);
    cg.emitULEB(cg.shadowBaseLocal);
    uint off = cg.shadowOffset(s);
    if (off != 0)
    {
        cg.emit(OP_I32_CONST);
        cg.emitSLEB(cast(int) off);
        cg.emit(OP_I32_ADD);
    }
}

// Emit shadow stack frame prologue (called once at function entry).
// Creates the shadow base local, gets __stack_pointer, subtracts frame size, stores back.
private void emitShadowPrologue(ref WasmCG cg) @trusted
{
    import dmd.backend.wasmobj : wmod_getOrCreateStackPtrGlobal;

    uint spIdx = wmod_getOrCreateStackPtrGlobal();

    // Round frame size up to 16
    uint fsz = (cg.shadowFrameSize + 15) & ~15u;

    // Allocate a new local to hold the shadow base address
    cg.shadowBaseLocal = cg.allocTemp(WASM_I32);

    // Emit: shadow_base = __stack_pointer - frame_size; __stack_pointer = shadow_base
    cg.emit(OP_GLOBAL_GET);
    cg.emitULEB(spIdx);
    cg.emit(OP_I32_CONST);
    cg.emitSLEB(cast(int) fsz);
    cg.emit(OP_I32_SUB);
    cg.emit(OP_LOCAL_TEE);
    cg.emitULEB(cg.shadowBaseLocal);
    cg.emit(OP_GLOBAL_SET);
    cg.emitULEB(spIdx);
}

// Emit shadow stack frame epilogue (restore __stack_pointer).
private void emitShadowEpilogue(ref WasmCG cg) @trusted
{
    import dmd.backend.wasmobj : wmod_getOrCreateStackPtrGlobal;

    uint spIdx = wmod_getOrCreateStackPtrGlobal();
    uint fsz = (cg.shadowFrameSize + 15) & ~15u;

    // Emit: __stack_pointer = shadow_base + frame_size
    cg.emit(OP_LOCAL_GET);
    cg.emitULEB(cg.shadowBaseLocal);
    cg.emit(OP_I32_CONST);
    cg.emitSLEB(cast(int) fsz);
    cg.emit(OP_I32_ADD);
    cg.emit(OP_GLOBAL_SET);
    cg.emitULEB(spIdx);
}

// Expression code generation

// Returns: true if the expression has a result on the stack after genElem
private bool genElem(ref WasmCG cg, elem* e) @trusted
{
    if (!e)
        return false;

    const op = e.Eoper;

    switch (op)
    {
    case OPconst:
        {
            const ty = tybasic(e.Ety);
            switch (ty)
            {
            case TYllong:
            case TYullong:
            case TYcent:
            case TYucent:
                cg.emit(OP_I64_CONST);
                cg.emitSLEB(e.Vllong);
                break;
            case TYfloat:
            case TYifloat:
                {
                    cg.emit(OP_F32_CONST);
                    float f = e.Vfloat;
                    cg.code.write(&f, 4);
                    break;
                }
            case TYdouble:
            case TYdouble_alias:
            case TYidouble:
            case TYreal:
            case TYireal:
                {
                    cg.emit(OP_F64_CONST);
                    double d = e.Vdouble;
                    cg.code.write(&d, 8);
                    break;
                }
            default:
                cg.emit(OP_I32_CONST);
                cg.emitSLEB(cast(int) e.Vlong);
                break;
            }
            return true;
        }

    case OPvar:
        {
            Symbol* s = e.Vsym;
            // Globals live in linear memory; locals/params live in WASM locals.
            if (isDataSym(s.Sfl))
            {
                cg.emitDataAddr(s, cast(uint) e.Voffset);
                emitLoad(cg, e.Ety);
                return true;
            }
            // Shadow-frame locals: load from linear memory.
            if (cg.inShadow(s))
            {
                emitShadowAddr(cg, s);
                if (e.Voffset != 0)
                {
                    cg.emit(OP_I32_CONST);
                    cg.emitSLEB(cast(int) e.Voffset);
                    cg.emit(OP_I32_ADD);
                }
                emitLoad(cg, e.Ety);
                return true;
            }
            const uint idx = cg.localFor(s);
            cg.emit(OP_LOCAL_GET);
            cg.emitULEB(idx);
            // For i64 locals (packed structs like D slices): field access via Voffset.
            // D slice layout: {size_t len (offset 0), T* ptr (offset 4)} packed as i64.
            //   Voffset=0 → low 32 bits (len)  → i32.wrap_i64
            //   Voffset=4 → high 32 bits (ptr) → i64.shr_u 32; i32.wrap_i64
            if (cg.locals[idx].ty == WASM_I64 && e.Voffset == 4)
            {
                cg.emit(OP_I64_CONST);
                cg.emitSLEB(32);
                cg.emit(OP_I64_SHR_U);
            }
            // Coerce if expression type differs from the local's stored type.
            emitCoerce(cg, cg.locals[idx].ty, wasmType(e.Ety));
            return true;
        }

    case OPrelconst:
        {
            Symbol* rs = e.Vsym;
            if (rs && isLocalSym(rs) && cg.inShadow(rs))
            {
                // Address of a shadow-frame local.
                emitShadowAddr(cg, rs);
                if (e.Voffset != 0)
                {
                    cg.emit(OP_I32_CONST);
                    cg.emitSLEB(cast(int) e.Voffset);
                    cg.emit(OP_I32_ADD);
                }
            }
            else if (rs && rs.Sfl == FL.func)
            {
                // Address of a function → WASM table index for call_indirect.
                import dmd.backend.wasmobj : wmod_funcTableIndex;

                uint tidx = wmod_funcTableIndex(rs);
                cg.emit(OP_I32_CONST);
                cg.emitSLEB(cast(int) tidx);
            }
            else
            {
                // Address of a global in linear memory.
                cg.emitDataAddr(rs, cast(uint) e.Voffset);
            }
            return true;
        }

    case OPaddr:
        {
            // Address-of operator: OPaddr(OPvar(x)) for local x.
            if (e.E1 && e.E1.Eoper == OPvar)
            {
                Symbol* as = e.E1.Vsym;
                if (as && isLocalSym(as) && cg.inShadow(as))
                {
                    emitShadowAddr(cg, as);
                    return true;
                }
            }
            // Fallback: just evaluate E1 address (e.g., OPaddr of global)
            return genElem(cg, e.E1);
        }

    case OPind:
        {
            genElem(cg, e.E1); // address on stack
            emitLoad(cg, e.Ety);
            return true;
        }

    case OPeq:
        {
            if (e.E1.Eoper == OPvar)
            {
                Symbol* lhs = e.E1.Vsym;
                if (isDataSym(lhs.Sfl))
                {
                    // Store to global in linear memory
                    cg.emitDataAddr(lhs, cast(uint) e.E1.Voffset);
                    genElem(cg, e.E2);
                    emitStore(cg, e.E1.Ety);
                    // Re-load for expression result
                    cg.emitDataAddr(lhs, cast(uint) e.E1.Voffset);
                    emitLoad(cg, e.E1.Ety);
                    return true;
                }
                // Shadow-frame local: store to linear memory, reload for result.
                if (cg.inShadow(lhs))
                {
                    emitShadowAddr(cg, lhs);
                    if (e.E1.Voffset != 0)
                    {
                        cg.emit(OP_I32_CONST);
                        cg.emitSLEB(cast(int) e.E1.Voffset);
                        cg.emit(OP_I32_ADD);
                    }
                    genElem(cg, e.E2);
                    emitStore(cg, e.E1.Ety);
                    emitShadowAddr(cg, lhs);
                    emitLoad(cg, e.E1.Ety);
                    return true;
                }
                const uint idx = cg.localFor(lhs);
                genElem(cg, e.E2);
                // Coerce i32→i64 if needed (e.g. assigning integer to ulong local).
                if (cg.locals[idx].ty == WASM_I64 && wasmType(e.E2.Ety) == WASM_I32)
                    cg.emit(OP_I64_EXTEND_I32_S);
                // Mask if storing into a narrow-type local (ubyte, bool, short, etc.).
                switch (tybasic(e.E1.Ety))
                {
                case TYbool:
                case TYchar:
                case TYschar:
                case TYuchar:
                case TYchar8:
                    cg.emit(OP_I32_CONST);
                    cg.emitSLEB(0xFF);
                    cg.emit(OP_I32_AND);
                    break;
                case TYshort:
                case TYwchar_t:
                case TYushort:
                case TYchar16:
                    cg.emit(OP_I32_CONST);
                    cg.emitSLEB(0xFFFF);
                    cg.emit(OP_I32_AND);
                    break;
                default:
                    break;
                }
                cg.emit(OP_LOCAL_TEE);
                cg.emitULEB(idx);
                return true;
            }
            else if (e.E1.Eoper == OPind)
            {
                // Store to memory. Save result in a temp to avoid re-evaluating
                // E2 (which may have side effects like i++ in arr[k++] = L[i++]).
                genElem(cg, e.E1.E1); // address
                genElem(cg, e.E2); // value
                uint valTmp = cg.allocTemp(wasmType(e.Ety));
                cg.emit(OP_LOCAL_TEE);
                cg.emitULEB(valTmp); // save, keep on stack
                emitStore(cg, e.E1.Ety); // store [addr, val]
                cg.emit(OP_LOCAL_GET);
                cg.emitULEB(valTmp); // result
                return true;
            }
            // Fallthrough: unsupported, just evaluate RHS
            genElem(cg, e.E2);
            return true;
        }

        // ---- Compound assignment operators ------------------------------------
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
            // Desugar: lhs op= rhs  =>  lhs = lhs op rhs
            if (e.E1.Eoper == OPvar)
            {
                Symbol* s = e.E1.Vsym;
                if (isDataSym(s.Sfl))
                {
                    // Global: load, op, store, load-result
                    const uint addend = cast(uint) e.E1.Voffset;
                    cg.emitDataAddr(s, addend);
                    cg.emitDataAddr(s, addend);
                    emitLoad(cg, e.E1.Ety);
                    genElem(cg, e.E2);
                    emitBinop(cg, compoundToBinop(op), e.Ety);
                    emitStore(cg, e.E1.Ety);
                    cg.emitDataAddr(s, addend);
                    emitLoad(cg, e.E1.Ety);
                    return true;
                }
                // Shadow-frame local compound assignment.
                if (cg.inShadow(s))
                {
                    emitShadowAddr(cg, s);
                    emitLoad(cg, e.E1.Ety);
                    genElem(cg, e.E2);
                    emitBinop(cg, compoundToBinop(op), e.Ety);
                    emitShadowAddr(cg, s);
                    // swap addr and value using temp
                    uint valTmp2 = cg.allocTemp(wasmType(e.Ety));
                    cg.emit(OP_LOCAL_SET);
                    cg.emitULEB(valTmp2);
                    cg.emit(OP_LOCAL_GET);
                    cg.emitULEB(valTmp2);
                    emitStore(cg, e.E1.Ety);
                    emitShadowAddr(cg, s);
                    emitLoad(cg, e.E1.Ety);
                    return true;
                }
                const uint idx = cg.localFor(s);
                cg.emit(OP_LOCAL_GET);
                cg.emitULEB(idx);
                genElem(cg, e.E2);
                emitBinop(cg, compoundToBinop(op), e.Ety);
                // Mask for narrow types (ubyte, ushort, etc.) to preserve wrapping.
                switch (tybasic(e.E1.Ety))
                {
                case TYbool:
                case TYchar:
                case TYschar:
                case TYuchar:
                case TYchar8:
                    cg.emit(OP_I32_CONST);
                    cg.emitSLEB(0xFF);
                    cg.emit(OP_I32_AND);
                    break;
                case TYshort:
                case TYwchar_t:
                case TYushort:
                case TYchar16:
                    cg.emit(OP_I32_CONST);
                    cg.emitSLEB(0xFFFF);
                    cg.emit(OP_I32_AND);
                    break;
                default:
                    break;
                }
                cg.emit(OP_LOCAL_TEE);
                cg.emitULEB(idx);
                return true;
            }
            if (e.E1.Eoper == OPind)
            {
                // *ptr op= rhs : load ptr, dup, load, op, store, load-result
                // Need ptr evaluated once; use a temp local for it
                genElem(cg, e.E1.E1); // ptr addr on stack
                // Duplicate addr via a temp local
                uint tmp = cg.allocTemp(WASM_I32);
                cg.emit(OP_LOCAL_TEE);
                cg.emitULEB(tmp);
                emitLoad(cg, e.E1.Ety);
                genElem(cg, e.E2);
                emitBinop(cg, compoundToBinop(op), e.Ety);
                // Now: result on stack. Store then reload.
                // We need addr again: local.get tmp; swap; store; local.get tmp; load
                uint valTmp = cg.allocTemp(wasmType(e.Ety));
                cg.emit(OP_LOCAL_SET);
                cg.emitULEB(valTmp);
                cg.emit(OP_LOCAL_GET);
                cg.emitULEB(tmp);
                cg.emit(OP_LOCAL_GET);
                cg.emitULEB(valTmp);
                emitStore(cg, e.E1.Ety);
                cg.emit(OP_LOCAL_GET);
                cg.emitULEB(tmp);
                emitLoad(cg, e.E1.Ety);
                return true;
            }
            genElem(cg, e.E2);
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
        {
            const ubyte rty = wasmType(e.Ety);
            genElem(cg, e.E1);
            emitCoerce(cg, wasmType(e.E1.Ety), rty);
            genElem(cg, e.E2);
            emitCoerce(cg, wasmType(e.E2.Ety), rty);
            emitBinop(cg, op, e.Ety);
            return true;
        }

    case OPeqeq:
    case OPne:
    case OPlt:
    case OPle:
    case OPgt:
    case OPge:
        {
            const ubyte cmpTy = wasmType(e.E1.Ety);
            genElem(cg, e.E1);
            genElem(cg, e.E2);
            emitCoerce(cg, wasmType(e.E2.Ety), cmpTy);
            emitRelop(cg, op, e.E1.Ety);
            return true;
        }

    case OPneg:
        {
            const ty = tybasic(e.Ety);
            if (ty == TYfloat)
            {
                genElem(cg, e.E1);
                cg.emit(OP_F32_NEG);
            }
            else if (ty == TYdouble || ty == TYdouble_alias || ty == TYreal)
            {
                genElem(cg, e.E1);
                cg.emit(OP_F64_NEG);
            }
            else if (ty == TYllong || ty == TYullong)
            {
                // i64.neg = 0 - x
                cg.emit(OP_I64_CONST);
                cg.emitSLEB(0);
                genElem(cg, e.E1);
                cg.emit(OP_I64_SUB);
            }
            else
            {
                cg.emit(OP_I32_CONST);
                cg.emitSLEB(0);
                genElem(cg, e.E1);
                cg.emit(OP_I32_SUB);
            }
            return true;
        }

    case OPnot:
        {
            genElem(cg, e.E1);
            const ty = tybasic(e.E1.Ety);
            if (ty == TYllong || ty == TYullong)
                cg.emit(OP_I64_EQZ);
            else
                cg.emit(OP_I32_EQZ);
            return true;
        }

    case OPcom:
        {
            genElem(cg, e.E1);
            const ty = tybasic(e.Ety);
            if (ty == TYllong || ty == TYullong)
            {
                cg.emit(OP_I64_CONST);
                cg.emitSLEB(-1);
                cg.emit(OP_I64_XOR);
            }
            else
            {
                cg.emit(OP_I32_CONST);
                cg.emitSLEB(-1);
                cg.emit(OP_I32_XOR);
            }
            return true;
        }

    case OPu16_32:
    case OPs16_32:
    case OPu8_16:
    case OPs8_16:
        {
            genElem(cg, e.E1);
            if (op == OPs8_16)
            {
                cg.emit(OP_I32_EXTEND8_S);
            }
            else if (op == OPs16_32)
            {
                cg.emit(OP_I32_EXTEND16_S);
            }
            // unsigned widening: already zero-extended as i32 — no-op
            return true;
        }

    case OPu32_64:
        {
            genElem(cg, e.E1);
            cg.emit(OP_I64_EXTEND_I32_U);
            return true;
        }
    case OPs32_64:
        {
            genElem(cg, e.E1);
            cg.emit(OP_I64_EXTEND_I32_S);
            return true;
        }
    case OP64_32:
        {
            genElem(cg, e.E1);
            cg.emit(OP_I32_WRAP_I64);
            return true;
        }
    case OPmsw:
        {
            // Extract high 32 bits of a 64-bit value (ptr part of D slice on wasm32).
            genElem(cg, e.E1);
            cg.emit(OP_I64_CONST);
            cg.emitSLEB(32);
            cg.emit(OP_I64_SHR_U);
            cg.emit(OP_I32_WRAP_I64);
            return true;
        }
    case OP16_8:
        {
            // Truncate 16→8 bit (e.g. cast(char)(expr)). Mask low 8 bits.
            genElem(cg, e.E1);
            cg.emit(OP_I32_CONST);
            cg.emitSLEB(0xFF);
            cg.emit(OP_I32_AND);
            return true;
        }
    case OP32_16:
        {
            // Truncate 32→16 bit (e.g. cast(short)(expr)). Mask low 16 bits.
            genElem(cg, e.E1);
            cg.emit(OP_I32_CONST);
            cg.emitSLEB(0xFFFF);
            cg.emit(OP_I32_AND);
            return true;
        }

    case OPd_f:
        {
            genElem(cg, e.E1);
            cg.emit(OP_F32_DEMOTE_F64);
            return true;
        }
    case OPf_d:
        {
            genElem(cg, e.E1);
            cg.emit(OP_F64_PROMOTE_F32);
            return true;
        }

    case OPd_s32:
        {
            genElem(cg, e.E1);
            cg.emit(OP_I32_TRUNC_F64_S);
            return true;
        }
    case OPd_s64:
        {
            genElem(cg, e.E1);
            cg.emit(OP_I64_TRUNC_F64_S);
            return true;
        }
    case OPs32_d:
        {
            genElem(cg, e.E1);
            cg.emit(OP_F64_CONVERT_I32_S);
            return true;
        }
    case OPs64_d:
        {
            genElem(cg, e.E1);
            cg.emit(OP_F64_CONVERT_I64_S);
            return true;
        }
    case OPu32_d:
        {
            genElem(cg, e.E1);
            cg.emit(OP_F64_CONVERT_I32_U);
            return true;
        }
    case OPu64_d:
        {
            genElem(cg, e.E1);
            cg.emit(OP_F64_CONVERT_I64_S);
            return true;
        }

    case OPcomma:
        {
            const bool r1 = genElem(cg, e.E1);
            if (r1)
                cg.emit(OP_DROP); // discard left-hand result
            return genElem(cg, e.E2);
        }

    case OPcall:
    case OPucall:
        {
            // E1 is the function.
            // Direct call: E1 is OPvar of a function symbol.
            if (e.E1.Eoper == OPvar && e.E1.Vsym && e.E1.Vsym.Sclass != SC.auto_ &&
                e.E1.Vsym.Sclass != SC.parameter && e.E1.Vsym.Sclass != SC.fastpar)
            {
                import dmd.backend.type : variadic;
                import dmd.backend.cc : param_t;
                import dmd.backend.wasmobj : wmod_fixImportType, wmod_getOrCreateStackPtrGlobal;

                Symbol* calleeSym = e.E1.Vsym;
                uint fidx = funcIndex(calleeSym);
                const bool isCVariadic = calleeSym.Stype !is null && variadic(calleeSym.Stype);

                if (isCVariadic)
                {
                    // C variadic ABI (matches LDC2/wasi-libc): variadic args are spilled
                    // to a shadow stack frame; a pointer to that frame is passed as the
                    // last i32 parameter after all fixed args.  When there are no variadic
                    // args the pointer is null (i32.const 0).
                    //
                    // C default promotions apply inside `...`:
                    //   float  → double (f64)
                    //   char/short → int (i32)

                    // Collect all args left-to-right (E2-first in OPparam tree).
                    elem*[] allArgs;
                    void gatherArgs(elem* p) nothrow @trusted
                    {
                        if (!p)
                            return;
                        if (p.Eoper == OPparam)
                        {
                            gatherArgs(p.E2);
                            gatherArgs(p.E1);
                        }
                        else
                            allArgs ~= p;
                    }
                    gatherArgs(e.E2);

                    // Count fixed (non-variadic) params from the function type.
                    int nFixed = 0;
                    for (param_t* p = calleeSym.Stype.Tparamtypes; p; p = p.Pnext)
                        nFixed++;

                    // Emit fixed args to the WASM value stack.
                    foreach (a; allArgs[0 .. nFixed])
                        genOneArg(cg, a);

                    // Compute variadic args layout and emit shadow-stack spill.
                    elem*[] varArgs = allArgs[nFixed .. $];
                    uint spLocal = uint.max;
                    uint vaFrameSize = 0;

                    if (varArgs.length > 0)
                    {
                        struct VaSlot { elem* e; uint off; ubyte storeOp; uint alignLog2; bool promoteF32; }
                        VaSlot[] slots;
                        uint offset = 0;
                        foreach (va; varArgs)
                        {
                            ubyte storeOp;
                            uint sz, al;
                            bool promF32 = false;
                            switch (tybasic(va.Ety))
                            {
                            case TYllong:
                            case TYullong:
                                storeOp = OP_I64_STORE; sz = 8; al = 3; break;
                            case TYdouble:
                            case TYdouble_alias:
                            case TYreal:
                            case TYireal:
                                storeOp = OP_F64_STORE; sz = 8; al = 3; break;
                            case TYfloat:
                            case TYifloat:
                                // C promotes float to double in varargs
                                storeOp = OP_F64_STORE; sz = 8; al = 3; promF32 = true; break;
                            default:
                                storeOp = OP_I32_STORE; sz = 4; al = 2; break;
                            }
                            uint byteAlign = 1u << al;
                            offset = (offset + byteAlign - 1) & ~(byteAlign - 1);
                            slots ~= VaSlot(va, offset, storeOp, al, promF32);
                            offset += sz;
                        }
                        vaFrameSize = (offset + 15) & ~15;

                        // Allocate shadow stack frame for varargs.
                        uint spIdx = wmod_getOrCreateStackPtrGlobal();
                        spLocal = cg.allocTemp(WASM_I32);
                        cg.emit(OP_GLOBAL_GET);
                        cg.emitULEB(spIdx);
                        cg.emit(OP_I32_CONST);
                        cg.emitSLEB(cast(int) vaFrameSize);
                        cg.emit(OP_I32_SUB);
                        cg.emit(OP_LOCAL_TEE);
                        cg.emitULEB(spLocal);
                        cg.emit(OP_GLOBAL_SET);
                        cg.emitULEB(spIdx);

                        // Store each variadic arg into the frame.
                        foreach (ref sl; slots)
                        {
                            cg.emit(OP_LOCAL_GET);
                            cg.emitULEB(spLocal);   // addr
                            genElem(cg, sl.e);       // value
                            if (sl.promoteF32)
                                cg.emit(OP_F64_PROMOTE_F32);
                            cg.emit(sl.storeOp);
                            cg.emitMemArg(sl.alignLog2, sl.off);
                        }

                        // Push varargs pointer as the last parameter.
                        cg.emit(OP_LOCAL_GET);
                        cg.emitULEB(spLocal);
                    }
                    else
                    {
                        // No variadic args: pass null pointer per LDC2 convention.
                        cg.emit(OP_I32_CONST);
                        cg.emitSLEB(0);
                    }

                    // Register import type: (fixed_params..., i32 varargs_ptr) -> result.
                    {
                        ubyte[] aparams;
                        foreach (a; allArgs[0 .. nFixed])
                        {
                            if (isSliceElem(a))
                            {
                                aparams ~= WASM_I32;
                                aparams ~= WASM_I32;
                            }
                            else
                                aparams ~= wasmType(tybasic(a.Ety));
                        }
                        aparams ~= WASM_I32; // varargs ptr
                        const tym_t retTy2 = tybasic(e.Ety);
                        ubyte[] aresults;
                        if (retTy2 != TYvoid && retTy2 != TYnoreturn)
                            aresults ~= wasmType(retTy2);
                        wmod_fixImportType(fidx, aparams, aresults);
                    }

                    cg.emitCall(fidx, calleeSym);

                    // Restore __stack_pointer after the call.
                    if (spLocal != uint.max)
                    {
                        uint spIdx = wmod_getOrCreateStackPtrGlobal();
                        cg.emit(OP_LOCAL_GET);
                        cg.emitULEB(spLocal);
                        cg.emit(OP_I32_CONST);
                        cg.emitSLEB(cast(int) vaFrameSize);
                        cg.emit(OP_I32_ADD);
                        cg.emit(OP_GLOBAL_SET);
                        cg.emitULEB(spIdx);
                    }

                    if (calleeSym.Sflags & SFLexit)
                        cg.emit(OP_UNREACHABLE);
                }
                else
                {
                    // Non-variadic direct call.
                    // Gather args left-to-right (OPparam tree is right-to-left at top).
                    elem*[] callArgs;
                    void gatherCallArgs(elem* p) nothrow @trusted
                    {
                        if (!p)
                            return;
                        if (p.Eoper == OPparam)
                        {
                            gatherCallArgs(p.E2);
                            gatherCallArgs(p.E1);
                            return;
                        }
                        callArgs ~= p;
                    }
                    gatherCallArgs(e.E2);

                    // Walk param chain in parallel: a slice param forces split even when
                    // the elem itself isn't recognised as a slice (e.g. OPconst null).
                    param_t* pp = (calleeSym.Stype !is null) ? calleeSym.Stype.Tparamtypes : null;
                    ubyte[] aparams;
                    foreach (a; callArgs)
                    {
                        const bool sliceParam = paramIsSlice(pp);
                        const bool asSlice = sliceParam || isSliceElem(a);
                        genOneArg(cg, a, sliceParam);
                        if (asSlice)
                        {
                            aparams ~= WASM_I32;
                            aparams ~= WASM_I32;
                        }
                        else
                            aparams ~= wasmType(tybasic(a.Ety));
                        if (pp)
                            pp = pp.Pnext;
                    }

                    // Runtime symbols (memcmp, __assert, etc.) are registered with a
                    // generic empty type because rtlsym.d uses type_fake(TYnfunc). Fix
                    // the import type from the actual call-site argument/return types.
                    {
                        const tym_t retTy2 = tybasic(e.Ety);
                        ubyte[] aresults;
                        if (retTy2 != TYvoid && retTy2 != TYnoreturn)
                            aresults ~= wasmType(retTy2);
                        wmod_fixImportType(fidx, aparams, aresults);
                    }
                    cg.emitCall(fidx, calleeSym);
                    // Noreturn (SFLexit) functions leave the stack empty. Emit unreachable
                    // so WASM's type checker accepts any type expectations after the call.
                    if (calleeSym.Sflags & SFLexit)
                        cg.emit(OP_UNREACHABLE);
                }
            }
            else
            {
                // Indirect call through a function pointer (call_indirect).
                // D IR: OPucall(OPind(OPvar(fptr)), args) — the OPind dereferences the
                // pointer-to-function; in WASM we use the table index directly without
                // loading from memory.
                import dmd.backend.wasmobj : wmod_internFuncPtrType;

                uint typeIdx = 0;
                elem* fexpr = e.E1;
                Symbol* fpSym = null;
                if (fexpr.Eoper == OPind && fexpr.E1 && fexpr.E1.Eoper == OPvar)
                {
                    // OPind(OPvar(fptr)) — fptr holds a table index.
                    // For WASM locals: load the local value directly.
                    // For globals (FL.data etc.): load the table index from linear memory.
                    fpSym = fexpr.E1.Vsym;
                    if (fpSym && fpSym.Stype)
                        typeIdx = wmod_internFuncPtrType(fpSym.Stype);
                    if (fpSym && isLocalSym(fpSym) && !cg.inShadow(fpSym))
                    {
                        // Local variable: its value IS the table index.
                        const uint idx = cg.localFor(fpSym);
                        cg.emit(OP_LOCAL_GET);
                        cg.emitULEB(idx);
                    }
                    else
                    {
                        // Global variable: load table index from linear memory.
                        genElem(cg, fexpr.E1); // push address or value
                        // If it loaded a value (for FL.data OPvar emits load), we're done.
                        // If it only pushed an address (shadow/relconst), emit a load too.
                    }
                }
                else
                {
                    // For virtual dispatch and function pointer calls, the outermost
                    // OPind is semantic ("call through pointer"), not a memory load.
                    // Strip it so we evaluate the inner expression to get the table index.
                    elem* fn = (fexpr.Eoper == OPind) ? fexpr.E1 : fexpr;
                    if (fn.Eoper == OPvar && fn.Vsym && fn.Vsym.Stype)
                    {
                        typeIdx = wmod_internFuncPtrType(fn.Vsym.Stype);
                    }
                    else
                    {
                        // Virtual dispatch: derive the call type from the call expression.
                        // Params come from e.E2 (already pushed above); return from e.Ety.
                        // Build a WASM type that matches what was registered for the method.
                        import dmd.backend.wasmobj : wmod_internType;

                        ubyte[] params;
                        void collectArgTypes(elem* p) nothrow @trusted
                        {
                            if (!p)
                                return;
                            if (p.Eoper == OPparam)
                            {
                                collectArgTypes(p.E2);
                                collectArgTypes(p.E1);
                                return;
                            }
                            if (isSliceElem(p)) // D slice splits into (len, ptr)
                            {
                                params ~= WASM_I32;
                                params ~= WASM_I32;
                            }
                            else
                                params ~= wasmType(tybasic(p.Ety));
                        }

                        collectArgTypes(e.E2);
                        ubyte[] results;
                        const tym_t retTy = tybasic(e.Ety);
                        if (retTy != TYvoid && retTy != TYnoreturn)
                            results ~= wasmType(retTy);
                        typeIdx = wmod_internType(params, results);
                    }
                    genElem(cg, fn);
                }
                cg.emit(OP_CALL_INDIRECT);
                cg.emitCallIndirectType(typeIdx);
                cg.emitULEB(0); // table index 0
            }
            const retTy = tybasic(e.Ety);
            return retTy != TYvoid;
        }

    case OPcond:
        {
            // e.E1 ? e.E2.E1 : e.E2.E2
            genElem(cg, e.E1);
            const ubyte rty = wasmType(e.Ety);
            cg.emit(OP_IF);
            cg.emit(rty);
            genElem(cg, e.E2.E1);
            cg.emit(OP_ELSE);
            genElem(cg, e.E2.E2);
            cg.emit(OP_END);
            return tybasic(e.Ety) != TYvoid;
        }

    case OPoror:
        {
            // a || b  =>  if (a) 1 else (b != 0)
            genElem(cg, e.E1);
            cg.emit(OP_IF);
            cg.emit(WASM_I32);
            cg.emit(OP_I32_CONST);
            cg.emitSLEB(1);
            cg.emit(OP_ELSE);
            genElem(cg, e.E2);
            cg.emit(OP_I32_CONST);
            cg.emitSLEB(0);
            cg.emit(OP_I32_NE);
            cg.emit(OP_END);
            return true;
        }

    case OPandand:
        {
            // a && b  =>  if (a) (b != 0) else 0
            genElem(cg, e.E1);
            cg.emit(OP_IF);
            cg.emit(WASM_I32);
            genElem(cg, e.E2);
            cg.emit(OP_I32_CONST);
            cg.emitSLEB(0);
            cg.emit(OP_I32_NE);
            cg.emit(OP_ELSE);
            cg.emit(OP_I32_CONST);
            cg.emitSLEB(0);
            cg.emit(OP_END);
            return true;
        }

        // ---- Bool conversion (while/for conditions) --------------------------
    case OPbool:
        {
            genElem(cg, e.E1);
            // Convert to bool: nonzero => 1, zero => 0
            // WASM i32: x != 0 is equivalent to i32.const 0; i32.ne
            const ty = tybasic(e.E1.Ety);
            if (ty == TYllong || ty == TYullong)
            {
                cg.emit(OP_I64_EQZ); // i64 => i32 (1 if zero)
                cg.emit(OP_I32_EQZ); // invert: 1 if nonzero
            }
            else
            {
                cg.emit(OP_I32_CONST);
                cg.emitSLEB(0);
                cg.emit(OP_I32_NE);
            }
            return true;
        }

    case OPb_8:
        genElem(cg, e.E1); // bool is already 0/1 as i32
        return true;

    case OPhalt:
        cg.emit(OP_UNREACHABLE);
        return false;

    case OPvoid:
        return false;

    case OPinfo:
        // Optimizer annotation, no code
        return genElem(cg, e.E2); // only the right child has the value

    case OPsizeof:
        // Sizeof (compile-time constant, should be folded)
        cg.emit(OP_I32_CONST);
        cg.emitSLEB(cast(int) e.Vlong);
        return true;

    case OPpostinc:
    case OPpostdec:
        {
            if (e.E1.Eoper == OPvar)
            {
                const uint idx = cg.localFor(e.E1.Vsym);
                cg.emit(OP_LOCAL_GET);
                cg.emitULEB(idx); // old value (result)
                cg.emit(OP_LOCAL_GET);
                cg.emitULEB(idx);
                genElem(cg, e.E2);
                emitBinop(cg, op == OPpostinc ? OPadd : OPmin, e.Ety);
                cg.emit(OP_LOCAL_SET);
                cg.emitULEB(idx);
                return true;
            }
            genElem(cg, e.E1);
            return true;
        }

    case OPpreinc:
    case OPpredec:
        {
            if (e.E1.Eoper == OPvar)
            {
                const uint idx = cg.localFor(e.E1.Vsym);
                cg.emit(OP_LOCAL_GET);
                cg.emitULEB(idx);
                genElem(cg, e.E2);
                emitBinop(cg, op == OPpreinc ? OPadd : OPmin, e.Ety);
                cg.emit(OP_LOCAL_TEE);
                cg.emitULEB(idx);
                return true;
            }
            genElem(cg, e.E1);
            return true;
        }

    case OPpair:
    case OPrpair:
        {
            // For i64 results (D slices, long long): pack two i32 halves into one i64.
            // OPpair:  E1=lo (len), E2=hi (ptr) → i64 = (E2<<32) | E1
            // OPrpair: E1=hi (ptr), E2=lo (len) → i64 = (E1<<32) | E2
            const tym_t resultTy = tybasic(e.Ety);
            if (resultTy == TYullong || resultTy == TYllong)
            {
                elem* loE = (e.Eoper == OPrpair) ? e.E2 : e.E1;
                elem* hiE = (e.Eoper == OPrpair) ? e.E1 : e.E2;
                genElem(cg, hiE);
                cg.emit(OP_I64_EXTEND_I32_U);
                cg.emit(OP_I64_CONST);
                cg.emitSLEB(32);
                cg.emit(OP_I64_SHL);
                genElem(cg, loE);
                cg.emit(OP_I64_EXTEND_I32_U);
                cg.emit(OP_I64_OR);
                return true;
            }
            // Other (multi-value): push both separately.
            genElem(cg, e.E1);
            genElem(cg, e.E2);
            return true;
        }

    case OPstreq:
        {
            // Struct assignment: copy type_size(e.ET) bytes from E2 to E1.
            // Result: the destination address (i32) for chained assignment.
            import dmd.backend.type : type_size;

            uint sz = e.ET ? cast(uint) type_size(e.ET) : 0;
            if (sz == 0)
                return false;
            uint dstTmp = cg.allocTemp(WASM_I32);
            genElemAddr(cg, e.E1);
            cg.emit(OP_LOCAL_TEE);
            cg.emitULEB(dstTmp);              // stack: dst
            genElemAddr(cg, e.E2);            // stack: dst, src
            cg.emit(OP_I32_CONST);
            cg.emitSLEB(sz);                  // stack: dst, src, n
            emitMemoryCopy(cg);
            cg.emit(OP_LOCAL_GET);
            cg.emitULEB(dstTmp);              // result: dst
            return true;
        }

    case OPmemcpy:
        {
            // IR: OPmemcpy(dst, OPparam(count, src)). Result is dst.
            uint dstTmp = cg.allocTemp(WASM_I32);
            genElem(cg, e.E1);
            cg.emit(OP_LOCAL_TEE);
            cg.emitULEB(dstTmp);              // stack: dst
            if (e.E2 && e.E2.Eoper == OPparam)
            {
                genElem(cg, e.E2.E2);         // src
                genElem(cg, e.E2.E1);         // count
            }
            else if (e.E2)
            {
                genElem(cg, e.E2);            // src
                cg.emit(OP_I32_CONST);
                cg.emitSLEB(0);               // count = 0
            }
            else
            {
                cg.emit(OP_I32_CONST); cg.emitSLEB(0);
                cg.emit(OP_I32_CONST); cg.emitSLEB(0);
            }
            emitMemoryCopy(cg);
            cg.emit(OP_LOCAL_GET);
            cg.emitULEB(dstTmp);
            return true;
        }

    case OPmemset:
        {
            // IR: OPmemset(dst, OPparam(count, val)). Result is dst.
            uint dstTmp = cg.allocTemp(WASM_I32);
            genElem(cg, e.E1);
            cg.emit(OP_LOCAL_TEE);
            cg.emitULEB(dstTmp);              // stack: dst
            if (e.E2 && e.E2.Eoper == OPparam)
            {
                genElem(cg, e.E2.E2);         // val
                genElem(cg, e.E2.E1);         // count
            }
            else
            {
                cg.emit(OP_I32_CONST); cg.emitSLEB(0); // val
                cg.emit(OP_I32_CONST); cg.emitSLEB(0); // count
            }
            emitMemoryFill(cg);
            cg.emit(OP_LOCAL_GET);
            cg.emitULEB(dstTmp);
            return true;
        }

    default:
        cg.emit(OP_UNREACHABLE);
        return tybasic(e.Ety) != TYvoid;
    }
}

// Get the address of an lvalue expression (OPind → its pointer; OPvar in shadow → shadow addr; else genElem).
private void genElemAddr(ref WasmCG cg, elem* e) @trusted
{
    if (!e)
    {
        cg.emit(OP_I32_CONST);
        cg.emitSLEB(0);
        return;
    }
    if (e.Eoper == OPind)
    {
        genElem(cg, e.E1); // evaluate the pointer
        return;
    }
    if (e.Eoper == OPvar)
    {
        Symbol* s = e.Vsym;
        if (s)
        {
            // Shadow-frame variable: emit its address.
            if (cg.inShadow(s))
            {
                emitShadowAddr(cg, s);
                return;
            }
            // Global: its Soffset is the linear memory address.
            if (isDataSym(s.Sfl))
            {
                cg.emitDataAddr(s, cast(uint) e.Voffset);
                return;
            }
            // Local in a WASM local — can't take address unless shadow-framed.
            // Fall through to genElem (will push the value, not the address).
        }
    }
    if (e.Eoper == OPrelconst)
    {
        // Address of something already in memory.
        genElem(cg, e);
        return;
    }
    // Generic: evaluate the expression (which should produce an address).
    genElem(cg, e);
}

// Emit argument list (OPparam chain or single elem)
// In DMD IR, OPparam(E1, E2) is right-to-left: E2 is the leftmost argument.
// WASM args are left-to-right on the stack, so emit E2 before E1.
// Return true if a TYullong elem is a D dynamic array (slice).
// On WASM32, TYdarray == TYullong (util_set32 keeps var.d default of TYullong).
// D slices are packed as i64 (len32 | ptr32<<32) and must be split into two
// i32 WASM params when passed as function arguments.
private bool isSliceElem(const(elem)* e) @trusted
{
    const tym_t ty = tybasic(e.Ety);
    if (ty != TYullong && ty != TYllong)
        return false;
    // Explicit element type with Tnext indicates a slice.
    if (e.ET && e.ET.Tnext)
        return true;
    // OPvar: check symbol's declared type for Tnext.
    if (e.Eoper == OPvar && e.Vsym && e.Vsym.Stype && e.Vsym.Stype.Tnext)
        return true;
    // OPpair/OPrpair always construct a (len, ptr) D slice.
    if (e.Eoper == OPpair || e.Eoper == OPrpair)
        return true;
    // OPind: dereferencing a pointer-to-slice.
    // addr.Vsym.Stype = ptr type; .Tnext = slice type (TYullong + Tnext = element).
    if (e.Eoper == OPind && e.E1)
    {
        const(elem)* addr = e.E1;
        if (addr.Eoper == OPvar && addr.Vsym && addr.Vsym.Stype)
        {
            const(type)* sliceTy = addr.Vsym.Stype.Tnext;
            // pointee must be TYullong (= TYdarray on WASM32) with an element type.
            if (sliceTy && tybasic(sliceTy.Tty) == TYullong && sliceTy.Tnext)
                return true;
        }
    }
    return false;
}

// True if a callee parameter type is a D slice (TYdarray == TYullong+Tnext on WASM32).
private bool paramIsSlice(const(param_t)* p) @trusted
{
    if (!p || !p.Ptype)
        return false;
    const(type)* t = p.Ptype;
    return tybasic(t.Tty) == TYullong && t.Tnext !is null;
}

// Emit a single function argument. D slices (TYdarray = TYullong on WASM32)
// are split into two i32 params (lo=len, hi=ptr) to match the WASM32/LDC2 ABI.
// `forceSlice` forces the split even when the elem itself isn't recognised as
// a slice (e.g. an OPconst null passed where the callee expects char[]).
private void genOneArg(ref WasmCG cg, elem* e, bool forceSlice = false) @trusted
{
    genElem(cg, e);
    const bool isDynArray = forceSlice || isSliceElem(e);
    if (isDynArray)
    {
        uint tmp = cg.allocTemp(WASM_I64);
        cg.emit(OP_LOCAL_SET);
        cg.emitULEB(tmp);
        cg.emit(OP_LOCAL_GET);
        cg.emitULEB(tmp);
        cg.emit(OP_I32_WRAP_I64); // lo = len (low 32 bits)
        cg.emit(OP_LOCAL_GET);
        cg.emitULEB(tmp);
        cg.emit(OP_I64_CONST);
        cg.emitSLEB(32);
        cg.emit(OP_I64_SHR_U);
        cg.emit(OP_I32_WRAP_I64); // hi = ptr (high 32 bits)
    }
}

// In DMD IR, OPparam(E1, E2) is right-to-left: E2 is the leftmost argument.
// WASM args are left-to-right on the stack, so emit E2 before E1.
private void genArgs(ref WasmCG cg, elem* e) @trusted
{
    if (!e)
        return;
    if (e.Eoper == OPparam)
    {
        genArgs(cg, e.E2); // leftmost arg first
        genArgs(cg, e.E1); // rightmost arg second
    }
    else
    {
        genOneArg(cg, e);
    }
}

// Pick the WASM opcode variant matching the IR operand's numeric kind.
// Order: f32, f64, i64, i32. Pass OP_UNREACHABLE for kinds that don't apply.
private ubyte pickByKind(tym_t ty, ubyte f32, ubyte f64, ubyte i64, ubyte i32) @safe
{
    switch (tybasic(ty))
    {
        case TYfloat, TYifloat:                              return f32;
        case TYdouble, TYdouble_alias, TYreal, TYireal:      return f64;
        case TYllong, TYullong:                              return i64;
        default:                                             return i32;
    }
}

// Binary operation opcode selection by IR operator
private void emitBinop(ref WasmCG cg, int op, tym_t ty) @trusted
{
    const U = OP_UNREACHABLE;
    const bool isUns = tyuns(ty) != 0;
    ubyte oc = U;
    switch (op)
    {
    case OPadd:  oc = pickByKind(ty, OP_F32_ADD, OP_F64_ADD, OP_I64_ADD, OP_I32_ADD); break;
    case OPmin:  oc = pickByKind(ty, OP_F32_SUB, OP_F64_SUB, OP_I64_SUB, OP_I32_SUB); break;
    case OPmul:  oc = pickByKind(ty, OP_F32_MUL, OP_F64_MUL, OP_I64_MUL, OP_I32_MUL); break;
    case OPdiv:  oc = pickByKind(ty, OP_F32_DIV, OP_F64_DIV,
                                     isUns ? OP_I64_DIV_U : OP_I64_DIV_S,
                                     isUns ? OP_I32_DIV_U : OP_I32_DIV_S); break;
    case OPmod:  oc = pickByKind(ty, U, U,
                                     isUns ? OP_I64_REM_U : OP_I64_REM_S,
                                     isUns ? OP_I32_REM_U : OP_I32_REM_S); break;
    case OPand:  oc = pickByKind(ty, U, U, OP_I64_AND,   OP_I32_AND);   break;
    case OPor:   oc = pickByKind(ty, U, U, OP_I64_OR,    OP_I32_OR);    break;
    case OPxor:  oc = pickByKind(ty, U, U, OP_I64_XOR,   OP_I32_XOR);   break;
    case OPshl:  oc = pickByKind(ty, U, U, OP_I64_SHL,   OP_I32_SHL);   break;
    case OPshr:  oc = pickByKind(ty, U, U, OP_I64_SHR_U, OP_I32_SHR_U); break;
    case OPashr: oc = pickByKind(ty, U, U, OP_I64_SHR_S, OP_I32_SHR_S); break;
    default: break;
    }
    cg.emit(oc);
}

// Map compound-assignment op to its binary counterpart
alias compoundToBinop = opeqtoop;

// Emit a relational/comparison opcode
private void emitRelop(ref WasmCG cg, int op, tym_t operandTy) @trusted
{
    const bool isUns = tyuns(operandTy) != 0;
    ubyte oc = OP_UNREACHABLE;
    switch (op)
    {
    case OPeqeq: oc = pickByKind(operandTy, OP_F32_EQ, OP_F64_EQ, OP_I64_EQ, OP_I32_EQ); break;
    case OPne:   oc = pickByKind(operandTy, OP_F32_NE, OP_F64_NE, OP_I64_NE, OP_I32_NE); break;
    case OPlt:   oc = pickByKind(operandTy, OP_F32_LT, OP_F64_LT,
                                            isUns ? OP_I64_LT_U : OP_I64_LT_S,
                                            isUns ? OP_I32_LT_U : OP_I32_LT_S); break;
    case OPle:   oc = pickByKind(operandTy, OP_F32_LE, OP_F64_LE,
                                            isUns ? OP_I64_LE_U : OP_I64_LE_S,
                                            isUns ? OP_I32_LE_U : OP_I32_LE_S); break;
    case OPgt:   oc = pickByKind(operandTy, OP_F32_GT, OP_F64_GT,
                                            isUns ? OP_I64_GT_U : OP_I64_GT_S,
                                            isUns ? OP_I32_GT_U : OP_I32_GT_S); break;
    case OPge:   oc = pickByKind(operandTy, OP_F32_GE, OP_F64_GE,
                                            isUns ? OP_I64_GE_U : OP_I64_GE_S,
                                            isUns ? OP_I32_GE_U : OP_I32_GE_S); break;
    default: break;
    }
    cg.emit(oc);
}

// ---------------------------------------------------------------------------
// Function index lookup
// ---------------------------------------------------------------------------

private uint funcIndex(Symbol* sfunc) @trusted
{
    import dmd.backend.wasmobj : wasmFuncBodies, wmod_funcs, wmod_numImports;

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

    // External symbol not yet registered — register as import now.
    import dmd.backend.wasmobj : WasmObj_external;

    if (sfunc && sfunc.Stype)
    {
        int idx = WasmObj_external(sfunc);
        return cast(uint) idx;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// Control-flow condition helpers
// ---------------------------------------------------------------------------

// Ensure a condition value on the WASM stack is an i32 suitable for br_if.
// For i64 (D slice / long): emit i64.eqz + i32.eqz to produce 1 if nonzero.
// For i32: nothing needed (already a valid br_if operand).
private void emitCondToI32(ref WasmCG cg, elem* condElem) @trusted
{
    if (!condElem) return;
    const tym_t ty = tybasic(condElem.Ety);
    if (ty == TYllong || ty == TYullong)
    {
        cg.emit(OP_I64_EQZ); // i64 → i32: 1 if zero, 0 if nonzero
        cg.emit(OP_I32_EQZ); // invert: 1 if nonzero (truthy)
    }
}

// Emit the inversion of a condition for "branch if FALSE" patterns (cond; eqz; br_if).
// For i64: i64.eqz produces 1 when zero (false).
// For i32: i32.eqz produces 1 when zero (false).
private void emitCondInvert(ref WasmCG cg, elem* condElem) @trusted
{
    if (!condElem)
    {
        cg.emit(OP_I32_EQZ);
        return;
    }
    const tym_t ty = tybasic(condElem.Ety);
    if (ty == TYllong || ty == TYullong)
        cg.emit(OP_I64_EQZ);
    else
        cg.emit(OP_I32_EQZ);
}

// Structured control flow synthesis (block CFG => WASM)
// ---------------------------------------------------------------------------

// Per-block metadata computed during analysis
private struct BlkInfo
{
    int idx; // sequential index (0-based)
    bool isLoopHeader; // targeted by a back edge
    int loopEnd; // for loop headers: index of the block that closes the loop
    int nOpen; // how many block/loop pairs open AT this block
    int nClose; // how many end's to emit AFTER this block
    int[] jmptabDests; // for BC.jmptab: unique sorted destination block indices
}

private block*[] collectBlocks(block* start) @trusted
{
    block*[] v;
    for (block* b = start; b; b = b.Bnext)
        v ~= b;
    return v;
}

private int blockIdx(block* b) @trusted
{
    return b ? b.Bdfoidx : int.max;
}

// Successor index in Bsucc list
private block* succ(block* b, int n) @trusted
{
    if (n < b.numSucc())
        return b.nthSucc(n);
    return null;
}

private void genBlocksProper(ref WasmCG cg, block* startblock, bool hasReturn) @trusted
{
    block*[] blocks = collectBlocks(startblock);
    const int N = cast(int) blocks.length;
    if (N == 0)
        return;

    // Assign sequential indices
    foreach (size_t i, b; blocks)
        b.Bdfoidx = cast(int) i;

    // Find back edges: edge B => A where A.idx <= B.idx
    // A back edge target is a loop header.
    BlkInfo[] info = new BlkInfo[N];
    foreach (size_t i, b; blocks)
    {
        info[i].idx = cast(int) i;
        if (b.bc == BC.goto_ || b.bc == BC.iftrue)
        {
            foreach (int si; 0 .. b.numSucc())
            {
                block* s = b.nthSucc(si);
                if (s && s.Bdfoidx <= cast(int) i) // back edge
                {
                    info[s.Bdfoidx].isLoopHeader = true;
                    if (info[s.Bdfoidx].loopEnd < cast(int) i)
                        info[s.Bdfoidx].loopEnd = cast(int) i;
                }
            }
        }
    }

    // Nesting stack: each entry is (isLoop: bool, openedAtIdx: int, closeAtIdx: int)
    struct Frame
    {
        bool isLoop;
        int closeAfter;
    }

    Frame[] stack;
    int depth()
    {
        return cast(int) stack.length;
    }

    // br depth to reach a given stack frame (0 = innermost)
    uint brDepth(size_t frameIdx)
    {
        return cast(uint)(stack.length - 1 - frameIdx);
    }

    // Find the stack frame for a loop whose header is at idx
    // Returns stack.length if not found (sentinel)
    size_t loopFrame(int headerIdx)
    {
        foreach_reverse (size_t fi, ref const Frame f; stack)
            if (f.isLoop && f.closeAfter >= headerIdx)
                return fi;
        return stack.length; // sentinel: not found
    }

    // Find the enclosing block (non-loop) frame index for a forward exit target
    size_t blockFrame(int exitTarget)
    {
        foreach_reverse (size_t fi, ref const Frame f; stack)
            if (!f.isLoop && f.closeAfter >= exitTarget - 1)
                return fi;
        return stack.length; // sentinel: not found
    }

    for (size_t bi = 0; bi < N; bi++)
    {
        block* b = blocks[bi];

        // Close frames whose closeAfter == bi - 1
        while (stack.length > 0 && stack[$ - 1].closeAfter < bi)
        {
            cg.emit(OP_END);
            stack = stack[0 .. $ - 1];
        }

        // Open wrapper blocks for BC.jmptab (switch via br_table).
        // Must happen before loop-header frames so depths are computed correctly.
        if (b.bc == BC.jmptab || b.bc == BC.switch_)
        {
            // Collect unique destination block indices, sorted ascending.
            // Bsucc[0] = default; Bsucc[1..n] = cases in Bswitch order.
            int[] dests;
            foreach (int si; 0 .. b.numSucc())
            {
                int idx = blockIdx(b.nthSucc(si));
                bool found = false;
                foreach (d; dests)
                    if (d == idx)
                    {
                        found = true;
                        break;
                    }
                if (!found)
                    dests ~= idx;
            }
            import std.algorithm : sort;

            sort(dests);

            // Open one wrapper block per unique dest, outermost (highest idx) first.
            // Frame closeAfter = destIdx - 1 so the block ends just before that block.
            foreach_reverse (int destIdx; dests)
            {
                stack ~= Frame(false, destIdx - 1);
                cg.emit(OP_BLOCK);
                cg.emit(WASM_VOID_BLOCK);
            }
            // stash dest list for use when emitting the br_table
            info[bi].jmptabDests = dests;
        }

        // Open a loop for loop headers: emit `block` (exit) + `loop` (continue)
        if (info[bi].isLoopHeader)
        {
            int loopEnd = info[bi].loopEnd;
            // block $exit (depth +1): close after loopEnd
            stack ~= Frame(false, loopEnd);
            cg.emit(OP_BLOCK);
            cg.emit(WASM_VOID_BLOCK);
            // loop $continue (depth +1): also close after loopEnd
            stack ~= Frame(true, loopEnd);
            cg.emit(OP_LOOP);
            cg.emit(WASM_VOID_BLOCK);
        }

        // Emit block expression (statement-level: discard result)
        if (b.bc == BC.retexp)
        {
            // Return value: leave on stack, then return
            if (b.Belem)
                genElem(cg, b.Belem);
            if (cg.hasShadowFrame)
            {
                if (b.Belem) // return value is on the stack
                {
                    // Save, epilogue, reload.
                    uint retTmp = cg.allocTemp(wasmType(b.Belem.Ety));
                    cg.emit(OP_LOCAL_SET);
                    cg.emitULEB(retTmp);
                    emitShadowEpilogue(cg);
                    cg.emit(OP_LOCAL_GET);
                    cg.emitULEB(retTmp);
                }
                else
                {
                    emitShadowEpilogue(cg);
                }
            }
            cg.emit(OP_RETURN);
            continue;
        }
        else if (b.bc == BC.ret)
        {
            if (b.Belem)
            {
                const bool v = genElem(cg, b.Belem);
                if (v)
                    cg.emit(OP_DROP);
            }
            if (cg.hasShadowFrame)
                emitShadowEpilogue(cg);
            // If the function has a return value but this path provides none
            // (e.g. void call to a noreturn function like __switch_error),
            // emit unreachable so the WASM validator sees a polymorphic stack.
            if (hasReturn)
                cg.emit(OP_UNREACHABLE);
            cg.emit(OP_RETURN);
            continue;
        }
        else if (b.bc == BC.exit)
        {
            if (b.Belem)
            {
                const bool v = genElem(cg, b.Belem);
                if (v)
                    cg.emit(OP_DROP);
            }
            cg.emit(OP_UNREACHABLE);
            continue;
        }
        else if (b.bc == BC.jmptab || b.bc == BC.switch_)
        {
            // Wrapper blocks already opened above.
            // dests[i] has depth = (dests.length - 1 - i) from the current stack top.
            int[] dests = info[bi].jmptabDests;
            size_t nw = dests.length;

            // Emit switch expression
            if (b.Belem)
                genElem(cg, b.Belem);
            else
            {
                cg.emit(OP_I32_CONST);
                cg.emitSLEB(0);
            }

            // Compute vmin/vmax from case values
            long vmin = long.max, vmax = long.min;
            foreach (v; b.Bswitch)
            {
                if (v < vmin)
                    vmin = v;
                if (v > vmax)
                    vmax = v;
            }
            if (b.Bswitch.length == 0)
            {
                cg.emit(OP_DROP);
                continue;
            }

            // Helper: depth for a given block index
            uint depthOf(int destIdx) @trusted
            {
                foreach (size_t di, int d; dests)
                    if (d == destIdx)
                        return cast(uint)(di);
                return cast(uint)(nw - 1); // fallback: default
            }

            // Default block: Bsucc[0]
            int defaultIdx = blockIdx(b.nthSucc(0));
            uint defaultDepth = depthOf(defaultIdx);

            // br_table is only valid for i32 indices and dense ranges.
            // Use if-else chain when: values are i64, or the range is too
            // sparse (table would exceed 1024 entries).
            const bool is64bit = (b.Belem && (tybasic(b.Belem.Ety) == TYllong ||
                                               tybasic(b.Belem.Ety) == TYullong));
            const ulong tableLen64 = cast(ulong)(vmax - vmin) + 1;
            const bool useBrTable = !is64bit && tableLen64 <= 1024 &&
                                    tableLen64 <= b.Bswitch.length * 4UL + 4;

            if (!useBrTable)
            {
                // If-else chain: store condition in a local, compare each case.
                const ubyte condTy = is64bit ? WASM_I64 : WASM_I32;
                uint condLocal = cg.allocTemp(condTy);
                cg.emit(OP_LOCAL_SET);
                cg.emitULEB(condLocal);
                foreach (size_t ci, long cv; b.Bswitch)
                {
                    int caseIdx = blockIdx(b.nthSucc(cast(int)(ci + 1)));
                    cg.emit(OP_LOCAL_GET);
                    cg.emitULEB(condLocal);
                    if (is64bit)
                    {
                        cg.emit(OP_I64_CONST);
                        cg.emitSLEB(cv);
                        cg.emit(OP_I64_EQ);
                    }
                    else
                    {
                        cg.emit(OP_I32_CONST);
                        cg.emitSLEB(cast(int)cv);
                        cg.emit(OP_I32_EQ);
                    }
                    cg.emit(OP_BR_IF);
                    cg.emitULEB(depthOf(caseIdx));
                }
                // Fall through to default
                if (defaultDepth > 0)
                {
                    cg.emit(OP_BR);
                    cg.emitULEB(defaultDepth);
                }
                continue;
            }

            // Dense i32 range: use br_table.
            // Adjust switch value to 0-based
            if (vmin != 0)
            {
                cg.emit(OP_I32_CONST);
                cg.emitSLEB(cast(int)-vmin);
                cg.emit(OP_I32_ADD);
            }

            // Table entries: for each integer value vmin..vmax, find its dest
            const size_t tableLen = cast(size_t) tableLen64;
            cg.emit(OP_BR_TABLE);
            cg.emitULEB(cast(uint) tableLen);
            foreach (long v; vmin .. vmax + 1)
            {
                // Find which Bswitch entry matches this value
                int destIdx = defaultIdx;
                foreach (size_t ci, long cv; b.Bswitch)
                    if (cv == v)
                    {
                        destIdx = blockIdx(b.nthSucc(cast(int)(ci + 1)));
                        break;
                    }
                cg.emitULEB(depthOf(destIdx));
            }
            cg.emitULEB(defaultDepth); // default label
            continue;
        }
        else if (b.bc == BC.ifthen) // switch converted to if-then chain — same as iftrue
            goto case_iftrue;
        else if (b.bc == BC.iftrue)
    case_iftrue :
        {
            block* taken = succ(b, 0);
            block* nottaken = succ(b, 1);
            int takenIdx = blockIdx(taken);
            int nottakenIdx = blockIdx(nottaken);

            // Find enclosing loop (if any)
            size_t outerLoop = stack.length;
            foreach_reverse (size_t fi, ref const Frame f; stack)
                if (f.isLoop)
                {
                    outerLoop = fi;
                    break;
                }
            int exitBlockIdx = (outerLoop < stack.length) ? stack[outerLoop - 1].closeAfter + 1 : -1;

            if (takenIdx <= cast(int) bi)
            {
                // Back edge: condition true => loop continue
                if (b.Belem)
                    genElem(cg, b.Belem);
                else
                {
                    cg.emit(OP_I32_CONST);
                    cg.emitSLEB(0);
                }
                emitCondToI32(cg, b.Belem);
                size_t lf = loopFrame(takenIdx);
                if (lf < stack.length)
                {
                    cg.emit(OP_BR_IF);
                    cg.emitULEB(brDepth(lf));
                    // false => exit loop
                    if (nottakenIdx > info[takenIdx].loopEnd)
                    {
                        size_t ef = blockFrame(nottakenIdx);
                        if (ef < stack.length)
                        {
                            cg.emit(OP_BR);
                            cg.emitULEB(brDepth(ef));
                        }
                    }
                }
                else
                    cg.emit(OP_DROP);
            }
            else if (nottakenIdx <= cast(int) bi)
            {
                // Back edge: condition false => loop continue
                if (b.Belem)
                    genElem(cg, b.Belem);
                else
                {
                    cg.emit(OP_I32_CONST);
                    cg.emitSLEB(0);
                }
                emitCondInvert(cg, b.Belem);
                size_t lf = loopFrame(nottakenIdx);
                if (lf < stack.length)
                {
                    cg.emit(OP_BR_IF);
                    cg.emitULEB(brDepth(lf));
                }
                else
                    cg.emit(OP_DROP);
            }
            else if (outerLoop < stack.length &&
                (nottakenIdx == exitBlockIdx || takenIdx == exitBlockIdx))
            {
                // Loop exit condition (condition block is loop header or part of loop)
                if (b.Belem)
                    genElem(cg, b.Belem);
                else
                {
                    cg.emit(OP_I32_CONST);
                    cg.emitSLEB(0);
                }
                if (nottakenIdx == exitBlockIdx)
                {
                    // condition true => stay in loop, false => exit
                    emitCondInvert(cg, b.Belem);
                    cg.emit(OP_BR_IF);
                    cg.emitULEB(brDepth(outerLoop - 1));
                }
                else
                {
                    // condition true => exit, false => stay
                    emitCondToI32(cg, b.Belem);
                    cg.emit(OP_BR_IF);
                    cg.emitULEB(brDepth(outerLoop - 1));
                }
            }
            else
            {
                // Pure forward if/else (no loop involved).
                // Open a block BEFORE emitting the condition so we can br_if out.
                if (takenIdx == cast(int) bi + 1)
                {
                    // True path is inline; false path at nottakenIdx.
                    // If the true path jumps past the false path (if-else), we need an
                    // outer block so the true path can 'br 1' to skip the false path.
                    // Detect by peeking at the taken block's successor.
                    int mergeIdx = -1;
                    if (bi + 1 < N)
                    {
                        block* takenBlock = blocks[bi + 1];
                        if (takenBlock.bc == BC.goto_ && takenBlock.numSucc() > 0)
                        {
                            block* mergeBlock = takenBlock.nthSucc(0);
                            if (mergeBlock)
                            {
                                int midx = blockIdx(mergeBlock);
                                if (midx > nottakenIdx)
                                    mergeIdx = midx;
                            }
                        }
                    }
                    if (mergeIdx >= 0)
                    {
                        // if-else structure: open outer block covering both paths.
                        stack ~= Frame(false, mergeIdx - 1);
                        cg.emit(OP_BLOCK);
                        cg.emit(WASM_VOID_BLOCK);
                    }
                    stack ~= Frame(false, nottakenIdx - 1);
                    cg.emit(OP_BLOCK);
                    cg.emit(WASM_VOID_BLOCK);
                    if (b.Belem)
                        genElem(cg, b.Belem);
                    else
                    {
                        cg.emit(OP_I32_CONST);
                        cg.emitSLEB(0);
                    }
                    emitCondInvert(cg, b.Belem);
                    cg.emit(OP_BR_IF);
                    cg.emitULEB(0);
                }
                else if (nottakenIdx == cast(int) bi + 1)
                {
                    // False path is inline; true path at takenIdx.
                    // block $skip ... cond; br_if 0 ... [false path] ... end $skip
                    stack ~= Frame(false, takenIdx - 1);
                    cg.emit(OP_BLOCK);
                    cg.emit(WASM_VOID_BLOCK);
                    if (b.Belem)
                        genElem(cg, b.Belem);
                    else
                    {
                        cg.emit(OP_I32_CONST);
                        cg.emitSLEB(0);
                    }
                    emitCondToI32(cg, b.Belem);
                    cg.emit(OP_BR_IF);
                    cg.emitULEB(0);
                }
                else
                {
                    // Both branches non-immediate — complex; just evaluate.
                    if (b.Belem)
                    {
                        bool v = genElem(cg, b.Belem);
                        if (v)
                            cg.emit(OP_DROP);
                    }
                }
            }
            continue;
        }
        else if (b.bc == BC.goto_)
        {
            block* target = succ(b, 0);
            if (b.Belem)
            {
                const bool v = genElem(cg, b.Belem);
                if (v)
                    cg.emit(OP_DROP);
            }
            if (!target)
                continue;

            int targetIdx = blockIdx(target);
            if (targetIdx <= bi)
            {
                // Back edge => loop continue
                size_t lf = loopFrame(targetIdx);
                if (lf < stack.length)
                {
                    cg.emit(OP_BR);
                    cg.emitULEB(brDepth(lf));
                }
            }
            else if (targetIdx > bi + 1)
            {
                // Forward goto that skips blocks — need to br out of if-block.
                // Find the shallowest non-loop block frame that encompasses targetIdx.
                foreach_reverse (size_t fi, ref const Frame f; stack)
                {
                    if (!f.isLoop && f.closeAfter >= targetIdx - 1)
                    {
                        cg.emit(OP_BR);
                        cg.emitULEB(brDepth(fi));
                        break;
                    }
                }
            }
            // targetIdx == bi+1: fall through naturally
            continue;
        }

        // Default: emit expression, discard result
        if (b.Belem)
        {
            const bool hasVal = genElem(cg, b.Belem);
            if (hasVal)
                cg.emit(OP_DROP);
        }
    }

    // Close any remaining open frames
    while (stack.length > 0)
    {
        cg.emit(OP_END);
        stack = stack[0 .. $ - 1];
    }
}

/// Main entry point generating code for a function - called from dout.d
void wasm_codgen(Symbol* sfunc) @trusted
{
    import dmd.backend.wasmobj : wasmFuncBodies, WasmFuncBody;

    // Find this function's entry in wasmFuncBodies
    WasmFuncBody* fb = null;
    foreach (ref WasmFuncBody f; wasmFuncBodies)
        if (f.sym == sfunc)
        {
            fb = &f;
            break;
        }
    if (!fb)
        return;

    WasmCG cg;

    // Register parameters. D slices (TYdarray = TYullong+Tnext on WASM32) are split
    // into two i32 WASM params (len, ptr) by buildFuncType/toArgTypes_wasm.
    // We create two anonymous i32 params and reconstruct the i64 into a non-param
    // local that the function body (which uses TYullong for slices) can access.
    struct SplitParam
    {
        Symbol* sym;
        uint loIdx, hiIdx, i64Idx;
    }

    SplitParam[] splitParams;

    foreach (s; globsym[])
    {
        if (s.Sclass == SC.parameter || s.Sclass == SC.fastpar ||
            s.Sclass == SC.regpar || s.Sclass == SC.shadowreg)
        {
            // D slice: TYdarray == TYullong on WASM32; identified by s.Stype.Tnext.
            const tym_t pty = tybasic(s.ty());
            if (pty == TYullong && s.Stype && s.Stype.Tnext)
            {
                SplitParam sp;
                sp.sym = s;
                sp.loIdx = cast(uint) cg.locals.length; // len param (i32)
                sp.hiIdx = sp.loIdx + 1; // ptr param (i32)
                sp.i64Idx = uint.max;
                splitParams ~= sp;
                WasmLocal lo, hi;
                lo.sym = null;
                lo.ty = WASM_I32;
                hi.sym = null;
                hi.ty = WASM_I32;
                cg.locals ~= lo;
                cg.locals ~= hi;
            }
            else
            {
                WasmLocal l;
                l.sym = s;
                l.ty = wasmType(s.ty());
                cg.locals ~= l;
            }
        }
    }
    cg.numParams = cast(uint) cg.locals.length;

    // Add i64 non-param locals for split slice params; reconstruct at entry.
    foreach (ref sp; splitParams)
    {
        sp.i64Idx = cast(uint) cg.locals.length;
        WasmLocal i64l;
        i64l.sym = sp.sym;
        i64l.ty = WASM_I64;
        cg.locals ~= i64l;
    }
    foreach (ref sp; splitParams)
    {
        // i64 = (ptr << 32) | len  (D slice layout: lo32=len, hi32=ptr)
        cg.emit(OP_LOCAL_GET);
        cg.emitULEB(sp.hiIdx); // ptr
        cg.emit(OP_I64_EXTEND_I32_U);
        cg.emit(OP_I64_CONST);
        cg.emitSLEB(32);
        cg.emit(OP_I64_SHL);
        cg.emit(OP_LOCAL_GET);
        cg.emitULEB(sp.loIdx); // len
        cg.emit(OP_I64_EXTEND_I32_U);
        cg.emit(OP_I64_OR);
        cg.emit(OP_LOCAL_SET);
        cg.emitULEB(sp.i64Idx);
    }

    // Then non-parameter locals. Aggregates (structs/arrays) can't live in
    // WASM locals — pre-register them in the shadow frame instead.
    foreach (s; globsym[])
    {
        if (s.Sclass == SC.auto_ || s.Sclass == SC.register || s.Sclass == SC.stack)
        {
            const tym_t tb = tybasic(s.ty());
            if (tb == TYstruct || tb == TYarray)
            {
                cg.registerShadow(s); // aggregate: lives in linear memory
            }
            else
            {
                WasmLocal l;
                l.sym = s;
                l.ty = wasmType(s.ty());
                cg.locals ~= l;
            }
        }
    }

    // Determine return type. Aggregate-returning functions return the hidden ptr (i32).
    type* retType = sfunc.Stype.Tnext;
    const bool hasReturn = retType && tybasic(retType.Tty) != TYvoid;

    // Scan all IR blocks for address-taken locals → populate shadow frame.
    block* startblock = sfunc.Sfunc.Fstartblock;
    for (block* sb = startblock; sb; sb = sb.Bnext)
        scanShadow(sb.Belem, cg);

    // If any locals need addresses, set up the shadow stack frame.
    if (cg.shadowEntries.length > 0)
    {
        cg.hasShadowFrame = true;
        emitShadowPrologue(cg);
    }

    // Generate code from the block CFG
    if (startblock)
        genBlocksProper(cg, startblock, hasReturn);

    // Emit epilogue at function end (reached when all paths fall through without explicit return).
    if (cg.hasShadowFrame)
        emitShadowEpilogue(cg);

    // Store results back into the WasmFuncBody
    fb.locals = cg.locals;
    fb.numParams = cg.numParams;
    fb.codeRelocs    = cg.codeRelocs;
    fb.dataAddrRelocs = cg.dataAddrRelocs;
    fb.code.reset();
    fb.code.write(cg.code.peekSlice());
}
