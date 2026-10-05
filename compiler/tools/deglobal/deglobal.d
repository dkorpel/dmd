module deglobal;

import core.stdc.stdio;
import core.stdc.stdlib : exit;

import std.algorithm;
import std.array;
import std.conv : to;
import std.file;
import std.getopt;
import std.path;
import std.range : iota, walkLength;
import std.string;

import dmd.arraytypes;
import dmd.astenums;
import dmd.attrib;
import dmd.declaration;
import dmd.cond : VersionCondition;
import dmd.dmodule;
import dmd.dstruct;
import dmd.dsymbol;
import dmd.dsymbolsem : dsymbolSemantic, importAll, runDeferredSemantic, runDeferredSemantic2, runDeferredSemantic3, include;
import dmd.dtemplate;
import dmd.errorsink;
import dmd.expression;
import dmd.frontend : initDMD;
import dmd.func;
import dmd.funcsem : isVirtual;
import dmd.globals;
import dmd.identifier;
import dmd.lexer;
import dmd.location;
import dmd.mtype;
import dmd.semantic2 : semantic2;
import dmd.semantic3 : semantic3;
import dmd.statement;
import dmd.tokens;
import dmd.visitor;

struct Call
{
    size_t callee;
    size_t caller;
    FuncDeclaration immediate;
    string file;
    uint off;
}

struct Global
{
    VarDeclaration vd;
    string name;
    string type;
    string file;
    size_t[] users;
}

struct Func
{
    FuncDeclaration fd;
    string name;
    string file;
    uint nameOff;
    uint endOff;
    bool editable;
    bool addressTaken;
    bool overloaded;
    bool template_;
    string[] localNames;
    uint[][size_t] globalRefs;
    size_t[] calls;
    size_t[] callers;
}

__gshared Func[] funcs;
__gshared size_t[void*] funcIndex;
__gshared Global[] globals;
__gshared size_t[void*] globalIndex;
__gshared Call[] calls;
__gshared string srcRoot;

string fileOf(Loc loc)
{
    auto f = loc.filename;
    return f ? f.fromStringz.idup : null;
}

uint off(Loc loc)
{
    return loc.filename ? loc.fileOffset : 0;
}

bool isEditableFile(string file)
{
    return file.canFind("/dmd/backend/") || file.canFind("/dmd/glue/") || file.endsWith("/dmd/dmsc.d") || file.endsWith("/dmd/eh.d");
}

size_t addFunc(FuncDeclaration fd)
{
    if (auto p = cast(void*) fd in funcIndex)
        return *p;
    Func f;
    f.fd = fd;
    f.name = fd.ident ? fd.ident.toString.idup : "";
    f.file = fileOf(fd.loc);
    f.nameOff = fd.loc.off;
    f.endOff = fd.endloc.off;
    f.editable = isEditableFile(f.file);
    for (Dsymbol p = fd.parent; p; p = p.parent)
        if (p.isTemplateInstance() || p.isTemplateMixin())
            f.template_ = true;
    funcs ~= f;
    funcIndex[cast(void*) fd] = funcs.length - 1;
    return funcs.length - 1;
}

FuncDeclaration outermost(FuncDeclaration fd)
{
    while (fd)
    {
        auto p = cast(Dsymbol) fd.toParent2();
        if (!p)
            break;
        auto pf = cast(FuncDeclaration) p.isFuncDeclaration();
        if (!pf)
            break;
        fd = pf;
    }
    return fd;
}

bool isBackendGlobal(VarDeclaration vd)
{
    auto f = fileOf(vd.loc);
    if (!f.canFind("/dmd/backend/") && !f.canFind("/dmd/glue/"))
        return false;
    if (vd.storage_class & (STC.manifest | STC.immutable_ | STC.const_))
        return false;
    if (vd.type && (vd.type.isImmutable() || vd.type.isConst()))
        return false;
    if (vd.toParent2() && vd.toParent2().isFuncDeclaration())
        return false;
    return vd.isDataseg();
}

