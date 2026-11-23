/**
 * Scope view for the explorer: records every `Scope` dmd pushes while analysing
 * the input module (via `dmd.dscope.scopeTraceHook`), then renders them as a tree
 * showing what caused each scope, which attributes it changes relative to the
 * scope it was derived from, the symbols it declares, their visibility, and
 * which outer declarations they shadow.
 */
module dmdwasm_scopes;

import core.stdc.stdio : snprintf;

import dmd.aggregate : AggregateDeclaration;
import dmd.attrib;
import dmd.arraytypes : Dsymbols;
import dmd.common.outbuffer : OutBuffer;
import dmd.declaration : VarDeclaration;
import dmd.dmodule : Module;
import dmd.dscope : Scope, Contract, scopeTraceHook;
import dmd.dsymbol;
import dmd.func : FuncDeclaration;
import dmd.dtemplate : TemplateDeclaration, TemplateInstance;

import dmd.hdrgen : stcToBuffer, linkageToString, visibilityToString;
import dmd.location : Loc;
import dmd.astenums : STC, LINK, CPPMANGLE;

/// Pass name recorded on scopes pushed from now on (set by the driver).
__gshared const(char)[] currentPass;

private:

/// Attribute state of a scope that the view compares between parent and child.
struct Attrs
{
    ScopeDsymbol scopesym;
    FuncDeclaration func;
    Dsymbol parent;
    TemplateInstance tinst;
    STC stc;
    LINK linkage = LINK.d;
    CPPMANGLE cppmangle;
    Visibility visibility;
    bool explicitVisibility;
    AlignDeclaration aligndecl;
    PragmaDeclaration inlining;
    DeprecatedDeclaration depdecl;
    UserAttributeDeclaration uda;
    CPPNamespaceDeclaration namespace;
    Dsymbol inunion;
    Contract contract;
    bool debug_, ctfe, condition, inTemplateConstraint, traitsCompiles, inLoop, inDefaultArg, noAccessCheck;
    ubyte intypeof;
}

Attrs capture(Scope* sc)
{
    Attrs a;
    if (!sc)
        return a;
    a.scopesym = sc.scopesym;
    a.func = sc.func;
    a.parent = sc.parent;
    a.tinst = sc.tinst;
    a.stc = sc.stc;
    a.linkage = sc.linkage;
    a.cppmangle = sc.cppmangle;
    a.visibility = sc.visibility;
    a.explicitVisibility = sc.explicitVisibility;
    a.aligndecl = sc.aligndecl;
    a.inlining = sc.inlining;
    a.depdecl = sc.depdecl;
    a.uda = sc.userAttribDecl;
    a.namespace = sc.namespace;
    a.inunion = sc.inunion;
    a.contract = sc.contract;
    a.debug_ = sc.debug_;
    a.ctfe = sc.ctfe;
    a.condition = sc.condition;
    a.inTemplateConstraint = sc.inTemplateConstraint;
    a.traitsCompiles = sc.traitsCompiles;
    a.inLoop = sc.inLoop;
    a.inDefaultArg = sc.inDefaultArg;
    a.noAccessCheck = sc.noAccessCheck;
    a.intypeof = sc.intypeof;
    return a;
}

final class Node
{
    Node parent;
    Dsymbol cause;
    Attrs before, after;
    uint seq;
    const(char)[] pass;
}

__gshared Module target;
__gshared Node[Scope*] live;
__gshared Node[] all;
__gshared uint seqCounter;

Node findLive(Scope* sc)
{
    for (; sc; sc = sc.enclosing)
        if (auto p = sc in live)
            return *p;
    return null;
}

void hook(Scope* sc, Scope* from, Dsymbol cause, bool popped)
{
    if (popped)
    {
        if (auto p = sc in live)
        {
            (*p).after = capture(sc);
            if (!sc.nofree)
                live.remove(sc);
        }
        return;
    }
    if (auto p = sc in live)
    {
        if (cause)
            (*p).cause = cause;
        return;
    }
    if (sc._module !is target)
        return;
    auto n = new Node();
    n.cause = cause;
    n.seq = seqCounter++;
    n.pass = currentPass;
    n.before = capture(from);
    n.after = capture(cast(Scope*) sc);
    n.parent = from ? (from in live ? live[from] : findLive(from.enclosing)) : null;
    live[sc] = n;
    all ~= n;
}

