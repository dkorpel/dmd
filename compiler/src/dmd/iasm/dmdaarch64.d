/**
 * Inline assembler implementation for DMD.
 * https://dlang.org/spec/iasm.html
 *
 * Copyright:   Copyright (C) 2025-2026 by The D Language Foundation, All Rights Reserved
 * Authors:     Walter Bright
 * License:     $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/compiler/src/dmd/iasmaarch64.d, _iasmaarch64.d)
 * Documentation:  https://dlang.org/phobos/dmd_iasmaarch64.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/compiler/src/dmd/iasmaarch64.d
 */

module dmd.iasm.dmdaarch64;

import core.stdc.stdio;
import core.stdc.stdarg;
import core.stdc.stdlib;
import core.stdc.string;

import dmd.astenums;
import dmd.astcodegen;
import dmd.declaration;
import dmd.denum;
import dmd.dinterpret;
import dmd.dmdparams;
import dmd.dscope;
import dmd.dsymbol;
import dmd.dsymbolsem : search;
import dmd.func : FuncDeclaration;
import dmd.errors;
import dmd.expression;
import dmd.expressionsem;
import dmd.funcsem : checkNestedReference;
import dmd.globals;
import dmd.id;
import dmd.identifier;
import dmd.init;
import dmd.location;
import dmd.mtype;
import dmd.parse;
import dmd.statement;
import dmd.target;
import dmd.tokens;
import dmd.typesem : pointerTo, size, isIntegral;

import dmd.root.ctfloat;
import dmd.root.string : iequals;
import dmd.common.outbuffer;
import dmd.root.rmem;
import dmd.rootobject;

import dmd.backend.cc;
import dmd.backend.cdef;
import dmd.backend.code;
import dmd.backend.x86.code_x86;
import dmd.backend.codebuilder : CodeBuilder;
import dmd.backend.global;
import dmd.backend.iasm;
import dmd.backend.arm.instr : INSTR;


/*******************************
 * Constants
 */

/// Immediate value range constants
private enum ImmediateRange
{
    PrePostIndex_Min = -256,
    PrePostIndex_Max = 255,
}

/// Register constants
private enum Reg : ubyte
{
    SP = 31,   /// Stack pointer register number
    ZR = 31,   /// Zero register number
    LR = 30,   /// Link register (x30)
}

/// Load/Store size encoding
private enum LSSize : ubyte
{
    Byte = 0,       /// 8-bit load/store
    HalfWord = 1,   /// 16-bit load/store
    Word = 2,       /// 32-bit load/store
    DoubleWord = 3, /// 64-bit load/store
}

/// Load/Store pair opc encoding
private enum LSPairOpc : ubyte
{
    Word = 0,       /// 32-bit pair (W registers)
    DoubleWord = 2, /// 64-bit pair (X registers)
}

/*******************************
 * AArch64 Operand Types and Structures
 */

/// Extend operations for scaled register offsets
private enum ExtendOp : ubyte
{
    None    = 0,
    UXTW    = 2,  /// Zero-extend word (32-bit)
    LSL     = 3,  /// Logical shift left (alias for UXTX for 64-bit)
    SXTW    = 6,  /// Sign-extend word (32-bit)
    SXTX    = 7,  /// Sign-extend doubleword (64-bit)
}

/// Addressing mode type for memory operands
private enum AddressingMode : ubyte
{
    Offset,       /// [Xn, #imm] or [Xn, Xm] - offset addressing
    PreIndexed,   /// [Xn, #imm]! - pre-indexed addressing
    PostIndexed,  /// [Xn], #imm - post-indexed addressing
}

/// Represents a parsed operand in an AArch64 instruction
private struct AArch64Operand
{
    // Register operands
    ubyte reg;          /// Register number (0-31)
    bool is64bit;       /// true for X registers, false for W registers
    bool isSP;

    // Memory operands
    ubyte baseReg;      /// Base register
    ubyte indexReg;     /// Index register (if used)
    long offset;        /// Immediate offset
    bool hasIndex;      /// True if index register is used
    bool hasOffset;     /// True if immediate offset is used

    // Extended addressing modes (Phase 2)
    ExtendOp extend;    /// Extend operation for register offset
    ubyte shiftAmount;  /// Shift amount for extend operation
    AddressingMode addressingMode;  /// Offset, pre-indexed, or post-indexed

}

/// State for parsing a single asm statement
private struct AsmState
{
    Token* tok;         /// Current token
    Scope* sc;          /// Scope
    Loc loc;            /// Location for error reporting
    uint startErrors;   /// Error count at start
}

/// Global state for current asm parsing
private __gshared AsmState asmstate;

/*******************************
 * Condition Codes
 */

/// AArch64 condition codes for conditional instructions
enum CondCode : ubyte
{
    EQ = 0b0000,  // Equal (Z set)
    NE = 0b0001,  // Not equal (Z clear)
    CS = 0b0010,  // Carry set / unsigned higher or same
    HS = CS,      // Unsigned higher or same (alias for CS)
    CC = 0b0011,  // Carry clear / unsigned lower
    LO = CC,      // Unsigned lower (alias for CC)
    MI = 0b0100,  // Minus / negative (N set)
    PL = 0b0101,  // Plus / positive or zero (N clear)
    VS = 0b0110,  // Overflow set (V set)
    VC = 0b0111,  // Overflow clear (V clear)
    HI = 0b1000,  // Unsigned higher
    LS = 0b1001,  // Unsigned lower or same
    GE = 0b1010,  // Signed greater than or equal
    LT = 0b1011,  // Signed less than
    GT = 0b1100,  // Signed greater than
    LE = 0b1101,  // Signed less than or equal
    AL = 0b1110,  // Always (unconditional)
    NV = 0b1111,  // Always (unconditional) - reserved
}

/// Parse a condition code from a string
private bool parseConditionCode(const(char)[] name, out CondCode cond)
{
    import core.stdc.ctype : tolower;

    if (name.length < 2 || name.length > 2)
        return false;

    // Convert to lowercase for comparison
    char[2] lower;
    lower[0] = cast(char)tolower(name[0]);
    lower[1] = cast(char)tolower(name[1]);

    switch (lower)
    {
        case "eq": cond = CondCode.EQ; return true;
        case "ne": cond = CondCode.NE; return true;
        case "cs": cond = CondCode.CS; return true;
        case "hs": cond = CondCode.HS; return true;
        case "cc": cond = CondCode.CC; return true;
        case "lo": cond = CondCode.LO; return true;
        case "mi": cond = CondCode.MI; return true;
        case "pl": cond = CondCode.PL; return true;
        case "vs": cond = CondCode.VS; return true;
        case "vc": cond = CondCode.VC; return true;
        case "hi": cond = CondCode.HI; return true;
        case "ls": cond = CondCode.LS; return true;
        case "ge": cond = CondCode.GE; return true;
        case "lt": cond = CondCode.LT; return true;
        case "gt": cond = CondCode.GT; return true;
        case "le": cond = CondCode.LE; return true;
        case "al": cond = CondCode.AL; return true;
        default: return false;
    }
}

/*******************************
 * Helper Functions
 */

/// Advance to the next token
private void asmNextToken()
{
    asmstate.tok = asmstate.tok.next;
}

/// Get the current token value
private TOK tokValue()
{
    return asmstate.tok ? asmstate.tok.value : TOK.endOfFile;
}

/// Check if there were errors during parsing
private bool hadErrors()
{
    return global.errors > asmstate.startErrors;
}

private const(char)* tokChars()
{
    return asmstate.tok ? asmstate.tok.toChars() : ";";
}

private bool parseComma()
{
    if (tokValue() == TOK.comma)
    {
        asmNextToken();
        return true;
    }
    error(asmstate.loc, "`,` expected, not `%s`", tokChars());
    return false;
}

private bool validate64BitRegister(ref const AArch64Operand op, const(char)* instrName)
{
    if (op.is64bit)
        return true;
    error(asmstate.loc, "64-bit register expected for `%s` instruction", instrName);
    return false;
}

private bool validateRegisterSizeMatch(ref const AArch64Operand op1, ref const AArch64Operand op2,
                                       const(char)* instrName)
{
    if (op1.is64bit == op2.is64bit)
        return true;
    error(asmstate.loc, "register size mismatch in `%s` instruction", instrName);
    return false;
}

private bool parseRegisterName(const(char)[] name, out ubyte regNum, out bool is64bit)
{
    import core.stdc.ctype : tolower;

    if (iequals(name, "sp"))
    {
        regNum = Reg.SP;
        is64bit = true;
        return true;
    }

    if (name.length < 2 || (tolower(name[0]) != 'x' && tolower(name[0]) != 'w'))
        return false;
    is64bit = tolower(name[0]) == 'x';

    if (iequals(name[1 .. $], "zr"))
    {
        regNum = Reg.ZR;
        return true;
    }

    uint num = 0;
    foreach (c; name[1 .. $])
    {
        if (c < '0' || c > '9')
            return false;
        num = num * 10 + (c - '0');
        if (num > 30)
            return false;
    }
    regNum = cast(ubyte)num;
    return true;
}

private bool parseRegister(out AArch64Operand op, bool allowSP = false)
{
    if (tokValue() != TOK.identifier)
    {
        error(asmstate.loc, "register expected, not `%s`", tokChars());
        return false;
    }

    const(char)[] regName = asmstate.tok.ident.toString();
    if (!parseRegisterName(regName, op.reg, op.is64bit))
    {
        error(asmstate.loc, "unknown register `%s`", regName.ptr);
        return false;
    }

    op.isSP = op.reg == Reg.SP && iequals(regName, "sp");
    if (op.isSP && !allowSP)
    {
        error(asmstate.loc, "`sp` cannot be used here");
        return false;
    }

    asmNextToken();
    return true;
}

private bool parseRegs(const(char)* instrName, AArch64Operand[] r, size_t zr = size_t.max)
{
    const size_t first = zr == 0;
    foreach (i, ref op; r)
    {
        if (i == zr)
            continue;
        if (i != first && !parseComma())
            return false;
        if (!parseRegister(op) || !validateRegisterSizeMatch(r[first], op, instrName))
            return false;
    }
    if (zr < r.length)
    {
        r[zr].reg = Reg.ZR;
        r[zr].is64bit = r[first].is64bit;
    }
    return true;
}

private bool parseImmediate(out long imm)
{
    if (tokValue() != TOK.pound)
    {
        error(asmstate.loc, "immediate value must start with `#`");
        return false;
    }
    asmNextToken();

    const neg = tokValue() == TOK.min;
    if (neg)
        asmNextToken();

    switch (tokValue())
    {
        case TOK.int32Literal, TOK.int64Literal, TOK.uns32Literal, TOK.uns64Literal:
            imm = neg ? -asmstate.tok.intvalue : asmstate.tok.intvalue;
            asmNextToken();
            return true;
        default:
            error(asmstate.loc, "numeric value expected after `#`");
            return false;
    }
}

private bool validateImmediateRange(long value, long min, long max, const(char)* context)
{
    if (value >= min && value <= max)
        return true;
    error(asmstate.loc, "immediate value %lld out of range for `%s` (must be %lld..%lld)",
          value, context, min, max);
    return false;
}

private bool parseImmRange(out uint value, uint max, const(char)* instrName)
{
    long imm;
    if (!parseImmediate(imm) || !validateImmediateRange(imm, 0, max, instrName))
        return false;
    value = cast(uint)imm;
    return true;
}

private bool parseOptionalShift(const(char)* instrName, bool is64bit, bool allowRor, out uint shift, out uint amount)
{
    if (tokValue() != TOK.comma)
        return true;
    asmNextToken();

    static immutable string[4] names = ["lsl", "lsr", "asr", "ror"];
    if (tokValue() == TOK.identifier)
    {
        foreach (i, n; names[0 .. allowRor ? 4 : 3])
        {
            if (iequals(asmstate.tok.ident.toString(), n))
            {
                asmNextToken();
                shift = cast(uint)i;
                return parseImmRange(amount, is64bit ? 63 : 31, instrName);
            }
        }
    }
    error(asmstate.loc, "invalid shift type for `%s`, expected %s", instrName,
        allowRor ? "lsl/lsr/asr/ror".ptr : "lsl/lsr/asr".ptr);
    return false;
}

private bool parseExtendOp(out ExtendOp extend)
{
    if (tokValue() != TOK.identifier)
        return false;

    const(char)[] extName = asmstate.tok.ident.toString();
    if (iequals(extName, "lsl"))
        extend = ExtendOp.LSL;
    else if (iequals(extName, "uxtw"))
        extend = ExtendOp.UXTW;
    else if (iequals(extName, "sxtw"))
        extend = ExtendOp.SXTW;
    else if (iequals(extName, "sxtx"))
        extend = ExtendOp.SXTX;
    else
        return false;

    asmNextToken();
    return true;
}

private bool parseMemoryOperand(out AArch64Operand op, const(char)* instrName)
{
    if (tokValue() != TOK.leftBracket)
    {
        error(asmstate.loc, "`[` expected for memory operand");
        return false;
    }
    asmNextToken();

    AArch64Operand baseOp;
    if (!parseRegister(baseOp, true))
        return false;

    if (!baseOp.is64bit || (baseOp.reg == Reg.ZR && !baseOp.isSP))
    {
        error(asmstate.loc, "`x0`..`x30` or `sp` expected as base in memory operand");
        return false;
    }
    op.baseReg = baseOp.reg;

    if (tokValue() == TOK.comma)
    {
        asmNextToken();

        if (tokValue() == TOK.pound)
        {
            if (!parseImmediate(op.offset))
                return false;
            op.hasOffset = true;
        }
        else
        {
            AArch64Operand indexOp;
            if (!parseRegister(indexOp))
                return false;

            op.indexReg = indexOp.reg;
            op.hasIndex = true;

            if (tokValue() == TOK.comma)
            {
                asmNextToken();
                if (!parseExtendOp(op.extend))
                {
                    error(asmstate.loc, "extend operation (LSL, UXTW, SXTW, SXTX) expected");
                    return false;
                }
                uint amount;
                if (tokValue() == TOK.pound && !parseImmRange(amount, 4, instrName))
                    return false;
                op.shiftAmount = cast(ubyte)amount;
            }

            const wantW = op.extend == ExtendOp.UXTW || op.extend == ExtendOp.SXTW;
            if (indexOp.is64bit == wantW)
            {
                error(asmstate.loc, wantW ? "32-bit index register expected for `uxtw`/`sxtw`"
                                          : "64-bit index register expected");
                return false;
            }
        }
    }

    if (tokValue() != TOK.rightBracket)
    {
        error(asmstate.loc, "`]` expected to close memory operand");
        return false;
    }
    asmNextToken();

    if (tokValue() == TOK.not)
    {
        if (!op.hasOffset)
        {
            error(asmstate.loc, "pre-indexed mode requires immediate offset");
            return false;
        }
        op.addressingMode = AddressingMode.PreIndexed;
        asmNextToken();
    }
    else if (tokValue() == TOK.comma)
    {
        if (op.hasOffset || op.hasIndex)
        {
            error(asmstate.loc, "post-indexed mode cannot have offset inside brackets");
            return false;
        }
        asmNextToken();

        if (tokValue() != TOK.pound)
        {
            error(asmstate.loc, "immediate offset expected for post-indexed mode");
            return false;
        }
        if (!parseImmediate(op.offset))
            return false;
        op.hasOffset = true;
        op.addressingMode = AddressingMode.PostIndexed;
    }

    return true;
}

