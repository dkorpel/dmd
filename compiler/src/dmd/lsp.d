/**
Implements dmd as a languag server, following the Language Server Protocol (LSP)

Provides 'hover' and 'go to definition' support for variables.

See_Also: https://microsoft.github.io/language-server-protocol/
*/
module dmd.lsp;

// dmd -main -unittest -i -J../.. -Jdmd/res -run dmd/lsp.d
// bdmdd && cat ../test/testlspinput.txt | dmdd -lsp
// echo -e "Content-Length: 49\r\n\r\n{\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"id\":1}" | nc -U /tmp/lsp-socket

import core.stdc.stdio;
import core.vararg;
import dmd.aggregate;
import dmd.astenums;
import dmd.ast_node;
import dmd.common.outbuffer;
import dmd.dclass;
import dmd.declaration;
import dmd.dmodule;
import dmd.dstruct;
import dmd.dsymbol;
import dmd.dsymbolsem;
import dmd.dtemplate;
import dmd.errors : ErrorSinkCompiler;
import dmd.errorsink;
import dmd.expression;
import dmd.func;
import dmd.globals;
import dmd.identifier;
import dmd.lexer;
import dmd.location;
import dmd.mtype;
import dmd.typesem : Type_init, toBasetype;
import dmd.root.filename;
import dmd.root.string;
import dmd.rootobject;
import dmd.semantic2;
import dmd.semantic3;
import dmd.target;
import dmd.tokens;
import dmd.visitor;


struct Lsp
{
    // dmd.globals.Param params;

    /// In-memory document store: URI -> content (kept in sync via textDocument/did* notifications)
    string[string] openDocuments;

    /// Sink that collects diagnostics produced during analyzeModule
    ErrorSinkLsp eSink;
}

/// One LSP diagnostic collected from an ErrorSink callback.
/// `line`/`column` are 1-based (as returned by SourceLoc); 0 means "unknown".
struct Diagnostic
{
    int line;
    int column;
    int severity; // 1=Error, 2=Warning, 3=Info, 4=Hint
    string message;
}

/// ErrorSink that captures diagnostics into a list instead of printing them.
/// One instance is owned by Lsp and reused across requests; callers must
/// clear `diagnostics` before each analysis run.
class ErrorSinkLsp : ErrorSinkCompiler
{
    Diagnostic[] diagnostics;

    private void add(Loc loc, int severity, const(char)* format, va_list ap) nothrow
    {
        OutBuffer msg;
        msg.vprintf(format, ap);
        auto sl = SourceLoc(loc);
        diagnostics ~= Diagnostic(sl.line, sl.column, severity, msg.extractSlice.idup);
    }

    private void appendToLast(const(char)* format, va_list ap) nothrow
    {
        if (diagnostics.length == 0)
            return;
        OutBuffer msg;
        msg.vprintf(format, ap);
        diagnostics[$ - 1].message ~= "\n" ~ msg.extractSlice.idup;
    }

    extern(C++) override:

    // Increment global.errors like ErrorSinkCompiler does: semantic passes rely
    // on it to know an error was already reported (e.g. ErrorStatement asserts it)
    void verror(Loc loc, const(char)* format, va_list ap)             { global.errors++; add(loc, 1, format, ap); }
    void vwarning(Loc loc, const(char)* format, va_list ap)           { add(loc, 2, format, ap); }
    void verrorSupplemental(Loc loc, const(char)* format, va_list ap) { appendToLast(format, ap); }
    void vwarningSupplemental(Loc loc, const(char)* format, va_list ap) { appendToLast(format, ap); }
}