public void beginScopeTrace(Module m)
{
    target = m;
    live = null;
    all = null;
    seqCounter = 0;
    currentPass = "importAll";
    scopeTraceHook = &hook;
}

public void endScopeTrace(ref OutBuffer buf)
{
    scopeTraceHook = null;
    foreach (sc, n; live)
        n.after = capture(cast(Scope*) sc);
    live = null;
    render(buf);
    all = null;
    target = null;
}

// ---------------------------------------------------------------------------
// Rendering

/// Display tree node: one or more recorded scopes with the same description.
final class View
{
    string key;
    string title;
    uint line;
    string[] changes;
    ScopeDsymbol[] syms;
    Attrs after;
    View[] kids;
    uint count = 1;
    uint seq;
    string[] passes;
    bool newSymtab;
}

string str(const(char)* p)
{
    import core.stdc.string : strlen;
    return p ? cast(string) p[0 .. strlen(p)].idup : "";
}

string stcText(STC stc)
{
    OutBuffer b;
    stcToBuffer(b, stc);
    return b[].idup;
}

string symName(Dsymbol s)
{
    if (!s)
        return "?";
    if (s.ident)
        return s.ident.toString().idup;
    return str(s.toChars());
}

uint lineOf(Dsymbol s) => s && s.loc.isValid && inInput(s.loc) ? s.loc.linnum : 0;

bool inInput(Loc loc)
{
    import core.stdc.string : strcmp;
    auto f = loc.filename();
    return !f || strcmp(f, target.srcfile.toChars()) == 0;
}

bool fromElsewhere(Dsymbol s)
{
    if (s.loc.isValid && !inInput(s.loc))
        return true;
    if (auto tm = s.isTemplateMixin())
        if (tm.tempdecl && tm.tempdecl.loc.isValid && !inInput(tm.tempdecl.loc))
            return true;
    return false;
}

/// Short description of the declaration that caused an attribute-only scope.
string attribTitle(Dsymbol d, ref uint line)
{
    line = lineOf(d);
    switch (d.dsym)
    {
        case DSYM.storageClassDeclaration:
            return "`" ~ stcText(d.isStorageClassDeclaration().stc) ~ "` attribute";
        case DSYM.linkDeclaration:
            return "`extern(" ~ linkageToString((cast(LinkDeclaration) d).linkage) ~ ")` attribute";
        case DSYM.cppMangleDeclaration:
            return "`extern(C++, class/struct)` attribute";
        case DSYM.visibilityDeclaration:
            return "`" ~ visText(d.isVisibilityDeclaration().visibility) ~ "` attribute";
        case DSYM.alignDeclaration:
            return "`align` attribute";
        case DSYM.pragmaDeclaration:
            return "`pragma(inline)` attribute";
        case DSYM.userAttributeDeclaration:
            return "`@(...)` user-defined attribute";
        case DSYM.cppNamespaceDeclaration:
            return "`extern(C++, namespace)` attribute";
        case DSYM.forwardingAttribDeclaration:
            return "`static foreach` declaration body";
        default:
            return str(d.kind());
    }
}

