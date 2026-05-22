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

    default:
        debug writeln("ty = ", tym_str(ty).fromStringz);
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

bool typeHasValue(tym_t ty)
{
    return tybasic(ty) == TYvoid || tybasic(ty) == TYnoreturn;
}

/// Per-function code-generation state
struct WasmCG
{
    OutBuffer code; /// bytecode being emitted
    WasmLocal[] locals; /// local variable table (params first)
    uint numParams; /// number of parameters (= first numParams locals)
    bool relocatable; /// generate relocatable
    WasmFuncBody.CodeReloc[] codeRelocs; /// relocations for direct function calls
    WasmFuncBody.DataAddrReloc[] dataAddrRelocs; /// R_WASM.MEMORY_ADDR_LEB relocations

    // Shadow stack frame
    bool hasShadowFrame;

    uint shadowBaseLocal; /// WASM local index holding the shadow frame base address
    uint shadowFrameSize; /// total size in bytes of shadow frame
    Symbol*[] shadowEntries; /// per-symbol shadow frame offsets

nothrow:

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
    static bool inShadow(Symbol* s)
    {
        return (s.Sflags & SFLwasmshadow) != 0;
    }

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
    // In relocatable mode, emits a 5-byte padded ULEB128 and records a
    // R_WASM.MEMORY_ADDR_LEB relocation so wasm-ld patches the address after
    // moving the data section to its final location.
    // In non-relocatable (final) mode, emits a compact SLEB128 — the data
    // section is already at its final address in that case.
    void emitDataAddr(Symbol* sym, uint addend)
    {
        emit(OP_I32_CONST);
        const uint addr = cast(uint)(sym.Soffset + addend);

        // Only relocate symbols in the INITIALIZED data section (FL.data, FL.csdata,
        // FL.datseg).  BSS (FL.udata) variables have offsets relative to the BSS
        // region which is handled differently by wasm-ld; they don't map to a
        // valid offset in the single initialized data segment.
        // Only relocate symbols in the INITIALIZED data section.
        // BSS (FL.udata) and TLS (FL.tlsdata) have offsets beyond the active
        // data segment and don't map to valid WASM_SYMTAB.DATA entries in it.
        const bool canRelocate = relocatable && sym.Sident.ptr != null &&
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
        if (relocatable)
        {
            codeRelocs ~= WasmFuncBody.CodeReloc(cast(uint) code.length,
                R_WASM.TABLE_INDEX_SLEB, fidx, 0, sym);
            emitULEBpadded(fidx);
        }
        else
        {
            emitSLEB(cast(int) fidx);
        }
    }