private bool checkReg31(ref const AArch64Operand op, bool isSPSlot)
{
    if (op.reg != Reg.SP || op.isSP == isSPSlot)
        return true;
    error(asmstate.loc, op.isSP ? "`sp` cannot be used here" : "`xzr`/`wzr` cannot be used here");
    return false;
}

private bool parseOptionalExtendShift(const(char)* instrName, out uint amount)
{
    uint shift;
    if (!parseOptionalShift(instrName, true, false, shift, amount))
        return false;
    if (shift != 0 || amount > 4)
    {
        error(asmstate.loc, "only `lsl #0`..`lsl #4` is allowed with `sp` in `%s`", instrName);
        return false;
    }
    return true;
}

private code* emitInstruction(uint encoding)
{
    code* c = code_calloc();
    c.Iop = encoding;
    return c;
}

private uint encodeLoadStore(uint size, uint opc, ubyte rt, ref const AArch64Operand mem, const(char)* instrName)
{
    if (mem.hasIndex)
    {
        if (mem.shiftAmount != 0 && mem.shiftAmount != size)
        {
            error(asmstate.loc, "shift amount for `%s` must be 0 or %u", instrName, size);
            return 0;
        }
        uint extend = mem.extend != ExtendOp.None ? mem.extend : ExtendOp.LSL;
        uint S = mem.shiftAmount != 0;
        return INSTR.ldst_regoff(size, 0, opc, mem.indexReg, extend, S, mem.baseReg, rt);
    }

    final switch (mem.addressingMode)
    {
        case AddressingMode.PreIndexed:
        case AddressingMode.PostIndexed:
            if (!validateImmediateRange(mem.offset, ImmediateRange.PrePostIndex_Min,
                                        ImmediateRange.PrePostIndex_Max, instrName))
                return 0;
            const imm9 = cast(uint)(mem.offset & 0x1FF);
            return mem.addressingMode == AddressingMode.PreIndexed
                ? INSTR.ldst_immpre(size, 0, opc, imm9, mem.baseReg, rt)
                : INSTR.ldst_immpost(size, 0, opc, imm9, mem.baseReg, rt);

        case AddressingMode.Offset:
            const long offset = mem.offset;
            const long scaled = offset >> size;
            if (offset >= 0 && (scaled << size) == offset && scaled <= 0xFFF)
                return INSTR.ldst_pos(size, 0, opc, cast(uint)scaled, mem.baseReg, rt);
            if (offset >= ImmediateRange.PrePostIndex_Min && offset <= ImmediateRange.PrePostIndex_Max)
                return INSTR.ldst_unscaled(size, 0, opc, offset & 0x1FF, mem.baseReg, rt);
            error(asmstate.loc, "offset %lld out of range for `%s`", offset, instrName);
            return 0;
    }
}

private code* parseInstr_mov(const(char)* name)
{
    AArch64Operand dst, src;
    if (!parseRegister(dst, true) || !parseComma() || !parseRegister(src, true) ||
        !validateRegisterSizeMatch(dst, src, name))
        return null;

    if (!dst.isSP && !src.isSP)
        return emitInstruction(INSTR.mov_register(dst.is64bit, src.reg, dst.reg));
    if (!checkReg31(dst, true) || !checkReg31(src, true))
        return null;
    return emitInstruction(INSTR.add_addsub_imm(1, 0, 0, src.reg, dst.reg));
}

private code* parseLoadStore(int size, int opc)(const(char)* name)
{
    AArch64Operand rt, mem;
    if (!parseRegister(rt))
        return null;

    static if (size >= 0 && opc >= 0)
    {
        if (rt.is64bit != (opc == 2))
        {
            error(asmstate.loc, "%d-bit register expected for `%s`", rt.is64bit ? 32 : 64, name);
            return null;
        }
    }

    if (!parseComma() || !parseMemoryOperand(mem, name))
        return null;

    const uint sz = size >= 0 ? size : rt.is64bit ? LSSize.DoubleWord : LSSize.Word;
    const uint op = opc >= 0 ? opc : rt.is64bit ? 2 : 3;
    const encoding = encodeLoadStore(sz, op, rt.reg, mem, name);
    return encoding ? emitInstruction(encoding) : null;
}

private code* parseLoadStorePair(uint L)(const(char)* name)
{
    AArch64Operand[2] rt;
    AArch64Operand mem;
    if (!parseRegs(name, rt[]) || !parseComma() || !parseMemoryOperand(mem, name))
        return null;

    if (mem.hasIndex)
    {
        error(asmstate.loc, "register offset not supported for `%s`", name);
        return null;
    }

    const uint scale = rt[0].is64bit ? 3 : 2;
    const long scaled = mem.offset >> scale;
    if ((scaled << scale) != mem.offset || scaled < -64 || scaled > 63)
    {
        error(asmstate.loc, "offset %lld for `%s` must be a multiple of %d in range %d..%d",
            mem.offset, name, 1 << scale, -64 << scale, 63 << scale);
        return null;
    }

    const uint opc = rt[0].is64bit ? LSPairOpc.DoubleWord : LSPairOpc.Word;
    const uint imm7 = cast(uint)scaled & 0x7F;
    final switch (mem.addressingMode)
    {
        case AddressingMode.PostIndexed:
            return emitInstruction(INSTR.ldstpair_post(opc, 0, L, imm7, rt[1].reg, mem.baseReg, rt[0].reg));
        case AddressingMode.PreIndexed:
            return emitInstruction(INSTR.ldstpair_pre(opc, 0, L, imm7, rt[1].reg, mem.baseReg, rt[0].reg));
        case AddressingMode.Offset:
            return emitInstruction(INSTR.ldstpair_off(opc, 0, L, imm7, rt[1].reg, mem.baseReg, rt[0].reg));
    }
}

private code* parseAddSub(uint op, uint S, bool cmp = false)(const(char)* name)
{
    AArch64Operand dst, src1, src2;
    static if (cmp)
    {
        if (!parseRegister(src1, true) || !parseComma())
            return null;
        dst.reg = Reg.ZR;
        dst.is64bit = src1.is64bit;
    }
    else
    {
        if (!parseRegister(dst, true) || !parseComma() || !parseRegister(src1, true) ||
            !validateRegisterSizeMatch(dst, src1, name) || !parseComma())
            return null;
    }

    const sf = dst.is64bit;
    if (tokValue() == TOK.pound)
    {
        uint imm12;
        if (!parseImmRange(imm12, 4095, name) || !checkReg31(dst, S == 0) || !checkReg31(src1, true))
            return null;
        return emitInstruction(INSTR.addsub_imm(sf, op, S, 0, imm12, src1.reg, dst.reg));
    }

    if (!parseRegister(src2) || !validateRegisterSizeMatch(dst, src2, name))
        return null;

    if (dst.isSP || src1.isSP)
    {
        uint imm3;
        if (!checkReg31(dst, S == 0) || !checkReg31(src1, true) || !parseOptionalExtendShift(name, imm3))
            return null;
        return emitInstruction(INSTR.addsub_ext(sf, op, S, 0, src2.reg, ExtendOp.LSL, imm3, src1.reg, dst.reg));
    }

    uint shift, imm6;
    if (!parseOptionalShift(name, sf, false, shift, imm6))
        return null;
    return emitInstruction(INSTR.addsub_shift(sf, op, S, shift, src2.reg, imm6, src1.reg, dst.reg));
}

private code* parseNeg(uint S)(const(char)* name)
{
    AArch64Operand[2] r;
    uint shift, imm6;
    if (!parseRegs(name, r[]) || !parseOptionalShift(name, r[0].is64bit, false, shift, imm6))
        return null;
    return emitInstruction(INSTR.neg_sub_addsub_shift(r[0].is64bit, S, shift, r[1].reg, imm6, r[0].reg));
}

private code* parseLogical(uint opc, uint N, size_t zr = size_t.max)(const(char)* name)
{
    AArch64Operand[3] r;
    uint shift, imm6;
    if (!parseRegs(name, r[], zr) || !parseOptionalShift(name, r[0].is64bit, true, shift, imm6))
        return null;
    return emitInstruction(INSTR.log_shift(r[0].is64bit, opc, shift, N, r[2].reg, imm6, r[1].reg, r[0].reg));
}

private code* parseReg3(alias encode)(const(char)* name)
{
    AArch64Operand[3] r;
    if (!parseRegs(name, r[]))
        return null;
    return emitInstruction(encode(r[0].is64bit, r[2].reg, r[1].reg, r[0].reg));
}

private code* parseMulAdd(alias encode, size_t zr = size_t.max)(const(char)* name)
{
    AArch64Operand[4] r;
    if (!parseRegs(name, r[], zr))
        return null;
    return emitInstruction(encode(r[0].is64bit, r[2].reg, r[3].reg, r[1].reg, r[0].reg));
}

private code* parseShift(alias encodeImm, alias encodeReg)(const(char)* name)
{
    AArch64Operand[2] r;
    if (!parseRegs(name, r[]) || !parseComma())
        return null;

    const sf = r[0].is64bit;
    if (tokValue() == TOK.pound)
    {
        uint amount;
        if (!parseImmRange(amount, sf ? 63 : 31, name))
            return null;
        return emitInstruction(encodeImm(sf, amount, r[1].reg, r[0].reg));
    }

    AArch64Operand rm;
    if (!parseRegister(rm) || !validateRegisterSizeMatch(r[0], rm, name))
        return null;
    return emitInstruction(encodeReg(sf, rm.reg, r[1].reg, r[0].reg));
}

private code* parseInstr_extr(const(char)* name)
{
    AArch64Operand[3] r;
    uint lsb;
    if (!parseRegs(name, r[]) || !parseComma() || !parseImmRange(lsb, r[0].is64bit ? 63 : 31, name))
        return null;
    return emitInstruction(INSTR.extr(r[0].is64bit, r[2].reg, lsb, r[1].reg, r[0].reg));
}

private code* parseBitfield(alias encode)(const(char)* name)
{
    AArch64Operand[2] r;
    uint immr, imms;
    if (!parseRegs(name, r[]) || !parseComma())
        return null;
    const max = r[0].is64bit ? 63 : 31;
    if (!parseImmRange(immr, max, name) || !parseComma() || !parseImmRange(imms, max, name))
        return null;
    return emitInstruction(encode(r[0].is64bit, r[0].is64bit, immr, imms, r[1].reg, r[0].reg));
}

private code* parseBranchLabel(uint encoding, const(char)* name)
{
    if (tokValue() != TOK.identifier)
    {
        error(asmstate.loc, "label expected for `%s`", name);
        return null;
    }

    LabelDsymbol label = asmstate.sc.func.searchLabel(asmstate.tok.ident, asmstate.loc);
    label.iasm = true;
    code* c = emitInstruction(encoding);
    c.IFL1 = FL.block;
    c.IEV1.Vlsym = cast(_LabelDsymbol*)label;
    asmNextToken();
    return c;
}

private code* parseInstr_b(const(char)* name)
{
    if (tokValue() != TOK.dot)
        return parseBranchLabel(INSTR.b_uncond(0), name);

    asmNextToken();
    CondCode cond;
    if (tokValue() != TOK.identifier || !parseConditionCode(asmstate.tok.ident.toString(), cond))
    {
        error(asmstate.loc, "condition code expected after `b.`");
        return null;
    }
    asmNextToken();
    return parseBranchLabel(INSTR.b_cond(0, cond), name);
}

private code* parseCompBranch(uint op)(const(char)* name)
{
    AArch64Operand rt;
    if (!parseRegister(rt) || !parseComma())
        return null;
    return parseBranchLabel(INSTR.compbranch(rt.is64bit, op, 0, rt.reg), name);
}

private code* parseTestBranch(uint op)(const(char)* name)
{
    AArch64Operand rt;
    uint bit;
    if (!parseRegister(rt) || !parseComma() || !parseImmRange(bit, rt.is64bit ? 63 : 31, name) || !parseComma())
        return null;
    return parseBranchLabel(INSTR.testbranch(bit >> 5, op, bit & 0x1F, 0, rt.reg), name);
}

private code* parseInstr_bl(const(char)* name)
{
    if (tokValue() != TOK.identifier)
    {
        error(asmstate.loc, "function name expected for `%s`", name);
        return null;
    }

    Dsymbol pscopesym;
    Dsymbol s = asmstate.sc.search(asmstate.loc, asmstate.tok.ident, pscopesym);
    FuncDeclaration fd = s ? s.isFuncDeclaration() : null;
    if (!fd)
    {
        error(asmstate.loc, "function expected for `%s`, not `%s`", name, asmstate.tok.ident.toChars());
        return null;
    }
    asmNextToken();

    code* c = emitInstruction(INSTR.bl(0));
    c.IFL1 = FL.func;
    c.Iflags |= CF.selfrel | CF.off | CF.selfrel26;
    c.IEV1.Vdsym = cast(_Declaration*)fd;
    return c;
}

private code* parseBranchReg(alias encode, bool optional = false)(const(char)* name)
{
    if (optional && tokValue() == TOK.endOfFile)
        return emitInstruction(encode(Reg.LR));

    AArch64Operand rn;
    if (!parseRegister(rn) || !validate64BitRegister(rn, name))
        return null;
    return emitInstruction(encode(rn.reg));
}

alias InstrHandlerFunc = code* function(const(char)* name);