extern(C++) class LspVisitor : SemanticTimeTransitiveVisitor
{
    alias visit = typeof(super).visit;

    int line;
    int column;
    ASTNode result;

    this(int line, int column)
    {
        this.line = line;
        this.column = column;
    }

    bool inLoc(Loc loc, Identifier ident)
    {
        if (!loc.isValid)
            return false;
        // fprintf(stderr, "[!] checking %s at %s\n", ident.toChars, loc.toChars);
        // fprintf(stderr, "[!] line %d ?= %d, col = %d > %d\n", this.line, sl.line, this.column, sl.column);
        auto sl = SourceLoc(loc);
        const endCol = sl.column + ident.toString().length;
        return (this.line == sl.line && this.column >= sl.column && this.column <= endCol);
    }

    override void visit(StructDeclaration d)
    {
        if (inLoc(d.loc, d.ident))
            this.result = d;
        super.visit(d);
    }

    override void visit(FuncDeclaration d)
    {
        if (inLoc(d.loc, d.ident))
            this.result = d;
        super.visit(d);
    }

    override void visit(ClassDeclaration d)
    {
        if (inLoc(d.loc, d.ident))
            this.result = d;
        super.visit(d);
    }

    override void visit(VarDeclaration d)
    {
        if (inLoc(d.loc, d.ident))
            this.result = d;
        // The variable's type may be written as a named type (e.g. `S s;`);
        // if the cursor is on the type name, resolve to the type's declaration
        else if (auto ti = d.originalType ? d.originalType.isTypeIdentifier() : null)
        {
            if (inLoc(ti.loc, ti.ident))
            {
                if (auto s = typeSymbolOf(d.type))
                    this.result = s;
            }
        }
        super.visit(d);
    }

    override void visit(VarExp e)
    {
        if (inLoc(e.loc, e.var.ident))
            this.result = e;
    }

    override void visit(DotVarExp e)
    {
        if (e.var && e.var.ident && inLoc(e.identLoc, e.var.ident))
            this.result = e;
        super.visit(e);
    }
}

/// Returns: the declaration of a struct/class/interface/enum type (following
/// one level of pointer indirection), or null for other types.
Dsymbol typeSymbolOf(Type t)
{
    if (!t)
        return null;
    t = t.toBasetype();
    if (auto tp = t.isTypePointer())
        t = tp.next.toBasetype();
    if (auto ts = t.isTypeStruct())
        return ts.sym;
    if (auto tc = t.isTypeClass())
        return tc.sym;
    if (auto te = t.isTypeEnum())
        return te.sym;
    return null;
}

/// Resolve the AST node under the cursor to the declaration it references,
/// for textDocument/definition. A declaration resolves to itself.
Dsymbol definitionTarget(ASTNode obj)
{
    if (auto e = isExpression(obj))
    {
        if (auto ve = e.isVarExp())
            return ve.var;
        if (auto dve = e.isDotVarExp())
            return dve.var;
        return null;
    }
    return isDsymbol(obj);
}

/// Write an LSP Location JSON object pointing at s's declaration.
/// Returns: false (and writes nothing) when s has no usable location.
bool writeLocation(ref OutBuffer buf, Dsymbol s)
{
    SourceLoc sl = SourceLoc(s.loc);
    if (sl.filename.length == 0 || sl.line == 0)
        return false;
    const len = s.ident ? cast(int) s.ident.toString().length : 1;
    buf.writestring(`{"uri":"file://`);
    buf.writeJsonString(sl.filename);
    buf.printf(`","range":{"start":{"line":%d,"character":%d},"end":{"line":%d,"character":%d}}}`,
        sl.line - 1, sl.column - 1, sl.line - 1, sl.column - 1 + len);
    return true;
}

/// Run the dmd pipeline (read → parse → semantic) on the document at `uri`.
/// Errors are routed through `lsp.eSink`; caller is responsible for clearing
/// `lsp.eSink.diagnostics` beforehand and for calling `deinitializeModule()`
/// when done with the returned module.
///
/// Returns: the post-semantic Module, or null on read/parse failure.
Module analyzeModule(ref Lsp lsp, string uri)
{
    Type_init();
    Module._init();
    Loc._init();

    SourceLoc sl = toSourceLoc(uri, Position(0, 0));
    const(char)[] p = FileName.name(sl.filename); // strip path
    auto ext = FileName.ext(sl.filename);
    p = p[0 .. $ - ext.length - 1];
    Loc loc = Loc.singleFilename(sl.filename.ptr);
    auto id = Identifier.idPool(p);
    Module m = new Module(loc, sl.filename, id, /*ddoc*/ true, false);

    // Use in-memory content if available (avoids reading unsaved file from disk)
    if (auto content = uri in lsp.openDocuments)
        m.src = cast(const(ubyte)[]) (*content ~ "\0\0\0\0");

    // Route compiler diagnostics into our collector for the duration of analysis
    auto savedSink = global.errorSink;
    auto savedErrors = global.errors;
    global.errorSink = lsp.eSink;
    global.errors = 0;
    scope(exit)
    {
        global.errorSink = savedSink;
        global.errors = savedErrors;
    }

    if (!m.read(loc))
        return null;
    m = m.parse();
    if (!m)
        return null;
    m.importedFrom = m;
    m.importAll(null);
    m.dsymbolSemantic(null);
    m.semantic2(null);
    m.semantic3(null);
    return m;
}

