/**
Implements dmd as a language server, following the Language Server Protocol (LSP)

Provides hover, go to definition, completion, signature help, references,
document symbols, document highlight, rename, diagnostics and semantic tokens.

See_Also: https://microsoft.github.io/language-server-protocol/
*/
module dmd.lsp;

// dmd -main -unittest -i -J../.. -Jdmd/res -run dmd/lsp.d

import core.stdc.stdio;
import core.vararg;
import dmd.aggregate;
import dmd.arraytypes;
import dmd.astenums;
import dmd.attrib;
import dmd.common.outbuffer;
import dmd.dcast : implicitConvTo;
import dmd.dclass;
import dmd.declaration;
import dmd.denum;
import dmd.dimport;
import dmd.dmodule;
import dmd.dscope;
import dmd.dstruct;
import dmd.dsymbol;
import dmd.dsymbolsem;
import dmd.dtemplate;
import dmd.errors : ErrorSinkCompiler;
import dmd.errorsink;
import dmd.expression;
import dmd.file_manager;
import dmd.func;
import dmd.globals;
import dmd.hdrgen : HdrGenState, toCBuffer, parameterToChars;
import dmd.id;
import dmd.identifier;
import dmd.location;
import dmd.mtype;
import dmd.typesem : Type_init, toBasetype;
import dmd.root.file;
import dmd.root.filename;
import dmd.root.json;
import dmd.root.string;
import dmd.semantic2;
import dmd.semantic3;
import dmd.visitor;


struct Lsp
{
    /// URI -> text of the documents open in the editor
    string[string] openDocuments;

    /// Sink that collects diagnostics produced during analyzeModule
    ErrorSinkLsp eSink;

    /// Whether the client counts columns in UTF-16 code units rather than bytes
    bool utf16 = true;

    bool shutdownRequested;

    /// The last analysis, reused by requests on the same document text
    Analysis cache;

    /// Other documents diagnostics were last published to, to clear them later
    string[] publishedUris;
}

/// A supplemental note attached to a diagnostic, with its own location.
struct RelatedInfo
{
    int line;
    int column;
    const(char)[] filename;
    string message;
}

/// One LSP diagnostic collected from an ErrorSink callback.
/// `line`/`column` are 1-based (as returned by SourceLoc); 0 means "unknown".
struct Diagnostic
{
    int line;
    int column;
    const(char)[] filename;
    int severity; // 1=Error, 2=Warning, 3=Info, 4=Hint
    bool deprecation;
    string message;
    RelatedInfo[] related;
}

private size_t utf8Trim(const(char)[] s, size_t max) nothrow @nogc
{
    if (s.length <= max)
        return s.length;
    size_t n = max;
    while (n > 0 && (s[n] & 0xC0) == 0x80)
        n--;
    return n;
}

/// ErrorSink that captures diagnostics into a list instead of printing them.
/// One instance is owned by Lsp and reused across requests; `clear` is called
/// before each analysis run.
class ErrorSinkLsp : ErrorSinkCompiler
{
    enum maxDiagnostics = 1000;
    enum maxMessageLength = 8 * 1024;

    Diagnostic[] diagnostics;

    // whether the last error was dropped as a duplicate, so its
    // supplemental lines are dropped as well
    private bool lastDuplicate;

    private bool truncated;

    private static string formatMessage(const(char)* format, va_list ap) nothrow
    {
        OutBuffer msg;
        msg.vprintf(format, ap);
        auto text = msg.extractSlice();
        return text[0 .. utf8Trim(text, maxMessageLength)].idup;
    }

    private void add(Loc loc, int severity, bool deprecation, const(char)* format, va_list ap) nothrow
    {
        if (diagnostics.length >= maxDiagnostics)
        {
            if (!truncated)
            {
                truncated = true;
                diagnostics ~= Diagnostic(0, 0, null, 1, false, "too many diagnostics, further messages suppressed");
            }
            lastDuplicate = true;
            return;
        }
        auto sl = SourceLoc(loc);
        auto message = formatMessage(format, ap);
        foreach (ref d; diagnostics)
        {
            if (d.line == sl.line && d.column == sl.column && d.severity == severity
                && d.message == message && d.filename == sl.filename)
            {
                lastDuplicate = true;
                return;
            }
        }
        lastDuplicate = false;
        diagnostics ~= Diagnostic(sl.line, sl.column, sl.filename, severity, deprecation, message);
    }

    private void appendToLast(Loc loc, const(char)* format, va_list ap) nothrow
    {
        if (diagnostics.length == 0 || lastDuplicate)
            return;
        auto d = &diagnostics[$ - 1];
        auto text = formatMessage(format, ap);
        auto sl = SourceLoc(loc);
        if (sl.line > 0 && sl.filename.length)
        {
            d.related ~= RelatedInfo(sl.line, sl.column, sl.filename, text);
            return;
        }
        if (d.message.length >= maxMessageLength)
            return;
        d.message ~= "\n" ~ text;
    }

    void clear() nothrow
    {
        diagnostics = null;
        lastDuplicate = false;
        truncated = false;
    }

    extern(C++) override:

    // Increment global.errors/gaggedErrors like ErrorSinkCompiler does:
    // semantic passes rely on the former to know an error was already reported
    // (e.g. ErrorStatement asserts it), and speculative compilation
    // (trySemantic) relies on the latter to detect that its gagged attempt
    // failed. Gagged diagnostics must not reach the client: they come from
    // rewrite attempts (e.g. `aggr` -> `aggr[]`) that the compiler discards.
    void verror(Loc loc, const(char)* format, va_list ap)
    {
        global.errors++;
        if (global.gag)
            global.gaggedErrors++;
        else
            add(loc, 1, false, format, ap);
    }
    void vwarning(Loc loc, const(char)* format, va_list ap)
    {
        if (!global.gag)
            add(loc, 2, false, format, ap);
    }
    void vdeprecation(Loc loc, const(char)* format, va_list ap)
    {
        if (useDeprecated == DiagnosticReporting.off)
            return;
        if (useDeprecated == DiagnosticReporting.error)
            return verror(loc, format, ap);
        if (global.gag)
        {
            global.gaggedDeprecations++;
            return;
        }
        global.deprecations++;
        add(loc, 2, true, format, ap);
    }
    void verrorSupplemental(Loc loc, const(char)* format, va_list ap)
    {
        if (!global.gag)
            appendToLast(loc, format, ap);
    }
    void vwarningSupplemental(Loc loc, const(char)* format, va_list ap)
    {
        if (!global.gag)
            appendToLast(loc, format, ap);
    }
    void vdeprecationSupplemental(Loc loc, const(char)* format, va_list ap)
    {
        if (useDeprecated != DiagnosticReporting.off && !global.gag)
            appendToLast(loc, format, ap);
    }
    void vmessage(Loc loc, const(char)* format, va_list ap)
    {
        OutBuffer msg;
        msg.vprintf(format, ap);
        fprintf(stderr, "%s\n", msg.peekChars());
    }
}

// ----------------------------------------------------------------------------
// URIs and position encoding
// ----------------------------------------------------------------------------

private int hexDigit(char c)
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

/// The file system path of a `file://` URI, with percent-escapes decoded.
/// Returns: null for other URI schemes.
string uriFilename(string uri)
{
    if (!uri.startsWith("file://"))
        return null;
    auto path = uri["file://".length .. $];
    char[] result;
    result.reserve(path.length);
    for (size_t i = 0; i < path.length; i++)
    {
        if (path[i] == '%' && i + 2 < path.length && hexDigit(path[i + 1]) >= 0 && hexDigit(path[i + 2]) >= 0)
        {
            result ~= cast(char)(hexDigit(path[i + 1]) * 16 + hexDigit(path[i + 2]));
            i += 2;
        }
        else
            result ~= path[i];
    }
    version (Windows)
    {
        if (result.length >= 3 && result[0] == '/' && result[2] == ':')
            result = result[1 .. $];
    }
    return cast(string) result;
}

/// Write `filename` as a `file://` URI. A relative filename (a module found
/// via a relative -I path) is made absolute: file://source/x.d makes `source`
/// the URI authority and the client opens the non-existing /x.d.
void writeFileUri(ref OutBuffer buf, const(char)[] filename)
{
    if (!FileName.absolute(filename))
    {
        OutBuffer nameBuf;
        nameBuf.writestring(filename);
        filename = FileName.toAbsolute(nameBuf.peekChars()).toDString();
    }
    buf.writestring("file://");
    version (Windows)
    {
        if (filename.length >= 2 && filename[1] == ':')
            buf.writeByte('/');
    }
    foreach (char c; filename)
    {
        const unreserved = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
            || c == '-' || c == '.' || c == '_' || c == '~' || c == '/';
        version (Windows)
            const keep = unreserved || c == ':';
        else
            const keep = unreserved;
        if (keep)
            buf.writeByte(c);
        else
            buf.printf("%%%02X", cast(uint) cast(ubyte) c);
    }
}

/// Number of UTF-16 code units needed for the UTF-8 text `s`
size_t utf16Length(const(char)[] s) nothrow @nogc
{
    size_t n = 0;
    foreach (char c; s)
    {
        if ((c & 0xC0) != 0x80)
            n++;
        if (c >= 0xF0)
            n++;
    }
    return n;
}