private struct InstrHandler
{
    string mnemonic;
    InstrHandlerFunc handler;
}

private immutable InstrHandler[] instrTable =
[
    InstrHandler("mov",   &parseInstr_mov),
    InstrHandler("ldr",   &parseLoadStore!(-1, 1)),
    InstrHandler("str",   &parseLoadStore!(-1, 0)),
    InstrHandler("ldp",   &parseLoadStorePair!1),
    InstrHandler("stp",   &parseLoadStorePair!0),
    InstrHandler("ldrb",  &parseLoadStore!(LSSize.Byte, 1)),
    InstrHandler("strb",  &parseLoadStore!(LSSize.Byte, 0)),
    InstrHandler("ldrh",  &parseLoadStore!(LSSize.HalfWord, 1)),
    InstrHandler("strh",  &parseLoadStore!(LSSize.HalfWord, 0)),
    InstrHandler("ldrsb", &parseLoadStore!(LSSize.Byte, -1)),
    InstrHandler("ldrsh", &parseLoadStore!(LSSize.HalfWord, -1)),
    InstrHandler("ldrsw", &parseLoadStore!(LSSize.Word, 2)),
    InstrHandler("add",   &parseAddSub!(0, 0)),
    InstrHandler("adds",  &parseAddSub!(0, 1)),
    InstrHandler("sub",   &parseAddSub!(1, 0)),
    InstrHandler("subs",  &parseAddSub!(1, 1)),
    InstrHandler("cmp",   &parseAddSub!(1, 1, true)),
    InstrHandler("cmn",   &parseAddSub!(0, 1, true)),
    InstrHandler("mul",   &parseMulAdd!(INSTR.madd, 3)),
    InstrHandler("madd",  &parseMulAdd!(INSTR.madd)),
    InstrHandler("msub",  &parseMulAdd!(INSTR.msub)),
    InstrHandler("sdiv",  &parseReg3!((sf, m, n, d) => INSTR.sdiv_udiv(sf, false, m, n, d))),
    InstrHandler("udiv",  &parseReg3!((sf, m, n, d) => INSTR.sdiv_udiv(sf, true, m, n, d))),
    InstrHandler("neg",   &parseNeg!0),
    InstrHandler("negs",  &parseNeg!1),
    InstrHandler("adc",   &parseReg3!(INSTR.adc)),
    InstrHandler("adcs",  &parseReg3!(INSTR.adcs)),
    InstrHandler("sbc",   &parseReg3!(INSTR.sbc)),
    InstrHandler("sbcs",  &parseReg3!(INSTR.sbcs)),
    InstrHandler("and",   &parseLogical!(0, 0)),
    InstrHandler("orr",   &parseLogical!(1, 0)),
    InstrHandler("eor",   &parseLogical!(2, 0)),
    InstrHandler("bic",   &parseLogical!(0, 1)),
    InstrHandler("mvn",   &parseLogical!(1, 1, 1)),
    InstrHandler("tst",   &parseLogical!(3, 0, 0)),
    InstrHandler("lsl",   &parseShift!(INSTR.lsl_ubfm, INSTR.lslv)),
    InstrHandler("lsr",   &parseShift!(INSTR.lsr_ubfm, INSTR.lsrv)),
    InstrHandler("asr",   &parseShift!(INSTR.asr_sbfm, INSTR.asrv)),
    InstrHandler("ror",   &parseShift!(INSTR.ror_extr, INSTR.rorv)),
    InstrHandler("extr",  &parseInstr_extr),
    InstrHandler("ubfm",  &parseBitfield!(INSTR.ubfm)),
    InstrHandler("sbfm",  &parseBitfield!(INSTR.sbfm)),
    InstrHandler("bfm",   &parseBitfield!(INSTR.bfm)),
    InstrHandler("b",     &parseInstr_b),
    InstrHandler("cbz",   &parseCompBranch!0),
    InstrHandler("cbnz",  &parseCompBranch!1),
    InstrHandler("tbz",   &parseTestBranch!0),
    InstrHandler("tbnz",  &parseTestBranch!1),
    InstrHandler("bl",    &parseInstr_bl),
    InstrHandler("blr",   &parseBranchReg!(INSTR.blr)),
    InstrHandler("br",    &parseBranchReg!(INSTR.br)),
    InstrHandler("ret",   &parseBranchReg!(INSTR.ret, true)),
];

private immutable(InstrHandler)* lookupInstruction(const(char)[] mnemonic)
{
    foreach (ref h; instrTable)
        if (iequals(h.mnemonic, mnemonic))
            return &h;
    return null;
}

/************************
 * Perform semantic analysis on InlineAsmStatement.
 * Params:
 *      s = inline asm statement
 *      sc = context
 * Returns:
 *      `s` on success, ErrorStatement if errors happened
 */
public Statement inlineAsmAArch64Semantic(InlineAsmStatement s, Scope* sc)
{
    // Initialize state
    asmstate.tok = s.tokens;
    asmstate.sc = sc;
    asmstate.loc = s.loc;
    asmstate.startErrors = global.errors;

    // Check for empty statement
    if (!asmstate.tok || tokValue() == TOK.endOfFile)
    {
        error(s.loc, "empty asm statement");
        return ErrorStatement.get();
    }

    // Handle `naked` and `op` pseudo-ops, which are not real instructions:
    //   asm { naked; }       — mark the enclosing function as naked
    //   asm { op <expr>; }   — emit <expr> as a single 4-byte raw opcode
    if (tokValue() == TOK.identifier &&
        (asmstate.tok.ident == Id.naked || asmstate.tok.ident == Id.op))
    {
        // The `op` form needs a full D expression parser for the operand,
        // so we hand the token list to a Parser for both pseudo-ops.
        const bool doUnittests = global.params.parsingUnittestsRequired(sc._module.isRoot);
        scope p = new Parser!ASTCodegen(sc._module, "", false,
            global.errorSink, &global.compileEnv, doUnittests);
        p.setTokenList(s.tokens, s.loc.linnum);

        if (p.token.ident == Id.naked)
        {
            s.naked = true;
            sc.func.isNaked = true;
            p.nextToken();
        }
        else // Id.op
        {
            p.nextToken();
            Expression exp = p.parseAssignExp();
            // Must evaluate to a constant, like an enum member does
            exp = exp.expressionSemantic(sc);
            exp = resolveProperties(sc, exp);
            exp = exp.ctfeInterpret();
            if (exp.op == EXP.error)
                return ErrorStatement.get();

            Type t = exp.type;
            if (!(size(t) == 4 && isIntegral(t)))
                error(s.loc, "size of opcode must be 4 of integral type");
            code* pc = code_calloc();
            pc.Iflags |= CF.psw;            // assume we want to keep the flags
            pc.Iop = cast(int)exp.toInteger();
            s.asmcode = pc;
        }

        if (p.token.value != TOK.endOfFile && !hadErrors())
        {
            error(s.loc, "end of instruction expected, not `%s`", p.token.toChars());
            return ErrorStatement.get();
        }
        return s;
    }

    // Get instruction mnemonic
    if (tokValue() != TOK.identifier)
    {
        error(asmstate.loc, "instruction mnemonic expected, not `%s`", asmstate.tok.toChars());
        return ErrorStatement.get();
    }

    const(char)[] mnemonic = asmstate.tok.ident.toString();

    auto handler = lookupInstruction(mnemonic);
    if (!handler)
    {
        error(asmstate.loc, "unknown AArch64 instruction `%s`", mnemonic.ptr);
        return ErrorStatement.get();
    }

    asmNextToken();
    code* c = handler.handler(handler.mnemonic.ptr);

    // Check for errors
    if (hadErrors() || !c)
        return ErrorStatement.get();

    // Check for unexpected tokens after instruction
    if (tokValue() != TOK.endOfFile)
    {
        error(asmstate.loc, "unexpected token `%s` after instruction", asmstate.tok.toChars());
        return ErrorStatement.get();
    }

    // Set the generated code
    s.asmcode = c;

    return s;
}

/*******************************
 * Unit Tests
 */

unittest
{
    // Test register name parsing
    ubyte regNum;
    bool is64bit;

    // Test X registers
    assert(parseRegisterName("x0", regNum, is64bit));
    assert(regNum == 0 && is64bit);

    assert(parseRegisterName("x15", regNum, is64bit));
    assert(regNum == 15 && is64bit);

    assert(parseRegisterName("x30", regNum, is64bit));
    assert(regNum == 30 && is64bit);

    // Test W registers
    assert(parseRegisterName("w0", regNum, is64bit));
    assert(regNum == 0 && !is64bit);

    assert(parseRegisterName("w20", regNum, is64bit));
    assert(regNum == 20 && !is64bit);

    // Test special registers
    assert(parseRegisterName("sp", regNum, is64bit));
    assert(regNum == 31 && is64bit);

    assert(parseRegisterName("SP", regNum, is64bit));
    assert(regNum == 31 && is64bit);

    assert(parseRegisterName("xzr", regNum, is64bit));
    assert(regNum == 31 && is64bit);

    assert(parseRegisterName("wzr", regNum, is64bit));
    assert(regNum == 31 && !is64bit);

    // Test case insensitivity
    assert(parseRegisterName("X0", regNum, is64bit));
    assert(regNum == 0 && is64bit);

    assert(parseRegisterName("W5", regNum, is64bit));
    assert(regNum == 5 && !is64bit);

    // Test invalid registers
    assert(!parseRegisterName("x32", regNum, is64bit));
    assert(!parseRegisterName("r0", regNum, is64bit));
    assert(!parseRegisterName("q0", regNum, is64bit));
    assert(!parseRegisterName("", regNum, is64bit));
    assert(!parseRegisterName("x", regNum, is64bit));
}

unittest
{
    // Test MOV encoding
    // mov x0, x1 should encode to 0xAA0103E0
    uint encoding = INSTR.mov_register(1, 1, 0);
    assert(encoding == 0xAA0103E0, "mov x0, x1 encoding incorrect");

    // mov w5, w10 should encode to 0x2A0A03E5
    encoding = INSTR.mov_register(0, 10, 5);
    assert(encoding == 0x2A0A03E5, "mov w5, w10 encoding incorrect");
}

unittest
{
    // Test ADD immediate encoding
    // add x0, x1, #42
    // Format: sf=1, op=0, S=0, sh=0, imm12=42, Rn=1, Rd=0
    uint encoding = INSTR.add_addsub_imm(1, 0, 42, 1, 0);
    assert(encoding == 0x9100A820, "add x0, x1, #42 encoding incorrect");
}

unittest
{
    // Test ADD register encoding
    // add x2, x3, x4
    uint encoding = INSTR.addsub_shift(1, 0, 0, 0, 4, 0, 3, 2);
    // This should produce a valid add instruction
    assert(encoding != 0, "add x2, x3, x4 encoding failed");
}

unittest
{
    // Test SUB immediate encoding
    // sub x0, x1, #42
    // Format: sf=1, op=1, S=0, sh=0, imm12=42, Rn=1, Rd=0
    uint encoding = INSTR.sub_addsub_imm(1, 0, 42, 1, 0);
    assert(encoding == 0xD100A820, "sub x0, x1, #42 encoding incorrect");
}

unittest
{
    // Test LDR encoding
    // ldr x0, [x1]
    uint encoding = INSTR.ldr_imm_gen(1, 0, 1, 0);
    // Should produce valid ldr instruction
    assert(encoding != 0, "ldr x0, [x1] encoding failed");
}

unittest
{
    // Test STR encoding
    // str x0, [x1]
    uint encoding = INSTR.str_imm_gen(1, 0, 1, 0);
    // Should produce valid str instruction
    assert(encoding != 0, "str x0, [x1] encoding failed");
}

unittest
{
    // Test instruction lookup
    assert(lookupInstruction("mov") !is null);
    assert(lookupInstruction("MOV") !is null);
    assert(lookupInstruction("ldr") !is null);
    assert(lookupInstruction("str") !is null);
    assert(lookupInstruction("add") !is null);
    assert(lookupInstruction("sub") !is null);
    assert(lookupInstruction("b") !is null);

    // Test unknown instruction
    assert(lookupInstruction("unknown") is null);
    assert(lookupInstruction("movx") is null);
}

unittest
{
    // Test more register parsing variations
    ubyte regNum;
    bool is64bit;

    // Test all valid X registers
    foreach (i; 0 .. 31)
    {
        import std.conv : to;
        string regName = "x" ~ i.to!string;
        assert(parseRegisterName(regName, regNum, is64bit));
        assert(regNum == i && is64bit);
    }

    // Test all valid W registers
    foreach (i; 0 .. 31)
    {
        import std.conv : to;
        string regName = "w" ~ i.to!string;
        assert(parseRegisterName(regName, regNum, is64bit));
        assert(regNum == i && !is64bit);
    }

    // Test case variations for special registers
    assert(parseRegisterName("XZR", regNum, is64bit));
    assert(regNum == 31 && is64bit);

    assert(parseRegisterName("WZR", regNum, is64bit));
    assert(regNum == 31 && !is64bit);

    assert(parseRegisterName("Sp", regNum, is64bit));
    assert(regNum == 31 && is64bit);
}

unittest
{
    // Test MOV with different register combinations
    uint encoding;

    // 64-bit moves
    encoding = INSTR.mov_register(1, 0, 0);   // mov x0, x0
    assert(encoding != 0);

    encoding = INSTR.mov_register(1, 30, 29); // mov x29, x30 (fp, lr)
    assert(encoding != 0);

    // 32-bit moves
    encoding = INSTR.mov_register(0, 0, 0);   // mov w0, w0
    assert(encoding != 0);

    encoding = INSTR.mov_register(0, 15, 7);  // mov w7, w15
    assert(encoding != 0);
}

unittest
{
    // Test ADD with different immediate values
    uint encoding;

    // Boundary values for 12-bit immediate
    encoding = INSTR.add_addsub_imm(1, 0, 0, 0, 0);      // add x0, x0, #0
    assert(encoding != 0);

    encoding = INSTR.add_addsub_imm(1, 0, 4095, 5, 3);   // add x3, x5, #4095 (max)
    assert(encoding != 0);

    encoding = INSTR.add_addsub_imm(1, 0, 1, 1, 1);      // add x1, x1, #1
    assert(encoding != 0);

    // 32-bit variants
    encoding = INSTR.add_addsub_imm(0, 0, 100, 10, 11);  // add w11, w10, #100
    assert(encoding != 0);
}

