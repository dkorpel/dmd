module narrow;

import core.stdc.stdio;

import std.algorithm;
import std.array;
import std.conv : to;
import std.file : exists;
import std.range : iota, take;
import std.string;

import deglobal;

import dmd.astenums;
import dmd.declaration;
import dmd.dstruct;
import dmd.dsymbol;
import dmd.dsymbolsem : search;
import dmd.expression;
import dmd.func;
import dmd.funcsem : isVirtual;
import dmd.location;
import dmd.mtype;
import dmd.tokens;
import dmd.typesem : toBasetype, isScalar;

struct Fwd
{
    size_t callee;
    int index;
    string prefix;
    uint rootOff;
    bool mutable;
}

struct PUse
{
    size_t func;
    int index;
    string name;
    uint nameOff;
    StructDeclaration sd;
    bool byRef;
    bool byPtr;
    bool[string] reads;
    bool[string] writes;
    Fwd[] fwds;
    uint[] roots;
    string wholeAt;
    bool[string] sumReads;
    bool[string] sumWrites;
}

__gshared PUse[] puses;
__gshared size_t[void*] puseOfVar;
__gshared size_t[string] puseOfKey;
__gshared bool[void*] claimed;
__gshared bool[size_t][string] writers;
__gshared bool[string] escaped;
__gshared bool[string][size_t] indirectCallers;

enum maxDepth = 3;

string pkey(size_t f, int index)
{
    return f.to!string ~ ":" ~ index.to!string;
}

string fkey(StructDeclaration sd, string field)
{
    return sd.toPrettyChars().fromStringz.idup ~ "." ~ field;
}

StructDeclaration structOf(Type t, out bool ptr)
{
    if (!t)
        return null;
    t = t.toBasetype();
    if (auto tp = t.isTypePointer())
    {
        ptr = true;
        t = tp.next.toBasetype();
    }
    if (auto ts = t.isTypeStruct())
        return ts.sym;
    return null;
}

void registerParams(FuncDeclaration fd)
{
    if (!fd.fbody)
        return;
    const f = addFunc(fd);
    if (fd.parameters)
        foreach (i, p; *fd.parameters)
            track(f, cast(int) i, p, (p.storage_class & (STC.ref_ | STC.out_)) != 0);
    if (fd.vthis)
        if (auto ad = fd.isThis())
            if (ad.isStructDeclaration())
                track(f, -1, fd.vthis, true);
}

void track(size_t f, int index, VarDeclaration v, bool byRef)
{
    if (cast(void*) v in puseOfVar)
        return;
    bool ptr;
    auto sd = structOf(v.type, ptr);
    if (!sd || ptr && byRef)
        return;
    PUse u;
    u.func = f;
    u.index = index;
    u.name = v.ident ? v.ident.toString.idup : "";
    u.nameOff = v.loc.off;
    u.sd = sd;
    u.byRef = byRef;
    u.byPtr = ptr;
    puses ~= u;
    puseOfVar[cast(void*) v] = puses.length - 1;
    puseOfKey[pkey(f, index)] = puses.length - 1;
}

struct Chain
{
    size_t pu = size_t.max;
    string path;
    uint rootOff = uint.max;
    Expression[] nodes;
    VarDeclaration[] fields;
    StructDeclaration rootStruct;
}

Chain chainOf(Expression e)
{
    Chain c;
    string[] parts;
    while (auto d = e.isDotVarExp())
    {
        auto v = d.var.isVarDeclaration();
        if (!v || !v.isField())
            return Chain.init;
        parts = v.ident.toString.idup ~ parts;
        c.nodes ~= e;
        c.fields ~= v;
        e = d.e1;
    }
    c.path = parts.join(".");
    bool ptr;
    c.rootStruct = structOf(e.type, ptr);
    if (ptr)
        c.rootStruct = null;
    if (auto pe = e.isPtrExp())
    {
        c.nodes ~= e;
        e = pe.e1;
    }
    VarDeclaration root;
    if (auto ve = e.isVarExp())
    {
        root = ve.var.isVarDeclaration();
        c.rootOff = ve.loc.off;
    }
    else if (auto te = e.isThisExp())
        root = te.var;
    else
        return c;
    c.nodes ~= e;
    if (root)
        if (auto p = cast(void*) root in puseOfVar)
            c.pu = *p;
    return c;
}

void claim(Expression e)
{
    claimed[cast(void*) e] = true;
}

bool isClaimed(Expression e)
{
    return (cast(void*) e) in claimed ? true : false;
}

void recordPath(ref Chain c, bool write, uint off = uint.max)
{
    auto u = &puses[c.pu];
    if (!c.path.length && !u.wholeAt.length)
        u.wholeAt = lineOf(funcs[u.func].file, off != uint.max ? off : c.rootOff != uint.max ? c.rootOff : funcs[u.func].nameOff);
    u.reads[c.path] = true;
    if (write)
        u.writes[c.path] = true;
    if (c.rootOff != uint.max)
        u.roots ~= c.rootOff;
    foreach (n; c.nodes)
        claim(n);
}

void noteWriter(ref Chain c, size_t cur, bool escape)
{
    if (cur == size_t.max)
        return;
    void mark(string k)
    {
        writers[k][cur] = true;
        if (escape)
            escaped[k] = true;
    }
    foreach (v; c.fields)
        if (auto sd = v.toParent().isStructDeclaration())
            mark(fkey(sd, v.ident.toString.idup));
    if (!c.fields.length && c.rootStruct)
        mark(fkey(c.rootStruct, "*"));
}