/// Reset compiler globals so the next analyzeModule call starts fresh.
void deinitializeModule()
{
    Type_init();
    Module.deinitialize();
    FuncDeclaration.lastMain = null;
}

/// Find the AST node under the cursor.
ASTNode findCursorObject(ref Lsp lsp, Params params)
{
    lsp.eSink.diagnostics = null;
    SourceLoc sl = toSourceLoc(params.textDocument.uri, params.position);
    Module m = analyzeModule(lsp, params.textDocument.uri);
    if (!m)
    {
        deinitializeModule();
        return null;
    }
    scope visitor = new LspVisitor(sl.line, sl.column);
    visitor.visit(m);
    deinitializeModule();
    return visitor.result;
}

/// LSP CompletionItemKind values for the kinds we currently emit.
private int completionKind(Dsymbol s)
{
    if (auto fd = s.isFuncDeclaration())
        return fd.isThis() ? 2 : 3;        // Method : Function
    if (s.isInterfaceDeclaration())
        return 8;                          // Interface
    if (s.isClassDeclaration())
        return 7;                          // Class
    if (s.isStructDeclaration())
        return 22;                         // Struct
    if (s.isEnumDeclaration())
        return 13;                         // Enum
    if (auto vd = s.isVarDeclaration())
        return vd.isField() ? 5 : 6;       // Field : Variable
    return 1;                              // Text (fallback)
}

/// Convert a list of symbols into LSP CompletionItem JSON, written
/// comma-separated into `buf` (no enclosing brackets).
void writeCompletionItems(ref OutBuffer buf, Dsymbol[] syms)
{
    bool first = true;
    foreach (s; syms)
    {
        if (!s || !s.ident)
            continue;
        if (!first)
            buf.writestring(",");
        first = false;
        buf.printf(`{"label":"%s","kind":%d`, s.ident.toChars, completionKind(s));
        auto d = s.isDeclaration();
        if (d && d.type)
        {
            buf.writestring(`,"detail":"`);
            buf.writeJsonString(d.type.toChars.toDString);
            buf.writestring(`"`);
        }
        buf.writestring(`}`);
    }
}

private bool isIdentChar(char c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c == '_';
}

/// What kind of completion the cursor position asks for.
struct CompletionContext
{
    bool member;              // completing `base.` member access
    const(char)[] baseIdent;  // identifier before the dot when member == true
}

/// Inspect the source text left of the cursor to see whether we're completing
/// a member access (`ident.` possibly followed by a partial member name).
CompletionContext completionContext(const(char)[] content, Position pos)
{
    // Convert (line, character), both 0-based, to a byte offset
    size_t off = 0;
    for (int line = 0; line < pos.line && off < content.length; off++)
    {
        if (content[off] == '\n')
            line++;
    }
    off += pos.character;
    if (off > content.length)
        off = content.length;

    // Skip back over the partially typed identifier, if any
    size_t i = off;
    while (i > 0 && isIdentChar(content[i - 1]))
        i--;

    CompletionContext result;
    if (i > 0 && content[i - 1] == '.')
    {
        const end = i - 1;
        size_t start = end;
        while (start > 0 && isIdentChar(content[start - 1]))
            start--;
        if (start < end)
        {
            result.member = true;
            result.baseIdent = content[start .. end];
        }
    }
    return result;
}

/// Finds the last variable declaration named `name` in the module.
extern(C++) final class VarFinder : SemanticTimeTransitiveVisitor
{
    alias visit = typeof(super).visit;

    const(char)[] name;
    VarDeclaration result;

    extern (D) this(const(char)[] name)
    {
        this.name = name;
    }

    override void visit(VarDeclaration d)
    {
        if (d.ident && d.ident.toString() == name)
            this.result = d;
        super.visit(d);
    }
}

/// Append the fields and methods of `ad` (and base classes) to `syms`,
/// skipping compiler-generated members.
void collectMembers(AggregateDeclaration ad, ref Dsymbol[] syms)
{
    while (ad)
    {
        if (ad.members)
        {
            foreach (s; *ad.members)
            {
                if (!s.ident || s.ident.toString().startsWith("__"))
                    continue;
                if (auto fd = s.isFuncDeclaration())
                {
                    if (!fd.isGenerated)
                        syms ~= fd;
                }
                else if (auto vd = s.isVarDeclaration())
                    syms ~= vd;
            }
        }
        auto cd = ad.isClassDeclaration();
        ad = cd ? cd.baseClass : null;
    }
}

