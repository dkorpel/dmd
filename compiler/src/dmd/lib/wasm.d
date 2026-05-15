/**
 * A library in the ar archive format, used for WebAssembly.
 *
 * wasm-ld reads WASM object files from standard ar archives and builds its
 * own symbol index by scanning each member's "linking" custom section.
 * No separate symbol dictionary entry is required in the archive itself.
 *
 * Copyright:   Copyright (C) 1999-2026 by The D Language Foundation, All Rights Reserved
 * License:     $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/compiler/src/dmd/lib/wasm.d, _libwasm.d)
 */

module dmd.lib.wasm;

import core.stdc.stdio : snprintf;
import core.stdc.string : memcmp, memset, memcpy;
import core.stdc.time : time, time_t;

import dmd.errors : fatal;
import dmd.lib;
import dmd.location;
import dmd.utils : readFile;

import dmd.root.array;
import dmd.common.outbuffer;
import dmd.root.filename;
import dmd.root.rmem;

// Entry point (only public symbol in this module).
package(dmd.lib) extern (C++) Library LibWasm_factory()
{
    return new LibWasm();
}

private:
nothrow:

enum AR_OBJECT_NAME_SIZE = 16;
enum AR_FILE_TIME_SIZE   = 12;
enum AR_USER_ID_SIZE     =  6;
enum AR_GROUP_ID_SIZE    =  6;
enum AR_FILE_MODE_SIZE   =  8;
enum AR_FILE_SIZE_SIZE   = 10;
enum AR_TRAILER_SIZE     =  2;

// Standard ar member header (60 bytes total, GNU/SVR4 format).
struct ArHeader
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

struct WasmObjModule
{
    const(char)[] name;  // basename used in ar header
    const(ubyte)[] data; // raw bytes of the WASM object
    long file_time;
    uint user_id;
    uint group_id;
    uint file_mode;
    uint name_offset;    // offset into // name table, or uint.max if short name fits
    uint offset;         // byte offset of this member in the archive
}

alias WasmObjModules = Array!(WasmObjModule*);

final class LibWasm : Library
{
    WasmObjModules objmodules;

    /***************************************
     * Add object module or library to the library.
     * If buffer is empty, load from module_name.
     */
    override void addObject(const(char)[] module_name, const(ubyte)[] buffer)
    {
        if (!buffer.length)
        {
            assert(module_name.length);
            OutBuffer b;
            if (readFile(Loc.initial, module_name, b))
                fatal();
            buffer = cast(ubyte[])b.extractSlice();
        }

        // If it's already an ar archive, extract its WASM members.
        if (buffer.length >= 8 && memcmp(buffer.ptr, "!<arch>\n".ptr, 8) == 0)
        {
            extractArchive(buffer);
            return;
        }

        // Validate WASM magic number (\0asm).
        if (buffer.length < 4 || buffer[0] != 0 || buffer[1] != 0x61 ||
            buffer[2] != 0x73 || buffer[3] != 0x6d)
        {
            eSink.error(Loc.initial, "not a WASM object: %.*s",
                cast(int)module_name.length, module_name.ptr);
            return;
        }

        auto om = new WasmObjModule();
        om.name = FileName.name(module_name); // store basename
        om.data = buffer;
        time_t t;
        time(&t);
        om.file_time = cast(long)t;
        om.user_id = 0;
        om.group_id = 0;
        om.file_mode = (1 << 15) | (6 << 6) | (4 << 3) | (4 << 0); // 0100644
        objmodules.push(om);
    }

    /***************************************
     * Write library as a GNU/SVR4 ar archive.
     * No symbol index is written; wasm-ld builds its own from each
     * member's "linking" custom section.
     */
    protected override void writeLibToBuffer(ref OutBuffer libbuf)
    {
        // Assign name_offset for members whose names are too long for the inline field.
        // Inline fits: "name/" in 16 bytes → name can be at most 14 chars (15 - 1 for '/').
        uint noffset = 0;
        foreach (om; objmodules)
        {
            // name field = 16 bytes: name + '/' + spaces. Name ≤ 14 chars fits inline.
            if (om.name.length < AR_OBJECT_NAME_SIZE)
            {
                om.name_offset = uint.max; // fits inline
            }
            else
            {
                om.name_offset = noffset;
                noffset += cast(uint)(om.name.length + 2); // "name/\n"
            }
        }

        // Compute member offsets.
        uint moffset = 8; // "!<arch>\n"
        if (noffset)
        {
            uint padded = (noffset + 1) & ~1u;
            moffset += ArHeader.sizeof + padded; // // header + name table
        }
        foreach (om; objmodules)
        {
            if (moffset & 1)
                moffset++; // pad to even
            om.offset = moffset;
            moffset += ArHeader.sizeof + cast(uint)om.data.length;
        }

        libbuf.reserve(moffset);
        libbuf.write("!<arch>\n");

        // Write the long filename table (//) if needed.
        if (noffset)
        {
            ArHeader h;
            // The // member name field is exactly "//" (no extra / suffix, padded with spaces).
            fillArHeader(h, "//", noffset, 0, 0, 0, 0);
            libbuf.write((&h)[0 .. 1]);
            foreach (om; objmodules)
            {
                if (om.name_offset != uint.max)
                {
                    libbuf.write(om.name);
                    libbuf.write("/\n");
                }
            }
            if (noffset & 1)
                libbuf.writeByte('\n'); // pad to even
        }

        // Write object members.
        foreach (om; objmodules)
        {
            if (libbuf.length & 1)
                libbuf.writeByte('\n'); // pad to even before header

            ArHeader h;
            if (om.name_offset == uint.max)
            {
                // Short name: write "name/" padded to 16 chars.
                char[AR_OBJECT_NAME_SIZE] namefield = ' ';
                memcpy(namefield.ptr, om.name.ptr, om.name.length);
                namefield[om.name.length] = '/';
                fillArHeader(h, namefield[], om.data.length,
                    om.file_time, om.user_id, om.group_id, om.file_mode);
            }
            else
            {
                // Long name: "/offset" reference into // table.
                char[AR_OBJECT_NAME_SIZE + 1] namefield = ' ';
                int n = snprintf(namefield.ptr, namefield.sizeof, "/%u", om.name_offset);
                namefield[n] = ' '; // overwrite null terminator with space
                fillArHeader(h, namefield[0 .. AR_OBJECT_NAME_SIZE], om.data.length,
                    om.file_time, om.user_id, om.group_id, om.file_mode);
            }
            libbuf.write((&h)[0 .. 1]);
            libbuf.write(om.data);
        }
    }

private:

