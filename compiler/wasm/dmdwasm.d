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

// printAST dump of the module *after* semantic analysis, read back by JS.
// Same internal-class-name format as parseBuf, but with types/lowerings filled in.
__gshared OutBuffer semaBuf;

// Internal lexer dump: one output line per source line, listing the TOK enum
// member names of that line's tokens. Tokens carrying a value (literals,
// identifiers) get that value as a parenthesized postfix, e.g. float32Literal(3.5).
__gshared OutBuffer lexBuf;

// Backend IR dumps of the `block`/`elem` graph of each function, at two stages:
//   irBuf    — right after lowering, before the optimizer (glue.backendIRDumpHook)
//   irOptBuf — after the -O global optimizer, before codegen (dout.backendIROptDumpHook)
// Comparing the two shows what the optimizer did. See the bottom of this file.
__gshared OutBuffer irBuf;
__gshared OutBuffer irOptBuf;

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
const(char)* dmdwasm_sema_ptr() => cast(const(char)*) semaBuf[].ptr;
size_t       dmdwasm_sema_len() => semaBuf[].length;
const(char)* dmdwasm_lex_ptr() => cast(const(char)*) lexBuf[].ptr;
size_t       dmdwasm_lex_len() => lexBuf[].length;
const(char)* dmdwasm_ir_ptr()  => cast(const(char)*) irBuf[].ptr;
size_t       dmdwasm_ir_len()  => irBuf[].length;
const(char)* dmdwasm_iropt_ptr() => cast(const(char)*) irOptBuf[].ptr;
size_t       dmdwasm_iropt_len() => irOptBuf[].length;
uint         dmdwasm_errors()  => global.errors;

// TOK value -> enum member name (e.g. TOK.add -> "add"), built at compile time.
import dmd.tokens : TOK;
private immutable string[TOK.max + 1] tokNames = () {
    string[TOK.max + 1] names;
    static foreach (member; __traits(allMembers, TOK))
        names[__traits(getMember, TOK, member)] = member;
    return names;
}();

// True for tokens that carry user data worth showing as a parenthesized postfix
// (numeric/char/string literals and identifiers). Keywords/punctuation don't.
private bool tokenHasValue(TOK v)
{
    switch (v)
    {
    case TOK.int32Literal, TOK.uns32Literal, TOK.int64Literal, TOK.uns64Literal,
         TOK.int128Literal, TOK.uns128Literal,
         TOK.float32Literal, TOK.float64Literal, TOK.float80Literal,
         TOK.imaginary32Literal, TOK.imaginary64Literal, TOK.imaginary80Literal,
         TOK.charLiteral, TOK.wcharLiteral, TOK.dcharLiteral, TOK.wchar_tLiteral,
         TOK.identifier, TOK.string_, TOK.hexadecimalString, TOK.interpolated:
        return true;
    default:
        return false;
    }
}

