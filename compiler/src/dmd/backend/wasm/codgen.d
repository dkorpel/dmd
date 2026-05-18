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
import dmd.backend.wasm;
import dmd.backend.wasmobj : WasmFuncBody, wasmFuncBodies, WasmLocal;

import dmd.common.outbuffer;

nothrow:

/// Returns: WASM value type for a backend type `ty`
ubyte wasmType(tym_t ty)
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
    case TYint:
    case TYuint:
    case TYshort:
    case TYushort:
    case TYchar:
    case TYuchar:
    case TYschar:
    case TYwchar_t:
    case TYbool:
    case TYenum:
        return WASM_I32; // int, pointer, bool, etc.

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
    WasmFuncBody.CodeReloc[] codeRelocs; /// relocations for direct function calls
    WasmFuncBody.DataAddrReloc[] dataAddrRelocs; /// R_WASM_MEMORY_ADDR_LEB relocations

    // Shadow stack frame (for locals whose address is taken)
    bool hasShadowFrame;
    uint shadowBaseLocal; /// WASM local index holding the shadow frame base address
    uint shadowFrameSize; /// total size in bytes of shadow frame
    ShadowEntry[] shadowEntries; /// per-symbol shadow frame offsets

nothrow:

    /// Allocate an anonymous temp local of the given WASM type
    ///
    /// Returns: index of allocated temp in `locals` array
    uint allocTemp(ubyte ty)
    {
        const uint result = cast(uint) locals.length;
        locals ~= WasmLocal(null, ty);
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
        locals ~= WasmLocal(s, s.ty().wasmType());
        return result;
    }

    /// Returns: true if symbol `s` lives in the shadow frame.
    bool inShadow(Symbol* s) const
    {
        foreach (ref const ShadowEntry e; shadowEntries)
            if (e.sym == s)
                return true;
        return false;
    }

    /// Returns: byte offset of `s` in the shadow frame (assumes inShadow).
    uint shadowOffset(Symbol* s) const
    {
        foreach (ref const ShadowEntry e; shadowEntries)
            if (e.sym == s)
                return e.offset;
        return 0;
    }

    /// Register a symbol in the shadow frame (idempotent).
    void registerShadow(Symbol* s)
    {
        if (inShadow(s))
            return;
        // Compute size and alignment for the type.
        uint sz = 4;
        uint al = 4;
        if (s.Stype)
        {
            import dmd.backend.type : type_size, type_alignsize;

            const targ_size_t ts = type_size(s.Stype);
            if (ts != targ_size_t.max && ts > 0)
                sz = cast(uint) ts;
            const uint ta = type_alignsize(s.Stype);
            if (ta > 0 && ta <= 16)
                al = ta;
        }
        const uint off = (shadowFrameSize + al - 1) & ~(al - 1);
        ShadowEntry se;
        se.sym = s;
        se.offset = off;
        shadowEntries ~= se;
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
    void emitConst(ubyte OP, long v)
    {
        emit(OP);
        emitSLEB(v);
    }

    /// Access local at index `v`
    void emitLocal(ubyte OP, long v)
    {
        emit(OP);
        emitULEB(cast(uint) v);
    }

    /// 5-byte padded ULEB128 so wasm-ld has room to write a patched value over it
    void emitULEBpadded(uint addr)
    {
        code.writeuLEB128_5(addr);
    }

    // Emit OP_I32_CONST with a data-segment address.
    // In relocatable mode, emits a 5-byte padded ULEB128 and records a
    // R_WASM_MEMORY_ADDR_LEB relocation so wasm-ld patches the address after
    // moving the data section to its final location.
    // In non-relocatable (final) mode, emits a compact SLEB128 — the data
    // section is already at its final address in that case.
    void emitDataAddr(Symbol* sym, uint addend)
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
            emitULEBpadded(addr);
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
    void emitCall(uint fidx, Symbol* sym = null)
    {
        emit(OP_CALL);
        codeRelocs ~= WasmFuncBody.CodeReloc(cast(uint) code.length, R_WASM_FUNCTION_INDEX_LEB, fidx, 0, sym);
        emitULEBpadded(fidx);
    }

    // Emit the type index operand of call_indirect.
    // In relocatable mode, emit R_WASM_TYPE_INDEX_LEB so wasm-ld can patch the
    // type index when merging type tables from multiple objects.  The relocation
    // references a named function whose type matches, preferring imports to avoid
    // a wasm-ld 22 crash on locally-defined symbol targets.  If no suitable
    // function is found yet (rare), fall back to compact ULEB without relocation
    // (type indices are stable for single-file linking via reorderImportTypesFirst).
    void emitCallIndirectType(uint typeIdx)
    {
        import dmd.backend.wasmobj : wmod_findFuncForType, wmod_funcs, wasm_relocatable;

        if (wasm_relocatable)
        {
            uint fidx = wmod_findFuncForType(typeIdx);
            if (fidx != uint.max)
            {
                // Anchor the reloc to the function's Symbol* so currentFuncIdx
                // resolves it correctly even after wmod.funcs is reordered late
                // in codegen — otherwise the stored fidx points at a different
                // function whose typeIdx is unrelated (and often type 0).
                auto reloc = WasmFuncBody.CodeReloc(cast(uint) code.length, R_WASM_TYPE_INDEX_LEB, fidx);
                reloc.sym = wmod_funcs(fidx);
                codeRelocs ~= reloc;

                // 5-byte padded ULEB128 so wasm-ld has room to write the patched index.
                emitULEBpadded(typeIdx);
                return;
            }
        }
        emitULEB(typeIdx); // single-file / no matching symbol: compact ULEB
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
    case TYdouble, TYdouble_alias,
        TYreal, TYireal:
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

// Emit `memory.copy 0 0` (stack: dst, src, n → empty).
// Bulk-memory proposal — supported by every current wasm runtime.
private void emitMemoryCopy(ref WasmCG cg)
{
    cg.emit(OP_FC_PREFIX);
    cg.emitULEB(10); // memory.copy sub-opcode
    cg.emit(0x00); // dst memidx
    cg.emit(0x00); // src memidx
}

// Emit `memory.fill 0` (stack: dst, val, n → empty).
private void emitMemoryFill(ref WasmCG cg)
{
    cg.emit(OP_FC_PREFIX);
    cg.emitULEB(11); // memory.fill sub-opcode
    cg.emit(0x00); // memidx
}

private void emitLoad(ref WasmCG cg, tym_t ty)
{
    const m = memOpsFor(ty);
    cg.emit(m.loadOp);
    cg.emitMemArg(m.alignLog2, 0);
}

// Emit a typed store (address then value already on stack).
private void emitStore(ref WasmCG cg, tym_t ty)
{
    const m = memOpsFor(ty);
    cg.emit(m.storeOp);
    cg.emitMemArg(m.alignLog2, 0);
}

// Emit a type coercion when a value's actual WASM type differs from what e.Ety expects.
// This handles cases where the optimizer elides explicit cast operators.
private void emitCoerce(ref WasmCG cg, ubyte from, ubyte to)
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

    static ubyte coerceOp(ubyte from, ubyte to)
    {
        static int X(ubyte from, ubyte to) { return from << 8 | to; }

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
            // Other combos: no-op (best effort)
            default: return 0;
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

// Walk the IR tree and pre-register any external function calls as imports.
// Must run before code generation so that import indices are stable across
// the whole module (call_indirect type indices are encoded as fixed-width
// LEBs, so they cannot grow after the fact).
void preRegisterExternals(elem* e)
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
        if (e.E1)
            preRegisterExternals(e.E1);
        if (e.E2)
            preRegisterExternals(e.E2);
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

// Emit address of a shadow-frame symbol onto the value stack: local.get $base; i32.const offset; i32.add
private void emitShadowAddr(ref WasmCG cg, Symbol* s)
{
    cg.emitLocal(OP_LOCAL_GET, cg.shadowBaseLocal);
    uint off = cg.shadowOffset(s);
    if (off != 0)
    {
        cg.emitConst(OP_I32_CONST, cast(int) off);
        cg.emit(OP_I32_ADD);
    }
}

// Emit shadow stack frame prologue (called once at function entry).
// Creates the shadow base local, gets __stack_pointer, subtracts frame size, stores back.
private void emitShadowPrologue(ref WasmCG cg)
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
    cg.emitConst(OP_I32_CONST, cast(int) fsz);
    cg.emit(OP_I32_SUB);
    cg.emit(OP_LOCAL_TEE);
    cg.emitULEB(cg.shadowBaseLocal);
    cg.emit(OP_GLOBAL_SET);
    cg.emitULEB(spIdx);
}

// Emit shadow stack frame epilogue (restore __stack_pointer).
private void emitShadowEpilogue(ref WasmCG cg)
{
    import dmd.backend.wasmobj : wmod_getOrCreateStackPtrGlobal;

    uint spIdx = wmod_getOrCreateStackPtrGlobal();
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

// Expression code generation

/// Returns: true if the expression has a result on the stack after genElem
private bool genElem(ref WasmCG cg, elem* e)
{
    if (!e)
        return false;

    const op = e.Eoper;

    bool unaryOp(ubyte op)
    {
        cg.genElem(e.E1);
        cg.emit(op);
        return true;
    }

    switch (op)
    {
    case OPconst:
        {
            switch (tybasic(e.Ety).wasmType)
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
            default: // TODO: assert for unknown types instead of assuming default
                cg.emitConst(OP_I32_CONST, cast(int) e.Vlong);
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
                cg.emitLoad(e.Ety);
                return true;
            }
            // Shadow-frame locals: load from linear memory.
            if (cg.inShadow(s))
            {
                cg.emitShadowAddr(s);
                if (e.Voffset != 0)
                {
                    cg.emitConst(OP_I32_CONST, cast(int) e.Voffset);
                    cg.emit(OP_I32_ADD);
                }
                cg.emitLoad(e.Ety);
                return true;
            }
            const uint idx = cg.localFor(s);
            cg.emitLocal(OP_LOCAL_GET, idx);
            // For i64 locals (packed structs like D slices): field access via Voffset.
            // D slice layout: {size_t len (offset 0), T* ptr (offset 4)} packed as i64.
            //   Voffset=0 → low 32 bits (len)  → i32.wrap_i64
            //   Voffset=4 → high 32 bits (ptr) → i64.shr_u 32; i32.wrap_i64
            if (cg.locals[idx].ty == WASM_I64 && e.Voffset == 4)
            {
                cg.emitConst(OP_I64_CONST, 32);
                cg.emit(OP_I64_SHR_U);
            }
            // Coerce if expression type differs from the local's stored type.
            // Skip when e.Ety is an aggregate (TYstruct/TYarray): aggregates
            // live by reference (i32 pointer in linear memory), so don't sign-
            // extend the pointer into an i64 struct-value just because Ety
            // claims a struct type wider than the actual local.
            const tym_t eebTy = tybasic(e.Ety);
            if (eebTy != TYstruct && eebTy != TYarray)
                emitCoerce(cg, cg.locals[idx].ty, wasmType(e.Ety));
            return true;
        }

    case OPrelconst:
        {
            Symbol* rs = e.Vsym;
            if (rs && isLocalSym(rs) && cg.inShadow(rs))
            {
                // Address of a shadow-frame local.
                cg.emitShadowAddr(rs);
                if (e.Voffset != 0)
                {
                    cg.emitConst(OP_I32_CONST, cast(int) e.Voffset);
                    cg.emit(OP_I32_ADD);
                }
            }
            else if (rs && rs.Sfl == FL.func)
            {
                // Address of a function → WASM table index for call_indirect.
                import dmd.backend.wasmobj : wmod_funcTableIndex;

                uint tidx = wmod_funcTableIndex(rs);
                cg.emitConst(OP_I32_CONST, cast(int) tidx);
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
                    cg.emitShadowAddr(as);
                    return true;
                }
            }
            // Fallback: just evaluate E1 address (e.g., OPaddr of global)
            return cg.genElem(e.E1);
        }

    case OPind:
        {
            cg.genElem(e.E1); // address on stack
            cg.emitLoad(e.Ety);
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
                    cg.genElem(e.E2);
                    cg.emitStore(e.E1.Ety);
                    // Re-load for expression result
                    cg.emitDataAddr(lhs, cast(uint) e.E1.Voffset);
                    cg.emitLoad(e.E1.Ety);
                    return true;
                }
                // Shadow-frame local: store to linear memory, reload for result.
                if (cg.inShadow(lhs))
                {
                    cg.emitShadowAddr(lhs);
                    if (e.E1.Voffset != 0)
                    {
                        cg.emitConst(OP_I32_CONST, cast(int) e.E1.Voffset);
                        cg.emit(OP_I32_ADD);
                    }
                    cg.genElem(e.E2);
                    cg.emitStore(e.E1.Ety);
                    cg.emitShadowAddr(lhs);
                    cg.emitLoad(e.E1.Ety);
                    return true;
                }
                const uint idx = cg.localFor(lhs);
                cg.genElem(e.E2);

                tym_t rhsTy = e.E2.Ety;

                // Coerce i32→i64 if needed (e.g. assigning integer to ulong local).
                if (cg.locals[idx].ty == WASM_I64 && wasmType(rhsTy) == WASM_I32)
                    cg.emit(OP_I64_EXTEND_I32_S);
                // Bit-pun assignments arising from *cast(long*)&y and similar:
                // optelem can collapse OPind(OPaddr(localf)) into the float value
                // and leave the type-mismatched OPeq for the codegen to widen.
                else if (cg.locals[idx].ty == WASM_I64 && wasmType(rhsTy) == WASM_F32)
                {
                    cg.emit(OP_I32_REINTERPRET_F32);
                    cg.emit(OP_I64_EXTEND_I32_U);
                }
                else if (cg.locals[idx].ty == WASM_I64 && wasmType(rhsTy) == WASM_F64)
                    cg.emit(OP_I64_REINTERPRET_F64);
                else if (cg.locals[idx].ty == WASM_F32 && wasmType(rhsTy) == WASM_I64)
                {
                    // i64 → low 32 bits → f32
                    cg.emit(OP_I32_WRAP_I64);
                    cg.emit(OP_F32_REINTERPRET_I32);
                }
                else if (cg.locals[idx].ty == WASM_F32 && wasmType(rhsTy) == WASM_I32)
                    cg.emit(OP_F32_REINTERPRET_I32);
                else if (cg.locals[idx].ty == WASM_F64 && wasmType(rhsTy) == WASM_I64)
                    cg.emit(OP_F64_REINTERPRET_I64);
                // Numeric narrowings the optimizer left for codegen.
                else if (cg.locals[idx].ty == WASM_I32 && wasmType(rhsTy) == WASM_F32)
                    cg.emit(OP_I32_TRUNC_F32_S);
                else if (cg.locals[idx].ty == WASM_I32 && wasmType(rhsTy) == WASM_F64)
                    cg.emit(OP_I32_TRUNC_F64_S);
                else if (cg.locals[idx].ty == WASM_I32 && wasmType(rhsTy) == WASM_I64)
                    cg.emit(OP_I32_WRAP_I64);

                // Mask if storing into a narrow-type local (ubyte, bool, short, etc.).
                cg.maskSmallInt(e.E1.Ety);

                cg.emit(OP_LOCAL_TEE);
                cg.emitULEB(idx);
                return true;
            }
            else if (e.E1.Eoper == OPind)
            {
                // Store to memory. Save result in a temp to avoid re-evaluating
                // E2 (which may have side effects like i++ in arr[k++] = L[i++]).
                cg.genElem(e.E1.E1); // address
                cg.genElem(e.E2); // value
                uint valTmp = cg.allocTemp(wasmType(e.Ety));
                cg.emit(OP_LOCAL_TEE);
                cg.emitULEB(valTmp); // save, keep on stack
                cg.emitStore(e.E1.Ety); // store [addr, val]
                cg.emitLocal(OP_LOCAL_GET, valTmp); // result
                return true;
            }
            // Fallthrough: unsupported, just evaluate RHS
            cg.genElem(e.E2);
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
                    cg.emitLoad(e.E1.Ety);
                    cg.genElem(e.E2);
                    emitCoerce(cg, wasmType(e.E2.Ety), wasmType(e.Ety));
                    cg.emitBinop(compoundToBinop(op), e.Ety);
                    cg.emitStore(e.E1.Ety);
                    cg.emitDataAddr(s, addend);
                    cg.emitLoad(e.E1.Ety);
                    return true;
                }
                // Shadow-frame local compound assignment.
                if (cg.inShadow(s))
                {
                    cg.emitShadowAddr(s);
                    cg.emitLoad(e.E1.Ety);
                    cg.genElem(e.E2);
                    emitCoerce(cg, wasmType(e.E2.Ety), wasmType(e.Ety));
                    cg.emitBinop(compoundToBinop(op), e.Ety);
                    // Stash result, then push [addr, value] in store order.
                    uint valTmp2 = cg.allocTemp(wasmType(e.Ety));
                    cg.emit(OP_LOCAL_SET);
                    cg.emitULEB(valTmp2);
                    cg.emitShadowAddr(s);
                    cg.emitLocal(OP_LOCAL_GET, valTmp2);
                    cg.emitStore(e.E1.Ety);
                    cg.emitShadowAddr(s);
                    cg.emitLoad(e.E1.Ety);
                    return true;
                }
                const uint idx = cg.localFor(s);
                cg.emitLocal(OP_LOCAL_GET, idx);
                cg.genElem(e.E2);
                emitCoerce(cg, wasmType(e.E2.Ety), wasmType(e.Ety));
                cg.emitBinop(compoundToBinop(op), e.Ety);
                // Mask for narrow types (ubyte, ushort, etc.) to preserve wrapping.
                cg.maskSmallInt(e.E1.Ety);

                cg.emit(OP_LOCAL_TEE);
                cg.emitULEB(idx);
                return true;
            }
            if (e.E1.Eoper == OPind)
            {
                // *ptr op= rhs : load ptr, dup, load, op, store, load-result
                // Need ptr evaluated once; use a temp local for it
                cg.genElem(e.E1.E1); // ptr addr on stack
                // Duplicate addr via a temp local
                uint tmp = cg.allocTemp(WASM_I32);
                cg.emit(OP_LOCAL_TEE);
                cg.emitULEB(tmp);
                cg.emitLoad(e.E1.Ety);
                cg.genElem(e.E2);
                emitCoerce(cg, wasmType(e.E2.Ety), wasmType(e.Ety));
                cg.emitBinop(compoundToBinop(op), e.Ety);
                // Now: result on stack. Store then reload.
                // We need addr again: local.get tmp; swap; store; local.get tmp; load
                uint valTmp = cg.allocTemp(wasmType(e.Ety));
                cg.emit(OP_LOCAL_SET);
                cg.emitULEB(valTmp);
                cg.emitLocal(OP_LOCAL_GET, tmp);
                cg.emitLocal(OP_LOCAL_GET, valTmp);
                cg.emitStore(e.E1.Ety);
                cg.emitLocal(OP_LOCAL_GET, tmp);
                cg.emitLoad(e.E1.Ety);
                return true;
            }
            cg.genElem(e.E2);
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
            cg.genElem(e.E1);
            emitCoerce(cg, wasmType(e.E1.Ety), rty);
            cg.genElem(e.E2);
            emitCoerce(cg, wasmType(e.E2.Ety), rty);
            cg.emitBinop(op, e.Ety);
            return true;
        }

    case OPeqeq:
    case OPne:
    case OPlt:
    case OPle:
    case OPgt:
    case OPge:
        {
            cg.genElem(e.E1);
            cg.genElem(e.E2);
            emitCoerce(cg, wasmType(e.E2.Ety), wasmType(e.E1.Ety));
            emitRelop(cg, op, e.E1.Ety);
            return true;
        }

    case OPneg:
        {
            const ty = tybasic(e.Ety).wasmType;
            if (ty == WASM_F32)
            {
                cg.genElem(e.E1);
                cg.emit(OP_F32_NEG);
            }
            else if (ty == WASM_F64)
            {
                cg.genElem(e.E1);
                cg.emit(OP_F64_NEG);
            }
            else if (ty == WASM_I64)
            {
                // i64.neg = 0 - x
                cg.emitConst(OP_I64_CONST, 0);
                cg.genElem(e.E1);
                cg.emit(OP_I64_SUB);
            }
            else if (ty == WASM_I32)
            {
                cg.emitConst(OP_I32_CONST, 0);
                cg.genElem(e.E1);
                cg.emit(OP_I32_SUB);
            }
            else
            {
                assert(0); // - operator only works on primitive type
            }
            return true;
        }

    case OPnot:
        cg.genElem(e.E1);
        emitCondInvert(cg, e.E1);
        return true;

    case OPcom:
        {
            cg.genElem(e.E1);
            const ty = tybasic(e.Ety).wasmType;
            if (ty == WASM_I64)
            {
                cg.emitConst(OP_I64_CONST, -1);
                cg.emit(OP_I64_XOR);
            }
            else if (ty == WASM_I32)
            {
                cg.emitConst(OP_I32_CONST, -1);
                cg.emit(OP_I32_XOR);
            }
            else
            {
                assert(0); // ~ operator not defined for float types
            }
            return true;
        }

    // unsigned widening is a no-op
    case OPu8_16:
    case OPu16_32:
        cg.genElem(e.E1);
        return true;

    case OPs8_16: return unaryOp(OP_I32_EXTEND8_S);
    case OPs16_32: return unaryOp(OP_I32_EXTEND16_S);
    case OPu32_64: return unaryOp(OP_I64_EXTEND_I32_U);
    case OPs32_64: return unaryOp(OP_I64_EXTEND_I32_S);
    case OP64_32: return unaryOp(OP_I32_WRAP_I64);
    case OPd_f: return unaryOp(OP_F32_DEMOTE_F64);
    case OPf_d: return unaryOp(OP_F64_PROMOTE_F32);
    case OPd_s32: return unaryOp(OP_I32_TRUNC_F64_S);
    case OPd_s64: return unaryOp(OP_I64_TRUNC_F64_S);
    case OPs32_d: return unaryOp(OP_F64_CONVERT_I32_S);
    case OPs64_d: return unaryOp(OP_F64_CONVERT_I64_S);
    case OPu32_d: return unaryOp(OP_F64_CONVERT_I32_U);
    case OPu64_d: return unaryOp(OP_F64_CONVERT_I64_S);

    case OPmsw:
        // Extract high 32 bits of a 64-bit value (ptr part of D slice on wasm32).
        cg.genElem(e.E1);
        cg.emitConst(OP_I64_CONST, 32);
        cg.emit(OP_I64_SHR_U);
        cg.emit(OP_I32_WRAP_I64);
        return true;

    case OP16_8:
        // Truncate 16→8 bit (e.g. cast(char)(expr)). Mask low 8 bits.
        cg.genElem(e.E1);
        cg.emitConst(OP_I32_CONST, 0xFF);
        cg.emit(OP_I32_AND);
        return true;

    case OP32_16:
        // Truncate 32→16 bit (e.g. cast(short)(expr)). Mask low 16 bits.
        cg.genElem(e.E1);
        cg.emitConst(OP_I32_CONST, 0xFFFF);
        cg.emit(OP_I32_AND);
        return true;

    case OPcomma:
        if (cg.genElem(e.E1))
            cg.emit(OP_DROP); // discard left-hand result
        return cg.genElem(e.E2);

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
                // C variadic requires at least one fixed parameter (e.g. `printf(fmt, ...)`).
                // Bare TYnfunc/TYjfunc types set TF.prototype with no Tparamtypes — those are
                // unprototyped declarations (typical of runtime/RTL symbols built via type_fake),
                // not real variadics, and must not enter the spill-to-shadow path.
                const bool isCVariadic = calleeSym.Stype !is null &&
                    calleeSym.Stype.Tparamtypes !is null &&
                    variadic(calleeSym.Stype);

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
                    void gatherArgs(elem* p) nothrow
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
                        struct VaSlot
                        {
                            elem* e;
                            uint off;
                            ubyte storeOp;
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
                        uint spIdx = wmod_getOrCreateStackPtrGlobal();
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
                    else
                    {
                        // No variadic args: pass null pointer per LDC2 convention.
                        cg.emitConst(OP_I32_CONST, 0);
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
                                aparams ~= tybasic(a.Ety).wasmType;
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
                        cg.emitLocal(OP_LOCAL_GET, spLocal);
                        cg.emitConst(OP_I32_CONST, cast(int) vaFrameSize);
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
                    // Gather args in WASM call order. For D linkage (TYjfunc),
                    // the function signature's globsym is built by reversing
                    // the source params then prepending sthis/shidden, so the
                    // declared param order is [this, shidden, line, file, args]
                    // (reversed src + leading hidden). The caller-side OPparam
                    // tree is built as left-fold of source-order args with
                    // ethis (and ehidden) appended last: OPparam(.. (args,file) .. line), this).
                    // Visiting E2 first then E1 walks this tree to produce the
                    // matching order: [this, line, file, args].
                    elem*[] callArgs;
                    void gatherCallArgs(elem* p) nothrow
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

                    // Slice handling: the WASM callee ABI splits each D slice
                    // parameter into two i32s (len, ptr). At IR level, many
                    // callers pre-split slice args into separate (OPconst
                    // length, OPrelconst ptr) entries — those flow through
                    // as plain i32 args. Other callers pass a packed i64
                    // slice value (OPpair, OPvar of a slice local, OPind of
                    // slice address, OPcall returning a slice). For the
                    // latter we must split on the value stack: pop i64,
                    // push wrap(lo) and shr(hi).
                    //
                    // Split only when the arg width is i64 (TYullong/TYllong)
                    // AND there's evidence the value is a slice — either the
                    // elem itself looks like a slice, or the matching callee
                    // parameter is declared as a slice.
                    //
                    // Param alignment: Tparamtypes is in source-declaration
                    // order. D linkage (TYjfunc) reverses params in globsym,
                    // so callArgs (gathered to match the callee's WASM ABI
                    // order) is reversed relative to source declaration. We
                    // reverse Tparamtypes into a flat array to align by
                    // position, then prepend nulls for any hidden leading
                    // args (this/shidden) when callArgs has more entries
                    // than declared params.
                    param_t*[] declParams;
                    for (param_t* q = (calleeSym.Stype !is null) ? calleeSym.Stype.Tparamtypes
                        : null; q; q = q.Pnext)
                        declParams ~= q;
                    // Only D-linkage (TYjfunc) reverses params in globsym; the
                    // gathered callArgs walk matches that reversed order. For
                    // extern(C) (TYnfunc) and other C-style linkages, declParams
                    // is already in source order — same as callArgs.
                    const calleeTy = (calleeSym.Stype !is null)
                        ? tybasic(calleeSym.Stype.Tty) : TYnfunc;
                    if (calleeTy == TYjfunc)
                    {
                        foreach (k; 0 .. declParams.length / 2)
                        {
                            auto t = declParams[k];
                            declParams[k] = declParams[declParams.length - 1 - k];
                            declParams[declParams.length - 1 - k] = t;
                        }
                    }
                    // Align each callArg to its matching declared param. Slice
                    // params may appear in callArgs either as a single i64 packed
                    // value or as two pre-split i32 entries (len, ptr) — walk
                    // declParams right-to-left consuming callArgs from the end so
                    // any hidden leading args (frame/this/sret) land at index < 0
                    // and resolve to pp=null.
                    param_t*[] ppPerArg;
                    ppPerArg.length = callArgs.length;
                    {
                        ptrdiff_t ai = cast(ptrdiff_t) callArgs.length - 1;
                        ptrdiff_t pi = cast(ptrdiff_t) declParams.length - 1;
                        while (ai >= 0 && pi >= 0)
                        {
                            auto q = declParams[pi];
                            if (paramIsSlice(q) && ai >= 1
                                && tybasic(callArgs[ai].Ety) != TYullong
                                && tybasic(callArgs[ai].Ety) != TYllong)
                            {
                                // Pre-split: (len, ptr) — both map to the slice pp.
                                ppPerArg[ai] = q;
                                ppPerArg[ai - 1] = q;
                                ai -= 2;
                            }
                            else
                            {
                                ppPerArg[ai] = q;
                                ai -= 1;
                            }
                            pi -= 1;
                        }
                    }
                    ubyte[] aparams;
                    foreach (i, a; callArgs)
                    {
                        const tym_t aty = tybasic(a.Ety);
                        param_t* pp = ppPerArg[i];
                        bool asSlice = false;
                        if (aty == TYullong || aty == TYllong)
                        {
                            asSlice = isSliceElem(a) || paramIsSlice(pp);
                            // Force packed i64 (no split) when the callee's
                            // matching param is declared as a delegate — its
                            // Tnext.Tty is a function type. paramIsSlice's
                            // delegate filter already returns false, but the
                            // isSliceElem branch can still fire when the
                            // optimizer rebuilt the delegate as OPshl/OPor.
                            if (asSlice && pp && pp.Ptype && pp.Ptype.Tnext
                                && tyfunc(pp.Ptype.Tnext.Tty) != 0)
                                asSlice = false;
                        }
                        // Aggregate (struct/static-array) param is passed by pointer
                        // (i32) per buildFuncType. Emit the arg's address instead
                        // of its loaded value:
                        //   OPind(addr) → addr
                        //   OPvar(shadow-frame sym) → shadow address + Voffset
                        //   OPvar(data sym) → data address + Voffset
                        // Otherwise the callee would receive a loaded i64/i32
                        // struct value where its WASM signature expects an i32
                        // pointer.
                        if (paramIsAggregate(pp) && emitAggregateArgAsPointer(cg, a))
                        {
                            aparams ~= WASM_I32;
                            continue;
                        }
                        // Independent of pp matching: when the arg expression
                        // is OPind of an OPcall that returns a struct via sret,
                        // the call leaves the sret address on the stack — load
                        // would consume it and produce a struct value instead
                        // of the pointer the callee expects. Treat as pointer.
                        // (pp may be misclassified when the callee's slice
                        // params get pre-split in callArgs and confuse the
                        // leading-hidden count.)
                        if (a.Eoper == OPind && a.E1 &&
                            (a.E1.Eoper == OPcall || a.E1.Eoper == OPucall) &&
                            a.E1.E1 && a.E1.E1.Eoper == OPvar && a.E1.E1.Vsym &&
                            a.E1.E1.Vsym.Stype && a.E1.E1.Vsym.Stype.Tnext &&
                            (tybasic(a.E1.E1.Vsym.Stype.Tnext.Tty) == TYstruct ||
                             tybasic(a.E1.E1.Vsym.Stype.Tnext.Tty) == TYarray))
                        {
                            cg.genElem(a.E1);
                            aparams ~= WASM_I32;
                            continue;
                        }
                        // Also detect OPind(OPadd(OPvar(struct-typed local), const))
                        // with i64 result type — a "load struct value from a
                        // pointer into an aggregate", which arises when an arg
                        // expression dereferences a struct field of an enclosing
                        // aggregate (param-ptr or shadow-frame). Pass the address.
                        if (a.Eoper == OPind && a.E1 && a.E1.Eoper == OPadd &&
                            a.E1.E1 && a.E1.E1.Eoper == OPvar && a.E1.E1.Vsym &&
                            a.E1.E1.Vsym.Stype &&
                            (tybasic(a.E1.E1.Vsym.Stype.Tty) == TYstruct ||
                             tybasic(a.E1.E1.Vsym.Stype.Tty) == TYarray) &&
                            (tybasic(a.Ety) == TYllong || tybasic(a.Ety) == TYullong))
                        {
                            cg.genElem(a.E1);
                            aparams ~= WASM_I32;
                            continue;
                        }
                        genOneArg(cg, a, asSlice);
                        if (asSlice)
                        {
                            aparams ~= WASM_I32;
                            aparams ~= WASM_I32;
                        }
                        else
                        {
                            // Coerce pushed type to the callee's declared param
                            // type when they differ (e.g. i32 ptr sign-extended
                            // to i64 by an OPs32_64 cast, but callee declared
                            // the param as a plain i32 pointer).
                            ubyte pushedTy = wasmType(aty);
                            if (pp && pp.Ptype && !paramIsSlice(pp))
                            {
                                ubyte declTy = wasmType(pp.Ptype.Tty);
                                // Only coerce within the integer domain. Crossing
                                // into float would misinterpret pointer-like ints
                                // as numeric values.
                                bool intDomain(ubyte t) { return t == WASM_I32 || t == WASM_I64; }
                                if (declTy != pushedTy && intDomain(declTy) && intDomain(pushedTy))
                                {
                                    emitCoerce(cg, pushedTy, declTy);
                                    pushedTy = declTy;
                                }
                            }
                            aparams ~= pushedTy;
                        }
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

                // Emit args first (e.E2). For OPucall, e.E2 is null and this is a no-op.
                // Then the function pointer, then call_indirect.
                genArgs(cg, e.E2);

                // Derive the indirect-call type authoritatively from the call site
                // (e.E2 for args, e.Ety for result). The symbol's Stype on a
                // function-pointer local is often a plain int/void* and yields no
                // function-type info — relying on it produced wrong (type 0) sigs.
                import dmd.backend.wasmobj : wmod_internType;

                ubyte[] callParams;
                void collectArgTypes(elem* p) nothrow
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
                        callParams ~= WASM_I32;
                        callParams ~= WASM_I32;
                    }
                    else
                        callParams ~= wasmType(tybasic(p.Ety));
                }
                collectArgTypes(e.E2);
                ubyte[] callResults;
                {
                    const tym_t retTy0 = tybasic(e.Ety);
                    if (retTy0 != TYvoid && retTy0 != TYnoreturn)
                        callResults ~= wasmType(retTy0);
                }
                uint typeIdx = wmod_internType(callParams, callResults);

                elem* fexpr = e.E1;
                Symbol* fpSym = null;
                if (fexpr.Eoper == OPind && fexpr.E1 && fexpr.E1.Eoper == OPvar)
                {
                    // OPind(OPvar(fptr)) — fptr holds a table index.
                    fpSym = fexpr.E1.Vsym;
                    if (fpSym && isLocalSym(fpSym) && !cg.inShadow(fpSym))
                    {
                        const uint idx = cg.localFor(fpSym);
                        cg.emitLocal(OP_LOCAL_GET, idx);
                    }
                    else
                    {
                        cg.genElem(fexpr.E1);
                    }
                }
                else
                {
                    // Virtual dispatch / general function pointer.
                    elem* fn = (fexpr.Eoper == OPind) ? fexpr.E1 : fexpr;
                    cg.genElem(fn);
                }
                cg.emit(OP_CALL_INDIRECT);
                cg.emitCallIndirectType(typeIdx);
                cg.emitULEB(0); // table index 0
            }
            // Whether the call left a value on the WASM stack depends on the
            // callee's WASM signature, not e.Ety. For direct calls to a function
            // defined in this module, e.Ety can disagree with the function's
            // actual return type (e.g. a void member call appearing in an
            // OPcomma chain): trust the callee's Stype.Tnext.
            const retTy = tybasic(e.Ety);
            bool pushedValue = retTy != TYvoid && retTy != TYnoreturn;
            if (e.E1.Eoper == OPvar && e.E1.Vsym && e.E1.Vsym.Stype && e.E1.Vsym.Stype.Tnext)
            {
                const tym_t calleeRet = tybasic(e.E1.Vsym.Stype.Tnext.Tty);
                pushedValue = calleeRet != TYvoid && calleeRet != TYnoreturn;
            }
            return pushedValue;
        }

    case OPcond:
        {
            // e.E1 ? e.E2.E1 : e.E2.E2
            cg.genElem(e.E1);
            emitCondToI32(cg, e.E1); // i64 cond → i32 truthiness
            const bool voidCond = tybasic(e.Ety) == TYvoid || tybasic(e.Ety) == TYnoreturn;
            cg.emit(OP_IF);
            if (voidCond)
                cg.emit(WASM_VOID_BLOCK); // void blocktype: discard any branch value
            else
                cg.emit(wasmType(e.Ety));
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
            emitCondToI32(cg, e.E1); // i64 cond → i32 truthiness
            cg.emit(OP_IF);
            cg.emit(WASM_I32);
            cg.emitConst(OP_I32_CONST, 1);
            cg.emit(OP_ELSE);
            cg.genElem(e.E2);
            if (tybasic(e.E2.Ety) == TYvoid || tybasic(e.E2.Ety) == TYnoreturn)
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
            if (tybasic(e.E2.Ety) == TYvoid || tybasic(e.E2.Ety) == TYnoreturn)
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

    case OPsizeof:
        // Sizeof (compile-time constant, should be folded)
        cg.emitConst(OP_I32_CONST, cast(int) e.Vlong);
        return true;

    case OPpostinc:
    case OPpostdec:
        {
            if (e.E1.Eoper == OPvar)
            {
                const uint idx = cg.localFor(e.E1.Vsym);
                cg.emitLocal(OP_LOCAL_GET, idx); // old value (result)
                cg.emitLocal(OP_LOCAL_GET, idx);
                cg.genElem(e.E2);
                cg.emitBinop(op == OPpostinc ? OPadd : OPmin, e.Ety);
                cg.emit(OP_LOCAL_SET);
                cg.emitULEB(idx);
                return true;
            }
            cg.genElem(e.E1);
            return true;
        }

    case OPpreinc:
    case OPpredec:
        {
            if (e.E1.Eoper == OPvar)
            {
                const uint idx = cg.localFor(e.E1.Vsym);
                cg.emitLocal(OP_LOCAL_GET, idx);
                cg.genElem(e.E2);
                cg.emitBinop(op == OPpreinc ? OPadd : OPmin, e.Ety);
                cg.emit(OP_LOCAL_TEE);
                cg.emitULEB(idx);
                return true;
            }
            cg.genElem(e.E1);
            return true;
        }

    case OPpair:
    case OPrpair:
        {
            // OPpair always packs two i32 halves into one i64 quadword
            // (D slices, long long, delegates). The Ety can be TYullong,
            // TYllong, TYdelegate (= TYllong), or wrapper types — always pack.
            // OPpair:  E1=lo (len), E2=hi (ptr) → i64 = (E2<<32) | E1
            // OPrpair: E1=hi (ptr), E2=lo (len) → i64 = (E1<<32) | E2
            elem* loE = (e.Eoper == OPrpair) ? e.E2 : e.E1;
            elem* hiE = (e.Eoper == OPrpair) ? e.E1 : e.E2;
            cg.genElem(hiE);
            cg.emit(OP_I64_EXTEND_I32_U);
            cg.emitConst(OP_I64_CONST, 32);
            cg.emit(OP_I64_SHL);
            cg.genElem(loE);
            cg.emit(OP_I64_EXTEND_I32_U);
            cg.emit(OP_I64_OR);
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
                cg.genElem(e.E2.E2); // src
                emitCoerce(cg, wasmType(e.E2.E2.Ety), WASM_I32);
                cg.genElem(e.E2.E1); // count
                emitCoerce(cg, wasmType(e.E2.E1.Ety), WASM_I32);
            }
            else if (e.E2)
            {
                cg.genElem(e.E2); // src
                emitCoerce(cg, wasmType(e.E2.Ety), WASM_I32);
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
            if (e.E2 && e.E2.Eoper == OPparam)
            {
                cg.genElem(e.E2.E2); // val
                emitCoerce(cg, wasmType(e.E2.E2.Ety), WASM_I32);
                cg.genElem(e.E2.E1); // count
                emitCoerce(cg, wasmType(e.E2.E1.Ety), WASM_I32);
            }
            else
            {
                cg.emitConst(OP_I32_CONST, 0); // val
                cg.emitConst(OP_I32_CONST, 0); // count
            }
            emitMemoryFill(cg);
            cg.emitLocal(OP_LOCAL_GET, dstTmp);
            return true;
        }

    default:
        cg.emit(OP_UNREACHABLE);
        return tybasic(e.Ety) != TYvoid;
    }
}