unittest
{
    // Test SUB with different immediate values
    uint encoding;

    // Different immediate values
    encoding = INSTR.sub_addsub_imm(1, 0, 1, 2, 3);      // sub x3, x2, #1
    assert(encoding != 0);

    encoding = INSTR.sub_addsub_imm(1, 0, 255, 4, 5);    // sub x5, x4, #255
    assert(encoding != 0);

    encoding = INSTR.sub_addsub_imm(0, 0, 16, 8, 7);     // sub w7, w8, #16
    assert(encoding != 0);
}

unittest
{
    // Test ADD with register operands
    uint encoding;

    // add x0, x1, x2
    encoding = INSTR.addsub_shift(1, 0, 0, 0, 2, 0, 1, 0);
    assert(encoding != 0);

    // add x10, x11, x12
    encoding = INSTR.addsub_shift(1, 0, 0, 0, 12, 0, 11, 10);
    assert(encoding != 0);

    // add w5, w6, w7
    encoding = INSTR.addsub_shift(0, 0, 0, 0, 7, 0, 6, 5);
    assert(encoding != 0);
}

unittest
{
    // Test SUB with register operands
    uint encoding;

    // sub x0, x1, x2
    encoding = INSTR.addsub_shift(1, 1, 0, 0, 2, 0, 1, 0);
    assert(encoding != 0);

    // sub x15, x16, x17
    encoding = INSTR.addsub_shift(1, 1, 0, 0, 17, 0, 16, 15);
    assert(encoding != 0);

    // sub w20, w21, w22
    encoding = INSTR.addsub_shift(0, 1, 0, 0, 22, 0, 21, 20);
    assert(encoding != 0);
}

unittest
{
    // Test LDR with different addressing modes
    uint encoding;

    // 64-bit loads
    encoding = INSTR.ldr_imm_gen(1, 0, 1, 0);    // ldr x0, [x1]
    assert(encoding != 0);

    encoding = INSTR.ldr_imm_gen(1, 5, 10, 8);   // ldr x5, [x10, #8]
    assert(encoding != 0);

    encoding = INSTR.ldr_imm_gen(1, 15, 20, 16); // ldr x15, [x20, #16]
    assert(encoding != 0);

    // 32-bit loads
    encoding = INSTR.ldr_imm_gen(0, 0, 1, 0);    // ldr w0, [x1]
    assert(encoding != 0);

    encoding = INSTR.ldr_imm_gen(0, 7, 8, 4);    // ldr w7, [x8, #4]
    assert(encoding != 0);
}

unittest
{
    // Test LDR with register offset
    uint encoding;

    // ldr x0, [x1, x2] - size=3, VR=0, opc=1, extend=3 (LSL), S=0
    encoding = INSTR.ldst_regoff(3, 0, 1, 2, 3, 0, 1, 0);
    assert(encoding != 0);

    // ldr w5, [x6, x7] - size=2, VR=0, opc=1, extend=3 (LSL), S=0
    encoding = INSTR.ldst_regoff(2, 0, 1, 7, 3, 0, 6, 5);
    assert(encoding != 0);
}

unittest
{
    // Test STR with different addressing modes
    uint encoding;

    // 64-bit stores
    encoding = INSTR.str_imm_gen(1, 0, 1, 0);    // str x0, [x1]
    assert(encoding != 0);

    encoding = INSTR.str_imm_gen(1, 3, 4, 8);    // str x3, [x4, #8]
    assert(encoding != 0);

    encoding = INSTR.str_imm_gen(1, 10, 11, 24); // str x10, [x11, #24]
    assert(encoding != 0);

    // 32-bit stores
    encoding = INSTR.str_imm_gen(0, 0, 1, 0);    // str w0, [x1]
    assert(encoding != 0);

    encoding = INSTR.str_imm_gen(0, 5, 6, 4);    // str w5, [x6, #4]
    assert(encoding != 0);
}

unittest
{
    // Test STR with register offset
    uint encoding;

    // str x0, [x1, x2] - size=3, VR=0, opc=0, extend=3 (LSL), S=0
    encoding = INSTR.ldst_regoff(3, 0, 0, 2, 3, 0, 1, 0);
    assert(encoding != 0);

    // str w8, [x9, x10] - size=2, VR=0, opc=0, extend=3 (LSL), S=0
    encoding = INSTR.ldst_regoff(2, 0, 0, 10, 3, 0, 9, 8);
    assert(encoding != 0);
}

unittest
{
    // Test encoding consistency - same instruction should produce same encoding
    uint enc1, enc2;

    // MOV
    enc1 = INSTR.mov_register(1, 5, 10);
    enc2 = INSTR.mov_register(1, 5, 10);
    assert(enc1 == enc2);

    // ADD immediate
    enc1 = INSTR.add_addsub_imm(1, 0, 123, 7, 8);
    enc2 = INSTR.add_addsub_imm(1, 0, 123, 7, 8);
    assert(enc1 == enc2);

    // SUB immediate
    enc1 = INSTR.sub_addsub_imm(0, 0, 50, 3, 4);
    enc2 = INSTR.sub_addsub_imm(0, 0, 50, 3, 4);
    assert(enc1 == enc2);
}

unittest
{
    // Test mixed 32/64-bit combinations to ensure size distinction
    uint enc64, enc32;

    // MOV - 64-bit vs 32-bit should be different
    enc64 = INSTR.mov_register(1, 1, 0);  // mov x0, x1
    enc32 = INSTR.mov_register(0, 1, 0);  // mov w0, w1
    assert(enc64 != enc32);

    // ADD - 64-bit vs 32-bit should be different
    enc64 = INSTR.add_addsub_imm(1, 0, 10, 2, 3);  // add x3, x2, #10
    enc32 = INSTR.add_addsub_imm(0, 0, 10, 2, 3);  // add w3, w2, #10
    assert(enc64 != enc32);

    // SUB - 64-bit vs 32-bit should be different
    enc64 = INSTR.sub_addsub_imm(1, 0, 20, 5, 6);  // sub x6, x5, #20
    enc32 = INSTR.sub_addsub_imm(0, 0, 20, 5, 6);  // sub w6, w5, #20
    assert(enc64 != enc32);
}

unittest
{
    // Test special register encodings
    uint encoding;

    // Using sp (register 31) as base
    encoding = INSTR.ldr_imm_gen(1, 0, 31, 0);  // ldr x0, [sp]
    assert(encoding != 0);

    encoding = INSTR.str_imm_gen(1, 0, 31, 8);  // str x0, [sp, #8]
    assert(encoding != 0);

    // Using different registers with sp
    encoding = INSTR.add_addsub_imm(1, 0, 16, 31, 29);  // add x29, sp, #16
    assert(encoding != 0);

    encoding = INSTR.sub_addsub_imm(1, 0, 32, 31, 31);  // sub sp, sp, #32
    assert(encoding != 0);
}

unittest
{
    // Test that different operands produce different encodings
    uint enc1, enc2;

    // Different destination registers
    enc1 = INSTR.mov_register(1, 1, 0);  // mov x0, x1
    enc2 = INSTR.mov_register(1, 1, 2);  // mov x2, x1
    assert(enc1 != enc2);

    // Different source registers
    enc1 = INSTR.mov_register(1, 1, 0);  // mov x0, x1
    enc2 = INSTR.mov_register(1, 3, 0);  // mov x0, x3
    assert(enc1 != enc2);

    // Different immediates
    enc1 = INSTR.add_addsub_imm(1, 0, 10, 1, 0);  // add x0, x1, #10
    enc2 = INSTR.add_addsub_imm(1, 0, 20, 1, 0);  // add x0, x1, #20
    assert(enc1 != enc2);
}

unittest
{
    // Test condition code parsing
    CondCode cond;

    // Test all standard condition codes
    assert(parseConditionCode("eq", cond) && cond == CondCode.EQ);
    assert(parseConditionCode("ne", cond) && cond == CondCode.NE);
    assert(parseConditionCode("cs", cond) && cond == CondCode.CS);
    assert(parseConditionCode("hs", cond) && cond == CondCode.HS);
    assert(parseConditionCode("cc", cond) && cond == CondCode.CC);
    assert(parseConditionCode("lo", cond) && cond == CondCode.LO);
    assert(parseConditionCode("mi", cond) && cond == CondCode.MI);
    assert(parseConditionCode("pl", cond) && cond == CondCode.PL);
    assert(parseConditionCode("vs", cond) && cond == CondCode.VS);
    assert(parseConditionCode("vc", cond) && cond == CondCode.VC);
    assert(parseConditionCode("hi", cond) && cond == CondCode.HI);
    assert(parseConditionCode("ls", cond) && cond == CondCode.LS);
    assert(parseConditionCode("ge", cond) && cond == CondCode.GE);
    assert(parseConditionCode("lt", cond) && cond == CondCode.LT);
    assert(parseConditionCode("gt", cond) && cond == CondCode.GT);
    assert(parseConditionCode("le", cond) && cond == CondCode.LE);
    assert(parseConditionCode("al", cond) && cond == CondCode.AL);

    // Test case insensitivity
    assert(parseConditionCode("EQ", cond) && cond == CondCode.EQ);
    assert(parseConditionCode("Ne", cond) && cond == CondCode.NE);
    assert(parseConditionCode("GE", cond) && cond == CondCode.GE);

    // Test invalid condition codes
    assert(!parseConditionCode("xx", cond));
    assert(!parseConditionCode("e", cond));
    assert(!parseConditionCode("equ", cond));
}

unittest
{
    // Test conditional branch encodings
    uint encoding;

    // b.eq with offset 0
    encoding = INSTR.b_cond(0, CondCode.EQ);
    assert(encoding != 0);

    // b.ne with offset 0
    encoding = INSTR.b_cond(0, CondCode.NE);
    assert(encoding != 0);

    // b.gt with offset 0
    encoding = INSTR.b_cond(0, CondCode.GT);
    assert(encoding != 0);

    // b.le with offset 0
    encoding = INSTR.b_cond(0, CondCode.LE);
    assert(encoding != 0);

    // Different conditions should produce different encodings
    uint enc_eq = INSTR.b_cond(0, CondCode.EQ);
    uint enc_ne = INSTR.b_cond(0, CondCode.NE);
    assert(enc_eq != enc_ne);
}

unittest
{
    // Test unconditional branch encoding
    uint encoding;

    // b with offset 0
    encoding = INSTR.b_uncond(0);
    assert(encoding != 0);

    // Different offsets should produce different encodings
    uint enc1 = INSTR.b_uncond(0);
    uint enc2 = INSTR.b_uncond(4);
    assert(enc1 != enc2);
}

unittest
{
    // Test CBZ/CBNZ encodings
    uint encoding;

    // cbz x0, label (64-bit)
    encoding = INSTR.compbranch(1, 0, 0, 0);
    assert(encoding != 0);

    // cbz w5, label (32-bit)
    encoding = INSTR.compbranch(0, 0, 0, 5);
    assert(encoding != 0);

    // cbnz x10, label (64-bit)
    encoding = INSTR.compbranch(1, 1, 0, 10);
    assert(encoding != 0);

    // cbnz w15, label (32-bit)
    encoding = INSTR.compbranch(0, 1, 0, 15);
    assert(encoding != 0);

    // CBZ vs CBNZ should be different
    uint cbz_enc = INSTR.compbranch(1, 0, 0, 0);
    uint cbnz_enc = INSTR.compbranch(1, 1, 0, 0);
    assert(cbz_enc != cbnz_enc);

    // Different registers should produce different encodings
    uint enc_x0 = INSTR.compbranch(1, 0, 0, 0);
    uint enc_x1 = INSTR.compbranch(1, 0, 0, 1);
    assert(enc_x0 != enc_x1);

    // 32-bit vs 64-bit should be different
    uint enc_64 = INSTR.compbranch(1, 0, 0, 0);
    uint enc_32 = INSTR.compbranch(0, 0, 0, 0);
    assert(enc_64 != enc_32);
}

unittest
{
    // Test TBZ/TBNZ encodings
    uint encoding;

    // tbz x0, #0, label
    encoding = INSTR.testbranch(0, 0, 0, 0, 0);
    assert(encoding != 0);

    // tbz x0, #31, label
    encoding = INSTR.testbranch(0, 0, 31, 0, 0);
    assert(encoding != 0);

    // tbz x0, #63, label (bit 63 requires b5=1, b40=31)
    encoding = INSTR.testbranch(1, 0, 31, 0, 0);
    assert(encoding != 0);

    // tbnz x5, #15, label
    encoding = INSTR.testbranch(0, 1, 15, 0, 5);
    assert(encoding != 0);

    // TBZ vs TBNZ should be different
    uint tbz_enc = INSTR.testbranch(0, 0, 10, 0, 0);
    uint tbnz_enc = INSTR.testbranch(0, 1, 10, 0, 0);
    assert(tbz_enc != tbnz_enc);

    // Different bit numbers should produce different encodings
    uint enc_bit0 = INSTR.testbranch(0, 0, 0, 0, 0);
    uint enc_bit10 = INSTR.testbranch(0, 0, 10, 0, 0);
    assert(enc_bit0 != enc_bit10);

    // Different registers should produce different encodings
    uint enc_x0 = INSTR.testbranch(0, 0, 5, 0, 0);
    uint enc_x7 = INSTR.testbranch(0, 0, 5, 0, 7);
    assert(enc_x0 != enc_x7);
}

unittest
{
    // Test instruction lookup for conditional branches
    assert(lookupInstruction("b") !is null);
    assert(lookupInstruction("cbz") !is null);
    assert(lookupInstruction("cbnz") !is null);
    assert(lookupInstruction("tbz") !is null);
    assert(lookupInstruction("tbnz") !is null);
}

unittest
{
    // Test that all condition codes have distinct values
    assert(CondCode.EQ != CondCode.NE);
    assert(CondCode.CS != CondCode.CC);
    assert(CondCode.MI != CondCode.PL);
    assert(CondCode.VS != CondCode.VC);
    assert(CondCode.HI != CondCode.LS);
    assert(CondCode.GE != CondCode.LT);
    assert(CondCode.GT != CondCode.LE);

    // Test that aliases match their base values
    assert(CondCode.HS == CondCode.CS);
    assert(CondCode.LO == CondCode.CC);
}

// Phase 2: Extended Addressing Modes Unit Tests

