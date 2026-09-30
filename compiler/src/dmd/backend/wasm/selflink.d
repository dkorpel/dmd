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
import dmd.backend.symbol;
import dmd.backend.wasm.enums;
import dmd.backend.wasm.obj;
import dmd.backend.ty : I64;
import dmd.backend.wasm.util : patchLE32, patchLE64, patchLEB5, patchLEB10;
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
        case "__heap_base":     return wmod.heapBase;
        case "__heap_end":      return wmod.memPages * 65536;
        case "__start_minfo":   return wmod.minfoStart;
        case "__stop_minfo":    return wmod.minfoStop;
        default:                return uint.max;
    }
}

/// Address of a data symbol: its own segment if it has one, else the segment of
/// an identically named definition (the `extern` declaration in one module and
/// the definition in another are distinct Symbols), else a linker symbol.
private uint dataSymAddr(ref WasmModule wmod, const(Symbol)* sym, ref uint[string] byName)
{
    if (!sym)
        return uint.max;
    foreach (ref const WasmDataSeg ds; wmod.dataSegs)
        if (ds.sym is sym)
            return ds.offset;
    if (sym.Sident.ptr)
    {
        if (auto p = cast(string) sym.identifier in byName)
            return *p;
        const uint la = linkerSymbolAddr(wmod, sym.identifier);
        if (la != uint.max)
            return la;
        if (auto p = cast(string) sym.identifier in wasmSelfLinkDataSymbols)
            return *p;
    }
    if (sym.Soffset)
        return cast(uint) sym.Soffset;
    return uint.max;
}

uint[string] buildDataAddrByName(ref WasmModule wmod)
{
    uint[string] byName;
    foreach (ref const WasmDataSeg ds; wmod.dataSegs)
    {
        if (!ds.sym || !ds.sym.Sident.ptr)
            continue;
        string name = cast(string) ds.sym.identifier;
        if (name !in byName)
            byName[name] = ds.offset;
    }
    return byName;
}

void noteUnresolved(const(Symbol)* sym)
{
    if (!sym || !sym.Sident.ptr)
        return;
    foreach (n; wasmSelfLinkUnresolved)
        if (n == sym.identifier)
            return;
    wasmSelfLinkUnresolved ~= sym.identifier;
}