/// Compute completion items for the request in `params`: members of the
/// aggregate before a `.`, or module-level types and functions otherwise.
/// No templates; only plainly declared types and functions are offered.
void completionItems(ref Lsp lsp, Params params, ref OutBuffer buf)
{
    lsp.eSink.diagnostics = null;
    CompletionContext ctx;
    if (auto content = params.textDocument.uri in lsp.openDocuments)
        ctx = completionContext(*content, params.position);

    Module m = analyzeModule(lsp, params.textDocument.uri);
    if (!m)
    {
        deinitializeModule();
        return;
    }

    Dsymbol[] syms;
    if (ctx.member)
    {
        scope finder = new VarFinder(ctx.baseIdent);
        finder.visit(m);
        if (finder.result)
        {
            if (auto sym = typeSymbolOf(finder.result.type))
                if (auto ad = sym.isAggregateDeclaration())
                    collectMembers(ad, syms);
        }
    }
    else if (m.members)
    {
        foreach (s; *m.members)
        {
            if (!s.ident)
                continue;
            if (s.isFuncDeclaration() || s.isAggregateDeclaration() || s.isEnumDeclaration())
                syms ~= s;
        }
    }
    writeCompletionItems(buf, syms);
    deinitializeModule();
}

/// Convert a list of Parameters into LSP SignatureInformation JSON for a
/// single signature, written into `buf`.
void writeSignature(ref OutBuffer buf, const(char)[] name, Parameter[] params_)
{
    buf.printf(`{"label":"%.*s(`, cast(int)name.length, name.ptr);
    bool first = true;
    foreach (p; params_)
    {
        if (!first)
            buf.writestring(", ");
        first = false;
        if (p.type)
            buf.printf("%s", p.type.toChars);
        if (p.ident)
            buf.printf(" %s", p.ident.toChars);
    }
    buf.writestring(`)","parameters":[`);
    first = true;
    foreach (p; params_)
    {
        if (!first)
            buf.writestring(",");
        first = false;
        buf.writestring(`{"label":"`);
        OutBuffer label;
        if (p.type)
            label.printf("%s", p.type.toChars);
        if (p.ident)
        {
            if (p.type)
                label.writestring(" ");
            label.printf("%s", p.ident.toChars);
        }
        buf.writeJsonString(label.extractSlice);
        buf.writestring(`"}`);
    }
    buf.writestring(`]}`);
}

/// MVP: emit a hard-coded signature with a hard-coded Parameter[].
void signatureHelp(ref Lsp lsp, Params params, ref OutBuffer buf)
{
    Type_init();
    Parameter[] sigParams = [
        new Parameter(Loc.initial, STC.none, Type.tint32,  Identifier.idPool("x"), null, null),
        new Parameter(Loc.initial, STC.none, Type.tstring, Identifier.idPool("y"), null, null),
    ];
    buf.writestring(`{"signatures":[`);
    writeSignature(buf, "exampleFunc", sigParams);
    buf.writestring(`],"activeSignature":0,"activeParameter":0}`);
}

/// Send a textDocument/publishDiagnostics notification with errors and
/// warnings collected from analyzing the document at `uri`.
void publishDiagnostics(ref Lsp lsp, string uri)
{
    lsp.eSink.diagnostics = null;
    analyzeModule(lsp, uri);
    deinitializeModule();

    OutBuffer buf;
    buf.writestring(`{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"`);
    buf.writeJsonString(uri);
    buf.writestring(`","diagnostics":[`);
    bool first = true;
    foreach (d; lsp.eSink.diagnostics)
    {
        if (!first)
            buf.writestring(",");
        first = false;
        // LSP positions are 0-based; SourceLoc is 1-based, 0 means unknown
        const line = d.line > 0 ? d.line - 1 : 0;
        const col = d.column > 0 ? d.column - 1 : 0;
        buf.printf(`{"range":{"start":{"line":%d,"character":%d},"end":{"line":%d,"character":%d}},"severity":%d,"message":"`,
            line, col, line, col + 1, d.severity);
        buf.writeJsonString(d.message);
        buf.writestring(`"}`);
    }
    buf.writestring(`]}}`);
    printf("Content-Length: %d\r\n\r\n", cast(int) buf.length);
    printf("%s", buf.extractChars());
    fflush(stdout);
}

