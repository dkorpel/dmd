/**
 * Configures and initializes the backend.
 *
 * Copyright:   Copyright (C) 1999-2026 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 https://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/compiler/src/dmd/dmsc.d, _dmsc.d)
 * Documentation:  https://dlang.org/phobos/dmd_dmsc.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/compiler/src/dmd/dmsc.d
 */

module dmd.dmsc;

import core.stdc.stdio;
import core.stdc.string;
import core.stdc.stddef;

import dmd.globals;
import dmd.dclass;
import dmd.dmdparams;
import dmd.dmodule;
import dmd.errors : errorBackend;
import dmd.mtype;
import dmd.target;

import dmd.root.filename;

import dmd.backend.backconfig;
import dmd.backend.go;
import dmd.backend.cc;
import dmd.backend.cdef;
import dmd.backend.global : ErrorCallbackBackend, GetFileContentsCallback;
import dmd.backend.ty;
import dmd.backend.type;

import dmd.file_manager : FileManager;

/// Callback for the backend to fetch cached source-file contents from the
/// front-end FileManager (Module.src), so hashing source files for debug info
/// reuses the in-memory cache instead of re-reading them from disk.
extern(C++) const(ubyte)* getFileContentsBackend(const(char)* filename, ref size_t length)
{
    length = 0;
    if (!global.fileManager)
        return null;
    const(ubyte)[] data = global.fileManager.getFileContents(FileName(filename[0 .. strlen(filename)]));
    if (!data)
        return null;
    length = data.length;
    return data.ptr;
}

/**************************************
 * Initialize backend config variables.
 * Params:
 *      params = command line parameters
 *      driverParams = more command line parameters
 *      target = target machine info
 */

void backend_init(const ref Param params, const ref DMDparams driverParams, const ref Target target)
{
    //printf("backend_init()\n");
    exefmt_t exfmt;
    bool is64 = target.isX86_64 || target.isAArch64 || target.isWasm64;
    if (target.isWasm)
        exfmt = EX_WASM;
    else switch (target.os)
    {
        case Target.OS.Windows: exfmt = is64 ? EX_WIN64     : EX_WIN32;   break;
        case Target.OS.linux:   exfmt = is64 ? EX_LINUX64   : EX_LINUX;   break;
        case Target.OS.OSX:     exfmt = is64 ? EX_OSX64     : EX_OSX;     break;
        case Target.OS.FreeBSD: exfmt = is64 ? EX_FREEBSD64 : EX_FREEBSD; break;
        case Target.OS.OpenBSD: exfmt = is64 ? EX_OPENBSD64 : EX_OPENBSD; break;
        case Target.OS.Solaris: exfmt = is64 ? EX_SOLARIS64 : EX_SOLARIS; break;
        case Target.OS.DragonFlyBSD: assert(is64); exfmt = EX_DRAGONFLYBSD64; break;
        case Target.OS.Hurd:    exfmt = is64 ? EX_HURD64    : EX_HURD; break;
        default: assert(0);
    }

    bool exe;
    if (driverParams.dll || driverParams.pic != PIC.fixed)
    {
    }
    else if (params.run)
        exe = true;         // EXE file only optimizations
    else if (driverParams.link && !params.deffile)
        exe = true;         // EXE file only optimizations
    else if (params.exefile.length &&
             params.exefile.length >= 4 &&
             FileName.equals(FileName.ext(params.exefile), "exe"))
        exe = true;         // if writing out EXE file

    out_config_init(
        target.isAArch64,
        is64 ? 64 : 32,
        exe,
        false, //params.trace,
        driverParams.nofloat,
        driverParams.vasm,
        params.v.verbose,
        driverParams.optimize || params.useInline,
        driverParams.symdebug,
        driverParams.alwaysframe,
        driverParams.stackstomp,
        driverParams.ibt,
        target.cpu >= CPU.avx2 ? 2 : target.cpu >= CPU.avx ? 1 : 0,
        driverParams.pic,
        params.useModuleInfo && Module.moduleinfo,
        params.useTypeInfo && Type.dtypeinfo,
        params.useExceptions && ClassDeclaration.throwable,
        driverParams.dwarf,
        global.versionString(),
        exfmt,
        params.addMain,
        driverParams.symImport != SymImport.none,
        go,
        // FIXME: casting to @nogc because errors.d is not marked @nogc yet
        cast(ErrorCallbackBackend) &errorBackend,
        cast(GetFileContentsCallback) &getFileContentsBackend,
    );

    out_config_debug(
        driverParams.debugb,
        driverParams.debugc,
        driverParams.debugf,
        driverParams.debugr,
        false,
        driverParams.debugx,
        driverParams.debugy
    );
}

/**************************************
 */

void backend_term() @safe
{
}

void backend_init_wasm_ctfe()
{
    import dmd.backend.cc : config;
    import dmd.backend.cdef : Config;

    config = Config.init;
    go.mfoptim = 0;
    import dmd.target : target;
    out_config_init(
        false,
        target.isLP64 ? 64 : 32,
        false,
        false,
        false,
        false,
        false,
        false,
        0,
        false,
        false,
        false,
        0,
        0,
        false,
        global.params.useTypeInfo && Type.dtypeinfo,
        true,
        0,
        global.versionString(),
        EX_WASM,
        false,
        false,
        go,
        cast(ErrorCallbackBackend) &errorBackend,
        cast(GetFileContentsCallback) &getFileContentsBackend,
    );
    {
        import dmd.backend.wasm.softreal : wasmSoftReal, softRealReset;
        import dmd.backend.ty : _tysize, _tyalignsize, TYreal, TYireal, TYcreal;
        import dmd.target : target;
        softRealReset();
        wasmSoftReal = real.mant_dig == 64 && (target.realsize == 16 && target.realpad == 6
            || target.realsize == 12 && target.realpad == 2);
        if (wasmSoftReal && target.realsize == 12)
        {
            _tysize[TYreal] = 12;
            _tysize[TYireal] = 12;
            _tysize[TYcreal] = 24;
            _tyalignsize[TYreal] = 4;
            _tyalignsize[TYireal] = 4;
            _tyalignsize[TYcreal] = 4;
        }
        else if (wasmSoftReal)
        {
            _tysize[TYreal] = 16;
            _tysize[TYireal] = 16;
            _tysize[TYcreal] = 32;
            _tyalignsize[TYreal] = 16;
            _tyalignsize[TYireal] = 16;
            _tyalignsize[TYcreal] = 16;
        }
    }
}

void backend_reinit_host()
{
    import dmd.backend.cc : config;
    import dmd.backend.cdef : Config;
    import dmd.target : target;
    import dmd.dmdparams : driverParams;
    import dmd.backend.wasm.softreal : wasmSoftReal;

    wasmSoftReal = false;
    config = Config.init;
    backend_init(global.params, driverParams, target);
}