unittest
{
    // Test pre-indexed addressing mode encoding for LDR
    // ldr x0, [x1, #8]! - pre-indexed with immediate offset
    // Expected: size=3, VR=0, opc=1, imm9=8, Rn=1, Rt=0
    uint encoding = INSTR.ldst_immpre(3, 0, 1, 8, 1, 0);
    assert(encoding != 0, "ldr x0, [x1, #8]! encoding failed");

    // Verify pre-indexed bit pattern (bits [11:10] should be 0b11)
    assert((encoding & (3 << 10)) == (3 << 10), "pre-indexed mode bits incorrect");
}

unittest
{
    // Test post-indexed addressing mode encoding for LDR
    // ldr x0, [x1], #8 - post-indexed with immediate offset
    // Expected: size=3, VR=0, opc=1, imm9=8, Rn=1, Rt=0
    uint encoding = INSTR.ldst_immpost(3, 0, 1, 8, 1, 0);
    assert(encoding != 0, "ldr x0, [x1], #8 encoding failed");

    // Verify post-indexed bit pattern (bits [11:10] should be 0b01)
    assert((encoding & (3 << 10)) == (1 << 10), "post-indexed mode bits incorrect");
}

unittest
{
    // Test pre-indexed addressing mode encoding for STR
    // str x0, [x1, #8]! - pre-indexed with immediate offset
    // Expected: size=3, VR=0, opc=0, imm9=8, Rn=1, Rt=0
    uint encoding = INSTR.ldst_immpre(3, 0, 0, 8, 1, 0);
    assert(encoding != 0, "str x0, [x1, #8]! encoding failed");
}

unittest
{
    // Test post-indexed addressing mode encoding for STR
    // str x0, [x1], #8 - post-indexed with immediate offset
    // Expected: size=3, VR=0, opc=0, imm9=8, Rn=1, Rt=0
    uint encoding = INSTR.ldst_immpost(3, 0, 0, 8, 1, 0);
    assert(encoding != 0, "str x0, [x1], #8 encoding failed");
}

unittest
{
    // Test register offset with extend operation
    // ldr x0, [x1, x2, lsl #3] - register offset with shift
    // Expected: size=3, VR=0, opc=1, Rm=2, option=3 (LSL), S=1, Rn=1, Rt=0
    uint encoding = INSTR.ldst_regoff(3, 0, 1, 2, 3, 1, 1, 0);
    assert(encoding != 0, "ldr x0, [x1, x2, lsl #3] encoding failed");
}

unittest
{
    // Test register offset with different extend operations
    // ldr x0, [x1, x2, uxtw #2] - register offset with UXTW extend
    // Expected: size=3, VR=0, opc=1, Rm=2, option=2 (UXTW), S=1, Rn=1, Rt=0
    uint encoding = INSTR.ldst_regoff(3, 0, 1, 2, 2, 1, 1, 0);
    assert(encoding != 0, "ldr x0, [x1, x2, uxtw #2] encoding failed");

    // ldr x0, [x1, x2, sxtw #3] - register offset with SXTW extend
    encoding = INSTR.ldst_regoff(3, 0, 1, 2, 6, 1, 1, 0);
    assert(encoding != 0, "ldr x0, [x1, x2, sxtw #3] encoding failed");
}

unittest
{
    // Test 32-bit loads/stores with pre/post-indexed modes
    // ldr w0, [x1, #4]! - 32-bit pre-indexed
    uint encoding = INSTR.ldst_immpre(2, 0, 1, 4, 1, 0);
    assert(encoding != 0, "ldr w0, [x1, #4]! encoding failed");

    // str w0, [x1], #4 - 32-bit post-indexed
    encoding = INSTR.ldst_immpost(2, 0, 0, 4, 1, 0);
    assert(encoding != 0, "str w0, [x1], #4 encoding failed");
}

unittest
{
    // Test negative offsets for pre/post-indexed modes
    // ldr x0, [x1, #-8]! - pre-indexed with negative offset
    // imm9 is 9-bit signed, so -8 should be encoded as 0x1F8 (two's complement)
    uint imm9 = cast(uint)(-8) & 0x1FF;
    uint encoding = INSTR.ldst_immpre(3, 0, 1, imm9, 1, 0);
    assert(encoding != 0, "ldr x0, [x1, #-8]! encoding failed");

    // str x0, [x1], #-16 - post-indexed with negative offset
    imm9 = cast(uint)(-16) & 0x1FF;
    encoding = INSTR.ldst_immpost(3, 0, 0, imm9, 1, 0);
    assert(encoding != 0, "str x0, [x1], #-16 encoding failed");
}

unittest
{
    // Test extend operation parsing
    ExtendOp ext;

    // Simulate tokens for LSL
    // (Note: This is a structural test - actual parsing would require token stream)
    ext = ExtendOp.LSL;
    assert(ext == 3, "LSL extend value incorrect");

    ext = ExtendOp.UXTW;
    assert(ext == 2, "UXTW extend value incorrect");

    ext = ExtendOp.SXTW;
    assert(ext == 6, "SXTW extend value incorrect");

    ext = ExtendOp.SXTX;
    assert(ext == 7, "SXTX extend value incorrect");
}

unittest
{
    // Test different combinations of register offset modes
    // str x5, [x10, x15, lsl #3] - 64-bit store with shifted register offset
    uint encoding = INSTR.ldst_regoff(3, 0, 0, 15, 3, 1, 10, 5);
    assert(encoding != 0, "str x5, [x10, x15, lsl #3] encoding failed");

    // ldr w3, [x7, x9] - 32-bit load with unshifted register offset
    encoding = INSTR.ldst_regoff(2, 0, 1, 9, 3, 0, 7, 3);
    assert(encoding != 0, "ldr w3, [x7, x9] encoding failed");
}

unittest
{
    // Verify that pre-indexed and post-indexed encodings are distinct
    uint pre_enc = INSTR.ldst_immpre(3, 0, 1, 8, 1, 0);
    uint post_enc = INSTR.ldst_immpost(3, 0, 1, 8, 1, 0);
    assert(pre_enc != post_enc, "pre-indexed and post-indexed encodings should differ");

    // The difference should only be in bits [11:10]
    uint diff = pre_enc ^ post_enc;
    assert(diff == (2 << 10), "pre/post difference should only be in bits [11:10]");
}

// Phase 6: Function Call Support Unit Tests

unittest
{
    // Test BL (branch with link) encoding
    // bl label (with offset 0 as placeholder)
    uint encoding = INSTR.bl(0);
    assert(encoding != 0, "bl encoding failed");

    // Verify that BL has op=1 (bit 31)
    assert((encoding & (1 << 31)) != 0, "BL should have op=1 (bit 31 set)");

    // bl with non-zero offset
    encoding = INSTR.bl(0x100);
    assert(encoding != 0, "bl with offset encoding failed");
    assert((encoding & 0x3FFFFFF) == 0x100, "bl offset bits incorrect");
}

unittest
{
    // Test BLR (branch with link to register) encoding
    // blr x0
    uint encoding = INSTR.blr(0);
    assert(encoding != 0, "blr x0 encoding failed");

    // blr x30 (link register)
    encoding = INSTR.blr(30);
    assert(encoding != 0, "blr x30 encoding failed");

    // blr x15
    encoding = INSTR.blr(15);
    assert(encoding != 0, "blr x15 encoding failed");

    // Verify register encoding is in bits [9:5]
    assert(((encoding >> 5) & 0x1F) == 15, "blr register bits incorrect");
}

unittest
{
    // Test BR (branch to register) encoding
    // br x0
    uint encoding = INSTR.br(0);
    assert(encoding != 0, "br x0 encoding failed");

    // br x30
    encoding = INSTR.br(30);
    assert(encoding != 0, "br x30 encoding failed");

    // br x15
    encoding = INSTR.br(15);
    assert(encoding != 0, "br x15 encoding failed");

    // Verify register encoding is in bits [9:5]
    assert(((encoding >> 5) & 0x1F) == 15, "br register bits incorrect");
}

unittest
{
    // Test RET (return) encoding
    // ret (defaults to x30)
    uint encoding = INSTR.ret();
    assert(encoding == 0xd65f03c0, "ret encoding incorrect");

    // ret x30 (explicit)
    encoding = INSTR.ret(30);
    assert(encoding == 0xd65f03c0, "ret x30 encoding incorrect");

    // ret x0
    encoding = INSTR.ret(0);
    assert(encoding != 0, "ret x0 encoding failed");

    // ret x15
    encoding = INSTR.ret(15);
    assert(encoding != 0, "ret x15 encoding failed");

    // Verify register encoding is in bits [9:5]
    assert(((encoding >> 5) & 0x1F) == 15, "ret register bits incorrect");
}

unittest
{
    // Test that BR, BLR, and RET are distinct
    uint br_enc = INSTR.br(0);
    uint blr_enc = INSTR.blr(0);
    uint ret_enc = INSTR.ret(0);

    assert(br_enc != blr_enc, "BR and BLR encodings should differ");
    assert(br_enc != ret_enc, "BR and RET encodings should differ");
    assert(blr_enc != ret_enc, "BLR and RET encodings should differ");

    // They differ in the opc field (bits [22:21])
    // BR: opc=0, BLR: opc=1, RET: opc=2
    uint br_opc = (br_enc >> 21) & 3;
    uint blr_opc = (blr_enc >> 21) & 3;
    uint ret_opc = (ret_enc >> 21) & 3;

    assert(br_opc == 0, "BR opc should be 0");
    assert(blr_opc == 1, "BLR opc should be 1");
    assert(ret_opc == 2, "RET opc should be 2");
}

unittest
{
    // Test BL vs B encoding difference
    uint b_enc = INSTR.b_uncond(0);
    uint bl_enc = INSTR.bl(0);

    assert(b_enc != bl_enc, "B and BL encodings should differ");

    // They differ in the op field (bit 31)
    // B: op=0, BL: op=1
    assert((b_enc & (1 << 31)) == 0, "B should have op=0");
    assert((bl_enc & (1 << 31)) != 0, "BL should have op=1");
}

unittest
{
    // Test function call instruction dispatch table entries
    assert(lookupInstruction("bl") !is null, "bl should be in dispatch table");
    assert(lookupInstruction("blr") !is null, "blr should be in dispatch table");
    assert(lookupInstruction("br") !is null, "br should be in dispatch table");
    assert(lookupInstruction("ret") !is null, "ret should be in dispatch table");

    // Case insensitivity
    assert(lookupInstruction("BL") !is null, "BL should be case-insensitive");
    assert(lookupInstruction("BLR") !is null, "BLR should be case-insensitive");
    assert(lookupInstruction("BR") !is null, "BR should be case-insensitive");
    assert(lookupInstruction("RET") !is null, "RET should be case-insensitive");
}

unittest
{
    // Test various register encodings for function call instructions
    // Test different registers for BLR
    for (ubyte r = 0; r <= 30; r++)
    {
        uint enc = INSTR.blr(r);
        uint decoded_reg = (enc >> 5) & 0x1F;
        assert(decoded_reg == r, "BLR register encoding incorrect");
    }

    // Test different registers for BR
    for (ubyte r = 0; r <= 30; r++)
    {
        uint enc = INSTR.br(r);
        uint decoded_reg = (enc >> 5) & 0x1F;
        assert(decoded_reg == r, "BR register encoding incorrect");
    }

    // Test different registers for RET
    for (ubyte r = 0; r <= 30; r++)
    {
        uint enc = INSTR.ret(r);
        uint decoded_reg = (enc >> 5) & 0x1F;
        assert(decoded_reg == r, "RET register encoding incorrect");
    }
}

// Phase 5: Additional Load/Store Instructions Unit Tests

unittest
{
    // Test LDP (load pair) encoding with different addressing modes
    // ldp x0, x1, [x2] - offset mode
    uint encoding = INSTR.ldstpair_off(2, 0, 1, 0, 1, 2, 0);
    assert(encoding != 0, "ldp x0, x1, [x2] encoding failed");

    // ldp x3, x4, [x5, #16] - offset mode with immediate
    encoding = INSTR.ldstpair_off(2, 0, 1, 16 / 8, 4, 5, 3);
    assert(encoding != 0, "ldp x3, x4, [x5, #16] encoding failed");

    // ldp x6, x7, [x8, #16]! - pre-indexed mode
    encoding = INSTR.ldstpair_pre(2, 0, 1, 16 / 8, 7, 8, 6);
    assert(encoding != 0, "ldp x6, x7, [x8, #16]! encoding failed");

    // ldp x9, x10, [x11], #16 - post-indexed mode
    encoding = INSTR.ldstpair_post(2, 0, 1, 16 / 8, 10, 11, 9);
    assert(encoding != 0, "ldp x9, x10, [x11], #16 encoding failed");
}

unittest
{
    // Test STP (store pair) encoding with different addressing modes
    // stp x0, x1, [x2] - offset mode
    uint encoding = INSTR.ldstpair_off(2, 0, 0, 0, 1, 2, 0);
    assert(encoding != 0, "stp x0, x1, [x2] encoding failed");

    // stp x3, x4, [x5, #16] - offset mode with immediate
    encoding = INSTR.ldstpair_off(2, 0, 0, 16 / 8, 4, 5, 3);
    assert(encoding != 0, "stp x3, x4, [x5, #16] encoding failed");

    // stp x6, x7, [x8, #16]! - pre-indexed mode
    encoding = INSTR.ldstpair_pre(2, 0, 0, 16 / 8, 7, 8, 6);
    assert(encoding != 0, "stp x6, x7, [x8, #16]! encoding failed");

    // stp x9, x10, [x11], #16 - post-indexed mode
    encoding = INSTR.ldstpair_post(2, 0, 0, 16 / 8, 10, 11, 9);
    assert(encoding != 0, "stp x9, x10, [x11], #16 encoding failed");
}

unittest
{
    // Test that LDP and STP are distinct for same operands
    uint ldp_enc = INSTR.ldstpair_off(2, 0, 1, 0, 2, 1, 0);
    uint stp_enc = INSTR.ldstpair_off(2, 0, 0, 0, 2, 1, 0);
    assert(ldp_enc != stp_enc, "LDP and STP encodings should differ");
}

