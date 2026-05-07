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

/// Per-function code-generation state
struct WasmCG
{
    OutBuffer code; /// bytecode being emitted
    WasmLocal[] locals; /// local variable table (params first)
    uint numParams; /// number of parameters (= first numParams locals)

nothrow:

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

    void emitMemArg(uint align_, uint offset) @trusted
    {
        uleb(&code, align_); // alignment (log2)
        uleb(&code, offset); // byte offset
    }
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
            const uint idx = cg.localFor(e.Vsym);
            cg.emit(OP_LOCAL_GET);
            cg.emitULEB(idx);
            return true;
        }

    case OPrelconst:
        {
            // For WASM, &global_var is its linear memory address (stored as i32.const)
            // The actual address is resolved at link time; emit 0 as placeholder.
            cg.emit(OP_I32_CONST);
            cg.emitSLEB(cast(int) e.Voffset);
            return true;
        }

    case OPind:
        {
            genElem(cg, e.E1); // address on stack
            const ty = tybasic(e.Ety);
            uint sz = tysize(ty);
            switch (ty)
            {
            case TYllong:
            case TYullong:
                cg.emit(OP_I64_LOAD);
                cg.emitMemArg(3, 0);
                break;
            case TYfloat:
                cg.emit(OP_F32_LOAD);
                cg.emitMemArg(2, 0);
                break;
            case TYdouble:
            case TYdouble_alias:
            case TYreal:
                cg.emit(OP_F64_LOAD);
                cg.emitMemArg(3, 0);
                break;
            case TYchar:
            case TYschar:
                cg.emit(OP_I32_LOAD8_S);
                cg.emitMemArg(0, 0);
                break;
            case TYuchar:
            case TYbool:
                cg.emit(OP_I32_LOAD8_U);
                cg.emitMemArg(0, 0);
                break;
            case TYshort:
                cg.emit(OP_I32_LOAD16_S);
                cg.emitMemArg(1, 0);
                break;
            case TYwchar_t:
            case TYushort:
                cg.emit(OP_I32_LOAD16_U);
                cg.emitMemArg(1, 0);
                break;
            default:
                cg.emit(OP_I32_LOAD);
                cg.emitMemArg(2, 0);
                break;
            }
            return true;
        }

    case OPeq:
        {
            if (e.E1.Eoper == OPvar)
            {
                genElem(cg, e.E2);
                const uint idx = cg.localFor(e.E1.Vsym);
                cg.emit(OP_LOCAL_TEE);
                cg.emitULEB(idx); // tee leaves copy on stack
                return true;
            }
            else if (e.E1.Eoper == OPind)
            {
                // Store to memory: address, value => store
                genElem(cg, e.E1.E1); // address
                genElem(cg, e.E2); // value
                const ty = tybasic(e.E1.Ety);
                switch (ty)
                {
                case TYllong:
                case TYullong:
                    cg.emit(OP_I64_STORE);
                    cg.emitMemArg(3, 0);
                    break;
                case TYfloat:
                    cg.emit(OP_F32_STORE);
                    cg.emitMemArg(2, 0);
                    break;
                case TYdouble:
                case TYdouble_alias:
                case TYreal:
                    cg.emit(OP_F64_STORE);
                    cg.emitMemArg(3, 0);
                    break;
                case TYchar:
                case TYschar:
                case TYuchar:
                case TYbool:
                    cg.emit(OP_I32_STORE8);
                    cg.emitMemArg(0, 0);
                    break;
                case TYshort:
                case TYwchar_t:
                case TYushort:
                    cg.emit(OP_I32_STORE16);
                    cg.emitMemArg(1, 0);
                    break;
                default:
                    cg.emit(OP_I32_STORE);
                    cg.emitMemArg(2, 0);
                    break;
                }
                // Store has no result; re-load the value for expression result
                genElem(cg, e.E2);
                return true;
            }
            // Fallthrough: unsupported assignment form
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
            // Only handle simple local var lhs for now
            if (e.E1.Eoper == OPvar)
            {
                const uint idx = cg.localFor(e.E1.Vsym);
                cg.emit(OP_LOCAL_GET);
                cg.emitULEB(idx);
                genElem(cg, e.E2);
                emitBinop(cg, compoundToBinop(op), e.Ety);
                cg.emit(OP_LOCAL_TEE);
                cg.emitULEB(idx);
                return true;
            }
            genElem(cg, e.E2);
            return true;
        }

        // ---- Binary arithmetic / bitwise / shifts ----------------------------
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
            genElem(cg, e.E1);
            genElem(cg, e.E2);
            emitBinop(cg, op, e.Ety);
            return true;
        }

        // ---- Comparisons -----------------------------------------------------
    case OPeqeq:
    case OPne:
    case OPlt:
    case OPle:
    case OPgt:
    case OPge:
        {
            genElem(cg, e.E1);
            genElem(cg, e.E2);
            emitRelop(cg, op, e.E1.Ety);
            return true;
        }

        // ---- Unary -----------------------------------------------------------
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

        // ---- Type conversions ------------------------------------------------
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
            // Push arguments (right-to-left in elem tree => emit left-first for WASM)
            // The E2 param chain: OPparam nodes or a single arg
            genArgs(cg, e.E2);

            // E1 is the function symbol
            if (e.E1.Eoper == OPvar)
            {
                Symbol* sfunc = e.E1.Vsym;
                // Look up function index in wasmFuncBodies
                uint fidx = funcIndex(sfunc);
                cg.emit(OP_CALL);
                cg.emitULEB(fidx);
            }
            else
            {
                // Indirect call — emit address, then call_indirect with type index 0
                genElem(cg, e.E1);
                cg.emit(OP_CALL_INDIRECT);
                cg.emitULEB(0); // type index (simplified)
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
        // Multiple return
        genElem(cg, e.E1);
        genElem(cg, e.E2);
        return true;

    default:
        // Unsupported: emit unreachable to keep stack balanced
        cg.emit(OP_UNREACHABLE);
        return tybasic(e.Ety) != TYvoid;
    }
}

