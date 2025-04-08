module compiler.test.nondet;

import std;

string dumpbin = `C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.42.34433\bin\Hostx86\x86\dumpbin.exe`;

// C:/Program Files/Microsoft Visual Studio/2022/Community/Common7/IDE/devenv.exe

void main()
{
    enum tries = 300;
    string[tries] of;
    string[tries] as;
    string[tries] asms;
    string[tries] xxds;
    string[tries] outputs;
    // string[tries] diffs;
    ubyte[][tries] datas;
    foreach (i; 0 .. tries)
    {
        write("#");
        as[i] = "x"~i.text~".asm";
        enum tmpName = "tmp.exe";
        auto res = execute([`C:\Users\Dennis\Repos\dmd\generated\windows\release\64\dmd.exe`,
            "-conf=",
            "-m64",
            "-L/Brepro",
            `-I"C:\Users\Dennis\Repos\dmd\compiler\test\..\..\druntime\import`,
            `-I"C:\Users\Dennis\Repos\dmd\compiler\test\..\..\..\phobos"`,
            `-odC:\Users\Dennis\Repos\dmd\compiler\test\test_results\runnable\c`,
            //`-ofC:\Users\Dennis\Repos\dmd\compiler\test\test_results\runnable\c\exe1_2.exe`,
            "runnable/exe1.c",
            "-of="~tmpName
        ], ["LIB": `C:\Users\Dennis\Repos\dmd\compiler\test\..\..\..\phobos`]);
        assert(res.status == 0, res.output);
        outputs[i] = res.output;
        datas[i] = cast(ubyte[]) std.file.read(tmpName);

        void update()
        {
            of[i] = "x"~i.text~".exe";
            rename(tmpName, of[i]);
            asms[i] = execute([dumpbin, "/DISASM", tmpName]).output;
            xxds[i] = execute(["xxd", tmpName]).output;
        }

        if (i == 0)
            update();

        if (datas[i] != datas[0])
        {
            update();
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