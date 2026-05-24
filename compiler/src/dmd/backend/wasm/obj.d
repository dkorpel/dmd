/**
 * WebAssembly binary module writer.
 *
 * Implements the Obj interface for the WebAssembly binary format.
 * Produces a valid .wasm file containing type, function, export, memory,
 * and data sections.  Function bodies are stubs (unreachable) until a
 * dedicated WASM code-generator is hooked in.
 *
 * Spec: https://webassembly.github.io/spec/core/binary/index.html
 *
 * Copyright:   Copyright (C) 1999-2026 by The D Language Foundation, All Rights Reserved
 * License:     $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/compiler/src/dmd/backend/wasm/obj.d, _obj.d)
 */

module dmd.backend.wasm.obj;

import std.stdio;
import std.string;

import dmd.backend.cc;
import dmd.backend.cdef;
import dmd.backend.code;
import dmd.backend.debugprint;
import dmd.backend.el;
import dmd.backend.obj;
import dmd.backend.ty;
import dmd.backend.type;
import dmd.backend.wasm.codgen;
import dmd.backend.wasm.enums;
import dmd.backend.wasm.util : ulebSize, writeuLEB128_5;
import dmd.common.outbuffer;

// Segment indices used by the backend (must match dmd/backend/cdef.d Segments enum values like DATA and UDATA)
private enum : int
{
    // WASM_CODE = 1,
    WASM_DATA = 2,
    // WASM_CDATA = 3,
    WASM_UDATA = 4
}

// Allocate a seg_data entry in SegData at the given index
private void pushSegData(int idx) nothrow
{
    import dmd.backend.barray : Rarray;

    while (SegData.length <= idx)
    {
        seg_data** p = SegData.push();
        *p = new seg_data();
        (*p).SDseg = cast(int)(SegData.length - 1);
        (*p).SDbuf = new OutBuffer();
    }
}

nothrow:

// Append a name string (length-prefixed)
private void appendName(ref OutBuffer buf, const(char)[] name)
{
    buf.writeuLEB128(cast(uint) name.length);
    buf.write(name.ptr[0 .. name.length]);
}

// Name of a WasmFunc as it appears in the wasm symbol table.
private const(char)[] funcName(ref const WasmFunc f)
{
    if (f.sym)
        return f.sym.identifier;
    return f.importName;
}

// Index of the func that "owns" the symbol-table entry for the given name:
// the first defined func with that name, else the first import with that name.
// Used to merge duplicate symbol-table entries that would otherwise conflict
// for wasm-ld (e.g. import+defined twin, or several modules each defining the
// same extern(C) symbol — drop subsequent copies from the symbol table).
private uint canonicalFuncForName(size_t i)
{
    const(char)[] name = funcName(wmod.funcs[i]);
    if (!name.length)
        return cast(uint) i;
    uint firstDefined = uint.max;
    uint firstImport = uint.max;
    foreach (size_t j, ref const WasmFunc g; wmod.funcs)
    {
        if (funcName(g) != name)
            continue;
        if (g.isImport)
        {
            if (firstImport == uint.max)
                firstImport = cast(uint) j;
        }
        else
        {
            if (firstDefined == uint.max)
                firstDefined = cast(uint) j;
        }
    }
    if (firstDefined != uint.max)
        return firstDefined;
    return firstImport;
}

// True if func i should be omitted from the symbol table because another
// func owns the canonical entry for its name.
private bool isShadowedFunc(size_t i)
{
    return canonicalFuncForName(i) != i;
}

// Write a custom section: section id 0, size, name, then payload bytes
// Build mapping: function index -> linking-section symbol index.
// Functions without a name get uint.max (excluded from the symbol table).
// Shadowed imports (same name as a defined func) alias to the defined sym idx
// so we never emit two symbol-table entries with the same name.
private uint[] buildFuncToSymIdx()
{
    uint[] funcToSymIdx;
    funcToSymIdx.length = wmod.funcs.length;
    enum uint SHADOWED = uint.max - 1;
    uint si = 0;
    foreach (size_t i, ref const WasmFunc f; wmod.funcs)
    {
        const(char)[] name = funcName(f);
        if (!name.length)
        {
            funcToSymIdx[i] = uint.max;
            continue;
        }
        if (isShadowedFunc(i))
        {
            funcToSymIdx[i] = SHADOWED;
            continue;
        }
        funcToSymIdx[i] = si++;
    }
    // Resolve shadowed funcs to the canonical func's sym index.
    foreach (size_t i; 0 .. wmod.funcs.length)
    {
        if (funcToSymIdx[i] != SHADOWED)
            continue;
        funcToSymIdx[i] = funcToSymIdx[canonicalFuncForName(i)];
    }
    return funcToSymIdx;
}

private void writeCustomSection(ref OutBuffer out_, const(char)[] name, OutBuffer* payload)
{
    OutBuffer header;
    appendName(header, name);
    out_.writeByte(0); // custom section id
    out_.writeuLEB128(cast(uint)(header.length() + payload.length()));
    out_.write(header.peekSlice());
    out_.write(payload.peekSlice());
}

/// WASM function type
struct WasmFuncType
{
    WASM_TYPE[] params; // value types of parameters
    WASM_TYPE[] results; // value types of return values (usually 0 or 1 unless the 'multiple values' extension is implemented)
}

// Recorded function definition
struct WasmFunc
{
    uint typeIdx; // index into typeSection; uint.max until pendingType is interned
    WasmFuncType pendingType; // signature of a defined function awaiting interning (after phase 1)
    Symbol* sym; // the D symbol
    bool exported;
    bool isImport;
    const(char)[] importModule; // for imports: module name
    const(char)[] importName; // for imports: field name
    // string name; // for synthesized functions with no Symbol and no importName
}

// Local variable in a WASM function
struct WasmLocal
{
    Symbol* sym; // null for anonymous temporaries
    WASM_TYPE ty; // WASM value type

    this(WASM_TYPE type) nothrow
    {
        this.ty = type;
    }

    this(Symbol* sym) nothrow
    {
        this.sym = sym;
        this.ty = tybasic(sym.ty).wasmType;
    }
}

// Generated code body for a defined function
struct WasmFuncBody
{
    Symbol* sym;
    string name; // for synthesized functions with no Symbol
    WasmLocal[] locals;
    uint numParams;
    OutBuffer code; // WASM bytecode (without local decls header)
    Symbol*[] savedGlobsym; // globsym snapshot at func_term time

    // Code relocations recorded during code generation.
    // offset is relative to the start of `code` (i.e. before the END byte).
    // Set by emitCodeSection: byte offset from code section payload start
    // where this function's code bytes begin (used for reloc.CODE offsets).
    struct CodeReloc
    {
        uint offset; // byte offset within code buffer (before the 5-byte ULEB)
        ubyte type; // R_WASM.FUNCTION_INDEX_LEB, R_WASM.TYPE_INDEX_LEB, etc.
        uint symIdx; // funcIdx snapshot at emit time (resolved via funcToSymIdx, or via sym at term time)
        uint addend; // for R_WASM.MEMORY_ADDR_LEB: offset within the segment
        Symbol* sym; // preferred: Symbol* whose current funcIdx is looked up at term time
        // (decouples from wmod.funcs reordering during late codegen)
    }

    // Data-address code relocations: R_WASM.MEMORY_ADDR_LEB entries.
    // sym is the D Symbol whose data segment is referenced; addend is the
    // byte offset from sym.Soffset (usually e.Voffset).
    struct DataAddrReloc
    {
        uint offset; // byte offset within code buffer
        Symbol* sym; // the data symbol
        uint addend; // extra offset beyond sym.Soffset
    }

    CodeReloc[] codeRelocs;
    DataAddrReloc[] dataAddrRelocs;
    uint codePayloadStart; // set by emitCodeSection
}

// Module-global table of function bodies (indexed same as WasmFunc)
__gshared WasmFuncBody[] wasmFuncBodies;

// Data segment (initialized global data). One per data symbol in the
// LDC-style layout: each named D symbol (and each rodata literal) gets its
// own WASM data segment, which lets wasm-ld dead-strip and reorder them.
struct WasmDataSeg
{
    uint offset;          // linear memory offset of first byte
    OutBuffer data;       // raw bytes
    Symbol* sym;          // owning data symbol (null for anonymous rodata)
    const(char)[] name;   // segment name for SEGMENT_INFO ("" => synthesise)
    uint alignLog2 = 2;   // log2(alignment) for SEGMENT_INFO
}

// WASM mutable global (used for __stack_pointer)
struct WasmGlobal
{
    ubyte valType; // e.g. WASM_I32
    bool mutable_;
    long initVal; // constant initializer (interpreted as i32 or i64)
}

// ---------------------------------------------------------------------------
// Module state
// ---------------------------------------------------------------------------

struct WasmModule
{
    OutBuffer* objbuf; // the output buffer (owned by caller)

    // Collected entries
    WasmFuncType[] funcTypes; // de-duplicated type table
    WasmFunc[] funcs; // all functions (imports first, then defined)
    uint numImports; // number of import functions
    WasmDataSeg[] dataSegs; // data segments (one per data symbol)
    int activeSegIdx = -1;  // index into dataSegs of segment being filled, or -1

    // dataSegs can grow (via data_start / allocRoData), invalidating any stored
    // WasmDataSeg* — always go through this accessor so the pointer is recomputed.
    @property WasmDataSeg* activeSeg() nothrow return
    {
        if (activeSegIdx < 0 || activeSegIdx >= cast(int) dataSegs.length)
            return null;
        return &dataSegs[activeSegIdx];
    }

    uint memoryPageCount; // number of 64 KiB memory pages
    bool needsMemory; // true if any data segments or shadow stack exist
    uint dataHeap = 4; // next free byte offset in linear memory; starts at 4 to reserve address 0 as null