Expression stripToStorage(Expression e)
{
    while (true)
    {
        if (auto ie = e.isIndexExp())
        {
            if (!ie.e1.type || !ie.e1.type.toBasetype().isTypeSArray())
                return null;
            e = ie.e1;
        }
        else if (auto se = e.isSliceExp())
        {
            if (!se.e1.type || !se.e1.type.toBasetype().isTypeSArray())
                return null;
            e = se.e1;
        }
        else if (auto ae = e.isArrayLengthExp())
            e = ae.e1;
        else
            return e;
    }
}

void onWrite(Expression lhs, size_t cur, bool escape)
{
    auto e = stripToStorage(lhs);
    if (!e)
        return;
    auto c = chainOf(e);
    noteWriter(c, cur, escape);
    if (c.pu != size_t.max)
        recordPath(c, true);
}

void onAssign(AssignExp e, size_t cur)
{
    onWrite(e.e1, cur, false);
    if (e.isConstructExp())
        if (auto ve = e.e1.isVarExp())
            if (auto v = ve.var.isVarDeclaration())
                if (v.storage_class & STC.ref_)
                    onWrite(e.e2, cur, true);
}

void onAddr(AddrExp e, size_t cur)
{
    if (!isClaimed(e))
        onWrite(e.e1, cur, true);
}

void onSlice(SliceExp e, size_t cur)
{
    if (!isClaimed(e) && e.e1.type && e.e1.type.toBasetype().isTypeSArray())
        onWrite(e.e1, cur, true);
}

void onCall(CallExp e, size_t cur)
{
    auto fd = e.f;
    if (cur != size_t.max)
    {
        if (!fd)
        {
            auto t = e.e1.type ? e.e1.type.toBasetype() : null;
            if (t && t.isTypePointer())
                t = t.isTypePointer().next;
            else if (t && t.isTypeDelegate())
                t = t.isTypeDelegate().next;
            auto tf = t ? t.isTypeFunction() : null;
            if (e.e1.type)
                indirectCallers[cur][tf ? sigOf(tf) : "?"] = true;
        }
        else if (fd.isVirtual() && !fd.isFinalFunc())
            indirectCallers[cur]["virtual " ~ funcs[addFunc(fd)].name] = true;
    }
    if (!fd)
        return;
    const callee = addFunc(fd);
    if (auto dve = e.e1.isDotVarExp())
        if (dve.var.isFuncDeclaration() && fd.isThis() && fd.isThis().isStructDeclaration())
        {
            auto c = chainOf(dve.e1);
            if (c.pu != size_t.max)
            {
                puses[c.pu].fwds ~= Fwd(callee, -1, c.path, c.rootOff, true);
                foreach (n; c.nodes)
                    claim(n);
                claim(dve);
            }
            else if (!fd.fbody)
                noteWriter(c, cur, false);
        }
    auto tf = fd.type ? fd.type.isTypeFunction() : null;
    if (!tf || !e.arguments)
        return;
    foreach (i, arg; *e.arguments)
    {
        if (!arg || i >= tf.parameterList.length)
            break;
        auto p = tf.parameterList[i];
        const isRef = (p.storageClass & (STC.ref_ | STC.out_)) != 0;
        bool pptr, aptr;
        auto psd = structOf(p.type, pptr);
        auto asd = structOf(arg.type, aptr);
        if (auto so = arg.isSymOffExp())
        {
            if (psd && pptr && fd.fbody)
                claim(so);
            continue;
        }
        Expression a = arg;
        auto addr = arg.isAddrExp();
        if (addr)
            a = addr.e1;
        auto c = chainOf(a);
        if (psd && psd is asd && pptr == aptr)
        {
            if (c.pu != size_t.max)
            {
                puses[c.pu].fwds ~= Fwd(callee, cast(int) i, c.path, c.rootOff, isRef || pptr);
                foreach (n; c.nodes)
                    claim(n);
            }
            if (addr)
                claim(addr);
            if (!fd.fbody && (isRef || pptr))
                noteWriter(c, cur, false);
        }
        else if (isRef || addr)
        {
            if (addr)
                claim(addr);
            onWrite(a, cur, addr !is null);
        }
    }
}

void onDotVar(DotVarExp e)
{
    if (isClaimed(e))
        return;
    if (!e.var.isVarDeclaration())
    {
        auto c = chainOf(e.e1);
        if (c.pu != size_t.max)
        {
            c.path = "";
            recordPath(c, true, e.loc.off);
        }
        return;
    }
    auto c = chainOf(e);
    if (c.pu != size_t.max)
        recordPath(c, false);
}

void onRoot(Expression e, VarDeclaration v)
{
    if (isClaimed(e) || !v)
        return;
    if (auto p = cast(void*) v in puseOfVar)
    {
        auto u = &puses[*p];
        u.reads[""] = true;
        u.writes[""] = true;
        if (!u.wholeAt.length)
            u.wholeAt = lineOf(funcs[u.func].file, e.loc.off);
        if (auto ve = e.isVarExp())
            u.roots ~= ve.loc.off;
    }
}