// Emit argument list (OPparam chain or single elem)
private void genArgs(ref WasmCG cg, elem* e) @trusted
{
    if (!e)
        return;
    if (e.Eoper == OPparam)
    {
        genArgs(cg, e.E1);
        genArgs(cg, e.E2);
    }
    else
    {
        genElem(cg, e);
    }
}

// Binary operation opcode selection by IR operator
private void emitBinop(ref WasmCG cg, int op, tym_t ty) @trusted
{
    const bool is64 = (tybasic(ty) == TYllong || tybasic(ty) == TYullong);
    const bool isF32 = (tybasic(ty) == TYfloat);
    const bool isF64 = (tybasic(ty) == TYdouble || tybasic(ty) == TYdouble_alias || tybasic(ty) == TYreal);
    const bool isUns = tyuns(ty) != 0;

    switch (op)
    {
    case OPadd:
        if (isF32)
            cg.emit(OP_F32_ADD);
        else if (isF64)
            cg.emit(OP_F64_ADD);
        else if (is64)
            cg.emit(OP_I64_ADD);
        else
            cg.emit(OP_I32_ADD);
        break;
    case OPmin:
        if (isF32)
            cg.emit(OP_F32_SUB);
        else if (isF64)
            cg.emit(OP_F64_SUB);
        else if (is64)
            cg.emit(OP_I64_SUB);
        else
            cg.emit(OP_I32_SUB);
        break;
    case OPmul:
        if (isF32)
            cg.emit(OP_F32_MUL);
        else if (isF64)
            cg.emit(OP_F64_MUL);
        else if (is64)
            cg.emit(OP_I64_MUL);
        else
            cg.emit(OP_I32_MUL);
        break;
    case OPdiv:
        if (isF32)
            cg.emit(OP_F32_DIV);
        else if (isF64)
            cg.emit(OP_F64_DIV);
        else if (is64)
            cg.emit(isUns ? OP_I64_DIV_U : OP_I64_DIV_S);
        else
            cg.emit(isUns ? OP_I32_DIV_U : OP_I32_DIV_S);
        break;
    case OPmod:
        if (is64)
            cg.emit(isUns ? OP_I64_REM_U : OP_I64_REM_S);
        else
            cg.emit(isUns ? OP_I32_REM_U : OP_I32_REM_S);
        break;
    case OPand:
        cg.emit(is64 ? OP_I64_AND : OP_I32_AND);
        break;
    case OPor:
        cg.emit(is64 ? OP_I64_OR : OP_I32_OR);
        break;
    case OPxor:
        cg.emit(is64 ? OP_I64_XOR : OP_I32_XOR);
        break;
    case OPshl:
        cg.emit(is64 ? OP_I64_SHL : OP_I32_SHL);
        break;
    case OPshr:
        cg.emit(is64 ? OP_I64_SHR_U : OP_I32_SHR_U);
        break;
    case OPashr:
        cg.emit(is64 ? OP_I64_SHR_S : OP_I32_SHR_S);
        break;
    default:
        cg.emit(OP_UNREACHABLE);
        break;
    }
}