    WasmGlobal[] globals; // module-level mutable globals
    int stackPtrGlobalIdx = -1; // index of __stack_pointer global (-1 = not created)
    bool importStackPtrGlobal; // true: import __stack_pointer from "env" instead of defining it
    bool importFuncTable; // true: import __indirect_function_table from "env"
    uint[] elemFuncRelocOffsets; // payload offsets of function indices in the element section
    bool relocatable; // true: emit linking/reloc sections (for -c / wasm-ld use)

    // Deferred relocations in data segments. Written as 0 at emit time;
    // patched in WasmObj_term once all symbol addresses are known.
    struct FuncReloc
    {
        uint segIdx;          // which dataSegs entry this offset is within
        uint dataByteOffset;  // byte offset inside that segment's data
        Symbol* sym;
    }

    struct DataReloc
    {
        uint segIdx;
        uint dataByteOffset;
        Symbol* sym;
        uint addend;
    }

    FuncReloc[] funcRelocations;
    DataReloc[] dataRelocations;

    // Scratch OutBuffer for section payloads
    OutBuffer scratch;

nothrow:

    // Intern the pending type of every defined function. Called after phase 1
    // has registered all imports, so imports occupy type indices 0..numImports-1
    // and defined-function types get appended in registration order. This matches
    // what wasm-ld produces, so call_indirect type indices stay stable across
    // single-file linking.
    void internPendingTypes() nothrow
    {
        foreach (ref WasmFunc f; funcs)
        {
            if (f.typeIdx == uint.max)
                f.typeIdx = internType(f.pendingType);
        }
    }

    // Return or create a type index for the given func type
    uint internType(const WasmFuncType ft)
    {
        foreach (size_t i, ref const WasmFuncType e; funcTypes)
        {
            if (e.params == ft.params && e.results == ft.results)
                return cast(uint) i;
        }
        funcTypes ~= WasmFuncType(ft.params.dup, ft.results.dup);
        return cast(uint)(funcTypes.length - 1);
    }
}

/// Global module instance (one per compilation unit)
private WasmModule* wmod;

// Set by the DMD frontend: true when -c is given (produce relocatable object
// for wasm-ld), false when producing a self-contained final module directly.
__gshared bool wasm_relocatable = true; // default: relocatable (for -c)

/// Maps mangled function name to WebAssembly import module name.
private __gshared const(char)[][string] g_importModuleTable;

/**
 * Register a WebAssembly import module name for the given mangled function name.
 * Called from the frontend glue for @wasmImportModule("moduleName").
 */
void WasmObj_registerImportModule(const(char)[] mangledName, const(char)[] moduleName) nothrow
{
    g_importModuleTable[cast(string) mangledName] = moduleName;
}


// TYdarray and TYdelegate alias TYullong/TYllong on wasm32, so the Tty enum
// can't distinguish them from a plain ulong/long. Real slices and delegates
// are allocated via type_dyn_array/type_delegate, which set Tnext; the
// integer types do not. Use that to disambiguate.
public bool isSliceOrDelegate(type* t) @trusted nothrow
{
    if (!t || t.Tnext is null)
        return false;
    const tym_t tb = tybasic(t.Tty);
    return tb == TYdarray || tb == TYdelegate;
}

///: Returns true if the backend type is an aggregate (struct/array) that must be
/// returned via a hidden pointer parameter in the WASM calling convention.
//
// Note: slices and delegates are NOT returned via hidden pointer at the WASM
// level — they continue to be returned as a packed i64 (length<<32 | ptr).
// The front-end builds them as OPpair-to-i64 and we keep that representation
// at the ABI boundary. Adding sret for slice/delegate returns is a larger
// refactor (see slice_abi_refactor_plan.md).
bool returnByPtr(type* t)
{
    auto tb = tybasic(t.Tty);
    if (tb == TYdarray || tb == TYdelegate)
    {
        // return true;
    }

    switch (tb)
    {
    case TYstruct:
    case TYarray:
        return true;
    default:
        return false;
    }
}

WasmFuncType buildFuncType(elem* e)
{
    WASM_TYPE[] callParams;
    void collect(elem* p)
    {
        if (!p)
            return;
        if (p.Eoper == OPparam)
        {
            collect(p.E2);
            collect(p.E1);
            return;
        }
        callParams ~= wasmType(tybasic(p.Ety));
    }

    collect(e);
    WASM_TYPE[] callResults;
    const tym_t retTy0 = tybasic(e.Ety);
    if (typeHasValue(retTy0))
        callResults ~= wasmType(retTy0);
    return WasmFuncType(callParams, callResults);
}

/// Build a WasmFuncType from a backend function type.
/// Aggregates are passed/returned by pointer; aggregate return adds a hidden i32 first.
/// Slices and delegates are split into 2 params.
/// `sfunc` may be null for indirect calls — Fmember/Fnested fixups are skipped.
public WasmFuncType buildFuncType(type* t, Symbol* sfunc)
{
    WasmFuncType ft;

    if (sfunc)
    {
        // D allows `void main()`, but druntime calls _Dmain through a fixed
        // `extern(C) int function(char[][])` pointer.  Force _Dmain to that
        // signature regardless of the user-written declaration.
        if (sfunc.identifier == "_Dmain")
        {
            enum WASM_PTR = WASM_I32; // assumes 32-bit
            return WasmFuncType([WASM_I32, WASM_PTR], [WASM_I32]);
        }
        // For `main`, the WASI _start shim calls it as `(i32, i32) -> i32`.
        // Pad user-written `int main()` or `int main(int)` to the runtime ABI
        // so wasm-ld doesn't warn.  Non-standard signatures (e.g. void main
        // with 3 args) are left alone — those users won't be linking with
        // the default WASI shim anyway.
        if (sfunc.identifier == "main")
        {
            int paramCount = 0;
            bool allI32 = true;
            for (param_t* p = t.Tparamtypes; p; p = p.Pnext)
            {
                if (!p.Ptype || !typeHasValue(p.Ptype.Tty))
                    continue;
                paramCount++;
                const tym_t pty = tybasic(p.Ptype.Tty);
                if (isSliceOrDelegate(p.Ptype) || pty == TYstruct || pty == TYarray)
                {
                    allI32 = false;
                    break;
                }
                if (wasmType(pty) != WASM_I32)
                {
                    allI32 = false;
                    break;
                }
            }
            const type* retM = t.Tnext;
            const bool retOK = retM && (tybasic(retM.Tty) == TYvoid ||
                                        (typeHasValue(retM.Tty) && wasmType(retM.Tty) == WASM_I32));
            if (allI32 && paramCount <= 2 && retOK)
                return WasmFuncType([WASM_I32, WASM_I32], [WASM_I32]);
        }
    }

    // Check for aggregate return: requires a hidden pointer as the first parameter.
    type* ret = t.Tnext;
    const bool hiddenPtr = returnByPtr(ret);
    if (hiddenPtr)
        ft.params ~= WASM_I32; // hidden return pointer (first param)

    // D member functions (Fmember) receive 'this' as an implicit first parameter.
    // D nested functions (Fnested) receive a static-link/closure pointer.
    // Neither is in Tparamtypes, so prepend an i32.
    // (TODO: what order are hidden ret and this ptr passed? doesn't matter here, but still...)
    if (sfunc && sfunc.Sfunc && (sfunc.Sfunc.Fflags3 & (Fmember | Fnested)))
        ft.params ~= WASM_I32;

    const tym_t fty = tybasic(t.Tty);

    for (param_t* p = t.Tparamtypes; p; p = p.Pnext)
    {
        if (!p.Ptype || !typeHasValue(p.Ptype.Tty))
            continue;

        const tym_t pty = tybasic(p.Ptype.Tty);

        // Split into two i32 WASM params: (size_t len, T* ptr).
        // TYdarray/TYdelegate alias TYullong/TYllong on wasm32 — distinguish
        // a real slice/delegate (Tnext != null) from a plain ulong/long.
        if (isSliceOrDelegate(p.Ptype))
        {
            ft.params ~= WASM_I32;
            ft.params ~= WASM_I32;
        }
        else if (pty == TYstruct || pty == TYarray)
        {
            // Pass aggregates by hidden pointer.
            ft.params ~= WASM_I32;
        }
        else
        {
            ft.params ~= wasmType(pty);
        }
    }

    // C variadic (`...`): append a trailing i32 varargs-pointer parameter.
    // Matches the LDC2/wasi-libc ABI: caller spills variadic args to the shadow
    // stack and passes a pointer to that region as the last function parameter.
    if (variadic(t))
        ft.params ~= WASM_I32;

    // Return type (void and noreturn both produce no WASM result)
    if (hiddenPtr)
        ft.results ~= WASM_I32; // returns hidden ptr
    else if (ret && typeHasValue(ret.Tty))
        ft.results ~= wasmType(ret.Tty);

    return ft;
}

private void writeSection(ref OutBuffer out_, WASM_SECTION id, OutBuffer* payload)
{
    out_.writeByte(cast(ubyte) id);
    out_.writeuLEB128(cast(uint) payload.length());
    out_.write(payload.peekSlice());
}

private bool emitTypeSection(ref OutBuffer out_, ref WasmModule wmod)
{
    OutBuffer* s = &wmod.scratch;
    s.reset();
    s.writeuLEB128(cast(uint) wmod.funcTypes.length);
    foreach (ref const WasmFuncType ft; wmod.funcTypes)
    {
        s.writeByte(0x60); // func type indicator
        s.writeuLEB128(cast(uint) ft.params.length);
        foreach (ubyte v; ft.params)
            s.writeByte(v);
        s.writeuLEB128(cast(uint) ft.results.length);
        foreach (ubyte v; ft.results)
            s.writeByte(v);
    }
    if (wmod.funcTypes.length == 0)
        return false;

    writeSection(out_, WASM_SECTION.type_, s);
    return true;
}