/// Byte offset in `line` of the character `units` UTF-16 code units in
size_t utf16ToByteOffset(const(char)[] line, size_t units) nothrow @nogc
{
    size_t n = 0;
    foreach (i, char c; line)
    {
        if ((c & 0xC0) != 0x80)
        {
            if (n >= units)
                return i;
            n++;
            if (c >= 0xF0)
                n++;
        }
    }
    return line.length;
}

/// The text of 0-based line `line` in `content`, without its line terminator
const(char)[] lineSlice(const(char)[] content, int line) nothrow @nogc
{
    size_t start = 0;
    for (int l = 0; l < line; l++)
    {
        while (start < content.length && content[start] != '\n')
            start++;
        if (start < content.length)
            start++;
    }
    size_t end = start;
    while (end < content.length && content[end] != '\n' && content[end] != '\r')
        end++;
    return content[start .. end];
}

/// The text of the document `filename`: the editor's copy when it is open,
/// otherwise the copy the compiler read (or reads now) from disk.
const(char)[] fileContent(ref Lsp lsp, const(char)[] filename)
{
    foreach (uri, content; lsp.openDocuments)
    {
        if (sameFile(uriFilename(uri), filename))
            return content;
    }
    if (auto bytes = global.fileManager.getFileContents(FileName(filename)))
        return cast(const(char)[]) bytes;
    return null;
}

/// Whether two file names refer to the same file (one may be relative)
bool sameFile(const(char)[] a, const(char)[] b)
{
    if (a == b)
        return true;
    if (a.length == 0 || b.length == 0)
        return false;
    if (FileName.absolute(a) == FileName.absolute(b))
        return false;
    OutBuffer nameBuf;
    nameBuf.writestring(FileName.absolute(a) ? b : a);
    return FileName.toAbsolute(nameBuf.peekChars()).toDString() == (FileName.absolute(a) ? a : b);
}

/// Convert a 1-based byte column on 1-based line `line` of `filename` to the
/// client's 0-based column
int clientColumn(ref Lsp lsp, const(char)[] filename, int line, int byteColumn)
{
    const col = byteColumn > 0 ? byteColumn - 1 : 0;
    if (!lsp.utf16)
        return col;
    auto text = lineSlice(fileContent(lsp, filename), line - 1);
    return cast(int) utf16Length(text[0 .. col < text.length ? col : text.length]);
}

/// Convert the client's 0-based column on 0-based `line` of `content` to a
/// 0-based byte column
int byteColumn(ref Lsp lsp, const(char)[] content, int line, int character)
{
    if (!lsp.utf16)
        return character;
    return cast(int) utf16ToByteOffset(lineSlice(content, line), character);
}

/// Convert the (0-based, byte) `pos` in the document at `uri` to a byte
/// column the compiler-side code expects
Position toBytePosition(ref Lsp lsp, string uri, Position pos)
{
    if (auto content = uri in lsp.openDocuments)
        pos.character = byteColumn(lsp, *content, pos.line, pos.character);
    return pos;
}

/// Write an LSP Range for `len` bytes at 1-based (line, column) in `filename`
void writeRange(ref OutBuffer buf, ref Lsp lsp, const(char)[] filename, int line, int column, int len)
{
    const start = clientColumn(lsp, filename, line, column);
    const end = clientColumn(lsp, filename, line, column + len);
    buf.printf(`{"start":{"line":%d,"character":%d},"end":{"line":%d,"character":%d}}`,
        line - 1, start, line - 1, end);
}

/// Write an LSP Location JSON object for a name of `len` characters at `sl`.
void writeLocationAt(ref OutBuffer buf, ref Lsp lsp, SourceLoc sl, int len)
{
    buf.writestring(`{"uri":"`);
    writeFileUri(buf, sl.filename);
    buf.writestring(`","range":`);
    writeRange(buf, lsp, sl.filename, sl.line, sl.column, len);
    buf.writestring(`}`);
}

/// Write an LSP Location JSON object pointing at s's declaration.
/// Returns: false (and writes nothing) when s has no usable location.
bool writeLocation(ref OutBuffer buf, ref Lsp lsp, Dsymbol s)
{
    SourceLoc sl = SourceLoc(declarationLoc(s));
    if (sl.filename.length == 0 || sl.line == 0)
        return false;
    writeLocationAt(buf, lsp, sl, declarationLength(s));
    return true;
}

/// Length of the identifier at a declaration's location
int declarationLength(Dsymbol s)
{
    if (s.isCtorDeclaration())
        return cast(int) "this".length;
    return s.ident ? cast(int) s.ident.toString().length : 1;
}

// ----------------------------------------------------------------------------
// Identifier occurrences
// ----------------------------------------------------------------------------

/// A declaration or use of a named symbol in the analyzed document
struct Occurrence
{
    SourceLoc loc;
    int len;
    Dsymbol sym;
    bool declaration;
}

/// Collects every occurrence of a resolved symbol, and every call, in a module
extern(C++) final class OccurrenceVisitor : SemanticTimeTransitiveVisitor
{
    alias visit = typeof(super).visit;

    Occurrence[] occurrences;
    CallExp[] calls;

    extern (D) void add(Loc loc, Dsymbol s, bool declaration, size_t len = 0)
    {
        if (!loc.isValid || !s || !s.ident)
            return;
        SourceLoc sl = SourceLoc(loc);
        if (sl.line == 0 || sl.filename != rootFilename)
            return;
        if (len == 0)
            len = s.isCtorDeclaration() ? "this".length : s.ident.toString().length;
        occurrences ~= Occurrence(sl, cast(int) len, s, declaration);
    }

    extern (D) void addDeclaration(Dsymbol s)
    {
        if (s.ident && (s.isCtorDeclaration() || !s.ident.toString().startsWith("__")))
            add(s.loc, s, true);
    }

    extern (D) void addFunction(FuncDeclaration d)
    {
        if (!d.isGenerated)
            addDeclaration(d);
        if (d.parameters)
            foreach (p; *d.parameters)
                addDeclaration(p);
    }

    override void visit(StructDeclaration d) { addDeclaration(d); super.visit(d); }
    override void visit(ClassDeclaration d) { addDeclaration(d); super.visit(d); }
    override void visit(InterfaceDeclaration d) { addDeclaration(d); super.visit(d); }
    override void visit(EnumDeclaration d) { addDeclaration(d); super.visit(d); }
    override void visit(EnumMember em) { addDeclaration(em); super.visit(em); }
    override void visit(AliasDeclaration d) { addDeclaration(d); super.visit(d); }
    override void visit(VarDeclaration d) { addDeclaration(d); super.visit(d); }
    override void visit(FuncDeclaration d) { addFunction(d); super.visit(d); }
    override void visit(CtorDeclaration d) { addFunction(d); super.visit(d); }

    override void visit(TemplateDeclaration d)
    {
        add(declarationLoc(d), d, true);
        super.visit(d);
    }

    override void visit(VarExp e)
    {
        if (!e.var.isSymbolDeclaration())
            add(e.loc, e.var, false);
    }

    override void visit(DotVarExp e)
    {
        Dsymbol s = e.var;
        if (auto ctor = s ? s.isCtorDeclaration() : null)
            s = ctor.isMember();
        add(e.identLoc, s, false);
        super.visit(e);
    }

    override void visit(StructLiteralExp e)
    {
        add(e.loc, e.sd, false);
        super.visit(e);
    }

    override void visit(NewExp e)
    {
        if (auto s = typeSymbolOf(e.type))
            add(e.typeLoc, e.member ? e.member : s, false, s.ident.toString().length);
        super.visit(e);
    }

    override void visit(ScopeExp e)
    {
        add(e.loc, e.sds, false);
        super.visit(e);
    }

    override void visit(TypeExp e)
    {
        add(e.loc, typeSymbolOf(e.type), false);
        super.visit(e);
    }

    override void visit(CallExp e)
    {
        calls ~= e;
        super.visit(e);
    }
}

/// The declaration of a struct, class, interface or enum type, through one level of pointer
Dsymbol typeSymbolOf(Type t)
{
    static Dsymbol direct(Type t)
    {
        if (auto te = t.isTypeEnum())
            return te.sym;
        t = t.toBasetype();
        if (auto ts = t.isTypeStruct())
            return ts.sym;
        if (auto tc = t.isTypeClass())
            return tc.sym;
        return null;
    }
    if (!t)
        return null;
    if (auto s = direct(t))
        return s;
    auto tp = t.toBasetype().isTypePointer();
    return tp ? direct(tp.next) : null;
}

/// Where the name of `s` is declared; a template's at its eponymous member
Loc declarationLoc(Dsymbol s)
{
    if (auto td = s.isTemplateDeclaration())
        if (td.onemember)
            return td.onemember.loc;
    return s.loc;
}

/// Every occurrence and call in `m`, plus the uses only known through frontend hooks
OccurrenceVisitor collectOccurrences(Module m)
{
    auto visitor = new OccurrenceVisitor();
    visitor.visit(m);
    visitor.occurrences ~= hookRefs;
    return visitor;
}

/// The symbol whose name is at `cursor`, or null
Dsymbol symbolAt(Occurrence[] occurrences, SourceLoc cursor)
{
    foreach (o; occurrences)
        if (o.loc.line == cursor.line && cursor.column >= o.loc.column && cursor.column <= o.loc.column + o.len)
            return o.sym;
    return null;
}

