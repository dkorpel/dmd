/**
 * A library in the GNU/SVR4 ar archive format for WebAssembly.
 *
 * The ar format is shared with the ELF library (same header structure and
 * symbol-table layout); see dmd.lib.ArHeader and arFillHeader() in package.d.
 * wasm-ld reads WASM object members from the archive and uses the symbol table
 * for lazy linking, exactly as LDC and llvm-ar produce it.
 *
 * Copyright:   Copyright (C) 1999-2026 by The D Language Foundation, All Rights Reserved
 * License:     $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/compiler/src/dmd/lib/wasm.d, _libwasm.d)
 */

module dmd.lib.wasm;

import core.stdc.stdlib : strtoul;
import core.stdc.string : memcmp, strlen;
import core.stdc.time : time, time_t;

import dmd.errors : fatal;
import dmd.lib;
import dmd.lib.scanwasm;
import dmd.location;
import dmd.root.array;
import dmd.root.filename;
import dmd.root.port;
import dmd.root.rmem;
import dmd.root.string;
import dmd.root.stringtable;
import dmd.common.outbuffer;
import dmd.utils : readFile;

// Entry point (only public symbol in this module).
package(dmd.lib) extern (C++) Library LibWasm_factory()
{
    return new LibWasm();
}

private:
nothrow:

struct WasmObjSymbol
{
    const(char)[] name;
    WasmObjModule* om;
}

struct WasmObjModule
{
    const(char)[] name;  // basename used in ar header (null-terminated)
    const(ubyte)[] data; // raw bytes of the WASM object
    long file_time;
    uint user_id;
    uint group_id;
    uint file_mode;
    int  name_offset; // offset into // name table, or -1 if inline
    uint offset;      // byte offset of this member in the archive
    uint length;      // same as data.length but kept as uint for arFillHeader
    bool scan;        // true = scan for symbols
}

alias WasmObjModules = Array!(WasmObjModule*);
alias WasmObjSymbols = Array!(WasmObjSymbol*);

final class LibWasm : Library
{
    WasmObjModules objmodules;
    WasmObjSymbols objsymbols;
    StringTable!(WasmObjSymbol*) tab;

    extern (D) this()
    {
        tab._init(14_000);
    }

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

        // Already an ar archive → extract WASM members from it.
        if (buffer.length >= 8 && memcmp(buffer.ptr, "!<arch>\n".ptr, 8) == 0)
        {
            extractArchive(buffer, module_name);
            return;
        }

        // Validate WASM magic (\0asm).
        if (buffer.length < 4 || buffer[0] != 0 || buffer[1] != 0x61 ||
            buffer[2] != 0x73 || buffer[3] != 0x6d)
        {
            eSink.error(Loc.initial, "not a WASM object: %.*s",
                cast(int)module_name.length, module_name.ptr);
            return;
        }

        auto om = new WasmObjModule();
        om.name = toCString(FileName.name(module_name));
        om.data = buffer;
        om.length = cast(uint)buffer.length;
        om.scan = true;