// Map compound-assignment op to its binary counterpart
private int compoundToBinop(int op) @safe
{
    switch (op)
    {
    case OPaddass:
        return OPadd;
    case OPminass:
        return OPmin;
    case OPmulass:
        return OPmul;
    case OPdivass:
        return OPdiv;
    case OPmodass:
        return OPmod;
    case OPandass:
        return OPand;
    case OPorass:
        return OPor;
    case OPxorass:
        return OPxor;
    case OPshlass:
        return OPshl;
    case OPshrass:
        return OPshr;
    case OPashrass:
        return OPashr;
    default:
        return OPadd;
    }
}

// Emit a relational/comparison opcode
private void emitRelop(ref WasmCG cg, int op, tym_t operandTy) @trusted
{
    const bool is64 = (tybasic(operandTy) == TYllong || tybasic(operandTy) == TYullong);
    const bool isF32 = (tybasic(operandTy) == TYfloat);
    const bool isF64 = (tybasic(operandTy) == TYdouble || tybasic(operandTy) == TYdouble_alias || tybasic(
            operandTy) == TYreal);
    const bool isUns = tyuns(operandTy) != 0;

    if (isF32)
    {
        switch (op)
        {
        case OPeqeq:
            cg.emit(OP_F32_EQ);
            break;
        case OPne:
            cg.emit(OP_F32_NE);
            break;
        case OPlt:
            cg.emit(OP_F32_LT);
            break;
        case OPle:
            cg.emit(OP_F32_LE);
            break;
        case OPgt:
            cg.emit(OP_F32_GT);
            break;
        case OPge:
            cg.emit(OP_F32_GE);
            break;
        default:
            cg.emit(OP_UNREACHABLE);
            break;
        }
        return;
    }
    if (isF64)
    {
        switch (op)
        {
        case OPeqeq:
            cg.emit(OP_F64_EQ);
            break;
        case OPne:
            cg.emit(OP_F64_NE);
            break;
        case OPlt:
            cg.emit(OP_F64_LT);
            break;
        case OPle:
            cg.emit(OP_F64_LE);
            break;
        case OPgt:
            cg.emit(OP_F64_GT);
            break;
        case OPge:
            cg.emit(OP_F64_GE);
            break;
        default:
            cg.emit(OP_UNREACHABLE);
            break;
        }
        return;
    }
    if (is64)
    {
        switch (op)
        {
        case OPeqeq:
            cg.emit(OP_I64_EQ);
            break;
        case OPne:
            cg.emit(OP_I64_NE);
            break;
        case OPlt:
            cg.emit(isUns ? OP_I64_LT_U : OP_I64_LT_S);
            break;
        case OPle:
            cg.emit(isUns ? OP_I64_LE_U : OP_I64_LE_S);
            break;
        case OPgt:
            cg.emit(isUns ? OP_I64_GT_U : OP_I64_GT_S);
            break;
        case OPge:
            cg.emit(isUns ? OP_I64_GE_U : OP_I64_GE_S);
            break;
        default:
            cg.emit(OP_UNREACHABLE);
            break;
        }
        return;
    }
    switch (op)
    {
    case OPeqeq:
        cg.emit(OP_I32_EQ);
        break;
    case OPne:
        cg.emit(OP_I32_NE);
        break;
    case OPlt:
        cg.emit(isUns ? OP_I32_LT_U : OP_I32_LT_S);
        break;
    case OPle:
        cg.emit(isUns ? OP_I32_LE_U : OP_I32_LE_S);
        break;
    case OPgt:
        cg.emit(isUns ? OP_I32_GT_U : OP_I32_GT_S);
        break;
    case OPge:
        cg.emit(isUns ? OP_I32_GE_U : OP_I32_GE_S);
        break;
    default:
        cg.emit(OP_UNREACHABLE);
        break;
    }
}