// Get the address of an lvalue expression (OPind → its pointer; OPvar in shadow → shadow addr; else genElem).
private void genElemAddr(ref WasmCG cg, elem* e)
{
    if (!e)
    {
        cg.emitConst(OP_I32_CONST, 0);
        return;
    }
    if (e.Eoper == OPind)
    {
        cg.genElem(e.E1); // evaluate the pointer
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
                cg.emitShadowAddr(s);
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
        cg.genElem(e);
        return;
    }
    // Generic: evaluate the expression (which should produce an address).
    cg.genElem(e);
}

// Emit argument list (OPparam chain or single elem)
// In DMD IR, OPparam(E1, E2) is right-to-left: E2 is the leftmost argument.
// True if `t` looks like a D delegate (TYllong wrapper with a function-typed
// Tnext). Delegates share the TYllong basic type with slices on WASM32 but
// must NOT be split into (len, ptr) at call sites — buildFuncType passes them
// as a single packed i64 param.
private bool isDelegateType(const(type)* t)
{
    if (!t || !t.Tnext)
        return false;
    return tyfunc(t.Tnext.Tty) != 0;
}

// WASM args are left-to-right on the stack, so emit E2 before E1.
// Return true if a TYullong elem is a D dynamic array (slice).
// On WASM32, TYdarray == TYullong (util_set32 keeps var.d default of TYullong).
// D slices are packed as i64 (len32 | ptr32<<32) and must be split into two
// i32 WASM params when passed as function arguments.
private bool isSliceElem(const(elem)* e)
{
    const tym_t ty = tybasic(e.Ety);
    if (ty != TYullong && ty != TYllong)
        return false;
    // Delegates also live in TYllong with a Tnext, but they're passed packed
    // as a single i64, not split. Detect by Tnext being a function type.
    if (e.ET && isDelegateType(e.ET))
        return false;
    if (e.Eoper == OPvar && e.Vsym && e.Vsym.Stype && isDelegateType(e.Vsym.Stype))
        return false;
    // Explicit element type with Tnext indicates a slice — but only when
    // the wrapper type is TYullong (TYdarray on WASM32). A TYarray wrapper
    // means a static array load and must not be split.
    if (e.ET && e.ET.Tnext && tybasic(e.ET.Tty) == TYullong && !isDelegateType(e.ET))
        return true;
    // OPvar: a true slice symbol has Stype.Tty == TYullong (TYdarray on WASM32)
    // with a Tnext element type. Static arrays use TYarray and must not match.
    if (e.Eoper == OPvar && e.Vsym && e.Vsym.Stype
        && tybasic(e.Vsym.Stype.Tty) == TYullong
        && e.Vsym.Stype.Tnext
        && !isDelegateType(e.Vsym.Stype))
        return true;
    // OPpair/OPrpair always construct a (len, ptr) D slice.
    if (e.Eoper == OPpair || e.Eoper == OPrpair)
        return true;
    // OPcall/OPucall: look at the callee's declared return type for Tnext.
    // The call elem's own Ety is TYullong without Tnext, but the callee
    // symbol's Stype.Tnext carries the slice element type.
    if (e.Eoper == OPcall || e.Eoper == OPucall)
    {
        const(elem)* callee = e.E1;
        // Strip semantic OPind on function pointers.
        if (callee && callee.Eoper == OPind && callee.E1)
            callee = callee.E1;
        if (callee && callee.Eoper == OPvar && callee.Vsym && callee.Vsym.Stype)
        {
            const(type)* ft = callee.Vsym.Stype;
            const(type)* rt = ft.Tnext; // return type
            if (rt && tybasic(rt.Tty) == TYullong && rt.Tnext && !isDelegateType(rt))
                return true;
        }
    }
    // OPind: dereferencing a pointer-to-slice. e.ET (the loaded type) is
    // the most reliable signal — for a slice load it has Tnext (element)
    // pointing to a basic data type. Plain ulong loads (res[0], etc.) have
    // either no Tnext or a Tnext.Tty that isn't a basic scalar.
    if (e.Eoper == OPind)
    {
        if (e.ET && e.ET.Tnext && tybasic(e.ET.Tty) == TYullong
            && !isDelegateType(e.ET))
        {
            const tym_t elemTy = tybasic(e.ET.Tnext.Tty);
            // Slice element should be a basic data type, not a wrapper struct
            // or array (which would indicate a load of an aggregate field).
            if (elemTy != TYstruct && elemTy != TYarray)
                return true;
        }
    }
    return false;
}

