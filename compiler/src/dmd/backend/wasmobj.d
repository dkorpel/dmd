/**
 * WebAssembly object module writer stub.
 *
 * Copyright:   Copyright (C) 1999-2026 by The D Language Foundation, All Rights Reserved
 * License:     $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/compiler/src/dmd/backend/wasmobj.d, _wasmobj.d)
 */

module dmd.backend.wasmobj;

import dmd.backend.cc;
import dmd.backend.cdef;
import dmd.backend.code;
import dmd.backend.el;
import dmd.backend.obj;

import dmd.common.outbuffer;

nothrow:

Obj WasmObj_init(OutBuffer* objbuf, const(char)* filename, const(char)* csegname)
{
    assert(0, "WASM object format not yet implemented");
}

void WasmObj_initfile(const(char)* filename, const(char)* csegname, const(char)* modname)
{
    assert(0, "WASM object format not yet implemented");
}

void WasmObj_termfile()
{
    assert(0, "WASM object format not yet implemented");
}

void WasmObj_term(const(char)[] objfilename)
{
    assert(0, "WASM object format not yet implemented");
}

void WasmObj_linnum(Srcpos srcpos, int seg, targ_size_t offset)
{
    assert(0, "WASM object format not yet implemented");
}

int WasmObj_codeseg(const char* name, int suffix)
{
    assert(0, "WASM object format not yet implemented");
}

void WasmObj_startaddress(Symbol* s)
{
    assert(0, "WASM object format not yet implemented");
}

bool WasmObj_includelib(scope const(char)[] name)
{
    assert(0, "WASM object format not yet implemented");
}

bool WasmObj_linkerdirective(scope const(char)* p)
{
    assert(0, "WASM object format not yet implemented");
}

bool WasmObj_allowZeroSize()
{
    assert(0, "WASM object format not yet implemented");
}

void WasmObj_exestr(const(char)* p)
{
    assert(0, "WASM object format not yet implemented");
}

void WasmObj_user(const(char)* p)
{
    assert(0, "WASM object format not yet implemented");
}

void WasmObj_compiler(const(char)* p)
{
    assert(0, "WASM object format not yet implemented");
}

void WasmObj_wkext(Symbol* s1, Symbol* s2)
{
    assert(0, "WASM object format not yet implemented");
}

void WasmObj_alias(const(char)* n1, const(char)* n2)
{
    assert(0, "WASM object format not yet implemented");
}

void WasmObj_staticctor(Symbol* s, int dtor, int seg)
{
    assert(0, "WASM object format not yet implemented");
}

void WasmObj_staticdtor(Symbol* s)
{
    assert(0, "WASM object format not yet implemented");
}

void WasmObj_setModuleCtorDtor(Symbol* s, bool isCtor)
{
    assert(0, "WASM object format not yet implemented");
}

void WasmObj_ehtables(Symbol* sfunc, uint size, Symbol* ehsym)
{
    assert(0, "WASM object format not yet implemented");
}

void WasmObj_ehsections()
{
    assert(0, "WASM object format not yet implemented");
}

void WasmObj_moduleinfo(Symbol* scc)
{
    assert(0, "WASM object format not yet implemented");
}

int WasmObj_comdat(Symbol* s)
{
    assert(0, "WASM object format not yet implemented");
}

int WasmObj_comdatsize(Symbol* s, targ_size_t symsize)
{
    assert(0, "WASM object format not yet implemented");
}

void WasmObj_setcodeseg(int seg)
{
    assert(0, "WASM object format not yet implemented");
}

seg_data* WasmObj_tlsseg()
{
    assert(0, "WASM object format not yet implemented");
}

seg_data* WasmObj_tlsseg_bss()
{
    assert(0, "WASM object format not yet implemented");
}

seg_data* WasmObj_tlsseg_data()
{
    assert(0, "WASM object format not yet implemented");
}

void WasmObj_export_symbol(Symbol* s, uint argsize)
{
    assert(0, "WASM object format not yet implemented");
}

