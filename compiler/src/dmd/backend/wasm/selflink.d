/**
 * Final-link mode for the WebAssembly backend.
 *
 * A relocatable object leaves memory, table, `__stack_pointer` and the element
 * segment to wasm-ld, and leaves zeros/padded LEBs behind for it to patch. When
 * `wasmSelfLink` is set the whole program is compiled as one unit instead, and
 * this module supplies what the linker would: it resolves the data and code
 * relocations in place, concatenates the per-module "minfo" segments druntime
 * scans, lays out the shadow stack and heap above the data section, and emits
 * the table, memory, global and element sections. The `linking`/`reloc.*`
 * metadata is then dropped, leaving a module a host can instantiate directly.
 *
 * Copyright:   Copyright (C) 1999-2026 by The D Language Foundation, All Rights Reserved
 * License:     $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/compiler/src/dmd/backend/wasm/selflink.d, _selflink.d)
 */

module dmd.backend.wasm.selflink;

import dmd.backend.cc;
import dmd.backend.cdef : SC;
import dmd.backend.symbol;
import dmd.backend.wasm.enums;
import dmd.backend.wasm.obj;
import dmd.backend.ty : I64;
import dmd.backend.wasm.codgen : memLimits, OP_PTR_CONST, WASM_PTR, wasmCGCtfeBuild;
import dmd.backend.wasm.util : patchLE, patchLEB;
import dmd.common.outbuffer;

nothrow:

/// Emit a complete, directly instantiable module instead of a relocatable
/// object. Set by the `-mwasm-selflink` driver switch.
__gshared bool wasmSelfLink;

/// Shadow stack reserved between the data section and the heap.
__gshared uint wasmSelfLinkStackSize = 1 << 20;

/// Base address of the data section. Non-zero places the module's data above an
/// existing image so it can share that image's memory.
__gshared uint wasmSelfLinkDataBase = 0;

/// Import linear memory from `env` instead of defining it. Set together with
/// `wasmSelfLinkDataBase` to run the module inside another module's memory,
/// which is what lets it call that module's `malloc`/`printf` with pointers the
/// callee can dereference.
__gshared bool wasmSelfLinkImportMemory = false;

/// Addresses of data symbols this compilation does not define, supplied by a
/// host that links the module against an existing image (the browser app maps
/// the snippet's `stdout`/`stderr` onto its own libc's).
__gshared uint[string] wasmSelfLinkDataSymbols;

/// Data symbols placed at `wasmSelfLinkPoisonBase` and above, beyond the most
/// the memory can grow to, so that every access to them traps while their
/// addresses can still be taken and compared. Their bytes are not emitted.
__gshared bool[string] wasmSelfLinkPoisonNames;
/// ditto
enum uint wasmSelfLinkPoisonBase = 0xF000_0000;

struct WasmDataExtent
{
    uint start;
    uint size;
    const(char)[] name;
}

/// Start, size and symbol name of each data segment `selfLink` placed, sorted by start.
__gshared WasmDataExtent[] wasmSelfLinkDataExtents;

/// Symbol name of each function, by table slot - 1, recorded by `selfLink`.
__gshared const(char)[][] wasmSelfLinkTableNames;

__gshared bool wasmSelfLinkShared;
__gshared uint wasmSelfLinkTableBase = 1;
__gshared uint[string] wasmSelfLinkSlots;
__gshared uint wasmSelfLinkPoisonNext = wasmSelfLinkPoisonBase;
__gshared uint wasmSelfLinkModuleId;
__gshared uint wasmSelfLinkDataEnd;
__gshared uint wasmSelfLinkPoisonEnd;
__gshared const(char)[][] wasmSelfLinkDefined;
__gshared WasmImportInfo[] wasmSelfLinkImports;

struct WasmImportInfo
{
    const(char)[] module_;
    const(char)[] name;
    WasmFuncType type;
    bool called;
}
__gshared uint[string] wasmSelfLinkNewData;

/// Data symbols no definition and no `wasmSelfLinkDataSymbols` entry was found
/// for; relocated to address 0. Reported by the driver once the module is done.
__gshared const(char)[][] wasmSelfLinkUnresolved;

/// Addresses the linker normally defines. Referenced from D as
/// `extern __gshared` data symbols, so they resolve through the same
/// MEMORY_ADDR relocations as ordinary globals.
private uint linkerSymbolAddr(ref WasmModule wmod, const(char)[] name)
{
    switch (name)
    {
        case "__global_base":   return wasmSelfLinkDataBase ? wasmSelfLinkDataBase : 4;
        case "__data_end":      return wmod.dataEnd;
        case "__stack_low":     return wmod.dataEnd;
        case "__stack_high":    return wmod.stackHigh;
        case "__heap_base":     return wmod.stackHigh;
        case "__heap_end":      return wmod.memPages * 65536;
        case "__start_minfo":   return wmod.minfoStart;
        case "__stop_minfo":    return wmod.minfoStop;
        default:                return uint.max;
    }
}