// Write the `import` prefix common to every import entry: module name,
// field name, and the descriptor kind byte. Caller appends the kind-specific
// type descriptor that follows.
private void appendImportHead(ref OutBuffer s, const(char)[] mod, const(char)[] name, WASM_EXPORT kind)
{
    appendName(s, mod);
    appendName(s, name);
    s.writeByte(kind);
}

/// Returns: true if section was actually written
private bool emitImportSection(ref OutBuffer out_, ref WasmModule wmod)
{
    const count = wmod.numImports
        + (wmod.importFuncTable ? 1 : 0)
        + (wmod.importStackPtrGlobal ? 1 : 0)
        + (wmod.relocatable ? 1 : 0);
    if (!count)
        return false;
    OutBuffer* s = &wmod.scratch;
    s.reset();
    s.writeuLEB128(count);
    foreach (ref const WasmFunc f; wmod.funcs[0 .. wmod.numImports])
    {
        appendImportHead(*s, f.importModule, f.importName, WASM_EXPORT.FUNC);
        s.writeuLEB128(f.typeIdx);
    }
    if (wmod.relocatable)
    {
        // (import "env" "__linear_memory" (memory 0))
        // Relocatable objects import memory from the linker (wasm-ld); the
        // linker provides the actual memory definition and export.
        appendImportHead(*s, "env", "__linear_memory", WASM_EXPORT.MEM);
        s.writeByte(WASM_LIMITS.NO_MAX);
        s.writeuLEB128(0); // min pages = 0 (linker sets actual size)
    }
    if (wmod.importStackPtrGlobal)
    {
        // (import "env" "__stack_pointer" (global (mut i32)))
        // wasm-ld synthesises this global with the proper initial value
        // (top of the linked stack region) and shares it across objects.
        appendImportHead(*s, "env", "__stack_pointer", WASM_EXPORT.GLOBAL);
        s.writeByte(WASM_I32);
        s.writeByte(WASM_MUT.VAR);
    }
    if (wmod.importFuncTable)
    {
        // (import "env" "__indirect_function_table" (table 0 funcref))
        appendImportHead(*s, "env", "__indirect_function_table", WASM_EXPORT.TABLE);
        s.writeByte(WASM_REFTYPE.FUNCREF);
        s.writeByte(WASM_LIMITS.NO_MAX);
        s.writeuLEB128(0); // min size = 0 (linker sets actual size)
    }
    writeSection(out_, WASM_SECTION.import_, s);
    return true;
}

/// Returns: true if section was actually written
private bool emitFunctionSection(ref OutBuffer out_, ref WasmModule wmod)
{
    const defined = cast(uint)(wmod.funcs.length - wmod.numImports);
    if (!defined)
        return false;
    OutBuffer* s = &wmod.scratch;
    s.reset();
    s.writeuLEB128(defined);
    foreach (ref const WasmFunc f; wmod.funcs[wmod.numImports .. $])
        s.writeuLEB128(f.typeIdx);
    writeSection(out_, WASM_SECTION.function_, s);
    return true;
}

// Emit a table section with one funcref table sized to hold all defined functions.
// Skipped when the table is imported as __indirect_function_table.
private bool emitTableSection(ref OutBuffer out_, ref WasmModule wmod)
{
    if (wmod.importFuncTable)
        return false; // table is imported, not defined here
    const defined = cast(uint)(wmod.funcs.length - wmod.numImports);
    if (!defined)
        return false;
    OutBuffer* s = &wmod.scratch;
    s.reset();
    s.writeuLEB128(1); // 1 table
    s.writeByte(WASM_REFTYPE.FUNCREF);
    s.writeByte(WASM_LIMITS.HAS_MAX);
    s.writeuLEB128(defined); // min = number of defined functions
    s.writeuLEB128(defined); // max = same
    writeSection(out_, WASM_SECTION.table, s);
    return true;
}

// Emit an element section populating table[0] with all defined function indices.
// Uses 5-byte padded ULEB128 for each function index to support R_WASM.FUNCTION_INDEX_LEB
// relocations (stored in the "reloc.ELEM" section so wasm-ld can patch them).
// After writing, elemFuncRelocOffsets contains the reloc payload offsets of each entry.
private bool emitElementSection(ref OutBuffer out_, ref WasmModule wmod)
{
    uint defined = cast(uint)(wmod.funcs.length - wmod.numImports);
    if (!defined)
        return false;
    OutBuffer* s = &wmod.scratch;
    s.reset();
    s.writeuLEB128(1); // 1 element segment
    // Segment payload:
    s.writeByte(0x00); // kind: active, table 0, funcref, offset init-expr, funcidx vec
    s.writeByte(OP_I32_CONST);
    s.writeByte(0x00); // offset = 0
    s.writeByte(OP_END);
    s.writeuLEB128(defined); // count of function indices
    // Byte offset from start of element section PAYLOAD (after section id + size bytes).
    // Payload starts with: [count=1 ULEB] + [kind=0] + [0x41]+[0x00]+[0x0B] + [defined ULEB]
    // = 1 + 1 + 3 + 1 = 6 bytes before the first function index.
    uint entryOffset = 1 + 1 + 3 + ulebSize(defined);
    wmod.elemFuncRelocOffsets.length = 0;
    wmod.elemFuncRelocOffsets.reserve(defined);
    foreach (size_t i; wmod.numImports .. wmod.funcs.length)
    {
        uint fidx = cast(uint) i;
        wmod.elemFuncRelocOffsets ~= entryOffset; // offset of this 5-byte entry
        (*s).writeuLEB128_5(fidx); // 5-byte padded ULEB for linker relocation patching
        entryOffset += 5;
    }
    writeSection(out_, WASM_SECTION.element, s);
    return true;
}

/// Returns: true if section was actually written
private bool emitMemorySection(ref OutBuffer out_, ref WasmModule wmod)
{
    // In relocatable mode memory is imported from env (see emitImportSection),
    // so the linker provides the definition — don't declare one here.
    if (wmod.relocatable)
        return false;
    // Always declare one page of linear memory — any function using pointers
    // or array indexing needs it, and it's harmless when unused.
    OutBuffer* s = &wmod.scratch;
    s.reset();
    s.writeuLEB128(1); // one memory
    s.writeByte(WASM_LIMITS.NO_MAX);
    s.writeuLEB128(wmod.memoryPageCount ? wmod.memoryPageCount : 1);
    writeSection(out_, WASM_SECTION.memory, s);
    return true;
}

/// Returns: true if section was actually written
private bool emitGlobalSection(ref OutBuffer out_, ref WasmModule wmod)
{
    if (!wmod.globals.length)
        return false;

    OutBuffer* s = &wmod.scratch;
    s.reset();
    s.writeuLEB128(cast(uint) wmod.globals.length);
    foreach (ref const WasmGlobal g; wmod.globals)
    {
        // globaltype = valtype + mut flag
        s.writeByte(g.valType);
        s.writeByte(g.mutable_ ? WASM_MUT.VAR : WASM_MUT.CONST);

        assert(g.valType == WASM_I32); // TODO: support other types

        // constant-expression initializer
        s.writeByte(OP_I32_CONST);
        s.writesLEB128(g.initVal);

        s.writeByte(0x0B); // end of sequence
    }
    writeSection(out_, WASM_SECTION.global, s);
    return true;
}

/// Returns: true if section was actually written
private bool emitExportSection(ref OutBuffer out_, ref WasmModule wmod)
{
    OutBuffer* s = &wmod.scratch;
    s.reset();
    uint count = 0;
    foreach (ref const WasmFunc f; wmod.funcs)
        if (f.exported)
            ++count;
    // Memory is exported only in self-contained mode; in relocatable mode
    // the linker exports memory itself.
    const exportMemory = !wmod.relocatable;
    if (exportMemory)
        ++count;
    if (!count)
        return false;
    s.writeuLEB128(count);
    if (exportMemory)
    {
        appendName(*s, "memory");
        s.writeByte(WASM_EXPORT.MEM);
        s.writeuLEB128(0); // memory index 0
    }
    foreach (size_t i, ref const WasmFunc f; wmod.funcs)
    {
        if (!f.exported)
            continue;
        appendName(*s, funcName(f));
        s.writeByte(WASM_EXPORT.FUNC);
        s.writeuLEB128(cast(uint) i);
    }
    writeSection(out_, WASM_SECTION.export_, s);
    return true;
}

/// Returns: true if section was actually written
private bool emitCodeSection(ref OutBuffer out_, ref WasmModule wmod)
{
    uint defined = cast(uint)(wmod.funcs.length - wmod.numImports);
    if (!defined)
        return false;
    OutBuffer* s = &wmod.scratch;
    s.reset();
    s.writeuLEB128(defined);

    // Track running byte offset from start of code section payload
    // to compute absolute relocation offsets for reloc.CODE.
    uint payloadOffset = ulebSize(defined);

    foreach (size_t fi, ref const WasmFunc f; wmod.funcs[wmod.numImports .. $])
    {
        WasmFuncBody* fb = fi < wasmFuncBodies.length ? &wasmFuncBodies[fi] : null;

        // Build local declarations into a temp buffer to know their size.
        OutBuffer locBuf;
        uint numLocalGroups = 0;
        if (fb && fb.code.length())
        {
            numLocalGroups = cast(uint)(fb.locals.length - fb.numParams);
            locBuf.writeuLEB128(numLocalGroups);
            foreach (ref const WasmLocal l; fb.locals[fb.numParams .. $])
            {
                locBuf.writeuLEB128(1); // count of this type
                locBuf.writeByte(l.ty);
            }
        }
        else
        {
            locBuf.writeuLEB128(0); // 0 local groups
        }

        uint codeLen = fb && fb.code.length() ? cast(uint) fb.code.length() : 1; // 1 = unreachable
        uint bodySize = cast(uint)(locBuf.length() + codeLen + 1); // +1 for END byte
        uint bodySizeBytes = ulebSize(bodySize);

        // Record where this function's code bytes start in the code section payload.
        // = offset of body_size field + body_size field bytes + local declarations
        if (fb)
            fb.codePayloadStart = payloadOffset + bodySizeBytes + cast(uint) locBuf.length();

        s.writeuLEB128(bodySize);
        s.write(locBuf.peekSlice());
        if (fb && fb.code.length())
            s.write(fb.code.peekSlice());
        else
            s.writeByte(OP_UNREACHABLE);
        s.writeByte(OP_END);

        payloadOffset += bodySizeBytes + bodySize;
    }
    writeSection(out_, WASM_SECTION.code, s);
    return true;
}