int lspMain()
{
    import core.stdc.stdlib : atoi;

    Lsp lsp;
    lsp.eSink = new ErrorSinkLsp();
    auto eSink = lsp.eSink;

    char[] buffer = new char[16 * 1024];

    while (!feof(stdin))
    {
        buffer[] = '\0';
        int contentLength = 0;
        while (fgets(buffer.ptr, cast(int) buffer.length, stdin))
        {
            enum cl = "Content-Length:";
            auto line = buffer.ptr.toDString();
            if (line.startsWith(cl))
                contentLength = atoi(buffer.ptr + cl.length);

            if (line.startsWith("\r\n"))
                break; // end of header
        }

        // Fill buffer up to contentLength
        if (contentLength > buffer.length)
            buffer.length = contentLength;
        char[] json = buffer[0 .. contentLength];
        size_t totalRead = 0;
        while (totalRead < json.length)
        {
            size_t n = fread(json.ptr + totalRead, char.sizeof, json.length - totalRead, stdin);
            if (n == 0)
            {
                if (ferror(stdin))
                {
                    import core.stdc.errno;
                    eSink.error(Loc.initial, "errno = %d", errno);
                    return errno;
                }
                break; // EOF mid-message
            }
            totalRead += n;
        }

        // fprintf(stderr, "[!] Content length = %d\n", cast(int) contentLength);
        fprintf(stderr, "[!] Content = %.*s\n", cast(int) json.length, json.ptr);
        JsonRpc result;
        jsonParse(result, json, eSink);
        fprintf(stderr, "[!] Responding to %.*s\n", cast(int) result.method.length, result.method.ptr);
        lspRespond(lsp, result);
    }
    return 0;
}

void lspRespond(ref Lsp lsp, JsonRpc result)
{
    OutBuffer buf;
    buf.printf(`{"jsonrpc":"2.0","id":%d,"result":`, result.id);

    if (result.method == "initialize")
    {
        buf.writestring(`{"capabilities":{
            "definitionProvider":true,
            "hoverProvider":true,
            "completionProvider":{"triggerCharacters":["."]},
            "signatureHelpProvider":{"triggerCharacters":["(",","]},
            "textDocumentSync":1
            }}`);
    }
    else if (result.method == "textDocument/definition")
    {
        Dsymbol target;
        if (auto obj = findCursorObject(lsp, result.params))
            target = definitionTarget(obj);
        if (!target || !writeLocation(buf, target))
            buf.printf("null");
    }
    else if (result.method == "textDocument/hover")
    {
        // fprintf(stderr, "[!] found! %s", v.toChars);
        if (auto obj = findCursorObject(lsp, result.params))
        {
            buf.printf(`{"contents":{"kind":"markdown","value":"`);

            OutBuffer hover;
            if (auto e = isExpression(obj))
            {
                if (auto ve = e.isVarExp())
                {
                    if (auto vd = ve.var)
                    {
                        if (auto comment = vd.comment)
                            hover.printf("%s\n\n", vd.comment);
                    }
                }
                hover.printf("**type**: %s\n", e.type.toChars);
            }
            else if (auto d = isDsymbol(obj))
            {
                if (auto sd = d.isStructDeclaration())
                {
                    // hover.printf(`type: %s`, d.type.toChars);
                    hover.printf("**sizeof**: %d\n", cast(int) sd.size(Loc.initial));
                }
                if (auto cd = d.isClassDeclaration())
                {
                    hover.printf("**classInstanceSize**: %d\n", cast(int) cd.size(Loc.initial));
                }
                if (auto fd = d.isFuncDeclaration())
                {
                    hover.printf("**type**: %s\n", fd.type.toChars);
                }
                if (auto vd = d.isVarDeclaration())
                {

                    hover.printf("**type**: %s\n\n", vd.type.toChars);
                    if (auto ei = vd._init ? vd._init.isExpInitializer() : null)
                    {
                        hover.printf("**init**: %s\n", ei.exp.toChars);
                    }
                }
            }

            // buf.printf(`{"contents":{"kind":"markdown","value":"**int**\n\nEH?."},`
            //     ~`"range": {"start": { "line": 0, "character": 1 },"end": { "line": 0, "character": 3 }}}`, );
            buf.writeJsonString(hover.extractSlice);
            buf.printf(`"}}`);
        }
        else
        {
            buf.printf("null");
        }
    }
    else if (result.method == "textDocument/completion")
    {
        buf.writestring(`{"isIncomplete":false,"items":[`);
        completionItems(lsp, result.params, buf);
        buf.writestring(`]}`);
    }
    else if (result.method == "textDocument/signatureHelp")
    {
        signatureHelp(lsp, result.params, buf);
    }
    else if (result.method == "textDocument/documentSymbol")
    {
        // list functions, types, variables in a file
    }
    else if (result.method == "textDocument/didOpen")
    {
        lsp.openDocuments[result.params.textDocument.uri] = result.params.textDocument.text;
        publishDiagnostics(lsp, result.params.textDocument.uri);
        return; // notification, no response
    }
    else if (result.method == "textDocument/didChange")
    {
        // textDocumentSync: Full (1) — contentChanges[0].text is the complete new content
        lsp.openDocuments[result.params.textDocument.uri] = result.params.contentChanges.text;
        publishDiagnostics(lsp, result.params.textDocument.uri);
        return; // notification, no response
    }
    else if (result.method == "textDocument/didClose")
    {
        lsp.openDocuments.remove(result.params.textDocument.uri);
        return; // notification, no response
    }
    else if (result.method == "textDocument/didSave")
    {
        return; // content already up to date from didChange; no response needed
    }
    else if (result.method == "initialized")
    {
        return; // Not required to respond
    }
    else
    {
        fprintf(stderr, "[!] unknown method %.*s\n", result.method.fTuple.expand);
        buf.printf("null");
    }

    buf.printf(`}`);
    // fprintf(stderr, "[!] send response of length %d: %s\n", cast(int) buf.length, buf.peekChars());
    printf("Content-Length: %d\r\n\r\n", cast(int) buf.length);
    printf("%s", buf.extractChars());
    fflush(stdout);
}