// True if a callee parameter type is a D slice (TYdarray == TYullong+Tnext on WASM32).
private bool paramIsSlice(const(param_t)* p)
{
    if (!p || !p.Ptype)
        return false;
    const(type)* t = p.Ptype;
    return tybasic(t.Tty) == TYullong && t.Tnext !is null && !isDelegateType(t);
}

private bool paramIsAggregate(const(param_t)* p)
{
    if (!p || !p.Ptype)
        return false;
    const tym_t tb = tybasic(p.Ptype.Tty);
    return tb == TYstruct || tb == TYarray;
}

// Emit a call argument whose declared param is an aggregate (struct/static
// array) as its address (i32), instead of the loaded struct value. Unwraps
// OPcomma chains, OPind, OPvar of shadow/data symbols. Returns true if it
// emitted the address; false if it didn't recognize the form (caller should
// fall back to genOneArg).
private bool emitAggregateArgAsPointer(ref WasmCG cg, elem* a)
{
    // OPcomma(E1, E2): evaluate E1 for side effects (drop result), then
    // unwrap to E2 — the actual value of the comma expression.
    while (a && a.Eoper == OPcomma)
    {
        const bool r1 = cg.genElem(a.E1);
        if (r1)
            cg.emit(OP_DROP);
        a = a.E2;
    }
    if (!a)
        return false;
    // Strip arbitrary nesting of OPstrpar and OPcomma chains.
    while (a)
    {
        if (a.Eoper == OPstrpar && a.E1)
            a = a.E1;
        else if (a.Eoper == OPcomma)
        {
            const bool r1 = cg.genElem(a.E1);
            if (r1)
                cg.emit(OP_DROP);
            a = a.E2;
        }
        else
            break;
    }
    if (!a)
        return false;
    if (a.Eoper == OPind)
    {
        if (a.E1)
        {
            cg.genElem(a.E1);
            return true;
        }
    }
    if (a.Eoper == OPvar && a.Vsym)
    {
        Symbol* vs = a.Vsym;
        if (cg.inShadow(vs))
        {
            cg.emitShadowAddr(vs);
            if (a.Voffset != 0)
            {
                cg.emitConst(OP_I32_CONST, cast(int) a.Voffset);
                cg.emit(OP_I32_ADD);
            }
            return true;
        }
        if (isDataSym(vs.Sfl))
        {
            cg.emitDataAddr(vs, cast(uint) a.Voffset);
            return true;
        }
    }
    // OPcall returning a struct (sret) already leaves the sret address on
    // the stack — exactly the pointer the callee expects. No extra load.
    if (a.Eoper == OPcall || a.Eoper == OPucall)
    {
        cg.genElem(a);
        return true;
    }
    return false;
}