string symTitle(ScopeDsymbol s, ref Attrs a, ref Attrs b, ref uint line)
{
    line = lineOf(s);
    if (auto m = s.isModule())
        return "module `" ~ str(m.toPrettyChars()) ~ "`";
    if (s.isTemplateMixin())
        return "mixin `" ~ str(s.toChars()) ~ "`";
    if (auto ti = s.isTemplateInstance())
        return "template instance `" ~ str(ti.toChars()) ~ "`";
    if (s.isWithScopeSymbol())
        return "`with` statement";
    if (s.isArrayScopeSymbol())
        return "`$` scope";
    if (s.isForwardingScopeDsymbol())
        return "`static foreach` body";
    if (s.isAggregateDeclaration() || s.isEnumDeclaration() || s.isTemplateDeclaration() || s.isNspace())
        return str(s.kind()) ~ " `" ~ symName(s) ~ "`";
    if (!s.ident)
    {
        if (b.func && b.func !is a.func && b.scopesym is s)
        {
            line = lineOf(b.func);
            return "function `" ~ symName(b.func) ~ "` parameters & body";
        }
        if (b.tinst && b.tinst.argsym is s)
        {
            line = lineOf(b.tinst);
            return "template arguments of `" ~ str(b.tinst.toChars()) ~ "`";
        }
        auto td = templateOfParams(s);
        if (td || allTemplateParams(s))
        {
            line = lineOf(td);
            const what = td ? "`" ~ symName(td) ~ "`" : b.tinst ? "`" ~ symName(b.tinst.tempdecl) ~ "`" : "a template";
            bool bound;
            foreach (kv; s.symtab.tab.asRange)
                bound |= kv.value && !kv.value.loc.isValid;
            if (b.tinst && b.tinst !is a.tinst && !bound)
                return "template parameters of " ~ what ~ " while matching `" ~ str(b.tinst.toChars()) ~ "`";
            if (bound)
                return "template arguments" ~ (b.tinst ? " of `" ~ str(b.tinst.toChars()) ~ "`" : "")
                    ~ "";
            return "template parameters of " ~ what;
        }
        if (b.tinst && b.tinst !is a.tinst)
        {
            line = lineOf(b.tinst);
            return "template parameters while matching `" ~ str(b.tinst.toChars()) ~ "`";
        }
        if (!s.endloc.isValid && (!s.symtab || !s.symtab.length))
            return "internal scope";
        if (!line && s.symtab)
            foreach (kv; s.symtab.tab.asRange)
                if (kv.value && kv.value.loc.isValid && (!line || kv.value.loc.linnum < line))
                    line = kv.value.loc.linnum;
        if (s.endloc.isValid)
        {
            char[32] tmp;
            const n = snprintf(tmp.ptr, tmp.length, "%u", s.endloc.linnum);
            return "block scope (to line " ~ tmp[0 .. n].idup ~ ")";
        }
        return "block scope";
    }
    return str(s.kind()) ~ " `" ~ symName(s) ~ "`";
}

string visText(Visibility v)
{
    string s = visibilityToString(v.kind);
    if (v.kind == Visibility.Kind.package_ && v.pkg)
        s ~= "(" ~ str(v.pkg.toPrettyChars()) ~ ")";
    return s;
}

/// Attribute changes `b` makes relative to `a`.
string[] diff(ref Attrs a, ref Attrs b)
{
    string[] r;
    const added = b.stc & ~a.stc, removed = a.stc & ~b.stc;
    if (added)
        r ~= "+" ~ stcText(added);
    if (removed)
        r ~= "-" ~ stcText(removed);
    if (a.linkage != b.linkage)
        r ~= "extern(" ~ linkageToString(a.linkage) ~ ") -> extern(" ~ linkageToString(b.linkage) ~ ")";
    if (a.cppmangle != b.cppmangle)
        r ~= "cppmangle";
    if (a.visibility.kind != b.visibility.kind || a.visibility.pkg !is b.visibility.pkg)
        r ~= visText(cast() a.visibility) ~ " -> " ~ visText(cast() b.visibility);
    if (a.aligndecl !is b.aligndecl)
        r ~= b.aligndecl ? "align" : "align default";
    if (a.inlining !is b.inlining)
        r ~= b.inlining ? "pragma(inline)" : "pragma(inline) off";
    if (a.depdecl !is b.depdecl && b.depdecl)
        r ~= "deprecated";
    if (a.uda !is b.uda && b.uda)
        r ~= "UDAs";
    if (a.namespace !is b.namespace && b.namespace)
        r ~= "extern(C++, namespace)";
    if (a.func !is b.func)
        r ~= b.func ? "func `" ~ symName(cast() b.func) ~ "`" : "func null";
    if (a.inunion !is b.inunion)
        r ~= b.inunion ? "inunion" : "inunion off";
    if (a.contract != b.contract)
        r ~= b.contract == Contract.require ? "contract in" : b.contract == Contract.ensure ? "contract out" :
             b.contract == Contract.invariant_ ? "contract invariant" : "contract none";
    if (b.debug_ && !a.debug_)
        r ~= "debug";
    if (b.ctfe && !a.ctfe)
        r ~= "ctfe";
    if (b.condition && !a.condition && a.scopesym is b.scopesym)
        r ~= "condition";
    if (b.inTemplateConstraint && !a.inTemplateConstraint)
        r ~= "inTemplateConstraint";
    if (b.traitsCompiles && !a.traitsCompiles)
        r ~= "traitsCompiles";
    if (b.inLoop && !a.inLoop)
        r ~= "inLoop";
    if (b.inDefaultArg && !a.inDefaultArg)
        r ~= "inDefaultArg";
    if (b.noAccessCheck && !a.noAccessCheck)
        r ~= "noAccessCheck";
    if (b.intypeof && !a.intypeof)
        r ~= "intypeof";
    return r;
}

