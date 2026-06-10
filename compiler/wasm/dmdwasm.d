/**
 * WebAssembly entry point: run the DMD frontend on an in-memory source string
 * and return the `-vcg-ast` dump (and diagnostics) as buffers JS can read.
 *
 * Mirrors dmd.frontend.initDMD / parseModule / fullSemantic without importing
 * Phobos (which is unavailable in the freestanding wasm build).
 */
module dmdwasm;

import dmd.globals : global;
import dmd.location : Loc;
import dmd.common.outbuffer : OutBuffer;

// Output buffer (the -vcg-ast dump), read back by JS after dmdwasm_run.
__gshared OutBuffer astBuf;

// Parser AST dump (printAST of the module, before semantic), read back by JS.
__gshared OutBuffer parseBuf;

extern (C):

// JS writes the source here (NUL-terminated not required); returns the buffer.
__gshared ubyte[] inputBuf;

ubyte* dmdwasm_input_buffer(size_t cap)
{
    inputBuf = (cast(ubyte*) pureMallocLike(cap))[0 .. cap];
    return inputBuf.ptr;
}

private void* pureMallocLike(size_t n)
{
    import core.stdc.stdlib : malloc;
    return malloc(n);
}

const(char)* dmdwasm_ast_ptr() => cast(const(char)*) astBuf[].ptr;
size_t       dmdwasm_ast_len() => astBuf[].length;
const(char)* dmdwasm_parse_ptr() => cast(const(char)*) parseBuf[].ptr;
size_t       dmdwasm_parse_len() => parseBuf[].length;
uint         dmdwasm_errors()  => global.errors;

/// Initialize global DMD state (subset of frontend.initDMD, Phobos-free).
private void initFrontend()
{
    import dmd.cond : VersionCondition;
    import dmd.dmodule : Module;
    import dmd.expression : Expression;
    import dmd.id : Id;
    import dmd.mtype : Type;
    import dmd.objc : Objc;
    import dmd.target : target, defaultTargetOS, addDefaultVersionIdentifiers;
    import dmd.typesem : Type_init;
    import dmd.root.ctfloat : CTFloat;
    import dmd.tokens : initTokens;
    import dmd.imphint : initImportHints;

    global._init();
    global.params.useUnitTests = false;

    global.errors = 0;
    global.warnings = 0;
    global.gag = 0;
    global.gaggedErrors = 0;
    global.gaggedDeprecations = 0;

    import dmd.astenums : CHECKENABLE;
    with (global.params)
    {
        useInvariants  = CHECKENABLE.on;
        useIn          = CHECKENABLE.on;
        useOut         = CHECKENABLE.on;
        useArrayBounds = CHECKENABLE.on;
        useAssert      = CHECKENABLE.on;
        useSwitchError = CHECKENABLE.on;
        useNullCheck   = CHECKENABLE.off;
    }

    // D `shared static this` module ctors don't run without _d_run_main; invoke the
    // essential ones directly. initTokens initializes the identifier string table and
    // registers keywords (must precede Id.initialize); initImportHints sets up the
    // undefined-identifier hint table.
    initTokens();
    initImportHints();

    target.os = defaultTargetOS();
    target.isX86_64 = true;
    target.isX86 = false;
    target._init(global.params);
    Type_init();
    Id.initialize();
    Module._init();
    Expression._init();
    Objc._init();
    Loc._init();
    addDefaultVersionIdentifiers(global.params, target);
    CTFloat.initialize();
}

/// Run the frontend on `src` (length `len`) and fill astBuf / diagBuf.
void dmdwasm_run(const(char)* src, size_t len)
{
    import dmd.dmodule : Module;
    import dmd.identifier : Identifier;
    import dmd.root.filename : FileName;
    import dmd.dsymbolsem : dsymbolSemantic, importAll, runDeferredSemantic;
    import dmd.semantic2 : semantic2;
    import dmd.semantic3 : semantic3;
    import dmd.hdrgen : moduleToBuffer;
    import dmd.printast : printAST;
    import dmd.astcodegen : ASTCodegen;

    astBuf.reset();
    astBuf.doindent = 1;
    parseBuf.reset();

    initFrontend();

    // Inject a minimal `object` module so snippets typecheck without disk I/O.
    enum objSrc = import("object_min.d");
    global.fileManager.add(FileName("object.d"), cast(ubyte[]) (objSrc ~ '\0').dup);

    enum fileName = "input.d";
    auto fb = (cast(ubyte*) src)[0 .. len] ~ cast(ubyte) '\0';
    global.fileManager.add(FileName(fileName), fb);

    auto id = Identifier.idPool("input");
    auto m = new Module(fileName, id, 0, 0);
    m.src = fb;
    m.importedFrom = m;
    m = m.parseModule!ASTCodegen();

    // Dump the AST exactly as the parser produced it (before any semantic
    // lowering), so the page can show the raw parse tree alongside -vcg-ast.
    printAST(m, parseBuf);

    if (global.errors == 0)
    {
        m.importAll(null);
        m.dsymbolSemantic(null);
        runDeferredSemantic();
        m.semantic2(null);
        m.semantic3(null);
    }

    moduleToBuffer(astBuf, /*vcg_ast*/ true, m);

    // Backend code generation with -vasm: the x86 disassembly is printed to
    // stdout as a side effect of codegen. JS captures stdout into the asm pane;
    // no object file is written.
    if (global.errors == 0)
    {
        import dmd.dmdparams : driverParams;
        import dmd.dmsc : backend_init, backend_term;
        import dmd.glue : generateCodeNoWrite, ObjcGlue_initialize;
        import dmd.target : target;

        driverParams.vasm = true;
        backend_init(global.params, driverParams, target);
        ObjcGlue_initialize();
        generateCodeNoWrite(m);
        backend_term();

        // The disassembly is printed via printf; flush so the host (JS / wasmtime)
        // sees the complete stdout, since this entry point never exits the process.
        import core.stdc.stdio : fflush, stdout;
        fflush(stdout);
    }
}

// Self-test: compile an embedded snippet and print the AST dump to stdout.
// Run with `wasmtime run --invoke dmdwasm_selftest dmd.wasm` (no memory setup needed).
int dmdwasm_selftest()
{
    import core.stdc.stdio : fwrite, stdout, printf, fflush;
    static immutable string snippet =
        "module test;\n" ~
        "int add(int a, int b) { return a + b; }\n" ~
        "enum N = 3;\n" ~
        "int[] squares() { int[] r; foreach (i; 0 .. N) r ~= i * i; return r; }\n";
    dmdwasm_run(snippet.ptr, snippet.length);
    auto ast = astBuf[];
    printf("=== errors: %u, ast bytes: %zu ===\n", global.errors, ast.length);
    if (ast.length)
        fwrite(ast.ptr, 1, ast.length, stdout);
    fflush(stdout);
    return cast(int) ast.length;
}

private extern(C) void __wasm_call_ctors();

void _start()
{
    __wasm_call_ctors();   // run C/global ctors (data relocs etc.) before any work
    dmdwasm_selftest();
}
