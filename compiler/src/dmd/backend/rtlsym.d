/**
 * Compiler runtime function symbols
 *
 * Compiler implementation of the
 * $(LINK2 https://www.dlang.org, D programming language).
 *
 * Copyright:   Copyright (C) 1996-1998 by Symantec
 *              Copyright (C) 2000-2026 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 https://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/compiler/src/dmd/backend/rtlsym.d, backend/rtlsym.d)
 */

module dmd.backend.rtlsym;

import core.stdc.stdio;
import core.stdc.stdlib;
import core.stdc.string;

import dmd.backend.cc;
import dmd.backend.cdef;
import dmd.backend.code;
import dmd.backend.x86.code_x86;
import dmd.backend.symbol : symbol_calloc, SYMIDX;
import dmd.backend.ty;
import dmd.backend.type;


nothrow:

enum RTLSYM
{
    THROWC,
    THROWDWARF,
    MONITOR_HANDLER,
    MONITOR_PROLOG,
    MONITOR_EPILOG,
    DCOVER2,
    DASSERT,
    DASSERTP,
    DASSERT_MSG,
    DUNITTEST,
    DUNITTESTP,
    DUNITTEST_MSG,
    DARRAYP,
    DARRAY_SLICEP,
    DARRAY_INDEXP,
    DNULLP,
    DINVARIANT,
    MEMCMP,
    MEMCPY,
    MEMSET8,
    MEMSET16,
    MEMSET32,
    MEMSET64,
    MEMSET128,
    MEMSET128ii,
    MEMSET80,
    MEMSET160,
    MEMSETFLOAT,
    MEMSETDOUBLE,
    MEMSETSIMD,
    MEMSETN,

    CALLFINALIZER,
    CALLINTERFACEFINALIZER,
    ALLOCMEMORY,
    ARRAYAPPENDCD,
    ARRAYAPPENDWD,
    ARRAYCOPY,
    ARRAYASSIGN_R,
    ARRAYASSIGN_L,
    ARRAYEQ2,

    D_HANDLER,
    D_LOCAL_UNWIND2,
    LOCAL_UNWIND2,
    UNWIND_RESUME,
    PERSONALITY,
    BEGIN_CATCH,
    CXA_BEGIN_CATCH,
    CXA_END_CATCH,

    TLS_INDEX,
    TLS_ARRAY,
    AHSHIFT,

    HDIFFN,
    HDIFFF,
    INTONLY,

    EXCEPT_LIST,
    SETJMP3,
    LONGJMP,
    ALLOCA,
    PTRCHK,
    CHKSTK,
    TRACE_PRO_N,
    TRACE_PRO_F,
    TRACE_EPI_N,
    TRACE_EPI_F,


    TRACECALLFINALIZER,
    TRACECALLINTERFACEFINALIZER,
    TRACEARRAYAPPENDCD,
    TRACEARRAYAPPENDWD,
    TRACEALLOCMEMORY,

    C_ASSERT,
    C__ASSERT,
    C__ASSERT_FAIL,
    C__ASSERT_RTN,

    FMODF,
    FMOD,
    FMODL,

    CXA_ATEXIT
}

private __gshared Symbol*[RTLSYM.max + 1] rtlsym;

/******************************************
 * Get Symbol corresponding to Dwarf "personality" function.
 * Returns:
 *      Personality function
 */
Symbol* getRtlsymPersonality() { return getRtlsym(RTLSYM.PERSONALITY); }


/******************************************
 * Get Symbol corresponding to i.
 * Params:
 *      i = RTLSYM.xxxx
 * Returns:
 *      runtime library Symbol
 */