string num(uint n)
{
    char[16] tmp;
    const len = snprintf(tmp.ptr, tmp.length, "%u", n);
    return tmp[0 .. len].idup;
}

View makeView(Node n)
{
    auto v = new View();
    v.seq = n.seq;
    v.after = n.after;
    if (n.pass.length)
        v.passes ~= n.pass.idup;
    uint line;
    const newSym = n.after.scopesym && n.after.scopesym !is n.before.scopesym;
    if (n.cause)
        v.title = attribTitle(n.cause, line);
    else if (newSym)
        v.title = symTitle(n.after.scopesym, n.before, n.after, line);
    else
        v.title = "internal scope";
    v.line = line;
    v.newSymtab = newSym;
    if (newSym)
        v.syms ~= n.after.scopesym;
    Attrs a = n.before;
    Attrs b = n.after;
    if (newSym && n.after.func is n.before.func)
        a.func = b.func;
    v.changes = diff(a, b);
    if (newSym && b.func && b.func !is n.before.func && b.scopesym)
    {
        string[] r;
        foreach (c; v.changes)
            if (!startsWith(c, "func "))
                r ~= c;
        v.changes = r;
    }
    string key = v.title ~ "|" ~ num(v.line);
    foreach (c; v.changes)
        key ~= "|" ~ c;
    v.key = key;
    return v;
}

void mergeInto(View dst, View src)
{
    dst.count += src.count;
    foreach (p; src.passes)
    {
        bool have;
        foreach (q; dst.passes)
            have |= q == p;
        if (!have)
            dst.passes ~= p;
    }
    foreach (s; src.syms)
    {
        bool have;
        foreach (t; dst.syms)
            have |= t is s;
        if (!have)
            dst.syms ~= s;
    }
    foreach (k; src.kids)
        addKid(dst, k);
}

View addKid(View parent, View kid)
{
    foreach (k; parent.kids)
        if (k.key == kid.key)
        {
            mergeInto(k, kid);
            return k;
        }
    parent.kids ~= kid;
    return kid;
}

bool transparent(View v)
{
    if (v.title != "internal scope")
        return false;
    foreach (c; v.changes)
        if (c[0] != '+' && c[0] != '-' && c != "func null")
            return false;
    return true;
}

bool startsWith(string s, string p) => s.length >= p.length && s[0 .. p.length] == p;

void render(ref OutBuffer buf)
{
    paramLocs = null;
    collectTemplates(target.members);
    View[Node] views;
    bool[Node] excluded;
    auto root = new View();
    foreach (n; all)
    {
        if (n.parent && n.parent in excluded || !ownedByTarget(n))
        {
            excluded[n] = true;
            continue;
        }
        views[n] = makeView(n);
    }
    foreach (n; all)
    {
        if (n in excluded)
            continue;
        auto v = views[n];
        Node p = n.parent;
        while (p && transparent(views[p]))
            p = p.parent;
        if (transparent(v))
            continue;
        views[n] = addKid(p ? views[p] : root, v);
    }

    renderKids(buf, root, 0);
}

__gshared TemplateDeclaration[ulong] paramLocs;

ulong locKey(Loc loc) => (cast(ulong) loc.linnum << 32) | loc.charnum;

void collectTemplates(Dsymbols* members)
{
    if (!members)
        return;
    foreach (d; *members)
    {
        if (auto td = d.isTemplateDeclaration())
        {
            if (td.parameters)
                foreach (tp; *td.parameters)
                    paramLocs[locKey(tp.loc)] = td;
            collectTemplates(td.members);
        }
        else if (auto ad = d.isAttribDeclaration())
            collectTemplates(ad.decl);
        else if (auto sd = d.isScopeDsymbol())
            collectTemplates(sd.members);
    }
}

