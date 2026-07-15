/**
 * WASM binary encoding constants
 */

module dmd.backend.wasm.enums;

alias WASM_OP = ubyte;

/// WASM instruction opcodes
enum : ubyte
{
    OP_UNREACHABLE = 0x00,
    OP_NOP = 0x01,
    OP_BLOCK = 0x02,
    OP_LOOP = 0x03,
    OP_IF = 0x04,
    OP_ELSE = 0x05,
    OP_THROW = 0x08,
    OP_THROW_REF = 0x0A,
    OP_TRY_TABLE = 0x1F,
    OP_END = 0x0B,
    OP_BR = 0x0C,
    OP_BR_IF = 0x0D,
    OP_BR_TABLE = 0x0E,
    OP_RETURN = 0x0F,
    OP_CALL = 0x10,
    OP_CALL_INDIRECT = 0x11,
    OP_RETURN_CALL = 0x12,
    OP_RETURN_CALL_INDIRECT = 0x13,
    OP_DROP = 0x1A,
    OP_SELECT = 0x1B,
    OP_LOCAL_GET = 0x20,
    OP_LOCAL_SET = 0x21,
    OP_LOCAL_TEE = 0x22,
    OP_GLOBAL_GET = 0x23,
    OP_GLOBAL_SET = 0x24,
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
    OP_MEMORY_SIZE = 0x3F,
    OP_MEMORY_GROW = 0x40,
    OP_I32_CONST = 0x41,
    OP_I64_CONST = 0x42,
    OP_F32_CONST = 0x43,
    OP_F64_CONST = 0x44,
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
    OP_I32_CLZ = 0x67,
    OP_I32_CTZ = 0x68,
    OP_I32_POPCNT = 0x69,
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
    OP_I64_CLZ = 0x79,
    OP_I64_CTZ = 0x7A,
    OP_I64_POPCNT = 0x7B,
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
    OP_I64_ROTL = 0x89,
    OP_I64_ROTR = 0x8A,
    OP_F32_ABS = 0x8B,
    OP_F32_NEG = 0x8C,
    OP_F32_SQRT = 0x91,
    OP_F32_ADD = 0x92,
    OP_F32_SUB = 0x93,
    OP_F32_MUL = 0x94,
    OP_F32_DIV = 0x95,
    OP_F64_ABS = 0x99,
    OP_F64_NEG = 0x9A,
    OP_F64_SQRT = 0x9F,
    OP_F64_ADD = 0xA0,
    OP_F64_SUB = 0xA1,
    OP_F64_MUL = 0xA2,
    OP_F64_DIV = 0xA3,
    OP_I32_WRAP_I64 = 0xA7,
    OP_I32_TRUNC_F32_S = 0xA8,
    OP_I32_TRUNC_F32_U = 0xA9,
    OP_I32_TRUNC_F64_S = 0xAA,
    OP_I32_TRUNC_F64_U = 0xAB,
    OP_I64_EXTEND_I32_S = 0xAC,
    OP_I64_EXTEND_I32_U = 0xAD,
    OP_I64_TRUNC_F32_S = 0xAE,
    OP_I64_TRUNC_F32_U = 0xAF,
    OP_I64_TRUNC_F64_S = 0xB0,
    OP_I64_TRUNC_F64_U = 0xB1,
    OP_F32_CONVERT_I32_S = 0xB2,
    OP_F32_CONVERT_I32_U = 0xB3,
    OP_F32_CONVERT_I64_S = 0xB4,
    OP_F32_CONVERT_I64_U = 0xB5,
    OP_F32_DEMOTE_F64 = 0xB6,
    OP_F64_CONVERT_I32_S = 0xB7,
    OP_F64_CONVERT_I32_U = 0xB8,
    OP_F64_CONVERT_I64_S = 0xB9,
    OP_F64_CONVERT_I64_U = 0xBA,
    OP_F64_PROMOTE_F32 = 0xBB,
    OP_I32_REINTERPRET_F32 = 0xBC,
    OP_I64_REINTERPRET_F64 = 0xBD,
    OP_F32_REINTERPRET_I32 = 0xBE,
    OP_F64_REINTERPRET_I64 = 0xBF,
    OP_FC_PREFIX = 0xFC,
    OP_I32_EXTEND8_S = 0xC0,
    OP_I32_EXTEND16_S = 0xC1,
    OP_I64_EXTEND8_S = 0xC2,
    OP_I64_EXTEND16_S = 0xC3,
    OP_I64_EXTEND32_S = 0xC4,
    OP_FD_PREFIX = 0xFD,
}