void onSymOff(SymOffExp e, size_t cur)
{
    auto vd = e.var.isVarDeclaration();
    if (!vd || isClaimed(e))
        return;
    if (auto p = cast(void*) vd in puseOfVar)
    {
        puses[*p].reads[""] = true;
        puses[*p].writes[""] = true;
    }
    bool ptr;
    Chain c;
    c.rootStruct = structOf(vd.type, ptr);
    if (c.rootStruct && !ptr)
        noteWriter(c, cur, true);
}

/********************* Summaries *********************/

string joinPath(string a, string b)
{
    string r = !a.length ? b : !b.length ? a : a ~ "." ~ b;
    auto parts = r.split(".");
    return parts.length > maxDepth ? parts[0 .. maxDepth].join(".") : r;
}

void summarize()
{
    foreach (ref u; puses)
    {
        u.sumReads = u.reads.dup;
        u.sumWrites = u.writes.dup;
    }
    bool changed = true;
    while (changed)
    {
        changed = false;
        foreach (ref u; puses)
            foreach (ref fw; u.fwds)
            {
                bool add(ref bool[string] set, string k)
                {
                    if (k in set)
                        return false;
                    set[k] = true;
                    return true;
                }
                auto q = pkey(fw.callee, fw.index) in puseOfKey;
                if (!q)
                {
                    changed |= add(u.sumReads, fw.prefix);
                    if (fw.mutable)
                        changed |= add(u.sumWrites, fw.prefix);
                    continue;
                }
                auto cu = &puses[*q];
                foreach (k; cu.sumReads.keys)
                    changed |= add(u.sumReads, joinPath(fw.prefix, k));
                if (fw.mutable && (cu.byRef || cu.byPtr))
                    foreach (k; cu.sumWrites.keys)
                        changed |= add(u.sumWrites, joinPath(fw.prefix, k));
            }
    }
}

bool isPrefix(string p, string s)
{
    return p.length == 0 || s == p || s.startsWith(p ~ ".");
}

string[] normalized(ref PUse u)
{
    auto all = (u.sumReads.keys ~ u.sumWrites.keys).sort.uniq.array;
    return all.filter!(s => !all.any!(p => p != s && isPrefix(p, s))).array;
}

string[] topFields(string[] paths)
{
    return paths.map!(p => p.findSplitBefore(".")[0]).array.sort.uniq.array;
}

bool writtenUnder(ref PUse u, string path)
{
    return u.sumWrites.keys.any!(w => isPrefix(path, w) || isPrefix(w, path));
}

string commonPrefix(string[] paths)
{
    if (!paths.length)
        return null;
    auto r = paths[0].split(".");
    foreach (p; paths[1 .. $])
    {
        auto q = p.split(".");
        size_t k;
        while (k < r.length && k < q.length && r[k] == q[k])
            k++;
        r = r[0 .. k];
    }
    return r.join(".");
}

VarDeclaration fieldAt(StructDeclaration sd, string path)
{
    VarDeclaration v;
    foreach (part; path.split("."))
    {
        if (!sd)
            return null;
        v = null;
        foreach (f; sd.fields)
            if (f.ident && f.ident.toString == part)
                v = f;
        if (!v)
            return null;
        bool ptr;
        sd = structOf(v.type, ptr);
        if (ptr)
            sd = null;
    }
    return v;
}

/********************* Report *********************/

string wholeWhy(ref PUse u)
{
    if (u.wholeAt.length)
        return "used at " ~ u.wholeAt;
    foreach (ref fw; u.fwds)
    {
        if (fw.prefix.length)
            continue;
        auto q = pkey(fw.callee, fw.index) in puseOfKey;
        if (!q)
            return "passed to " ~ funcs[fw.callee].name ~ " (no body)";
        if ("" in puses[*q].sumReads)
            return "passed to " ~ funcs[fw.callee].name;
    }
    return "whole";
}

size_t fieldsUsed(ref PUse u)
{
    auto n = normalized(u);
    return n.canFind("") ? u.sd.fields.length : topFields(n).length;
}

string fieldUse(ref PUse u, string p)
{
    return p ~ (writtenUnder(u, p) ? "[w]" : "[r]");
}