/// Lex `src` (NUL-terminated, `len` bytes before the NUL) and fill lexBuf with
/// one line per source line listing that line's token enum names.
private void dumpTokens(const(char)* fileName, const(char)* src, size_t len)
{
    import dmd.lexer : Lexer;
    import dmd.tokens : Token;

    lexBuf.reset();
    scope lexer = new Lexer(fileName, src, 0, len, false, false, global.errorSinkNull, null);

    uint curLine = 1;
    bool atLineStart = true;
    lexer.nextToken();
    while (lexer.token.value != TOK.endOfFile)
    {
        const L = lexer.token.loc.linnum;
        while (curLine < L)
        {
            lexBuf.writeByte('\n');
            curLine++;
            atLineStart = true;
        }
        if (!atLineStart)
            lexBuf.writeByte(' ');
        lexBuf.writestring(tokNames[lexer.token.value]);
        if (tokenHasValue(lexer.token.value))
        {
            lexBuf.writeByte('(');
            lexer.token.toString((ubyte c) { lexBuf.writeByte(c); });
            lexBuf.writeByte(')');
        }
        atLineStart = false;
        lexer.nextToken();
    }
    lexBuf.writeByte('\n');
}

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
    semaBuf.reset();
    lexBuf.reset();
    irBuf.reset();
    irOptBuf.reset();

    initFrontend();

    // Inject a minimal `object` module so snippets typecheck without disk I/O.
    enum objSrc = import("object_min.d");
    global.fileManager.add(FileName("object.d"), cast(ubyte[]) (objSrc ~ '\0').dup);

    enum fileName = "input.d";
    auto fb = (cast(ubyte*) src)[0 .. len] ~ cast(ubyte) '\0';
    global.fileManager.add(FileName(fileName), fb);

    // Internal lexer dump: token enum names per source line.
    dumpTokens(fileName.ptr, cast(const(char)*) fb.ptr, len);

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

    // Dump the AST again after semantic analysis: same internal-class-name
    // format as the parse tree, but now with types resolved and lowerings applied.
    printAST(m, semaBuf);

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
        driverParams.optimize = true;   // run the -O global optimizer so the two IR panes differ
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

// ===========================================================================
// Backend IR (block/elem graph) printer
//
// Written from scratch instead of reusing backend/debugprint.d: every node is
// labelled with the actual backend enum member name (OPadd, TYint, BC.goto_),
// and those names are derived from the enums themselves by compile-time
// reflection, so the dump can never drift out of sync with the source.
//
// Output is one `function` per codegen'd function; under it the blocks in
// Bnext order (numbered B1..Bn) with their BC exit condition and successor
// edges; under each block its `elem` tree as an indented preorder dump showing
// the full binary-tree structure (E1/E2 children) but not every leaf field.
// ===========================================================================
extern (D):
private:
nothrow:

import dmd.backend.cc : block, Symbol, BC;
import dmd.backend.el : elem;
import dmd.backend.oper;
import dmd.backend.ty;

/// OPER value -> "OPxxx" enum member name. OPER is an anonymous `enum {}` aliased
/// to int, so reflect over the module's members and keep the integer constants
/// whose name starts with "OP" (skipping the OPMAX sentinel).
immutable string[OPMAX] operNames = () {
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
immutable string[TYMAX] tyNames = () {
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
immutable string[BC.max + 1] bcNames = () {
    string[BC.max + 1] names;
    static foreach (m; __traits(allMembers, BC))
        names[__traits(getMember, BC, m)] = m;
    return names;
}();

string operName(uint op) => (op < OPMAX && operNames[op].length) ? operNames[op] : "OP?";

string tyName(tym_t ty)
{
    const b = tybasic(ty);
    return (b < TYMAX && tyNames[b].length) ? tyNames[b] : "TY?";
}

void irIndent(OutBuffer* buf, int depth)
{
    foreach (_; 0 .. depth)
        buf.writestring("  ");
}

/// Print one `elem` and, recursively, its E1/E2 subtrees (preorder, indented).
void dumpElem(OutBuffer* buf, elem* e, int depth)
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
void dumpFunctionIR(OutBuffer* buf, Symbol* sfunc, block* startblock)
{
    // Number the blocks 1..n along the Bnext chain for readable references.
    uint n = 0;
    for (block* b = startblock; b; b = b.Bnext)
        b.Bnumber = ++n;

    buf.writestring("function ");
    if (sfunc)
        buf.writestring(sfunc.Sident.ptr);
    buf.writestring("()\n");

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

/// glue.backendIRDumpHook: pre-optimization graph (as lowered).
void dumpFunctionIRPre(Symbol* sfunc, block* startblock) => dumpFunctionIR(&irBuf, sfunc, startblock);

/// dout.backendIROptDumpHook: post-optimization graph (after optfunc, before codgen).
void dumpFunctionIROpt(Symbol* sfunc, block* startblock) => dumpFunctionIR(&irOptBuf, sfunc, startblock);