/// Sub-opcodes following the `0xFD` SIMD prefix (uLEB128-encoded)
enum WASM_SIMD : uint
{
    V128_LOAD = 0x00,
    V128_STORE = 0x0B,
    V128_CONST = 0x0C,

    I8X16_SPLAT = 0x0F,
    I16X8_SPLAT = 0x10,
    I32X4_SPLAT = 0x11,
    I64X2_SPLAT = 0x12,
    F32X4_SPLAT = 0x13,
    F64X2_SPLAT = 0x14,

    I8X16_EQ = 0x23,
    I8X16_NE = 0x24,
    I8X16_LT_S = 0x25,
    I8X16_LT_U = 0x26,
    I8X16_GT_S = 0x27,
    I8X16_GT_U = 0x28,
    I8X16_LE_S = 0x29,
    I8X16_LE_U = 0x2A,
    I8X16_GE_S = 0x2B,
    I8X16_GE_U = 0x2C,

    I16X8_EQ = 0x2D,
    I16X8_NE = 0x2E,
    I16X8_LT_S = 0x2F,
    I16X8_LT_U = 0x30,
    I16X8_GT_S = 0x31,
    I16X8_GT_U = 0x32,
    I16X8_LE_S = 0x33,
    I16X8_LE_U = 0x34,
    I16X8_GE_S = 0x35,
    I16X8_GE_U = 0x36,

    I32X4_EQ = 0x37,
    I32X4_NE = 0x38,
    I32X4_LT_S = 0x39,
    I32X4_LT_U = 0x3A,
    I32X4_GT_S = 0x3B,
    I32X4_GT_U = 0x3C,
    I32X4_LE_S = 0x3D,
    I32X4_LE_U = 0x3E,
    I32X4_GE_S = 0x3F,
    I32X4_GE_U = 0x40,

    F32X4_EQ = 0x41,
    F32X4_NE = 0x42,
    F32X4_LT = 0x43,
    F32X4_GT = 0x44,
    F32X4_LE = 0x45,
    F32X4_GE = 0x46,

    F64X2_EQ = 0x47,
    F64X2_NE = 0x48,
    F64X2_LT = 0x49,
    F64X2_GT = 0x4A,
    F64X2_LE = 0x4B,
    F64X2_GE = 0x4C,

    V128_NOT = 0x4D,
    V128_AND = 0x4E,
    V128_OR = 0x50,
    V128_XOR = 0x51,

    I8X16_NEG = 0x61,
    I8X16_SHL = 0x6B,
    I8X16_SHR_S = 0x6C,
    I8X16_SHR_U = 0x6D,
    I8X16_ADD = 0x6E,
    I8X16_SUB = 0x71,

    I16X8_NEG = 0x81,
    I16X8_SHL = 0x8B,
    I16X8_SHR_S = 0x8C,
    I16X8_SHR_U = 0x8D,
    I16X8_ADD = 0x8E,
    I16X8_SUB = 0x91,
    I16X8_MUL = 0x95,

    I32X4_NEG = 0xA1,
    I32X4_SHL = 0xAB,
    I32X4_SHR_S = 0xAC,
    I32X4_SHR_U = 0xAD,
    I32X4_ADD = 0xAE,
    I32X4_SUB = 0xB1,
    I32X4_MUL = 0xB5,

    I64X2_NEG = 0xC1,
    I64X2_SHL = 0xCB,
    I64X2_SHR_S = 0xCC,
    I64X2_SHR_U = 0xCD,
    I64X2_ADD = 0xCE,
    I64X2_SUB = 0xD1,
    I64X2_MUL = 0xD5,
    I64X2_EQ = 0xD6,
    I64X2_NE = 0xD7,
    I64X2_LT_S = 0xD8,
    I64X2_GT_S = 0xD9,
    I64X2_LE_S = 0xDA,
    I64X2_GE_S = 0xDB,

    F32X4_NEG = 0xE1,
    F32X4_ADD = 0xE4,
    F32X4_SUB = 0xE5,
    F32X4_MUL = 0xE6,
    F32X4_DIV = 0xE7,

    F64X2_NEG = 0xED,
    F64X2_ADD = 0xF0,
    F64X2_SUB = 0xF1,
    F64X2_MUL = 0xF2,
    F64X2_DIV = 0xF3,
}

