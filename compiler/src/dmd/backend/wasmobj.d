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

import core.stdc.string : strlen, strcmp;

import dmd.backend.cc;
import dmd.backend.cdef;
import dmd.backend.code;
import dmd.backend.el;
import dmd.backend.obj;
import dmd.backend.ty;
import dmd.backend.type;

import dmd.common.outbuffer;

// Segment indices used by the backend (must match cdef.d enum segfl_t values)
private enum : int
{
    WASM_CODE = 1,
    WASM_DATA = 2,
    WASM_CDATA = 3,
    WASM_UDATA = 4
}

// Allocate a seg_data entry in SegData at the given index
private void pushSegData(int idx) nothrow @trusted
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

// ---------------------------------------------------------------------------
// WASM binary encoding constants
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// LEB128 encoding helpers
// ---------------------------------------------------------------------------

// Append unsigned LEB128
private void appendULEB128(OutBuffer* buf, uint val) @trusted
{
    do
    {
        ubyte b = val & 0x7F;
        val >>= 7;
        if (val != 0)
            b |= 0x80;
        buf.writeByte(b);
    }
    while (val != 0);
}

// Append a name string (length-prefixed)
private void appendName(OutBuffer* buf, const(char)[] name) @trusted
{
    appendULEB128(buf, cast(uint) name.length);
    buf.write(name.ptr[0 .. name.length]);
}

// ---------------------------------------------------------------------------
// Data structures
// ---------------------------------------------------------------------------

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
}

// Local variable in a WASM function
struct WasmLocal
{
    Symbol* sym; // null for anonymous temporaries
    ubyte ty; // WASM value type
}

// Generated code body for a defined function
struct WasmFuncBody
{
    Symbol* sym;
    WasmLocal[] locals;
    uint numParams;
    OutBuffer code; // WASM bytecode (without local decls header)
}

// Module-global table of function bodies (indexed same as WasmFunc)
__gshared WasmFuncBody[] wasmFuncBodies;

// Data segment (initialized global data)
struct WasmDataSeg
{
    uint offset; // linear memory offset
    OutBuffer data; // raw bytes
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
    bool needsMemory; // true if any data segments exist
    uint dataHeap; // next free byte offset in linear memory

    // Scratch OutBuffer for section payloads
    OutBuffer scratch;

nothrow:

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

// ---------------------------------------------------------------------------
// Global module instance (one per compilation unit)
// ---------------------------------------------------------------------------

private WasmModule* wmod;

// ---------------------------------------------------------------------------
// WASM value type for a backend type
// ---------------------------------------------------------------------------

private ubyte wasmValType(tym_t ty) @trusted
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
        return WASM_I32;

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
        return WASM_I32; // aggregate / unknown: pass by pointer
    }
}

// Build a WasmFuncType from a backend function type
private WasmFuncType buildFuncType(type* t) @trusted
{
    WasmFuncType ft;

    // Parameters
    param_t* p = t.Tparamtypes;
    while (p)
    {
        if (p.Ptype && tybasic(p.Ptype.Tty) != TYvoid)
            ft.params ~= wasmValType(p.Ptype.Tty);
        p = p.Pnext;
    }

    // Return type
    type* ret = t.Tnext;
    if (ret && tybasic(ret.Tty) != TYvoid)
        ft.results ~= wasmValType(ret.Tty);

    return ft;
}

// ---------------------------------------------------------------------------
// Section writers
// ---------------------------------------------------------------------------

private void writeSection(OutBuffer* out_, WasmSection id, OutBuffer* payload) @trusted
{
    out_.writeByte(cast(ubyte) id);
    appendULEB128(out_, cast(uint) payload.length());
    out_.write(payload.peekSlice());
}