void paramsReport(string type)
{

    size_t[][string] byType;
    foreach (i, ref u; puses)
        if (u.index >= 0 && funcs[u.func].editable && u.sd.fields.length > 1)
            byType[u.sd.ident.toString.idup] ~= i;
    auto types = byType.keys.sort!((a, b) => byType[a].length > byType[b].length).array;
    if (!type.length)
    {
        printf("%-20s %6s %6s %6s %6s %6s %6s\n", "struct".ptr, "fields".ptr, "params".ptr, "unused".ptr, "1".ptr, "2-3".ptr, "whole".ptr);
        foreach (t; types)
        {
            size_t unused, one, few, whole;
            foreach (i; byType[t])
            {
                auto n = normalized(puses[i]);
                if (!n.length)
                    unused++;
                else if (n.canFind(""))
                    whole++;
                else if (topFields(n).length == 1)
                    one++;
                else if (topFields(n).length <= 3)
                    few++;
            }
            printf("%-20s %6zu %6zu %6zu %6zu %6zu %6zu\n", t.toStringz, puses[byType[t][0]].sd.fields.length.to!size_t,
                byType[t].length, unused, one, few, whole);
        }
        return;
    }
    auto list = byType.get(type, null);
    if (!list.length)
    {
        printf("no parameters of type %s\n", type.toStringz);
        return;
    }
    size_t[string] fieldCount;
    size_t[string] setCount;
    foreach (i; list)
    {
        auto n = normalized(puses[i]);
        foreach (f; topFields(n))
            fieldCount[f.length ? f : "(whole)"]++;
        setCount[!n.length ? "(unused)" : n.canFind("") ? "(whole)" : topFields(n).join(" ")]++;
    }
    printf("%s: %zu fields, %zu parameters\n\nfield use (parameters needing the field):\n", type.toStringz, cast(size_t) puses[list[0]].sd.fields.length, list.length);
    foreach (f; fieldCount.keys.sort!((a, b) => fieldCount[a] > fieldCount[b]))
        printf("  %-20s %zu\n", f.toStringz, fieldCount[f]);
    printf("\nmost common field sets:\n");
    foreach (s; setCount.keys.sort!((a, b) => setCount[a] > setCount[b]).take(15))
        printf("  %4zu  %s\n", setCount[s], s.toStringz);
    printf("\nparameters (fewest fields first):\n");
    list.sort!((a, b) => fieldsUsed(puses[a]) < fieldsUsed(puses[b]));
    foreach (i; list)
    {
        auto u = &puses[i];
        auto n = normalized(*u);
        string what = !n.length ? "unused" : n.canFind("") ? "whole, " ~ wholeWhy(*u) : n.map!(p => fieldUse(*u, p)).join(" ");
        auto why = n.canFind("") ? "" : narrowProblem(i);
        auto cp = commonPrefix(n);
        if (cp.length && !writtenUnder(*u, cp))
            if (auto ap = aliasProblem(*u, cp))
                why ~= " (by ref: " ~ ap ~ ")";
        printf("  %-28s %-24s %-3zu %s%s%s\n", lineOf(funcs[u.func].file, funcs[u.func].nameOff).toStringz,
            (funcs[u.func].name ~ "(" ~ u.name ~ ")").toStringz, fieldsUsed(*u), what.toStringz,
            n.canFind("") ? "".ptr : why.length ? "  -- ".ptr : "  -- ok".ptr, why.toStringz);
    }
}

/********************* Rewrite *********************/

uint[2][] argSpans(string file, uint open)
{
    auto tks = allTokens(file);
    auto t = text(file);
    auto i = tokIndex(file, open);
    uint[2][] r;
    if (i == size_t.max)
        return r;
    int depth;
    size_t start = i + 1;
    for (size_t k = i + 1; k < tks.length; k++)
    {
        const v = tks[k].value;
        if (v == TOK.leftParenthesis || v == TOK.leftBracket || v == TOK.leftCurly)
            depth++;
        else if ((v == TOK.rightParenthesis || v == TOK.rightBracket || v == TOK.rightCurly) && depth > 0)
            depth--;
        else if (depth == 0 && (v == TOK.comma || v == TOK.rightParenthesis))
        {
            if (k > start)
                r ~= [tks[start].off, cast(uint)(skipWsBack(t, cast(int) tks[k].off - 1) + 1)];
            if (v == TOK.rightParenthesis)
                return r;
            start = k + 1;
        }
    }
    return null;
}

bool simpleChain(string a)
{
    if (!a.length || !(isIdentChar(a[0]) && !(a[0] >= '0' && a[0] <= '9')))
        return false;
    return a.representation.all!(ch => isIdentChar(ch) || ch == '.');
}

void narrowArg(string file, uint s, uint e, string path)
{
    auto t = text(file);
    auto a = t[s .. e];
    if (simpleChain(a))
        edits[file] ~= Edit(e, 0, "." ~ path);
    else if ((a[0] == '&' || a[0] == '*') && simpleChain(a[1 .. $].strip))
    {
        edits[file] ~= Edit(s, skipWs(t, s + 1) - s, "");
        edits[file] ~= Edit(e, 0, "." ~ path);
    }
    else
    {
        edits[file] ~= Edit(s, 0, "(");
        edits[file] ~= Edit(e, 0, ")." ~ path);
    }
}

void removeArg(string file, uint[2][] spans, size_t i)
{
    if (i + 1 < spans.length)
        edits[file] ~= Edit(spans[i][0], spans[i + 1][0] - spans[i][0], "");
    else if (i > 0)
        edits[file] ~= Edit(spans[i - 1][1], spans[i][1] - spans[i - 1][1], "");
    else
        edits[file] ~= Edit(spans[i][0], spans[i][1] - spans[i][0], "");
}

__gshared size_t[size_t] reachParent;

string sigOf(TypeFunction tf)
{
    string r = tf.next && tf.next.deco ? tf.next.deco.fromStringz.idup : "?";
    foreach (i; 0 .. tf.parameterList.length)
    {
        auto p = tf.parameterList[i];
        r ~= (p.storageClass & (STC.ref_ | STC.out_) ? " ref " : " ") ~ (p.type && p.type.deco ? p.type.deco.fromStringz.idup : "?");
    }
    return r;
}

bool mayCall(bool[string] sigs, ref Func o)
{
    if ("?" in sigs)
        return o.addressTaken;
    if (o.fd.isVirtual() && ("virtual " ~ o.name) in sigs)
        return true;
    if (!o.addressTaken)
        return false;
    auto tf = o.fd.type ? o.fd.type.isTypeFunction() : null;
    return tf && (sigOf(tf) in sigs) !is null;
}