/// The symbol at the cursor of a request
Dsymbol symbolAt(ref Lsp lsp, Params params)
{
    Module m = analyzeModule(lsp, params.textDocument.uri);
    if (!m)
        return null;
    return symbolAt(collectOccurrences(m).occurrences, toSourceLoc(params.textDocument.uri, params.position));
}

// ----------------------------------------------------------------------------
// Analysis
// ----------------------------------------------------------------------------

version (Posix)
{
    import core.sys.posix.setjmp : jmp_buf, setjmp;

    /// Recovery point for a compiler fatal() raised while analyzing a document.
    /// analyzeModule arms this and the fatalErrorHandler installed in lspMain
    /// longjmp()s back to it, so an unrecoverable analysis (e.g. a failed
    /// `static assert`) abandons that one request instead of exiting the server.
    private __gshared jmp_buf lspFatalEnv;
    private __gshared bool lspFatalArmed;
    private __gshared ErrorSinkCompiler lspFatalSavedSink;
    private __gshared uint lspFatalSavedErrors;
    private __gshared Module lspFatalModule;
}

/// A file the last analysis read from disk, with the bytes it saw
struct DepFile
{
    const(char)[] name;
    const(ubyte)[] contents;
}

/// The last analysis, reused by requests on the same document text
struct Analysis
{
    bool valid;
    string uri;
    string text;
    Module mod;
    DepFile[] deps;
}

/// An `e1.ident` member access recorded by `onMemberLookup`; an incomplete `e1.` has the empty identifier
struct MemberAccess
{
    Expression e1;
    Identifier ident;
    SourceLoc loc;
    SourceLoc identLoc;
}

/// A scope recorded by `onScopeEntered`: the scope symbols visible in it, innermost first
struct ScopeRecord
{
    SourceLoc loc;
    SourceLoc endloc;
    ScopeDsymbol[] chain;
}

private __gshared Occurrence[] hookRefs;
private __gshared MemberAccess[] memberAccesses;
private __gshared ScopeRecord[] scopeRecords;
private __gshared const(char)[] rootFilename;

private void recordConstantFold(Dsymbol d, Loc loc)
{
    SourceLoc sl = SourceLoc(loc);
    if (sl.line == 0 || sl.filename != rootFilename || !d.ident)
        return;
    hookRefs ~= Occurrence(sl, cast(int) d.ident.toString().length, d, false);
}

private void recordTypeResolved(Type t, Dsymbol s, Identifier ident, Loc loc)
{
    Dsymbol ts = typeSymbolOf(t);
    if (ts && ts.ident !is ident)
        ts = null;
    if (!ts && s && s.ident is ident)
        ts = s;
    if (ts)
        recordConstantFold(ts, loc);
}

private void recordMemberLookup(Expression e1, Identifier ident, Loc loc, Loc identLoc)
{
    SourceLoc sl = SourceLoc(loc);
    if (sl.line == 0 || sl.filename != rootFilename)
        return;
    memberAccesses ~= MemberAccess(e1, ident, sl, SourceLoc(identLoc));
}

private void recordScopeEntered(Loc loc, Loc endloc, Scope* sc)
{
    SourceLoc sl = SourceLoc(loc);
    if (sl.line == 0 || sl.filename != rootFilename)
        return;
    ScopeDsymbol[] chain;
    for (Scope* s = sc; s; s = s.enclosing)
    {
        if (s.scopesym && (chain.length == 0 || chain[$ - 1] !is s.scopesym))
            chain ~= s.scopesym;
    }
    scopeRecords ~= ScopeRecord(sl, SourceLoc(endloc), chain);
}

/// Analyze the document at `uri`, or return the previous result when its text
/// and every file it depends on are unchanged. Diagnostics end up in `lsp.eSink`.
/// A compiler fatal() abandons that one analysis instead of exiting the server.
/// Returns: the Module, partially analyzed after a fatal(), or null on read/parse failure.
Module analyzeModule(ref Lsp lsp, string uri)
{
    string text;
    if (auto p = uri in lsp.openDocuments)
        text = *p;
    if (lsp.cache.valid && lsp.cache.uri == uri && lsp.cache.text == text && depsUnchanged(lsp.cache.deps))
        return lsp.cache.mod;

    deinitializeModule(lsp);
    Module m;
    version (Posix)
    {
        // Save the pre-analysis globals where the recovery path can reach them:
        // longjmp() unwinds past analyzeModuleImpl's scope(exit), so it cannot
        // restore them itself.
        lspFatalSavedSink = global.errorSink;
        lspFatalSavedErrors = global.errors;
        lspFatalModule = null;
        if (setjmp(lspFatalEnv) != 0)
        {
            // A fatal() fired during analysis and jumped us back here.
            lspFatalArmed = false;
            global.errorSink = lspFatalSavedSink;
            global.errors = lspFatalSavedErrors;
            m = lspFatalModule;
            lspFatalModule = null;
        }
        else
        {
            lspFatalArmed = true;
            m = analyzeModuleImpl(lsp, uri);
            lspFatalArmed = false;
            lspFatalModule = null;
        }
    }
    else
        m = analyzeModuleImpl(lsp, uri);

    if (m)
        lsp.cache = Analysis(true, uri, text, m, collectDeps(lsp));
    return m;
}

/// Every file the compiler read from disk during the last analysis
private DepFile[] collectDeps(ref Lsp lsp)
{
    DepFile[] all;
    foreach (name, contents; global.fileManager)
        all ~= DepFile(name, contents);
    DepFile[] deps;
    foreach (dep; all)
    {
        bool open = false;
        foreach (uri, _; lsp.openDocuments)
            if (sameFile(uriFilename(uri), dep.name))
                open = true;
        if (!open)
            deps ~= dep;
    }
    return deps;
}

/// Whether every file in `deps` still has the bytes the analysis saw
private bool depsUnchanged(DepFile[] deps)
{
    foreach (dep; deps)
    {
        OutBuffer buf;
        if (File.read(dep.name, buf))
            return false;
        if (buf.peekSlice() != dep.contents)
            return false;
    }
    return true;
}

private Module analyzeModuleImpl(ref Lsp lsp, string uri)
{
    Type_init();
    Module._init();
    Loc._init();
    hookRefs = null;
    memberAccesses = null;
    scopeRecords = null;
    lsp.eSink.clear();
    onConstantFold = &recordConstantFold;
    onTypeResolved = &recordTypeResolved;
    onMemberLookup = &recordMemberLookup;
    onScopeEntered = &recordScopeEntered;

    foreach (docUri, content; lsp.openDocuments)
    {
        const filename = uriFilename(docUri);
        if (filename.length == 0)
            continue;
        const bytes = cast(const(ubyte)[]) (content ~ "\0\0\0\0");
        global.fileManager.add(FileName(filename), bytes[0 .. $ - 4]);
    }

    SourceLoc sl = toSourceLoc(uri, Position(0, 0));
    rootFilename = sl.filename;
    const(char)[] p = FileName.name(sl.filename); // strip path
    auto ext = FileName.ext(sl.filename);
    p = p[0 .. $ - ext.length - 1];
    Loc loc = Loc.singleFilename(sl.filename.ptr);
    auto id = Identifier.idPool(p);
    Module m = new Module(loc, sl.filename, id, /*ddoc*/ true, false);

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
    m.importedFrom = m;
    m = m.parse();
    if (!m)
        return null;
    version (Posix)
        lspFatalModule = m;
    m.importedFrom = m;
    m.importAll(null);

    // Mirror the compile driver (main.d): each semantic pass is followed by its
    // runDeferredSemantic* drain, so symbols whose analysis was postponed
    // (forward references, circular imports) are resolved before the next pass
    // instead of being left half-analyzed.
    m.dsymbolSemantic(null);
    runDeferredSemantic();
    m.semantic2(null);
    runDeferredSemantic2();
    m.semantic3(null);
    runDeferredSemantic3();
    return m;
}

/// Drop the last analysis and reset compiler globals so the next
/// analyzeModule call starts fresh.
void deinitializeModule(ref Lsp lsp)
{
    lsp.cache = Analysis.init;
    hookRefs = null;
    memberAccesses = null;
    scopeRecords = null;
    Type_init();
    Module.deinitialize();
    FuncDeclaration.lastMain = null;
    global.fileManager = new FileManager();

    // The previous analysis is now unreachable garbage. dmd runs with the
    // collecting GC under -lsp (see main.d), but its default schedule lets that
    // garbage pile up between collections, so a long editing session ratchets
    // RSS upward. Collect eagerly and hand the freed pages back to the OS to
    // keep the server's footprint flat across thousands of edits.
    import core.memory : GC;
    GC.collect();
    GC.minimize();
}

// ----------------------------------------------------------------------------
// Hover
// ----------------------------------------------------------------------------

/// The template `s` is the eponymous member or an instance member of, if any
private TemplateDeclaration templateOf(Dsymbol s)
{
    if (!s.parent)
        return null;
    if (auto ti = s.parent.isTemplateInstance())
        return ti.tempdecl ? ti.tempdecl.isTemplateDeclaration() : null;
    if (auto td = s.parent.isTemplateDeclaration())
        return td.onemember is s ? td : null;
    return null;
}