size_t addGlobal(VarDeclaration vd)
{
    if (auto p = cast(void*) vd in globalIndex)
        return *p;
    Global g;
    g.vd = vd;
    g.name = vd.ident.toString.idup;
    g.type = vd.type ? vd.type.toString.idup : "?";
    g.file = fileOf(vd.loc);
    globals ~= g;
    globalIndex[cast(void*) vd] = globals.length - 1;
    return globals.length - 1;
}

extern (C++) final class Collector : SemanticTimeTransitiveVisitor
{
    alias visit = SemanticTimeTransitiveVisitor.visit;

    size_t cur = size_t.max;
    Expression consumed;

    void useGlobal(VarDeclaration vd, Loc loc)
    {
        if (!isBackendGlobal(vd))
            return;
        const g = addGlobal(vd);
        if (cur == size_t.max)
            return;
        funcs[cur].globalRefs[g] ~= loc.off;
        if (!globals[g].users.canFind(cur))
            globals[g].users ~= cur;
    }

    void funcRef(FuncDeclaration fd)
    {
        funcs[addFunc(fd)].addressTaken = true;
    }

    override void visit(CallExp e)
    {
        FuncDeclaration f = e.f;
        if (f)
        {
            Expression e1 = e.e1;
            if (auto ve = e1.isVarExp())
                consumed = ve;
            else if (auto dve = e1.isDotVarExp())
                consumed = dve;
            const callee = addFunc(f);
            Call c;
            c.callee = callee;
            c.caller = cur;
            c.immediate = cur == size_t.max ? null : funcs[cur].fd;
            c.file = fileOf(e.loc);
            c.off = e.loc.off;
            calls ~= c;
        }
        super.visit(e);
    }

    override void visit(VarExp e)
    {
        if (auto vd = e.var.isVarDeclaration())
            useGlobal(vd, e.loc);
        else if (auto fd = e.var.isFuncDeclaration())
            if (consumed !is e)
                funcRef(fd);
    }

    override void visit(SymOffExp e)
    {
        if (auto vd = e.var.isVarDeclaration())
            useGlobal(vd, e.loc);
        else if (auto fd = e.var.isFuncDeclaration())
            funcRef(fd);
    }

    override void visit(DotVarExp e)
    {
        if (auto fd = e.var.isFuncDeclaration())
            if (consumed !is e)
                funcRef(fd);
        super.visit(e);
    }

    override void visit(DelegateExp e)
    {
        funcRef(e.func);
        super.visit(e);
    }

    override void visit(VarDeclaration v)
    {
        if (cur != size_t.max && v.ident)
            funcs[cur].localNames ~= v.ident.toString.idup;
        super.visit(v);
    }

    override void visit(FuncDeclaration fd)
    {
        if (cur != size_t.max && fd.ident)
            funcs[cur].localNames ~= fd.ident.toString.idup;
        if (fd.fbody)
            fd.fbody.accept(this);
    }
}

void walkFunction(FuncDeclaration fd, Collector c)
{
    if (!fd.fbody || fd.semanticRun < PASS.semantic3done)
        return;
    const i = addFunc(fd);
    auto saved = c.cur;
    c.cur = i;
    if (fd.parameters)
        foreach (p; *fd.parameters)
            if (p.ident)
                funcs[i].localNames ~= p.ident.toString.idup;
    fd.fbody.accept(c);
    c.cur = saved;
}

void walkSymbols(Dsymbols* members, Collector c)
{
    if (!members)
        return;
    foreach (s; *members)
        walkSymbol(s, c);
}

void walkSymbol(Dsymbol s, Collector c)
{
    if (!s)
        return;
    if (auto ad = s.isAttribDeclaration())
        return walkSymbols(ad.include(null), c);
    if (s.isTemplateDeclaration())
        return;
    if (auto fd = s.isFuncDeclaration())
    {
        walkFunction(fd, c);
        return;
    }
    if (auto vd = s.isVarDeclaration())
    {
        if (isBackendGlobal(vd))
            addGlobal(vd);
        if (vd._init)
        {
            auto saved = c.cur;
            c.cur = size_t.max;
            vd._init.accept(c);
            c.cur = saved;
        }
        return;
    }
    if (auto ti = s.isTemplateInstance())
        return walkSymbols(ti.members, c);
    if (auto sds = s.isScopeDsymbol())
        return walkSymbols(sds.members, c);
}

