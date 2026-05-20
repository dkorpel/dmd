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
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/compiler/src/dmd/backend/wasmobj.d, _wasmobj.d)
 */

module dmd.backend.wasmobj;

import core.stdc.string : strlen;

import dmd.backend.cc;
import dmd.backend.cdef;
import dmd.backend.code;
import dmd.backend.el;
import dmd.backend.obj;
import dmd.backend.ty;
import dmd.backend.type;
import dmd.backend.wasm.codgen : wasmType, funcIndex;

import dmd.backend.wasm;
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

/// Returns: number of bytes needed for ULEB128 encoding of v
private uint ulebSize(uint v)
{
    uint n = 0;
    do
    {
        n++;
        v >>= 7;
    }
    while (v);
    return n;
}

// Name of a WasmFunc as it appears in the wasm symbol table.
private const(char)[] funcName(ref const WasmFunc f)
{
    if (f.sym)
        return f.sym.identifier;
    return f.importName.length ? f.importName : f.name[];
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

// WASM function type: params and result
struct WasmFuncType
{
    ubyte[] params; // value types of parameters
    ubyte[] results; // value types of return values (0 or 1 for MVP)
}

// Recorded function definition
struct WasmFunc
{
    uint typeIdx; // index into typeSection
    Symbol* sym; // the D symbol
    bool exported;
    bool isImport;
    const(char)[] importModule; // for imports: module name
    const(char)[] importName; // for imports: field name
    string name; // for synthesized functions with no Symbol and no importName
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

// Data segment (initialized global data)
struct WasmDataSeg
{
    uint offset; // linear memory offset
    OutBuffer data; // raw bytes
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
    WasmDataSeg[] dataSegs; // data segments
    WasmDataSeg* activeSeg; // current data segment being filled

    uint memoryPageCount; // number of 64 KiB memory pages
    bool needsMemory; // true if any data segments or shadow stack exist
    uint dataHeap = 4; // next free byte offset in linear memory; starts at 4 to reserve address 0 as null

    WasmGlobal[] globals; // module-level mutable globals
    int stackPtrGlobalIdx = -1; // index of __stack_pointer global (-1 = not created)
    bool importFuncTable; // true: import __indirect_function_table from "env"
    uint[] elemFuncRelocOffsets; // payload offsets of function indices in the element section
    bool relocatable; // true: emit linking/reloc sections (for -c / wasm-ld use)

    // Deferred relocations in data segments. Written as 0 at emit time;
    // patched in WasmObj_term once all symbol addresses are known.
    struct FuncReloc
    {
        uint dataByteOffset;
        Symbol* sym;
    }

    struct DataReloc
    {
        uint dataByteOffset;
        Symbol* sym;
        uint addend;
    }

    FuncReloc[] funcRelocations;
    DataReloc[] dataRelocations;

    // Scratch OutBuffer for section payloads
    OutBuffer scratch;

nothrow:

    // Rearrange funcTypes so import function types come first (in import order).
    // wasm-ld does the same when creating the final module, so by pre-empting
    // this reordering our type indices remain stable after single-file linking,
    // and call_indirect instructions stay correct without relocation patching.
    void reorderImportTypesFirst() nothrow
    {
        if (!numImports || funcTypes.length == 0)
            return;

        // Build mapping: old type index -> new type index
        uint[] oldToNew;
        oldToNew.length = funcTypes.length;
        oldToNew[] = uint.max;

        WasmFuncType[] newTypes;

        // Step 1: add import function types first, in import-function order.
        foreach (ref const WasmFunc f; funcs[0 .. numImports])
        {
            uint oi = f.typeIdx;
            if (oi < funcTypes.length && oldToNew[oi] == uint.max)
            {
                oldToNew[oi] = cast(uint) newTypes.length;
                newTypes ~= WasmFuncType(funcTypes[oi].params.dup, funcTypes[oi].results.dup);
            }
        }

        // Step 2: append remaining types in their original relative order.
        foreach (size_t i, ref const WasmFuncType ft; funcTypes)
        {
            if (oldToNew[i] == uint.max)
            {
                oldToNew[i] = cast(uint) newTypes.length;
                newTypes ~= WasmFuncType(ft.params.dup, ft.results.dup);
            }
        }

        // Update typeIdx for all registered functions.
        foreach (ref WasmFunc f; funcs)
            if (f.typeIdx < oldToNew.length)
                f.typeIdx = oldToNew[f.typeIdx];

        funcTypes = newTypes;
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


// Returns true if the backend type is an aggregate (struct/array) that must be
// returned via a hidden pointer parameter in the WASM calling convention.
private bool isAggregateType(type* t)
{
    if (!t)
        return false;
    switch (tybasic(t.Tty))
    {
    case TYstruct:
    case TYarray:
        return true;
    default:
        return false;
    }
}

// Build a WasmFuncType from a backend function type.
// Aggregates are passed/returned by pointer; aggregate return adds a hidden i32 first.
private WasmFuncType buildFuncType(type* t, Symbol* sfunc)
{
    WasmFuncType ft;

    // Check for aggregate return: requires a hidden pointer as the first parameter.
    type* ret = t.Tnext;
    const bool hiddenPtr = isAggregateType(ret);
    if (hiddenPtr)
        ft.params ~= WASM_I32; // hidden return pointer (first param)

    // D member functions (Fmember) receive 'this' as an implicit first parameter.
    // D nested functions (Fnested) receive a static-link/closure pointer.
    // Neither is in Tparamtypes, so prepend an i32.
    if (sfunc.Sfunc && (sfunc.Sfunc.Fflags3 & (Fmember | Fnested)))
        ft.params = WASM_I32 ~ ft.params;

    // Parameters. D dynamic arrays (TYdarray = TYullong on WASM32) are decomposed
    // by toArgTypes_wasm into (size_t length, void* ptr) = (i32, i32), matching
    // LDC2's WebAssembly ABI. TYdarray is identified by Tnext != null (element type).
    const tym_t fty = tybasic(t.Tty);

    for (param_t* p = t.Tparamtypes; p; p = p.Pnext)
    {
        if (p.Ptype && tybasic(p.Ptype.Tty) != TYvoid)
        {
            const tym_t pty = tybasic(p.Ptype.Tty);
            // TYdarray (D slice) == TYullong on WASM32; Tnext holds the element type.
            // Split into two i32 WASM params: (size_t len, T* ptr).
            if (pty == TYullong && p.Ptype.Tnext)
            {
                ft.params ~= WASM_I32;
                ft.params ~= WASM_I32;
            }
            else
            {
                ft.params ~= wasmType(pty);
            }
        }
    }

    // C variadic (`...`): append a trailing i32 varargs-pointer parameter.
    // Matches the LDC2/wasi-libc ABI: caller spills variadic args to the shadow
    // stack and passes a pointer to that region as the last function parameter.
    // A real C variadic requires at least one fixed param; bare type_fake(TYnfunc)
    // symbols (RTL: _d_assertp, etc.) have TF.prototype set but Tparamtypes == null
    // and must not get the trailing varargs ptr.
    import dmd.backend.type : variadic;

    if (variadic(t) && t.Tparamtypes !is null)
        ft.params ~= WASM_I32;

    // Return type (void and noreturn both produce no WASM result)
    if (hiddenPtr)
        ft.results ~= WASM_I32; // returns hidden ptr
    else if (ret && tybasic(ret.Tty) != TYvoid && tybasic(ret.Tty) != TYnoreturn)
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

/// Returns: true if section was actually written
private bool emitImportSection(ref OutBuffer out_, ref WasmModule wmod)
{
    uint count = wmod.numImports + (wmod.importFuncTable ? 1 : 0);
    if (!count)
        return false;
    OutBuffer* s = &wmod.scratch;
    s.reset();
    s.writeuLEB128(count);
    foreach (ref const WasmFunc f; wmod.funcs[0 .. wmod.numImports])
    {
        appendName(*s, f.importModule);
        appendName(*s, f.importName);
        s.writeByte(WASM_EXPORT.FUNC); // import kind: function
        s.writeuLEB128(f.typeIdx);
    }
    if (wmod.importFuncTable)
    {
        // (import "env" "__indirect_function_table" (table 0 funcref))
        appendName(*s, "env");
        appendName(*s, "__indirect_function_table");
        s.writeByte(0x01); // import kind: table
        s.writeByte(0x70); // funcref element type
        s.writeByte(0x00); // limits: no max
        s.writeuLEB128(0); // min size = 0 (linker sets actual size)
    }
    writeSection(out_, WASM_SECTION.import_, s);
    return true;
}

/// Returns: true if section was actually written
private bool emitFunctionSection(ref OutBuffer out_, ref WasmModule wmod)
{
    uint defined = cast(uint)(wmod.funcs.length - wmod.numImports);
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
    uint defined = cast(uint)(wmod.funcs.length - wmod.numImports);
    if (!defined)
        return false;
    OutBuffer* s = &wmod.scratch;
    s.reset();
    s.writeuLEB128(1); // 1 table
    s.writeByte(0x70); // funcref type
    s.writeByte(0x01); // has min and max (limits flag)
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
    // Always declare one page of linear memory — any function using pointers
    // or array indexing needs it, and it's harmless when unused.
    OutBuffer* s = &wmod.scratch;
    s.reset();
    s.writeuLEB128(1); // one memory
    s.writeByte(0x00); // flags: no maximum
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
        s.writeByte(g.mutable_ ? 1 : 0);

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
    ++count; // always export "memory"
    s.writeuLEB128(count);
    // Always export memory (index 0)
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
    // Data symbols referenced by code relocations.
    Symbol*[] datasymsForLinking = collectRelocDataSyms();
    symCount += cast(uint) datasymsForLinking.length;

    // One TABLE symbol for the function table (defined or imported).
    const bool hasTable = !wmod.importFuncTable &&
        (wmod.funcs.length > wmod.numImports);
    const bool hasImportedTable = wmod.importFuncTable;
    if (hasTable || hasImportedTable)
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

    // Add WASM_SYMTAB.DATA entries for all globally-referenced data symbols.
    // These are needed so R_WASM.MEMORY_ADDR_LEB relocations in reloc.CODE can
    // reference them by symbol index for wasm-ld to patch after data relocation.
    foreach (Symbol* sym; datasymsForLinking)
    {
        symtab.writeByte(WASM_SYMTAB.DATA);
        // Use local binding so same-named temporaries in different objects don't conflict.
        symtab.writeuLEB128(WASM_SYM.BINDING_LOCAL | WASM_SYM.EXPLICIT_NAME);
        appendName(symtab, sym.identifier);
        // Data symbol payload: segment index (0), offset in segment, size.
        // sym.Soffset is the linear memory address (including the null-pointer slot
        // at 0..ds.offset-1).  The segment-relative offset subtracts the segment's
        // own start address so wasm-ld computes: final_addr = segment_base + seg_off.
        const uint dsBase = wmod.dataSegs.length ? wmod.dataSegs[0].offset : 4;
        const uint segOff = sym.Soffset > dsBase ? cast(uint)(sym.Soffset - dsBase) : 0;
        // Real symbol size if available (needed by --gc-sections / wasm-ld bounds
        // checks). type_size returns the type size in bytes; for symbols whose
        // type is unset, fall back to 0 (interpreted as opaque by wasm-ld).
        uint symSize = 0;
        if (sym.Stype)
        {
            const ts = type_size(sym.Stype);
            if (ts <= uint.max)
                symSize = cast(uint) ts;
        }
        symtab.writeuLEB128(0); // segment index (single data seg)
        symtab.writeuLEB128(segOff); // offset within segment
        symtab.writeuLEB128(symSize); // size in bytes
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

    // Compute the data section payload prefix size:
    // [count=1 ULEB] + [seg_kind=0] + [i32.const=0x41] + [offset=4 ULEB] + [end=0x0B]
    //   + [seg_size ULEB]
    uint segSize = cast(uint) wmod.dataSegs[0].data.length();
    uint dataSectionPrefix = 1 + 1 + 1 + ulebSize(4) + 1 + ulebSize(segSize);

    // Two-pass: first count valid relocs, then write them.
    uint relCount = 0;
    foreach (ref WasmModule.FuncReloc rel; wmod.funcRelocations)
    {
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
        payload.writeuLEB128(dataSectionPrefix + rel.dataByteOffset);
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

    // Build ordered list of referenced data symbols and their symbol-table indices.
    // Data symbols follow function symbols in the linking symbol table.
    // We collect unique data symbols in the order first encountered.
    Symbol*[] datasyms;
    void collectDataSyms(const WasmFuncBody.DataAddrReloc[] relocs)
    {
        foreach (ref const r; relocs)
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

    foreach (ref const WasmFuncBody fb; wasmFuncBodies)
        collectDataSyms(fb.dataAddrRelocs);

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
                import core.stdc.string : strlen;
                const(char)[] rname = r.sym.Sident.ptr[0 .. strlen(r.sym.Sident.ptr)];
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
            uint fi = currentFuncIdx(r);
            if (r.type == R_WASM.TYPE_INDEX_LEB)
            {
                // Type relocs reference the type section directly; r.symIdx
                // holds the funcIdx whose type we want to import-merge against.
                if (fi >= wmod.funcs.length)
                    continue;
                idx = wmod.funcs[fi].typeIdx;
            }
            else
            {
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
        // Reorder type table so import types come first — this must happen
        // between phase 1 and phase 2 so that code generation uses the
        // correct post-reorder type indices in call_indirect instructions.
        wmod.reorderImportTypesFirst();

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

    // Patch deferred relocations in the data segment.
    if (wmod.dataSegs.length > 0)
    {
        ubyte[] dataBuf = cast(ubyte[]) wmod.dataSegs[0].data.peekSlice();

        if (!wmod.relocatable)
        {
            // Final module: resolve function-pointer table indices directly.
            foreach (ref WasmModule.FuncReloc rel; wmod.funcRelocations)
            {
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
            if (rel.dataByteOffset + 4 > dataBuf.length)
                continue;
            uint addr = cast(uint)(rel.sym.Soffset + rel.addend);
            dataBuf[rel.dataByteOffset .. rel.dataByteOffset + 4] =
                (cast(ubyte*)&addr)[0 .. 4];
        }
    }

    // Finalize __stack_pointer initial value.
    // Data section occupies low addresses (0..dataHeap-1).
    // Shadow stack grows downward from 65536 (top of first 64KiB page).
    // Both fit in a single page as long as dataHeap < 65536.
    if (wmod.stackPtrGlobalIdx >= 0)
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

    // BSS allocations advance dataHeap without writing to the data segment.
    // Pad with zeros so all symbol addresses fall within the segment payload
    // wasm-ld rejects data symbols whose offset is past the segment size.
    if (wmod.dataSegs.length > 0)
    {
        auto ds = &wmod.dataSegs[0];
        uint needed = wmod.dataHeap > ds.offset ? wmod.dataHeap - ds.offset : 0;
        while (ds.data.length() < needed)
            ds.data.writeByte(0);
    }

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
    f.typeIdx = wmod.internType(ft);
    f.sym = s;
    f.exported = (s.Sclass == SC.global);
    wmod.funcs ~= f;
    s.Sseg = cast(int)(wmod.funcs.length - 1);
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

    // All data goes into a single data segment at offset wmod.dataHeap.
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

    if (wmod.dataSegs.length == 0)
    {
        wmod.dataSegs.length = 1;
        wmod.dataSegs[0].offset = 4; // reserve address 0 as null pointer
    }

    if (seg == WASM_UDATA)
    {
        // BSS: just reserve address space. WASM linear memory is zero-initialized,
        // so no bytes need to be emitted. Deactivate the data buffer so subsequent
        // lidata/write calls (which don't exist for BSS) are ignored.
        wmod.activeSeg = null;
        if (sdata)
            sdata.Soffset = base;
        wmod.dataHeap = base + cast(uint) datasize;
        return seg;
    }

    wmod.activeSeg = &wmod.dataSegs[0];

    // Write alignment padding bytes so buffer position == symbol address.
    foreach (_; wmod.dataHeap .. base)
        wmod.activeSeg.data.writeByte(0);

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
    const(char)[] id = s.Sident.ptr[0 .. strlen(s.Sident.ptr)];
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
    if (!wmod.activeSeg)
        return 4;
    // Function symbols: write 0 as placeholder; real table index patched in WasmObj_term.
    if (s && s.Stype && tyfunc(tybasic(s.Stype.Tty)))
    {
        uint dataOff = cast(uint) wmod.activeSeg.data.length;
        uint zero = 0;
        wmod.activeSeg.data.write(&zero, 4);
        wmod.funcRelocations ~= WasmModule.FuncReloc(dataOff, s);
        return 4;
    }
    // Data symbols: write linear memory address, or defer if not yet allocated.
    uint addr;
    if (s && s.Soffset == 0)
    {
        // Soffset is 0: symbol may not be allocated yet. Record deferred relocation;
        // WasmObj_term will patch with the final address (or leave as 0 if truly external).
        uint dataOff = cast(uint) wmod.activeSeg.data.length;
        uint zero = 0;
        wmod.activeSeg.data.write(&zero, 4);
        wmod.dataRelocations ~= WasmModule.DataReloc(dataOff, s, cast(uint) val);
        return 4;
    }
    addr = cast(uint)(s ? (s.Soffset + val) : val);
    wmod.activeSeg.data.write(&addr, 4);
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
uint wmod_internType(ubyte[] params, ubyte[] results)
{
    assert(wmod);

    WasmFuncType ft;
    ft.params = params;
    ft.results = results;
    return wmod.internType(ft);
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

// Add a synthesized (no-Symbol) function to the module with the given type signature.
// Returns the combined function index (numImports + body position).
// After calling, the caller must write code into wasmFuncBodies[$-1].code.
uint wmod_addDefinedFunc(string name, WasmLocal[] locals, uint numParams,
    ubyte[] params, ubyte[] results)
{
    WasmFuncType ft;
    ft.params = params.dup;
    ft.results = results.dup;
    WasmFunc f;
    f.typeIdx = wmod.internType(ft);
    f.sym = null;
    f.exported = false;
    f.name = name; // store for symbol table
    wmod.funcs ~= f;
    WasmFuncBody empty;
    empty.name = name;
    empty.locals = locals;
    empty.numParams = numParams;
    wasmFuncBodies ~= empty;
    return wmod.numImports + cast(uint)(wasmFuncBodies.length - 1);
}

// Return the index of the __stack_pointer mutable global, creating it if needed.
// Called by codgen.d when a function needs a shadow stack frame.
uint wmod_getOrCreateStackPtrGlobal()
{
    if (wmod.stackPtrGlobalIdx >= 0)
        return cast(uint) wmod.stackPtrGlobalIdx;
    WasmGlobal g;
    g.valType = WASM_I32;
    g.mutable_ = true;
    g.initVal = 65536; // placeholder; updated in WasmObj_term from dataHeap
    wmod.stackPtrGlobalIdx = cast(int) wmod.globals.length;
    wmod.globals ~= g;
    wmod.needsMemory = true; // shadow stack lives in linear memory
    return cast(uint) wmod.stackPtrGlobalIdx;
}

// Public entry point for codgen.d to allocate string data directly.
uint allocRoData_wasm(const(void)* p, uint len, uint align_)
{
    return allocRoData(p, len, align_);
}

// Allocate `len` bytes of read-only data at the next aligned offset,
// write the bytes, and return the linear memory address.
private uint allocRoData(const(void)* p, uint len, uint align_)
{
    wmod.needsMemory = true;
    if (wmod.dataSegs.length == 0)
    {
        wmod.dataSegs.length = 1;
        wmod.dataSegs[0].offset = 4; // reserve address 0 as null pointer
    }
    uint mask = align_ - 1;
    uint base = (wmod.dataHeap + mask) & ~mask;
    // Pad with zeros up to the aligned base (relative to segment start = 4)
    foreach (_; wmod.dataHeap .. base)
        wmod.dataSegs[0].data.writeByte(0);
    if (p)
        wmod.dataSegs[0].data.write(p, len);
    else
        foreach (_; 0 .. len)
            wmod.dataSegs[0].data.writeByte(0);
    wmod.dataHeap = base + len;
    wmod.activeSeg = &wmod.dataSegs[0];
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
    f.typeIdx = wmod.internType(ft);
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