/// Markdown with the declaration of `s` in a D code block, followed by its ddoc comment
private string hoverText(Dsymbol s)
{
    if (auto td = templateOf(s))
        s = td;
    OutBuffer hover;
    hover.writestring("```d\n");
    if (auto td = s.isTemplateDeclaration())
        hover.writestring(td.toChars());
    else if (s.isDeclaration())
    {
        HdrGenState hgs;
        hgs.hdrgen = true;
        hgs.insideAggregate = 1;
        toCBuffer(s, hover, hgs);
        while (hover.length && (hover[hover.length - 1] == '\n' || hover[hover.length - 1] == ';'))
            hover.setsize(hover.length - 1);
    }
    else
        hover.printf("%s %s", s.kind(), s.toChars());
    hover.writestring("\n```");
    if (s.comment)
    {
        hover.writestring("\n\n");
        hover.writestring(s.comment.toDString());
    }
    return hover.extractSlice().idup;
}

// ----------------------------------------------------------------------------
// Completion
// ----------------------------------------------------------------------------

/// LSP CompletionItemKind of `s`
private int completionKind(Dsymbol s)
{
    if (auto td = s.isTemplateDeclaration())
        return td.onemember ? completionKind(td.onemember) : 3;
    if (auto fd = s.isFuncDeclaration())
        return fd.isThis() ? 2 : 3;
    if (s.isInterfaceDeclaration())
        return 8;
    if (s.isClassDeclaration())
        return 7;
    if (s.isStructDeclaration())
        return 22;
    if (s.isEnumDeclaration())
        return 13;
    if (s.isEnumMember())
        return 20;
    if (auto vd = s.isVarDeclaration())
    {
        if (vd.storage_class & STC.manifest)
            return 21;
        return vd.isField() ? 5 : 6;
    }
    if (s.isModule() || s.isPackage() || s.isImport() || s.isTemplateMixin())
        return 9;
    if (auto ad = s.isAliasDeclaration())
        return ad.aliassym && ad.aliassym !is s ? completionKind(ad.aliassym) : 7;
    return 1;
}

/// A completion candidate and how many scopes out it was found
struct Candidate
{
    Dsymbol s;
    int depth;
}

/// Keeps the first symbol seen for each name, so inner scopes shadow outer ones
struct CandidateSet
{
    Candidate[] items;
    bool[Identifier] seen;
    SourceLoc cursor;

    void add(Dsymbol s, int depth)
    {
        if (!s || !s.ident || s.ident == Id.This || s.ident.toString().startsWith("__"))
            return;
        if (auto fd = s.isFuncDeclaration())
            if (fd.isGenerated)
                return;
        if (auto vd = s.isVarDeclaration())
        {
            if (vd.parent && vd.parent.isFuncDeclaration() && cursor.line)
            {
                SourceLoc sl = SourceLoc(vd.loc);
                if (sl.filename == cursor.filename && (sl.line > cursor.line || (sl.line == cursor.line && sl.column > cursor.column)))
                    return;
            }
        }
        if (s.ident in seen)
            return;
        seen[s.ident] = true;
        items ~= Candidate(s, depth);
    }
}

/// Whether a member of another module can be named from outside it; `_`-prefixed names are library internals
private bool visibleFromOutside(Dsymbol s)
{
    if (s.ident && s.ident.toString().startsWith("_"))
        return false;
    const kind = s.visible().kind;
    return kind != Visibility.Kind.private_ && kind != Visibility.Kind.undefined;
}

/// Add the symbols declared directly in `sds` and, for aggregates, in its bases
private void addScopeMembers(ScopeDsymbol sds, ref CandidateSet set, int depth, bool fromOutside)
{
    if (sds.symtab)
    {
        foreach (kv; sds.symtab.tab.asRange)
            if (!fromOutside || visibleFromOutside(kv.value))
                set.add(kv.value, depth);
    }
    if (auto cd = sds.isClassDeclaration())
    {
        if (cd.baseClass)
            addScopeMembers(cd.baseClass, set, depth + 1, fromOutside);
        foreach (b; cd.interfaces)
            if (b.sym)
                addScopeMembers(b.sym, set, depth + 1, fromOutside);
    }
    if (auto ws = sds.isWithScopeSymbol())
        if (ws.withstate && ws.withstate.exp)
            addTypeMembers(ws.withstate.exp.type, set, depth);
}

/// Add the members of aggregate or enum type `t`
private void addTypeMembers(Type t, ref CandidateSet set, int depth)
{
    if (!t)
        return;
    if (auto te = t.isTypeEnum())
    {
        if (te.sym.members)
            foreach (s; *te.sym.members)
                if (s.isEnumMember())
                    set.add(s, depth);
        return;
    }
    if (auto agg = typeSymbolOf(t) ? typeSymbolOf(t).isAggregateDeclaration() : null)
        addScopeMembers(agg, set, depth, false);
}

/// Add the members of the modules `sds` imports, and transitively of their public imports
private void addImportedScopes(ScopeDsymbol sds, ref CandidateSet set, int depth, ref bool[Dsymbol] visited, bool publicOnly)
{
    if (!sds.importedScopes)
        return;
    foreach (i, ss; *sds.importedScopes)
    {
        if (publicOnly && sds.visibilities[i] < Visibility.Kind.public_)
            continue;
        auto imported = ss.isScopeDsymbol();
        if (!imported || imported in visited)
            continue;
        visited[imported] = true;
        addScopeMembers(imported, set, depth, true);
        addImportedScopes(imported, set, depth + 1, visited, true);
    }
}

/// The recorded scope chain in effect at `cursor`, innermost first, or null
private ScopeDsymbol[] scopeChainAt(SourceLoc cursor)
{
    static bool before(SourceLoc a, SourceLoc b)
    {
        return a.line < b.line || (a.line == b.line && a.column <= b.column);
    }
    ScopeRecord* best;
    foreach (ref r; scopeRecords)
    {
        if (!before(r.loc, cursor) || !before(cursor, r.endloc))
            continue;
        if (!best || before(best.loc, r.loc))
            best = &r;
    }
    return best ? best.chain : null;
}

/// Add everything visible at the cursor: the scope chain's symbols, then their imports
private void addScopeCandidates(Module m, SourceLoc cursor, ref CandidateSet set)
{
    ScopeDsymbol[] chain = scopeChainAt(cursor);
    if (chain.length == 0)
        chain = [m];
    foreach (i, sds; chain)
        addScopeMembers(sds, set, cast(int) i, false);
    bool[Dsymbol] visited;
    foreach (i, sds; chain)
        addImportedScopes(sds, set, cast(int) (chain.length + i), visited, false);
}

/// The member access whose identifier, or for an incomplete `e.` the spot after the dot, is at the cursor
private MemberAccess* memberAccessAt(SourceLoc cursor)
{
    foreach (ref ma; memberAccesses)
    {
        if (ma.ident == Id.empty)
        {
            if (ma.loc.line == cursor.line && cursor.column > ma.loc.column)
                return &ma;
            continue;
        }
        if (ma.identLoc.line != cursor.line)
            continue;
        const endCol = ma.identLoc.column + ma.ident.toString().length;
        if (cursor.column >= ma.identLoc.column && cursor.column <= endCol)
            return &ma;
    }
    return null;
}

/// Add module-level functions visible at the cursor whose first parameter accepts `baseType`
private void addUfcsCandidates(Module m, SourceLoc cursor, Type baseType, ref CandidateSet set)
{
    if (!baseType || baseType.ty == Terror)
        return;
    CandidateSet all;
    all.cursor = cursor;
    addScopeCandidates(m, cursor, all);
    foreach (c; all.items)
    {
        auto fd = c.s.isFuncDeclaration();
        if (!fd || fd.isThis() || !fd.parent || !fd.parent.isModule())
            continue;
        for (FuncDeclaration f = fd; f; f = f.overnext ? f.overnext.isFuncDeclaration() : null)
        {
            auto tf = f.type ? f.type.isTypeFunction() : null;
            if (!tf || tf.parameterList.length == 0)
                continue;
            auto pt = tf.parameterList[0].type;
            if (pt && implicitConvTo(baseType, pt) != MATCH.nomatch)
            {
                set.add(fd, c.depth);
                break;
            }
        }
    }
}

/// Add the members reachable through `ma.e1.`
private void addMemberCandidates(Module m, SourceLoc cursor, ref MemberAccess ma, ref CandidateSet set)
{
    Expression e1 = ma.e1;
    if (auto se = e1.isScopeExp())
    {
        const outside = se.sds.isModule() || se.sds.isPackage();
        addScopeMembers(se.sds, set, 0, outside);
        bool[Dsymbol] visited;
        if (outside)
            addImportedScopes(se.sds, set, 1, visited, true);
        return;
    }
    if (auto te = e1.isTypeExp())
        return addTypeMembers(te.type, set, 0);
    if (!e1.type)
        return;
    addTypeMembers(e1.type, set, 0);
    addUfcsCandidates(m, cursor, e1.type, set);
}