// Emit a single function argument. D slices (TYdarray = TYullong on WASM32)
// are split into two i32 params (lo=len, hi=ptr) to match the WASM32/LDC2 ABI.
// `forceSlice` forces the split even when the elem itself isn't recognised as
// a slice (e.g. an OPconst null passed where the callee expects char[]).
private void genOneArg(ref WasmCG cg, elem* e, bool forceSlice = false)
{
    cg.genElem(e);
    const bool isDynArray = forceSlice || isSliceElem(e);
    if (isDynArray)
    {
        uint tmp = cg.allocTemp(WASM_I64);
        cg.emit(OP_LOCAL_SET);
        cg.emitULEB(tmp);
        cg.emitLocal(OP_LOCAL_GET, tmp);
        cg.emit(OP_I32_WRAP_I64); // lo = len (low 32 bits)
        cg.emitLocal(OP_LOCAL_GET, tmp);
        cg.emitConst(OP_I64_CONST, 32);
        cg.emit(OP_I64_SHR_U);
        cg.emit(OP_I32_WRAP_I64); // hi = ptr (high 32 bits)
    }
}

// Walk the OPparam tree to push args in the declared param order.
// For D linkage (TYjfunc), globsym is built by reversing the source-order
// params then prepending sthis/shidden, while the OPparam tree from e2ir is
// a left-fold of source-order args with sthis/shidden appended at the tail
// (root.E2). Visiting E2 first then E1 yields [this, line, file, args] — the
// matching push order.
private void genArgs(ref WasmCG cg, elem* e)
{
    if (!e)
        return;
    if (e.Eoper == OPparam)
    {
        genArgs(cg, e.E2);
        genArgs(cg, e.E1);
    }
    else
    {
        genOneArg(cg, e);
    }
}

