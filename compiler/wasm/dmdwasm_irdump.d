/**
 * Backend IR (block/elem graph) printer for the wasm web app's IR panes.
 *
 * Written from scratch instead of reusing backend/debugprint.d: every node is
 * labelled with the actual backend enum member name (OPadd, TYint, BC.goto_),
 * and those names are derived from the enums themselves by compile-time
 * reflection, so the dump can never drift out of sync with the source.
 *
 * Output is one `function` per codegen'd function; under it the blocks in
 * Bnext order (numbered B1..Bn) with their BC exit condition and successor
 * edges; under each block its `elem` tree as an indented preorder dump showing
 * the full binary-tree structure (E1/E2 children) but not every leaf field.
 */
module dmdwasm_irdump;

import dmd.common.outbuffer : OutBuffer;
import dmd.backend.cc : block, Symbol, BC;
import dmd.backend.el : elem;
import dmd.backend.oper;
import dmd.backend.ty;

nothrow:

/// OPER value -> "OPxxx" enum member name. OPER is an anonymous `enum {}` aliased
/// to int, so reflect over the module's members and keep the integer constants
/// whose name starts with "OP" (skipping the OPMAX sentinel).
private immutable string[OPMAX] operNames = () {
    string[OPMAX] names;
    static foreach (m; __traits(allMembers, dmd.backend.oper))
    {{
        static if (m.length >= 2 && m[0] == 'O' && m[1] == 'P' && m != "OPMAX"
                && __traits(compiles, { enum int v = __traits(getMember, dmd.backend.oper, m); }))
        {
            enum int v = __traits(getMember, dmd.backend.oper, m);
            static if (v >= 0 && v < OPMAX)
                if (names[v].length == 0)
                    names[v] = m;
        }
    }}
    return names;
}();

/// Basic-type value -> "TYxxx" name, same trick. Excludes the separate TYFLxxx
/// flag enum (overlapping small values) and the TYMAX sentinel.
private immutable string[TYMAX] tyNames = () {
    string[TYMAX] names;
    static foreach (m; __traits(allMembers, dmd.backend.ty))
    {{
        static if (m.length >= 2 && m[0] == 'T' && m[1] == 'Y' && m != "TYMAX"
                && !(m.length >= 4 && m[0 .. 4] == "TYFL")
                && __traits(compiles, { enum int v = __traits(getMember, dmd.backend.ty, m); }))
        {
            enum int v = __traits(getMember, dmd.backend.ty, m);
            static if (v >= 0 && v < TYMAX)
                if (names[v].length == 0)
                    names[v] = m;
        }
    }}
    return names;
}();

/// BC is a real named enum, so reflect over it directly.
private immutable string[BC.max + 1] bcNames = () {
    string[BC.max + 1] names;
    static foreach (m; __traits(allMembers, BC))
        names[__traits(getMember, BC, m)] = m;
    return names;
}();

private string operName(uint op) => (op < OPMAX && operNames[op].length) ? operNames[op] : "OP?";

private string tyName(tym_t ty)
{
    const b = tybasic(ty);
    return (b < TYMAX && tyNames[b].length) ? tyNames[b] : "TY?";
}

private void irIndent(ref OutBuffer buf, int depth)
{
    foreach (_; 0 .. depth)
        buf.writestring("  ");
}

/// Print one `elem` and, recursively, its E1/E2 subtrees (preorder, indented).
private void dumpElem(ref OutBuffer buf, elem* e, int depth)
{
    irIndent(buf, depth);
    if (!e)
    {
        buf.writestring("(null)\n");
        return;
    }

    buf.writestring(operName(e.Eoper));
    buf.writeByte(' ');
    buf.writestring(tyName(e.Ety));

    // A few leaf operators carry data worth showing inline.
    switch (e.Eoper)
    {
        case OPconst:
            buf.writeByte(' ');
            if (tyfloating(e.Ety))
                buf.printf("%g", e.Vdouble);
            else
                buf.printf("%lld", cast(long) e.Vllong);
            break;

        case OPvar:
        case OPrelconst:
            if (e.Vsym)
            {
                buf.writeByte(' ');
                buf.writestring(e.Vsym.Sident.ptr);
            }
            if (e.Voffset)
                buf.printf("+%lld", cast(long) e.Voffset);
            break;

        case OPstring:
        case OPasm:
            if (e.Vstring)
            {
                buf.writestring(" \"");
                buf.writestring(e.Vstring);
                buf.writeByte('"');
            }
            break;

        default:
            break;
    }
    // Source-line marker (SOH + decimal line) so the web app can map this elem
    // back to the source line it came from. Omitted when the elem has no source
    // position (Slinnum == 0), so child nodes inherit their parent's line.
    if (e.Esrcpos.Slinnum)
        buf.printf("\x01%u", e.Esrcpos.Slinnum);
    buf.writeByte('\n');

    if (OTbinary(e.Eoper))
    {
        dumpElem(buf, e.E1, depth + 1);
        dumpElem(buf, e.E2, depth + 1);
    }
    else if (OTunary(e.Eoper))
        dumpElem(buf, e.E1, depth + 1);
}

/// Dump one function's block/elem graph into `buf`.
void dumpFunctionIR(ref OutBuffer buf, Symbol* sfunc, block* startblock)
{
    // Number the blocks 1..n along the Bnext chain for readable references.
    uint n = 0;
    for (block* b = startblock; b; b = b.Bnext)
        b.Bnumber = ++n;

    buf.writestring("function ");
    if (sfunc)
        buf.writestring(sfunc.Sident.ptr);
    // `\x010` resets the web app's source-line carry-forward so the function
    // header (and block headers, which inherit it) map to no source line,
    // rather than bleeding the previous function's last elem line.
    buf.writestring("()\x010\n");

    for (block* b = startblock; b; b = b.Bnext)
    {
        buf.printf("  B%u: BC.", b.Bnumber);
        buf.writestring(b.bc <= BC.max ? bcNames[b.bc] : "?");

        if (b.Bsucc.length)
        {
            buf.writestring(" -> ");
            foreach (i, s; b.Bsucc[])
            {
                if (i)
                    buf.writestring(", ");
                buf.printf("B%u", s ? s.Bnumber : 0);
            }
        }
        buf.writeByte('\n');

        if (b.Belem)
            dumpElem(buf, b.Belem, 2);
    }
    buf.writeByte('\n');
}