unittest
{
    // Test LDRB (load byte) encoding
    // ldrb w0, [x1] - offset mode
    uint encoding = INSTR.ldrb_imm(0, 0, 1, 0);
    assert(encoding != 0, "ldrb w0, [x1] encoding failed");

    // ldrb w2, [x3, #4] - offset mode with immediate
    encoding = INSTR.ldrb_imm(0, 2, 3, 4);
    assert(encoding != 0, "ldrb w2, [x3, #4] encoding failed");

    // Verify size field for byte access
    uint size = (encoding >> 30) & 3;
    assert(size == 0, "LDRB size field should be 0 for byte access");
}

unittest
{
    // Test STRB (store byte) encoding
    // strb w0, [x1] - offset mode
    uint encoding = INSTR.strb_imm(0, 1, 0);
    assert(encoding != 0, "strb w0, [x1] encoding failed");

    // strb w2, [x3, #4] - offset mode with immediate
    encoding = INSTR.strb_imm(2, 3, 4);
    assert(encoding != 0, "strb w2, [x3, #4] encoding failed");

    // Verify size field for byte access
    uint size = (encoding >> 30) & 3;
    assert(size == 0, "STRB size field should be 0 for byte access");
}

unittest
{
    // Test that LDRB and STRB are distinct for same operands
    uint ldrb_enc = INSTR.ldrb_imm(0, 0, 1, 0);
    uint strb_enc = INSTR.strb_imm(0, 1, 0);
    assert(ldrb_enc != strb_enc, "LDRB and STRB encodings should differ");
}

unittest
{
    // Test LDRH (load halfword) encoding
    // ldrh w0, [x1] - offset mode
    uint encoding = INSTR.ldrh_imm(0, 0, 1, 0);
    assert(encoding != 0, "ldrh w0, [x1] encoding failed");

    // ldrh w2, [x3, #8] - offset mode with immediate
    encoding = INSTR.ldrh_imm(0, 2, 3, 8);
    assert(encoding != 0, "ldrh w2, [x3, #8] encoding failed");

    // Verify size field for halfword access
    uint size = (encoding >> 30) & 3;
    assert(size == 1, "LDRH size field should be 1 for halfword access");
}

unittest
{
    // Test STRH (store halfword) encoding
    // strh w0, [x1] - offset mode
    uint encoding = INSTR.strh_imm(0, 1, 0);
    assert(encoding != 0, "strh w0, [x1] encoding failed");

    // strh w2, [x3, #8] - offset mode with immediate
    encoding = INSTR.strh_imm(2, 3, 8);
    assert(encoding != 0, "strh w2, [x3, #8] encoding failed");

    // Verify size field for halfword access
    uint size = (encoding >> 30) & 3;
    assert(size == 1, "STRH size field should be 1 for halfword access");
}

unittest
{
    // Test that LDRH and STRH are distinct for same operands
    uint ldrh_enc = INSTR.ldrh_imm(0, 0, 1, 0);
    uint strh_enc = INSTR.strh_imm(0, 1, 0);
    assert(ldrh_enc != strh_enc, "LDRH and STRH encodings should differ");
}

unittest
{
    // Test LDRSB (load signed byte) encoding
    // ldrsb w0, [x1] - load to 32-bit register
    uint encoding = INSTR.ldrsb_imm(0, 0, 1, 0);
    assert(encoding != 0, "ldrsb w0, [x1] encoding failed");

    // ldrsb x2, [x3] - load to 64-bit register
    encoding = INSTR.ldrsb_imm(1, 2, 3, 0);
    assert(encoding != 0, "ldrsb x2, [x3] encoding failed");

    // ldrsb w4, [x5, #4] - with immediate offset
    encoding = INSTR.ldrsb_imm(0, 4, 5, 4);
    assert(encoding != 0, "ldrsb w4, [x5, #4] encoding failed");

    // Verify that 32-bit and 64-bit variants are different
    uint enc_w = INSTR.ldrsb_imm(0, 0, 1, 0);
    uint enc_x = INSTR.ldrsb_imm(1, 0, 1, 0);
    assert(enc_w != enc_x, "LDRSB w and LDRSB x should differ");
}

unittest
{
    // Test LDRSH (load signed halfword) encoding
    // ldrsh w0, [x1] - load to 32-bit register
    uint encoding = INSTR.ldrsh_imm(0, 0, 1, 0);
    assert(encoding != 0, "ldrsh w0, [x1] encoding failed");

    // ldrsh x2, [x3] - load to 64-bit register
    encoding = INSTR.ldrsh_imm(1, 2, 3, 0);
    assert(encoding != 0, "ldrsh x2, [x3] encoding failed");

    // ldrsh w4, [x5, #8] - with immediate offset
    encoding = INSTR.ldrsh_imm(0, 4, 5, 8);
    assert(encoding != 0, "ldrsh w4, [x5, #8] encoding failed");

    // Verify that 32-bit and 64-bit variants are different
    uint enc_w = INSTR.ldrsh_imm(0, 0, 1, 0);
    uint enc_x = INSTR.ldrsh_imm(1, 0, 1, 0);
    assert(enc_w != enc_x, "LDRSH w and LDRSH x should differ");
}

unittest
{
    // Test LDRSW (load signed word to 64-bit) encoding
    // ldrsw x0, [x1] - load signed 32-bit to 64-bit
    uint encoding = INSTR.ldrsw_imm(0, 1, 0);
    assert(encoding != 0, "ldrsw x0, [x1] encoding failed");

    // ldrsw x2, [x3, #8] - with immediate offset (8/4 = 2)
    encoding = INSTR.ldrsw_imm(2, 3, 2);
    assert(encoding != 0, "ldrsw x2, [x3, #8] encoding failed");

    // Verify size field for word access
    uint size = (encoding >> 30) & 3;
    assert(size == 2, "LDRSW size field should be 2 for word access");
}

unittest
{
    // Test Phase 5 instruction dispatch table entries
    assert(lookupInstruction("ldp") !is null, "ldp should be in dispatch table");
    assert(lookupInstruction("stp") !is null, "stp should be in dispatch table");
    assert(lookupInstruction("ldrb") !is null, "ldrb should be in dispatch table");
    assert(lookupInstruction("strb") !is null, "strb should be in dispatch table");
    assert(lookupInstruction("ldrh") !is null, "ldrh should be in dispatch table");
    assert(lookupInstruction("strh") !is null, "strh should be in dispatch table");
    assert(lookupInstruction("ldrsb") !is null, "ldrsb should be in dispatch table");
    assert(lookupInstruction("ldrsh") !is null, "ldrsh should be in dispatch table");
    assert(lookupInstruction("ldrsw") !is null, "ldrsw should be in dispatch table");

    // Case insensitivity
    assert(lookupInstruction("LDP") !is null, "LDP should be case-insensitive");
    assert(lookupInstruction("STP") !is null, "STP should be case-insensitive");
    assert(lookupInstruction("LDRB") !is null, "LDRB should be case-insensitive");
    assert(lookupInstruction("STRB") !is null, "STRB should be case-insensitive");
}

unittest
{
    // Test that different size loads produce different encodings
    uint ldrb_enc = INSTR.ldrb_imm(0, 0, 1, 0);   // byte
    uint ldrh_enc = INSTR.ldrh_imm(0, 0, 1, 0);   // halfword
    uint ldr_enc = INSTR.ldr_imm_gen(0, 0, 1, 0);  // word (32-bit)

    assert(ldrb_enc != ldrh_enc, "LDRB and LDRH should differ");
    assert(ldrb_enc != ldr_enc, "LDRB and LDR should differ");
    assert(ldrh_enc != ldr_enc, "LDRH and LDR should differ");

    // Verify size fields
    assert(((ldrb_enc >> 30) & 3) == 0, "LDRB size should be 0");
    assert(((ldrh_enc >> 30) & 3) == 1, "LDRH size should be 1");
}

unittest
{
    // Test pair instruction offset encoding
    // For 64-bit pairs, offset is in units of 8 bytes
    uint ldp_0 = INSTR.ldstpair_off(2, 0, 1, 0, 2, 1, 0);      // offset 0
    uint ldp_8 = INSTR.ldstpair_off(2, 0, 1, 1, 2, 1, 0);      // offset 8 (1 * 8)
    uint ldp_16 = INSTR.ldstpair_off(2, 0, 1, 2, 2, 1, 0);     // offset 16 (2 * 8)

    assert(ldp_0 != ldp_8, "Different offsets should produce different encodings");
    assert(ldp_8 != ldp_16, "Different offsets should produce different encodings");
    assert(ldp_0 != ldp_16, "Different offsets should produce different encodings");
}

unittest
{
    // Test pair instruction addressing mode encoding
    uint ldp_offset = INSTR.ldstpair_off(2, 0, 1, 0, 2, 1, 0);      // [Xn, #imm]
    uint ldp_pre = INSTR.ldstpair_pre(2, 0, 1, 0, 2, 1, 0);         // [Xn, #imm]!
    uint ldp_post = INSTR.ldstpair_post(2, 0, 1, 0, 2, 1, 0);       // [Xn], #imm

    assert(ldp_offset != ldp_pre, "Offset and pre-indexed should differ");
    assert(ldp_offset != ldp_post, "Offset and post-indexed should differ");
    assert(ldp_pre != ldp_post, "Pre-indexed and post-indexed should differ");
}

// Phase 5: Additional edge case unit tests

unittest
{
    // Test pair instructions with 32-bit variants
    uint ldp_w = INSTR.ldstpair_off(0, 0, 1, 0, 1, 2, 0);  // ldp w0, w1, [x2]
    uint ldp_x = INSTR.ldstpair_off(2, 0, 1, 0, 1, 2, 0);  // ldp x0, x1, [x2]

    assert(ldp_w != ldp_x, "32-bit and 64-bit pair instructions should differ");

    // Verify opc field
    uint opc_w = (ldp_w >> 30) & 3;
    uint opc_x = (ldp_x >> 30) & 3;
    assert(opc_w == 0, "32-bit pair opc should be 0");
    assert(opc_x == 2, "64-bit pair opc should be 2");
}

unittest
{
    // Test pair instructions with negative offsets
    // For 64-bit pairs, -16 bytes = -2 units (scaled by 8)
    uint neg_offset = cast(uint)(-2) & 0x7F;
    uint ldp_neg = INSTR.ldstpair_off(2, 0, 1, neg_offset, 2, 1, 0);
    uint ldp_pos = INSTR.ldstpair_off(2, 0, 1, 2, 2, 1, 0);

    assert(ldp_neg != ldp_pos, "Negative and positive offsets should differ");
}

unittest
{
    // Test byte load with different register offset extend modes
    uint ldrb_lsl = INSTR.ldrb_reg(0, 1, ExtendOp.LSL, 0, 2, 0);
    uint ldrb_uxtw = INSTR.ldrb_reg(0, 1, ExtendOp.UXTW, 0, 2, 0);
    uint ldrb_sxtw = INSTR.ldrb_reg(0, 1, ExtendOp.SXTW, 0, 2, 0);

    assert(ldrb_lsl != ldrb_uxtw, "Different extend modes should differ");
    assert(ldrb_lsl != ldrb_sxtw, "Different extend modes should differ");
    assert(ldrb_uxtw != ldrb_sxtw, "Different extend modes should differ");
}

unittest
{
    // Test halfword load with scaled vs unscaled register offset
    uint ldrh_unscaled = INSTR.ldrh_reg(0, 1, ExtendOp.LSL, 0, 2, 0);  // S=0
    uint ldrh_scaled = INSTR.ldrh_reg(0, 1, ExtendOp.LSL, 1, 2, 0);    // S=1

    assert(ldrh_unscaled != ldrh_scaled, "Scaled and unscaled should differ");
}

unittest
{
    // Test signed loads with maximum immediate offsets
    uint ldrsb_max = INSTR.ldrsb_imm(0, 0, 1, 0xFFF);  // Max 12-bit unsigned
    uint ldrsb_zero = INSTR.ldrsb_imm(0, 0, 1, 0);

    assert(ldrsb_max != ldrsb_zero, "Different offsets should differ");
}

unittest
{
    // Test that signed loads with W vs X destinations differ
    uint ldrsb_w = INSTR.ldrsb_imm(0, 0, 1, 0);
    uint ldrsb_x = INSTR.ldrsb_imm(1, 0, 1, 0);

    assert(ldrsb_w != ldrsb_x, "W and X destinations should differ");

    uint ldrsh_w = INSTR.ldrsh_imm(0, 0, 1, 0);
    uint ldrsh_x = INSTR.ldrsh_imm(1, 0, 1, 0);

    assert(ldrsh_w != ldrsh_x, "W and X destinations should differ");
}

unittest
{
    // Test LDRSW with scaled offset (word-aligned)
    // Offset is in units of 4 bytes, so 0 and 1 represent 0 and 4 byte offsets
    uint ldrsw_0 = INSTR.ldrsw_imm(0, 1, 0);
    uint ldrsw_4 = INSTR.ldrsw_imm(1, 1, 0);  // 1 * 4 = 4 bytes
    uint ldrsw_8 = INSTR.ldrsw_imm(2, 1, 0);  // 2 * 4 = 8 bytes

    assert(ldrsw_0 != ldrsw_4, "Different offsets should differ");
    assert(ldrsw_4 != ldrsw_8, "Different offsets should differ");
    assert(ldrsw_0 != ldrsw_8, "Different offsets should differ");
}

unittest
{
    // Test that byte/halfword/word sizes are properly encoded
    uint ldrb = INSTR.ldrb_imm(0, 0, 1, 0);
    uint ldrh = INSTR.ldrh_imm(0, 0, 1, 0);
    uint ldr_w = INSTR.ldr_imm_gen(0, 0, 1, 0);
    uint ldr_x = INSTR.ldr_imm_gen(1, 0, 1, 0);

    // All four should be distinct
    assert(ldrb != ldrh, "Byte and halfword should differ");
    assert(ldrb != ldr_w, "Byte and word should differ");
    assert(ldrb != ldr_x, "Byte and doubleword should differ");
    assert(ldrh != ldr_w, "Halfword and word should differ");
    assert(ldrh != ldr_x, "Halfword and doubleword should differ");
    assert(ldr_w != ldr_x, "Word and doubleword should differ");
}

unittest
{
    // Test pair instructions with maximum positive offset
    // For 64-bit pairs: 7-bit signed, max positive = 0x3F (63 units * 8 = 504 bytes)
    uint ldp_max = INSTR.ldstpair_off(2, 0, 1, 0x3F, 2, 1, 0);
    uint ldp_min = INSTR.ldstpair_off(2, 0, 1, 0, 2, 1, 0);

    assert(ldp_max != ldp_min, "Max and min offsets should differ");
}