/// Write `items` as comma-separated CompletionItem objects
void writeCompletionItems(ref OutBuffer buf, Candidate[] items)
{
    foreach (i, c; items)
    {
        Dsymbol s = c.s;
        if (i)
            buf.writestring(",");
        buf.writestring(`{"label":"`);
        buf.writeJsonString(s.ident.toString());
        buf.printf(`","kind":%d,"sortText":"%02d`, completionKind(s), c.depth < 99 ? c.depth : 99);
        buf.writeJsonString(s.ident.toString());
        buf.writestring(`"`);
        const(char)* detail;
        if (auto td = s.isTemplateDeclaration())
            detail = td.toChars();
        else if (auto d = s.isDeclaration())
            detail = d.type ? d.type.toChars() : null;
        else if (s.isAggregateDeclaration() || s.isEnumDeclaration() || s.isModule() || s.isPackage())
            detail = s.kind();
        if (detail)
        {
            buf.writestring(`,"detail":"`);
            buf.writeJsonString(detail.toDString());
            buf.writestring(`"`);
        }
        if (s.isDeprecated())
            buf.writestring(`,"tags":[1]`);
        if (s.comment)
        {
            buf.writestring(`,"documentation":{"kind":"markdown","value":"`);
            buf.writeJsonString(s.comment.toDString());
            buf.writestring(`"}`);
        }
        buf.writestring(`}`);
    }
}

/// The completion items at the cursor: the members of the expression before a `.`
/// plus UFCS-callable functions, or everything in scope otherwise
void completionItems(ref Lsp lsp, Params params, ref OutBuffer buf)
{
    Module m = analyzeModule(lsp, params.textDocument.uri);
    if (!m)
        return;
    SourceLoc cursor = toSourceLoc(params.textDocument.uri, params.position);
    CandidateSet set;
    set.cursor = cursor;
    if (auto ma = memberAccessAt(cursor))
        addMemberCandidates(m, cursor, *ma, set);
    else
        addScopeCandidates(m, cursor, set);
    writeCompletionItems(buf, set.items);
}

// ----------------------------------------------------------------------------
// Signature help
// ----------------------------------------------------------------------------

/// Write one SignatureInformation for `tf` called as `name`
void writeSignature(ref OutBuffer buf, const(char)[] name, TypeFunction tf)
{
    const(char)[][] labels;
    foreach (i; 0 .. tf.parameterList.length)
        labels ~= parameterToChars(tf.parameterList[i], tf, false).toDString;

    buf.writestring(`{"label":"`);
    OutBuffer label;
    label.printf("%.*s(", cast(int)name.length, name.ptr);
    foreach (i, l; labels)
    {
        if (i)
            label.writestring(", ");
        label.writestring(l);
    }
    label.writestring(")");
    buf.writeJsonString(label.extractSlice);
    buf.writestring(`","parameters":[`);
    foreach (i, l; labels)
    {
        if (i)
            buf.writestring(",");
        buf.writestring(`{"label":"`);
        buf.writeJsonString(l);
        buf.writestring(`"}`);
    }
    buf.writestring(`]}`);
}

/// The overload set `fd` belongs to
private FuncDeclaration[] overloadsOf(FuncDeclaration fd)
{
    Dsymbol start = fd;
    if (auto p = fd.parent ? fd.parent.isScopeDsymbol() : null)
        if (p.symtab)
            if (auto s = p.symtab.lookup(fd.ident))
                start = s;
    FuncDeclaration[] overloads;
    for (Dsymbol s = start; s;)
    {
        auto f = s.isFuncDeclaration();
        if (!f)
            break;
        overloads ~= f;
        s = f.overnext;
    }
    return overloads.length ? overloads : [fd];
}

/// Handle textDocument/signatureHelp: the innermost resolved call starting at or
/// before the cursor on its line; the active parameter is the last argument
/// starting at or before the cursor
void signatureHelp(ref Lsp lsp, Params params, ref OutBuffer buf)
{
    SourceLoc cursor = toSourceLoc(params.textDocument.uri, params.position);
    CallExp call;
    if (Module m = analyzeModule(lsp, params.textDocument.uri))
    {
        foreach (ce; collectOccurrences(m).calls)
        {
            SourceLoc sl = SourceLoc(ce.loc);
            if (!ce.f || sl.filename != rootFilename || sl.line != cursor.line || sl.column > cursor.column)
                continue;
            if (!call || SourceLoc(call.loc).column < sl.column)
                call = ce;
        }
    }

    FuncDeclaration[] overloads;
    const(char)[] name;
    int activeParam;
    if (call)
    {
        overloads = overloadsOf(call.f);
        name = call.f.ident.toString();
        if (auto ctor = call.f.isCtorDeclaration())
            if (auto ad = ctor.isMember())
                name = ad.ident.toString();
        if (call.arguments)
        {
            foreach (arg; *call.arguments)
            {
                SourceLoc al = SourceLoc(arg.loc);
                if (al.line < cursor.line || (al.line == cursor.line && al.column <= cursor.column))
                    activeParam++;
            }
        }
        if (activeParam)
            activeParam--;
    }

    int activeSig = 0;
    foreach (i, f; overloads)
    {
        auto tf = f.type ? f.type.isTypeFunction() : null;
        if (tf && tf.parameterList.length > activeParam)
        {
            activeSig = cast(int) i;
            break;
        }
    }

    buf.writestring(`{"signatures":[`);
    bool first = true;
    foreach (f; overloads)
    {
        auto tf = f.type ? f.type.isTypeFunction() : null;
        if (!tf)
            continue;
        if (!first)
            buf.writestring(",");
        first = false;
        writeSignature(buf, name, tf);
    }
    buf.printf(`],"activeSignature":%d,"activeParameter":%d}`, activeSig, activeParam);
}

// ----------------------------------------------------------------------------
// Semantic tokens
// ----------------------------------------------------------------------------

/// Indices into the `tokenTypes` legend of the initialize response
enum SemanticTokenType : int
{
    type,
    namespace,
    class_,
    enum_,
    interface_,
    struct_,
    parameter,
    variable,
    property,
    enumMember,
    function_,
    method,
}

/// Bits of the `tokenModifiers` legend of the initialize response
enum SemanticTokenModifier : int
{
    declaration = 1 << 0,
    static_ = 1 << 1,
    deprecated_ = 1 << 2,
    readonly = 1 << 3,
    defaultLibrary = 1 << 4,
}

/// The token type for an occurrence of `s`, or -1
private int symbolTokenType(Dsymbol s)
{
    if (auto td = s.isTemplateDeclaration())
        return td.onemember ? symbolTokenType(td.onemember) : SemanticTokenType.function_;
    if (auto fd = s.isFuncDeclaration())
        return fd.isThis() ? SemanticTokenType.method : SemanticTokenType.function_;
    if (s.isEnumMember())
        return SemanticTokenType.enumMember;
    if (auto vd = s.isVarDeclaration())
    {
        if (vd.storage_class & STC.parameter)
            return SemanticTokenType.parameter;
        return vd.isField() ? SemanticTokenType.property : SemanticTokenType.variable;
    }
    if (s.isInterfaceDeclaration())
        return SemanticTokenType.interface_;
    if (s.isClassDeclaration())
        return SemanticTokenType.class_;
    if (s.isStructDeclaration())
        return SemanticTokenType.struct_;
    if (s.isEnumDeclaration())
        return SemanticTokenType.enum_;
    if (s.isModule() || s.isPackage() || s.isImport())
        return SemanticTokenType.namespace;
    if (s.isTemplateInstance())
        return SemanticTokenType.type;
    if (auto ad = s.isAliasDeclaration())
        return ad.aliassym && ad.aliassym !is s ? symbolTokenType(ad.aliassym) : SemanticTokenType.type;
    return -1;
}

/// The modifier bits for `s`, excluding `declaration`
private int symbolTokenModifiers(Dsymbol s)
{
    int mods = 0;
    if (s.isDeprecated())
        mods |= SemanticTokenModifier.deprecated_;
    if (auto vd = s.isVarDeclaration())
    {
        if ((vd.storage_class & STC.manifest) || vd.isEnumMember()
            || (vd.type && (vd.type.isConst() || vd.type.isImmutable())))
            mods |= SemanticTokenModifier.readonly;
        if (vd.isStatic() && !vd.isField() && vd.parent && vd.parent.isAggregateDeclaration())
            mods |= SemanticTokenModifier.static_;
    }
    if (auto fd = s.isFuncDeclaration())
        if (fd.isStatic() && fd.parent && fd.parent.isAggregateDeclaration())
            mods |= SemanticTokenModifier.static_;
    SourceLoc sl = SourceLoc(s.loc);
    if (sl.line > 0 && sl.filename != rootFilename)
        mods |= SemanticTokenModifier.defaultLibrary;
    return mods;
}

/// Handle textDocument/semanticTokens/full: one token per occurrence, sorted,
/// overlaps dropped, delta-encoded, columns in the client's encoding
void semanticTokens(ref Lsp lsp, Params params, ref OutBuffer buf)
{
    Module m = analyzeModule(lsp, params.textDocument.uri);
    if (!m)
        return;
    auto tokens = collectOccurrences(m).occurrences;
    foreach (i; 1 .. tokens.length)
    {
        auto t = tokens[i];
        size_t j = i;
        while (j > 0 && (t.loc.line < tokens[j - 1].loc.line
            || (t.loc.line == tokens[j - 1].loc.line && t.loc.column < tokens[j - 1].loc.column)))
        {
            tokens[j] = tokens[j - 1];
            j--;
        }
        tokens[j] = t;
    }

    int prevLine = 1;
    int prevColumn = 0;
    int prevEnd = 0;
    bool first = true;
    foreach (ref t; tokens)
    {
        const type = symbolTokenType(t.sym);
        if (type < 0 || (t.loc.line == prevLine && t.loc.column < prevEnd))
            continue;
        const column = clientColumn(lsp, rootFilename, t.loc.line, t.loc.column);
        const length = clientColumn(lsp, rootFilename, t.loc.line, t.loc.column + t.len) - column;
        const mods = symbolTokenModifiers(t.sym) | (t.declaration ? SemanticTokenModifier.declaration : 0);
        if (!first)
            buf.writestring(",");
        buf.printf("%d,%d,%d,%d,%d", t.loc.line - prevLine, t.loc.line == prevLine ? column - prevColumn : column,
            length, type, mods);
        first = false;
        prevLine = t.loc.line;
        prevColumn = column;
        prevEnd = t.loc.column + t.len;
    }
}