string[] dmdSources()
{
    string[] r;
    foreach (e; dirEntries(srcRoot ~ "/dmd", "*.d", SpanMode.depth))
    {
        if (e.name.endsWith("/frontend.d"))
            continue;
        r ~= e.name;
    }
    sort(r);
    return r;
}

void analyze()
{
    initDMD(null, null, ["MARS"]);
    global.params.debugEnabled = true;
    global.params.useUnitTests = true;
    VersionCondition.addPredefinedGlobalIdent("unittest");
    global.params.v.errorLimit = 0;
    global.path.push(ImportPathInfo(srcRoot.toStringz));
    global.path.push(ImportPathInfo((srcRoot ~ "/../../druntime/src").toStringz));
    global.path.push(ImportPathInfo((srcRoot ~ "/../../../phobos").toStringz));
    global.filePath.push((srcRoot ~ "/dmd/res").toStringz);
    global.filePath.push((srcRoot ~ "/../../generated/linux/release/64").toStringz);
    global.filePath.push((srcRoot ~ "/../..").toStringz);

    Module[] mods;
    foreach (file; dmdSources())
    {
        auto id = Identifier.idPool(file.baseName.stripExtension);
        auto m = new Module(Loc.singleFilename(file.toStringz), file, id, 0, 0);
        m.read(Loc.initial);
        mods ~= m;
    }
    foreach (m; mods)
    {
        m.importedFrom = m;
        m.parse();
    }
    foreach (m; mods)
        m.importAll(null);
    foreach (m; mods)
        m.dsymbolSemantic(null);
    runDeferredSemantic();
    foreach (m; mods)
        m.semantic2(null);
    runDeferredSemantic2();
    foreach (m; mods)
        m.semantic3(null);
    runDeferredSemantic3();
    if (global.errors)
    {
        fprintf(stderr, "deglobal: %u semantic errors\n", global.errors);
        exit(1);
    }

    scope c = new Collector();
    foreach (m; mods)
        walkSymbols(m.members, c);

    foreach (ref call; calls)
    {
        if (call.caller != size_t.max)
        {
            auto outer = outermost(funcs[call.caller].fd);
            call.caller = addFunc(outer);
        }
    }
    foreach (i, ref f; funcs)
    {
        auto outer = outermost(f.fd);
        if (outer !is f.fd)
        {
            const oi = addFunc(outer);
            foreach (g, offs; f.globalRefs)
                funcs[oi].globalRefs[g] ~= offs;
            funcs[oi].localNames ~= f.localNames;
        }
    }
    foreach (ref g; globals)
        g.users = g.users.map!(u => addFunc(outermost(funcs[u].fd))).array.sort.uniq.array;
    foreach (ref call; calls)
    {
        if (call.caller == size_t.max)
            continue;
        if (!funcs[call.caller].calls.canFind(call.callee))
            funcs[call.caller].calls ~= call.callee;
        if (!funcs[call.callee].callers.canFind(call.caller))
            funcs[call.callee].callers ~= call.caller;
    }
    size_t[string] nameCount;
    foreach (ref f; funcs)
        if (f.fd.fbody)
            nameCount[f.name ~ "@" ~ (f.fd.parent ? f.fd.parent.toPrettyChars().fromStringz.idup : "")]++;
    foreach (ref f; funcs)
        f.overloaded = nameCount.get(f.name ~ "@" ~ (f.fd.parent ? f.fd.parent.toPrettyChars().fromStringz.idup : ""), 0) > 1;
}

/********************* Text helpers *********************/

__gshared string[string] fileText;

string text(string file)
{
    if (auto p = file in fileText)
        return *p;
    auto t = readText(file);
    fileText[file] = t;
    return t;
}

struct Tok
{
    uint off;
    string ident;
    TOK value;
    ulong intval;
}

__gshared Tok[][string] fileTokens;
__gshared Tok[][string] fileIdents;
__gshared uint[2][][string] fileDead;