    // Emit the type index operand of call_indirect.
    // In relocatable mode, emit R_WASM.TYPE_INDEX_LEB so wasm-ld can patch the
    // type index when merging type tables from multiple objects.  The relocation
    // references a named function whose type matches, preferring imports to avoid
    // a wasm-ld 22 crash on locally-defined symbol targets.  If no suitable
    // function is found yet (rare), fall back to compact ULEB without relocation
    // (type indices are stable for single-file linking via reorderImportTypesFirst).
    void emitCallIndirectType(uint typeIdx)
    {
        import dmd.backend.wasm.obj : wmod_findFuncForType, wmod_funcs;

        if (relocatable)
        {
            uint fidx = wmod_findFuncForType(typeIdx);
            if (fidx != uint.max)
            {
                // Anchor the reloc to the function's Symbol* so currentFuncIdx
                // resolves it correctly even after wmod.funcs is reordered late
                // in codegen — otherwise the stored fidx points at a different
                // function whose typeIdx is unrelated (and often type 0).
                auto reloc = WasmFuncBody.CodeReloc(cast(uint) code.length, R_WASM.TYPE_INDEX_LEB, fidx);
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

/// Emit `<addr> ; load.ty` for the symbol value at `s + off`.
/// Returns: true on success.
bool emitSymLoad(ref WasmCG cg, Symbol* s, uint off, tym_t ty)
{
    if (!emitSymAddr(cg, s, off))
        return false;
    cg.emitLoad(ty);
    return true;
}

/// Emit shadow stack frame prologue (called once at function entry).
/// Creates the shadow base local, gets __stack_pointer, subtracts frame size, stores back.
void emitShadowPrologue(ref WasmCG cg)
{
    import dmd.backend.wasm.obj : wmod_getOrCreateStackPtrGlobal;

    uint spIdx = wmod_getOrCreateStackPtrGlobal();

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
elem*[] gatherCallArgs(elem* p)
{
    elem*[] callArgs;
    void gather(elem* p) nothrow
    {
        if (!p)
            return;
        if (p.Eoper == OPparam)
        {
            gather(p.E2);
            gather(p.E1);
            return;
        }
        callArgs ~= p;
    }
    gather(p);
    return callArgs;
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
    if (e.Eoper == OPvar && e.Vsym &&
        emitSymAddr(cg, e.Vsym, cast(uint) e.Voffset + half))
    {
        cg.emit(OP_I32_LOAD);
        cg.emitMemArg(2, 0);
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
    const tym_t tb = tybasic(p.Ptype.Tty);
    return tb == TYdarray || tb == TYdelegate;
}

// Emit `arg` for a call site. When `slice` is true, the callee expects the
// arg as two separate i32 values (length/context first, then ptr/funcptr) —
// slices/delegates are never packed into a single i64. Load both halves
// directly from the arg's address.
private void emitCallArg(ref WasmCG cg, elem* arg, bool slice)
{
    if (!slice)
    {
        cg.genElem(arg);
        return;
    }
    elem* a = unwrapComma(cg, arg);
    // OPconst null slice/delegate → emit (0, 0).
    if (a.Eoper == OPconst)
    {
        cg.emitConst(OP_I32_CONST, 0);
        cg.emitConst(OP_I32_CONST, 0);
        return;
    }
    if (emitSliceHalf(cg, a, /*ptrHalf*/ false) &&
        emitSliceHalf(cg, a, /*ptrHalf*/ true))
        return;
    // Fallback: well-formed IR shouldn't reach here.
    cg.emit(OP_UNREACHABLE);
}

// Expression code generation
private bool genCall(ref WasmCG cg, elem* e)
{
    // E1 is the function.
    // Direct call: E1 is OPvar of a function symbol.
    if (e.E1.Eoper == OPvar && e.E1.Vsym && e.E1.Vsym.Sclass != SC.auto_ &&
        e.E1.Vsym.Sclass != SC.parameter && e.E1.Vsym.Sclass != SC.fastpar)
    {
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
            elem*[] allArgs = gatherCallArgs(e.E2);

            // Count fixed (non-variadic) params from the function type
            // and collect them positionally for slice-split decisions.
            int nFixed = 0;
            param_t*[] fixedParams;
            for (param_t* p = calleeSym.Stype.Tparamtypes; p; p = p.Pnext)
            {
                fixedParams ~= p;
                nFixed++;
            }

            // Emit fixed args to the WASM value stack. A fixed param
            // declared as a D slice splits the matching i64 arg into
            // (len, ptr). C variadic linkage has no param reversal, so
            // fixedParams aligns with allArgs by position directly.
            foreach (i, a; allArgs[0 .. nFixed])
                emitCallArg(cg, a, paramIsSlice(fixedParams[i]));

            // Compute variadic args layout and emit shadow-stack spill.
            elem*[] varArgs = allArgs[nFixed .. $];

            uint spLocal;
            uint vaFrameSize;
            cg.genVarArgs(varArgs, spLocal, vaFrameSize);

            cg.emitCall(fidx, calleeSym);

            // Restore __stack_pointer after the call.
            if (varArgs.length)
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
            auto callArgs = gatherCallArgs(e.E2);

            param_t*[] declParams;

            assert(calleeSym.Stype);

            auto paramTypes = calleeSym.Stype.Tparamtypes;

            for (param_t* q = paramTypes; q; q = q.Pnext)
                declParams ~= q;

            foreach (i, a; callArgs)
            {
                const bool splitSlice = i < declParams.length && paramIsSlice(declParams[i]);
                emitCallArg(cg, a, splitSlice);
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
        WasmFuncType paramTypesFromElem(elem* e)
        {
            elem*[] args = gatherCallArgs(e.E2);

            WASM_TYPE[] callParams;
            foreach (a; args)
            {
                // if (a.Ety == TYdarray || a.Ety == TYdelegate)

                callParams ~= wasmType(tybasic(a.Ety));
            }
            WASM_TYPE[] callResults;
            {
                const tym_t retTy0 = tybasic(e.Ety);
                if (typeHasValue(retTy0))
                    callResults ~= wasmType(retTy0);
            }
            return WasmFuncType(callParams, callResults);
        }

        // foreach
        cg.genElem(e.E2);
        uint typeIdx = wmod_internType(paramTypesFromElem(e.E2));

        // Function pointer source: strip an outer OPind (fptr table index
        // lives at the address) and evaluate the inner expression to push
        // the table index on the value stack.
        elem* fn = (e.E1.Eoper == OPind && e.E1.E1) ? e.E1.E1 : e.E1;
        cg.genElem(fn);
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
        pushedValue = typeHasValue(calleeRet);
    }
    return pushedValue;
}

/// Code generation for an element
/// Returns: true if the expression has a result on the stack after genElem
bool genElem(ref WasmCG cg, elem* e, WASM_TYPE type)
{
    const result = cg.genElem(e);
    emitCoerce(cg, wasmType(e.Ety), wasmType(e.Ety));
    return result;
}

bool genElem(ref WasmCG cg, elem* e)
{
    if (!e)
        return false;

    const op = e.Eoper;

    // import std.stdio; debug writeln()
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
    case OPconst:
        {
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
        }

    case OPvar:
        {
            Symbol* s = e.Vsym;
            if (emitSymLoad(cg, s, cast(uint) e.Voffset, e.Ety))
                return true;
            // Bare WASM-local fallback (should not normally hit after the
            // shadow-stack refactor — every globsym now lives in shadow).
            const uint idx = cg.localFor(s);
            cg.emitLocal(OP_LOCAL_GET, idx);
            return true;
        }

    case OPrelconst:
        {
            Symbol* rs = e.Vsym;
            // Function address → table-index relocation, not a memory address.
            if (rs && rs.Sfl == FL.func)
            {
                cg.emitTableIndex(funcIndex(rs), rs);
                return true;
            }
            // Memory address — data sym or shadow-frame local.
            emitSymAddr(cg, rs, cast(uint) e.Voffset);
            return true;
        }

    case OPaddr:
        {
            // Address-of operator: OPaddr(OPvar(s, off)).
            if (e.E1 && e.E1.Eoper == OPvar && e.E1.Vsym &&
                emitSymAddr(cg, e.E1.Vsym, cast(uint) e.E1.Voffset))
                return true;
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
                const uint loff = cast(uint) e.E1.Voffset;
                if (emitSymAddr(cg, lhs, loff))
                {
                    cg.genElem(e.E2);
                    cg.emitStore(e.E1.Ety);
                    emitSymLoad(cg, lhs, loff, e.E1.Ety);
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
            // Load lhs, evaluate rhs, apply op, mask narrow, store back, leave result.
            if (e.E1.Eoper == OPvar && e.E1.Vsym)
            {
                Symbol* s = e.E1.Vsym;
                const uint loff = cast(uint) e.E1.Voffset;
                if (emitSymLoad(cg, s, loff, e.E1.Ety))
                {
                    cg.genElem(e.E2, wasmType(e));
                    cg.emitBinop(compoundToBinop(op), e.Ety);
                    cg.maskSmallInt(e.E1.Ety);

                    uint vTmp = cg.allocTemp(wasmType(e.E1.Ety));
                    cg.emit(OP_LOCAL_TEE);
                    cg.emitULEB(vTmp);
                    emitSymAddr(cg, s, loff);
                    cg.emitLocal(OP_LOCAL_GET, vTmp);
                    cg.emitStore(e.E1.Ety);
                    cg.emitLocal(OP_LOCAL_GET, vTmp);
                    return true;
                }
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
            const rty = wasmType(e.Ety);
            cg.genElem(e.E1, rty);
            cg.genElem(e.E2, rty);
            cg.emitBinop(op, e.Ety);
            return true;
        }

    case OPeqeq:
    case OPne:
    case OPlt:
    case OPle:
    case OPgt:
    case OPge:
        cg.genElem(e.E1);
        cg.genElem(e.E2, wasmType(e.E1.Ety));
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

    case OPnot:
        cg.genElem(e.E1);
        emitCondInvert(cg, e.E1);
        return true;

    case OPcom:
        // ~x = x ^ 0xFFFFFFFF
        switch (e.wasmType)
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
        default:
            assert(0); // operator not defined for float types
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
            const bool voidCond = typeHasValue(e.Ety);
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
            emitCondToI32(cg, e.E1);
            cg.emit(OP_IF);
            cg.emit(WASM_I32);
            cg.emitConst(OP_I32_CONST, 1);
            cg.emit(OP_ELSE);
            cg.genElem(e.E2);

            if (typeHasValue(e.E2.Ety))
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
            if (typeHasValue(e.E2.Ety))
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
            if (e.E2 && e.E2.Eoper == OPparam)
            {
                cg.genElem(e.E2.E2, WASM_I32); // val
                cg.genElem(e.E2.E1, WASM_I32); // count
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

    // bit scan forward = count trailing zeros; result is always i32
    case OPbsf:
        switch (e.wasmType)
        {
            case WASM_I64:
                cg.genElem(e.E1);
                cg.emit(OP_I64_CTZ);
                cg.emit(OP_I32_WRAP_I64);
                return true;
            case WASM_I32:
                cg.genElem(e.E1);
                cg.emit(OP_I32_CTZ);
                return true;
            default:
                assert(0);
        }

    case OPbsr:
        switch (e.wasmType)
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
            default:
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

    default:
        cg.emit(OP_UNREACHABLE);
        debug writeln("-----------------");
        elem_print(e);
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
uint funcIndex(Symbol* sfunc)
{
    import dmd.backend.wasm.obj : wasmFuncBodies, wmod_funcs, wmod_numImports;

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
    import dmd.backend.wasm.obj : WasmObj_external;

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
void wasm_codgen(Symbol* sfunc, bool relocatable)
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
    wasm_codgen2(sfunc, *fb, relocatable);
}

// Describes how one WASM-level param slot maps into a shadow-frame slot.
private struct ParamSpill
{
    uint wasmLocalIdx; // index of incoming WASM param
    Symbol* sym;       // symbol whose shadow slot this fills
    uint byteOffset;   // offset within the symbol's shadow slot
    tym_t ty;          // backend type of the param (used to pick store op + alignment)
}

void wasm_codgen2(Symbol* sfunc, ref WasmFuncBody fb, bool relocatable)
{
    WasmCG cg;
    cg.relocatable = relocatable;

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
        if (pty == TYdarray || pty == TYdelegate)
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

    // Always allocate a shadow frame, even when empty — keeps code paths uniform.
    cg.hasShadowFrame = true;
    emitShadowPrologue(cg);

    // Spill incoming WASM params into their shadow-frame slots.
    foreach (ref sp; paramSpills)
    {
        cg.emitLocal(OP_LOCAL_GET, cg.shadowBaseLocal);
        const uint off = cast(uint) sp.sym.Soffset + sp.byteOffset;
        if (off != 0)
        {
            cg.emitConst(OP_I32_CONST, cast(int) off);
            cg.emit(OP_I32_ADD);
        }
        cg.emitLocal(OP_LOCAL_GET, sp.wasmLocalIdx);
        const m = memOpsFor(sp.ty);
        cg.emit(m.storeOp);
        cg.emitMemArg(m.alignLog2, 0);
    }

    block* startblock = sfunc.Sfunc.Fstartblock;
    if (startblock)
        genBlocksProper(cg, startblock, hasReturn);

    if (cg.hasShadowFrame)
        emitShadowEpilogue(cg);

    fb.locals = cg.locals;
    fb.numParams = cg.numParams;
    fb.codeRelocs = cg.codeRelocs;
    fb.dataAddrRelocs = cg.dataAddrRelocs;
    fb.code.reset();
    fb.code.write(cg.code.peekSlice());
}