// ----------------------------------------------------------------------------
// Document symbols
// ----------------------------------------------------------------------------

/// LSP SymbolKind values for the kinds documentSymbol emits.
private int documentSymbolKind(Dsymbol s)
{
    if (auto fd = s.isFuncDeclaration())
        return fd.isThis() ? 6 : 12;       // Method : Function
    if (s.isInterfaceDeclaration())
        return 11;                         // Interface
    if (s.isClassDeclaration())
        return 5;                          // Class
    if (s.isStructDeclaration())
        return 23;                         // Struct
    if (s.isEnumDeclaration())
        return 10;                         // Enum
    if (s.isEnumMember())
        return 22;                         // EnumMember
    if (auto vd = s.isVarDeclaration())
        return vd.isField() ? 8 : 13;      // Field : Variable
    return 13;                             // Variable (fallback)
}

/// Write one DocumentSymbol JSON object for `s`, recursing into aggregate and
/// enum members as `children`.
/// Returns: false (and writes nothing) for unnamed, generated, or locationless symbols.
private bool writeDocumentSymbol(ref OutBuffer buf, ref Lsp lsp, Dsymbol s)
{
    const(char)[] name = s.ident ? s.ident.toString() : null;
    int kind = documentSymbolKind(s);
    if (s.isCtorDeclaration())
    {
        name = "this";
        kind = 9;                          // Constructor
    }
    if (name.length == 0 || name.startsWith("__"))
        return false;
    if (auto fd = s.isFuncDeclaration())
        if (fd.isGenerated)
            return false;
    SourceLoc sl = SourceLoc(s.loc);
    if (sl.filename.length == 0 || sl.line == 0)
        return false;
    const len = cast(int) name.length;
    buf.writestring(`{"name":"`);
    buf.writeJsonString(name);
    buf.printf(`","kind":%d,`, kind);
    if (s.isDeprecated())
        buf.writestring(`"tags":[1],`);

    int endLine = sl.line;
    int endCol = sl.column + len;
    if (auto fd = s.isFuncDeclaration())
    {
        SourceLoc el = SourceLoc(fd.endloc);
        if (el.line > 0)
        {
            endLine = el.line;
            endCol = el.column + 1;
        }
    }
    buf.printf(`"range":{"start":{"line":%d,"character":%d},"end":{"line":%d,"character":%d}},`,
        sl.line - 1, clientColumn(lsp, sl.filename, sl.line, sl.column),
        endLine - 1, clientColumn(lsp, sl.filename, endLine, endCol));
    buf.writestring(`"selectionRange":`);
    writeRange(buf, lsp, sl.filename, sl.line, sl.column, len);

    Dsymbols* members = null;
    if (auto ad = s.isAggregateDeclaration())
        members = ad.members;
    else if (auto ed = s.isEnumDeclaration())
        members = ed.members;
    if (members)
    {
        buf.writestring(`,"children":[`);
        writeDocumentSymbols(buf, lsp, *members);
        buf.writestring(`]`);
    }
    buf.writestring(`}`);
    return true;
}

/// Write a comma-separated list of DocumentSymbols for declarations in `members`.
private void writeDocumentSymbols(ref OutBuffer buf, ref Lsp lsp, ref Dsymbols members)
{
    bool first = true;
    writeDocumentSymbols(buf, lsp, members, first);
}

private void writeDocumentSymbols(ref OutBuffer buf, ref Lsp lsp, ref Dsymbols members, ref bool first)
{
    foreach (s; members)
    {
        if (auto ad = s.isAttribDeclaration())
        {
            if (auto d = ad.include(null))
                writeDocumentSymbols(buf, lsp, *d, first);
            continue;
        }
        if (!s.isFuncDeclaration() && !s.isAggregateDeclaration()
            && !s.isEnumDeclaration() && !s.isVarDeclaration())
            continue;
        const before = buf.length;
        if (!first)
            buf.writestring(",");
        if (writeDocumentSymbol(buf, lsp, s))
            first = false;
        else
            buf.setsize(before);
    }
}

/// Handle textDocument/documentSymbol: write a hierarchical DocumentSymbol
/// array for the module's declarations.
void documentSymbols(ref Lsp lsp, Params params, ref OutBuffer buf)
{
    Module m = analyzeModule(lsp, params.textDocument.uri);
    buf.writestring(`[`);
    if (m && m.members)
        writeDocumentSymbols(buf, lsp, *m.members);
    buf.writestring(`]`);
}

// ----------------------------------------------------------------------------
// References, highlight, rename
// ----------------------------------------------------------------------------

/// What occurrences are compared by: a constructor stands for its aggregate,
/// a template's eponymous and instance members for the template
private Dsymbol referenceTarget(Dsymbol s)
{
    if (auto ctor = s.isCtorDeclaration())
        if (auto ad = ctor.isMember())
            return ad;
    if (auto td = templateOf(s))
        return td;
    return s;
}

/// The symbol at the cursor and its declaration plus every occurrence of it in the document
private Occurrence[] findReferences(ref Lsp lsp, Params params, out Dsymbol target)
{
    Module m = analyzeModule(lsp, params.textDocument.uri);
    if (!m)
        return null;
    auto occurrences = collectOccurrences(m).occurrences;
    target = symbolAt(occurrences, toSourceLoc(params.textDocument.uri, params.position));
    if (!target || !target.ident)
        return null;
    Occurrence[] refs;
    SourceLoc dl = SourceLoc(declarationLoc(target));
    if (dl.line)
        refs ~= Occurrence(dl, declarationLength(target), target, true);
    foreach (o; occurrences)
    {
        if (referenceTarget(o.sym) !is referenceTarget(target))
            continue;
        bool seen = false;
        foreach (r; refs)
            if (r.loc.line == o.loc.line && r.loc.column == o.loc.column && r.loc.filename == o.loc.filename)
                seen = true;
        if (!seen)
            refs ~= o;
    }
    return refs;
}

/// Handle textDocument/references
void references(ref Lsp lsp, Params params, ref OutBuffer buf)
{
    Dsymbol target;
    buf.writestring(`[`);
    foreach (i, r; findReferences(lsp, params, target))
    {
        if (i)
            buf.writestring(",");
        writeLocationAt(buf, lsp, r.loc, r.len);
    }
    buf.writestring(`]`);
}

/// Handle textDocument/documentHighlight: the references within the document
void documentHighlight(ref Lsp lsp, Params params, ref OutBuffer buf)
{
    Dsymbol target;
    const filename = uriFilename(params.textDocument.uri);
    buf.writestring(`[`);
    bool first = true;
    foreach (r; findReferences(lsp, params, target))
    {
        if (!sameFile(r.loc.filename, filename))
            continue;
        if (!first)
            buf.writestring(",");
        first = false;
        buf.writestring(`{"range":`);
        writeRange(buf, lsp, r.loc.filename, r.loc.line, r.loc.column, r.len);
        buf.writestring(`,"kind":1}`);
    }
    buf.writestring(`]`);
}

/// Whether every use of `s` must be in the file declaring it: locals,
/// parameters, nested functions, and private symbols
private bool renameStaysInFile(Dsymbol s)
{
    for (Dsymbol p = s.parent; p; p = p.parent)
    {
        if (p.isFuncDeclaration())
            return true;
        if (p.isModule())
            break;
    }
    if (s.visible().kind == Visibility.Kind.private_)
        return true;
    for (Dsymbol p = s.parent; p; p = p.parent)
    {
        if (p.isModule())
            break;
        if (p.visible().kind == Visibility.Kind.private_)
            return true;
    }
    return false;
}

/// Handle textDocument/rename: a WorkspaceEdit replacing every reference.
/// Returns: an error message when the rename can't be done completely.
string rename(ref Lsp lsp, Params params, ref OutBuffer buf)
{
    if (params.newName.length == 0)
        return "no new name given";
    Dsymbol target;
    auto refs = findReferences(lsp, params, target);
    if (!target)
        return "no renamable symbol at the cursor";
    const filename = uriFilename(params.textDocument.uri);
    if (!sameFile(SourceLoc(target.loc).filename, filename))
        return "cannot rename a symbol declared in another file";
    if (!renameStaysInFile(target))
        return "cannot rename a symbol that may be used from other files";
    if (target.isCtorDeclaration())
        return "cannot rename a constructor";
    buf.writestring(`{"changes":{"`);
    buf.writeJsonString(params.textDocument.uri);
    buf.writestring(`":[`);
    foreach (i, r; refs)
    {
        if (i)
            buf.writestring(",");
        buf.writestring(`{"range":`);
        writeRange(buf, lsp, r.loc.filename, r.loc.line, r.loc.column, r.len);
        buf.writestring(`,"newText":"`);
        buf.writeJsonString(params.newName);
        buf.writestring(`"}`);
    }
    buf.writestring(`]}}`);
    return null;
}