Tok[] allTokens(string file)
{
    if (auto p = file in fileTokens)
        return *p;
    auto t = text(file);
    auto buf = (t ~ "\0\0\0\0").dup;
    scope sink = new ErrorSinkNull();
    scope lexer = new Lexer(file.toStringz, buf.ptr, 0, t.length, false, false, sink, &global.compileEnv);
    Tok[] r;
    while (lexer.nextToken() != TOK.endOfFile)
    {
        Tok tk;
        tk.off = lexer.token.loc.off;
        tk.value = lexer.token.value;
        if (tk.value == TOK.identifier)
            tk.ident = lexer.token.ident.toString.idup;
        else if (tk.value == TOK.int32Literal)
            tk.intval = lexer.token.intvalue;
        r ~= tk;
    }
    fileTokens[file] = r;
    return r;
}

Tok[] identTokens(string file)
{
    if (auto p = file in fileIdents)
        return *p;
    auto r = allTokens(file).filter!(tk => tk.value == TOK.identifier).array;
    fileIdents[file] = r;
    return r;
}

size_t statementEnd(Tok[] tks, size_t i)
{
    int depth;
    for (; i < tks.length; i++)
    {
        const v = tks[i].value;
        if (v == TOK.leftCurly || v == TOK.leftParenthesis || v == TOK.leftBracket)
            depth++;
        else if (v == TOK.rightCurly || v == TOK.rightParenthesis || v == TOK.rightBracket)
        {
            depth--;
            if (depth == 0 && v == TOK.rightCurly && (i + 1 >= tks.length || tks[i + 1].value != TOK.else_))
                return i;
        }
        else if (v == TOK.semicolon && depth == 0)
            return i;
    }
    return tks.length - 1;
}

uint[2][] deadRanges(string file)
{
    if (auto p = file in fileDead)
        return *p;
    auto tks = allTokens(file);
    uint[2][] r;
    for (size_t i = 0; i + 4 < tks.length; i++)
    {
        size_t c;
        if (tks[i].value == TOK.static_ && tks[i + 1].value == TOK.if_)
            c = i + 2;
        else if (tks[i].value == TOK.version_ && tks[i + 1].value == TOK.leftParenthesis)
            c = i + 1;
        else
            continue;
        if (tks[c].value != TOK.leftParenthesis || tks[c + 2].value != TOK.rightParenthesis)
            continue;
        const k = tks[c + 1];
        int truth = -1;
        if (k.value == TOK.int32Literal || k.value == TOK.false_ || k.value == TOK.true_)
            truth = k.value == TOK.true_ || k.value == TOK.int32Literal && k.intval != 0;
        else if (k.value == TOK.identifier && k.ident == "none")
            truth = 0;
        if (truth < 0)
            continue;
        const bodyStart = c + 3;
        size_t bodyEnd = bodyStart;
        int depth;
        for (; bodyEnd < tks.length; bodyEnd++)
        {
            const v = tks[bodyEnd].value;
            if (v == TOK.leftCurly || v == TOK.leftParenthesis || v == TOK.leftBracket)
                depth++;
            else if (v == TOK.rightCurly || v == TOK.rightParenthesis || v == TOK.rightBracket)
            {
                if (--depth == 0 && v == TOK.rightCurly)
                    break;
            }
            else if (v == TOK.semicolon && depth == 0)
                break;
        }
        if (bodyEnd >= tks.length)
            continue;
        if (truth == 0)
            r ~= [tks[bodyStart].off, tks[bodyEnd].off + 1];
        if (bodyEnd + 1 < tks.length && tks[bodyEnd + 1].value == TOK.else_ && truth == 1)
        {
            const es = bodyEnd + 2;
            const ee = statementEnd(tks, es);
            r ~= [tks[es].off, tks[ee].off + 1];
        }
    }
    fileDead[file] = r;
    return r;
}

bool isDead(string file, uint off)
{
    return deadRanges(file).any!(d => off >= d[0] && off < d[1]);
}

bool isIdentChar(char c)
{
    return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
}

bool identAt(string t, uint off, string id)
{
    if (off + id.length > t.length || t[off .. off + id.length] != id)
        return false;
    if (off > 0 && isIdentChar(t[off - 1]))
        return false;
    return off + id.length == t.length || !isIdentChar(t[off + id.length]);
}