bool allTemplateParams(ScopeDsymbol s)
{
    if (!s.symtab || !s.symtab.length)
        return false;
    foreach (kv; s.symtab.tab.asRange)
    {
        auto d = kv.value ? (cast() kv.value).isDeclaration() : null;
        if (!d || !(d.storage_class & STC.templateparameter))
            return false;
    }
    return true;
}

TemplateDeclaration templateOfParams(ScopeDsymbol s)
{
    if (!s.symtab || !s.symtab.length)
        return null;
    TemplateDeclaration found;
    foreach (kv; s.symtab.tab.asRange)
    {
        auto p = kv.value ? locKey(kv.value.loc) in paramLocs : null;
        if (!p || found && *p !is found)
            return null;
        found = *p;
    }
    return found;
}

bool ownedByTarget(Node n)
{
    Dsymbol owner;
    if (n.after.scopesym && n.after.scopesym !is n.before.scopesym)
    {
        owner = n.after.scopesym;
        if (!owner.isModule() && !owner.ident && owner.parent)
            owner = owner.parent;
    }
    if (!owner)
        owner = n.after.parent;
    if (!owner)
        return true;
    if (fromElsewhere(owner))
        return false;
    if (owner.isScopeDsymbol() && !owner.isModule() && !owner.parent)
        return true;
    return owner.getModule() is target;
}

void sortKids(View v)
{
    import core.stdc.stdlib : qsort;
    static extern (C) int cmp(const void* x, const void* y)
    {
        auto a = *cast(View*) x, b = *cast(View*) y;
        if (a.line != b.line)
            return a.line < b.line ? -1 : 1;
        return a.seq < b.seq ? -1 : a.seq > b.seq;
    }
    if (v.kids.length > 1)
        qsort(v.kids.ptr, v.kids.length, View.sizeof, &cmp);
}

void indent(ref OutBuffer buf, int depth)
{
    foreach (i; 0 .. depth)
        buf.writestring("  ");
}

void endLine(ref OutBuffer buf, uint line)
{
    if (line)
        buf.printf("\x01%u", line);
    buf.writeByte('\n');
}

/// Scopes with symbol tables enclosing the one being rendered, innermost last,
/// paired with the function each belongs to (for the shadowing rules).
struct Outer
{
    ScopeDsymbol sym;
    FuncDeclaration func;
    string title;
}

__gshared Outer[] outerStack;

void renderKids(ref OutBuffer buf, View v, int depth)
{
    sortKids(v);
    foreach (k; v.kids)
        renderView(buf, k, depth);
}

void renderView(ref OutBuffer buf, View v, int depth)
{
    indent(buf, depth);
    buf.writestring("▸ ");
    buf.writestring(v.title);
    if (v.count > 1)
        buf.printf("  ×%u", v.count);
    if (v.passes.length)
    {
        buf.writestring("  [");
        foreach (i, p; v.passes)
        {
            if (i)
                buf.writestring(", ");
            buf.writestring(p);
        }
        buf.writestring("]");
    }
    endLine(buf, v.line);
    foreach (c; v.changes)
    {
        indent(buf, depth + 2);
        buf.writestring("~ ");
        buf.writestring(c);
        endLine(buf, v.line);
    }
    size_t pushed;
    if (v.newSymtab)
    {
        renderSymbols(buf, v, depth + 2);
        foreach (s; v.syms)
        {
            outerStack ~= Outer(s, cast() v.after.func, v.title);
            pushed++;
        }
    }
    renderKids(buf, v, depth + 1);
    outerStack = outerStack[0 .. $ - pushed];
}

struct Entry
{
    Dsymbol s;
    ScopeDsymbol owner;
}