// ----------------------------------------------------------------------------
// Protocol
// ----------------------------------------------------------------------------

enum maxPayloadLength = 16 * 1024 * 1024;

private void sendMessage(ref OutBuffer buf)
{
    printf("Content-Length: %d\r\n\r\n", cast(int) buf.length);
    const data = buf.peekSlice();
    if (data.length)
        fwrite(data.ptr, 1, data.length, stdout);
    fflush(stdout);
}

private void writeDiagnostic(ref OutBuffer buf, ref Lsp lsp, ref Diagnostic d)
{
    buf.writestring(`{"range":`);
    if (d.line > 0)
        writeRange(buf, lsp, d.filename, d.line, d.column, 1);
    else
        buf.writestring(`{"start":{"line":0,"character":0},"end":{"line":0,"character":1}}`);
    buf.printf(`,"severity":%d,"message":"`, d.severity);
    buf.writeJsonString(d.message);
    buf.writestring(`"`);
    if (d.deprecation)
        buf.writestring(`,"tags":[2]`);
    if (d.related.length)
    {
        buf.writestring(`,"relatedInformation":[`);
        foreach (i, r; d.related)
        {
            if (i)
                buf.writestring(",");
            buf.writestring(`{"location":{"uri":"`);
            writeFileUri(buf, r.filename);
            buf.writestring(`","range":`);
            writeRange(buf, lsp, r.filename, r.line, r.column, 1);
            buf.writestring(`},"message":"`);
            buf.writeJsonString(r.message);
            buf.writestring(`"}`);
        }
        buf.writestring(`]`);
    }
    buf.writestring(`}`);
}

private void sendDiagnostics(ref Lsp lsp, string uri, Diagnostic[] diagnostics, bool delegate(ref Diagnostic) include)
{
    OutBuffer buf;
    buf.writestring(`{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"`);
    buf.writeJsonString(uri);
    buf.writestring(`","diagnostics":[`);
    bool first = true;
    foreach (ref d; diagnostics)
    {
        if (!include(d))
            continue;
        if (!first)
            buf.writestring(",");
        first = false;
        writeDiagnostic(buf, lsp, d);
        if (buf.length > maxPayloadLength)
            break;
    }
    buf.writestring(`]}}`);
    sendMessage(buf);
}

/// Publish the diagnostics of analyzing `uri`; those in other files go to
/// their own URIs and are cleared again next time
void publishDiagnostics(ref Lsp lsp, string uri)
{
    analyzeModule(lsp, uri);
    auto diagnostics = lsp.eSink.diagnostics;
    const rootFile = uriFilename(uri);

    bool isRoot(ref Diagnostic d)
    {
        return d.line == 0 || d.filename.length == 0 || sameFile(d.filename, rootFile);
    }
    sendDiagnostics(lsp, uri, diagnostics, &isRoot);

    string[] published;
    foreach (ref d; diagnostics)
    {
        if (isRoot(d))
            continue;
        OutBuffer uriBuf;
        writeFileUri(uriBuf, d.filename);
        string otherUri = uriBuf.extractSlice().idup;
        bool seen = false;
        foreach (u; published)
            if (u == otherUri)
                seen = true;
        if (seen)
            continue;
        published ~= otherUri;
        const(char)[] file = d.filename;
        sendDiagnostics(lsp, otherUri, diagnostics, (ref Diagnostic x) => x.line > 0 && x.filename == file);
    }
    foreach (old; lsp.publishedUris)
    {
        bool still = false;
        foreach (u; published)
            if (u == old)
                still = true;
        if (!still && old != uri)
            sendDiagnostics(lsp, old, null, (ref Diagnostic x) => false);
    }
    lsp.publishedUris = published;
}

/// The byte offset of the 0-based, byte column `pos` in `content`
size_t byteOffset(const(char)[] content, Position pos)
{
    size_t off = 0;
    for (int line = 0; line < pos.line && off < content.length; off++)
    {
        if (content[off] == '\n')
            line++;
    }
    off += pos.character;
    if (off > content.length)
        off = content.length;
    return off;
}

/// Apply the content changes of a didChange notification to the document
/// text `content`
string applyContentChanges(ref Lsp lsp, string content, ContentChange[] changes)
{
    foreach (ref change; changes)
    {
        if (change.range.start.line < 0)
        {
            content = change.text;
            continue;
        }
        Position start = change.range.start;
        Position end = change.range.end;
        start.character = byteColumn(lsp, content, start.line, start.character);
        end.character = byteColumn(lsp, content, end.line, end.character);
        const startOff = byteOffset(content, start);
        size_t endOff = byteOffset(content, end);
        if (endOff < startOff)
            endOff = startOff;
        content = content[0 .. startOff] ~ change.text ~ content[endOff .. $];
    }
    return content;
}

int lspMain()
{
    import core.stdc.stdlib : atoi;

    Lsp lsp;
    lsp.eSink = new ErrorSinkLsp();
    if (auto sink = cast(ErrorSinkCompiler) global.errorSink)
        lsp.eSink.useDeprecated = sink.useDeprecated;
    scope jsonSink = new ErrorSinkNull();

    // Keep a compiler fatal() from taking the whole server down. dmd signals
    // many unrecoverable conditions - a failed `static assert`, an unresolvable
    // import, an internal error - by calling fatal(), which exits the process.
    // That is fine for a one-shot compile but fatal (literally) for a long-lived
    // language server: a single bad file, or a transient false error while the
    // user is mid-edit, would kill it. While an analysis is in progress we route
    // fatal() back to the recovery point armed in analyzeModule instead (see
    // lspFatalEnv), abandoning just that analysis. Outside an analysis we let
    // fatal() exit normally.
    version (Posix)
    {
        import dmd.errors : fatalErrorHandler;
        import core.sys.posix.setjmp : longjmp;
        fatalErrorHandler = () {
            if (lspFatalArmed)
            {
                lspFatalArmed = false;
                longjmp(lspFatalEnv, 1); // does not return
            }
            return false; // not analyzing: allow the normal exit
        };
    }

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

        if (contentLength <= 0)
        {
            if (ferror(stdin))
                return 1;
            continue;
        }

        if (contentLength > maxPayloadLength)
        {
            fprintf(stderr, "[!] Content-Length %d exceeds the payload limit, aborting\n", contentLength);
            return 1;
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
                    fprintf(stderr, "[!] read error, errno = %d\n", errno);
                    return errno;
                }
                break; // EOF mid-message
            }
            totalRead += n;
        }

        if (totalRead < json.length)
        {
            fprintf(stderr, "[!] truncated message: got %d of %d bytes\n",
                cast(int) totalRead, cast(int) json.length);
            return 1;
        }

        enum maxEcho = 4 * 1024;
        fprintf(stderr, "[!] Content = %.*s\n",
            cast(int) utf8Trim(json, maxEcho), json.ptr);
        JsonRpc result;
        jsonParse(result, json, jsonSink);
        if (result.method.length == 0)
            continue;
        fprintf(stderr, "[!] Responding to %.*s\n", cast(int) result.method.length, result.method.ptr);
        if (result.method == "exit")
            return lsp.shutdownRequested ? 0 : 1;
        lspRespond(lsp, result);
    }
    return 0;
}

/// Handle a notification: returns false when the method is unknown
private bool handleNotification(ref Lsp lsp, ref JsonRpc msg)
{
    auto params = &msg.params;
    switch (msg.method)
    {
    case "initialized", "$/cancelRequest", "$/setTrace", "workspace/didChangeConfiguration":
        return true;
    case "textDocument/didOpen":
        lsp.openDocuments[params.textDocument.uri] = params.textDocument.text;
        deinitializeModule(lsp);
        publishDiagnostics(lsp, params.textDocument.uri);
        return true;
    case "textDocument/didChange":
        string content;
        if (auto p = params.textDocument.uri in lsp.openDocuments)
            content = *p;
        lsp.openDocuments[params.textDocument.uri] = applyContentChanges(lsp, content, params.contentChanges);
        deinitializeModule(lsp);
        publishDiagnostics(lsp, params.textDocument.uri);
        return true;
    case "textDocument/didClose":
        lsp.openDocuments.remove(params.textDocument.uri);
        deinitializeModule(lsp);
        return true;
    case "textDocument/didSave":
        deinitializeModule(lsp);
        return true;
    default:
        return false;
    }
}