/// Write the resolved values of the data-section relocations into the segment
/// bytes, where a relocatable object leaves zeros for wasm-ld.
private void applyDataRelocs(ref WasmModule wmod)
{
    uint[string] byName = buildDataAddrByName(wmod);
    foreach (ref WasmModule.DataReloc rel; wmod.dataRelocations)
    {
        if (rel.segIdx >= wmod.dataSegs.length)
            continue;
        ubyte[] seg = wmod.dataSegs[rel.segIdx].data.peekSlice();
        const bool wide = rel.type == R_WASM.TABLE_INDEX_I64 || rel.type == R_WASM.MEMORY_ADDR_I64;
        if (rel.type == R_WASM.TABLE_INDEX_I32 || rel.type == R_WASM.TABLE_INDEX_I64)
        {
            const uint fi = funcIdxBySymOrName(wmod, rel.sym);
            const uint v = fi == uint.max ? 0 : fi + 1;
            if (wide)
                patchLE64(seg, rel.dataByteOffset, v);
            else
                patchLE32(seg, rel.dataByteOffset, v);
        }
        else
        {
            const uint addr = dataSymAddr(wmod, rel.sym, byName);
            if (addr == uint.max)
                noteUnresolved(rel.sym);
            const uint v = addr == uint.max ? 0 : addr + rel.addend;
            if (wide)
                patchLE64(seg, rel.dataByteOffset, v);
            else
                patchLE32(seg, rel.dataByteOffset, v);
        }
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
    if (!wmod.initFuncs.length)
        return;

    uint idx = uint.max;
    foreach (i; wmod.numImports .. wmod.funcs.length)
    {
        const Symbol* fs = wmod.funcs[i].sym;
        if (fs && fs.Sident.ptr && fs.identifier == "__wasm_call_ctors")
        {
            idx = cast(uint) i;
            break;
        }
    }
    if (idx == uint.max)
        return;
    const size_t bodyIdx = idx - wmod.numImports;
    if (bodyIdx >= wasmFuncBodies.length)
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
    wmod.stackHigh = wmod.dataEnd + wasmSelfLinkStackSize;
    wmod.heapBase = wmod.stackHigh;
    // A page of headroom above the heap base so a module that never grows
    // memory still has somewhere to put its first allocation.
    wmod.memPages = (wmod.heapBase + 65535) / 65536 + 1;
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
    wasmSelfLinkTableNames = new const(char)[][](wmod.funcs.length);
    foreach (i, ref f; wmod.funcs)
        if (f.sym && f.sym.Sident.ptr)
            wasmSelfLinkTableNames[i] = f.sym.identifier.idup;
    wasmSelfLinkDataExtents = null;
    foreach (ref const WasmDataSeg ds; wmod.dataSegs)
        if (ds.data && ds.data.length)
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
void patchSelfLinkCodeRelocs(ref WasmModule wmod, ref WasmFuncBody fb, ubyte[] code, uint[string] byName)
{
    foreach (ref const WasmReloc r; fb.relocs)
    {
        if (r.type == R_WASM.TABLE_INDEX_SLEB)
        {
            const uint fi = funcIdxBySymOrName(wmod, r.sym);
            const uint v = fi == uint.max ? 0 : fi + 1;
            if (I64())
                patchLEB10(code, r.offset, v);
            else
                patchLEB5(code, r.offset, v);
        }
        else if (r.type == R_WASM.MEMORY_ADDR_LEB)
        {
            const uint addr = dataSymAddr(wmod, r.sym, byName);
            if (addr == uint.max)
                noteUnresolved(r.sym);
            else if (I64())
                patchLEB10(code, r.offset, addr + r.addend);
            else if (r.offset && code[r.offset - 1] == OP.I32_CONST)
                patchLEB5(code, r.offset, cast(int)(addr + r.addend));
            else
                patchLEB5(code, r.offset, addr + r.addend);
        }
    }
}

/// Table section (id 4): the indirect function table wasm-ld would import.
/// Slot 0 is left empty so a null function pointer traps instead of calling
/// whatever happens to be function 0.
bool emitTableSection(ref OutBuffer out_, ref WasmModule wmod)
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
    return true;
}

bool emitMemorySection(ref OutBuffer out_, ref WasmModule wmod)
{
    OutBuffer* s = &wmod.scratch;
    s.reset();
    s.writeuLEB128(1);
    import dmd.backend.wasm.codgen : wasmCGCtfeBuild;
    if (wasmCGCtfeBuild)
        s.writeByte(I64() ? WASM_LIMITS.MEM64_HAS_MAX : WASM_LIMITS.HAS_MAX);
    else
        s.writeByte(I64() ? WASM_LIMITS.MEM64_NO_MAX : WASM_LIMITS.NO_MAX);
    s.writeuLEB128(wmod.memPages);
    if (wasmCGCtfeBuild)
        s.writeuLEB128(wasmSelfLinkPoisonBase >> 16);
    writeSection(out_, WASM_SECTION.memory, s);
    return true;
}

/// Global section (id 6): `__stack_pointer` only, at index 0 — the index the
/// GLOBAL_INDEX_LEB placeholders already carry.
bool emitGlobalSection(ref OutBuffer out_, ref WasmModule wmod)
{
    OutBuffer* s = &wmod.scratch;
    s.reset();
    s.writeuLEB128(1);
    s.writeByte(I64() ? WASM_I64 : WASM_I32);
    s.writeByte(WASM_MUT.VAR);
    s.writeByte(I64() ? OP.I64_CONST : OP.I32_CONST);
    s.writesLEB128(cast(int) wmod.stackHigh);
    s.writeByte(OP.END);
    writeSection(out_, WASM_SECTION.global, s);
    return true;
}

/// Element section (id 9): identity mapping of table slot `i + 1` onto function
/// `i`, matching the `funcIdx + 1` written into the TABLE_INDEX relocations.
bool emitElemSection(ref OutBuffer out_, ref WasmModule wmod)
{
    if (!wmod.funcs.length)
        return false;
    OutBuffer* s = &wmod.scratch;
    s.reset();
    s.writeuLEB128(1);
    s.writeuLEB128(0);
    s.writeByte(OP.I32_CONST);
    s.writesLEB128(1);
    s.writeByte(OP.END);
    s.writeuLEB128(cast(uint) wmod.funcs.length);
    foreach (uint i; 0 .. cast(uint) wmod.funcs.length)
        s.writeuLEB128(i);
    writeSection(out_, WASM_SECTION.element, s);
    return true;
}