void writeJsonString(ref OutBuffer buf, const(char)[] str)
{
    foreach (c; str)
        writeCharLiteral(c, &buf.put);
        //buf.writeCharLiteral(c);
}

/// Returns: whether you can access Token.intvalue from a token of `tok` kind
bool hasIntValue(TOK tok)
{
    switch (tok)
    {
        case TOK.int32Literal, TOK.int64Literal, TOK.string_, TOK.true_, TOK.false_:
            return true;
        default:
            return false;
    }
}

/// Parses json `text` and store the values inthe matching fields of `result`.
JsonRpc jsonParse(ref JsonRpc result, const(char)[] text, ErrorSink eSink)
{
    auto lexer = new Lexer("json", (text ~ "\0\0\0\0").ptr, 0, text.length, false, false, eSink, &global.compileEnv);
    lexer.popFront(); // Pop the 'reserved' token
    const(char)[][] keys = [];

    // Example: setPrimary(obj, ["pos", "x"], Token(3))
    // Means we want to set: obj.pos.x = 3
    // Returns: whether we found and set the field
    bool setPrimary(T)(ref T destination, const(char)[][] keys, const ref Token token)
    {
        static if (is(T == struct))
        {
            if (keys.length == 0)
                return false; // type mismatch: expected object, got int or string

            foreach (member; __traits(allMembers, T))
            {
                if (keys[0] == member)
                    return setPrimary(__traits(getMember, destination, member), keys[1 .. $], token);
            }
            return false; // field not found
        }
        else
        {
            if (keys.length != 0)
                return false; // type mismatch: expected simple value, got object

            static if (is(T == string))
            {
                if (token.value != TOK.string_)
                    return false; // type mismatch: expected string, got int or something
                destination = token.ustring.toDString.idup;
            }
            else static if (is(T : long))
            {
                if (!hasIntValue(token.value))
                    return false; // type mismatch: expected int, got string or something
                destination = cast(T) token.intvalue;
            }
            else
                static assert(0, "unsupported field type `" ~ T.stringof ~ "`");

            return true;
        }
    }

    // Parse primary expression, number or string
    void primary()
    {
        if (!hasIntValue(lexer.front) && !lexer.front == TOK.string_)
            eSink.error(lexer.scanloc, "Json value can't start with %s", Token.toChars(lexer.front));
        else
            setPrimary(result, keys, lexer.token);

        lexer.popFront();
    }

    /// Require a specific token, error if not present
    auto expect(TOK value)
    {
        if (lexer.front != value)
            eSink.error(lexer.scanloc, "Expected `%s`, got `%s` while parsing `%.*s`",
                Token.toChars(value), Token.toChars(lexer.front), cast(int) text.length, text.ptr);

        auto res = lexer.token;
        lexer.popFront();
        return res;
    }

    /// Optionally lex a single token. If lexer points at `value`, pop it and return true.
    bool accepted(TOK value)
    {
        if (lexer.front == value)
        {
            lexer.popFront();
            return true;
        }
        return false;
    }

    // Parse JSON array, e.g. [{}, "x", 5]
    void array()()
    {
        expect(TOK.leftBracket);
        if (accepted(TOK.rightBracket))
            return;


        for (size_t i = 0; !lexer.empty; i++)
        {
            anyValue();
            if (!accepted(TOK.comma))
                break;
        }
        expect(TOK.rightBracket);
    }

    // Parse JSON key-value pair, e.g. "key": 3
    void keyValue()()
    {
        auto key = expect(TOK.string_);
        keys ~= key.ustring.toDString; // push field on the stack
        expect(TOK.colon);
        anyValue();
        keys = keys[0 .. $ - 1]; // pop field from stack
    }

    void obj()()
    {
        expect(TOK.leftCurly);
        if (accepted(TOK.rightCurly))
            return;

        while (!lexer.empty)
        {
            keyValue();
            if (!accepted(TOK.comma))
                break;
        }
        expect(TOK.rightCurly);
    }

    void anyValue()()
    {
        if (lexer.front == TOK.leftCurly)
            obj();
        else if (lexer.front == TOK.leftBracket)
            array();
        else
            primary();
    }

    obj();
    return result;
}

