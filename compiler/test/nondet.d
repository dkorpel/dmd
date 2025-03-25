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
        execute([`C:\Users\Dennis\Repos\dmd\generated\windows\debug\64\dmd.exe`, "testi.i", "-lib", "-of=tmp.lib"]);
        asms[i] = execute([dumpbin, "/DISASM", "tmp.lib"]).output;
        xxds[i] = execute(["xxd", "tmp.lib"]).output;
        rename("tmp.lib", of[i]);
        datas[i] = cast(ubyte[]) std.file.read(of[i]);

        version(none) if (datas[i] != datas[0])
        {
            writeln("FILE ", i, " differs");
            std.file.write("a.txt", xxds[i]);
            std.file.write("b.txt", xxds[0]);
            execute(["diff", "a.txt", "b.txt"]).output.writeln;
        }

        if (asms[i] != asms[0])
        {
            writeln("ASM ", i, " differs");
            execute(["diff", asms[i], asms[0]]).output.writeln;
            return;
        }
    }

    writeln("Different files:", datas[].sort.uniq.walkLength);
}