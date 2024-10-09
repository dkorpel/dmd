/**
 * Encapsulates file/line/column locations.
 *
 * Copyright:   Copyright (C) 1999-2024 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 https://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/location.d, _location.d)
 * Documentation:  https://dlang.org/phobos/dmd_location.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/location.d
 */

module dmd.location;

import core.stdc.stdio;

import dmd.common.outbuffer;
import dmd.root.array;
import dmd.root.filename;
import dmd.root.string: toDString;

/// How code locations are formatted for diagnostic reporting
enum MessageStyle : ubyte
{
    digitalmars,  /// filename.d(line): message
    gnu,          /// filename.d:line: message, see https://www.gnu.org/prep/standards/html_node/Errors.html
    sarif         /// JSON SARIF output, see https://docs.oasis-open.org/sarif/sarif/v2.1.0/sarif-v2.1.0.html
}
/**
A source code location

Used for error messages, `__FILE__` and `__LINE__` tokens, `__traits(getLocation, XXX)`,
debug info etc.
*/
struct Loc
{
    private uint index = 0; // offset into lineTable[]

    static immutable Loc initial; /// use for default initialization of const ref Loc's

    extern (C++) __gshared bool showColumns;
    extern (C++) __gshared MessageStyle messageStyle;

nothrow:

    /*******************************
     * Configure how display is done
     * Params:
     *  showColumns = when to display columns
     *  messageStyle = digitalmars or gnu style messages
     */
    extern (C++) static void set(bool showColumns, MessageStyle messageStyle)
    {
        this.showColumns = showColumns;
        this.messageStyle = messageStyle;
    }

    static Loc singleFilename(const char* filename)
    {
        Loc result;
        locFileTable ~= BaseLoc(filename, locIndex, 0);
        result.index = locIndex++;
        return result;
    }

    /// utf8 code unit index relative to start of line, starting from 1
    extern (C++) uint charnum() const @nogc @safe
    {
        return SourceLoc(this).column;
    }

    /// line number, starting from 1
    extern (C++) uint linnum() const @nogc @trusted
    {
        return SourceLoc(this).line;
    }

    /***
     * Returns: filename for this location, null if none
     */
    extern (C++) const(char)* filename() const @nogc
    {
        return SourceLoc(this).filename.ptr; // _filename;
    }

    extern (C++) const(char)* toChars(
        bool showColumns = Loc.showColumns,
        MessageStyle messageStyle = Loc.messageStyle) const nothrow
    {
        OutBuffer buf;
        writeSourceLoc(buf, SourceLoc(this), showColumns, messageStyle);
        return buf.extractChars();
    }

    /**
     * Checks for equivalence by comparing the filename contents (not the pointer) and character location.
     *
     * Note:
     *  - Uses case-insensitive comparison on Windows
     *  - Ignores `charnum` if `Columns` is false.
     */
    extern (C++) bool equals(ref const(Loc) loc) const
    {
        SourceLoc lhs = SourceLoc(this);
        SourceLoc rhs = SourceLoc(loc);
        return (!showColumns || lhs.column == rhs.column) &&
               lhs.line == rhs.line &&
               FileName.equals(lhs.filename, rhs.filename);
    }

    /**
     * `opEquals()` / `toHash()` for AA key usage
     *
     * Compare filename contents (case-sensitively on Windows too), not
     * the pointer - a static foreach loop repeatedly mixing in a mixin
     * may lead to multiple equivalent filenames (`foo.d-mixin-<line>`),
     * e.g., for test/runnable/test18880.d.
     */
    extern (D) bool opEquals(ref const(Loc) loc) const @trusted nothrow @nogc
    {
        SourceLoc lhs = SourceLoc(this);
        SourceLoc rhs = SourceLoc(loc);

        return lhs.column == rhs.column &&
               lhs.line == rhs.line &&
               lhs.filename == rhs.filename;
    }

    /// ditto
    extern (D) size_t toHash() const @trusted nothrow
    {
        return hashOf(this.index);
    }

    /******************
     * Returns:
     *   true if Loc has been set to other than the default initialization
     */
    bool isValid() const pure @safe
    {
        return this.index != 0;
    }
}

/**
 * Format a source location for error messages
 *
 * Params:
 *   buf = buffer to write string into
 *   loc = source location to write
 *   showColumns = include column number in message
 *   messageStyle = select error message format
 */
void writeSourceLoc(ref OutBuffer buf,
    SourceLoc loc,
    bool showColumns,
    MessageStyle messageStyle) nothrow
{
    if (loc.filename.length == 0)
        return;
    buf.writestring(loc.filename);
    if (loc.line == 0)
        return;

    final switch (messageStyle)
    {
        case MessageStyle.digitalmars:
            buf.writeByte('(');
            buf.print(loc.line);
            if (showColumns && loc.column)
            {
                buf.writeByte(',');
                buf.print(loc.column);
            }
            buf.writeByte(')');
            break;
        case MessageStyle.gnu: // https://www.gnu.org/prep/standards/html_node/Errors.html
            buf.writeByte(':');
            buf.print(loc.line);
            if (showColumns && loc.column)
            {
                buf.writeByte(':');
                buf.print(loc.column);
            }
            break;
        case MessageStyle.sarif: // https://docs.oasis-open.org/sarif/sarif/v2.1.0/sarif-v2.1.0.html
            // No formatting needed here for SARIF
            break;
    }
}

