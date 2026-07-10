/**
 * Code coverage listing (.lst) writer for WebAssembly.
 *
 * A -cov compiled module's ctor calls `_d_cover_register2`; `rt_coverWrite`
 * (called by `rt.wasm.start._d_run_main` after `main` returns) writes one
 * `<module>.lst` per registered module in the same format as `rt.cover`.
 * Requires the host to preopen the source and destination directories
 * (the test harness runs wasmtime with `--dir`).
 *
 * Merge mode (`dmd_coverSetMerge`) is accepted but ignored: listings are
 * always rewritten from scratch.
 *
 * Copyright: Copyright (C) 1999-2026 by The D Language Foundation, All Rights Reserved
 * License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 */
module rt.wasm.cover;

import core.stdc.stdio;
import core.stdc.stdlib : malloc, free, exit, EXIT_FAILURE;

nothrow:

private struct Cover
{
    string filename;
    const(size_t)* validPtr;
    size_t validLen;
    uint[] data;
    ubyte minPercent;
}

private __gshared Cover[] gdata;
private __gshared string dstpath;
private __gshared string srcpath;

extern (C):

void dmd_coverDestPath(string pathname) { dstpath = pathname; }
void dmd_coverSourcePath(string pathname) { srcpath = pathname; }
void dmd_coverSetMerge(bool flag) {}

void _d_cover_register2(string filename, size_t[] valid, uint[] data, ubyte minPercent)
{
    gdata ~= Cover(filename, valid.ptr, valid.length, data, minPercent);
}

void _d_cover_register(string filename, size_t[] valid, uint[] data)
{
    _d_cover_register2(filename, valid, data, 0);
}

private bool validBit(ref const Cover c, size_t i) @nogc
{
    enum bits = 8 * size_t.sizeof;
    const word = i / bits;
    if (word >= c.validLen)
        return false;
    return ((c.validPtr[word] >> (i % bits)) & 1) != 0;
}

private uint digits(uint number) @nogc
{
    uint n = 1;
    while (number >= 10)
    {
        number /= 10;
        n++;
    }
    return n;
}

private char* toCstr(const(char)[] path) @nogc
{
    auto p = cast(char*) malloc(path.length + 1);
    if (!p)
        return null;
    p[0 .. path.length] = path[];
    p[path.length] = 0;
    return p;
}

private char[] readWholeFile(const(char)[] name) @nogc
{
    char* cname = toCstr(name);
    if (!cname)
        return null;
    FILE* f = fopen(cname, "rb");
    free(cname);
    if (!f)
        return null;
    fseek(f, 0, SEEK_END);
    const len = cast(size_t) ftell(f);
    fseek(f, 0, SEEK_SET);
    auto buf = cast(char*) malloc(len ? len : 1);
    if (!buf)
    {
        fclose(f);
        return null;
    }
    const got = fread(buf, 1, len, f);
    fclose(f);
    return buf[0 .. got];
}

private char[][] splitLines(char[] buf)
{
    char[][] lines;
    size_t start = 0;
    foreach (i, ch; buf)
    {
        if (ch == '\n')
        {
            size_t end = i;
            if (end > start && buf[end - 1] == '\r')
                end--;
            lines ~= buf[start .. end];
            start = i + 1;
        }
    }
    if (start < buf.length)
    {
        size_t end = buf.length;
        if (end > start && buf[end - 1] == '\r')
            end--;
        lines ~= buf[start .. end];
    }
    return lines;
}

private char[] expandTabs(char[] line)
{
    enum tabWidth = 8;
    bool hasTab = false;
    foreach (ch; line)
        if (ch == '\t')
            hasTab = true;
    if (!hasTab)
        return line;
    char[] r;
    size_t col = 0;
    foreach (ch; line)
    {
        if (ch == '\t')
        {
            do
            {
                r ~= ' ';
                col++;
            } while (col % tabWidth != 0);
        }
        else
        {
            r ~= ch;
            col++;
        }
    }
    return r;
}

private const(char)[] joinPath(const(char)[] dir, const(char)[] name)
{
    if (!dir.length)
        return name;
    char[] r;
    r ~= dir;
    if (dir[$ - 1] != '/')
        r ~= '/';
    r ~= name;
    return r;
}

// filename with path separators flattened to '-' (matching rt.cover's
// baseName, so runnable/a20.d becomes runnable-a20.lst) and the extension
// replaced by .lst
private const(char)[] lstName(const(char)[] filename)
{
    char[] flat;
    foreach (ch; filename)
        flat ~= (ch == '/' || ch == '\\' || ch == ':') ? '-' : ch;
    size_t dot = flat.length;
    foreach_reverse (i, ch; flat)
    {
        if (ch == '.')
        {
            dot = i;
            break;
        }
    }
    char[] r;
    r ~= flat[0 .. dot];
    r ~= ".lst";
    return r;
}

void rt_coverWrite()
{
    if (!srcpath.length)
    {
        import core.stdc.stdlib : getenv;
        import core.stdc.string : strlen;
        if (auto p = getenv("PWD"))
            srcpath = cast(string) p[0 .. strlen(p)];
    }
    foreach (ref c; gdata)
    {
        auto srcname = c.filename.length && c.filename[0] == '/'
            ? cast(const(char)[]) c.filename : joinPath(srcpath, c.filename);
        auto src = readWholeFile(srcname);
        if (src is null)
        {
            fprintf(stderr, "coverage: cannot read source %.*s\n",
                cast(int) srcname.length, srcname.ptr);
            continue;
        }
        auto lines = splitLines(src);

        auto outname = joinPath(dstpath, lstName(c.filename));
        char* cname = toCstr(outname);
        if (!cname)
            continue;
        FILE* flst = fopen(cname, "wb");
        free(cname);
        if (!flst)
        {
            fprintf(stderr, "coverage: cannot write %.*s\n",
                cast(int) outname.length, outname.ptr);
            continue;
        }

        const minLineLength = c.data.length < lines.length ? c.data.length : lines.length;

        uint maxCallCount;
        foreach (n; c.data[0 .. minLineLength])
            if (n > maxCallCount)
                maxCallCount = n;
        const int maxDigits = digits(maxCallCount) > 7 ? digits(maxCallCount) : 7;

        uint nno, nyes;
        foreach (i; 0 .. minLineLength)
        {
            auto line = expandTabs(lines[i]);
            const n = c.data[i];
            if (n == 0)
            {
                if (validBit(c, i))
                {
                    ++nno;
                    fprintf(flst, "%0*u|%.*s\n", maxDigits, 0u, cast(int) line.length, line.ptr);
                }
                else
                    fprintf(flst, "%*s|%.*s\n", maxDigits, " ".ptr, cast(int) line.length, line.ptr);
            }
            else
            {
                ++nyes;
                fprintf(flst, "%*u|%.*s\n", maxDigits, n, cast(int) line.length, line.ptr);
            }
        }

        if (nyes + nno)
        {
            const uint percent = (nyes * 100) / (nyes + nno);
            fprintf(flst, "%.*s is %d%% covered\n",
                cast(int) c.filename.length, c.filename.ptr, percent);
            if (percent < c.minPercent)
            {
                fprintf(stderr, "Error: %.*s is %d%% covered, less than required %d%%\n",
                    cast(int) c.filename.length, c.filename.ptr, percent, cast(int) c.minPercent);
                fclose(flst);
                exit(EXIT_FAILURE);
            }
        }
        else
            fprintf(flst, "%.*s has no code\n",
                cast(int) c.filename.length, c.filename.ptr);

        fclose(flst);
    }
}
