import dshell;

int main()
{
    const lib = shellExpand("$OUTPUT_BASE/libtemplatemembers$LIBEXT");
    run("$DMD -m$MODEL -lib -of" ~ lib ~ " $EXTRA_FILES/libtemplatemembers.d");

    const data = cast(const(ubyte)[]) std.file.read(lib);
    assert(data[0 .. 8] == "!<arch>\n");
    size_t members;
    for (size_t i = 8; i + 60 <= data.length; )
    {
        const name = (cast(const(char)[]) data[i .. i + 16]).stripRight;
        size_t size;
        foreach (c; (cast(const(char)[]) data[i + 48 .. i + 58]).strip)
            size = size * 10 + (c - '0');
        if (name != "/" && name != "//" && !name.startsWith("__.SYMDEF"))
            members++;
        i += 60 + size + (size & 1);
    }
    if (members != 1)
    {
        writeln("expected 1 library member, got ", members);
        return 1;
    }
    return 0;
}