/**
 * Describes a location in the source code as a file + line number + column number
 *
 * While `Loc` is a compact opaque location meant to be stored in the AST,
 * this struct has simple modifiable fields and is used for printing.
 */
struct SourceLoc
{
    const(char)[] filename; /// name of source file
    uint line; /// line number (starts at 1)
    uint column; /// column number (starts at 1)

    // aliases for backwards compatibility
    alias linnum = line;
    alias charnum = column;

    this(const(char)[] filename, uint line, uint column) nothrow @nogc pure @safe
    {
        this.filename = filename;
        this.line = line;
        this.column = column;
    }

    this(Loc loc) nothrow @nogc @trusted
    {
        if (loc.index == 0 || locFileTable.length == 0)
            return;

        foreach (i, ref locFile; locFileTable)
        {
            if (loc.index >= locFile.startIndex &&
                (i + 1 >= locFileTable.length || loc.index < locFileTable[i + 1].startIndex))
            {
                this = locFile.getSourceLoc(loc.index - locFile.startIndex);
                return;
            }
        }
    }
}

BaseLoc* newBaseLoc(const(char)* filename, size_t size) nothrow
{
    locFileTable ~= BaseLoc(filename, locIndex, 1);
    locIndex += size;
    return &locFileTable[$ - 1];
}

///
struct BaseLoc
{
@safe nothrow:

    const(char)* filename;
    uint startIndex; // Loc's with this index start here
    int startLine = 1;
    uint[] lines;
    BaseLoc[] substitutions;

    /// Register that a new line starts at `offset`
    void newLine(uint offset)
    {
        lines ~= offset;
    }

    Loc getLoc(uint offset) @nogc
    {
        Loc result;
        // import std.stdio; debug writeln(startIndex, " + ", offset, " = ", startIndex + offset);
        result.index = startIndex + offset;
        return result;
    }

    /// Handles #file and #line directives
    void addSubstitution(uint offset, const(char)* filename, uint linnum)
    {
        substitutions ~= BaseLoc(filename, offset, cast(int) (linnum - (lines.length + startLine + 1)));
    }

    SourceLoc substitute(SourceLoc loc, uint offset) @nogc @system
    {
        // printf("substitutions: %d\n", cast(int) substitutions.length);
        size_t latest = -1;
        foreach (i, ref sub; substitutions)
        {
            if (offset >= sub.startIndex)
                latest = i;
            else
                break;
        }
        if (latest != -1)
        {
            if (substitutions[latest].filename)
                loc.filename = substitutions[latest].filename.toDString;
            loc.linnum += substitutions[latest].startLine;
        }
        return loc;
    }

    SourceLoc getSourceLoc(uint offset) @nogc @system
    {
        // import std.stdio;
        // debug writeln("getSourceLoc ", offset);
        size_t lineIndex = lines.length;
        uint lineStartOffset = 0;
        foreach (i; 0 .. lines.length)
        {
            if (lines[i] > offset)
            {
                lineIndex = i;
                lineStartOffset = i > 0 ? lines[i - 1] : 0;
                break;
            }
        }
        return this.substitute(
            SourceLoc(filename.toDString, cast(uint) (lineIndex + startLine), 1 + offset - lineStartOffset),
            offset
        );
    }

    SourceLoc getSourceLocBinary(uint offset) @nogc @system
    {
        size_t lineIndex = lines.length;
        uint lineStartOffset = 0;

        size_t lo = 0;
        size_t hi = lines.length + -1;
        while (lo < hi)
        {
            const mid = lo + (hi - lo) / 2;
            if (offset < lines[mid])
                hi = mid;
            else if (offset > lines[mid])
                lo = mid + 1;
            else
            {
                lineIndex = mid;
                lineStartOffset = mid > 0 ? lines[mid - 1] : 0;
                break;
            }
        }
        return SourceLoc("a", cast(int) lineIndex, lineStartOffset);
    }
}

__gshared uint locIndex = 1; // Index of start of the file
__gshared BaseLoc[] locFileTable;

version(none) LineEntry find(T)(int offset, T[] lineTable)
{

}

unittest
{
    // dmd -i -g -unittest -main -run dmd/location.d
    BaseLoc loc;

    loc.newLine(10);
    loc.newLine(20);

    import std;
    writeln = loc.getSourceLocBinary(0);
    writeln = loc.getSourceLocBinary(10);
    writeln = loc.getSourceLocBinary(9);
    writeln = loc.getSourceLocBinary(13);
    writeln = loc.getSourceLocBinary(20);
}