uint skipWs(string t, uint i)
{
    while (i < t.length && (t[i] == ' ' || t[i] == '\t' || t[i] == '\n' || t[i] == '\r'))
        i++;
    return i;
}

int skipWsBack(string t, int i)
{
    while (i >= 0 && (t[i] == ' ' || t[i] == '\t' || t[i] == '\n' || t[i] == '\r'))
        i--;
    return i;
}

/********************* Report *********************/

bool[size_t] reachSet(size_t g)
{
    bool[size_t] reach;
    size_t[] work = globals[g].users.dup;
    foreach (u; work)
        reach[u] = true;
    while (work.length)
    {
        auto f = work[$ - 1];
        work = work[0 .. $ - 1];
        foreach (c; funcs[f].callers)
            if (c !in reach)
            {
                reach[c] = true;
                work ~= c;
            }
    }
    return reach;
}

bool isLeaf(size_t g, size_t f, bool[size_t] reach)
{
    foreach (c; funcs[f].calls)
        if (c != f && c in reach)
            return false;
    return true;
}

string rel(string file)
{
    return relativePath(file, srcRoot);
}

void report(string only)
{
    auto order = iota(globals.length).array;
    order.sort!((a, b) => globals[a].users.length > globals[b].users.length);
    foreach (g; order)
    {
        auto gl = globals[g];
        if (only.length && gl.name != only)
            continue;
        size_t refs;
        foreach (u; gl.users)
            refs += funcs[u].globalRefs.get(g, null).length;
        auto reach = reachSet(g);
        printf("%-24s %-28s %-32s users=%-4zu refs=%-5zu reach=%zu\n", gl.name.toStringz, gl.type.toStringz,
            rel(gl.file).toStringz, gl.users.length, refs, reach.length);
        if (!only.length)
            continue;
        foreach (u; gl.users)
        {
            auto why = candidateProblem(g, u, paramName(g, ""));
            printf("  %s %-30s %-28s refs=%-3zu callers=%-3zu %s\n", isLeaf(g, u, reach) ? "leaf".ptr : "    ".ptr,
                funcs[u].name.toStringz, rel(funcs[u].file).toStringz, funcs[u].globalRefs[g].length,
                funcs[u].callers.length, why.length ? why.toStringz : "ok".ptr);
        }
    }
}

/********************* Rewrite *********************/

struct Edit
{
    uint off;
    uint len;
    string repl;
}

__gshared Edit[][string] edits;

string paramName(size_t g, string given)
{
    if (given.length)
        return given;
    if (globals[g].name == "cgstate")
        return "cg";
    return globals[g].name;
}

string existingParam(size_t f, size_t g)
{
    auto fd = funcs[f].fd;
    if (!fd.parameters)
        return null;
    foreach (p; *fd.parameters)
        if (p.type && p.type.toString == globals[g].type && (p.storage_class & STC.ref_) && p.ident)
            return p.ident.toString.idup;
    return null;
}

uint paramListOpen(size_t f)
{
    auto t = text(funcs[f].file);
    uint i = funcs[f].nameOff;
    if (!identAt(t, i, funcs[f].name))
        return uint.max;
    i = skipWs(t, cast(uint)(i + funcs[f].name.length));
    if (i >= t.length || t[i] != '(')
        return uint.max;
    return i;
}

size_t tokIndex(string file, uint off)
{
    auto tks = allTokens(file);
    size_t lo = 0, hi = tks.length;
    while (lo < hi)
    {
        const mid = (lo + hi) / 2;
        if (tks[mid].off < off)
            lo = mid + 1;
        else
            hi = mid;
    }
    return lo < tks.length && tks[lo].off == off ? lo : size_t.max;
}

uint callIdent(ref Call c)
{
    const i = tokIndex(c.file, c.off);
    auto tks = allTokens(c.file);
    if (i == size_t.max || i == 0 || tks[i].value != TOK.leftParenthesis || tks[i - 1].value != TOK.identifier)
        return uint.max;
    return tks[i - 1].off;
}

enum Qual { none, ok, ufcs, bad }