private void emitTypeSection(OutBuffer* out_) @trusted
{
    OutBuffer* s = &wmod.scratch;
    s.reset();
    appendULEB128(s, cast(uint) wmod.funcTypes.length);
    foreach (ref const WasmFuncType ft; wmod.funcTypes)
    {
        s.writeByte(0x60); // func type indicator
        appendULEB128(s, cast(uint) ft.params.length);
        foreach (ubyte v; ft.params)
            s.writeByte(v);
        appendULEB128(s, cast(uint) ft.results.length);
        foreach (ubyte v; ft.results)
            s.writeByte(v);
    }
    if (wmod.funcTypes.length)
        writeSection(out_, WasmSection.type_, s);
}

private void emitImportSection(OutBuffer* out_) @trusted
{
    if (!wmod.numImports)
        return;
    OutBuffer* s = &wmod.scratch;
    s.reset();
    appendULEB128(s, wmod.numImports);
    foreach (ref const WasmFunc f; wmod.funcs[0 .. wmod.numImports])
    {
        appendName(s, f.importModule);
        appendName(s, f.importName);
        s.writeByte(WASM_EXPORT_FUNC); // import kind: function
        appendULEB128(s, f.typeIdx);
    }
    writeSection(out_, WasmSection.import_, s);
}

private void emitFunctionSection(OutBuffer* out_) @trusted
{
    uint defined = cast(uint)(wmod.funcs.length - wmod.numImports);
    if (!defined)
        return;
    OutBuffer* s = &wmod.scratch;
    s.reset();
    appendULEB128(s, defined);
    foreach (ref const WasmFunc f; wmod.funcs[wmod.numImports .. $])
        appendULEB128(s, f.typeIdx);
    writeSection(out_, WasmSection.function_, s);
}

private void emitMemorySection(OutBuffer* out_) @trusted
{
    if (!wmod.needsMemory)
        return;
    OutBuffer* s = &wmod.scratch;
    s.reset();
    appendULEB128(s, 1); // one memory
    s.writeByte(0x00); // flags: no maximum
    appendULEB128(s, wmod.memoryPageCount ? wmod.memoryPageCount : 1);
    writeSection(out_, WasmSection.memory, s);
}

private void emitExportSection(OutBuffer* out_) @trusted
{
    OutBuffer* s = &wmod.scratch;
    s.reset();
    uint count = 0;
    foreach (ref const WasmFunc f; wmod.funcs)
    {
        if (f.exported)
            ++count;
    }
    if (!count)
        return;
    appendULEB128(s, count);
    foreach (size_t i, ref const WasmFunc f; wmod.funcs)
    {
        if (!f.exported)
            continue;
        const(char)[] name = f.sym ? f.sym.Sident.ptr[0 .. strlen(f.sym.Sident.ptr)] : f.importName;
        appendName(s, name);
        s.writeByte(WASM_EXPORT_FUNC);
        appendULEB128(s, cast(uint) i);
    }
    writeSection(out_, WasmSection.export_, s);
}

private void emitCodeSection(OutBuffer* out_) @trusted
{
    uint defined = cast(uint)(wmod.funcs.length - wmod.numImports);
    if (!defined)
        return;
    OutBuffer* s = &wmod.scratch;
    s.reset();
    appendULEB128(s, defined);

    foreach (size_t fi, ref const WasmFunc f; wmod.funcs[wmod.numImports .. $])
    {
        // Find the matching WasmFuncBody (if any)
        WasmFuncBody* fb = null;
        foreach (ref WasmFuncBody b; wasmFuncBodies)
            if (b.sym == f.sym)
            {
                fb = &b;
                break;
            }

        OutBuffer body_;

        if (fb && fb.code.length())
        {
            // Emit local variable declarations (non-parameter locals only)
            uint numLocals = cast(uint)(fb.locals.length - fb.numParams);
            appendULEB128(&body_, numLocals);
            foreach (ref const WasmLocal l; fb.locals[fb.numParams .. $])
            {
                appendULEB128(&body_, 1); // count of this type
                body_.writeByte(l.ty);
            }
            // Append the generated bytecode
            body_.write(fb.code.peekSlice());
        }
        else
        {
            // No codegen result: emit unreachable stub
            appendULEB128(&body_, 0); // 0 locals
            body_.writeByte(WASM_UNREACHABLE);
        }
        body_.writeByte(WASM_END);

        appendULEB128(s, cast(uint) body_.length());
        s.write(body_.peekSlice());
    }
    writeSection(out_, WasmSection.code, s);
}

