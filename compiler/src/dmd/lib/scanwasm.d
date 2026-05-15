/**
 * Extract exported symbols from a WebAssembly relocatable object module.
 *
 * Reads the "linking" custom section (WebAssembly tool-conventions v2) and
 * reports all globally-visible, defined, non-hidden function, data, and table
 * symbols to the caller via a delegate.  These are the symbol names that
 * wasm-ld uses when doing lazy archive linking.
 *
 * Reference: https://github.com/WebAssembly/tool-conventions/blob/main/Linking.md
 *
 * Copyright:   Copyright (C) 1999-2026 by The D Language Foundation, All Rights Reserved
 * License:     $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/compiler/src/dmd/lib/scanwasm.d, _scanwasm.d)
 */

module dmd.lib.scanwasm;

import dmd.errorsink;
import dmd.location;
import dmd.root.string : fTuple;

nothrow:

// Symbol-table flags (WASM_SYM_* from tool-conventions).
private enum WASM_SYM_BINDING_WEAK    = 0x01;
private enum WASM_SYM_BINDING_LOCAL   = 0x02;
private enum WASM_SYM_VISIBILITY_HIDDEN = 0x04;
private enum WASM_SYM_UNDEFINED       = 0x10;
private enum WASM_SYM_EXPLICIT_NAME   = 0x40;

// WASM section IDs.
private enum WASM_SECTION_CUSTOM   = 0;
private enum WASM_SECTION_FUNCTION = 3;
private enum WASM_SECTION_EXPORT   = 7;

// Linking subsection type for the symbol table.
private enum WASM_SYMBOL_TABLE = 8;

// Symbol kinds.
private enum WASM_SYMKIND_FUNCTION = 0;
private enum WASM_SYMKIND_DATA     = 1;
private enum WASM_SYMKIND_GLOBAL   = 2;
private enum WASM_SYMKIND_SECTION  = 3;
private enum WASM_SYMKIND_TAG      = 4;
private enum WASM_SYMKIND_TABLE    = 5;

/*****************************************
 * Read a WASM relocatable object and pass names of global (exported) symbols
 * to pAddSymbol.
 *
 * Params:
 *  pAddSymbol  = delegate to receive each symbol name
 *  base        = raw bytes of the WASM object module
 *  module_name = name used in error messages
 *  filename    = archive filename for error messages
 *  eSink       = error sink
 */
package(dmd.lib)
void scanWasmObjModule(void delegate(const(char)[] name, int pickAny) nothrow pAddSymbol,
    scope const(ubyte)[] base, const(char)* module_name,
    const(char)[] filename, ErrorSink eSink)
{
    void corrupt(int reason)
    {
        eSink.error(Loc.initial, "corrupt WASM object `%.*s` module `%s` %d",
            filename.fTuple.expand, module_name, reason);
    }

    // Validate WASM magic + version.
    if (base.length < 8)
        return corrupt(__LINE__);
    if (base[0] != 0 || base[1] != 0x61 || base[2] != 0x73 || base[3] != 0x6d)
        return corrupt(__LINE__);
    if (base[4] != 1 || base[5] != 0 || base[6] != 0 || base[7] != 0)
        return corrupt(__LINE__);

    size_t pos = 8; // skip magic + version

    // Helper: read a ULEB128 unsigned integer.
    uint readULEB(ref size_t p) nothrow
    {
        uint result = 0;
        uint shift = 0;
        while (p < base.length)
        {
            ubyte b = base[p++];
            result |= (b & 0x7F) << shift;
            if (!(b & 0x80))
                break;
            shift += 7;
        }
        return result;
    }

    // Helper: read a length-prefixed string (WASM "name" encoding).
    const(char)[] readName(ref size_t p) nothrow
    {
        uint len = readULEB(p);
        if (p + len > base.length)
            return null;
        auto s = cast(const(char)[])(base[p .. p + len]);
        p += len;
        return s;
    }

    // Scan sections looking for the "linking" custom section.
    while (pos + 2 <= base.length)
    {
        uint sectionId = readULEB(pos);
        uint sectionSize = readULEB(pos);
        size_t sectionEnd = pos + sectionSize;
        if (sectionEnd > base.length)
            return corrupt(__LINE__);

        if (sectionId != WASM_SECTION_CUSTOM)
        {
            pos = sectionEnd;
            continue;
        }

        // Read the custom section name.
        size_t nameStart = pos;
        const(char)[] sectionName = readName(pos);
        if (sectionName != "linking")
        {
            pos = sectionEnd;
            continue;
        }

        // Found the "linking" section — parse it.
        uint linkingVersion = readULEB(pos);
        if (linkingVersion != 2)
        {
            pos = sectionEnd;
            continue;
        }

        // Iterate subsections until WASM_SYMBOL_TABLE is found.
        while (pos < sectionEnd)
        {
            uint subtype = readULEB(pos);
            uint subsize = readULEB(pos);
            size_t subEnd = pos + subsize;
            if (subEnd > sectionEnd)
                return corrupt(__LINE__);

            if (subtype != WASM_SYMBOL_TABLE)
            {
                pos = subEnd;
                continue;
            }

            // Parse the symbol table.
            uint count = readULEB(pos);
            foreach (_; 0 .. count)
            {
                if (pos >= subEnd)
                    return corrupt(__LINE__);

                uint kind  = readULEB(pos);
                uint flags = readULEB(pos);

                bool isLocal     = (flags & WASM_SYM_BINDING_LOCAL) != 0;
                bool isUndefined = (flags & WASM_SYM_UNDEFINED) != 0;
                bool isHidden    = (flags & WASM_SYM_VISIBILITY_HIDDEN) != 0;
                bool hasName     = (flags & WASM_SYM_EXPLICIT_NAME) != 0;

                const(char)[] symName;

                if (kind == WASM_SYMKIND_FUNCTION || kind == WASM_SYMKIND_GLOBAL ||
                    kind == WASM_SYMKIND_TAG || kind == WASM_SYMKIND_TABLE)
                {
                    if (!isUndefined)
                        readULEB(pos); // index — consume but don't use
                    if (hasName || isUndefined)
                        symName = readName(pos);
                }
                else if (kind == WASM_SYMKIND_DATA)
                {
                    symName = readName(pos);
                    if (!isUndefined)
                    {
                        readULEB(pos); // segment index
                        readULEB(pos); // offset
                        readULEB(pos); // size
                    }
                }
                else if (kind == WASM_SYMKIND_SECTION)
                {
                    readULEB(pos); // section index
                }

                // Add to symbol table if global, defined, and visible.
                if (!isLocal && !isUndefined && !isHidden && symName.length)
                    pAddSymbol(symName, 1);
            }
            break; // only one WASM_SYMBOL_TABLE subsection
        }
        break; // only one "linking" section
    }
}
