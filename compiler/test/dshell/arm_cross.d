#!/usr/bin/env rdmd
/**
Cross-compile AArch64 runnable tests and execute them under qemu-aarch64.

Can be run directly or via test runner:
```
rdmd compiler/test/dshell/arm_cross.d
compiler/test/run.d arm
```
Or via the test runner:
Install prerequisites:

Debian/Ubuntu:
```
sudo apt install qemu-user clang lld gcc-aarch64-linux-gnu
```

Arch Linux:
```
sudo pacman -S qemu-user clang lld aarch64-linux-gnu-gcc
```
*/
module arm_cross;

import std.algorithm : canFind, filter, map;
import std.array : replace;
import std.array : array, join;
import std.file : dirEntries, exists, mkdirRecurse, remove, SpanMode, tempDir;
import std.file : fileWrite = write;
import std.path;
import std.process;
import std.stdio;

// When run via run.d the DMD env var is set; otherwise fall back to the built binary.
string dmd()
{
    import tools.paths : dmdPath;

    auto env = environment.get("DMD");
    return env ? env : dmdPath;
}

int main()
{
    foreach (tool; ["qemu-aarch64", "clang", "ld.lld"])
    {
        if (!toolExists(tool))
        {
            writeln("Skipping arm_cross: '", tool, "' not found in PATH");
            return 0;
        }
    }

    import tools.paths : projectRootDir;
    immutable testDir = projectRootDir.buildPath("compiler", "test", "runnable");
    immutable drImport = projectRootDir.buildPath("druntime", "import");
    immutable outDir = tempDir.buildPath("arm_cross_tests");

    if (!outDir.exists)
        outDir.mkdirRecurse;

    if (buildShim(outDir, drImport) != 0)
        return 1;

    int result = 0;
    foreach (testName; [
        "ai",
        "aliasassign",
        "arm",
        "bcraii",
        "bcraii2",
        "complex3",
        "dbitfields",
        "nan",
        "opcolon",
        "powinline",
        "real_to_float",
        "test14613",
        "test18472",
        "test19639",
        "test19825",
        "test20809",
        "test21301",
        "test21416",
        "test21822",
        "test22175",
        "test22384",
        "test23010",
        "test23278",
        "test24884",
        "traits_child",
        "tuple_default_parameters",
    ])
        result |= runTest(outDir, testDir, drImport, testName);

    foreach (testName; [
        "structlit_rvalue",
        "test21301",
        "test21424",
        "test21435",
        "test_real_array_param",
    ])
        result |= runTest(outDir, testDir, drImport, testName, "-O");

    immutable drSrc = projectRootDir.buildPath("druntime", "src");
    immutable drLib = buildDruntime(outDir, drSrc);
    if (drLib is null)
        return 1;

    foreach (testName; [
        "aliasthis",
        "bit",
        "casting",
        "class_opCmp",
        "closure",
        "declaration",
        "evalorder",
        "foreach",
        "inner",
        "interface",
        "interface1",
        "interpret",
        "literal",
        "mixin1",
        "newaa",
        "nogc",
        "opover",
        "s2ir",
        "staticaa",
        "staticarray",
        "template3",
        "test23",
        "testconst",
        "testtypeid",
        "traits_getPointerBitmap",
        "uniformctor",
        "unique_typeinfo_names",
    ])
        result |= runDruntimeTest(outDir, testDir, drSrc, drLib, testName);
    return result;
}

/**
Compile druntime for AArch64 into a static library, together with the assembly
files that provide what DMD has no AArch64 inline assembler for yet.
Returns: path to the library, or null on failure
*/
string buildDruntime(string outDir, string drSrc)
{
    static bool skip(string path)
    {
        foreach (part; ["core/sys/hurd/", "core/sys/wasi/", "rt/sections_wasm.d", "test_runner.d"])
            if (path.replace("\\", "/").canFind(part))
                return true;
        return false;
    }

    auto sources = dirEntries(drSrc, "*.d", SpanMode.depth)
        .map!(e => e.name)
        .filter!(name => !skip(name))
        .array;

    immutable drLib = buildPath(outDir, "libdruntime-aarch64.a");
    if (run([dmd, "-marm64", "-lib", "-I" ~ drSrc, "-of=" ~ drLib] ~ sources) != 0)
        return null;

    foreach (asmSrc; [
        buildPath(drSrc, "core", "thread", "fiber", "switch_context_asm.S"),
        buildPath(drSrc, "core", "internal", "atomic_aarch64.S"),
        buildPath(drSrc, "core", "thread", "stack_aarch64.S"),
    ])
    {
        immutable obj = buildPath(outDir, asmSrc.baseName.setExtension("o"));
        if (run(["clang", "--target=aarch64-linux-gnu", "-c", asmSrc, "-o", obj]) != 0)
            return null;
        if (run(["ar", "r", drLib, obj]) != 0)
            return null;
    }
    return drLib;
}

int runDruntimeTest(string outDir, string testDir, string drSrc, string drLib, string testName)
{
    immutable armO = buildPath(outDir, testName ~ "_dr.o");
    immutable armExe = buildPath(outDir, testName ~ "_dr");
    immutable armSrc = buildPath(testDir, testName ~ ".d");

    writefln("--- %s (AArch64, druntime) ---", testName);

    if (run([dmd, "-marm64", "-c", armSrc, "-I" ~ drSrc, "-of=" ~ armO]) != 0)
        return 1;

    if (run([
        "clang", "--target=aarch64-linux-gnu", "--sysroot=/usr/aarch64-linux-gnu",
        "-fuse-ld=lld", "-static", armO, drLib, "-lm", "-lpthread", "-ldl", "-o", armExe
    ]) != 0)
        return 1;

    return run(["qemu-aarch64", armExe]);
}

int buildShim(string outDir, string drImport)
{
    immutable shimSrc = buildPath(outDir, "drunmain.d");
    fileWrite(shimSrc, q{
        extern(C) int _d_run_main(int argc, char** argv, int function(char[][]) mainFunc)
        {
            return mainFunc(null);
        }
    });
    return run([
        dmd, "-marm64", "-betterC", "-c", shimSrc, "-I" ~ drImport,
        "-of=" ~ buildPath(outDir, "drunmain.o")
    ]);
}

int runTest(string outDir, string testDir, string drImport, string testName, string opt = null)
{
    immutable suffix = opt ? "_O" : "";
    immutable armO = buildPath(outDir, testName ~ suffix ~ ".o");
    immutable armExe = buildPath(outDir, testName ~ suffix);
    immutable armSrc = buildPath(testDir, testName ~ ".d");

    writefln("--- %s %s (AArch64) ---", testName, opt);

    if (run([
            dmd, "-marm64", "-betterC", "-c", armSrc, "-I" ~ drImport,
            "-of=" ~ armO
        ] ~ (opt ? [opt] : [])) != 0)
        return 1;

    if (run([
        "clang", "--target=aarch64-linux-gnu", "-fuse-ld=lld", "-static",
        armO, buildPath(outDir, "drunmain.o"), "-o", armExe
    ]) != 0)
        return 1;

    return run(["qemu-aarch64", armExe]);
}

int run(string[] args)
{
    writeln("+ ", args.join(" "));
    stdout.flush();
    return spawnProcess(args).wait;
}

bool toolExists(string program)
{
    return execute(["which", program]).status == 0;
}