unittest
{
    // Test store vs load with register offsets for byte/halfword
    uint ldrb_reg = INSTR.ldrb_reg(0, 1, ExtendOp.LSL, 0, 2, 0);
    uint strb_reg = INSTR.strb_reg(1, ExtendOp.LSL, 0, 2, 0);

    assert(ldrb_reg != strb_reg, "Load and store should differ");

    uint ldrh_reg = INSTR.ldrh_reg(0, 1, ExtendOp.LSL, 1, 2, 0);
    uint strh_reg = INSTR.strh_reg(1, ExtendOp.LSL, 1, 2, 0);

    assert(ldrh_reg != strh_reg, "Load and store should differ");
}

// Phase 4.1: Arithmetic Instructions Unit Tests

unittest
{
    // Test MADD (multiply-add) encoding
    // madd x0, x1, x2, x3 -> x0 = x3 + x1 * x2
    uint encoding = INSTR.madd(1, 2, 3, 1, 0);
    assert(encoding != 0, "madd x0, x1, x2, x3 encoding failed");

    // Test 32-bit variant: madd w0, w1, w2, w3
    uint encoding_w = INSTR.madd(0, 2, 3, 1, 0);
    assert(encoding_w != 0, "madd w0, w1, w2, w3 encoding failed");

    // 64-bit and 32-bit should differ
    assert(encoding != encoding_w, "MADD 64-bit and 32-bit should differ");

    // Verify sf bit (bit 31)
    assert((encoding >> 31) & 1, "MADD 64-bit should have sf=1");
    assert(!((encoding_w >> 31) & 1), "MADD 32-bit should have sf=0");

    // Test with different registers
    uint enc2 = INSTR.madd(1, 10, 11, 12, 13);
    assert(enc2 != encoding, "Different registers should produce different encodings");

    // Verify register fields
    assert((enc2 & 0x1F) == 13, "MADD Rd field incorrect");
    assert(((enc2 >> 5) & 0x1F) == 12, "MADD Rn field incorrect");
    assert(((enc2 >> 10) & 0x1F) == 11, "MADD Ra field incorrect");
    assert(((enc2 >> 16) & 0x1F) == 10, "MADD Rm field incorrect");
}

unittest
{
    // Test MSUB (multiply-subtract) encoding
    // msub x0, x1, x2, x3 -> x0 = x3 - x1 * x2
    uint encoding = INSTR.msub(1, 2, 3, 1, 0);
    assert(encoding != 0, "msub x0, x1, x2, x3 encoding failed");

    // Test 32-bit variant: msub w0, w1, w2, w3
    uint encoding_w = INSTR.msub(0, 2, 3, 1, 0);
    assert(encoding_w != 0, "msub w0, w1, w2, w3 encoding failed");

    // 64-bit and 32-bit should differ
    assert(encoding != encoding_w, "MSUB 64-bit and 32-bit should differ");

    // MADD and MSUB should differ (o0 bit differs)
    uint madd_enc = INSTR.madd(1, 2, 3, 1, 0);
    assert(encoding != madd_enc, "MSUB and MADD should differ");

    // Verify they only differ in bit 15 (o0 field)
    uint diff = encoding ^ madd_enc;
    assert(diff == (1 << 15), "MADD and MSUB should only differ in bit 15");

    // Test with different registers
    uint enc2 = INSTR.msub(1, 10, 11, 12, 13);
    assert((enc2 & 0x1F) == 13, "MSUB Rd field incorrect");
    assert(((enc2 >> 5) & 0x1F) == 12, "MSUB Rn field incorrect");
}

unittest
{
    // Test SDIV (signed division) encoding
    // sdiv x0, x1, x2 -> x0 = x1 / x2 (signed)
    uint encoding = INSTR.sdiv_udiv(1, false, 2, 1, 0);
    assert(encoding != 0, "sdiv x0, x1, x2 encoding failed");

    // Test 32-bit variant: sdiv w0, w1, w2
    uint encoding_w = INSTR.sdiv_udiv(0, false, 2, 1, 0);
    assert(encoding_w != 0, "sdiv w0, w1, w2 encoding failed");

    // 64-bit and 32-bit should differ
    assert(encoding != encoding_w, "SDIV 64-bit and 32-bit should differ");

    // Verify sf bit (bit 31)
    assert((encoding >> 31) & 1, "SDIV 64-bit should have sf=1");
    assert(!((encoding_w >> 31) & 1), "SDIV 32-bit should have sf=0");

    // Test with different registers
    uint enc2 = INSTR.sdiv_udiv(1, false, 10, 11, 12);
    assert(enc2 != encoding, "Different registers should produce different encodings");

    // Verify register fields
    assert((enc2 & 0x1F) == 12, "SDIV Rd field incorrect");
    assert(((enc2 >> 5) & 0x1F) == 11, "SDIV Rn field incorrect");
    assert(((enc2 >> 16) & 0x1F) == 10, "SDIV Rm field incorrect");
}

unittest
{
    // Test UDIV (unsigned division) encoding
    // udiv x0, x1, x2 -> x0 = x1 / x2 (unsigned)
    uint encoding = INSTR.sdiv_udiv(1, true, 2, 1, 0);
    assert(encoding != 0, "udiv x0, x1, x2 encoding failed");

    // Test 32-bit variant: udiv w0, w1, w2
    uint encoding_w = INSTR.sdiv_udiv(0, true, 2, 1, 0);
    assert(encoding_w != 0, "udiv w0, w1, w2 encoding failed");

    // 64-bit and 32-bit should differ
    assert(encoding != encoding_w, "UDIV 64-bit and 32-bit should differ");

    // SDIV and UDIV should differ (opcode bit differs)
    uint sdiv_enc = INSTR.sdiv_udiv(1, false, 2, 1, 0);
    assert(encoding != sdiv_enc, "UDIV and SDIV should differ");

    // Verify they differ in opcode field
    uint diff = encoding ^ sdiv_enc;
    assert(diff != 0, "SDIV and UDIV should have different opcodes");

    // Test with different registers
    uint enc2 = INSTR.sdiv_udiv(1, true, 10, 11, 12);
    assert((enc2 & 0x1F) == 12, "UDIV Rd field incorrect");
    assert(((enc2 >> 5) & 0x1F) == 11, "UDIV Rn field incorrect");
}

unittest
{
    // Test NEG (negate) encoding without shift
    // neg x0, x1 -> x0 = 0 - x1
    uint encoding = INSTR.neg_sub_addsub_shift(1, 0, 0, 1, 0, 0);
    assert(encoding != 0, "neg x0, x1 encoding failed");

    // Test 32-bit variant: neg w0, w1
    uint encoding_w = INSTR.neg_sub_addsub_shift(0, 0, 0, 1, 0, 0);
    assert(encoding_w != 0, "neg w0, w1 encoding failed");

    // 64-bit and 32-bit should differ
    assert(encoding != encoding_w, "NEG 64-bit and 32-bit should differ");

    // Verify sf bit (bit 31)
    assert((encoding >> 31) & 1, "NEG 64-bit should have sf=1");
    assert(!((encoding_w >> 31) & 1), "NEG 32-bit should have sf=0");

    // Test with different registers
    uint enc2 = INSTR.neg_sub_addsub_shift(1, 0, 0, 10, 0, 11);
    assert(enc2 != encoding, "Different registers should produce different encodings");

    // Verify register fields
    assert((enc2 & 0x1F) == 11, "NEG Rd field incorrect");
    assert(((enc2 >> 16) & 0x1F) == 10, "NEG Rm field incorrect");
}

unittest
{
    // Test NEG with LSL shift
    // neg x0, x1, lsl #2 -> x0 = 0 - (x1 << 2)
    uint enc_lsl = INSTR.neg_sub_addsub_shift(1, 0, 0, 1, 2, 0);
    assert(enc_lsl != 0, "neg x0, x1, lsl #2 encoding failed");

    // NEG with and without shift should differ
    uint enc_no_shift = INSTR.neg_sub_addsub_shift(1, 0, 0, 1, 0, 0);
    assert(enc_lsl != enc_no_shift, "NEG with shift should differ from without shift");

    // Verify shift amount in bits [15:10]
    uint shift_amt = (enc_lsl >> 10) & 0x3F;
    assert(shift_amt == 2, "NEG shift amount incorrect");
}

unittest
{
    // Test NEG with different shift types
    // LSL (shift = 0)
    uint enc_lsl = INSTR.neg_sub_addsub_shift(1, 0, 0, 1, 3, 0);

    // LSR (shift = 1)
    uint enc_lsr = INSTR.neg_sub_addsub_shift(1, 0, 1, 1, 3, 0);

    // ASR (shift = 2)
    uint enc_asr = INSTR.neg_sub_addsub_shift(1, 0, 2, 1, 3, 0);

    // ROR (shift = 3)
    uint enc_ror = INSTR.neg_sub_addsub_shift(1, 0, 3, 1, 3, 0);

    // All four shift types should produce different encodings
    assert(enc_lsl != enc_lsr, "LSL and LSR should differ");
    assert(enc_lsl != enc_asr, "LSL and ASR should differ");
    assert(enc_lsl != enc_ror, "LSL and ROR should differ");
    assert(enc_lsr != enc_asr, "LSR and ASR should differ");
    assert(enc_lsr != enc_ror, "LSR and ROR should differ");
    assert(enc_asr != enc_ror, "ASR and ROR should differ");

    // Verify shift type in bits [23:22]
    assert(((enc_lsl >> 22) & 3) == 0, "LSL shift type should be 0");
    assert(((enc_lsr >> 22) & 3) == 1, "LSR shift type should be 1");
    assert(((enc_asr >> 22) & 3) == 2, "ASR shift type should be 2");
    assert(((enc_ror >> 22) & 3) == 3, "ROR shift type should be 3");
}

unittest
{
    // Test Phase 4.1 instruction dispatch table entries
    assert(lookupInstruction("madd") !is null, "madd should be in dispatch table");
    assert(lookupInstruction("msub") !is null, "msub should be in dispatch table");
    assert(lookupInstruction("sdiv") !is null, "sdiv should be in dispatch table");
    assert(lookupInstruction("udiv") !is null, "udiv should be in dispatch table");
    assert(lookupInstruction("neg") !is null, "neg should be in dispatch table");

    // Case insensitivity
    assert(lookupInstruction("MADD") !is null, "MADD should be case-insensitive");
    assert(lookupInstruction("MSUB") !is null, "MSUB should be case-insensitive");
    assert(lookupInstruction("SDIV") !is null, "SDIV should be case-insensitive");
    assert(lookupInstruction("UDIV") !is null, "UDIV should be case-insensitive");
    assert(lookupInstruction("NEG") !is null, "NEG should be case-insensitive");
}

unittest
{
    // Test that MUL and MADD encodings are related correctly
    // MUL is encoded as MADD with Ra=31 (XZR)
    // mul x0, x1, x2 -> x0 = 0 + x1 * x2 = x1 * x2
    uint mul_enc = INSTR.madd(1, 2, 31, 1, 0);  // Ra=31 for MUL
    uint madd_enc = INSTR.madd(1, 2, 3, 1, 0);  // Ra=3 for MADD

    // They should only differ in the Ra field (bits [14:10])
    uint ra_mul = (mul_enc >> 10) & 0x1F;
    uint ra_madd = (madd_enc >> 10) & 0x1F;

    assert(ra_mul == 31, "MUL should have Ra=31");
    assert(ra_madd == 3, "MADD should have Ra=3");
}

unittest
{
    // Test division with all register combinations
    for (ubyte rd = 0; rd <= 10; rd++)
    {
        for (ubyte rn = 0; rn <= 10; rn++)
        {
            for (ubyte rm = 0; rm <= 10; rm++)
            {
                // Test SDIV
                uint sdiv_enc = INSTR.sdiv_udiv(1, false, rm, rn, rd);
                assert((sdiv_enc & 0x1F) == rd, "SDIV Rd encoding failed");
                assert(((sdiv_enc >> 5) & 0x1F) == rn, "SDIV Rn encoding failed");
                assert(((sdiv_enc >> 16) & 0x1F) == rm, "SDIV Rm encoding failed");

                // Test UDIV
                uint udiv_enc = INSTR.sdiv_udiv(1, true, rm, rn, rd);
                assert((udiv_enc & 0x1F) == rd, "UDIV Rd encoding failed");
                assert(((udiv_enc >> 5) & 0x1F) == rn, "UDIV Rn encoding failed");
                assert(((udiv_enc >> 16) & 0x1F) == rm, "UDIV Rm encoding failed");
            }
        }
    }
}

unittest
{
    // Test NEG with maximum shift amounts
    // 64-bit: maximum shift is 63
    uint enc_max64 = INSTR.neg_sub_addsub_shift(1, 0, 0, 1, 63, 0);
    assert(((enc_max64 >> 10) & 0x3F) == 63, "NEG 64-bit max shift incorrect");

    // 32-bit: maximum shift is 31
    uint enc_max32 = INSTR.neg_sub_addsub_shift(0, 0, 0, 1, 31, 0);
    assert(((enc_max32 >> 10) & 0x3F) == 31, "NEG 32-bit max shift incorrect");

    // Zero shift
    uint enc_zero = INSTR.neg_sub_addsub_shift(1, 0, 0, 1, 0, 0);
    assert(((enc_zero >> 10) & 0x3F) == 0, "NEG zero shift incorrect");
}

unittest
{
    // Test MADD/MSUB edge cases with register 31 (XZR/SP)
    // Using XZR as addend/minuend should be valid
    uint madd_xzr = INSTR.madd(1, 2, 31, 1, 0);  // x0 = XZR + x1 * x2
    assert(madd_xzr != 0, "MADD with XZR as addend encoding failed");
    assert(((madd_xzr >> 10) & 0x1F) == 31, "MADD XZR addend incorrect");

    uint msub_xzr = INSTR.msub(1, 2, 31, 1, 0);  // x0 = XZR - x1 * x2
    assert(msub_xzr != 0, "MSUB with XZR as minuend encoding failed");
    assert(((msub_xzr >> 10) & 0x1F) == 31, "MSUB XZR minuend incorrect");

    // Using different source registers
    uint madd_all_diff = INSTR.madd(1, 5, 6, 7, 8);
    assert((madd_all_diff & 0x1F) == 8, "MADD with different regs Rd failed");
    assert(((madd_all_diff >> 5) & 0x1F) == 7, "MADD with different regs Rn failed");
    assert(((madd_all_diff >> 10) & 0x1F) == 6, "MADD with different regs Ra failed");
    assert(((madd_all_diff >> 16) & 0x1F) == 5, "MADD with different regs Rm failed");
}