    // Extract WASM object members from an existing ar archive.
    void extractArchive(const(ubyte)[] buf)
    {
        uint offset = 8; // skip "!<arch>\n"
        const(char)[] nametab; // extended filename table (//)

        while (offset + ArHeader.sizeof <= buf.length)
        {
            auto h = cast(const(ArHeader)*)(buf.ptr + offset);
            offset += ArHeader.sizeof;

            // Parse size field (decimal, space-padded).
            import core.stdc.stdlib : strtoul;
            char* endptr;
            uint size = cast(uint)strtoul(cast(char*)h.file_size.ptr, &endptr, 10);
            if (offset + size > buf.length)
                break;

            const(char)[] memberName = h.object_name[];

            if (memberName.length >= 2 && memberName[0] == '/' && memberName[1] == '/')
            {
                // Extended filename table.
                nametab = cast(const(char)[])(buf.ptr + offset)[0 .. size];
            }
            else if (memberName[0] != '/' || memberName[1] == ' ')
            {
                // Regular object member — resolve name and add it.
                const(char)[] name;
                if (memberName[0] == '/')
                {
                    // Short / followed by space: shouldn't happen but skip.
                }
                else
                {
                    // Short name: strip trailing '/' and spaces.
                    name = memberName;
                    size_t end = name.length;
                    while (end > 0 && (name[end-1] == ' ' || name[end-1] == '/'))
                        end--;
                    name = name[0 .. end];
                }
                if (name.length)
                    addObject(name, cast(const(ubyte)[])(buf.ptr + offset)[0 .. size]);
            }
            else if (memberName[0] == '/' && memberName[1] != '/')
            {
                // Long name reference: "/offset" into nametab.
                import core.stdc.stdlib : strtoul;
                uint noff = cast(uint)strtoul(cast(char*)memberName.ptr + 1, null, 10);
                const(char)[] name;
                if (noff < nametab.length)
                {
                    const(char)[] rest = nametab[noff .. $];
                    size_t end = 0;
                    while (end < rest.length && rest[end] != '/' && rest[end] != '\n')
                        end++;
                    name = rest[0 .. end];
                }
                if (name.length)
                    addObject(name, cast(const(ubyte)[])(buf.ptr + offset)[0 .. size]);
            }

            offset += size;
            if (offset & 1)
                offset++; // align to even
        }
    }
}

// Fill an ar member header with the given fields.
// `nameField` must be exactly AR_OBJECT_NAME_SIZE (16) chars, already space-padded.
// Special names like "//" and "/" are passed as-is (no automatic '/' suffix added).
private void fillArHeader(ref ArHeader h, const(char)[] nameField,
    ulong dataSize, long fileTime, uint uid, uint gid, uint mode) nothrow
{
    memset(&h, ' ', ArHeader.sizeof);

    // Name field: copy up to 16 chars.
    size_t nlen = nameField.length < AR_OBJECT_NAME_SIZE ? nameField.length : AR_OBJECT_NAME_SIZE;
    memcpy(h.object_name.ptr, nameField.ptr, nlen);

    // Numeric fields: format then copy without null terminator.
    char[13] tmp = void;
    int n;

    n = snprintf(tmp.ptr, tmp.sizeof, "%-12lld", cast(long)fileTime);
    memcpy(h.file_time.ptr, tmp.ptr, AR_FILE_TIME_SIZE);

    n = snprintf(tmp.ptr, tmp.sizeof, "%-6u", uid);
    memcpy(h.user_id.ptr, tmp.ptr, AR_USER_ID_SIZE);

    n = snprintf(tmp.ptr, tmp.sizeof, "%-6u", gid);
    memcpy(h.group_id.ptr, tmp.ptr, AR_GROUP_ID_SIZE);

    n = snprintf(tmp.ptr, tmp.sizeof, "%-8o", mode);
    memcpy(h.file_mode.ptr, tmp.ptr, AR_FILE_MODE_SIZE);

    n = snprintf(tmp.ptr, tmp.sizeof, "%-10llu", cast(ulong)dataSize);
    memcpy(h.file_size.ptr, tmp.ptr, AR_FILE_SIZE_SIZE);

    h.trailer[0] = '`';
    h.trailer[1] = '\n';

    cast(void)n;
}