/// Returns: true if section was actually written
private bool emitDataSection(ref OutBuffer out_, ref WasmModule wmod)
{
    if (!wmod.dataSegs.length)
        return false;
    OutBuffer* s = &wmod.scratch;
    s.reset();
    s.writeuLEB128(cast(uint) wmod.dataSegs.length);
    foreach (ref WasmDataSeg ds; wmod.dataSegs)
    {
        s.writeByte(0x00); // active segment, memory 0
        // offset initializer: i32.const <offset> end
        s.writeByte(OP_I32_CONST); // i32.const
        s.writeuLEB128(ds.offset);
        s.writeByte(OP_END);
        s.writeuLEB128(cast(uint) ds.data.length());
        s.write(ds.data.peekSlice());
    }
    writeSection(out_, WASM_SECTION.data, s);
    return true;
}

// Emit the "linking" custom section required by wasm-ld.
// Contains WASM_LINKING_SYMBOL_TABLE with one entry per function (import or defined).
private bool emitLinkingSection(ref OutBuffer out_, ref WasmModule wmod)
{
    OutBuffer body_;
    body_.writeuLEB128(2); // linking metadata version 2

    // WASM_LINKING_SYMBOL_TABLE subsection
    OutBuffer symtab;
    // Count usable symbols (skip anonymous synthesized functions and
    // imports that are shadowed by a same-named defined function).
    uint symCount = 0;
    foreach (size_t i, ref const WasmFunc f; wmod.funcs)
    {
        const(char)[] name = funcName(f);
        if (!name.length)
            continue;
        if (isShadowedFunc(i))
            continue;
        symCount++;
    }
    // Data symbols: one DATA entry per data segment that has a sym, plus
    // UNDEFINED entries for code-referenced syms without a segment (externs).
    Symbol*[] datasymsForLinking = buildDataSymtabOrder();
    symCount += cast(uint) datasymsForLinking.length;

    // One TABLE symbol for the function table (defined or imported).
    const bool hasTable = !wmod.importFuncTable &&
        (wmod.funcs.length > wmod.numImports);
    const bool hasImportedTable = wmod.importFuncTable;
    if (hasTable || hasImportedTable)
        symCount++;
    // One GLOBAL symbol for __stack_pointer when imported.
    if (wmod.importStackPtrGlobal)
        symCount++;
    symtab.writeuLEB128(symCount);

    foreach (size_t i, ref const WasmFunc f; wmod.funcs)
    {
        const(char)[] name = funcName(f);
        if (!name.length)
            continue; // skip anonymous synthesized functions
        if (isShadowedFunc(i))
            continue; // canonical twin owns the symbol-table entry

        symtab.writeByte(WASM_SYMTAB.FUNCTION);

        // For UNDEFINED (import) symbols the name comes from the import
        // section; do NOT include a name field in the symbol table entry.
        // For defined symbols, provide an explicit name. Use global binding
        // (no WASM_SYM.BINDING_LOCAL) so wasm-ld accepts these symbols as
        // targets for R_WASM.TYPE_INDEX_LEB relocations.
        uint flags;
        if (f.isImport)
        {
            flags = WASM_SYM.UNDEFINED;
        }
        else
        {
            flags = WASM_SYM.EXPLICIT_NAME;
            if (f.exported)
                flags |= WASM_SYM.EXPORTED;
            // Defined non-exported functions: global binding by default
            // (omit WASM_SYM.BINDING_LOCAL so wasm-ld can use them for type relocs)
        }

        symtab.writeuLEB128(flags);
        symtab.writeuLEB128(cast(uint) i); // function index
        if (flags & WASM_SYM.EXPLICIT_NAME)
            appendName(symtab, name); // only for defined symbols
    }

    // Emit WASM_SYMTAB.DATA entries in buildDataSymtabOrder order.
    foreach (Symbol* sym; datasymsForLinking)
    {
        uint segIdx = uint.max;
        foreach (size_t i, ref const WasmDataSeg ds; wmod.dataSegs)
        {
            if (ds.sym is sym)
            {
                segIdx = cast(uint) i;
                break;
            }
        }

        symtab.writeByte(WASM_SYMTAB.DATA);
        if (segIdx == uint.max)
        {
            // Extern data symbol: no segment in this object; linker will resolve.
            symtab.writeuLEB128(WASM_SYM.UNDEFINED | WASM_SYM.EXPLICIT_NAME);
            appendName(symtab, sym.identifier);
            // UNDEFINED data symbols carry no segment/offset/size payload.
        }
        else
        {
            symtab.writeuLEB128(WASM_SYM.BINDING_LOCAL | WASM_SYM.EXPLICIT_NAME);
            appendName(symtab, sym.identifier);
            uint symSize = cast(uint) wmod.dataSegs[segIdx].data.length();
            if (sym.Stype)
            {
                const ts = type_size(sym.Stype);
                if (ts <= uint.max)
                    symSize = cast(uint) ts;
            }
            symtab.writeuLEB128(segIdx);
            symtab.writeuLEB128(0); // offset within segment (sym starts at byte 0)
            symtab.writeuLEB128(symSize);
        }
    }

    // Add a SYMTAB_TABLE entry for the function table so wasm-ld accepts it.
    if (hasTable)
    {
        // Defined table: table index 0, weak binding so wasm-ld can merge it
        // with __indirect_function_table provided by other inputs.
        symtab.writeByte(WASM_SYMTAB.TABLE);
        symtab.writeuLEB128(WASM_SYM.BINDING_WEAK | WASM_SYM.EXPLICIT_NAME);
        symtab.writeuLEB128(0); // table index 0
        appendName(symtab, "__indirect_function_table");
    }
    else if (hasImportedTable)
    {
        // Imported table: table index 0, undefined.
        symtab.writeByte(WASM_SYMTAB.TABLE);
        symtab.writeuLEB128(WASM_SYM.UNDEFINED);
        symtab.writeuLEB128(0); // table index 0
    }

    if (wmod.importStackPtrGlobal)
    {
        // Imported __stack_pointer global: global index 0, undefined.
        // Name is taken from the import section (no EXPLICIT_NAME).
        symtab.writeByte(WASM_SYMTAB.GLOBAL);
        symtab.writeuLEB128(WASM_SYM.UNDEFINED);
        symtab.writeuLEB128(0); // global index 0
    }

    // SEGMENT_INFO subsection: one entry per data segment. Names give wasm-ld
    // grouping/dead-strip granularity; alignment is the segment's own log2 align.
    if (wmod.dataSegs.length > 0)
    {
        OutBuffer seginfo;
        seginfo.writeuLEB128(cast(uint) wmod.dataSegs.length);
        foreach (size_t i, ref const WasmDataSeg ds; wmod.dataSegs)
        {
            const(char)[] segName = ds.name.length ? ds.name : ".rodata";
            seginfo.writeuLEB128(cast(uint) segName.length);
            seginfo.write(segName.ptr, cast(uint) segName.length);
            seginfo.writeuLEB128(ds.alignLog2);
            seginfo.writeuLEB128(0); // flags
        }

        body_.writeByte(WASM_LINKING.SEGMENT_INFO);
        body_.writeuLEB128(cast(uint) seginfo.length());
        body_.write(seginfo.peekSlice());
    }

    body_.writeByte(WASM_LINKING.SYMBOL_TABLE);
    body_.writeuLEB128(cast(uint) symtab.length());
    body_.write(symtab.peekSlice());

    writeCustomSection(out_, "linking", &body_);
    return true;
}