Symbol* getRtlsym(RTLSYM i) @trusted
{
     Symbol** ps = &rtlsym[i];
     if (*ps)
        return* ps;

    __gshared type* t;
    __gshared type* tv;

    if (!t)
    {
        t = type_fake(TYnfunc);
        t.Tmangle = Mangle.c;
        t.Tcount++;

        // Variadic function
        tv = type_fake(TYnfunc);
        tv.Tmangle = Mangle.c;
        tv.Tcount++;
    }

    auto FREGSAVED = cgstate.fregsaved; // varies depending on C ABI

    // Lazilly initialize only what we use
    switch (i)
    {
        case RTLSYM.THROWC:                 symbolz(ps,FL.func,(mES | mBP),"_d_throwc", SFLexit, t); break;
        case RTLSYM.THROWDWARF:             symbolz(ps,FL.func,(mES | mBP),"_d_throwdwarf", SFLexit, t); break;
        case RTLSYM.MONITOR_HANDLER:        symbolz(ps,FL.func,FREGSAVED,"_d_monitor_handler", 0, tsclib); break;
        case RTLSYM.MONITOR_PROLOG:         symbolz(ps,FL.func,FREGSAVED,"_d_monitor_prolog",0,t); break;
        case RTLSYM.MONITOR_EPILOG:         symbolz(ps,FL.func,FREGSAVED,"_d_monitor_epilog",0,t); break;
        case RTLSYM.DCOVER2:                symbolz(ps,FL.func,FREGSAVED,"_d_cover_register2", 0, t); break;
        case RTLSYM.DASSERT:                symbolz(ps,FL.func,FREGSAVED,"_d_assert", SFLexit, t); break;
        case RTLSYM.DASSERTP:               symbolz(ps,FL.func,FREGSAVED,"_d_assertp", SFLexit, t); break;
        case RTLSYM.DASSERT_MSG:            symbolz(ps,FL.func,FREGSAVED,"_d_assert_msg", SFLexit, t); break;
        case RTLSYM.DUNITTEST:              symbolz(ps,FL.func,FREGSAVED,"_d_unittest", 0, t); break;
        case RTLSYM.DUNITTESTP:             symbolz(ps,FL.func,FREGSAVED,"_d_unittestp", 0, t); break;
        case RTLSYM.DUNITTEST_MSG:          symbolz(ps,FL.func,FREGSAVED,"_d_unittest_msg", 0, t); break;
        case RTLSYM.DARRAYP:                symbolz(ps,FL.func,FREGSAVED,"_d_arrayboundsp", SFLexit, t); break;
        case RTLSYM.DARRAY_SLICEP:          symbolz(ps,FL.func,FREGSAVED,"_d_arraybounds_slicep", SFLexit, t); break;
        case RTLSYM.DARRAY_INDEXP:          symbolz(ps,FL.func,FREGSAVED,"_d_arraybounds_indexp", SFLexit, t); break;
        case RTLSYM.DNULLP:                 symbolz(ps,FL.func,FREGSAVED,"_d_nullpointerp", SFLexit, t); break;
        case RTLSYM.DINVARIANT:             symbolz(ps,FL.func,FREGSAVED,"_D2rt10invariant_12_d_invariantFC6ObjectZv", 0, tsdlib); break;
        case RTLSYM.MEMCMP:                 symbolz(ps,FL.func,FREGSAVED,"memcmp",    0, t); break;
        case RTLSYM.MEMCPY:                 symbolz(ps,FL.func,FREGSAVED,"memcpy",    0, t); break;
        case RTLSYM.MEMSET8:                symbolz(ps,FL.func,FREGSAVED,"memset",    0, t); break;
        case RTLSYM.MEMSET16:               symbolz(ps,FL.func,FREGSAVED,"_memset16", 0, t); break;
        case RTLSYM.MEMSET32:               symbolz(ps,FL.func,FREGSAVED,"_memset32", 0, t); break;
        case RTLSYM.MEMSET64:               symbolz(ps,FL.func,FREGSAVED,"_memset64", 0, t); break;
        case RTLSYM.MEMSET128:              symbolz(ps,FL.func,FREGSAVED,"_memset128",0, t); break;
        case RTLSYM.MEMSET128ii:            symbolz(ps,FL.func,FREGSAVED,"_memset128ii",0, t); break;
        case RTLSYM.MEMSET80:               symbolz(ps,FL.func,FREGSAVED,"_memset80", 0, t); break;
        case RTLSYM.MEMSET160:              symbolz(ps,FL.func,FREGSAVED,"_memset160",0, t); break;
        case RTLSYM.MEMSETFLOAT:            symbolz(ps,FL.func,FREGSAVED,"_memsetFloat", 0, t); break;
        case RTLSYM.MEMSETDOUBLE:           symbolz(ps,FL.func,FREGSAVED,"_memsetDouble", 0, t); break;
        case RTLSYM.MEMSETSIMD:             symbolz(ps,FL.func,FREGSAVED,"_memsetSIMD",0, t); break;
        case RTLSYM.MEMSETN:                symbolz(ps,FL.func,FREGSAVED,"_memsetn",  0, t); break;
        case RTLSYM.CALLFINALIZER:          symbolz(ps,FL.func,FREGSAVED,"_d_callfinalizer", 0, t); break;
        case RTLSYM.CALLINTERFACEFINALIZER: symbolz(ps,FL.func,FREGSAVED,"_d_callinterfacefinalizer", 0, t); break;
        case RTLSYM.ALLOCMEMORY:            symbolz(ps,FL.func,FREGSAVED,"_d_allocmemory", 0, t); break;
        case RTLSYM.ARRAYAPPENDCD:          symbolz(ps,FL.func,FREGSAVED,"_d_arrayappendcd", 0, t); break;
        case RTLSYM.ARRAYAPPENDWD:          symbolz(ps,FL.func,FREGSAVED,"_d_arrayappendwd", 0, t); break;
        case RTLSYM.ARRAYCOPY:              symbolz(ps,FL.func,FREGSAVED,"_d_arraycopy", 0, t); break;
        case RTLSYM.ARRAYASSIGN_R:          symbolz(ps,FL.func,FREGSAVED,"_d_arrayassign_r", 0, t); break;
        case RTLSYM.ARRAYASSIGN_L:          symbolz(ps,FL.func,FREGSAVED,"_d_arrayassign_l", 0, t); break;

        case RTLSYM.D_HANDLER:              symbolz(ps,FL.func,FREGSAVED,"_d_framehandler", 0, tsclib); break;
        case RTLSYM.D_LOCAL_UNWIND2:        symbolz(ps,FL.func,FREGSAVED,"_d_local_unwind2", 0, tsclib); break;
        case RTLSYM.LOCAL_UNWIND2:          symbolz(ps,FL.func,FREGSAVED,"_local_unwind2", 0, tsclib); break;
        case RTLSYM.UNWIND_RESUME:          symbolz(ps,FL.func,FREGSAVED,"_Unwind_Resume", SFLexit, t); break;
        case RTLSYM.PERSONALITY:            symbolz(ps,FL.func,FREGSAVED,"__dmd_personality_v0", 0, t); break;
        case RTLSYM.BEGIN_CATCH:            symbolz(ps,FL.func,FREGSAVED,"__dmd_begin_catch", 0, t); break;
        case RTLSYM.CXA_BEGIN_CATCH:        symbolz(ps,FL.func,FREGSAVED,"__cxa_begin_catch", 0, t); break;
        case RTLSYM.CXA_END_CATCH:          symbolz(ps,FL.func,FREGSAVED,"__cxa_end_catch", 0, t); break;

        case RTLSYM.TLS_INDEX:              symbolz(ps,FL.extern_,0,"_tls_index",0,tstypes[TYint]); break;
        case RTLSYM.TLS_ARRAY:              symbolz(ps,FL.extern_,0,"_tls_array",0,tspvoid); break;
        case RTLSYM.AHSHIFT:                symbolz(ps,FL.func,0,"_AHSHIFT",0,tstrace); break;

        case RTLSYM.HDIFFN:                 symbolz(ps,FL.func,mBX|mCX|mSI|mDI|mBP|mES,"_aNahdiff", 0, tsclib); break;
        case RTLSYM.HDIFFF:                 symbolz(ps,FL.func,mBX|mCX|mSI|mDI|mBP|mES,"_aFahdiff", 0, tsclib); break;
        case RTLSYM.INTONLY:                symbolz(ps,FL.func,mSI|mDI,"_intonly", 0, tsclib); break;

        case RTLSYM.EXCEPT_LIST:            symbolz(ps,FL.extern_,0,"_except_list",0,tstypes[TYint]); break;
        case RTLSYM.SETJMP3:                symbolz(ps,FL.func,FREGSAVED,"_setjmp3", 0, tsclib); break;
        case RTLSYM.LONGJMP:                symbolz(ps,FL.func,FREGSAVED,"_seh_longjmp_unwind@4", 0, tsclib); break;
        case RTLSYM.ALLOCA:                 symbolz(ps,FL.func,FREGSAVED,"__alloca", 0, tsclib); break;
        case RTLSYM.PTRCHK:                 symbolz(ps,FL.func,FREGSAVED,"_ptrchk", 0, tsclib); break;
        case RTLSYM.CHKSTK:                 symbolz(ps,FL.func,FREGSAVED,"_chkstk", 0, tsclib); break;
        case RTLSYM.TRACE_PRO_N:            symbolz(ps,FL.func,ALLREGS|mBP|mES,"_trace_pro_n",0,tstrace); break;
        case RTLSYM.TRACE_PRO_F:            symbolz(ps,FL.func,ALLREGS|mBP|mES,"_trace_pro_f",0,tstrace); break;
        case RTLSYM.TRACE_EPI_N:            symbolz(ps,FL.func,ALLREGS|mBP|mES,"_trace_epi_n",0,tstrace); break;
        case RTLSYM.TRACE_EPI_F:            symbolz(ps,FL.func,ALLREGS|mBP|mES,"_trace_epi_f",0,tstrace); break;


        case RTLSYM.TRACECALLFINALIZER:     symbolz(ps,FL.func,FREGSAVED,"_d_callfinalizerTrace", 0, t); break;
        case RTLSYM.TRACECALLINTERFACEFINALIZER: symbolz(ps,FL.func,FREGSAVED,"_d_callinterfacefinalizerTrace", 0, t); break;
        case RTLSYM.TRACEARRAYAPPENDCD:     symbolz(ps,FL.func,FREGSAVED,"_d_arrayappendcdTrace", 0, t); break;
        case RTLSYM.TRACEARRAYAPPENDWD:     symbolz(ps,FL.func,FREGSAVED,"_d_arrayappendwdTrace", 0, t); break;
        case RTLSYM.TRACEALLOCMEMORY:       symbolz(ps,FL.func,FREGSAVED,"_d_allocmemoryTrace", 0, t); break;
        case RTLSYM.C_ASSERT:               symbolz(ps,FL.func,FREGSAVED,"_assert", SFLexit, t); break;
        case RTLSYM.C__ASSERT:              symbolz(ps,FL.func,FREGSAVED,"__assert", SFLexit, t); break;
        case RTLSYM.C__ASSERT_FAIL:         symbolz(ps,FL.func,FREGSAVED,"__assert_fail", SFLexit, t); break;
        case RTLSYM.C__ASSERT_RTN:          symbolz(ps,FL.func,FREGSAVED,"__assert_rtn", SFLexit, t); break;

        case RTLSYM.FMODF:                  symbolz(ps,FL.func,FREGSAVED,"fmodf", 0, t); break;  // C library function fmodf()
        case RTLSYM.FMOD:                   symbolz(ps,FL.func,FREGSAVED,"fmod",  0, t); break;  // C library function fmod()
        case RTLSYM.FMODL:                  symbolz(ps,FL.func,FREGSAVED,"fmodl", 0, t); break;  // C library function fmodl()

        case RTLSYM.CXA_ATEXIT:             symbolz(ps,FL.func,FREGSAVED,"__cxa_atexit", 0, t); break;
        default:
            assert(0);
    }

    // The shared placeholder `t` carries no parameter types and a void return,
    // which is fine for backends that derive the call ABI from the IR argument
    // list.  The WASM backend, however, encodes a fixed function signature in
    // the type section and validates operand-stack types against it, so each
    // runtime symbol needs its real prototype.  Supply it at the source rather
    // than reverse-engineering it from call sites in the WASM object writer.
    if (config.objfmt == OBJ_WASM)
        if (type* wt = wasmRtlsymType(i))
            (*ps).Stype = wt;

    return* ps;
}