bool[size_t] reachFrom(size_t f)
{
    bool[size_t] seen = [f: true];
    reachParent = null;
    size_t[] work = [f];
    while (work.length)
    {
        auto x = work[$ - 1];
        work = work[0 .. $ - 1];
        if (!funcs[x].editable)
            continue;
        if (auto sigs = x in indirectCallers)
        {
            foreach (i, ref o; funcs)
                if (i !in seen && mayCall(*sigs, o))
                {
                    seen[i] = true;
                    reachParent[i] = x;
                    work ~= i;
                }
        }
        foreach (c; funcs[x].calls)
            if (c !in seen)
            {
                seen[c] = true;
                reachParent[c] = x;
                work ~= c;
            }
    }
    return seen;
}

string aliasProblem(ref PUse u, string path)
{
    auto sd = u.sd;
    auto reach = reachFrom(u.func);
    foreach (part; path.split("."))
    {
        foreach (k; [fkey(sd, part), fkey(sd, "*")])
        {
            if (k in escaped)
                return k ~ " escapes";
            foreach (w, _; writers.get(k, null))
                if (w in reach)
                {
                    string via;
                    for (auto x = w; x in reachParent; x = reachParent[x])
                        via = " < " ~ funcs[reachParent[x]].name ~ (x in indirectCallers ? "*" : "") ~ via;
                    return k ~ " written by " ~ funcs[w].name ~ via;
                }
        }
        auto v = fieldAt(sd, part);
        bool ptr;
        sd = v ? structOf(v.type, ptr) : null;
        if (!sd || ptr)
            break;
    }
    return null;
}

bool cheapType(Type t)
{
    t = t.toBasetype();
    return t.isScalar() || t.isTypePointer() || t.isTypeClass() || t.isTypeDArray() || t.isTypeDelegate();
}

string typeText(VarDeclaration v, string file, bool apply, out string problem)
{
    Type t = v.originalType ? v.originalType : v.type;
    for (Type x = t; x;)
    {
        if (auto ti = x.isTypeIdentifier())
        {
            if (ti.idents.length)
            {
                problem = "qualified field type";
                return null;
            }
            auto ad = v.toParent().isStructDeclaration();
            Dsymbol s = ad ? search(ad, Loc.initial, ti.ident) : null;
            if (!s && v.getModule())
                s = search(v.getModule(), Loc.initial, ti.ident);
            if (!s)
            {
                problem = "can't resolve " ~ ti.ident.toString.idup;
                return null;
            }
            if (s.toParent() is ad)
            {
                problem = "field type nested in struct";
                return null;
            }
            if (apply)
                ensureVisible(file, s);
            break;
        }
        if (x.isTypeInstance() || x.isTypeTypeof() || x.isTypeReturn())
        {
            problem = "complex field type";
            return null;
        }
        if (auto tp = x.isTypePointer())
            x = tp.next;
        else if (auto ts = x.isTypeSArray())
            x = ts.next;
        else if (auto td = x.isTypeDArray())
            x = td.next;
        else
            break;
    }
    return t.toString.idup;
}

__gshared bool[size_t] narrowing;
__gshared string[size_t] problemCache;

string narrowProblem(size_t i)
{
    if (auto p = i in problemCache)
        return *p;
    auto r = narrowPlan(i, false);
    problemCache[i] = r;
    return r;
}