// Pick the WASM opcode variant matching the IR operand's numeric kind.
// Order: f32, f64, i64, i32. Pass OP_UNREACHABLE for kinds that don't apply.
private ubyte pickByKind(tym_t ty, ubyte f32, ubyte f64, ubyte i64, ubyte i32)
{
    switch (tybasic(ty).wasmType)
    {
    case WASM_F32: return f32;
    case WASM_F64: return f64;
    case WASM_I64: return i64;
    case WASM_I32: return i32;
    default: return i32;
    }
}

private ubyte pickByKindSigned(tym_t ty, ubyte f32, ubyte f64, ubyte i64, ubyte s64, ubyte i32, ubyte s32)
{
    const bool isUns = tyuns(ty) != 0;
    switch (tybasic(ty).wasmType)
    {
    case WASM_F32: return f32;
    case WASM_F64: return f64;
    case WASM_I64: return isUns ? i64 : s64;
    case WASM_I32: return isUns ? i32 : s32;
    default: return i32;
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
                isUns ? OP_I64_DIV_U
                    : OP_I64_DIV_S,
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
        default:
            return OP_UNREACHABLE;
        }
    }

    cg.emit(binOp(op, ty));
}

// Map compound-assignment op to its binary counterpart
alias compoundToBinop = opeqtoop;

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
            return OP_UNREACHABLE;
        }
    }
    cg.emit(relOp(op, ty));
}