/******************************************
 * Build the real backend signature for a runtime library symbol when targeting
 * WASM.  Returns null for symbols that are x86/Windows-only (or otherwise never
 * emitted on WASM), in which case the shared placeholder type is kept.
 *
 * `size_t` is 32-bit on wasm32, so it maps to TYuint.  D slices (`string`,
 * `void[]`) are modelled as TYdarray so the object writer splits them into the
 * (length, pointer) pair, and `ref T[]` / class references are plain pointers.
 */
private type* wasmRtlsymType(RTLSYM i) @trusted
{
    type* tvoid = tstypes[TYvoid];
    type* tint  = tstypes[TYint];
    type* tuint = tstypes[TYuint];
    type* tsize = tstypes[TYuint];   // size_t on wasm32
    type* tdchar = tstypes[TYdchar];

    static type* ptrTo(type* tn) => type_pointer(tn);
    type* voidPtr()  => ptrTo(tvoid);
    type* charPtr()  => ptrTo(tstypes[TYchar]);
    type* str()      => type_dyn_array(tstypes[TYchar]); // immutable(char)[]
    type* voidArr()  => type_dyn_array(tvoid);           // void[]

    type* fn(type*[] params, type* ret) => type_function(TYnfunc, params, false, ret);

    switch (i)
    {
        case RTLSYM.THROWC:
        case RTLSYM.THROWDWARF:
        case RTLSYM.DINVARIANT:
        case RTLSYM.CALLFINALIZER:
        case RTLSYM.CALLINTERFACEFINALIZER:
            return fn([voidPtr()], tvoid);

        case RTLSYM.DASSERT:
        case RTLSYM.DUNITTEST:
            return fn([str(), tuint], tvoid);
        case RTLSYM.DASSERTP:
        case RTLSYM.DUNITTESTP:
        case RTLSYM.DARRAYP:
        case RTLSYM.DNULLP:
            return fn([charPtr(), tuint], tvoid);
        case RTLSYM.DASSERT_MSG:
        case RTLSYM.DUNITTEST_MSG:
            return fn([str(), str(), tuint], tvoid);
        case RTLSYM.DARRAY_INDEXP:
            return fn([charPtr(), tuint, tsize, tsize], tvoid);
        case RTLSYM.DARRAY_SLICEP:
            return fn([charPtr(), tuint, tsize, tsize, tsize], tvoid);

        case RTLSYM.MEMCMP:
            return fn([voidPtr(), voidPtr(), tsize], tint);
        case RTLSYM.MEMCPY:
            return fn([voidPtr(), voidPtr(), tsize], voidPtr());
        case RTLSYM.MEMSET8:
            return fn([voidPtr(), tint, tsize], voidPtr());
        case RTLSYM.ALLOCMEMORY:
        case RTLSYM.TRACEALLOCMEMORY:
            return fn([tsize], voidPtr());

        case RTLSYM.ARRAYAPPENDCD:
        case RTLSYM.ARRAYAPPENDWD:
            return fn([voidPtr(), tdchar], voidArr()); // ref byte[] x, dchar c
        case RTLSYM.ARRAYCOPY:
            return fn([tsize, voidArr(), voidArr()], voidArr());

        case RTLSYM.C_ASSERT:   // _assert(msg, file, line)
        case RTLSYM.C__ASSERT:  // __assert(msg, file, line)
            return fn([charPtr(), charPtr(), tint], tvoid);
        case RTLSYM.C__ASSERT_FAIL: // __assert_fail(exp, file, line, func)
            return fn([charPtr(), charPtr(), tuint, charPtr()], tvoid);
        case RTLSYM.C__ASSERT_RTN:  // __assert_rtn(func, file, line, msg)
            return fn([charPtr(), charPtr(), tint, charPtr()], tvoid);

        case RTLSYM.FMODF:
            return fn([tstypes[TYfloat], tstypes[TYfloat]], tstypes[TYfloat]);
        case RTLSYM.FMOD:
            return fn([tstypes[TYdouble], tstypes[TYdouble]], tstypes[TYdouble]);

        default:
            return null;
    }
}


