/**
 * WASM binary encoding constants
 */

module dmd.backend.wasm;

enum : ubyte
{
    WASM_MAGIC_0 = 0x00,
    WASM_MAGIC_1 = 0x61, // 'a'
    WASM_MAGIC_2 = 0x73, // 's'
    WASM_MAGIC_3 = 0x6D, // 'm'

    WASM_VERSION_0 = 0x01,
    WASM_VERSION_1 = 0x00,
    WASM_VERSION_2 = 0x00,
    WASM_VERSION_3 = 0x00,
}

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

// Value types
enum : ubyte
{
    WASM_I32 = 0x7F,
    WASM_I64 = 0x7E,
    WASM_F32 = 0x7D,
    WASM_F64 = 0x7C,
    WASM_VOID = 0x40, // used in blocktype for void blocks
}

// Export kinds
enum : ubyte
{
    WASM_EXPORT_FUNC = 0x00,
    WASM_EXPORT_TABLE = 0x01,
    WASM_EXPORT_MEM = 0x02,
    WASM_EXPORT_GLOBAL = 0x03,
}

// Instructions
enum : ubyte
{
    WASM_UNREACHABLE = 0x00,
    WASM_END = 0x0B,
}

// WASM relocation types (WebAssembly tool conventions / linking metadata)
enum : ubyte
{
    R_WASM_FUNCTION_INDEX_LEB = 0, // function index in call (5-byte padded ULEB)
    R_WASM_TABLE_INDEX_SLEB = 1,
    R_WASM_TABLE_INDEX_I32 = 2,
    R_WASM_MEMORY_ADDR_LEB = 3,
    R_WASM_MEMORY_ADDR_SLEB = 4,
    R_WASM_MEMORY_ADDR_I32 = 5,
    R_WASM_TYPE_INDEX_LEB = 6,
    R_WASM_GLOBAL_INDEX_LEB = 7,
}

// "linking" custom section subsection IDs (version 2)
enum : ubyte
{
    WASM_LINKING_SEGMENT_INFO = 5,
    WASM_LINKING_INIT_FUNCS = 6,
    WASM_LINKING_COMDAT_INFO = 7,
    WASM_LINKING_SYMBOL_TABLE = 8,
}

// Symbol table entry kinds
enum : ubyte
{
    WASM_SYMTAB_FUNCTION = 0,
    WASM_SYMTAB_DATA = 1,
    WASM_SYMTAB_GLOBAL = 2,
    WASM_SYMTAB_SECTION = 3,
    WASM_SYMTAB_TAG = 4,
    WASM_SYMTAB_TABLE = 5,
}

// Symbol table flags
enum : uint
{
    WASM_SYM_BINDING_WEAK = 0x01,
    WASM_SYM_BINDING_LOCAL = 0x02,
    WASM_SYM_VISIBILITY_HIDDEN = 0x04,
    WASM_SYM_UNDEFINED = 0x10,
    WASM_SYM_EXPORTED = 0x40,
    WASM_SYM_EXPLICIT_NAME = 0x80,
    WASM_SYM_NO_STRIP = 0x100,
}