/// Emit "reloc.DATA" custom section with R_WASM.TABLE_INDEX_I32 entries for
/// function-table-index (function pointer) writes in the data section.
/// wasm-ld patches these with the correct table indices after linking.
/// dataSectionIdx: the 0-based section index of the data section in the module.
///
/// Returns: true if section was actually written
private bool emitRelocDataSection(ref OutBuffer out_, ref WasmModule wmod, uint dataSectionIdx)
{
    if (!wmod.funcRelocations.length || !wmod.dataSegs.length)
        return false;

    uint[] funcToSymIdx = buildFuncToSymIdx();

    // Data section payload layout (matches emitDataSection):
    //   [count ULEB]
    //   for each seg:
    //     [kind=0x00] [i32.const=0x41] [offset ULEB] [end=0x0B]
    //     [size ULEB] [data bytes]
    // Pre-compute, for each segment, the byte offset of its first data byte
    // within the data section payload.
    uint[] segDataStart;
    segDataStart.length = wmod.dataSegs.length;
    uint cursor = ulebSize(cast(uint) wmod.dataSegs.length);
    foreach (size_t i, ref const WasmDataSeg ds; wmod.dataSegs)
    {
        const uint sz = cast(uint) ds.data.length();
        const uint header = 1 /*kind*/ + 1 /*i32.const*/ + ulebSize(ds.offset)
                          + 1 /*end*/ + ulebSize(sz);
        segDataStart[i] = cursor + header;
        cursor += header + sz;
    }

    // Two-pass: first count valid relocs, then write them.
    uint relCount = 0;
    foreach (ref WasmModule.FuncReloc rel; wmod.funcRelocations)
    {
        if (rel.segIdx >= wmod.dataSegs.length)
            continue;
        uint funcIdx = uint.max;
        foreach (size_t fi; wmod.numImports .. wmod.funcs.length)
            if (wmod.funcs[fi].sym == rel.sym)
            {
                funcIdx = cast(uint) fi;
                break;
            }
        if (funcIdx != uint.max && funcIdx < funcToSymIdx.length &&
            funcToSymIdx[funcIdx] != uint.max)
            relCount++;
    }
    if (!relCount)
        return false;

    OutBuffer payload;
    payload.writeuLEB128(dataSectionIdx);
    payload.writeuLEB128(relCount);

    foreach (ref WasmModule.FuncReloc rel; wmod.funcRelocations)
    {
        if (rel.segIdx >= wmod.dataSegs.length)
            continue;
        uint funcIdx = uint.max;
        foreach (size_t fi; wmod.numImports .. wmod.funcs.length)
            if (wmod.funcs[fi].sym == rel.sym)
            {
                funcIdx = cast(uint) fi;
                break;
            }
        if (funcIdx == uint.max)
            continue;
        uint sym = funcToSymIdx[funcIdx];
        if (sym == uint.max)
            continue;

        payload.writeByte(R_WASM.TABLE_INDEX_I32);
        payload.writeuLEB128(segDataStart[rel.segIdx] + rel.dataByteOffset);
        payload.writeuLEB128(sym);
    }

    writeCustomSection(out_, "reloc.DATA", &payload);
    return true;
}

// Emit "reloc.ELEM" custom section with R_WASM.FUNCTION_INDEX_LEB entries for
// each function index in the element section so wasm-ld can patch them when
// the element is merged with other objects (function indices may change).
private bool emitRelocElemSection(ref OutBuffer out_, ref WasmModule wmod, uint elemSectionIdx)
{
    if (!wmod.elemFuncRelocOffsets.length)
        return false;

    uint[] funcToSymIdx = buildFuncToSymIdx();

    // Two-pass: count valid relocs first, then write.
    uint relCount = 0;
    foreach (size_t k, uint payloadOff; wmod.elemFuncRelocOffsets)
    {
        uint funcIdx = cast(uint)(wmod.numImports + k);
        if (funcIdx < funcToSymIdx.length && funcToSymIdx[funcIdx] != uint.max)
            relCount++;
    }
    if (!relCount)
        return false;

    OutBuffer payload;
    payload.writeuLEB128(elemSectionIdx);
    payload.writeuLEB128(relCount);

    foreach (size_t k, uint payloadOff; wmod.elemFuncRelocOffsets)
    {
        uint funcIdx = cast(uint)(wmod.numImports + k);
        uint sym = funcIdx < funcToSymIdx.length ? funcToSymIdx[funcIdx] : uint.max;
        if (sym == uint.max)
            continue;
        payload.writeByte(R_WASM.FUNCTION_INDEX_LEB);
        payload.writeuLEB128(payloadOff);
        payload.writeuLEB128(sym);
    }

    writeCustomSection(out_, "reloc.ELEM", &payload);
    return true;
}

// Emit "reloc.CODE" custom section with function and data-address relocs.
// codeSectionIdx: the 0-based section index of the code section in the module.
private bool emitRelocCodeSection(ref OutBuffer out_, ref WasmModule wmod, uint codeSectionIdx)
{
    uint[] funcToSymIdx = buildFuncToSymIdx();

    // Data symbol table ordering: must match buildDataSymtabOrder used by
    // emitLinkingSection (defined-by-segment first, then extern code-refs).
    Symbol*[] datasyms = buildDataSymtabOrder();

    // The data symbol table indices start right after the function symbol table.
    // Count distinct function sym indices (shadowed funcs alias to a canonical
    // index and must not inflate the count).
    uint dataSymBase = 0;
    foreach (size_t i, ref const WasmFunc f; wmod.funcs)
    {
        if (funcToSymIdx[i] == uint.max)
            continue;
        if (isShadowedFunc(i))
            continue;
        dataSymBase++;
    }
    // (TABLE symbol is emitted after data syms in the linking section, so it
    //  doesn't affect data sym indices here.)

    uint dataSymIdx(const(Symbol)* sym)
    {
        foreach (size_t k, ds; datasyms)
            if (ds == sym)
                return dataSymBase + cast(uint) k;
        return uint.max;
    }

    // Resolve a CodeReloc's funcIdx to the current wmod.funcs index. Prefers
    // r.sym (stable across post-codegen import insertions); falls back to a
    // name-based match (an RTL symbol may have been deduped against a defined
    // function of the same name, so the original Symbol* never landed in funcs);
    // last resort is the funcIdx snapshot recorded at emit time.
    uint currentFuncIdx(ref const WasmFuncBody.CodeReloc r)
    {
        if (r.sym)
        {
            foreach (size_t k, ref const WasmFunc f; wmod.funcs)
                if (f.sym == r.sym)
                    return cast(uint) k;
            if (r.sym.Sident.ptr)
            {
                const(char)[] rname = r.sym.identifier;
                foreach (size_t k, ref const WasmFunc f; wmod.funcs)
                    if (funcName(f) == rname)
                        return cast(uint) k;
            }
        }
        return r.symIdx;
    }

    // Count total relocations.
    uint totalRelocs = 0;
    foreach (ref const WasmFuncBody fb; wasmFuncBodies)
    {
        foreach (ref const WasmFuncBody.CodeReloc r; fb.codeRelocs)
        {
            // R_WASM.TYPE_INDEX_LEB encodes a type-section index directly,
            // not a symbol-table index. Always valid (typeIdx already chosen).
            uint fi = currentFuncIdx(r);
            if (r.type == R_WASM.TYPE_INDEX_LEB ||
                (fi < funcToSymIdx.length && funcToSymIdx[fi] != uint.max))
                totalRelocs++;
        }
        foreach (ref const WasmFuncBody.DataAddrReloc r; fb.dataAddrRelocs)
            if (r.sym && dataSymIdx(r.sym) != uint.max)
                totalRelocs++;
    }
    if (!totalRelocs)
        return false;

    // wasm-ld requires relocations in ascending offset order.
    // Merge all relocations into a flat list and sort by absolute offset.
    struct AnyReloc
    {
        uint absOffset; // fb.codePayloadStart + r.offset
        ubyte type;
        uint sym;
        uint addend; // only for MEMORY_ADDR_LEB
    }

    AnyReloc[] allRelocs;
    allRelocs.reserve(totalRelocs);

    foreach (ref const WasmFuncBody fb; wasmFuncBodies)
    {
        foreach (ref const WasmFuncBody.CodeReloc r; fb.codeRelocs)
        {
            uint idx;
            if (r.type == R_WASM.TYPE_INDEX_LEB)
            {
                // R_WASM.TYPE_INDEX_LEB references the local type section
                // index directly — wasm-ld remaps to the merged type table.
                idx = r.symIdx;
            }
            else
            {
                uint fi = currentFuncIdx(r);
                if (fi >= funcToSymIdx.length)
                    continue;
                idx = funcToSymIdx[fi];
                if (idx == uint.max)
                    continue;
            }
            allRelocs ~= AnyReloc(fb.codePayloadStart + r.offset, r.type, idx, 0);
        }
        foreach (ref const WasmFuncBody.DataAddrReloc r; fb.dataAddrRelocs)
        {
            if (!r.sym)
                continue;
            uint sym = dataSymIdx(r.sym);
            if (sym == uint.max)
                continue;
            // addend = offset relative to the symbol's base (usually 0 or Voffset)
            allRelocs ~= AnyReloc(fb.codePayloadStart + r.offset,
                R_WASM.MEMORY_ADDR_LEB, sym, r.addend);
        }
    }

    // Sort by absOffset (insertion sort — typically nearly-sorted already).
    for (size_t i = 1; i < allRelocs.length; i++)
    {
        AnyReloc key = allRelocs[i];
        size_t j = i;
        while (j > 0 && allRelocs[j - 1].absOffset > key.absOffset)
        {
            allRelocs[j] = allRelocs[j - 1];
            j--;
        }
        allRelocs[j] = key;
    }

    OutBuffer payload;
    payload.writeuLEB128(codeSectionIdx);
    payload.writeuLEB128(cast(uint) allRelocs.length);

    foreach (ref const AnyReloc r; allRelocs)
    {
        payload.writeByte(r.type);
        payload.writeuLEB128(r.absOffset);
        payload.writeuLEB128(r.sym);
        if (r.type == R_WASM.MEMORY_ADDR_LEB)
            payload.writesLEB128(cast(int) r.addend); // addend is SLEB per spec
    }

    writeCustomSection(out_, "reloc.CODE", &payload);
    return true;
}

// Symbol-table order for DATA entries:
//   1. one entry per WasmDataSeg with a sym (defined data symbols), in seg order
//   2. then extra Symbols referenced by code relocs but lacking a segment
//      (extern data symbols — emitted as UNDEFINED)
// Both the linking section and reloc.CODE must agree on this ordering.
private Symbol*[] buildDataSymtabOrder()
{
    Symbol*[] order;
    foreach (ref const WasmDataSeg ds; wmod.dataSegs)
        if (ds.sym)
            order ~= cast(Symbol*) ds.sym;
    foreach (Symbol* sym; collectRelocDataSyms())
    {
        bool present = false;
        foreach (s; order)
            if (s is sym) { present = true; break; }
        if (!present)
            order ~= sym;
    }
    return order;
}