Qual qualifier(string file, uint id, FuncDeclaration fd, out uint recvOff)
{
    auto tks = allTokens(file);
    const i = tokIndex(file, id);
    if (i < 2 || tks[i - 1].value != TOK.dot)
        return Qual.none;
    if (fd.isThis())
        return Qual.ok;
    const q = tks[i - 2];
    if (q.value != TOK.identifier)
        return Qual.bad;
    if (auto m = fd.getModule())
        if (m.ident && q.ident == m.ident.toString)
            return Qual.ok;
    if (auto p = fd.toParent())
        if (auto ad = p.isAggregateDeclaration())
            if (ad.ident && q.ident == ad.ident.toString)
                return Qual.ok;
    if (i >= 3 && (tks[i - 3].value == TOK.dot || tks[i - 3].value == TOK.rightParenthesis || tks[i - 3].value == TOK.rightBracket))
        return Qual.bad;
    recvOff = q.off;
    return Qual.ufcs;
}

bool inImport(string file, uint off)
{
    auto tks = allTokens(file);
    auto i = tokIndex(file, off);
    if (i == size_t.max)
        return false;
    for (; i > 0; i--)
    {
        const v = tks[i - 1].value;
        if (v == TOK.import_)
            return true;
        if (v == TOK.semicolon || v == TOK.leftCurly || v == TOK.rightCurly)
            return false;
    }
    return false;
}

string lineOf(string file, uint off)
{
    auto t = text(file);
    return rel(file) ~ ":" ~ (t[0 .. min(off, t.length)].count('\n') + 1).to!string;
}

uint[2][] patternLines(size_t f, size_t g, string pname)
{
    auto fn = &funcs[f];
    auto t = text(fn.file);
    const want = globals[g].type ~ "*" ~ pname ~ "=&" ~ globals[g].name ~ ";";
    const wantAuto = "auto" ~ pname ~ "=&" ~ globals[g].name ~ ";";
    uint[2][] r;
    uint i = fn.nameOff;
    while (i < fn.endOff)
    {
        uint e = i;
        while (e < t.length && t[e] != '\n')
            e++;
        auto line = t[i .. e];
        const c = line.indexOf("//");
        if (c >= 0)
            line = line[0 .. c];
        const norm = line.filter!(ch => ch != ' ' && ch != '\t' && ch != '\r').to!string;
        if (norm == want || norm == wantAuto)
            r ~= [i, cast(uint) min(e + 1, t.length)];
        i = e + 1;
    }
    return r;
}

uint deadCallOpen(string file, Tok tok)
{
    auto t = text(file);
    const i = skipWs(t, cast(uint)(tok.off + tok.ident.length));
    return i < t.length && t[i] == '(' ? i : uint.max;
}

string enclosingArg(string file, uint off, size_t g)
{
    size_t best = size_t.max;
    foreach (i, ref o; funcs)
        if (o.file == file && o.nameOff <= off && off < o.endOff && !o.fd.isNested())
            best = i;
    return best == size_t.max ? globals[g].name : callerArg(best, g);
}

string unexplainedUse(size_t f)
{
    const name = funcs[f].name;
    bool[string] known;
    foreach (ref o; funcs)
        if (o.name == name)
            known[o.file ~ ":" ~ o.nameOff.to!string] = true;
    foreach (ref c; calls)
        if (funcs[c.callee].name == name)
        {
            const id = callIdent(c);
            if (id != uint.max)
                known[c.file ~ ":" ~ id.to!string] = true;
        }
    foreach (file; editableFiles())
        foreach (tok; identTokens(file))
            if (tok.ident == name && (file ~ ":" ~ tok.off.to!string) !in known && !inImport(file, tok.off) && !(isDead(file, tok.off) && deadCallOpen(file, tok) != uint.max))
                return lineOf(file, tok.off);
    return null;
}

uint[] globalRefOffsets(size_t f, size_t g)
{
    auto t = text(funcs[f].file);
    uint[] r;
    foreach (off; funcs[f].globalRefs.get(g, null))
    {
        if (off < t.length && t[off] == '&')
            off = skipWs(t, off + 1);
        r ~= off;
    }
    foreach (tok; identTokens(funcs[f].file))
        if (tok.off > funcs[f].nameOff && tok.off < funcs[f].endOff && tok.ident == globals[g].name && isDead(funcs[f].file, tok.off))
            r ~= tok.off;
    return r.sort.uniq.array;
}