string narrowPlan(size_t i, bool apply)
{
    auto u = &puses[i];
    auto fn = &funcs[u.func];
    auto fd = fn.fd;
    if (u.index < 0)
        return "this";
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
    auto n = normalized(*u);
    if (n.canFind(""))
        return "uses whole struct";
    const path = commonPrefix(n);
    const remove = n.length == 0;
    if (!remove && !path.length)
        return "uses " ~ topFields(n).length.to!string ~ " fields";
    string newName, decl;
    bool byValue;
    if (!remove)
    {
        auto v = fieldAt(u.sd, path);
        if (!v)
            return "can't resolve " ~ path;
        newName = path.split(".")[$ - 1];
        string tp;
        const typ = typeText(v, fn.file, apply, tp);
        if (tp.length)
            return tp;
        byValue = !u.byRef && !u.byPtr;
        if (!byValue && !writtenUnder(*u, path) && cheapType(v.type))
            byValue = aliasProblem(*u, path) is null;
        decl = (byValue ? "" : "ref ") ~ typ ~ " " ~ newName;
    }
    auto t = text(fn.file);
    const open = paramListOpen(u.func);
    if (open == uint.max)
        return "can't find parameter list";
    auto pspans = argSpans(fn.file, open);
    if (pspans.length != fd.parameters.length || u.index >= pspans.length)
        return "odd parameter list";
    auto ps = pspans[u.index];
    if (u.nameOff < ps[0] || u.nameOff >= ps[1] || !identAt(t, u.nameOff, u.name) || u.nameOff + u.name.length != ps[1])
        return "odd parameter declaration";
    if (fn.localNames.count(u.name) > 1)
        return "parameter name shadowed";
    if (newName.length && newName == fn.name)
        return "name clash: " ~ newName;
    uint[2][] copies;
    if (newName.length && fn.localNames.canFind(newName))
    {
        copies = localCopies(u.func, u.name, newName, path);
        if (copies.length != fn.localNames.count(newName))
            return "name clash: " ~ newName;
        if (!byValue)
            return "local copy of ref field " ~ newName;
        if (auto w = writtenLocal(u.func, newName, copies))
            return "local " ~ newName ~ " written at " ~ w;
    }
    bool inCopy(uint off)
    {
        return copies.any!(c => off >= c[0] && off < c[1]);
    }

    Edit[][string] mine;
    uint[] selfOffs;
    bool[string] seenOpen;
    string fail;
    void callSite(string file, uint openOff, size_t caller, bool ufcs)
    {
        if (fail.length || (file ~ ":" ~ openOff.to!string) in seenOpen)
            return;
        seenOpen[file ~ ":" ~ openOff.to!string] = true;
        auto spans = argSpans(file, openOff);
        const ai = ufcs ? u.index - 1 : u.index;
        if (ufcs && u.index == 0)
        {
            fail = "UFCS receiver " ~ lineOf(file, openOff);
            return;
        }
        if (ai >= spans.length)
        {
            fail = "missing argument " ~ lineOf(file, openOff);
            return;
        }
        auto ct = text(file);
        auto a = ct[spans[ai][0] .. spans[ai][1]];
        if (remove)
        {
            if (!simpleChain(a) && !(a[0] == '&' && simpleChain(a[1 .. $].strip)))
            {
                fail = "argument with side effects " ~ lineOf(file, openOff);
                return;
            }
            removeArg(file, spans, ai);
            return;
        }
        if (caller == u.func && file == fn.file && a == u.name)
        {
            selfOffs ~= spans[ai][0];
            return;
        }
        if (auto gn = caller in groupFuncName)
            if (a == *gn)
                return;
        narrowArg(file, spans[ai][0], spans[ai][1], path);
    }

    auto saved = edits;
    edits = null;
    scope (exit)
    {
        mine = edits;
        edits = saved;
        if (apply && !fail.length)
            foreach (file, list; mine)
                edits[file] ~= list;
    }

    foreach (ref c; calls)
    {
        if (c.callee != u.func)
            continue;
        if (c.caller == size_t.max)
            return fail = "call outside function " ~ lineOf(c.file, c.off);
        if (!isEditableFile(c.file))
            return fail = "caller outside backend/glue " ~ lineOf(c.file, c.off);
        const id = callIdent(c);
        if (id == uint.max)
            return fail = "odd call site " ~ lineOf(c.file, c.off);
        if (c.caller in narrowing && c.caller != u.func && c.caller !in groupFuncName)
            return fail = "caller " ~ funcs[c.caller].name ~ " narrowed in this step";
        uint recv;
        const q = qualifier(c.file, id, fd, recv);
        if (q == Qual.bad)
            return fail = "complex qualifier " ~ lineOf(c.file, c.off);
        callSite(c.file, c.off, c.caller, q == Qual.ufcs);
    }
    auto known = knownUses(fn.name);
    foreach (file; editableFiles())
        foreach (tok; identTokens(file))
            if (tok.ident == fn.name && (isDead(file, tok.off) || unseenCall(file, tok)) && (file ~ ":" ~ tok.off.to!string) !in known)
            {
                const o = deadCallOpen(file, tok);
                if (o == uint.max)
                    continue;
                const inside = file == fn.file && o > fn.nameOff && o < fn.endOff;
                foreach (ref o2; funcs)
                    if (o2.file == file && o2.nameOff < o && o < o2.endOff && &o2 != fn && (cast(size_t)(&o2 - funcs.ptr)) in narrowing &&
                        (cast(size_t)(&o2 - funcs.ptr)) !in groupFuncName)
                        fail = "dead caller narrowed in this step";
                callSite(file, o, inside ? u.func : size_t.max, false);
            }
    if (fail.length)
        return fail;

    auto tks = allTokens(fn.file);
    const parts = remove ? null : path.split(".");
    bool[uint] matched;
    foreach (k, tk; tks)
    {
        if (tk.value != TOK.identifier || tk.ident != u.name || tk.off <= fn.nameOff || tk.off >= fn.endOff || tk.off == u.nameOff)
            continue;
        if (k > 0 && tks[k - 1].value == TOK.dot)
            continue;
        if (inCopy(tk.off))
        {
            matched[tk.off] = true;
            continue;
        }
        if (remove)
            return fail = "use of unused parameter " ~ lineOf(fn.file, tk.off);
        size_t j = k + 1;
        bool ok = true;
        foreach (part; parts)
        {
            if (j + 1 < tks.length && tks[j].value == TOK.dot && tks[j + 1].value == TOK.identifier && tks[j + 1].ident == part)
                j += 2;
            else
            {
                ok = false;
                break;
            }
        }
        if (ok)
        {
            const end = tks[j - 1].off + cast(uint) parts[$ - 1].length;
            edits[fn.file] ~= Edit(tk.off, end - tk.off, newName);
        }
        else if (selfOffs.canFind(tk.off) || groupForward(*u, tk.off, path))
            edits[fn.file] ~= Edit(tk.off, cast(uint) u.name.length, newName);
        else
        {
            foreach (ref fw; u.fwds)
                if (fw.rootOff == tk.off && fw.prefix.length < path.length && fw.callee != u.func)
                    return fail = "waits on " ~ funcs[fw.callee].name;
            return fail = "use at " ~ lineOf(fn.file, tk.off);
        }
        matched[tk.off] = true;
    }
    foreach (r; u.roots ~ u.fwds.map!(f => f.rootOff).array)
        if (r != uint.max && r !in matched)
            return fail = "unmatched use " ~ lineOf(fn.file, r);
    if (newName.length)
        foreach (k, tk; tks)
            if (tk.value == TOK.identifier && tk.ident == newName && tk.off > fn.nameOff && tk.off < fn.endOff &&
                !(k > 0 && tks[k - 1].value == TOK.dot) && !inCopy(tk.off) &&
                !(copies.length && k + 1 < tks.length && tks[k + 1].value != TOK.leftParenthesis))
                return fail = "name clash: " ~ newName ~ " " ~ lineOf(fn.file, tk.off);
    foreach (c; copies)
        edits[fn.file] ~= Edit(c[0], c[1] - c[0], "");
    if (remove)
        removeArg(fn.file, pspans, u.index);
    else
        edits[fn.file] ~= Edit(ps[0], ps[1] - ps[0], decl);
    if (auto bad = fixDoc(u.func, u.name, newName, remove ? null : fieldAt(u.sd, path)))
        return fail = bad;
    return null;
}