// Collect all data symbols referenced in code relocations.
// Must match the ordering used in emitRelocCodeSection.
private Symbol*[] collectRelocDataSyms()
{
    Symbol*[] datasyms;
    foreach (ref const WasmFuncBody fb; wasmFuncBodies)
    {
        foreach (ref const WasmFuncBody.DataAddrReloc r; fb.dataAddrRelocs)
        {
            if (!r.sym)
                continue;
            bool found = false;
            foreach (ds; datasyms)
                if (ds == r.sym)
                {
                    found = true;
                    break;
                }
            if (!found)
                datasyms ~= cast(Symbol*) r.sym;
        }
    }
    return datasyms;
}

// ---------------------------------------------------------------------------
// Obj interface implementation
// ---------------------------------------------------------------------------

Obj WasmObj_init(OutBuffer* objbuf, const(char)* filename, const(char)* csegname)
{
    wmod = new WasmModule();
    wmod.objbuf = objbuf;
    wasmFuncBodies = null;
    // The relocatable flag is set externally (by the DMD frontend) when -c is given.
    wmod.relocatable = wasm_relocatable;

    // Initialize the SegData array with placeholder entries for the standard
    // segment indices (CODE=1, DATA=2, CDATA=3, UDATA=4) so the backend's
    // segment-offset bookkeeping doesn't crash.
    SegData.reset();
    SegData.push(); // index 0 reserved
    pushSegData(WASM_UDATA); // push indices 1-4

    return new Obj();
}

void WasmObj_initfile(const(char)* filename, const(char)* csegname, const(char)* modname)
{
}

void WasmObj_termfile()
{
}

void WasmObj_term(const(char)[] objfilename)
{
    WasmObj_term2(objfilename, *wmod, *wmod.objbuf);
    wmod = null;
}

import dmd.backend.el;
import dmd.backend.oper;