// struct and field names match JsonRPC / LSP protocol
struct JsonRpc
{
    int id;
    string method;
    Params params;
}

struct Params
{
    Uri textDocument;
    Position position;
    string rootPath; // main folder that is open in editor
    ContentChange contentChanges; // maps contentChanges[0].text for textDocument/didChange

    // struct Capabilities
    // {
    //     struct TextDocument {}
    //     TextDocument textDocument;
    // }
    // Capabilities capabilities;
}

struct Uri
{
    string uri;
    string text; // populated in textDocument/didOpen
}

struct ContentChange
{
    Range range; // changed range (for textDocumentSync Incremental mode)
    string text; // full new content (textDocumentSync Full mode)
}

struct Position
{
    int line;
    int character;
}

struct Range
{
    Position start;
    Position end;
}

SourceLoc toSourceLoc(string uri, Position position)
{
    SourceLoc result;
    if (uri.startsWith("file://"))
        result.filename = uri["file://".length .. $];

    result.line = position.line + 1; // 0-based
    result.column = position.character + 1; // 0-based
    return result;
}

unittest
{
    scope eSink = new ErrorSinkStderr();
    JsonRpc result;
    jsonParse(result, `
    {
        "jsonrpc": "2.0",
        "id": 1,
        "array": [],
        "method": "textDocument/definition",
        "params": {
            "textDocument": { "uri": "file:///path/to/file" },
            "position": { "line": 10, "character": 5 }
        }
    }`, eSink);

    assert(result.id == 1);
    assert(result.method == "textDocument/definition");
    assert(result.params.textDocument.uri == "file:///path/to/file");
    assert(result.params.position.line == 10);
    assert(result.params.position.character == 5);

    string initialize = `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":20036,"clientInfo":{"name":"Sublime Text LSP","version":"2.3.0"},"rootUri":"file:///home/dennis/repos/dmd","rootPath":"/home/dennis/repos/dmd","workspaceFolders":[{"name":"dmd","uri":"file:///home/dennis/repos/dmd"}],"capabilities":{"general":{"regularExpressions":{"engine":"ECMAScript"},"markdown":{"parser":"Python-Markdown","version":"3.2.2"}},"textDocument":{"synchronization":{"dynamicRegistration":true,"didSave":true,"willSave":true,"willSaveWaitUntil":true},"hover":{"dynamicRegistration":true,"contentFormat":["markdown","plaintext"]},"completion":{"dynamicRegistration":true,"completionItem":{"snippetSupport":true,"deprecatedSupport":true,"documentationFormat":["markdown","plaintext"],"tagSupport":{"valueSet":[1]},"resolveSupport":{"properties":["detail","documentation","additionalTextEdits"]},"insertReplaceSupport":true,"insertTextModeSupport":{"valueSet":[2]},"labelDetailsSupport":true},"completionItemKind":{"valueSet":[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25]},"insertTextMode":2,"completionList":{"itemDefaults":["editRange","insertTextFormat","data"]}},"signatureHelp":{"dynamicRegistration":true,"contextSupport":true,"signatureInformation":{"activeParameterSupport":true,"documentationFormat":["markdown","plaintext"],"parameterInformation":{"labelOffsetSupport":true}}},"references":{"dynamicRegistration":true},"documentHighlight":{"dynamicRegistration":true},"documentSymbol":{"dynamicRegistration":true,"hierarchicalDocumentSymbolSupport":true,"symbolKind":{"valueSet":[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26]},"tagSupport":{"valueSet":[1]}},"documentLink":{"dynamicRegistration":true,"tooltipSupport":true},"formatting":{"dynamicRegistration":true},"rangeFormatting":{"dynamicRegistration":true,"rangesSupport":true},"declaration":{"dynamicRegistration":true,"linkSupport":true},"definition":{"dynamicRegistration":true,"linkSupport":true},"typeDefinition":{"dynamicRegistration":true,"linkSupport":true},"implementation":{"dynamicRegistration":true,"linkSupport":true},"codeAction":{"dynamicRegistration":true,"codeActionLiteralSupport":{"codeActionKind":{"valueSet":["quickfix","refactor","refactor.extract","refactor.inline","refactor.rewrite","source.fixAll","source.organizeImports"]}},"dataSupport":true,"isPreferredSupport":true,"resolveSupport":{"properties":["edit"]}},"rename":{"dynamicRegistration":true,"prepareSupport":true,"prepareSupportDefaultBehavior":1},"colorProvider":{"dynamicRegistration":true},"publishDiagnostics":{"relatedInformation":true,"tagSupport":{"valueSet":[1,2]},"versionSupport":true,"codeDescriptionSupport":true,"dataSupport":true},"diagnostic":{"dynamicRegistration":true,"relatedDocumentSupport":true},"selectionRange":{"dynamicRegistration":true},"foldingRange":{"dynamicRegistration":true,"foldingRangeKind":{"valueSet":["comment","imports","region"]}},"codeLens":{"dynamicRegistration":true},"inlayHint":{"dynamicRegistration":true,"resolveSupport":{"properties":["textEdits","label.command"]}},"semanticTokens":{"dynamicRegistration":true,"requests":{"range":true,"full":{"delta":true}},"tokenTypes":["namespace","type","class","enum","interface","struct","typeParameter","parameter","variable","property","enumMember","event","function","method","macro","keyword","modifier","comment","string","number","regexp","operator","decorator","label"],"tokenModifiers":["declaration","definition","readonly","static","deprecated","abstract","async","modification","documentation","defaultLibrary"],"formats":["relative"],"overlappingTokenSupport":false,"multilineTokenSupport":true,"augmentsSyntaxTokens":true},"callHierarchy":{"dynamicRegistration":true},"typeHierarchy":{"dynamicRegistration":true}},"workspace":{"applyEdit":true,"didChangeConfiguration":{"dynamicRegistration":true},"executeCommand":{},"workspaceEdit":{"documentChanges":true,"failureHandling":"abort"},"workspaceFolders":true,"symbol":{"dynamicRegistration":true,"resolveSupport":{"properties":["location.range"]},"symbolKind":{"valueSet":[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26]},"tagSupport":{"valueSet":[1]}},"configuration":true,"codeLens":{"refreshSupport":true},"inlayHint":{"refreshSupport":true},"semanticTokens":{"refreshSupport":true},"diagnostics":{"refreshSupport":true}},"window":{"showDocument":{"support":true},"showMessage":{"messageActionItem":{"additionalPropertiesSupport":true}},"workDoneProgress":true}},"initializationOptions":{}}}`;
    jsonParse(result, initialize, eSink);

    // textDocument/didOpen: params.textDocument.text contains the full file content
    JsonRpc didOpen;
    jsonParse(didOpen, `{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///foo.d","languageId":"d","version":1,"text":"module foo;\nint x = 5;\n"}}}`, eSink);
    assert(didOpen.method == "textDocument/didOpen");
    assert(didOpen.params.textDocument.uri == "file:///foo.d");
    assert(didOpen.params.textDocument.text == "module foo;\nint x = 5;\n");

    // textDocument/didChange: contentChanges[0].text is the full new content (Full sync)
    JsonRpc didChange;
    jsonParse(didChange, `{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///foo.d","version":2},"contentChanges":[{"text":"module foo;\nint x = 42;\n"}]}}`, eSink);
    assert(didChange.method == "textDocument/didChange");
    assert(didChange.params.textDocument.uri == "file:///foo.d");
    assert(didChange.params.contentChanges.text == "module foo;\nint x = 42;\n");
}
