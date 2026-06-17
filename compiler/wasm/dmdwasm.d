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
import dmd.backend.cc : block, Symbol;

import dmdwasm_lexdump : dumpTokens;
import dmdwasm_irdump : dumpFunctionIR;

/// All mutable global state, read back by JS through the dmdwasm_* accessors.
struct WasmBuffers
{
    /// JS writes the source here via dmdwasm_input_buffer (NUL-termination not required).
    ubyte[] input;

    /// The -vcg-ast dump.
    OutBuffer ast;

    /// Parser AST dump (printAST of the module, before semantic).
    OutBuffer parse;

    /// printAST dump *after* semantic analysis: same internal-class-name format
    /// as `parse`, but with types resolved and lowerings filled in.
    OutBuffer sema;

    /// Internal lexer dump: one output line per source line, listing the TOK enum
    /// member names of that line's tokens. Tokens carrying a value (literals,
    /// identifiers) get that value as a parenthesized postfix, e.g. float32Literal(3.5).
    OutBuffer lex;

    /// Backend IR (block/elem graph) right after lowering, before the optimizer
    /// (glue.backendIRDumpHook).
    OutBuffer ir;

    /// Backend IR after the -O global optimizer, before codegen
    /// (dout.backendIROptDumpHook). Comparing `ir` and `irOpt` shows what the
    /// optimizer did.
    OutBuffer irOpt;
}

__gshared WasmBuffers buffers;

extern (C):

ubyte* dmdwasm_input_buffer(size_t cap)
{
    buffers.input = (cast(ubyte*) pureMallocLike(cap))[0 .. cap];
    return buffers.input.ptr;
}

private void* pureMallocLike(size_t n)
{
    import core.stdc.stdlib : malloc;
    return malloc(n);
}

const(char)* dmdwasm_ast_ptr() => cast(const(char)*) buffers.ast[].ptr;
size_t       dmdwasm_ast_len() => buffers.ast[].length;
const(char)* dmdwasm_parse_ptr() => cast(const(char)*) buffers.parse[].ptr;
size_t       dmdwasm_parse_len() => buffers.parse[].length;
const(char)* dmdwasm_sema_ptr() => cast(const(char)*) buffers.sema[].ptr;
size_t       dmdwasm_sema_len() => buffers.sema[].length;
const(char)* dmdwasm_lex_ptr() => cast(const(char)*) buffers.lex[].ptr;
size_t       dmdwasm_lex_len() => buffers.lex[].length;
const(char)* dmdwasm_ir_ptr()  => cast(const(char)*) buffers.ir[].ptr;
size_t       dmdwasm_ir_len()  => buffers.ir[].length;
const(char)* dmdwasm_iropt_ptr() => cast(const(char)*) buffers.irOpt[].ptr;
size_t       dmdwasm_iropt_len() => buffers.irOpt[].length;
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
    import dmd.console : createConsole;
    import core.stdc.stdio : stderr;

    global._init();
    global.params.useUnitTests = false;
    global.params.v.color = true;
    global.console = cast(void*) createConsole(stderr);

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

    // target._init() copies the *host* `real_t` properties into RealProperties.
    // On x86_64 hosts that's the 80-bit x87 extended type, matching the target.
    // But this frontend runs on wasm, whose `real` is 128-bit (mant_dig 113), so
    // `real.mant_dig` would report 113 and float Phobos (std.math) would fail its
    // `mant_dig == 64` static asserts. We compile *for* x86_64, so override the
    // properties with the real x87 80-bit values.
    with (target.RealProperties)
    {
        mant_dig   = 64;
        dig        = 18;
        max_exp    = 16384;
        min_exp    = -16381;
        max_10_exp = 4932;
        min_10_exp = -4931;
        max        = 0x1.fffffffffffffffep+16383L;
        min_normal = 0x1p-16382L;
        epsilon    = 0x1p-63L;
    }

    Type_init();
    Id.initialize();
    Module._init();
    Expression._init();
    Objc._init();
    Loc._init();
    addDefaultVersionIdentifiers(global.params, target);
    CTFloat.initialize();
}