/******************************************
 * Create and initialize Symbol for runtime function.
 * Params:
 *    ps = where to store initialized Symbol pointer
 *    f = FL.xxx
 *    regsaved = registers not altered by function
 *    name = name of function
 *    flags = value for Sflags
 *    t = type of function
 */
private void symbolz(Symbol** ps, FL fl, regm_t regsaved, const(char)* name, SYMFLGS flags, type* t)
{
    Symbol* s = symbol_calloc(name[0 .. strlen(name)]);
    s.Stype = t;
    s.Ssymnum = SYMIDX.max;
    s.Sclass = SC.extern_;
    s.Sfl = fl;
    s.Sregsaved = regsaved;
    s.Sflags = flags;
    *ps = s;
}

/******************************************
 * Initialize rtl symbols.
 */

void rtlsym_init()
{
}

/*******************************
 * Reset the symbols for the case when we are generating multiple
 * .OBJ files from one compile.
 */
void rtlsym_reset()
{
    clib_inited = 0;            // reset CLIB symbols, too
    for (size_t i = 0; i <= RTLSYM.max; i++)
    {
        if (rtlsym[i])
        {
            rtlsym[i].Sxtrnnum = 0;
            rtlsym[i].Stypidx = 0;
        }
    }
}

/*******************************
 */

void rtlsym_term()
{
}