/// Address of a data symbol: its own segment if it has one, else the segment of
/// an identically named definition (the `extern` declaration in one module and
/// the definition in another are distinct Symbols), else a linker symbol.
private uint dataSymAddr(ref WasmModule wmod, const(Symbol)* sym, ref DataAddrIndex ix)
{
    if (!sym)
        return uint.max;
    if (auto p = sym in ix.bySym)
        return *p;
    if (sym.Sident.ptr)
    {
        const name = cast(string) sym.identifier;
        if (auto p = name in ix.byName)
            return *p;
        const uint la = linkerSymbolAddr(wmod, name);
        if (la != uint.max)
            return la;
        if (auto p = name in wasmSelfLinkDataSymbols)
            return *p;
    }
    if (sym.Soffset)
        return cast(uint) sym.Soffset;
    return uint.max;
}

struct DataAddrIndex
{
    uint[const(Symbol)*] bySym;
    uint[string] byName;
}

DataAddrIndex buildDataAddrIndex(ref WasmModule wmod)
{
    DataAddrIndex ix;
    foreach (ref const WasmDataSeg ds; wmod.dataSegs)
    {
        if (!ds.sym)
            continue;
        if (ds.sym !in ix.bySym)
            ix.bySym[ds.sym] = ds.offset;
        if (!ds.sym.Sident.ptr)
            continue;
        string name = cast(string) ds.sym.identifier;
        if (name !in ix.byName)
            ix.byName[name] = ds.offset;
    }
    return ix;
}

void noteUnresolved(const(Symbol)* sym)
{
    if (!sym || !sym.Sident.ptr)
        return;
    const name = sym.identifier;
    foreach (n; wasmSelfLinkUnresolved)
        if (n == name)
            return;
    wasmSelfLinkUnresolved ~= name;
}

private uint tableSlot(ref WasmModule wmod, const(Symbol)* sym)
{
    const uint fi = funcIdxBySymOrName(wmod, sym);
    if (fi == uint.max)
        return 0;
    if (!wasmSelfLinkShared)
        return fi + 1;
    if (wmod.slotOfFunc.length < wmod.funcs.length)
        wmod.slotOfFunc.length = wmod.funcs.length;
    if (const slot = wmod.slotOfFunc[fi])
        return slot;
    const name = cast(string) utf8SanitizeName(funcName(wmod.funcs[fi]));
    uint slot;
    if (auto p = name in wasmSelfLinkSlots)
        slot = *p;
    else
    {
        slot = wasmSelfLinkTableBase + cast(uint) wmod.slotFuncs.length;
        wmod.slotFuncs ~= fi;
    }
    wmod.slotOfFunc[fi] = slot;
    return slot;
}

private void assignCodeSlots(ref WasmModule wmod)
{
    foreach (ref fb; wasmFuncBodies)
        foreach (ref const WasmReloc r; fb.relocs)
            if (r.type == R_WASM.TABLE_INDEX_SLEB)
                tableSlot(wmod, r.sym);
}

/// Write the resolved values of the data-section relocations into the segment
/// bytes, where a relocatable object leaves zeros for wasm-ld.
private void applyDataRelocs(ref WasmModule wmod)
{
    DataAddrIndex ix = buildDataAddrIndex(wmod);
    foreach (ref WasmModule.DataReloc rel; wmod.dataRelocations)
    {
        if (rel.segIdx >= wmod.dataSegs.length)
            continue;
        ubyte[] seg = wmod.dataSegs[rel.segIdx].data.peekSlice();
        uint v;
        if (isTableIndexReloc(rel.type))
            v = tableSlot(wmod, rel.sym);
        else
        {
            const uint addr = dataSymAddr(wmod, rel.sym, ix);
            if (addr == uint.max)
                noteUnresolved(rel.sym);
            v = addr == uint.max ? 0 : addr + rel.addend;
        }
        const wide = rel.type == R_WASM.TABLE_INDEX_I64 || rel.type == R_WASM.MEMORY_ADDR_I64;
        patchLE(seg, rel.dataByteOffset, v, wide ? 8 : 4);
    }
}