void WasmObj_pubdef(int seg, Symbol* s, targ_size_t offset)
{
    assert(0, "WASM object format not yet implemented");
}

void WasmObj_pubdefsize(int seg, Symbol* s, targ_size_t offset, targ_size_t symsize)
{
    assert(0, "WASM object format not yet implemented");
}

int WasmObj_external_def(const(char)* name)
{
    assert(0, "WASM object format not yet implemented");
}

int WasmObj_data_start(Symbol* sdata, targ_size_t datasize, int seg)
{
    assert(0, "WASM object format not yet implemented");
}

int WasmObj_external(Symbol* s)
{
    assert(0, "WASM object format not yet implemented");
}

int WasmObj_common_block(Symbol* s, targ_size_t size, targ_size_t count)
{
    assert(0, "WASM object format not yet implemented");
}

int WasmObj_common_block(Symbol* s, int flag, targ_size_t size, targ_size_t count)
{
    assert(0, "WASM object format not yet implemented");
}

void WasmObj_lidata(int seg, targ_size_t offset, targ_size_t count)
{
    assert(0, "WASM object format not yet implemented");
}

void WasmObj_write_zeros(seg_data* pseg, targ_size_t count)
{
    assert(0, "WASM object format not yet implemented");
}

void WasmObj_write_byte(seg_data* pseg, uint _byte)
{
    assert(0, "WASM object format not yet implemented");
}

void WasmObj_write_bytes(seg_data* pseg, const(void[]) a)
{
    assert(0, "WASM object format not yet implemented");
}

void WasmObj_byte(int seg, targ_size_t offset, uint _byte)
{
    assert(0, "WASM object format not yet implemented");
}

size_t WasmObj_bytes(int seg, targ_size_t offset, size_t nbytes, const(void)* p)
{
    assert(0, "WASM object format not yet implemented");
}

void WasmObj_reftodatseg(int seg, targ_size_t offset, targ_size_t val, uint targetdatum, int flags)
{
    assert(0, "WASM object format not yet implemented");
}

void WasmObj_reftocodeseg(int seg, targ_size_t offset, targ_size_t val)
{
    assert(0, "WASM object format not yet implemented");
}

int WasmObj_reftoident(int seg, targ_size_t offset, Symbol* s, targ_size_t val, int flags)
{
    assert(0, "WASM object format not yet implemented");
}

void WasmObj_far16thunk(Symbol* s)
{
    assert(0, "WASM object format not yet implemented");
}

void WasmObj_fltused()
{
    assert(0, "WASM object format not yet implemented");
}

int WasmObj_data_readonly(char* p, int len, int* pseg)
{
    assert(0, "WASM object format not yet implemented");
}

int WasmObj_data_readonly(char* p, int len)
{
    assert(0, "WASM object format not yet implemented");
}

int WasmObj_string_literal_segment(uint sz)
{
    assert(0, "WASM object format not yet implemented");
}

Symbol* WasmObj_sym_cdata(tym_t ty, char* p, int len)
{
    assert(0, "WASM object format not yet implemented");
}

void WasmObj_func_start(Symbol* sfunc)
{
    assert(0, "WASM object format not yet implemented");
}

void WasmObj_func_term(Symbol* sfunc)
{
    assert(0, "WASM object format not yet implemented");
}

void WasmObj_write_pointerRef(Symbol* s, uint off)
{
    assert(0, "WASM object format not yet implemented");
}

int WasmObj_jmpTableSegment(Symbol* s)
{
    assert(0, "WASM object format not yet implemented");
}

Symbol* WasmObj_tlv_bootstrap()
{
    assert(0, "WASM object format not yet implemented");
}

void WasmObj_gotref(Symbol* s)
{
    // WASM has no GOT; no-op
}

Symbol* WasmObj_getGOTsym()
{
    return null;
}

void WasmObj_refGOTsym()
{
    // WASM has no GOT; no-op
}
