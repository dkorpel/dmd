/**
 * WASM binary encoding constants
 */

module dmd.backend.wasm;

import dmd.common.outbuffer;

/// Emit a 5-byte padded ULEB128 (fixed-width, allowing linker relocation patching)
void writeuLEB128_5(ref OutBuffer buf, uint v) nothrow @safe
{
    buf.writeByte(cast(ubyte)((v & 0x7F) | 0x80));
    buf.writeByte(cast(ubyte)(((v >> 7) & 0x7F) | 0x80));
    buf.writeByte(cast(ubyte)(((v >> 14) & 0x7F) | 0x80));
    buf.writeByte(cast(ubyte)(((v >> 21) & 0x7F) | 0x80));
    buf.writeByte(cast(ubyte)((v >> 28) & 0x0F)); // MSB=0 to terminate
}

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
    // i64 arithmetic
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
enum WASM_TYPE : ubyte
{
    I32 = 0x7F,
    I64 = 0x7E,
    F32 = 0x7D,
    F64 = 0x7C,
}

enum WASM_I32 = WASM_TYPE.I32;
enum WASM_I64 = WASM_TYPE.I64;
enum WASM_F32 = WASM_TYPE.F32;
enum WASM_F64 = WASM_TYPE.F64;

/// Block type for void blocks
enum ubyte WASM_VOID_BLOCK = 0x40;

// Section IDs
enum WasmSection : ubyte
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
}

// Export kinds
enum WASM_EXPORT : ubyte
{
    FUNC = 0x00,
    TABLE = 0x01,
    MEM = 0x02,
    GLOBAL = 0x03,
}

// WASM relocation types (WebAssembly tool conventions / linking metadata)
enum R_WASM : ubyte
{
    FUNCTION_INDEX_LEB = 0, // function index in call (5-byte padded ULEB)
    TABLE_INDEX_SLEB = 1,
    TABLE_INDEX_I32 = 2,
    MEMORY_ADDR_LEB = 3,
    MEMORY_ADDR_SLEB = 4,
    MEMORY_ADDR_I32 = 5,
    TYPE_INDEX_LEB = 6,
    GLOBAL_INDEX_LEB = 7,
}

// "linking" custom section subsection IDs (version 2)
enum WASM_LINKING : ubyte
{
    SEGMENT_INFO = 5,
    INIT_FUNCS = 6,
    COMDAT_INFO = 7,
    SYMBOL_TABLE = 8,
}

// Symbol table entry kinds
enum WASM_SYMTAB : ubyte
{
    FUNCTION = 0,
    DATA = 1,
    GLOBAL = 2,
    SECTION = 3,
    TAG = 4,
    TABLE = 5,
}

// Symbol table flags
enum WASM_SYM : uint
{
    BINDING_WEAK = 0x01,
    BINDING_LOCAL = 0x02,
    VISIBILITY_HIDDEN = 0x04,
    UNDEFINED = 0x10,
    EXPORTED = 0x40,
    EXPLICIT_NAME = 0x80,
    NO_STRIP = 0x100,
}
