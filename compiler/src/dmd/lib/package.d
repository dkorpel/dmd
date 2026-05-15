/**
 * A module defining an abstract library.
 * Implementations for various formats are in separate `libXXX.d` modules.
 *
 * Copyright:   Copyright (C) 1999-2026 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 https://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/compiler/src/dmd/lib/package.d, _lib.d)
 * Documentation:  https://dlang.org/phobos/dmd_lib.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/compiler/src/dmd/lib/package.d
 */

module dmd.lib;

import core.stdc.stdio;
import core.stdc.string : memset, memcpy;

import dmd.common.outbuffer;
import dmd.errorsink;
import dmd.location;
import dmd.target : Target;

// ──────────────────────────────────────────────────────────────────────────────
// ar archive header format shared by ELF and WASM libraries.
//
// All three of ELF, Mach-O/BSD, and WASM use the same GNU/SVR4 ar format:
//   !<arch>\n
//   [member header (60 bytes)] [member data] ...
//
// See: https://en.wikipedia.org/wiki/Ar_(Unix)
// ──────────────────────────────────────────────────────────────────────────────

enum AR_OBJECT_NAME_SIZE = 16;
enum AR_FILE_TIME_SIZE   = 12;
enum AR_USER_ID_SIZE     =  6;
enum AR_GROUP_ID_SIZE    =  6;
enum AR_FILE_MODE_SIZE   =  8;
enum AR_FILE_SIZE_SIZE   = 10;
enum AR_TRAILER_SIZE     =  2;

/// Standard ar member header, 60 bytes (GNU/SVR4 format).
package(dmd.lib) struct ArHeader
{
    char[AR_OBJECT_NAME_SIZE] object_name;
    char[AR_FILE_TIME_SIZE]   file_time;
    char[AR_USER_ID_SIZE]     user_id;
    char[AR_GROUP_ID_SIZE]    group_id;
    char[AR_FILE_MODE_SIZE]   file_mode;
    char[AR_FILE_SIZE_SIZE]   file_size;
    char[AR_TRAILER_SIZE]     trailer;
}

static assert(ArHeader.sizeof == 60);

/**
 * Write a GNU/SVR4 ar member header into `h`.
 *
 * Params:
 *  h           = header to fill (60 bytes)
 *  name        = basename of the member, without trailing '/'. Null-terminated.
 *  name_offset = if >= 0, use long-name format "/offset" instead of inline name
 *  file_time   = modification time (seconds since epoch)
 *  user_id     = Unix UID (clamped to 999999)
 *  group_id    = Unix GID (clamped to 999999)
 *  file_mode   = Unix mode bits (octal format in header)
 *  file_size   = payload size in bytes
 */
package(dmd.lib)
void arFillHeader(ref ArHeader h, const(char)* name, int name_offset,
    long file_time, uint user_id, uint group_id, uint file_mode, uint file_size) nothrow
{
    if (user_id > 999_999)
        user_id = 0;
    if (group_id > 999_999)
        group_id = 0;

    char[ArHeader.sizeof + 1] buf = void;
    int len;
    if (name_offset < 0)
    {
        len = snprintf(buf.ptr, buf.sizeof,
            "%-16s%-12lld%-6u%-6u%-8o%-10u`",
            name, cast(long)file_time, user_id, group_id, file_mode, file_size);
        // snprintf pads name to 16 with spaces; replace the null at name.length with '/'
        import core.stdc.string : strlen;
        buf[strlen(name)] = '/';
    }
    else
    {
        len = snprintf(buf.ptr, buf.sizeof,
            "/%-15d%-12lld%-6u%-6u%-8o%-10u`",
            name_offset, cast(long)file_time, user_id, group_id, file_mode, file_size);
    }
    assert(len + 1 != 0);
    assert(len == ArHeader.sizeof - 1);
    buf[len] = '\n';
    (cast(char*)&h)[0 .. ArHeader.sizeof] = buf[0 .. ArHeader.sizeof];
}

import dmd.lib.elf;
import dmd.lib.mach;
import dmd.lib.mscoff;
import dmd.lib.wasm;

private enum LOG = false;

class Library
{
    const(char)[] lib_ext;      // library file extension
    ErrorSink eSink;            // where the error messages go

    static Library factory(Target.ObjectFormat of, const char[] lib_ext, ErrorSink eSink)
    {
        Library lib;
        final switch (of)
        {
            case Target.ObjectFormat.elf:   lib = LibElf_factory();     break;
            case Target.ObjectFormat.macho: lib = LibMach_factory();    break;
            case Target.ObjectFormat.coff:  lib = LibMSCoff_factory();  break;
            case Target.ObjectFormat.wasm: lib = LibWasm_factory(); break;
        }
        lib.lib_ext = lib_ext;
        lib.eSink = eSink;
        return lib;
    }

    abstract void addObject(const(char)[] module_name, const ubyte[] buf);

    abstract void writeLibToBuffer(ref OutBuffer libbuf);


    /***********************************
     * Set library file name
     * Params:
     *  filename = name of library file
     */
    final void setFilename(const char[] filename)
    {
        static if (LOG)
        {
            printf("LibElf::setFilename(filename = '%.*s')\n",
                   cast(int)filename.length, filename.ptr);
        }

        this.filename = filename;
    }

  public:
    const(char)[] filename; /// the filename of the library
}
