module compiler.test.nondet;

import std;

string dumpbin = `C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.42.34433\bin\Hostx86\x86\dumpbin.exe`;

void main()
{
    enum tries = 50;
    string[tries] of;
    string[tries] as;
    string[tries] asms;
    string[tries] xxds;
    // string[tries] diffs;
    ubyte[][tries] datas;
    foreach (i; 0 .. tries)
    {
        write("#");
        of[i] = "x"~i.text~".obj";
        as[i] = "x"~i.text~".asm";
        enum tmpName = "tmp.exe";
        auto res = execute([`C:\Users\Dennis\Repos\dmd\generated\windows\release\64\dmd.exe`, "-m64", "runnable/exe1.c", "-L/Brepro", "-of="~tmpName]);
        assert(res.status == 0);
        // asms[i] = execute([dumpbin, "/DISASM", tmpName]).output;
        xxds[i] = execute(["xxd", tmpName]).output;
        rename(tmpName, of[i]);
        datas[i] = cast(ubyte[]) std.file.read(of[i]);

        if (datas[i] != datas[0])
        {
            writeln("FILE ", i, " differs");
            std.file.write("a.txt", xxds[i]);
            std.file.write("b.txt", xxds[0]);
            execute(["diff", "a.txt", "b.txt"]).output.writeln;
        }

        version(none) if (asms[i] != asms[0])
        {
            writeln("ASM ", i, " differs");
            execute(["diff", asms[i], asms[0]]).output.writeln;
            return;
        }
    }
    writeln();
    writeln("Different files:", datas[].sort.uniq.walkLength);
}