// ---------------------------------------------------------------------------
// Function index lookup
// ---------------------------------------------------------------------------

private uint funcIndex(Symbol* sfunc) @trusted
{
    import dmd.backend.wasmobj : wasmFuncBodies;

    foreach (size_t i, ref const fb; wasmFuncBodies)
        if (fb.sym == sfunc)
            return cast(uint) i;
    return 0;
}

// ---------------------------------------------------------------------------
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

            // Adjust switch value to 0-based
            if (vmin != 0)
            {
                cg.emit(OP_I32_CONST);
                cg.emitSLEB(cast(int)-vmin);
                cg.emit(OP_I32_ADD);
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

            // Table entries: for each integer value vmin..vmax, find its dest
            size_t tableLen = cast(size_t)(vmax - vmin + 1);
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
                cg.emit(OP_I32_EQZ);
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
                    cg.emit(OP_I32_EQZ);
                    cg.emit(OP_BR_IF);
                    cg.emitULEB(brDepth(outerLoop - 1));
                }
                else
                {
                    // condition true => exit, false => stay
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
                    // block $skip ... cond; eqz; br_if 0 ... [true path] ... end $skip
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
                    cg.emit(OP_I32_EQZ);
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

    // Register parameters first (locals 0..numParams-1), then other locals.
    // globsym[] holds all symbols for this function, with Ssymnum = their index.
    // Parameters have Sclass SC.parameter / SC.fastpar / SC.regpar / SC.shadowreg.
    foreach (s; globsym[])
    {
        if (s.Sclass == SC.parameter || s.Sclass == SC.fastpar ||
            s.Sclass == SC.regpar || s.Sclass == SC.shadowreg)
        {
            WasmLocal l;
            l.sym = s;
            l.ty = wasmType(s.ty());
            cg.locals ~= l;
        }
    }
    cg.numParams = cast(uint) cg.locals.length;

    // Then non-parameter locals
    foreach (s; globsym[])
    {
        if (s.Sclass == SC.auto_ || s.Sclass == SC.register || s.Sclass == SC.stack)
        {
            WasmLocal l;
            l.sym = s;
            l.ty = wasmType(s.ty());
            cg.locals ~= l;
        }
    }

    // Determine return type
    type* retType = sfunc.Stype.Tnext;
    const bool hasReturn = retType && tybasic(retType.Tty) != TYvoid;

    // Generate code from the block CFG
    block* startblock = sfunc.Sfunc.Fstartblock;
    if (startblock)
        genBlocksProper(cg, startblock, hasReturn);

    // Store results back into the WasmFuncBody
    fb.locals = cg.locals;
    fb.numParams = cg.numParams;
    fb.code.reset();
    fb.code.write(cg.code.peekSlice());
}