/// druntime walks the ModuleInfo array between `__start_minfo` and
/// `__stop_minfo`, which wasm-ld synthesizes by concatenating the per-module
/// "minfo" segments. Those segments are interleaved with ordinary data here, so
/// gather their (already relocated) contents into one contiguous segment.
private void gatherMinfo(ref WasmModule wmod)
{
    OutBuffer* buf = new OutBuffer();
    foreach (ref WasmDataSeg ds; wmod.dataSegs)
        if (ds.name == "minfo")
            buf.write(ds.data.peekSlice());
    if (!buf.length())
        return;

    const uint base = (wmod.dataHeap + 3) & ~3;
    WasmDataSeg ds;
    ds.data = buf;
    ds.offset = base;
    ds.name = "minfo.all";
    ds.alignLog2 = 2;
    ds.reserved = cast(uint) buf.length();
    wmod.dataSegs ~= ds;
    wmod.dataHeap = base + ds.reserved;
    wmod.segOpen = false;
    wmod.minfoStart = base;
    wmod.minfoStop = base + ds.reserved;
}

/// wasm-ld synthesizes `__wasm_call_ctors` from the WASM_INIT_FUNCS entries of
/// the objects it links. Self-linking has no such step, so the stub
/// `rt.wasm.selflink` defines stays empty and `pragma(crt_constructor)`
/// functions (the GC registration among them) never run. Fill its body in with
/// a call to each of them.
private void fillCallCtors(ref WasmModule wmod)
{
    uint bodyIdx;
    if (!wmod.initFuncs.length || !lookupDefinedFuncBody("__wasm_call_ctors", bodyIdx))
        return;

    OutBuffer* code = new OutBuffer();
    foreach (Symbol* ctor; wmod.initFuncs)
    {
        const uint fi = funcIdxBySymOrName(wmod, ctor);
        if (fi == uint.max)
        {
            noteUnresolved(ctor);
            continue;
        }
        code.writeByte(OP.CALL);
        code.writeuLEB128(fi);
    }

    WasmFuncBody* fb = &wasmFuncBodies[bodyIdx];
    fb.code = code;
    fb.relocs = null;
    fb.locals = fb.locals[0 .. fb.numParams];
}

private void computeLayout(ref WasmModule wmod)
{
    wmod.dataEnd = (wmod.dataHeap + 15) & ~15;
    wasmSelfLinkDataEnd = wmod.dataEnd;
    wasmSelfLinkPoisonEnd = wmod.poisonHeap;
    wmod.stackHigh = wmod.dataEnd + wasmSelfLinkStackSize;
    // A page of headroom above the heap base so a module that never grows
    // memory still has somewhere to put its first allocation.
    wmod.memPages = (wmod.stackHigh + 65535) / 65536 + 1;
}

/// Turn the relocatable object into a self-contained module: resolve the data
/// relocations, lay out the shadow stack and heap, and record the addresses the
/// code relocations will be patched with in `emitCodeSection`.
void selfLink(ref WasmModule wmod)
{
    applyDataRelocs(wmod);
    fillCallCtors(wmod);
    gatherMinfo(wmod);
    computeLayout(wmod);
    if (wasmSelfLinkShared)
    {
        assignCodeSlots(wmod);
        wasmSelfLinkTableNames = new const(char)[][](wmod.slotFuncs.length);
        foreach (i, fi; wmod.slotFuncs)
            wasmSelfLinkTableNames[i] = utf8SanitizeName(funcName(wmod.funcs[fi])).idup;
        wasmSelfLinkNewData = null;
        foreach (ref const WasmDataSeg ds; wmod.dataSegs)
            if (!ds.dup && ds.sym && ds.sym.Sident.ptr && (ds.sym.Sclass == SC.global || ds.sym.Sclass == SC.comdat))
                if (cast(string) ds.sym.identifier !in wasmSelfLinkNewData)
                    wasmSelfLinkNewData[ds.sym.identifier.idup] = ds.offset;
    }
    else
    {
        wasmSelfLinkTableNames = new const(char)[][](wmod.funcs.length);
        foreach (i, ref f; wmod.funcs)
            if (f.sym && f.sym.Sident.ptr)
                wasmSelfLinkTableNames[i] = f.sym.identifier.idup;
    }
    wasmSelfLinkDataExtents = null;
    foreach (ref const WasmDataSeg ds; wmod.dataSegs)
        if (ds.data && ds.data.length && !ds.dup)
            wasmSelfLinkDataExtents ~= WasmDataExtent(ds.offset, cast(uint) ds.data.length,
                ds.sym && ds.sym.Sident.ptr ? ds.sym.identifier.idup : null);
    {
        import core.stdc.stdlib : qsort;
        extern (C) static int cmp(scope const void* a, scope const void* b)
        {
            const x = (cast(const WasmDataExtent*) a).start, y = (cast(const WasmDataExtent*) b).start;
            return x < y ? -1 : x > y;
        }
        qsort(wasmSelfLinkDataExtents.ptr, wasmSelfLinkDataExtents.length, WasmDataExtent.sizeof, &cmp);
    }
}