// RTLSYMs like _d_arraybounds_indexp and libc functions like memcmp are
// declared with type_fake(TYnfunc) and all share a single __gshared `t`
// (see rtlsym.d:146), leaving Tparamtypes null and Tnext = TYvoid.
// The signature derived from such a declaration won't match the real
// definition, so wasm-ld emits "function signature mismatch" warnings,
// and (worse) memcmp's missing i32 return makes callers underflow the
// operand stack. Clone Stype so each symbol gets its own type, then
// synthesize Tparamtypes from the OPparam tree and Tnext from e.Ety.
void guessTypeFromCall(ref Symbol s, ref elem e)
{
    if (!s.Stype || !tyfunc(s.Stype.Tty))
        return;

    if (s.Stype.Tparamtypes.length != 0)
        return;

    s.Stype = type_copy(s.Stype);
    s.Stype.Tcount++;
    if (e.E2)
    {
        void appendArgTypes(elem* p)
        {
            if (!p)
                return;
            if (p.Eoper == OPparam)
            {
                // Match consumeCallArg walk order (E2 then E1) so the
                // synthesised param types line up with the actual push order.
                appendArgTypes(p.E2);
                appendArgTypes(p.E1);
                return;
            }
            param_append_type(&s.Stype.Tparamtypes, type_fake(tybasic(p.Ety)));
        }
        appendArgTypes(e.E2);
        // Synthesised arity is full and fixed — flag so variadic() returns false
        // and we don't emit a spurious trailing varargs i32 pointer.
        s.Stype.Tflags |= TF.fixed;
    }
    // Synthesize the return type from the call expression's type.
    // The shared placeholder Tnext is TYvoid; replace it with whatever
    // the caller expects (e.g. memcmp → TYint, memcpy → TYnptr).
    if (s.Stype.Tnext && tybasic(s.Stype.Tnext.Tty) == TYvoid && typeHasValue(e.Ety))
    {
        type* old = s.Stype.Tnext;
        s.Stype.Tnext = type_fake(tybasic(e.Ety));
        s.Stype.Tnext.Tcount++;
        type_free(old);
    }
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
            // elem_print(e);
            Symbol* s = e.E1.Vsym;
            if (s)
            {
                guessTypeFromCall(*s, * e);
                if (s.Sclass != SC.auto_ && s.Sclass != SC.parameter && s.Sclass != SC.fastpar)
                {
                    funcIndex(s); // side-effect: registers as import if not defined
                }
            }
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

void WasmObj_term2(const(char)[] objfilename, ref WasmModule wmod, ref OutBuffer out_)
{
    // WASM magic + version
    out_.put("\x00\x61\x73\x6D\x01\x00\x00\x00");

    // Two-phase code generation:
    // Phase 1: pre-scan all function IRs to register all external imports.
    //   This ensures import indices are stable before any bytecode is emitted.
    // Phase 2: generate bytecode for all functions.
    {
        import dmd.backend.wasm.codgen : wasm_codgen;

        // Phase 1: collect all external function references across all functions.
        foreach (ref WasmFuncBody fb; wasmFuncBodies)
        {
            if (!fb.sym || !fb.sym.Sfunc)
                continue;
            block* b = fb.sym.Sfunc.Fstartblock;
            for (; b; b = b.Bnext)
                preRegisterExternals(b.Belem);
        }
        // Intern types of defined functions now that all import types are
        // registered. Imports occupy indices 0..numImports-1; defined-function
        // types are appended next, in registration order. Phase 2 codegen
        // sees stable, ld-compatible type indices.
        wmod.internPendingTypes();

        // Phase 2: generate code now that import indices are stable.
        // Restore each function's globsym before calling wasm_codgen.
        import dmd.backend.var : globsym;

        foreach (ref WasmFuncBody fb; wasmFuncBodies)
        {
            if (!fb.sym)
                continue;
            // Restore the function's local symbol table.
            globsym.setLength(cast(uint) fb.savedGlobsym.length);
            foreach (size_t i, s; fb.savedGlobsym)
                globsym[i] = s;
            wasm_codgen(fb.sym, wasm_relocatable);
        }
        globsym.setLength(0);
    }

    // Patch deferred relocations. Each reloc carries its segment index.
    if (!wmod.relocatable)
    {
        // Final module: resolve function-pointer table indices directly.
        foreach (ref WasmModule.FuncReloc rel; wmod.funcRelocations)
        {
            if (rel.segIdx >= wmod.dataSegs.length)
                continue;
            ubyte[] dataBuf = cast(ubyte[]) wmod.dataSegs[rel.segIdx].data.peekSlice();
            if (rel.dataByteOffset + 4 > dataBuf.length)
                continue;
            uint tableIdx = 0;
            foreach (size_t fi; wmod.numImports .. wmod.funcs.length)
                if (wmod.funcs[fi].sym == rel.sym)
                {
                    tableIdx = cast(uint)(fi - wmod.numImports);
                    break;
                }
            dataBuf[rel.dataByteOffset .. rel.dataByteOffset + 4] =
                (cast(ubyte*)&tableIdx)[0 .. 4];
        }
    }
    // In relocatable mode, funcRelocations are left as 0 placeholders;
    // wasm-ld patches them via R_WASM.TABLE_INDEX_I32 in reloc.DATA.

    // Always patch data-to-data address references (stable across linking).
    foreach (ref WasmModule.DataReloc rel; wmod.dataRelocations)
    {
        if (rel.segIdx >= wmod.dataSegs.length)
            continue;
        ubyte[] dataBuf = cast(ubyte[]) wmod.dataSegs[rel.segIdx].data.peekSlice();
        if (rel.dataByteOffset + 4 > dataBuf.length)
            continue;
        uint addr = cast(uint)(rel.sym.Soffset + rel.addend);
        dataBuf[rel.dataByteOffset .. rel.dataByteOffset + 4] =
            (cast(ubyte*)&addr)[0 .. 4];
    }

    // Finalize __stack_pointer initial value (self-contained mode only).
    // Data section occupies low addresses (0..dataHeap-1).
    // Shadow stack grows downward from 65536 (top of first 64KiB page).
    // Both fit in a single page as long as dataHeap < 65536.
    // In relocatable mode the global is imported, not defined here, so the
    // linker provides the initial value.
    if (wmod.stackPtrGlobalIdx >= 0 && !wmod.importStackPtrGlobal)
        wmod.globals[wmod.stackPtrGlobalIdx].initVal = 65536;

    // In relocatable mode the linker owns __indirect_function_table; importing
    // it (rather than defining it) lets wasm-ld merge tables across objects
    // and avoids "reserved symbol must not be defined in input files".
    wmod.importFuncTable = wmod.relocatable;

    // Emit all sections in canonical order and track section indices
    // so reloc.CODE can reference the code section by its module index.
    uint sectionIdx = 0;
    sectionIdx += emitTypeSection(out_, wmod);
    sectionIdx += emitImportSection(out_, wmod);
    sectionIdx += emitFunctionSection(out_, wmod);
    sectionIdx += emitTableSection(out_, wmod);
    sectionIdx += emitMemorySection(out_, wmod);
    sectionIdx += emitGlobalSection(out_, wmod);
    sectionIdx += emitExportSection(out_, wmod);

    const uint elemSectionIdx = sectionIdx;
    sectionIdx += emitElementSection(out_, wmod);

    uint codeSectionIdx = sectionIdx;
    sectionIdx += emitCodeSection(out_, wmod);

    uint dataSectionIdx = sectionIdx;
    sectionIdx += emitDataSection(out_, wmod);

    // Relocatable objects include "linking" + "reloc.*" custom sections
    // so wasm-ld can patch symbol references when linking.
    if (wmod.relocatable)
    {
        emitLinkingSection(out_, wmod);
        emitRelocDataSection(out_, wmod, dataSectionIdx);
        emitRelocElemSection(out_, wmod, elemSectionIdx);
        emitRelocCodeSection(out_, wmod, codeSectionIdx);
    }
}

void WasmObj_linnum(Srcpos srcpos, int seg, targ_size_t offset)
{
}

int WasmObj_codeseg(const char* name, int suffix)
{
    return 0;
}

void WasmObj_startaddress(Symbol* s)
{
}

bool WasmObj_includelib(scope const(char)[] name)
{
    return false;
}

bool WasmObj_linkerdirective(scope const(char)* p)
{
    return false;
}

bool WasmObj_allowZeroSize()
{
    return true;
}

void WasmObj_exestr(const(char)* p)
{
}

void WasmObj_user(const(char)* p)
{
}

void WasmObj_compiler(const(char)* p)
{
}

void WasmObj_wkext(Symbol* s1, Symbol* s2)
{
}

void WasmObj_alias(const(char)* n1, const(char)* n2)
{
}

void WasmObj_staticctor(Symbol* s, int dtor, int seg)
{
}

void WasmObj_staticdtor(Symbol* s)
{
}

void WasmObj_setModuleCtorDtor(Symbol* s, bool isCtor)
{
}

void WasmObj_ehtables(Symbol* sfunc, uint size, Symbol* ehsym)
{
}

void WasmObj_ehsections()
{
}

void WasmObj_moduleinfo(Symbol* scc)
{
}

int WasmObj_comdat(Symbol* s)
{
    if (!s || !s.Stype)
        return 0;

    // Dedup: if already registered, return existing func index
    if (s.Sseg >= 0 && s.Sseg < wmod.funcs.length && wmod.funcs[s.Sseg].sym == s)
        return s.Sseg;

    // Register a defined function
    WasmFuncType ft;
    if (tybasic(s.Stype.Tty) != TYvoid)
    {
        ft = buildFuncType(s.Stype, s);
    }

    WasmFunc f;
    f.typeIdx = uint.max;
    f.pendingType = ft;
    f.sym = s;
    f.exported = (s.Sclass == SC.global);

    s.Sseg = cast(int) wmod.funcs.length;
    wmod.funcs ~= f;
    return s.Sseg;
}

int WasmObj_comdatsize(Symbol* s, targ_size_t symsize)
{
    // For data comdats (class/struct initializers), use the data segment.
    // Function comdats use WasmObj_comdat.
    if (s && s.Stype && tyfunc(tybasic(s.Stype.Tty)))
        return WasmObj_comdat(s);
    // Data comdat: allocate in linear memory data segment.
    s.Sseg = WASM_DATA;
    WasmObj_data_start(s, cast(targ_size_t) symsize, WASM_DATA);
    return WASM_DATA;
}

void WasmObj_setcodeseg(int seg)
{
}

seg_data* WasmObj_tlsseg()
{
    // WASM MVP has no TLS; map thread-local storage to the data segment
    return SegData[WASM_DATA];
}

seg_data* WasmObj_tlsseg_bss()
{
    return SegData[WASM_UDATA];
}

seg_data* WasmObj_tlsseg_data()
{
    return SegData[WASM_DATA];
}

void WasmObj_export_symbol(Symbol* s, uint argsize)
{
    if (!s)
        return;
    // Mark the function as exported
    foreach (ref WasmFunc f; wmod.funcs)
    {
        if (f.sym == s)
        {
            f.exported = true;
            return;
        }
    }
}

void WasmObj_pubdef(int seg, Symbol* s, targ_size_t offset)
{
    WasmObj_export_symbol(s, 0);
}

void WasmObj_pubdefsize(int seg, Symbol* s, targ_size_t offset, targ_size_t symsize)
{
    WasmObj_export_symbol(s, 0);
}

int WasmObj_external_def(const(char)* name)
{
    return 0;
}

int WasmObj_data_start(Symbol* sdata, targ_size_t datasize, int seg)
{
    if (!datasize)
        return 0;
    wmod.needsMemory = true;

    // Align to natural alignment of the data type (max 8 bytes).
    uint align_ = 4;
    if (sdata && sdata.Stype)
    {
        uint sz = tyalignsize(sdata.Stype.Tty);
        if (sz > 0 && sz <= 8)
            align_ = sz;
    }
    uint mask = align_ - 1;
    uint base = (wmod.dataHeap + mask) & ~mask;

    if (seg == WASM_UDATA)
    {
        // BSS: just reserve address space. WASM linear memory is zero-initialized,
        // so no bytes need to be emitted. Deactivate the data buffer so subsequent
        // lidata/write calls (which don't exist for BSS) are ignored.
        wmod.activeSegIdx = -1;
        if (sdata)
            sdata.Soffset = base;
        wmod.dataHeap = base + cast(uint) datasize;
        return seg;
    }

    // One WASM data segment per data symbol (LDC-style). Its own offset is
    // the symbol's linear-memory address; the segment's bytes are exactly
    // the symbol's payload.
    WasmDataSeg ds;
    ds.offset = base;
    ds.sym = sdata;
    if (sdata)
        ds.name = sdata.identifier;
    uint a = 1;
    int log2 = 0;
    while (a < align_) { a <<= 1; log2++; }
    ds.alignLog2 = cast(uint) log2;

    wmod.dataSegs ~= ds;
    wmod.activeSegIdx = cast(int)(wmod.dataSegs.length - 1);

    // Assign this symbol's linear memory address.
    if (sdata)
        sdata.Soffset = base;

    wmod.dataHeap = base + cast(uint) datasize;
    return 1;
}

// Update an import's WASM function type. Called from codgen when the actual
// Returns the number of WASM parameters for a function at index fidx.
// Used to detect variadic-style extra args (pushed count > WASM param count).
uint wmod_func_param_count(uint fidx)
{
    if (fidx >= wmod.funcs.length)
        return 0;
    const typeIdx = wmod.funcs[fidx].typeIdx;
    if (typeIdx >= wmod.funcTypes.length)
        return 0;
    return cast(uint) wmod.funcTypes[typeIdx].params.length;
}

int WasmObj_external(Symbol* s)
{
    if (!s || !s.Stype)
        return 0;
    // If the same symbol is already registered (import or defined), return its index.
    const(char)[] id = s.identifier;

    foreach (size_t i, ref const WasmFunc f; wmod.funcs)
    {
        // Deduplicate imports: multiple D modules may declare the same extern(C) symbol.
        if (f.isImport && f.importName == id)
        {
            s.Sseg = cast(int) i;
            return s.Sseg;
        }
        // If a non-import function with the same name is already defined (e.g. user provides
        // `extern(C) int memcmp(...)`), use that instead of importing.
        if (!f.isImport && f.sym && f.sym.Sident.ptr != s.Sident.ptr)
        {
            const(char)[] fname = f.sym.identifier;
            if (fname == id)
            {
                s.Sseg = cast(int) i;
                return s.Sseg;
            }
        }
    }
    // Register as an import. Module name comes from pragma(wasm_import_module), else "env".
    WasmFuncType ft;
    if (tybasic(s.Stype.Tty) != TYvoid)
        ft = buildFuncType(s.Stype, s);
    WasmFunc f;
    f.typeIdx = wmod.internType(ft);
    f.sym = s;
    if (auto p = cast(string) id in g_importModuleTable)
        f.importModule = *p;
    else
        f.importModule = "env";
    f.importName = id;
    f.isImport = true;
    // Imports must come before defined functions; insert at numImports position
    wmod.funcs = wmod.funcs[0 .. wmod.numImports] ~ [f] ~ wmod.funcs[wmod.numImports .. $];
    s.Sseg = cast(int) wmod.numImports;
    wmod.numImports++;
    return s.Sseg;
}

int WasmObj_common_block(Symbol* s, targ_size_t size, targ_size_t count)
{
    return 0;
}

int WasmObj_common_block(Symbol* s, int flag, targ_size_t size, targ_size_t count)
{
    return 0;
}

void WasmObj_lidata(int seg, targ_size_t offset, targ_size_t count)
{
    // BSS segment: WASM linear memory is zero-initialized by the runtime; address
    // space was already reserved in data_start, so nothing to emit.
    if (seg == WASM_UDATA || !wmod.activeSeg)
        return;
    foreach (_; 0 .. count)
        wmod.activeSeg.data.writeByte(0);
}

void WasmObj_write_zeros(seg_data* pseg, targ_size_t count)
{
    if (pseg.SDseg == WASM_UDATA || !wmod.activeSeg)
        return;
    foreach (_; 0 .. count)
        wmod.activeSeg.data.writeByte(0);
}

void WasmObj_write_byte(seg_data* pseg, uint _byte)
{
    if (wmod.activeSeg)
        wmod.activeSeg.data.writeByte(cast(ubyte) _byte);
}

void WasmObj_write_bytes(seg_data* pseg, const(void[]) a)
{
    if (wmod.activeSeg)
        wmod.activeSeg.data.write(a.ptr, a.length);
}

void WasmObj_byte(int seg, targ_size_t offset, uint _byte)
{
    if (wmod.activeSeg)
        wmod.activeSeg.data.writeByte(cast(ubyte) _byte);
}

size_t WasmObj_bytes(int seg, targ_size_t offset, size_t nbytes, const(void)* p)
{
    if (wmod.activeSeg && p)
        wmod.activeSeg.data.write(p, nbytes);
    return nbytes;
}

void WasmObj_reftodatseg(int seg, targ_size_t offset, targ_size_t val, uint targetdatum, int flags)
{
    // Write `val` (an address in linear memory) as a 4-byte LE integer
    // into the active data segment at the current position.
    // In WASM single-segment layout, val IS the linear memory address.
    if (!wmod.activeSeg)
        return;
    uint addr = cast(uint) val;
    wmod.activeSeg.data.write(&addr, 4);
}

void WasmObj_reftocodeseg(int seg, targ_size_t offset, targ_size_t val)
{
}

int WasmObj_reftoident(int seg, targ_size_t offset, Symbol* s, targ_size_t val, int flags)
{
    auto active = wmod.activeSeg;
    if (!active)
        return 4;
    const uint segIdx = cast(uint) wmod.activeSegIdx;
    // Function symbols: write 0 as placeholder; real table index patched in WasmObj_term.
    if (s && s.Stype && tyfunc(tybasic(s.Stype.Tty)))
    {
        uint dataOff = cast(uint) active.data.length;
        uint zero = 0;
        active.data.write(&zero, 4);
        wmod.funcRelocations ~= WasmModule.FuncReloc(segIdx, dataOff, s);
        return 4;
    }
    // Data symbols: write linear memory address, or defer if not yet allocated.
    uint addr;
    if (s && s.Soffset == 0)
    {
        // Soffset is 0: symbol may not be allocated yet. Record deferred relocation;
        // WasmObj_term will patch with the final address (or leave as 0 if truly external).
        uint dataOff = cast(uint) active.data.length;
        uint zero = 0;
        active.data.write(&zero, 4);
        wmod.dataRelocations ~= WasmModule.DataReloc(segIdx, dataOff, s, cast(uint) val);
        return 4;
    }
    addr = cast(uint)(s ? (s.Soffset + val) : val);
    active.data.write(&addr, 4);
    return 4;
}

void WasmObj_far16thunk(Symbol* s)
{
}

void WasmObj_fltused()
{
}

// Accessors for codgen.d to query wmod.funcs without importing the struct.
uint wmod_numImports()
{
    return wmod ? wmod.numImports : 0;
}

Symbol* wmod_funcs(size_t i)
{
    if (!wmod || i >= wmod.funcs.length)
        return null;
    return wmod.funcs[i].sym;
}

// Intern a WASM function type given explicit param and result byte arrays.
// Used by codgen.d to compute typeIdx for virtual call_indirect.
uint wmod_internType(WasmFuncType funcType)
{
    assert(wmod);
    return wmod.internType(funcType);
}

/// Look up the WASM signature recorded for `sfunc` when its body was registered
/// (via WasmObj_func_start).  Returns the registered param count, or uint.max
/// if the function isn't in this module.  Used by wasm_codgen2 so locals get
/// indexed past the implicit WASM params even when the source signature has
/// fewer params than the recorded sig (e.g. `_Dmain` normalisation).
uint wmod_recordedParamCount(Symbol* sfunc)
{
    if (!wmod || !sfunc)
        return uint.max;
    foreach (ref const WasmFunc f; wmod.funcs)
    {
        if (f.sym is sfunc)
            return cast(uint) f.pendingType.params.length;
    }
    return uint.max;
}

// Find the function index of a named function whose WASM type matches typeIdx.
// Used to produce R_WASM.TYPE_INDEX_LEB relocations for call_indirect instructions
// so wasm-ld can patch the type index when merging type tables.
// Prefers import functions: wasm-ld 22 can crash on R_WASM.TYPE_INDEX_LEB
// relocations targeting locally-defined symbols; imports are always safe.
uint wmod_findFuncForType(uint typeIdx)
{
    assert(wmod);

    uint localFallback = uint.max;
    foreach (size_t i, ref const WasmFunc f; wmod.funcs)
    {
        if (f.typeIdx != typeIdx)
            continue;

        // Only consider functions that have a symbol table entry (named).
        const(char)[] name = funcName(f);
        if (!name.length)
            continue;

        if (f.isImport)
            return cast(uint) i; // prefer import symbols (safe for wasm-ld 22)

        if (localFallback == uint.max)
            localFallback = cast(uint) i;
    }
    return localFallback;
}

// Record a R_WASM.MEMORY_ADDR_LEB relocation for a data symbol address emitted
// in the current function's code.  codeOffset is the byte offset within the
// current WasmFuncBody.code buffer where the 5-byte padded ULEB128 begins.
// sym is the D Symbol for the data object; addend is the extra byte offset
// beyond sym.Soffset (typically e.Voffset in the IR).
void wmod_recordDataAddrReloc(uint codeOffset, Symbol* sym, uint addend)
{
    if (!wasmFuncBodies.length)
        return;
    WasmFuncBody.DataAddrReloc r;
    r.offset = codeOffset;
    r.sym = sym;
    r.addend = addend;
    wasmFuncBodies[$ - 1].dataAddrRelocs ~= r;
}

// Return the index of the __stack_pointer mutable global, creating it if needed.
// Called by codgen.d when a function needs a shadow stack frame.
//
// Relocatable mode: import __stack_pointer from "env" so wasm-ld can merge
// stack pointers across objects. The imported global occupies global index 0
// in the WASM global index space (imports precede defined globals, and
// __stack_pointer is currently the only imported global).
//
// Non-relocatable (self-contained) mode: define the global locally and let
// WasmObj_term compute its initial value from the final data layout.
uint wmod_getOrCreateStackPtrGlobal()
{
    if (wmod.stackPtrGlobalIdx >= 0)
        return cast(uint) wmod.stackPtrGlobalIdx;
    wmod.needsMemory = true; // shadow stack lives in linear memory
    if (wmod.relocatable)
    {
        wmod.importStackPtrGlobal = true;
        wmod.stackPtrGlobalIdx = 0; // first (and only) imported global
        return 0;
    }
    WasmGlobal g;
    g.valType = WASM_I32;
    g.mutable_ = true;
    g.initVal = 65536; // placeholder; updated in WasmObj_term from dataHeap
    wmod.stackPtrGlobalIdx = cast(int) wmod.globals.length;
    wmod.globals ~= g;
    return cast(uint) wmod.stackPtrGlobalIdx;
}

// Public entry point for codgen.d to allocate string data directly.
uint allocRoData_wasm(const(void)* p, uint len, uint align_)
{
    return allocRoData(p, len, align_);
}

// Allocate `len` bytes of read-only data at the next aligned offset,
// write the bytes into a fresh segment, and return the linear memory address.
private uint allocRoData(const(void)* p, uint len, uint align_)
{
    wmod.needsMemory = true;
    uint mask = align_ - 1;
    uint base = (wmod.dataHeap + mask) & ~mask;

    WasmDataSeg ds;
    ds.offset = base;
    // Synthesised name (".rodata.<n>") matches the LLVM convention so wasm-ld
    // groups these alongside other rodata.
    {
        import core.stdc.stdio : snprintf;
        char[32] buf;
        const n = snprintf(buf.ptr, buf.length, ".rodata.%u",
            cast(uint) wmod.dataSegs.length);
        ds.name = buf[0 .. n].idup;
    }
    uint a = 1;
    int log2 = 0;
    while (a < align_) { a <<= 1; log2++; }
    ds.alignLog2 = cast(uint) log2;
    if (p)
        ds.data.write(p, len);
    else
        foreach (_; 0 .. len)
            ds.data.writeByte(0);

    wmod.dataSegs ~= ds;
    wmod.activeSegIdx = cast(int)(wmod.dataSegs.length - 1);
    wmod.dataHeap = base + len;
    return base;
}

int WasmObj_data_readonly(char* p, int len, int* pseg)
{
    uint align_ = len >= 8 ? 8 : len >= 4 ? 4 : len >= 2 ? 2 : 1;
    uint off = allocRoData(p, len, align_);
    if (pseg)
        *pseg = 1;
    return cast(int) off;
}

int WasmObj_data_readonly(char* p, int len)
{
    int pseg;
    return WasmObj_data_readonly(p, len, &pseg);
}

int WasmObj_string_literal_segment(uint sz)
{
    // Return UNKNOWN so outdata() routes the string symbol through DATA.
    return UNKNOWN;
}

Symbol* WasmObj_sym_cdata(tym_t ty, char* p, int len)
{
    import dmd.backend.global : symboldata;

    uint align_ = cast(uint) tyalignsize(ty);
    if (align_ < 1)
        align_ = 1;
    uint off = allocRoData(p, len, align_);
    Symbol* s = symboldata(off, ty);
    s.Sseg = 1;
    return s;
}

void WasmObj_func_start(Symbol* sfunc)
{
    if (!sfunc || !sfunc.Stype)
        return;

    WasmFuncType ft = buildFuncType(sfunc.Stype, sfunc);

    WasmFunc f;
    f.typeIdx = uint.max;
    f.pendingType = ft;
    f.sym = sfunc;
    f.exported = (sfunc.Sclass == SC.global);
    wmod.funcs ~= f;
    sfunc.Sseg = cast(int)(wmod.funcs.length - 1);

    // Allocate a function body slot
    WasmFuncBody fb;
    fb.sym = sfunc;
    wasmFuncBodies ~= fb;
}

void WasmObj_func_term(Symbol* sfunc)
{
    // Save globsym (function locals/params) for use in deferred codegen.
    // globsym is cleared by the caller after func_term returns.
    import dmd.backend.var : globsym;

    foreach (ref WasmFuncBody fb; wasmFuncBodies)
    {
        if (fb.sym == sfunc)
        {
            fb.savedGlobsym.length = globsym.length;
            foreach (size_t i, s; globsym[])
                fb.savedGlobsym[i] = s;
            break;
        }
    }
    // Code generation deferred to WasmObj_term (two-phase compilation).
}

void WasmObj_write_pointerRef(Symbol* s, uint off)
{
}

int WasmObj_jmpTableSegment(Symbol* s)
{
    return 0;
}

Symbol* WasmObj_tlv_bootstrap()
{
    return null;
}

void WasmObj_gotref(Symbol* s)
{
}

Symbol* WasmObj_getGOTsym()
{
    return null;
}

void WasmObj_refGOTsym()
{
}