__gshared string[size_t] groupPath;
__gshared string[size_t] groupFuncName;

bool groupForward(ref PUse u, uint off, string path)
{
    foreach (ref fw; u.fwds)
        if (fw.rootOff == off && !fw.prefix.length)
            if (auto q = pkey(fw.callee, fw.index) in puseOfKey)
                if (auto gp = *q in groupPath)
                    if (*gp == path)
                        return true;
    return false;
}

size_t[] buildGroup(size_t i)
{
    const path = commonPrefix(normalized(puses[i]));
    if (!path.length)
        return null;
    size_t[] order = [i];
    bool[size_t] set = [i: true];
    for (size_t k = 0; k < order.length; k++)
        foreach (ref fw; puses[order[k]].fwds)
        {
            if (fw.prefix.length)
                continue;
            auto q = pkey(fw.callee, fw.index) in puseOfKey;
            if (!q)
                return null;
            if (*q in set)
                continue;
            if (puses[*q].sd !is puses[i].sd || commonPrefix(normalized(puses[*q])) != path || order.length >= 10)
                return null;
            set[*q] = true;
            order ~= *q;
        }
    return order.length > 1 ? order : null;
}

bool isTypeStart(TOK v)
{
    with (TOK) return v == identifier || v == auto_ || v == const_ || v == immutable_ || (v >= void_ && v <= bool_);
}

uint[2][] localCopies(size_t f, string pname, string newName, string path)
{
    auto fn = &funcs[f];
    auto t = text(fn.file);
    auto tks = allTokens(fn.file);
    auto parts = path.split(".");
    uint[2][] r;
    foreach (k, tk; tks)
    {
        if (tk.off <= fn.nameOff || tk.off >= fn.endOff || tk.value != TOK.identifier || tk.ident != newName || k < 2)
            continue;
        if (!isTypeStart(tks[k - 1].value))
            continue;
        const prev = tks[k - 2].value;
        if (prev != TOK.semicolon && prev != TOK.leftCurly && prev != TOK.rightCurly)
            continue;
        size_t j = k + 1;
        if (j + 1 >= tks.length || tks[j].value != TOK.assign || tks[j + 1].value != TOK.identifier || tks[j + 1].ident != pname)
            continue;
        j += 2;
        bool ok = true;
        foreach (part; parts)
        {
            if (j + 1 < tks.length && tks[j].value == TOK.dot && tks[j + 1].value == TOK.identifier && tks[j + 1].ident == part)
                j += 2;
            else
                ok = false;
        }
        if (!ok || j >= tks.length || tks[j].value != TOK.semicolon)
            continue;
        const ls = lineStart(t, tks[k - 1].off);
        const le = lineEnd(t, tks[j].off);
        if (t[ls .. le].strip != t[tks[k - 1].off .. tks[j].off + 1])
            continue;
        r ~= [ls, cast(uint) min(le + 1, t.length)];
    }
    return r;
}

string writtenLocal(size_t f, string name, uint[2][] copies)
{
    auto fn = &funcs[f];
    auto tks = allTokens(fn.file);
    foreach (k, tk; tks)
    {
        if (tk.off <= fn.nameOff || tk.off >= fn.endOff || tk.value != TOK.identifier || tk.ident != name)
            continue;
        if (copies.any!(c => tk.off >= c[0] && tk.off < c[1]) || k > 0 && tks[k - 1].value == TOK.dot)
            continue;
        const next = k + 1 < tks.length ? tks[k + 1].value : TOK.reserved;
        const prev = k > 0 ? tks[k - 1].value : TOK.reserved;
        with (TOK) if (next == assign || next == addAssign || next == minAssign || next == mulAssign || next == divAssign ||
            next == modAssign || next == andAssign || next == orAssign || next == xorAssign || next == leftShiftAssign ||
            next == rightShiftAssign || next == unsignedRightShiftAssign || next == concatenateAssign || next == plusPlus ||
            next == minusMinus || prev == plusPlus || prev == minusMinus || prev == and && k > 1 && unaryContext(tks[k - 2].value))
            return lineOf(fn.file, tk.off);
    }
    return null;
}

uint lineStart(string t, uint off)
{
    while (off > 0 && t[off - 1] != '\n')
        off--;
    return off;
}

uint lineEnd(string t, uint off)
{
    while (off < t.length && t[off] != '\n')
        off++;
    return off;
}