private void emitDataSection(OutBuffer* out_) @trusted
{
    if (!wmod.dataSegs.length)
        return;
    OutBuffer* s = &wmod.scratch;
    s.reset();
    appendULEB128(s, cast(uint) wmod.dataSegs.length);
    foreach (ref WasmDataSeg ds; wmod.dataSegs)
    {
        s.writeByte(0x00); // active segment, memory 0
        // offset initializer: i32.const <offset> end
        s.writeByte(0x41); // i32.const
        appendULEB128(s, ds.offset);
        s.writeByte(WASM_END);
        appendULEB128(s, cast(uint) ds.data.length());
        s.write(ds.data.peekSlice());
    }
    writeSection(out_, WasmSection.data, s);
}

// ---------------------------------------------------------------------------
// Obj interface implementation
// ---------------------------------------------------------------------------

Obj WasmObj_init(OutBuffer* objbuf, const(char)* filename, const(char)* csegname) @trusted
{
    wmod = new WasmModule();
    wmod.objbuf = objbuf;
    wasmFuncBodies = null;

    // Initialize the SegData array with placeholder entries for the standard
    // segment indices (CODE=1, DATA=2, CDATA=3, UDATA=4) so the backend's
    // segment-offset bookkeeping doesn't crash.
    SegData.reset();
    SegData.push(); // index 0 reserved
    pushSegData(WASM_UDATA); // push indices 1-4

    return new Obj();
}

void WasmObj_initfile(const(char)* filename, const(char)* csegname, const(char)* modname) @trusted
{
}

void WasmObj_termfile() @trusted
{
}

void WasmObj_term(const(char)[] objfilename) @trusted
{
    OutBuffer* out_ = wmod.objbuf;

    // WASM magic + version
    out_.writeByte(WASM_MAGIC_0);
    out_.writeByte(WASM_MAGIC_1);
    out_.writeByte(WASM_MAGIC_2);
    out_.writeByte(WASM_MAGIC_3);
    out_.writeByte(WASM_VERSION_0);
    out_.writeByte(WASM_VERSION_1);
    out_.writeByte(WASM_VERSION_2);
    out_.writeByte(WASM_VERSION_3);

    emitTypeSection(out_);
    emitImportSection(out_);
    emitFunctionSection(out_);
    emitMemorySection(out_);
    emitExportSection(out_);
    emitCodeSection(out_);
    emitDataSection(out_);

    wmod = null;
}

void WasmObj_linnum(Srcpos srcpos, int seg, targ_size_t offset) @trusted
{
}

int WasmObj_codeseg(const char* name, int suffix) @trusted
{
    return 0;
}

void WasmObj_startaddress(Symbol* s) @trusted
{
}

bool WasmObj_includelib(scope const(char)[] name) @trusted
{
    return false;
}

bool WasmObj_linkerdirective(scope const(char)* p) @trusted
{
    return false;
}

bool WasmObj_allowZeroSize() @trusted
{
    return true;
}

void WasmObj_exestr(const(char)* p) @trusted
{
}

void WasmObj_user(const(char)* p) @trusted
{
}

void WasmObj_compiler(const(char)* p) @trusted
{
}

void WasmObj_wkext(Symbol* s1, Symbol* s2) @trusted
{
}

void WasmObj_alias(const(char)* n1, const(char)* n2) @trusted
{
}

void WasmObj_staticctor(Symbol* s, int dtor, int seg) @trusted
{
}

void WasmObj_staticdtor(Symbol* s) @trusted
{
}

void WasmObj_setModuleCtorDtor(Symbol* s, bool isCtor) @trusted
{
}