string cannotTouchGlobal(FuncDeclaration fd)
{
    for (; fd; fd = cast(FuncDeclaration) fd.toParent2().isFuncDeclaration())
    {
        auto tf = fd.type ? fd.type.isTypeFunction() : null;
        if (!tf)
            continue;
        if (tf.trust == TRUST.safe)
            return "@safe";
        if (tf.purity != PURE.impure)
            return "pure";
    }
    return null;
}

string candidateProblem(size_t g, size_t f, string pname)
{
    auto fn = &funcs[f];
    auto fd = fn.fd;
    if (!fn.editable)
        return "not in backend/glue";
    if (fn.template_)
        return "template";
    if (fd.isNested())
        return "nested";
    if (fn.addressTaken)
        return "address taken";
    if (fn.overloaded)
        return "overloaded";
    if (fd.isVirtual())
        return "virtual";
    if (fd._linkage != LINK.d && fd._linkage != LINK.default_)
        return "linkage";
    if (auto ad = fd.isThis())
        if (ad.type && ad.type.toString == globals[g].type)
            return "member of state type";
    auto t = text(fn.file);
    auto pn = existingParam(f, g);
    if (!pn.length && paramListOpen(f) == uint.max)
        return "can't find parameter list";
    if (!pn.length && pname != globals[g].name)
    {
        const decls = fn.localNames.count(pname);
        if (decls != patternLines(f, g, pname).length)
            return "name clash: " ~ pname;
    }
    auto gname = globals[g].name;
    uint[] refs = globalRefOffsets(f, g);
    foreach (off; refs)
        if (!identAt(t, off, gname))
            return "global ref not at identifier " ~ lineOf(fn.file, off);
    size_t lexical;
    foreach (tok; identTokens(fn.file))
        if (tok.off > fn.nameOff && tok.off < fn.endOff && tok.ident == gname)
            lexical++;
    if (lexical != refs.length)
        return "unexplained refs to " ~ gname ~ " (" ~ lexical.to!string ~ " tokens vs " ~ refs.length.to!string ~ ")";
    foreach (ref c; calls)
    {
        if (c.callee != f)
            continue;
        if (c.caller == size_t.max)
            return "call outside function " ~ lineOf(c.file, c.off);
        const id = callIdent(c);
        if (id == uint.max || t.length == 0 || text(c.file)[id .. id + fn.name.length] != fn.name)
            return "odd call site " ~ lineOf(c.file, c.off);
        if (!existingParam(c.caller, g).length && c.caller != f)
            if (auto bad = cannotTouchGlobal(c.immediate))
                return bad ~ " caller " ~ lineOf(c.file, c.off);
        uint recv;
        if (qualifier(c.file, id, fd, recv) == Qual.bad)
            return "complex qualifier " ~ lineOf(c.file, c.off);
    }
    if (auto u = unexplainedUse(f))
        return "unexplained use " ~ u;
    return null;
}

__gshared string[] editableCache;

string[] editableFiles()
{
    if (!editableCache.length)
        editableCache = dmdSources().filter!(f => isEditableFile(f)).array;
    return editableCache;
}

string callerArg(size_t caller, size_t g)
{
    auto p = existingParam(caller, g);
    return p.length ? p : globals[g].name;
}