string fieldComment(VarDeclaration v)
{
    auto file = fileOf(v.loc);
    if (!file.exists)
        return null;
    auto t = text(file);
    auto line = t[v.loc.off .. lineEnd(t, v.loc.off)];
    const c = line.indexOf("//");
    return c < 0 ? null : line[c + 2 .. $].strip;
}

string fixDoc(size_t f, string oldName, string newName, VarDeclaration field)
{
    auto fn = &funcs[f];
    auto t = text(fn.file);
    auto tks = allTokens(fn.file);
    auto k = tokIndex(fn.file, fn.nameOff);
    if (k == size_t.max)
        return null;
    while (k > 0 && tks[k - 1].value != TOK.semicolon && tks[k - 1].value != TOK.rightCurly && tks[k - 1].value != TOK.leftCurly &&
        tks[k - 1].value != TOK.colon)
        k--;
    const declStart = tks[k].off;
    const from = k > 0 ? tks[k - 1].off + 1 : 0;
    auto gap = t[from .. declStart];
    const close = gap.lastIndexOf("*/");
    if (close < 0)
        return null;
    const open = gap[0 .. close].lastIndexOf("/**");
    if (open < 0)
        return null;
    uint i = cast(uint)(from + open);
    const end = cast(uint)(from + close);
    while (i < end)
    {
        const e = lineEnd(t, i);
        auto line = t[i .. e];
        auto body_ = line.stripLeft;
        if (body_.startsWith("*"))
            body_ = body_[1 .. $].stripLeft;
        if (body_.startsWith(oldName) && body_[oldName.length .. $].stripLeft.startsWith("="))
        {
            const nameAt = cast(uint)(i + line.length - body_.length);
            auto rest = body_[oldName.length .. $].stripLeft[1 .. $];
            const pad = body_[oldName.length .. $].length - body_[oldName.length .. $].stripLeft.length;
            const descAt = cast(uint)(e - rest.stripLeft.length);
            const next = e + 1 < t.length ? lineEnd(t, e + 1) : e;
            auto nextBody = e + 1 < next ? t[e + 1 .. next].stripLeft : "";
            if (nextBody.startsWith("*"))
                nextBody = nextBody[1 .. $].stripLeft;
            const continued = nextBody.length && !nextBody.canFind("=") && !nextBody.endsWith(":") && t[e + 1 .. next].indexOf(nextBody) > line.indexOf(body_) + 2;
            if (!newName.length)
            {
                if (continued)
                    return "multi-line parameter doc";
                edits[fn.file] ~= Edit(i, e + 1 - i, "");
                return null;
            }
            auto desc = field ? fieldComment(field) : null;
            edits[fn.file] ~= Edit(nameAt, cast(uint)(oldName.length + pad), newName ~ " ".replicate(max(1, cast(int)(oldName.length + pad) - cast(int) newName.length)));
            if (desc.length && !continued)
                edits[fn.file] ~= Edit(descAt, e - descAt, desc);
            return null;
        }
        i = e + 1;
    }
    return null;
}

int narrowStep(string type, size_t max, string[] skip, string[] only, bool dry)
{
    size_t[] cands;
    foreach (i, ref u; puses)
        if (u.index >= 0 && funcs[u.func].editable && u.sd.ident.toString == type)
            cands ~= i;
    cands.sort!((a, b) => funcs[puses[a].func].callers.length < funcs[puses[b].func].callers.length);
    size_t[] chosen;
    foreach (i; cands)
    {
        if (chosen.length >= max)
            break;
        auto f = puses[i].func;
        if (skip.canFind(funcs[f].name) || only.length && !only.canFind(funcs[f].name) || f in narrowing)
            continue;
        if (chosen.any!(c => funcs[puses[c].func].calls.canFind(f) || funcs[f].calls.canFind(puses[c].func)))
            continue;
        auto why = narrowPlan(i, false);
        if (!why.length)
        {
            narrowing[f] = true;
            chosen ~= i;
            continue;
        }
        if (!why.startsWith("waits on"))
            continue;
        auto grp = buildGroup(i);
        if (!grp.length || chosen.length + grp.length > max)
            continue;
        if (grp.any!(g => g in groupPath || puses[g].func in narrowing || skip.canFind(funcs[puses[g].func].name) ||
            chosen.any!(c => funcs[puses[c].func].calls.canFind(puses[g].func) || funcs[puses[g].func].calls.canFind(puses[c].func))))
            continue;
        const gpath = commonPrefix(normalized(puses[i]));
        foreach (g; grp)
        {
            groupPath[g] = gpath;
            groupFuncName[puses[g].func] = puses[g].name;
            narrowing[puses[g].func] = true;
        }
        if (grp.all!(g => narrowPlan(g, false).length == 0))
        {
            chosen ~= grp;
            continue;
        }
        foreach (g; grp)
        {
            groupPath.remove(g);
            groupFuncName.remove(puses[g].func);
            narrowing.remove(puses[g].func);
        }
    }
    foreach (i; chosen)
    {
        auto u = &puses[i];
        auto n = normalized(*u);
        auto bad = narrowPlan(i, true);
        if (bad.length)
        {
            fprintf(stderr, "narrow: %s: %s\n", funcs[u.func].name.toStringz, bad.toStringz);
            return 1;
        }
        printf("%s %s %s\n", funcs[u.func].name.toStringz, rel(funcs[u.func].file).toStringz, (n.length ? commonPrefix(n) : "-").toStringz);
    }
    if (!dry)
        applyEdits();
    return 0;
}