void lspRespond(ref Lsp lsp, JsonRpc msg)
{
    if (msg.id < 0)
    {
        if (!handleNotification(lsp, msg))
            fprintf(stderr, "[!] unknown notification %.*s\n", msg.method.fTuple.expand);
        return;
    }

    OutBuffer buf;
    string error;
    int errorCode = -32803;
    auto params = msg.params;
    if (msg.method != "initialize")
        params.position = toBytePosition(lsp, params.textDocument.uri, params.position);

    switch (msg.method)
    {
    case "initialize":
        lsp.utf16 = true;
        foreach (enc; params.capabilities.general.positionEncodings)
            if (enc == "utf-8")
                lsp.utf16 = false;
        // The semanticTokens legend must match SemanticTokenType / SemanticTokenModifier
        buf.printf(`{"capabilities":{
            "positionEncoding":"%s",
            "definitionProvider":true,
            "hoverProvider":true,
            "completionProvider":{"triggerCharacters":["."]},
            "signatureHelpProvider":{"triggerCharacters":["(",","]},
            "documentSymbolProvider":true,
            "referencesProvider":true,
            "documentHighlightProvider":true,
            "renameProvider":true,
            "semanticTokensProvider":{"legend":{"tokenTypes":["type","namespace","class","enum","interface","struct","parameter","variable","property","enumMember","function","method"],"tokenModifiers":["declaration","static","deprecated","readonly","defaultLibrary"]},"full":true},
            "textDocumentSync":1
            }}`, lsp.utf16 ? "utf-16".ptr : "utf-8".ptr);
        break;
    case "shutdown":
        lsp.shutdownRequested = true;
        buf.writestring("null");
        break;
    case "textDocument/definition":
        Dsymbol target = symbolAt(lsp, params);
        if (!target || !writeLocation(buf, lsp, target))
            buf.writestring("null");
        break;
    case "textDocument/hover":
        Dsymbol target = symbolAt(lsp, params);
        if (!target)
        {
            buf.writestring("null");
            break;
        }
        buf.writestring(`{"contents":{"kind":"markdown","value":"`);
        buf.writeJsonString(hoverText(target));
        buf.writestring(`"}}`);
        break;
    case "textDocument/completion":
        buf.writestring(`{"isIncomplete":false,"items":[`);
        completionItems(lsp, params, buf);
        buf.writestring(`]}`);
        break;
    case "textDocument/signatureHelp":
        signatureHelp(lsp, params, buf);
        break;
    case "textDocument/semanticTokens/full":
        buf.writestring(`{"data":[`);
        semanticTokens(lsp, params, buf);
        buf.writestring(`]}`);
        break;
    case "textDocument/documentSymbol":
        documentSymbols(lsp, params, buf);
        break;
    case "textDocument/references":
        references(lsp, params, buf);
        break;
    case "textDocument/documentHighlight":
        documentHighlight(lsp, params, buf);
        break;
    case "textDocument/rename":
        error = rename(lsp, params, buf);
        break;
    default:
        fprintf(stderr, "[!] unknown method %.*s\n", msg.method.fTuple.expand);
        error = "method not found: " ~ msg.method;
        errorCode = -32601;
        break;
    }

    OutBuffer response;
    if (error.length)
    {
        response.printf(`{"jsonrpc":"2.0","id":%d,"error":{"code":%d,"message":"`, msg.id, errorCode);
        response.writeJsonString(error);
        response.writestring(`"}}`);
    }
    else
    {
        response.printf(`{"jsonrpc":"2.0","id":%d,"result":`, msg.id);
        response.write(buf.peekSlice());
        response.writestring(`}`);
    }
    if (response.length > maxPayloadLength)
    {
        fprintf(stderr, "[!] response of %d bytes exceeds the payload limit, replaced by null\n",
            cast(int) response.length);
        response.reset();
        response.printf(`{"jsonrpc":"2.0","id":%d,"result":null}`, msg.id);
    }
    sendMessage(response);
}

// struct and field names match JsonRPC / LSP protocol
struct JsonRpc
{
    int id = -1;
    string method;
    Params params;
}

struct Params
{
    Uri textDocument;
    Position position;
    string rootPath; // main folder that is open in editor
    ContentChange[] contentChanges; // textDocument/didChange
    Capabilities capabilities; // initialize
    string newName; // textDocument/rename
}

struct Capabilities
{
    General general;
}

struct General
{
    string[] positionEncodings;
}

struct Uri
{
    string uri;
    string text; // populated in textDocument/didOpen
}

struct ContentChange
{
    Range range = Range(Position(-1, -1), Position(-1, -1));
    string text;
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
    result.filename = uriFilename(uri);
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

    string initialize = `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":20036,"clientInfo":{"name":"Sublime Text LSP","version":"2.3.0"},"rootUri":"file:///home/dennis/repos/dmd","rootPath":"/home/dennis/repos/dmd","workspaceFolders":[{"name":"dmd","uri":"file:///home/dennis/repos/dmd"}],"capabilities":{"general":{"regularExpressions":{"engine":"ECMAScript"},"markdown":{"parser":"Python-Markdown","version":"3.2.2"},"positionEncodings":["utf-16","utf-8"]},"textDocument":{"synchronization":{"dynamicRegistration":true,"didSave":true,"willSave":true,"willSaveWaitUntil":true},"hover":{"dynamicRegistration":true,"contentFormat":["markdown","plaintext"]},"completion":{"dynamicRegistration":true,"completionItem":{"snippetSupport":true,"deprecatedSupport":true,"documentationFormat":["markdown","plaintext"],"tagSupport":{"valueSet":[1]},"resolveSupport":{"properties":["detail","documentation","additionalTextEdits"]},"insertReplaceSupport":true,"insertTextModeSupport":{"valueSet":[2]},"labelDetailsSupport":true},"completionItemKind":{"valueSet":[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25]},"insertTextMode":2,"completionList":{"itemDefaults":["editRange","insertTextFormat","data"]}},"signatureHelp":{"dynamicRegistration":true,"contextSupport":true,"signatureInformation":{"activeParameterSupport":true,"documentationFormat":["markdown","plaintext"],"parameterInformation":{"labelOffsetSupport":true}}},"references":{"dynamicRegistration":true},"documentHighlight":{"dynamicRegistration":true},"documentSymbol":{"dynamicRegistration":true,"hierarchicalDocumentSymbolSupport":true,"symbolKind":{"valueSet":[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26]},"tagSupport":{"valueSet":[1]}},"semanticTokens":{"dynamicRegistration":true,"requests":{"range":true,"full":{"delta":true}},"tokenTypes":["namespace","type"],"tokenModifiers":["declaration"],"formats":["relative"],"overlappingTokenSupport":false,"multilineTokenSupport":true,"augmentsSyntaxTokens":true}},"workspace":{"applyEdit":true,"workspaceEdit":{"documentChanges":true,"failureHandling":"abort"},"workspaceFolders":true,"configuration":true},"window":{"showDocument":{"support":true},"workDoneProgress":true}},"initializationOptions":{}}}`;
    jsonParse(result, initialize, eSink);
    assert(result.params.capabilities.general.positionEncodings == ["utf-16", "utf-8"]);

    // textDocument/didOpen: params.textDocument.text contains the full file content
    JsonRpc didOpen;
    jsonParse(didOpen, `{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///foo.d","languageId":"d","version":1,"text":"module foo;\nint x = 5;\n"}}}`, eSink);
    assert(didOpen.id == -1);
    assert(didOpen.method == "textDocument/didOpen");
    assert(didOpen.params.textDocument.uri == "file:///foo.d");
    assert(didOpen.params.textDocument.text == "module foo;\nint x = 5;\n");

    // textDocument/didChange: contentChanges[0].text is the full new content (Full sync)
    JsonRpc didChange;
    jsonParse(didChange, `{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///foo.d","version":2},"contentChanges":[{"text":"module foo;\nint x = 42;\n"}]}}`, eSink);
    assert(didChange.method == "textDocument/didChange");
    assert(didChange.params.textDocument.uri == "file:///foo.d");
    assert(didChange.params.contentChanges.length == 1);
    assert(didChange.params.contentChanges[0].text == "module foo;\nint x = 42;\n");
    assert(didChange.params.contentChanges[0].range.start.line == -1);

    JsonRpc ranged;
    jsonParse(ranged, `{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///foo.d","version":3},"contentChanges":[{"range":{"start":{"line":1,"character":8},"end":{"line":1,"character":9}},"rangeLength":1,"text":"7"},{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"text":"// c\n"}]}}`, eSink);
    assert(ranged.params.contentChanges.length == 2);
    assert(ranged.params.contentChanges[0].range.start == Position(1, 8));
    Lsp lsp;
    assert(applyContentChanges(lsp, "module foo;\nint x = 5;\n", ranged.params.contentChanges) == "// c\nmodule foo;\nint x = 7;\n");

    assert(applyContentChanges(lsp, "auto s = \"\U0001F600\"; int y;\n", [ContentChange(Range(Position(0, 15), Position(0, 16)), "z")])
        == "auto s = \"\U0001F600\"; znt y;\n");
    lsp.utf16 = false;
    assert(applyContentChanges(lsp, "auto s = \"\U0001F600\"; int y;\n", [ContentChange(Range(Position(0, 15), Position(0, 16)), "z")])
        == "auto s = \"\U0001F600\"z int y;\n");

    assert(uriFilename("file:///home/a%20b/c%C3%A9.d") == "/home/a b/cé.d");
    assert(uriFilename("untitled:x") is null);
    OutBuffer uri;
    writeFileUri(uri, "/home/a b/cé.d");
    assert(uri.peekChars().toDString() == "file:///home/a%20b/c%C3%A9.d");
}

unittest
{
    const text = "abc\ndef\n";
    assert(byteOffset(text, Position(1, 2)) == 6);
    assert(lineSlice("ab\ncd\r\nef", 1) == "cd");
    assert(lineSlice("ab\ncd\r\nef", 2) == "ef");
    assert(lineSlice("ab", 3) == "");
    assert(utf16Length("aé😀b") == 5);
    assert(utf16ToByteOffset("aé😀b", 2) == 3);
    assert(utf16ToByteOffset("aé😀b", 4) == 7);
    assert(utf16ToByteOffset("aé😀b", 9) == 8);
}