void WasmObj_ehtables(Symbol* sfunc, uint size, Symbol* ehsym) @trusted
{
}

void WasmObj_ehsections() @trusted
{
}

void WasmObj_moduleinfo(Symbol* scc) @trusted
{
}

int WasmObj_comdat(Symbol* s) @trusted
{
    if (!s || !s.Stype)
        return 0;
    // Register a defined function
    WasmFuncType ft;
    if (tybasic(s.Stype.Tty) != TYvoid)
        ft = buildFuncType(s.Stype);
    WasmFunc f;
    f.typeIdx = wmod.internType(ft);
    f.sym = s;
    f.exported = (s.Sclass == SC.global);
    wmod.funcs ~= f;
    s.Sseg = cast(int)(wmod.funcs.length - 1);
    return s.Sseg;
}

int WasmObj_comdatsize(Symbol* s, targ_size_t symsize) @trusted
{
    return WasmObj_comdat(s);
}

void WasmObj_setcodeseg(int seg) @trusted
{
}

seg_data* WasmObj_tlsseg() @trusted
{
    // WASM MVP has no TLS; map thread-local storage to the data segment
    return SegData[WASM_DATA];
}

seg_data* WasmObj_tlsseg_bss() @trusted
{
    return SegData[WASM_UDATA];
}

seg_data* WasmObj_tlsseg_data() @trusted
{
    return SegData[WASM_DATA];
}

void WasmObj_export_symbol(Symbol* s, uint argsize) @trusted
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

void WasmObj_pubdef(int seg, Symbol* s, targ_size_t offset) @trusted
{
    WasmObj_export_symbol(s, 0);
}

void WasmObj_pubdefsize(int seg, Symbol* s, targ_size_t offset, targ_size_t symsize) @trusted
{
    WasmObj_export_symbol(s, 0);
}

int WasmObj_external_def(const(char)* name) @trusted
{
    return 0;
}

int WasmObj_data_start(Symbol* sdata, targ_size_t datasize, int seg) @trusted
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
    wmod.dataHeap = (wmod.dataHeap + mask) & ~mask;

    // Assign this symbol's linear memory address.
    if (sdata)
        sdata.Soffset = wmod.dataHeap;

    if (wmod.dataSegs.length == 0)
    {
        wmod.dataSegs.length = 1;
        wmod.dataSegs[0].offset = 0;
    }
    wmod.activeSeg = &wmod.dataSegs[0];
    wmod.dataHeap += cast(uint) datasize;
    return 1;
}

int WasmObj_external(Symbol* s) @trusted
{
    if (!s || !s.Stype)
        return 0;
    // Register as an import (env.name)
    WasmFuncType ft;
    if (tybasic(s.Stype.Tty) != TYvoid)
        ft = buildFuncType(s.Stype);
    WasmFunc f;
    f.typeIdx = wmod.internType(ft);
    f.sym = s;
    const(char)[] id = s.Sident.ptr[0 .. strlen(s.Sident.ptr)];
    f.importModule = "env";
    f.importName = id;
    f.isImport = true;
    // Imports must come before defined functions; insert at numImports position
    wmod.funcs = wmod.funcs[0 .. wmod.numImports] ~ [f] ~ wmod.funcs[wmod.numImports .. $];
    s.Sseg = cast(int) wmod.numImports;
    wmod.numImports++;
    return s.Sseg;
}

int WasmObj_common_block(Symbol* s, targ_size_t size, targ_size_t count) @trusted
{
    return 0;
}

int WasmObj_common_block(Symbol* s, int flag, targ_size_t size, targ_size_t count) @trusted
{
    return 0;
}

void WasmObj_lidata(int seg, targ_size_t offset, targ_size_t count) @trusted
{
    if (!wmod.activeSeg)
        return;
    foreach (_; 0 .. count)
        wmod.activeSeg.data.writeByte(0);
}