/// Function index lookup
///
/// Returns: index of `sfunc`
private uint funcIndex(Symbol* sfunc)
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

// Ensure a condition value on the WASM stack is an i32 suitable for br_if.
private void emitCondToI32(ref WasmCG cg, elem* condElem, bool invert = false)
{
    if (!condElem)
    {
        if (invert)
            cg.emit(OP_I32_EQZ);
        return;
    }
    const ty = tybasic(condElem.Ety).wasmType;
    if (ty == WASM_I64)
    {
        cg.emit(OP_I64_EQZ); // i64 → i32: 1 if zero, 0 if nonzero

        if (!invert)
            cg.emit(OP_I32_EQZ); // invert again, `cast(bool) i = !!i`
    }
    else if (ty == WASM_F32)
    {
        // f32 truthiness: nonzero (NaN is truthy under WASM's NE semantics).
        cg.emit(OP_F32_CONST);
        float fz = 0.0f;
        cg.code.write(&fz, 4);
        cg.emit(invert ? OP_F32_EQ : OP_F32_NE);
    }
    else if (ty == WASM_F64)
    {
        cg.emit(OP_F64_CONST);
        double dz = 0.0;
        cg.code.write(&dz, 8);
        cg.emit(invert ? OP_F64_EQ : OP_F64_NE);
    }
    else if (ty == WASM_I32)
    {
        cg.emitConst(OP_I32_CONST, 0);
        cg.emit(invert ? OP_I32_EQ : OP_I32_NE);
    }
}