/// Run the frontend on `src` (length `len`) and fill the output buffers.
/// `optimize` runs the backend `-O` global optimizer; the web app compiles the
/// same source twice (optimize off then on) to fill the two disassembly panes.
void dmdwasm_run(const(char)* src, size_t len, int optimize)
{
    import dmd.dmodule : Module;
    import dmd.identifier : Identifier;
    import dmd.root.filename : FileName;
    import dmd.dsymbolsem : dsymbolSemantic, importAll, runDeferredSemantic;
    import dmd.semantic2 : semantic2;
    import dmd.semantic3 : semantic3;
    import dmd.hdrgen : moduleToBuffer;
    import dmd.printast : printAST, printASTLineMarkers;
    import dmd.astcodegen : ASTCodegen;

    // Emit per-node source-line markers in the printAST dumps so the web app can
    // synchronize highlighting between the source and the parse/semantic trees.
    printASTLineMarkers = true;

    buffers.ast.reset();
    buffers.ast.doindent = 1;
    buffers.parse.reset();
    buffers.sema.reset();
    buffers.lex.reset();
    buffers.ir.reset();
    buffers.irOpt.reset();

    initFrontend();

    // Register the full druntime source tree (baked into the wasm) so snippets
    // can `import core.stdc.stdio;` etc., and so the real `object` module (with
    // a class/TypeInfo layout matching the compiler) backs `class`/AA snippets.
    import druntime_embed : registerDruntime;
    registerDruntime();

    // Make fatal() recoverable instead of calling exit(): a freestanding wasm
    // exit kills the instance (the page must reload). Every fatal() is preceded
    // by an .error() that already bumped global.errors, and the continuation
    // paths are the same ones native dmd takes when gagged (e.g. a missing
    // import: read() returns false -> load() returns null). Returning true
    // turns the whole proc_exit crash class (missing/typo'd imports, etc.)
    // into ordinary errors the web app can display.
    import dmd.errors : fatalErrorHandler;
    fatalErrorHandler = () => true;

    enum fileName = "input.d";
    auto fb = (cast(ubyte*) src)[0 .. len] ~ cast(ubyte) '\0';
    global.fileManager.add(FileName(fileName), fb);

    // Internal lexer dump: token enum names per source line.
    dumpTokens(buffers.lex, fileName.ptr, cast(const(char)*) fb.ptr, len);

    auto id = Identifier.idPool("input");
    auto m = new Module(fileName, id, 0, 0);
    m.src = fb;
    m.importedFrom = m;
    m = m.parseModule!ASTCodegen();

    // Dump the AST exactly as the parser produced it (before any semantic
    // lowering), so the page can show the raw parse tree alongside -vcg-ast.
    printAST(m, buffers.parse);

    if (global.errors == 0)
    {
        m.importAll(null);
        m.dsymbolSemantic(null);
        runDeferredSemantic();
        m.semantic2(null);
        m.semantic3(null);
    }

    // Dump the AST again after semantic analysis: same internal-class-name
    // format as the parse tree, but now with types resolved and lowerings applied.
    printAST(m, buffers.sema);

    moduleToBuffer(buffers.ast, /*vcg_ast*/ true, m);

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
        // Annotate the disassembly with "; line N" markers so the web app can sync
        // source<->asm highlighting. Opt-in: plain native -vasm stays unmarked.
        import dmd.backend.x86.cgcod : vasmSourceLines;
        vasmSourceLines = true;
        driverParams.optimize = optimize != 0;   // -O drives both the optimized IR pane and the optimized disassembly
        backend_init(global.params, driverParams, target);
        ObjcGlue_initialize();

        // Register both per-function IR dumpers, then generate code. The pre-opt hook
        // fires before the optimizer (block/elem graph as lowered); the post-opt hook
        // fires after optfunc() and before codgen() rewrites the graph into machine code.
        import dmd.glue : backendIRDumpHook;
        import dmd.backend.dout : backendIROptDumpHook;
        backendIRDumpHook    = &dumpFunctionIRPre;
        backendIROptDumpHook = &dumpFunctionIROpt;
        generateCodeNoWrite(m);
        backendIRDumpHook    = null;
        backendIROptDumpHook = null;

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
    dmdwasm_run(snippet.ptr, snippet.length, 1);
    auto ast = buffers.ast[];
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

// Fuzz entry point: read a whole D source from stdin, run the frontend+backend on
// it, and print a one-line summary. Used by the fuzz harness, which launches one
// `wasmtime --invoke dmdwasm_run_stdin` process per test file under a wall-clock
// timeout so traps (nonzero exit) and infinite loops (timeout kill) are both caught.
void dmdwasm_run_stdin()
{
    import core.stdc.stdio : fread, stdin, stdout, printf, fflush;
    import core.stdc.stdlib : malloc, realloc;

    __wasm_call_ctors();

    size_t cap = 1 << 16, len = 0;
    char* buf = cast(char*) malloc(cap);
    while (true)
    {
        if (len == cap)
        {
            cap *= 2;
            buf = cast(char*) realloc(buf, cap);
        }
        const n = fread(buf + len, 1, cap - len, stdin);
        if (n == 0)
            break;
        len += n;
    }

    dmdwasm_run(buf, len, 1);
    printf("errors=%u astlen=%zu\n", global.errors, cast(size_t) buffers.ast[].length);
    fflush(stdout);
}

extern (D) nothrow:

/// glue.backendIRDumpHook: pre-optimization graph (as lowered).
private void dumpFunctionIRPre(Symbol* sfunc, block* startblock) => dumpFunctionIR(buffers.ir, sfunc, startblock);

/// dout.backendIROptDumpHook: post-optimization graph (after optfunc, before codgen).
private void dumpFunctionIROpt(Symbol* sfunc, block* startblock) => dumpFunctionIR(buffers.irOpt, sfunc, startblock);