void WasmObj_write_zeros(seg_data* pseg, targ_size_t count) @trusted
{
    if (!wmod.activeSeg)
        return;
    foreach (_; 0 .. count)
        wmod.activeSeg.data.writeByte(0);
}

void WasmObj_write_byte(seg_data* pseg, uint _byte) @trusted
{
    if (wmod.activeSeg)
        wmod.activeSeg.data.writeByte(cast(ubyte) _byte);
}

void WasmObj_write_bytes(seg_data* pseg, const(void[]) a) @trusted
{
    if (wmod.activeSeg)
        wmod.activeSeg.data.write(a.ptr, a.length);
}

void WasmObj_byte(int seg, targ_size_t offset, uint _byte) @trusted
{
    if (wmod.activeSeg)
        wmod.activeSeg.data.writeByte(cast(ubyte) _byte);
}

size_t WasmObj_bytes(int seg, targ_size_t offset, size_t nbytes, const(void)* p) @trusted
{
    if (wmod.activeSeg && p)
        wmod.activeSeg.data.write(p, nbytes);
    return nbytes;
}

void WasmObj_reftodatseg(int seg, targ_size_t offset, targ_size_t val, uint targetdatum, int flags) @trusted
{
}

void WasmObj_reftocodeseg(int seg, targ_size_t offset, targ_size_t val) @trusted
{
}

int WasmObj_reftoident(int seg, targ_size_t offset, Symbol* s, targ_size_t val, int flags) @trusted
{
    return 0;
}

void WasmObj_far16thunk(Symbol* s) @trusted
{
}

void WasmObj_fltused() @trusted
{
}

// Public entry point for codgen.d to allocate string data directly.
uint allocRoData_wasm(const(void)* p, uint len, uint align_) @trusted
{
    return allocRoData(p, len, align_);
}

// Allocate `len` bytes of read-only data at the next aligned offset,
// write the bytes, and return the linear memory address.
private uint allocRoData(const(void)* p, uint len, uint align_) @trusted
{
    wmod.needsMemory = true;
    if (wmod.dataSegs.length == 0)
    {
        wmod.dataSegs.length = 1;
        wmod.dataSegs[0].offset = 0;
    }
    uint mask = align_ - 1;
    uint base = (wmod.dataHeap + mask) & ~mask;
    // Pad with zeros up to the aligned base
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

int WasmObj_data_readonly(char* p, int len, int* pseg) @trusted
{
    uint align_ = len >= 8 ? 8 : len >= 4 ? 4 : len >= 2 ? 2 : 1;
    uint off = allocRoData(p, len, align_);
    if (pseg)
        *pseg = 1;
    return cast(int) off;
}

int WasmObj_data_readonly(char* p, int len) @trusted
{
    int pseg;
    return WasmObj_data_readonly(p, len, &pseg);
}

int WasmObj_string_literal_segment(uint sz) @trusted
{
    // Return UNKNOWN so outdata() routes the string symbol through DATA.
    return UNKNOWN;
}

Symbol* WasmObj_sym_cdata(tym_t ty, char* p, int len) @trusted
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

void WasmObj_func_start(Symbol* sfunc) @trusted
{
    if (!sfunc || !sfunc.Stype)
        return;
    WasmFuncType ft = buildFuncType(sfunc.Stype);
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

void WasmObj_func_term(Symbol* sfunc) @trusted
{
    import dmd.backend.wasm.codgen : wasm_codgen;

    if (sfunc)
        wasm_codgen(sfunc);
}

void WasmObj_write_pointerRef(Symbol* s, uint off) @trusted
{
}

int WasmObj_jmpTableSegment(Symbol* s) @trusted
{
    return 0;
}

Symbol* WasmObj_tlv_bootstrap() @trusted
{
    return null;
}

void WasmObj_gotref(Symbol* s) @trusted
{
}

Symbol* WasmObj_getGOTsym() @trusted
{
    return null;
}

void WasmObj_refGOTsym() @trusted
{
}
