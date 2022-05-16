/**
 * Run the C preprocessor on a C source file.
 *
 * Specification: C11
 *
 * Copyright:   Copyright (C) 2022 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 https://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/cpreprocess.d, _cpreprocess.d)
 * Documentation:  https://dlang.org/phobos/dmd_cpreprocess.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/cpreprocess.d
 */

module dmd.cpreprocess;

import core.stdc.stdio;
import core.stdc.stdlib;
import core.stdc.string;

import dmd.astenums;
import dmd.errors;
import dmd.globals;
import dmd.link;
import dmd.target;
import dmd.vsoptions;

import dmd.common.outbuffer;

import dmd.root.array;
import dmd.root.filename;
import dmd.root.rmem;
import dmd.root.rootobject;
import dmd.root.string;

/***************************************
 * Preprocess C file.
 * Params:
 *      csrcfile = C file to be preprocessed, with .c or .h extension
 *      importc_h = filename of importc.h
 *      cppswitches = array of switches to pass to C preprocessor
 *      ifile = set to true if an output file was written
 * Result:
 *      filename of output
 */
extern (C++)
FileName preprocess(FileName csrcfile, const char* importc_h, ref Array!(const(char)*) cppswitches, out bool ifile)
{
    //printf("preprocess %s\n", csrcfile.toChars());
    version (Posix)
    {
        const name = FileName.name(csrcfile.toString());
        const ext = FileName.ext(name);
        assert(ext);
        const ifilename = FileName.addExt(name[0 .. name.length - (ext.length + 1)], i_ext);
        const command = cppCommand();
        auto status = runPreprocessor(command, csrcfile.toString(), importc_h, cppswitches, ifilename);
        if (status)
        {
            error(Loc.initial, "C preprocess command %.*s failed for file %s, exit status %d\n",
                cast(int)command.length, command.ptr, csrcfile.toChars(), status);
            fatal();
        }
        ifile = true;
        return FileName(ifilename);
    }
    else version (Windows)
    {
        /*
           To get sppn.exe: http://ftp.digitalmars.com/sppn.zip
           To get the dmc C headers, dmc will need to be installed:
           http://ftp.digitalmars.com/Digital_Mars_C++/Patch/dm857c.zip
         */
        const name = FileName.name(csrcfile.toString());
        const ext = FileName.ext(name);
        assert(ext);
        const ifilename = FileName.addExt(name[0 .. name.length - (ext.length + 1)], i_ext);
        const command = cppCommand();
        auto status = runPreprocessor(command, csrcfile.toString(), importc_h, cppswitches, ifilename);
        if (status)
        {
            error(Loc.initial, "C preprocess command %.*s failed for file %s, exit status %d\n",
                cast(int)command.length, command.ptr, csrcfile.toChars(), status);
            fatal();
        }
        //printf("C preprocess succeeded %s\n", ifilename.ptr);
        ifile = true;
        return FileName(ifilename);
    }
    else
        return csrcfile;        // no-op
}

private const(char)[] cppCommand()
{
    if (auto p = getenv("CPPCMD"))
        return toDString(p);

    version (Windows)
    {
        if (target.objectFormat() == Target.ObjectFormat.coff)
        {
            VSOptions vsopt;
            vsopt.initialize();
            auto path = vsopt.compilerPath(target.is64bit);
            OutBuffer cmdbuf;
            cmdbuf.writestring(path);
            cmdbuf.writestring(r" /P");
            return cmdbuf.extractSlice();
        }
        if (target.objectFormat() == Target.ObjectFormat.omf)
        {
            return "sppn.exe";
        }
    }
    return "cpp";
}