void planEdits(size_t g, size_t f, string pname)
{
    auto fn = &funcs[f];
    auto t = text(fn.file);
    auto pn = existingParam(f, g);
    uint[2][] deleted;
    if (!pn.length)
    {
        pn = pname;
        const open = paramListOpen(f);
        const next = skipWs(t, open + 1);
        const decl = "ref " ~ globals[g].type ~ " " ~ pn;
        edits[fn.file] ~= Edit(open + 1, 0, t[next] == ')' ? decl : decl ~ ", ");
        if (pn != globals[g].name)
            deleted = patternLines(f, g, pn);
        foreach (d; deleted)
            edits[fn.file] ~= Edit(d[0], d[1] - d[0], "");
    }
    if (pn != globals[g].name)
        foreach (off; globalRefOffsets(f, g))
            if (!deleted.any!(d => off >= d[0] && off < d[1]))
                edits[fn.file] ~= Edit(off, cast(uint) globals[g].name.length, pn);
    foreach (ref c; calls)
    {
        if (c.callee != f)
            continue;
        const arg = c.caller == f ? pn : callerArg(c.caller, g);
        auto ct = text(c.file);
        const next = skipWs(ct, c.off + 1);
        uint recv;
        if (qualifier(c.file, callIdent(c), fn.fd, recv) == Qual.ufcs)
        {
            const id = callIdent(c);
            const recvName = allTokens(c.file)[tokIndex(c.file, recv)].ident;
            edits[c.file] ~= Edit(recv, id - recv, "");
            edits[c.file] ~= Edit(c.off + 1, 0, arg ~ ", " ~ recvName ~ (ct[next] == ')' ? "" : ", "));
        }
        else
            edits[c.file] ~= Edit(c.off + 1, 0, ct[next] == ')' ? arg : arg ~ ", ");
    }
    foreach (file; editableFiles())
        foreach (tok; identTokens(file))
            if (tok.ident == fn.name && isDead(file, tok.off))
            {
                const open = deadCallOpen(file, tok);
                if (open == uint.max)
                    continue;
                const arg = open > fn.nameOff && open < fn.endOff && file == fn.file ? pn : enclosingArg(file, open, g);
                auto ct = text(file);
                const next = skipWs(ct, open + 1);
                edits[file] ~= Edit(open + 1, 0, ct[next] == ')' ? arg : arg ~ ", ");
            }
}

void applyEdits()
{
    foreach (file, list; edits)
    {
        auto t = text(file);
        auto sorted = list.sort!((a, b) => a.off > b.off).uniq!((a, b) => a.off == b.off && a.len == b.len).array;
        foreach (e; sorted)
            t = t[0 .. e.off] ~ e.repl ~ t[e.off + e.len .. $];
        std.file.write(file, t);
    }
}

int main(string[] args)
{
    string gname, pname, skipList, onlyList;
    size_t max = 10;
    bool dry;
    getopt(args, "global", &gname, "param", &pname, "max", &max, "skip", &skipList, "only", &onlyList, "dry", &dry);
    srcRoot = buildNormalizedPath(absolutePath(dirName(__FILE_FULL_PATH__) ~ "/../../src"));
    if (args.length < 2)
    {
        fprintf(stderr, "usage: deglobal report|step [--global=NAME] [--param=NAME] [--max=N] [--skip=a,b] [--dry]\n");
        return 1;
    }
    analyze();
    if (args[1] == "report")
    {
        report(gname);
        return 0;
    }
    if (args[1] != "step" || !gname.length)
    {
        fprintf(stderr, "step needs --global\n");
        return 1;
    }
    auto gs = globals.length.iota.filter!(i => globals[i].name == gname).array;
    if (gs.length != 1)
    {
        fprintf(stderr, "global %.*s not found or ambiguous\n", cast(int) gname.length, gname.ptr);
        return 1;
    }
    const g = gs[0];
    const pn = paramName(g, pname);
    auto skip = skipList.split(",");
    auto only = onlyList.split(",");
    auto reach = reachSet(g);
    size_t[] chosen;
    auto users = globals[g].users.dup;
    users.sort!((a, b) => funcs[a].callers.length < funcs[b].callers.length);
    foreach (u; users)
    {
        if (chosen.length >= max)
            break;
        if (skip.canFind(funcs[u].name) || only.length && !only.canFind(funcs[u].name) || !isLeaf(g, u, reach))
            continue;
        if (candidateProblem(g, u, pn).length)
            continue;
        chosen ~= u;
    }
    foreach (u; chosen)
        planEdits(g, u, pn);
    foreach (u; chosen)
        printf("%s %s\n", funcs[u].name.toStringz, rel(funcs[u].file).toStringz);
    if (!dry)
        applyEdits();
    return 0;
}