// Emit the inversion of a condition for "branch if FALSE" patterns (cond; eqz; br_if).
private void emitCondInvert(ref WasmCG cg, elem* condElem)
{
    return emitCondToI32(cg, condElem, true);
}

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

private block*[] collectBlocks(block* start)
{
    block*[] v;
    for (block* b = start; b; b = b.Bnext)
        v ~= b;
    return v;
}

private int blockIdx(block* b)
{
    return b ? b.Bdfoidx : int.max;
}

// Successor index in Bsucc list
private block* succ(block* b, int n)
{
    if (n < b.numSucc())
        return b.nthSucc(n);
    return null;
}

// Structured control flow synthesis (block CFG => WASM)
private void genBlocksProper(ref WasmCG cg, block* startblock, bool hasReturn)
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

    foreach (const bi; 0 .. N)
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
                cg.genElem(b.Belem);
            if (cg.hasShadowFrame)
            {
                if (b.Belem) // return value is on the stack
                {
                    // Save, epilogue, reload.
                    uint retTmp = cg.allocTemp(wasmType(b.Belem.Ety));
                    cg.emit(OP_LOCAL_SET);
                    cg.emitULEB(retTmp);
                    emitShadowEpilogue(cg);
                    cg.emitLocal(OP_LOCAL_GET, retTmp);
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
                const bool v = cg.genElem(b.Belem);
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
                const bool v = cg.genElem(b.Belem);
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
                cg.genElem(b.Belem);
            else
            {
                cg.emitConst(OP_I32_CONST, 0);
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
            uint depthOf(int destIdx)
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
                    cg.emitLocal(OP_LOCAL_GET, condLocal);
                    if (is64bit)
                    {
                        cg.emitConst(OP_I64_CONST, cv);
                        cg.emit(OP_I64_EQ);
                    }
                    else
                    {
                        cg.emitConst(OP_I32_CONST, cast(int) cv);
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
                cg.emitConst(OP_I32_CONST, cast(int)-vmin);
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
        else if (b.bc == BC.ifthen || b.bc == BC.iftrue)
        {
            // switch converted to if-then chain is same as iftrue
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
                    cg.genElem(b.Belem);
                else
                {
                    cg.emitConst(OP_I32_CONST, 0);
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
                    cg.genElem(b.Belem);
                else
                {
                    cg.emitConst(OP_I32_CONST, 0);
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
                    cg.genElem(b.Belem);
                else
                {
                    cg.emitConst(OP_I32_CONST, 0);
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
                        cg.genElem(b.Belem);
                    else
                    {
                        cg.emitConst(OP_I32_CONST, 0);
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
                        cg.genElem(b.Belem);
                    else
                    {
                        cg.emitConst(OP_I32_CONST, 0);
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
                        bool v = cg.genElem(b.Belem);
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
                const bool v = cg.genElem(b.Belem);
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
            const bool hasVal = cg.genElem(b.Belem);
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
void wasm_codgen(Symbol* sfunc)
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
        uint loIdx;
        uint hiIdx;
        uint i64Idx;
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
                cg.locals ~= WasmLocal(null, WASM_I32); // lo
                cg.locals ~= WasmLocal(null, WASM_I32); // hi
            }
            else
            {
                cg.locals ~= WasmLocal(s, s.ty().wasmType);
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
        cg.emitLocal(OP_LOCAL_GET, sp.hiIdx); // ptr
        cg.emit(OP_I64_EXTEND_I32_U);
        cg.emitConst(OP_I64_CONST, 32);
        cg.emit(OP_I64_SHL);
        cg.emitLocal(OP_LOCAL_GET, sp.loIdx); // len
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

    // If the function has a return type but every path that reaches here did
    // so via an unreachable construct (infinite loop with internal returns,
    // assert-noreturn tail, etc.), the implicit-return point still needs to
    // satisfy WASM's type checker. Emit unreachable so the validator treats
    // the fallthrough as a polymorphic stack.
    if (hasReturn)
        cg.emit(OP_UNREACHABLE);

    // Store results back into the WasmFuncBody
    fb.locals = cg.locals;
    fb.numParams = cg.numParams;
    fb.codeRelocs = cg.codeRelocs;
    fb.dataAddrRelocs = cg.dataAddrRelocs;
    fb.code.reset();
    fb.code.write(cg.code.peekSlice());
}