        time_t t;
        time(&t);
        om.file_time = cast(long)t;
        om.user_id = 0;
        om.group_id = 0;
        om.file_mode = (1 << 15) | (6 << 6) | (4 << 3) | (4 << 0); // 0100644
        objmodules.push(om);
    }

    void addSymbol(WasmObjModule* om, const(char)[] name, int pickAny = 0) nothrow
    {
        auto s = tab.insert(name.ptr, name.length, null);
        if (!s)
        {
            if (!pickAny)
            {
                s = tab.lookup(name.ptr, name.length);
                assert(s);
                WasmObjSymbol* os2 = s.value;
                eSink.error(Loc.initial, "multiple definition of %s: %s and %s: %s",
                    om.name.ptr, name.ptr, os2.om.name.ptr, os2.name.ptr);
            }
        }
        else
        {
            auto os = new WasmObjSymbol();
            os.name = xarraydup(name);
            os.om = om;
            s.value = os;
            objsymbols.push(os);
        }
    }

    /***************************************
     * Write library as a GNU/SVR4 ar archive with a symbol table.
     * Compatible with wasm-ld and llvm-ar.
     */
    protected override void writeLibToBuffer(ref OutBuffer libbuf)
    {
        // 1. Scan object modules for symbols.
        foreach (om; objmodules)
        {
            if (om.scan)
                scanObjModule(om);
        }

        // 2. Assign long name offsets (// table) for names ≥ 15 chars.
        uint noffset = 0;
        foreach (om; objmodules)
        {
            // name field = 16 bytes: "name/" fits if name is ≤ 14 chars.
            if (strlen(om.name.ptr) < AR_OBJECT_NAME_SIZE)
                om.name_offset = -1;
            else
            {
                om.name_offset = cast(int)noffset;
                noffset += cast(uint)(strlen(om.name.ptr) + 2); // "name/\n"
            }
        }

        // 3. Compute member offsets (symbol table first, then // table, then data).
        //    Symbol table payload: 4-byte count + 4 bytes per symbol + symbol names + NULs.
        uint symtabPayload = 4;
        foreach (os; objsymbols)
            symtabPayload += 4 + cast(uint)(os.name.length + 1);

        uint moffset = 8; // "!<arch>\n"
        moffset += ArHeader.sizeof + symtabPayload;
        moffset += moffset & 1; // align to even

        if (noffset)
        {
            moffset += ArHeader.sizeof + ((noffset + 1) & ~1u);
        }

        foreach (om; objmodules)
        {
            moffset += moffset & 1;
            om.offset = moffset;
            moffset += ArHeader.sizeof + om.length;
        }

        libbuf.reserve(moffset);

        // 4. Write magic.
        libbuf.write("!<arch>\n");

        // 5. Write symbol table "/" member.
        {
            ArHeader h;
            arFillHeader(h, "/", -1, 0, 0, 0, 0, symtabPayload);
            // arFillHeader would turn "/" into "//", so fix the name field manually.
            // The "/" symbol-table member is a special case: name field = "/               "
            h.object_name[0] = '/';
            foreach (ref c; h.object_name[1 .. $])
                c = ' ';
            libbuf.write((&h)[0 .. 1]);

            // Payload: [count BE-u32] [offsets BE-u32...] [names NUL-terminated...]
            char[4] tmp;
            Port.writelongBE(cast(uint)objsymbols.length, tmp.ptr);
            libbuf.write(tmp[0 .. 4]);
            foreach (os; objsymbols)
            {
                Port.writelongBE(os.om.offset, tmp.ptr);
                libbuf.write(tmp[0 .. 4]);
            }
            foreach (os; objsymbols)
            {
                libbuf.write(os.name);
                libbuf.writeByte(0);
            }
        }
        if (libbuf.length & 1)
            libbuf.writeByte('\n');

        // 6. Write long filename table "//" if needed.
        if (noffset)
        {
            ArHeader h;
            // "//" member: name field = "//              " (no extra '/' suffix).
            arFillHeader(h, "/", -1, 0, 0, 0, 0, noffset);
            h.object_name[0] = '/';
            h.object_name[1] = '/';
            foreach (ref c; h.object_name[2 .. $])
                c = ' ';
            libbuf.write((&h)[0 .. 1]);
            foreach (om; objmodules)
            {
                if (om.name_offset >= 0)
                {
                    libbuf.writestring(om.name.ptr);
                    libbuf.write("/\n");
                }
            }
            if (noffset & 1)
                libbuf.writeByte('\n');
        }

        // 7. Write object members.
        foreach (om; objmodules)
        {
            if (libbuf.length & 1)
                libbuf.writeByte('\n');

            ArHeader h;
            arFillHeader(h, om.name.ptr, om.name_offset,
                om.file_time, om.user_id, om.group_id, om.file_mode, om.length);
            libbuf.write((&h)[0 .. 1]);
            libbuf.write(om.data);
        }
    }

private:

    void scanObjModule(WasmObjModule* om) nothrow
    {
        extern (D) void addSym(const(char)[] name, int pickAny) nothrow
        {
            this.addSymbol(om, name, pickAny);
        }
        scanWasmObjModule(&addSym, om.data, om.name.ptr, filename, eSink);
    }

    // Extract WASM object members from an existing ar archive.
    void extractArchive(const(ubyte)[] buf, const(char)[] archiveName)
    {
        uint offset = 8; // skip "!<arch>\n"
        const(char)[] nametab; // extended filename table (//)

        while (offset + ArHeader.sizeof <= buf.length)
        {
            auto h = cast(const(ArHeader)*)(buf.ptr + offset);
            offset += ArHeader.sizeof;

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
            else if (memberName[0] != '/')
            {
                // Short-name regular member.
                const(char)[] name = memberName;
                size_t end = name.length;
                while (end > 0 && (name[end-1] == ' ' || name[end-1] == '/'))
                    end--;
                if (end)
                    addObject(name[0 .. end], cast(const(ubyte)[])(buf.ptr + offset)[0 .. size]);
            }
            else if (memberName[0] == '/' && memberName[1] != '/' && memberName[1] != ' ')
            {
                // Long-name reference into // table.
                uint noff = cast(uint)strtoul(cast(char*)memberName.ptr + 1, null, 10);
                if (noff < nametab.length)
                {
                    const(char)[] rest = nametab[noff .. $];
                    size_t end = 0;
                    while (end < rest.length && rest[end] != '/' && rest[end] != '\n')
                        end++;
                    if (end)
                        addObject(rest[0 .. end], cast(const(ubyte)[])(buf.ptr + offset)[0 .. size]);
                }
            }
            // else: "/" symbol table or other special member — skip.

            offset += size;
            if (offset & 1)
                offset++;
        }
    }
}