/// Sub-opcodes following the `0xFC` prefix.
/// Should be uLEB128-encoded unlike regular opcodes which are 1 byte
enum WASM_FC : uint
{
    I32_TRUNC_SAT_F32_S = 0,
    I32_TRUNC_SAT_F32_U = 1,
    I32_TRUNC_SAT_F64_S = 2,
    I32_TRUNC_SAT_F64_U = 3,
    I64_TRUNC_SAT_F32_S = 4,
    I64_TRUNC_SAT_F32_U = 5,
    I64_TRUNC_SAT_F64_S = 6,
    I64_TRUNC_SAT_F64_U = 7,

    MEMORY_COPY = 10,
    MEMORY_FILL = 11,
}

/// Value type bytes
enum WASM_TYPE : ubyte
{
    I32 = 0x7F,
    I64 = 0x7E,
    F32 = 0x7D,
    F64 = 0x7C,
    V128 = 0x7B,
    // Reference to an in-flight exception. Pushed by a `try_table`'s `catch_all_ref`
    // clause when unwinding into a `finally` (blocks.d openTryFrames), stashed in a
    // local (codgen.d exnLocalFor) across the finally body, then rethrown with
    // `throw_ref` (codgen.d OP_THROW_REF).
    EXNREF = 0x69,
}

/// Catch clause kind bytes inside a `try_table` instruction
enum WASM_CATCH : ubyte
{
    CATCH = 0x00,
    CATCH_REF = 0x01,
    CATCH_ALL = 0x02,
    CATCH_ALL_REF = 0x03,
}

enum WASM_I32 = WASM_TYPE.I32;
enum WASM_I64 = WASM_TYPE.I64;
enum WASM_F32 = WASM_TYPE.F32;
enum WASM_F64 = WASM_TYPE.F64;

enum ubyte WASM_VOID_BLOCK = 0x40;

/// Section IDs
enum WASM_SECTION : ubyte
{
    custom = 0,
    type_ = 1,
    import_ = 2,
    function_ = 3,
    table = 4,
    memory = 5,
    global = 6,
    export_ = 7,
    start = 8,
    element = 9,
    code = 10,
    data = 11,
    tag = 13,
}

/// Reference type bytes (used in element type fields, e.g. table imports)
enum WASM_REFTYPE : ubyte
{
    FUNCREF = 0x70,
    EXTERNREF = 0x6F,
}

/// Limits flags byte (used in memory and table types)
enum WASM_LIMITS : ubyte
{
    NO_MAX = 0x00,
    HAS_MAX = 0x01,
}

/// Mutability flag byte (used in global types)
enum WASM_MUT : ubyte
{
    CONST = 0x00,
    VAR = 0x01,
}

/// Import/export descriptor kinds. Same byte encoding for both
/// `importdesc` and `exportdesc` per the WASM core spec.
enum WASM_EXPORT : ubyte
{
    FUNC = 0x00,
    TABLE = 0x01,
    MEM = 0x02,
    GLOBAL = 0x03,
}

/// WASM relocation types (WebAssembly tool conventions / linking metadata)
enum R_WASM : ubyte
{
    FUNCTION_INDEX_LEB = 0,
    TABLE_INDEX_SLEB = 1,
    TABLE_INDEX_I32 = 2,
    MEMORY_ADDR_LEB = 3,
    MEMORY_ADDR_SLEB = 4,
    MEMORY_ADDR_I32 = 5,
    TYPE_INDEX_LEB = 6,
    GLOBAL_INDEX_LEB = 7,
    TAG_INDEX_LEB = 10,
    TABLE_NUMBER_LEB = 20,
}

/// "linking" custom section subsection IDs (version 2)
enum WASM_LINKING : ubyte
{
    SEGMENT_INFO = 5,
    INIT_FUNCS = 6,
    COMDAT_INFO = 7,
    SYMBOL_TABLE = 8,
}

/// SEGMENT_INFO per-segment flags (linking metadata)
enum WASM_SEG : uint
{
    STRINGS = 0x01,
    TLS = 0x02,
    RETAIN = 0x04, // keep under --gc-sections even without a reference
}

/// Symbol table entry kinds
enum WASM_SYMTAB : ubyte
{
    FUNCTION = 0,
    DATA = 1,
    GLOBAL = 2,
    SECTION = 3,
    TAG = 4,
    TABLE = 5,
}

/// Symbol table flags
enum WASM_SYM : uint
{
    BINDING_WEAK = 0x01,
    BINDING_LOCAL = 0x02,
    VISIBILITY_HIDDEN = 0x04,
    UNDEFINED = 0x10,
    EXPORTED = 0x20,      // force wasm-ld to export the symbol without --export-dynamic
    EXPLICIT_NAME = 0x40,
    NO_STRIP = 0x80,      // retain even without a reference (no --gc-sections stripping)
    TLS = 0x100,
}