void renderSymbols(ref OutBuffer buf, View v, int depth)
{
    import core.stdc.stdlib : qsort;
    Entry[] list;
    foreach (sym; v.syms)
    {
        if (!sym.symtab)
            continue;
        foreach (kv; sym.symtab.tab.asRange)
        {
            Dsymbol s = cast() kv.value;
            if (!s || fromElsewhere(s))
                continue;
            bool dup;
            foreach (e; list)
                dup |= e.s.ident is s.ident && e.s.loc.linnum == s.loc.linnum;
            if (!dup)
                list ~= Entry(s, sym);
        }
    }
    static extern (C) int cmp(const void* x, const void* y)
    {
        auto a = cast(Entry*) x, b = cast(Entry*) y;
        const la = a.s.loc.linnum, lb = b.s.loc.linnum;
        if (la != lb)
            return la < lb ? -1 : 1;
        import core.stdc.string : strcmp;
        return strcmp(a.s.ident.toChars(), b.s.ident.toChars());
    }
    if (list.length > 1)
        qsort(list.ptr, list.length, Entry.sizeof, &cmp);

    const isModule = v.syms.length && v.syms[0].isModule();
    const isAggregate = v.syms.length && v.syms[0].isAggregateDeclaration();
    if (list.length)
    {
        indent(buf, depth);
        buf.writestring("declares:");
        endLine(buf, v.line);
    }
    foreach (e; list)
    {
        Dsymbol s = e.s;
        indent(buf, depth + 1);
        const name = symName(s);
        buf.writestring(name);
        foreach (i; name.length .. 14)
            buf.writeByte(' ');
        buf.writeByte(' ');
        buf.writestring(str(s.kind()));
        if (isModule || isAggregate)
        {
            buf.writeByte(' ');
            buf.writestring(visText(s.visible()));
        }
        auto sh = shadowExplanation(s, v);
        if (sh.length)
        {
            buf.writestring(" — ");
            buf.writestring(sh);
        }
        endLine(buf, lineOf(s));
    }
    if (isModule)
        renderImports(buf, v, depth);
}

/// Explain which declaration in an enclosing scope `s` hides, and whether
/// that's allowed.
string shadowExplanation(Dsymbol s, View v)
{
    if (!s.ident)
        return null;
    auto myFunc = v.after.func;
    foreach_reverse (o; outerStack)
    {
        if (!o.sym.symtab)
            continue;
        auto t = o.sym.symtab.lookup(s.ident);
        if (!t || t is s)
            continue;
        if (auto ti = v.syms.length ? v.syms[0].isTemplateInstance() : null)
            if (ti.tempdecl is t)
                return "eponymous member";
        const where = str(t.kind()) ~ " `" ~ symName(t) ~ "`" ~ (lineOf(t) ? " (line " ~ num(lineOf(t)) ~ ")" : "");
        if (myFunc && o.func is myFunc && s.isVarDeclaration() && t.isVarDeclaration())
            return "shadows " ~ where ~ ": error";
        if (o.sym.isModule())
            return "shadows " ~ where ~ ", use `." ~ symName(s) ~ "`";
        if (o.sym.isAggregateDeclaration())
            return "shadows " ~ where ~ ", use `this." ~ symName(s) ~ "`";
        return "shadows " ~ where;
    }
    if (s.isImport() || s.isPackage())
        return null;
    if (auto m = v.syms.length ? v.syms[0].isModule() : null)
    {
        if (m.importedScopes)
            foreach (imp; *m.importedScopes)
            {
                auto sd = imp.isScopeDsymbol();
                if (!sd || !sd.symtab || sd.isTemplateMixin() && fromElsewhere(sd))
                    continue;
                if (auto t = sd.symtab.lookup(s.ident))
                {
                    if (t.visible().kind == Visibility.Kind.private_)
                        continue;
                    return "hides `" ~ str(t.toPrettyChars()) ~ "`";
                }
            }
    }
    return null;
}

void renderImports(ref OutBuffer buf, View v, int depth)
{
    auto m = v.syms[0];
    if (!m.importedScopes || !m.importedScopes.length)
        return;
    indent(buf, depth);
    buf.writestring("imports:");
    endLine(buf, v.line);
    foreach (i, imp; *m.importedScopes)
    {
        if (imp.isTemplateMixin() && fromElsewhere(imp))
            continue;
        indent(buf, depth + 1);
        buf.writestring(str(imp.toPrettyChars()));
        const vk = m.visibilities ? m.visibilities[i] : Visibility.Kind.private_;
        buf.writeByte(' ');
        buf.writestring(visibilityToString(vk));
        endLine(buf, 0);
    }
}