// Phase 4.2: BIC and TST Instructions Unit Tests

unittest
{
    // Test BIC (Bit Clear) encoding without shift
    // bic x0, x1, x2 -> x0 = x1 & ~x2
    uint encoding = INSTR.log_shift(1, 0, 0, 1, 2, 0, 1, 0);
    assert(encoding != 0, "bic x0, x1, x2 encoding failed");

    // Verify N bit (bit 21) is set for NOT
    assert((encoding >> 21) & 1, "BIC should have N=1 (NOT bit)");

    // Verify opc field (bits [30:29]) is 0 for AND
    assert(((encoding >> 29) & 3) == 0, "BIC should have opc=0 (AND)");

    // Test 32-bit variant: bic w0, w1, w2
    uint encoding_w = INSTR.log_shift(0, 0, 0, 1, 2, 0, 1, 0);
    assert(encoding_w != 0, "bic w0, w1, w2 encoding failed");

    // 64-bit and 32-bit should differ
    assert(encoding != encoding_w, "BIC 64-bit and 32-bit should differ");

    // Verify sf bit (bit 31)
    assert((encoding >> 31) & 1, "BIC 64-bit should have sf=1");
    assert(!((encoding_w >> 31) & 1), "BIC 32-bit should have sf=0");

    // Test with different registers
    uint enc2 = INSTR.log_shift(1, 0, 0, 1, 10, 0, 11, 12);
    assert(enc2 != encoding, "Different registers should produce different encodings");

    // Verify register fields
    assert((enc2 & 0x1F) == 12, "BIC Rd field incorrect");
    assert(((enc2 >> 5) & 0x1F) == 11, "BIC Rn field incorrect");
    assert(((enc2 >> 16) & 0x1F) == 10, "BIC Rm field incorrect");
}

unittest
{
    // Test BIC with shifts
    // bic x0, x1, x2, lsl #3
    uint enc_lsl = INSTR.log_shift(1, 0, 0, 1, 2, 3, 1, 0);
    assert(enc_lsl != 0, "bic x0, x1, x2, lsl #3 encoding failed");

    // Verify shift amount in bits [15:10]
    uint shift_amt = (enc_lsl >> 10) & 0x3F;
    assert(shift_amt == 3, "BIC shift amount should be 3");

    // Verify shift type in bits [23:22]
    uint shift_type = (enc_lsl >> 22) & 3;
    assert(shift_type == 0, "LSL shift type should be 0");

    // Test different shift types
    uint enc_lsr = INSTR.log_shift(1, 0, 1, 1, 2, 4, 1, 0);  // LSR
    assert(((enc_lsr >> 22) & 3) == 1, "LSR shift type should be 1");
    assert(((enc_lsr >> 10) & 0x3F) == 4, "LSR shift amount should be 4");

    uint enc_asr = INSTR.log_shift(1, 0, 2, 1, 2, 8, 1, 0);  // ASR
    assert(((enc_asr >> 22) & 3) == 2, "ASR shift type should be 2");
    assert(((enc_asr >> 10) & 0x3F) == 8, "ASR shift amount should be 8");

    uint enc_ror = INSTR.log_shift(1, 0, 3, 1, 2, 16, 1, 0);  // ROR
    assert(((enc_ror >> 22) & 3) == 3, "ROR shift type should be 3");
    assert(((enc_ror >> 10) & 0x3F) == 16, "ROR shift amount should be 16");

    // All four shift types should produce different encodings
    assert(enc_lsl != enc_lsr, "LSL and LSR should differ");
    assert(enc_lsl != enc_asr, "LSL and ASR should differ");
    assert(enc_lsl != enc_ror, "LSL and ROR should differ");
}

unittest
{
    // Test BIC vs AND difference (N bit)
    uint and_enc = INSTR.log_shift(1, 0, 0, 0, 2, 0, 1, 0);  // AND
    uint bic_enc = INSTR.log_shift(1, 0, 0, 1, 2, 0, 1, 0);  // BIC

    // They should only differ in bit 21 (N field)
    uint diff = and_enc ^ bic_enc;
    assert(diff == (1 << 21), "AND and BIC should only differ in bit 21");

    // Verify N bit
    assert(!((and_enc >> 21) & 1), "AND should have N=0");
    assert((bic_enc >> 21) & 1, "BIC should have N=1");
}

unittest
{
    // Test TST (Test) encoding without shift
    // tst x1, x2 -> flags = x1 & x2, result to XZR (Rd=31)
    uint encoding = INSTR.log_shift(1, 3, 0, 0, 2, 0, 1, 31);
    assert(encoding != 0, "tst x1, x2 encoding failed");

    // Verify Rd is 31 (XZR) - TST doesn't write result, only sets flags
    assert((encoding & 0x1F) == 31, "TST should have Rd=31 (XZR)");

    // Verify opc field (bits [30:29]) is 3 for ANDS
    assert(((encoding >> 29) & 3) == 3, "TST should have opc=3 (ANDS)");

    // Verify N bit (bit 21) is 0 for normal (not inverted)
    assert(!((encoding >> 21) & 1), "TST should have N=0");

    // Test 32-bit variant: tst w1, w2
    uint encoding_w = INSTR.log_shift(0, 3, 0, 0, 2, 0, 1, 31);
    assert(encoding_w != 0, "tst w1, w2 encoding failed");

    // 64-bit and 32-bit should differ
    assert(encoding != encoding_w, "TST 64-bit and 32-bit should differ");

    // Verify sf bit (bit 31)
    assert((encoding >> 31) & 1, "TST 64-bit should have sf=1");
    assert(!((encoding_w >> 31) & 1), "TST 32-bit should have sf=0");

    // Test with different registers
    uint enc2 = INSTR.log_shift(1, 3, 0, 0, 10, 0, 11, 31);
    assert(enc2 != encoding, "Different registers should produce different encodings");

    // Verify register fields
    assert((enc2 & 0x1F) == 31, "TST Rd should always be 31");
    assert(((enc2 >> 5) & 0x1F) == 11, "TST Rn field incorrect");
    assert(((enc2 >> 16) & 0x1F) == 10, "TST Rm field incorrect");
}

unittest
{
    // Test TST with shifts
    // tst x1, x2, lsl #3
    uint enc_lsl = INSTR.log_shift(1, 3, 0, 0, 2, 3, 1, 31);
    assert(enc_lsl != 0, "tst x1, x2, lsl #3 encoding failed");

    // Verify shift amount in bits [15:10]
    uint shift_amt = (enc_lsl >> 10) & 0x3F;
    assert(shift_amt == 3, "TST shift amount should be 3");

    // Verify shift type in bits [23:22]
    uint shift_type = (enc_lsl >> 22) & 3;
    assert(shift_type == 0, "LSL shift type should be 0");

    // Test different shift types
    uint enc_lsr = INSTR.log_shift(1, 3, 1, 0, 2, 4, 1, 31);  // LSR
    assert(((enc_lsr >> 22) & 3) == 1, "LSR shift type should be 1");

    uint enc_asr = INSTR.log_shift(1, 3, 2, 0, 2, 8, 1, 31);  // ASR
    assert(((enc_asr >> 22) & 3) == 2, "ASR shift type should be 2");

    uint enc_ror = INSTR.log_shift(1, 3, 3, 0, 2, 16, 1, 31);  // ROR
    assert(((enc_ror >> 22) & 3) == 3, "ROR shift type should be 3");

    // All four shift types should produce different encodings
    assert(enc_lsl != enc_lsr, "LSL and LSR should differ");
    assert(enc_lsl != enc_asr, "LSL and ASR should differ");
    assert(enc_lsl != enc_ror, "LSL and ROR should differ");
}

unittest
{
    // Test TST vs AND difference
    uint and_enc = INSTR.log_shift(1, 0, 0, 0, 2, 0, 1, 0);   // AND (opc=0)
    uint tst_enc = INSTR.log_shift(1, 3, 0, 0, 2, 0, 1, 31);  // TST (opc=3, Rd=31)

    assert(and_enc != tst_enc, "AND and TST should differ");

    // Verify opc field difference
    uint and_opc = (and_enc >> 29) & 3;
    uint tst_opc = (tst_enc >> 29) & 3;
    assert(and_opc == 0, "AND should have opc=0");
    assert(tst_opc == 3, "TST should have opc=3");

    // Verify Rd field difference
    assert((and_enc & 0x1F) == 0, "AND Rd should be 0");
    assert((tst_enc & 0x1F) == 31, "TST Rd should be 31");
}

unittest
{
    // Test Phase 4.2 instruction dispatch table entries
    assert(lookupInstruction("bic") !is null, "bic should be in dispatch table");
    assert(lookupInstruction("tst") !is null, "tst should be in dispatch table");

    // Case insensitivity
    assert(lookupInstruction("BIC") !is null, "BIC should be case-insensitive");
    assert(lookupInstruction("TST") !is null, "TST should be case-insensitive");
}

unittest
{
    // Test BIC with maximum shift amounts
    // 64-bit: maximum shift is 63
    uint enc_max64 = INSTR.log_shift(1, 0, 0, 1, 1, 63, 2, 0);
    assert(((enc_max64 >> 10) & 0x3F) == 63, "BIC 64-bit max shift incorrect");

    // 32-bit: maximum shift is 31
    uint enc_max32 = INSTR.log_shift(0, 0, 0, 1, 1, 31, 2, 0);
    assert(((enc_max32 >> 10) & 0x3F) == 31, "BIC 32-bit max shift incorrect");

    // Zero shift
    uint enc_zero = INSTR.log_shift(1, 0, 0, 1, 1, 0, 2, 0);
    assert(((enc_zero >> 10) & 0x3F) == 0, "BIC zero shift incorrect");
}

unittest
{
    // Test TST with maximum shift amounts
    // 64-bit: maximum shift is 63
    uint enc_max64 = INSTR.log_shift(1, 3, 0, 0, 1, 63, 2, 31);
    assert(((enc_max64 >> 10) & 0x3F) == 63, "TST 64-bit max shift incorrect");

    // 32-bit: maximum shift is 31
    uint enc_max32 = INSTR.log_shift(0, 3, 0, 0, 1, 31, 2, 31);
    assert(((enc_max32 >> 10) & 0x3F) == 31, "TST 32-bit max shift incorrect");

    // Zero shift
    uint enc_zero = INSTR.log_shift(1, 3, 0, 0, 1, 0, 2, 31);
    assert(((enc_zero >> 10) & 0x3F) == 0, "TST zero shift incorrect");
}

unittest
{
    // Test BIC/TST relationship with AND/ANDS
    // BIC = AND with N=1 (NOT)
    // TST = ANDS with Rd=31 (XZR)

    // Verify BIC is AND with NOT
    uint and_enc = INSTR.log_shift(1, 0, 0, 0, 2, 0, 1, 0);  // AND: opc=0, N=0
    uint bic_enc = INSTR.log_shift(1, 0, 0, 1, 2, 0, 1, 0);  // BIC: opc=0, N=1
    assert(((and_enc >> 21) & 1) == 0, "AND should have N=0");
    assert(((bic_enc >> 21) & 1) == 1, "BIC should have N=1");
    assert(((and_enc >> 29) & 3) == ((bic_enc >> 29) & 3), "AND and BIC should have same opc");

    // Verify TST is ANDS with Rd=31
    uint ands_enc = INSTR.log_shift(1, 3, 0, 0, 2, 0, 1, 0);  // ANDS: opc=3, Rd=0
    uint tst_enc = INSTR.log_shift(1, 3, 0, 0, 2, 0, 1, 31);  // TST: opc=3, Rd=31
    assert(((ands_enc >> 29) & 3) == 3, "ANDS should have opc=3");
    assert(((tst_enc >> 29) & 3) == 3, "TST should have opc=3");
    assert((ands_enc & 0x1F) == 0, "ANDS Rd should be 0");
    assert((tst_enc & 0x1F) == 31, "TST Rd should be 31");
}

unittest
{
    // Test all register combinations for BIC
    for (ubyte rd = 0; rd <= 10; rd++)
    {
        for (ubyte rn = 0; rn <= 10; rn++)
        {
            for (ubyte rm = 0; rm <= 10; rm++)
            {
                uint enc = INSTR.log_shift(1, 0, 0, 1, rm, 0, rn, rd);
                assert((enc & 0x1F) == rd, "BIC Rd encoding failed");
                assert(((enc >> 5) & 0x1F) == rn, "BIC Rn encoding failed");
                assert(((enc >> 16) & 0x1F) == rm, "BIC Rm encoding failed");
            }
        }
    }
}

unittest
{
    // Test all register combinations for TST (Rd is always 31)
    for (ubyte rn = 0; rn <= 10; rn++)
    {
        for (ubyte rm = 0; rm <= 10; rm++)
        {
            uint enc = INSTR.log_shift(1, 3, 0, 0, rm, 0, rn, 31);
            assert((enc & 0x1F) == 31, "TST Rd should always be 31");
            assert(((enc >> 5) & 0x1F) == rn, "TST Rn encoding failed");
            assert(((enc >> 16) & 0x1F) == rm, "TST Rm encoding failed");
        }
    }
}

unittest
{
    // Test BIC with all shift types and various amounts
    for (uint shift = 0; shift <= 3; shift++)
    {
        for (uint amt = 0; amt <= 15; amt++)
        {
            uint enc = INSTR.log_shift(1, 0, shift, 1, 1, amt, 2, 0);
            assert(((enc >> 22) & 3) == shift, "BIC shift type encoding failed");
            assert(((enc >> 10) & 0x3F) == amt, "BIC shift amount encoding failed");
        }
    }
}

unittest
{
    // Test TST with all shift types and various amounts
    for (uint shift = 0; shift <= 3; shift++)
    {
        for (uint amt = 0; amt <= 15; amt++)
        {
            uint enc = INSTR.log_shift(1, 3, shift, 0, 1, amt, 2, 31);
            assert(((enc >> 22) & 3) == shift, "TST shift type encoding failed");
            assert(((enc >> 10) & 0x3F) == amt, "TST shift amount encoding failed");
        }
    }
}