/// Resolve the code relocations a relocatable object leaves to wasm-ld.
/// `FUNCTION_INDEX_LEB` is already patched by the caller, and `TYPE_INDEX_LEB`,
/// `GLOBAL_INDEX_LEB`, `TABLE_NUMBER_LEB` and `TAG_INDEX_LEB` already hold the
/// index they need (there is exactly one table, one global and one tag). That
/// leaves function-pointer constants and the addresses of data symbols that
/// this module does not itself define.
void patchSelfLinkCodeRelocs(ref WasmModule wmod, ref WasmFuncBody fb, ubyte[] code, ref DataAddrIndex ix)
{
    const uint n = I64() ? 10 : 5;
    foreach (ref const WasmReloc r; fb.relocs)
    {
        if (r.type == R_WASM.TABLE_INDEX_SLEB)
            patchLEB(code, r.offset, tableSlot(wmod, r.sym), n);
        else if (r.type == R_WASM.MEMORY_ADDR_LEB)
        {
            const uint addr = dataSymAddr(wmod, r.sym, ix);
            if (addr == uint.max)
                noteUnresolved(r.sym);
            else if (!I64() && r.offset && code[r.offset - 1] == OP.I32_CONST)
                patchLEB(code, r.offset, cast(int)(addr + r.addend), n);
            else
                patchLEB(code, r.offset, addr + r.addend, n);
        }
    }
}

/// Table section (id 4): the indirect function table wasm-ld would import.
/// Slot 0 is left empty so a null function pointer traps instead of calling
/// whatever happens to be function 0.
void emitTableSection(ref OutBuffer out_, ref WasmModule wmod)
{
    OutBuffer* s = &wmod.scratch;
    s.reset();
    s.writeuLEB128(1);
    s.writeByte(WASM_REFTYPE.FUNCREF);
    s.writeByte(WASM_LIMITS.HAS_MAX);
    const uint n = cast(uint)(wmod.funcs.length + 1);
    s.writeuLEB128(n);
    s.writeuLEB128(n);
    writeSection(out_, WASM_SECTION.table, s);
}

void emitMemorySection(ref OutBuffer out_, ref WasmModule wmod)
{
    OutBuffer* s = &wmod.scratch;
    s.reset();
    s.writeuLEB128(1);
    s.writeByte(memLimits(wasmCGCtfeBuild));
    s.writeuLEB128(wmod.memPages);
    if (wasmCGCtfeBuild)
        s.writeuLEB128(wasmSelfLinkPoisonBase >> 16);
    writeSection(out_, WASM_SECTION.memory, s);
}

/// Global section (id 6): `__stack_pointer` only, at index 0 — the index the
/// GLOBAL_INDEX_LEB placeholders already carry.
void emitGlobalSection(ref OutBuffer out_, ref WasmModule wmod)
{
    OutBuffer* s = &wmod.scratch;
    s.reset();
    s.writeuLEB128(1);
    s.writeByte(WASM_PTR);
    s.writeByte(WASM_MUT.VAR);
    s.writeByte(OP_PTR_CONST);
    s.writesLEB128(cast(int) wmod.stackHigh);
    s.writeByte(OP.END);
    writeSection(out_, WASM_SECTION.global, s);
}

/// Element section (id 9): identity mapping of table slot `i + 1` onto function
/// `i`, matching the `funcIdx + 1` written into the TABLE_INDEX relocations.
void emitElemSection(ref OutBuffer out_, ref WasmModule wmod)
{
    if (wasmSelfLinkShared ? !wmod.slotFuncs.length : !wmod.funcs.length)
        return;
    OutBuffer* s = &wmod.scratch;
    s.reset();
    s.writeuLEB128(1);
    s.writeuLEB128(0);
    s.writeByte(OP.I32_CONST);
    s.writesLEB128(wasmSelfLinkShared ? cast(int) wasmSelfLinkTableBase : 1);
    s.writeByte(OP.END);
    if (wasmSelfLinkShared)
    {
        s.writeuLEB128(cast(uint) wmod.slotFuncs.length);
        foreach (fi; wmod.slotFuncs)
            s.writeuLEB128(fi);
        writeSection(out_, WASM_SECTION.element, s);
        return;
    }
    s.writeuLEB128(cast(uint) wmod.funcs.length);
    foreach (uint i; 0 .. cast(uint) wmod.funcs.length)
        s.writeuLEB128(i);
    writeSection(out_, WASM_SECTION.element, s);
}
