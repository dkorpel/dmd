module dmd.wasmctfe;

enum WasmCtfeMode
{
    off,
    verify,
    inproc,
    strict,
}

version (NoBackend)
{
    import dmd.expression;
    import dmd.func;

    WasmCtfeMode wasmCtfeMode() { return WasmCtfeMode.off; }
    bool wasmCtfeBuildActiveNow() { return false; }
    bool wasmCtfeLoweringActive() pure nothrow @nogc @trusted { return false; }
    void wasmCtfeCompare(Expression e, Expression astResult, Expression wasmResult) { }
    Expression tryWasmCtfe(Expression e) { return null; }
    enum wasmCtfeDeferred = false;
    bool wasmCtfeTakeForcedSem3Error(FuncDeclaration fd) { return false; }
    void wasmCtfeSuspendMinstNull() { }
    void wasmCtfeResumeMinstNull() { }
}
else
{

import core.stdc.stdio;
import core.stdc.string;
import core.stdc.stdlib : getenv, malloc, realloc, free;

import dmd.arraytypes;
import dmd.astenums;
import dmd.tokens : EXP;
import dmd.builtin : isBuiltin;
import dmd.common.outbuffer;
import dmd.declaration;
import dmd.dmodule;
import dmd.dstruct;
import dmd.dsymbol;
import dmd.expression;
import dmd.func;
import dmd.globals;
import dmd.id;
import dmd.identifier;
import dmd.location;
import dmd.mangle : mangleExact, mangleToBuffer;
import dmd.mtype;
import dmd.root.array;
import dmd.root.ctfloat;
import dmd.root.rmem;
import dmd.root.string : startsWith, toDString;
import dmd.root.stringtable;
import dmd.statement;
import dmd.typesem : toBasetype, size, nextOf, defaultInitLiteral, arrayOf, equivalent, immutableOf;
import dmd.expressionsem : toInteger, toUInteger;
import dmd.funcsem : functionSemantic3;
import dmd.dsymbolsem : isPOD, determineSize, isOverlappedWith;
import dmd.visitor;

struct WasmCtfeStats
{
    uint calls;
    uint attempts;
    uint successes;
    uint compileFailures;
    uint cacheHits;
    uint mismatches;
    uint modules;
    uint tempModules;
    uint flushes;
    uint nestedRuns;
    long[Phase.max + 1] ticks;
    enum Phase { total, gen, compile, link, call, decode, teardown }
}

private long ipNow()
{
    import core.time : MonoTime;
    return MonoTime.currTime().ticks();
}

__gshared WasmCtfeStats wasmCtfeStats;
__gshared bool wasmCtfeTraceGen;

private __gshared uint buildActiveSuspended;

public void wasmCtfeSuspendMinstNull()
{
    ++buildActiveSuspended;
}

public void wasmCtfeResumeMinstNull()
{
    --buildActiveSuspended;
}

private __gshared uint preSemDepth;

bool wasmCtfeBuildActiveNow()
{
    if (buildActiveSuspended)
        return false;
    if (wasmCtfeMode() == WasmCtfeMode.off)
        return false;
    if (preSemDepth)
        return true;
    return wasmCGCtfeBuild;
}

bool wasmCtfeLoweringActive() pure nothrow @nogc @trusted
{
    alias FP = WasmCtfeMode function() pure nothrow @nogc;
    auto fp = cast(FP) &wasmCtfeMode;
    return fp() != WasmCtfeMode.off;
}

private __gshared
{
    WasmCtfeMode mode = WasmCtfeMode.off;
    bool modeChecked = false;
    bool verbose = false;
    bool keepFiles = false;
    bool traceFallback = false;
    uint seq = 0;
    StringTable!(Expression) ipResultCache;
}

WasmCtfeMode wasmCtfeMode()
{
    if (modeChecked)
        return mode;
    modeChecked = true;
    version (Posix)
    {
        mode = WasmCtfeMode.strict;
        if (const p = getenv("DMD_CTFE"))
        {
            if (strcmp(p, "off") == 0)
                mode = WasmCtfeMode.off;
            else if (strcmp(p, "verify") == 0)
                mode = WasmCtfeMode.verify;
            else if (strcmp(p, "inproc") == 0)
                mode = WasmCtfeMode.inproc;
        }
        verbose = getenv("DMD_CTFE_VERBOSE") !is null;
        if (mode != WasmCtfeMode.off)
        {
            import core.stdc.stdlib : atexit;
            if (getenv("DMD_CTFE_STATS"))
                atexit(&wasmCtfePrintStats);
            ipResultCache._init(64);
        }
        keepFiles = getenv("DMD_CTFE_KEEP") !is null;
        traceFallback = getenv("DMD_CTFE_TRACEFB") !is null;
        wasmCtfeTraceGen = getenv("DMD_CTFE_TRACEGEN") !is null;
    }
    return mode;
}

private extern (C) void wasmCtfePrintStats()
{
    with (wasmCtfeStats)
        fprintf(stderr, "wasm-ctfe: calls=%u attempts=%u ok=%u compilefail=%u cachehit=%u mismatch=%u\n",
            calls, attempts, successes, compileFailures, cacheHits, mismatches);
    import core.time : MonoTime;
    const double tps = MonoTime.ticksPerSecond() / 1000.0;
    with (wasmCtfeStats)
        fprintf(stderr, "wasm-ctfe: modules=%u temp=%u flushes=%u nested=%u total=%.1fms gen=%.1fms compile=%.1fms link=%.1fms call=%.1fms decode=%.1fms teardown=%.1fms\n",
            modules, tempModules, flushes, nestedRuns, ticks[Phase.total] / tps, ticks[Phase.gen] / tps, ticks[Phase.compile] / tps,
            ticks[Phase.link] / tps, ticks[Phase.call] / tps, ticks[Phase.decode] / tps, ticks[Phase.teardown] / tps);
}

private struct IpCmpPair
{
    StructLiteralExp ast, wasm;
}

private __gshared Array!IpCmpPair ipCmpStack;

private bool ipIsVthisField(AggregateDeclaration ad, size_t i, size_t n)
{
    auto cd = ad.isClassDeclaration();
    if (!cd)
        return i < ad.fields.length && ad.fields[i].isThisDeclaration() !is null;
    ptrdiff_t soFar = n;
    for (auto c = cd; c; c = c.baseClass)
    {
        soFar -= c.fields.length;
        if (cast(ptrdiff_t) i >= soFar)
            return c.fields[i - soFar].isThisDeclaration() !is null;
    }
    return false;
}

private bool ipResultEqual(Expression astResult, Expression wasmResult, int depth = 0)
{
    if (depth > 200)
        return true;
    if (!astResult || !wasmResult)
        return astResult is wasmResult;
    if (astResult.type && wasmResult.type && astResult.type.toBasetype().ty == Tvoid && wasmResult.type.toBasetype().ty == Tvoid)
        return true;
    if (auto aae = astResult.isAddrExp())
    {
        auto wae = wasmResult.isAddrExp();
        if (!wae)
            return false;
        auto aie = aae.e1.isIndexExp();
        auto wie = wae.e1.isIndexExp();
        if (aie && wie && aie.e1.isArrayLiteralExp() && wie.e1.isArrayLiteralExp()
            && aie.e2.isIntegerExp() && wie.e2.isIntegerExp())
        {
            auto aal = aie.e1.isArrayLiteralExp();
            auto wal = wie.e1.isArrayLiteralExp();
            const ai = cast(size_t) aie.e2.toInteger();
            const wi = cast(size_t) wie.e2.toInteger();
            if (!aal.elements || !wal.elements || ai >= aal.elements.length || wi >= wal.elements.length)
                return false;
            return ipResultEqual(aal[ai], wal[wi], depth + 1);
        }
        return ipResultEqual(aae.e1, wae.e1, depth + 1);
    }
    if (auto ate = astResult.isTupleExp())
    {
        auto wte = wasmResult.isTupleExp();
        if (!wte || ate.exps.length != wte.exps.length)
            return false;
        foreach (i; 0 .. ate.exps.length)
            if (!ipResultEqual((*ate.exps)[i], (*wte.exps)[i], depth + 1))
                return false;
        return true;
    }
    if (auto ace = astResult.isClassReferenceExp())
    {
        if (auto wce = wasmResult.isClassReferenceExp())
            if (ipResultEqual(ace.value, wce.value, depth + 1))
                return true;
    }
    if (auto ave = astResult.isVectorExp())
    {
        auto wve = wasmResult.isVectorExp();
        return wve && ipResultEqual(ave.e1, wve.e1, depth + 1);
    }
    if (auto aie = astResult.isIndexExp())
    {
        auto wie = wasmResult.isIndexExp();
        if (!wie || !aie.e2.isIntegerExp() || !wie.e2.isIntegerExp())
            return false;
        return aie.e2.toInteger() == wie.e2.toInteger() && ipResultEqual(aie.e1, wie.e1, depth + 1);
    }
    if (auto asl = astResult.isSliceExp())
    {
        auto ase = asl.e1.isStringExp();
        auto wse = wasmResult.isStringExp();
        if (ase && wse && asl.lwr && asl.upr && asl.lwr.isIntegerExp() && asl.upr.isIntegerExp())
        {
            const lo = cast(size_t) asl.lwr.toInteger();
            const hi = cast(size_t) asl.upr.toInteger();
            if (lo > hi || hi > ase.len || hi - lo != wse.len)
                return false;
            foreach (i; 0 .. wse.len)
                if (ase.getIndex(lo + i) != wse.getIndex(i))
                    return false;
            return true;
        }
    }
    if (wasmResult.isNullExp())
    {
        if (astResult.isNullExp())
            return true;
        if (auto ale = astResult.isArrayLiteralExp())
            if (ale.elements is null || ale.elements.length == 0)
                return true;
        if (auto se = astResult.isStringExp())
            if (se.len == 0)
                return true;
    }
    static bool stringEqualsLiteral(StringExp se, ArrayLiteralExp ale)
    {
        if (!se || !ale || (ale.elements ? ale.elements.length : 0) != se.len)
            return false;
        foreach (i; 0 .. se.len)
        {
            auto ie = ale[i] ? ale[i].isIntegerExp() : null;
            if (!ie || cast(ulong) ie.toInteger() != se.getIndex(i))
                return false;
        }
        return true;
    }
    if (stringEqualsLiteral(wasmResult.isStringExp(), astResult.isArrayLiteralExp())
        || stringEqualsLiteral(astResult.isStringExp(), wasmResult.isArrayLiteralExp()))
        return true;
    if (auto wsl = wasmResult.isStructLiteralExp())
    {
        auto asl = astResult.isStructLiteralExp();
        auto cd = wsl.sd.isClassDeclaration();
        if (asl && asl.sd is wsl.sd && cd && ipClassHasOverlap(cd))
        {
            const sz = cast(size_t) cd.structsize;
            auto ab = new ubyte[](sz);
            auto wb = new ubyte[](sz);
            if (ipEncodeClassFields(ab, cd, asl.elements) && ipEncodeClassFields(wb, cd, wsl.elements))
                return ab == wb;
        }
        if (asl && asl.sd is wsl.sd && hasOverlaps(wsl.sd) && wsl.type)
        {
            const sz = cast(size_t) wsl.type.size();
            auto ab = new ubyte[](sz);
            auto wb = new ubyte[](sz);
            if (ipEncodeVal(ab, 0, wsl.type, asl) && ipEncodeVal(wb, 0, wsl.type, wsl))
                return ab == wb;
        }
        if (asl && asl.sd is wsl.sd)
        {
            foreach (p; ipCmpStack)
                if (p.ast is asl && p.wasm is wsl)
                    return true;
            ipCmpStack.push(IpCmpPair(asl, wsl));
            scope (exit) ipCmpStack.pop();
            const n = wsl.elements ? wsl.elements.length : 0;
            const na = asl.elements ? asl.elements.length : 0;
            bool same = na <= n;
            for (size_t i = 0; same && i < n; i++)
            {
                auto ael = i < na ? (*asl.elements)[i] : null;
                if (!ael || !(*wsl.elements)[i] || ael.isVoidInitExp())
                    continue;
                if (ael.isNullExp() && ipIsVthisField(wsl.sd, i, n))
                    continue;
                same = ipResultEqual(ael, (*wsl.elements)[i], depth + 1);
            }
            if (same)
                return true;
        }
    }
    if (auto wal = wasmResult.isArrayLiteralExp())
    {
        if (astResult.isIntegerExp() || astResult.isRealExp())
        {
            const n = wal.elements ? wal.elements.length : 0;
            if (n && wal[0] && ipResultEqual(astResult, wal[0], depth + 1))
                return true;
        }
        if (auto aal = astResult.isArrayLiteralExp())
        {
            const n = wal.elements ? wal.elements.length : 0;
            bool same = n == (aal.elements ? aal.elements.length : 0);
            for (size_t i = 0; same && i < n; i++)
                same = aal[i] && wal[i] && ipResultEqual(aal[i], wal[i], depth + 1);
            if (same)
                return true;
        }
    }
    if (auto aie = astResult.isIntegerExp())
    {
        if (auto wie = wasmResult.isIntegerExp())
            return aie.toInteger() == wie.toInteger();
        return false;
    }
    if (auto are = astResult.isRealExp())
    {
        if (auto wre = wasmResult.isRealExp())
        {
            if (CTFloat.isIdentical(are.value, wre.value))
                return true;
        }
        else
            return false;
    }
    return strcmp(astResult.toChars(), wasmResult.toChars()) == 0;
}

private bool ipClassHasOverlap(ClassDeclaration cd)
{
    for (auto c = cd; c; c = c.baseClass)
        foreach (v; c.fields)
            if (v.overlapped)
                return true;
    return false;
}

private bool ipEncodeClassFields(ubyte[] buf, ClassDeclaration cd, Expressions* elems)
{
    if (!elems)
        return false;
    ptrdiff_t soFar = elems.length;
    for (auto c = cd; c; c = c.baseClass)
    {
        soFar -= c.fields.length;
        foreach (i, v; c.fields)
        {
            if (soFar + cast(ptrdiff_t) i < 0)
                return false;
            auto el = (*elems)[soFar + i];
            if (!el)
                continue;
            if (!ipScalarType(v.type) && !ipMemType(v.type))
                return false;
            if (!ipEncodeVal(buf, v.offset, v.type, el))
                return false;
        }
    }
    return true;
}

void wasmCtfeCompare(Expression e, Expression astResult, Expression wasmResult)
{
    if (ipResultEqual(astResult, wasmResult))
        return;
    if (auto ae = astResult.isAddrExp())
        if (auto ve = ae.e1.isVarExp())
            if (auto v = ve.var.isVarDeclaration())
                if (!v.isDataseg())
                    return;
    wasmCtfeStats.mismatches++;
    fprintf(stderr, "wasm-ctfe MISMATCH at %s: `%s`\n  ast:  %s\n  wasm: %s\n",
        e.loc.toChars(), e.toChars(), astResult.toChars(), wasmResult.toChars());
}

Expression tryWasmCtfe(Expression e)
{
    if (mode == WasmCtfeMode.off)
        return null;
    ipLastReason[0] = 0;
    const savedDeferred = ipNestedDeferred;
    ipNestedDeferred = false;
    scope (exit)
    {
        wasmCtfeDeferred = ipNestedDeferred;
        ipNestedDeferred = savedDeferred;
    }
    wasmCtfeStats.calls++;
    __gshared int depth;
    const t0 = ipNow();
    depth++;
    scope (exit)
        if (--depth == 0)
            wasmCtfeStats.ticks[WasmCtfeStats.Phase.total] += ipNow() - t0;
    if (auto v = ipCircularVar(e))
    {
        if (mode == WasmCtfeMode.verify)
            return null;
        global.errorSink.error(e.loc, "circular initialization of %s `%s`", v.kind(), v.toPrettyChars());
        return ErrorExp.get();
    }
    if (mode != WasmCtfeMode.verify)
    {
        if (auto r = ipReportCircularCall(e, false))
            return r;
        if (auto r = ipCheckRootAssign(e))
            return r;
        if (auto r = ipCheckNewClass(e))
            return r;
    }
    auto ce = e.isCallExp();
    if (ce && ce.f && ce.f.semanticRun >= PASS.semantic3done && ce.f.hasSemantic3Errors
        && mode != WasmCtfeMode.verify)
    {
        import dmd.hdrgen : toErrMsg;
        if (wasmCtfeTakeForcedSem3Error(ce.f))
            ipCalledFrom(ce);
        else
            global.errorSink.error(ce.loc, "CTFE failed because of previous errors in `%s`", ce.f.toErrMsg());
        return ErrorExp.get();
    }
    if (ce && ce.f)
    {
        Expression thisExp;
        if (auto dve = ce.e1.isDotVarExp())
            thisExp = dve.e1;
        auto savedRoot = ipRootCall;
        ipRootCall = ce;
        auto r = tryWasmCtfeInproc(ce.f, thisExp, ce.arguments ? (*ce.arguments)[] : null, e.type, e.loc);
        ipRootCall = savedRoot;
        if (r)
            return r;
    }
    auto outerRoot = ipRootCall;
    ipRootCall = null;
    auto r = tryWasmCtfeExpr(e);
    ipRootCall = outerRoot;
    if (!r && mode != WasmCtfeMode.verify)
        r = ipReportCircularCall(e, true);
    if (!r && mode == WasmCtfeMode.strict && !ipNestedDeferred && !wasmCtfeIsLiteral(e))
    {
        global.errorSink.error(e.loc, "wasm-ctfe cannot evaluate `%s` [%s]", e.toChars(),
            ipLastReason[0] ? ipLastReason.ptr : "run");
        return ErrorExp.get();
    }
    return r;
}

private bool ipContains(Expression root, Expression target)
{
    import dmd.visitor.postorder : walkPostorder;
    extern (C++) final class Contains : StoppableVisitor
    {
        alias visit = typeof(super).visit;
        Expression target;
        override void visit(Expression e)
        {
            if (e is target)
                stop = true;
        }
    }
    scope c = new Contains();
    c.target = target;
    return walkPostorder(root, c);
}

private Expression ipCheckRootAssign(Expression root)
{
    import dmd.visitor.postorder : walkPostorder;
    import dmd.hdrgen : toErrMsg;
    extern (C++) final class Find : StoppableVisitor
    {
        alias visit = typeof(super).visit;
        BinExp found;
        override void visit(Expression) {}
        override void visit(AssignExp e) { note(e); }
        override void visit(BinAssignExp e) { note(e); }
        extern (D) void note(BinExp e)
        {
            if (!found || ipContains(e, found))
                found = e;
        }
    }
    scope f = new Find();
    walkPostorder(root, f);
    if (!f.found)
        return null;
    global.errorSink.error(f.found.loc, "value of `%s` is not known at compile time", f.found.e1.toErrMsg());
    return ErrorExp.get();
}

private Expression ipCheckNewClass(Expression root)
{
    import dmd.visitor.postorder : walkPostorder;
    import dmd.expressionsem : getConstInitializer;
    extern (C++) final class Find : StoppableVisitor
    {
        alias visit = typeof(super).visit;
        Expression result;
        override void visit(Expression) {}
        override void visit(NewExp e)
        {
            auto tc = e.newtype ? e.newtype.toBasetype().isTypeClass() : null;
            if (!tc)
                return;
            for (ClassDeclaration c = tc.sym; c; c = c.baseClass)
                foreach (v; c.fields)
                {
                    if (v.inuse)
                    {
                        global.errorSink.error(e.loc, "circular reference to `%s`", v.toPrettyChars());
                        result = ErrorExp.get();
                        stop = true;
                        return;
                    }
                    if (!v._init || v._init.isVoidInitializer())
                        continue;
                    auto m = v.getConstInitializer(true);
                    if (!m || m.op == EXP.error)
                    {
                        result = ErrorExp.get();
                        stop = true;
                        return;
                    }
                }
        }
    }
    scope f = new Find();
    walkPostorder(root, f);
    return f.result;
}

private Expression ipReportCircularCall(Expression root, bool pending)
{
    import dmd.visitor.postorder : walkPostorder;
    extern (C++) final class Find : StoppableVisitor
    {
        alias visit = typeof(super).visit;
        CallExp found;
        bool pending;
        override void visit(Expression) {}
        override void visit(CallExp e)
        {
            if (auto dve = e.e1.isDotVarExp())
                if (dve.e1.isThisExp())
                    return;
            if (e.f && (e.f.semanticRun == PASS.semantic3 || pending && e.f.semanticRun < PASS.semantic3done))
            {
                found = e;
                stop = true;
            }
        }
    }
    scope f = new Find();
    f.pending = pending;
    walkPostorder(root, f);
    if (!f.found)
        return null;
    auto fd = f.found.f;
    global.errorSink.error(fd.loc, "%s `%s` circular dependency. Functions cannot be interpreted while being compiled",
        fd.kind, fd.toPrettyChars);
    ipCalledFrom(f.found);
    return ErrorExp.get();
}

private VarDeclaration ipCircularVar(Expression e)
{
    import dmd.visitor.postorder : walkPostorder;
    extern (C++) final class Circular : StoppableVisitor
    {
        VarDeclaration found;
        alias visit = typeof(super).visit;
        override void visit(Expression) {}
        override void visit(VarExp e)
        {
            auto v = e.var.isVarDeclaration();
            if (v && v.inuse && v._init && !v.isCTFE()
                && (v.isConst() || v.isImmutable() || v.storage_class & STC.manifest))
            {
                found = v;
                stop = true;
            }
        }
    }
    scope c = new Circular();
    walkPostorder(e, c);
    return c.found;
}

private bool ipHasCall(Expression e)
{
    import dmd.visitor.postorder : walkPostorder;
    extern (C++) final class HasCall : StoppableVisitor
    {
        alias visit = typeof(super).visit;
        override void visit(Expression) {}
        override void visit(CallExp) { stop = true; }
    }
    scope v = new HasCall();
    return walkPostorder(e, v);
}

import dmd.aggregate : AggregateDeclaration, ClassKind;
import dmd.dclass : ClassDeclaration, InterfaceDeclaration;
import dmd.dtemplate : TemplateDeclaration, TemplateInstance;
import dmd.dmsc : wasmCtfeSoftRealTarget;
import dmd.backend.barray : Barray;
import dmd.backend.wasm.codgen : wasmCGCtfeBuild;
import dmd.backend.wasm.softreal : SR, softRealNames, softRealPrefix;
import dmd.glue.e2ir : wasmCtfeDollarInit;


private void ipPutFloat(ubyte[] mem, ulong addr, size_t sz, real r)
{
    auto p = mem.ptr + cast(size_t) addr;
    if (sz == 4)
    {
        const f = cast(float) r;
        memcpy(p, &f, 4);
    }
    else if (sz == 8)
    {
        const d = cast(double) r;
        memcpy(p, &d, 8);
    }
    else
    {
        p[0 .. sz] = 0;
        memcpy(p, &r, 10);
    }
}

private real ipLdReal(const(void)* p) nothrow @nogc
{
    real r = 0;
    memcpy(&r, p, 10);
    return r;
}

private bool ipTypeBlocksEngine(Type t, int depth = 0)
{
    import dmd.typesem : isComplex, isImaginary;
    if (!t || depth > 8)
        return false;
    auto tb = t.toBasetype();
    if (tb.isComplex() || tb.isImaginary() || (tb.ty == Tfloat80 && !wasmCtfeSoftRealTarget()))
        return true;
    if (auto ts = tb.isTypeStruct())
    {
        foreach (f; ts.sym.fields)
            if (ipTypeBlocksEngine(f.type, depth + 1))
                return true;
        return false;
    }
    if (tb.isTypeSArray())
        return ipTypeBlocksEngine(tb.nextOf(), depth + 1);
    return false;
}

private bool ipNestedFrameFree(FuncDeclaration f)
{
    import dmd.funcsem : hasNestedFrameRefs;
    if (f.hasDualContext || f.needThis())
        return false;
    for (Dsymbol p = f.toParent2(); p; p = p.toParent2())
    {
        auto pf = p.isFuncDeclaration();
        if (pf && (pf.hasNestedFrameRefs() || pf.hasDualContext))
            return false;
        if (!pf || !pf.isNested())
            return !ipReadsOuterLocals(f);
    }
    return false;
}

private bool ipNestedCallable(FuncDeclaration f)
{
    if (f.hasDualContext || f.needThis())
        return false;
    for (Dsymbol p = f.toParent2(); p; p = p.toParent2())
    {
        auto pf = p.isFuncDeclaration();
        if (!pf || !pf.isNested())
            return true;
        if (pf.hasDualContext || pf.needThis())
            return false;
    }
    return true;
}

private bool ipReadsOuterLocals(FuncDeclaration f)
{
    import dmd.visitor.foreachvar : foreachExpAndVar;
    import dmd.visitor.postorder : walkPostorder;
    if (!f.fbody)
        return false;
    extern (C++) final class OuterScan : StoppableVisitor
    {
        alias visit = typeof(super).visit;
        FuncDeclaration f;
        VarDeclarations declared;
        VarDeclarations suspects;
        extern (D) void check(Declaration d)
        {
            auto v = d ? d.isVarDeclaration() : null;
            if (!v || v.isDataseg() || (v.storage_class & STC.manifest))
                return;
            auto p = v.toParent2();
            if (p && p.isFuncDeclaration() && p !is f && !wasmCtfeOuterConstInit(v))
                suspects.push(v);
        }
        extern (D) void declare(VarDeclaration vd)
        {
            if (vd.toParent2() !is f)
                declared.push(vd);
            if (auto ei = vd._init ? vd._init.isExpInitializer() : null)
                if (ei.exp)
                    walkPostorder(ei.exp, this);
        }
        override void visit(Expression) {}
        override void visit(VarExp e) { check(e.var); }
        override void visit(SymOffExp e) { check(e.var); }
        override void visit(DeclarationExp e)
        {
            if (auto vd = e.declaration ? e.declaration.isVarDeclaration() : null)
                declare(vd);
        }
    }
    scope v = new OuterScan();
    v.f = f;
    foreachExpAndVar(f.fbody, (Expression e) { walkPostorder(e, v); }, (VarDeclaration vd) { v.declare(vd); });
    foreach (s; v.suspects[])
        if (!v.declared.contains(s))
            return true;
    return false;
}

Expression wasmCtfeOuterConstInit(VarDeclaration v, FuncDeclaration reader = null)
{
    if (!v || !(v.isConst() || v.isImmutable()) || v.isReference() || v.isDataseg() || v.inuse)
        return null;
    if (reader && v.nestedrefs.contains(reader))
        return null;
    if (!v._init || v._init.isVoidInitializer() || !v.type || v.type.ty == Terror)
        return null;
    auto ei = v._init.isExpInitializer();
    if (!ei || !ei.exp)
        return null;
    Expression e = ei.exp;
    if (e.op == EXP.construct || e.op == EXP.blit)
        e = (cast(AssignExp) e).e2;
    if (!e || !e.type)
        return null;
    if (auto ts = v.type.toBasetype().isTypeStruct())
        if (ei.exp.op == EXP.blit && e.op == EXP.int64)
            e = ts.defaultInitLiteral(v.loc);
    return e;
}

private bool ipExprSupported(Expression e, out const(char)* why, VarDeclarations* declaredOut = null,
    VarDeclarations* enclosingOut = null, VarDeclaration* badOut = null, Expression* failAtOut = null)
{
    import dmd.visitor.postorder : walkPostorder;
    extern (C++) final class Scan : StoppableVisitor
    {
        alias visit = typeof(super).visit;
        VarDeclarations declared;
        VarDeclarations funcLocals;
        const(char)* why;
        Expression failAt;
        Type lastClear;
        extern (D) void fail(const(char)* r, Expression at = null)
        {
            if (!why)
            {
                why = r;
                failAt = at;
            }
            stop = true;
        }
        override void visit(DeclarationExp e)
        {
            if (auto vd = e.declaration ? e.declaration.isVarDeclaration() : null)
                declared.push(vd);
        }
        override void visit(SliceExp e)
        {
            visit(cast(Expression) e);
            if (e.lengthVar)
                declared.push(e.lengthVar);
        }
        override void visit(IndexExp e)
        {
            visit(cast(Expression) e);
            if (e.lengthVar)
                declared.push(e.lengthVar);
        }
        override void visit(SymbolExp e)
        {
            visit(cast(Expression) e);
            if (stop)
                return;
            auto vd = e.var ? e.var.isVarDeclaration() : null;
            if (vd && !vd.isDataseg() && !(vd.storage_class & STC.manifest)
                && vd.parent && (vd.parent.isFuncDeclaration() || (vd.isField() && !((vd.isConst() || vd.isImmutable()) && vd._init))))
                funcLocals.push(vd);
        }
        override void visit(Expression e)
        {
            if (!e.type || e.type is lastClear)
                return;
            if (ipTypeBlocksEngine(e.type))
                fail("blocked type");
            else
                lastClear = e.type;
        }
        override void visit(BinExp e)
        {
            visit(cast(Expression) e);
            if (stop)
                return;
            switch (e.op)
            {
                case EXP.add, EXP.min, EXP.mul, EXP.div, EXP.mod, EXP.pow,
                     EXP.and, EXP.or, EXP.xor,
                     EXP.leftShift, EXP.rightShift, EXP.unsignedRightShift,
                     EXP.lessThan, EXP.lessOrEqual, EXP.greaterThan, EXP.greaterOrEqual,
                     EXP.addAssign, EXP.minAssign, EXP.mulAssign, EXP.divAssign,
                     EXP.modAssign, EXP.powAssign, EXP.andAssign, EXP.orAssign,
                     EXP.xorAssign, EXP.leftShiftAssign, EXP.rightShiftAssign,
                     EXP.unsignedRightShiftAssign:
                    break;
                default:
                    return;
            }
            auto t1 = e.e1.type ? e.e1.type.toBasetype() : null;
            auto t2 = e.e2.type ? e.e2.type.toBasetype() : null;
            if ((t1 && t1.isStaticOrDynamicArray()) || (t2 && t2.isStaticOrDynamicArray()))
                fail("array binop", e);
        }
        override void visit(CatExp e)
        {
            if (!e.lowering)
                fail("CatExp");
        }
        override void visit(CatAssignExp e)
        {
            if (!e.lowering)
                fail("CatAssignExp");
        }
        override void visit(NewExp e)
        {
            auto nt = e.type ? e.type.toBasetype() : null;
            if (!e.lowering && !(nt && (nt.ty == Tclass || (nt.ty == Tpointer && !e.placement)
                || (nt.ty == Tarray && e.arguments && e.arguments.length == 1))))
                fail("NewExp");
        }
        override void visit(AssignExp e)
        {
            if (e.e1.isArrayLengthExp())
                fail("length assign");
        }
        override void visit(FuncExp e)
        {
            if (!e.fd || (e.fd.isNested() && !ipNestedCallable(e.fd)) || e.fd.needThis()
                || e.fd.semanticRun < PASS.semantic3done
                || e.fd.errors || e.fd.hasSemantic3Errors)
                fail("FuncExp");
        }
        bool[void*] classRefSeen;
        override void visit(ClassReferenceExp e)
        {
            visit(cast(Expression) e);
            if (stop)
                return;
            auto sle = e.value;
            if (!sle || cast(void*) sle in classRefSeen)
                return;
            classRefSeen[cast(void*) sle] = true;
            if (sle.elements)
                foreach (el; *sle.elements)
                    if (el && !stop)
                        el.accept(this);
        }
        override void visit(AssocArrayLiteralExp e)
        {
            visit(cast(Expression) e);
            if (stop)
                return;
            if (!e.lowering)
                fail("AssocArrayLiteralExp");
        }
        override void visit(ThisExp e)
        {
            fail("ThisExp", e);
        }
        override void visit(SuperExp e)
        {
            fail("SuperExp", e);
        }
        override void visit(CallExp e)
        {
            visit(cast(Expression) e);
            if (stop)
                return;
            if (e.e1.isTypeExp())
            {
                fail("type call", e);
                return;
            }
            if (!e.f)
                return;
            if (e.f.isNested() && !ipNestedCallable(e.f))
                fail("nested call");
        }
        override void visit(DelegateExp)
        {
            fail("DelegateExp");
        }
        override void visit(CastExp e)
        {
            visit(cast(Expression) e);
            if (stop || e.lowering)
                return;
            auto tb = e.type ? e.type.toBasetype() : null;
            auto fb = e.e1.type ? e.e1.type.toBasetype() : null;
            if (!tb || !fb)
                return;
            if (tb.ty == Tclass && fb.ty == Tclass)
            {
                auto ct = tb.isTypeClass().sym;
                auto cf = fb.isTypeClass().sym;
                if (wasmCtfeCppDowncast(cf, ct))
                    return;
                if (!ct.isBaseOf(cf, null))
                    fail("class or array cast");
            }
            else if (tb.ty == Tclass || fb.ty == Tclass)
                fail("class or array cast");
            else if (tb.ty == Tarray && fb.ty == Tarray
                && tb.nextOf().size() != fb.nextOf().size() && !wasmCtfeBadPointerCast(e, null))
                fail("class or array cast");
        }
    }
    scope v = new Scan();
    if (walkPostorder(e, v))
    {
        why = v.why;
        if (failAtOut && v.failAt)
            *failAtOut = v.failAt;
        return false;
    }
    if (declaredOut)
        foreach (dv; v.declared)
            declaredOut.push(dv);
    foreach (vd; v.funcLocals)
    {
        if (v.declared.contains(vd))
            continue;
        if (!enclosingOut || !ipHoistEnclosing(vd, why, declaredOut, enclosingOut, failAtOut))
        {
            if (!why)
            {
                why = "enclosing local";
                if (badOut)
                    *badOut = vd;
            }
            return false;
        }
    }
    return true;
}

private bool ipHoistEnclosing(VarDeclaration vd, out const(char)* why, VarDeclarations* declaredOut,
    VarDeclarations* enclosingOut, Expression* failAtOut)
{
    if (enclosingOut.contains(vd))
        return true;
    if (!(vd.isConst() || vd.isImmutable()) || (vd.storage_class & (STC.parameter | STC.ref_ | STC.out_ | STC.lazy_)))
        return false;
    auto ei = vd._init ? vd._init.isExpInitializer() : null;
    if (!ei || !ei.exp || enclosingOut.length > 16)
        return false;
    enclosingOut.push(vd);
    if (!ipExprSupported(ei.exp, why, declaredOut, enclosingOut, null, failAtOut))
        return false;
    enclosingOut.remove(enclosingOut.find(vd));
    enclosingOut.push(vd);
    return true;
}

private void ipAppendExpKey(Expression e, ref OutBuffer kb)
{
    import dmd.hdrgen : toCBuffer, HdrGenState;
    import dmd.visitor.postorder : walkPostorder;
    HdrGenState hgs;
    toCBuffer(e, kb, hgs);
    extern (C++) final class SymKey : StoppableVisitor
    {
        OutBuffer* kb;
        alias visit = typeof(super).visit;
        override void visit(Expression) {}
        override void visit(VarExp e) { put(e.var); }
        override void visit(SymOffExp e) { put(e.var); }
        override void visit(DotVarExp e) { put(e.var); }
        override void visit(FuncExp e) { put(e.fd); }
        override void visit(CallExp e) { if (e.f) put(e.f); }
        override void visit(StringExp e) { kb.writeByte(0); kb.write(e.peekData()); }
        override void visit(IntegerExp e) { lit(e); }
        override void visit(RealExp e) { lit(e); }
        extern (D) void lit(Expression e)
        {
            kb.writeByte(0);
            mangleToBuffer(e, *kb);
        }
        extern (D) void put(Dsymbol s)
        {
            kb.writeByte(0);
            kb.write(&s, s.sizeof);
        }
    }
    scope v = new SymKey();
    v.kb = &kb;
    walkPostorder(e, v);
}

private Expression ipReportUnreadable(Expression root, VarDeclaration bad)
{
    import dmd.visitor.postorder : walkPostorder;
    import dmd.hdrgen : toErrMsg;
    extern (C++) final class Find : StoppableVisitor
    {
        alias visit = typeof(super).visit;
        VarDeclaration bad;
        Expression target;
        SymbolExp found;
        CallExp[] calls;
        override void visit(Expression) {}
        override void visit(SymbolExp e)
        {
            if (!target && e.var is bad)
            {
                found = e;
                stop = true;
            }
        }
        override void visit(CallExp e)
        {
            if (!target || !e.arguments)
                return;
            foreach (a; *e.arguments)
                if (ipContains(a, target))
                {
                    calls ~= e;
                    break;
                }
        }
    }
    if ((bad.isConst() || bad.isImmutable()) && bad._init)
    {
        import dmd.init : ExpInitializer;
        auto ei = bad._init.isExpInitializer();
        if (!ei || !ei.exp || ei.exp.op == EXP.error || bad.type.ty == Terror)
            return ErrorExp.get();
        if (auto ae = ei.exp.isAssignExp())
            if (ae.e2.op == EXP.error)
                return ErrorExp.get();
    }
    scope f = new Find();
    f.bad = bad;
    walkPostorder(root, f);
    if (!f.found)
        return null;
    scope g = new Find();
    g.target = f.found;
    walkPostorder(root, g);
    global.errorSink.error(f.found.loc, "variable `%s` cannot be read at compile time", bad.toErrMsg());
    foreach (ce; g.calls)
        ipCalledFrom(ce);
    return ErrorExp.get();
}

private Expression ipReportStringArrayOp(BinExp be)
{
    import dmd.hdrgen : toErrMsg;
    foreach (op; [be.e1, be.e2])
    {
        Expression x = op;
        while (x.isSliceExp() || x.isCastExp())
            x = x.isSliceExp() ? x.isSliceExp().e1 : x.isCastExp().e1;
        auto se = x.isStringExp();
        if (!se)
            continue;
        global.errorSink.error(se.loc, "CTFE internal error: non-constant value `%s`", se.toErrMsg());
        global.errorSink.error(be.loc, "`%s` cannot be interpreted at compile time", be.toErrMsg());
        return ErrorExp.get();
    }
    return null;
}

private Expression ipFallback(Expression e, const(char)* reason)
{
    if (traceFallback)
        fprintf(stderr, "wasm-ctfe fallback %s: %s: %s\n", reason, e.loc.toChars(), e.toChars());
    snprintf(ipLastReason.ptr, ipLastReason.length, "%s", reason);
    return null;
}

private __gshared char[128] ipLastReason;
private __gshared bool ipNestedDeferred;
public __gshared bool wasmCtfeDeferred;

private bool wasmCtfeIsLiteral(Expression e)
{
    if (ipIsLiteral(e))
        return true;
    if (auto te = e.isTupleExp())
    {
        if (te.e0 && !ipIsLiteral(te.e0))
            return false;
        foreach (el; *te.exps)
            if (!ipIsLiteral(el))
                return false;
        return true;
    }
    return false;
}

private bool ipAllLiteral(Expression[] args)
{
    foreach (a; args)
        if (!ipIsLiteral(a))
            return false;
    return true;
}

private bool ipIsLiteralElems(Expressions* es, int depth)
{
    if (es)
        foreach (el; *es)
            if (el && !ipIsLiteral(el, depth + 1))
                return false;
    return true;
}

private bool ipIsLiteral(Expression e, int depth = 0)
{
    if (depth > 64)
        return false;
    if (e.isIntegerExp() || e.isRealExp() || e.isComplexExp()
        || e.isStringExp() || e.isNullExp() || e.isSymOffExp()
        || e.isFuncExp() || ipIsAddrLiteral(e) || ipIsVectorLiteral(e))
        return true;
    if (auto ve = e.isVarExp())
        return !ve.var.isVarDeclaration();
    if (auto de = e.isDelegateExp())
        if (auto ve = de.e1.isVarExp())
            if (ve.var == de.func)
                return true;
    if (auto te = e.isTypeidExp())
    {
        import dmd.dtemplate : isType;
        return isType(te.obj) !is null;
    }
    if (auto ale = e.isArrayLiteralExp())
        return (!ale.basis || ipIsLiteral(ale.basis, depth + 1)) && ipIsLiteralElems(ale.elements, depth);
    if (auto sle = e.isStructLiteralExp())
        return ipIsLiteralElems(sle.elements, depth);
    if (auto cre = e.isClassReferenceExp())
        return ipIsLiteralElems(cre.value.elements, depth);
    if (auto aae = e.isAssocArrayLiteralExp())
        return ipIsLiteralElems(aae.keys, depth) && ipIsLiteralElems(aae.values, depth);
    return false;
}

private bool ipIsVectorLiteral(Expression e)
{
    auto ve = e.isVectorExp();
    return ve && (ve.e1.isIntegerExp() || ve.e1.isRealExp() || ve.e1.isArrayLiteralExp());
}

private bool ipIsAddrLiteral(Expression e)
{
    auto ae = e.isAddrExp();
    if (!ae)
        return false;
    if (ae.e1.isStructLiteralExp())
        return true;
    auto ie = ae.e1.isIndexExp();
    return ie && ie.e1.isArrayLiteralExp() && ie.e2.isIntegerExp();
}

private Expression ipOptimizeGagged(Expression e)
{
    import dmd.optimize : optimize;
    const oldGagged = global.startGagging();
    auto r = e.optimize(WANTvalue);
    return global.endGagging(oldGagged) ? null : r;
}

private Expression ipFoldedLiteral(Expression r)
{
    import dmd.typesem : equivalent;
    if (auto se = r ? r.isSliceExp() : null)
        if (!se.lwr && !se.upr && se.type && se.e1.type && (se.e1.isArrayLiteralExp() || se.e1.isStringExp())
            && se.e1.type.toBasetype().ty == Tarray && equivalent(se.e1.type, se.type))
        {
            r = se.e1.copy();
            r.type = se.type;
        }
    return r && r.type && ipIsLiteral(r) ? r : null;
}

private Expression ipFoldOptimize(Expression e)
{
    auto r = ipFoldedLiteral(ipOptimizeGagged(e));
    return r is e ? null : r;
}

private Expression ipFoldConstVars(Expression e)
{
    import dmd.ctfeexpr : copyLiteral;
    auto x = ipSubstConstVars(e, 0);
    if (!x || x is e)
        return null;
    auto r = ipFoldedLiteral(ipOptimizeGagged(x));
    return r ? copyLiteral(r).copy() : null;
}

private bool ipValueLiteral(Expression e, int depth = 0)
{
    if (!e || depth > 64)
        return false;
    if (e.isIntegerExp() || e.isRealExp() || e.isComplexExp() || e.isStringExp() || e.isNullExp())
        return true;
    Expressions* elems;
    if (auto ale = e.isArrayLiteralExp())
    {
        if (ale.basis)
            return false;
        elems = ale.elements;
    }
    else if (auto sle = e.isStructLiteralExp())
    {
        if (sle.sd.vthis)
            return false;
        elems = sle.elements;
    }
    else
        return false;
    if (elems)
        foreach (el; *elems)
            if (!ipValueLiteral(el, depth + 1))
                return false;
    return true;
}

private int ipConstBody(Statement s, ref Expression result, int depth = 0)
{
    if (!s)
        return 0;
    if (depth > 32)
        return -1;
    if (auto rs = s.isReturnStatement())
    {
        result = rs.exp;
        return rs.exp ? 1 : -1;
    }
    if (auto cs = s.isCompoundStatement())
    {
        foreach (x; cs.statements)
            if (const r = ipConstBody(x, result, depth + 1))
                return r;
        return 0;
    }
    if (auto ss = s.isScopeStatement())
        return ipConstBody(ss.statement, result, depth + 1);
    if (auto fs = s.isForwardingStatement())
        return ipConstBody(fs.statement, result, depth + 1);
    if (auto ifs = s.isIfStatement())
    {
        int c = ifs.param ? 0 : ipCtfeCond(ifs.condition);
        if (!c && !ifs.param)
            if (auto oe = ipOptimizeGagged(ifs.condition.copy()))
                if (auto ie = oe.isIntegerExp())
                    c = ie.toInteger() ? 1 : -1;
        return c ? ipConstBody(c > 0 ? ifs.ifbody : ifs.elsebody, result, depth + 1) : -1;
    }
    if (auto es = s.isExpStatement())
    {
        if (!es.exp)
            return 0;
        auto de = es.exp.isDeclarationExp();
        if (!de)
            return -1;
        if (auto v = de.declaration.isVarDeclaration())
            return v.storage_class & STC.manifest ? 0 : -1;
        auto d = de.declaration;
        return d.isAliasDeclaration() || d.isFuncDeclaration() || d.isAggregateDeclaration()
            || d.isEnumDeclaration() || d.isTemplateDeclaration() ? 0 : -1;
    }
    return s.isImportStatement() ? 0 : -1;
}

private Expression ipFoldConstBody(FuncDeclaration fd, Type resultType)
{
    import dmd.ctfeexpr : copyLiteral;
    import dmd.typesem : equivalent;
    Expression e;
    if (fd.hasSemantic3Errors || global.params.ctfe_cov || ipConstBody(fd.fbody, e) != 1)
        return null;
    auto r = ipFoldedLiteral(ipOptimizeGagged(e.copy()));
    if (!ipValueLiteral(r) || !equivalent(r.type, resultType))
        return null;
    r = copyLiteral(r).copy();
    r.type = resultType;
    return r;
}

private bool ipFoldableOp(EXP op)
{
    switch (op)
    {
        case EXP.add, EXP.min, EXP.mul, EXP.div, EXP.mod, EXP.pow,
            EXP.and, EXP.or, EXP.xor, EXP.leftShift, EXP.rightShift, EXP.unsignedRightShift,
            EXP.concatenate, EXP.equal, EXP.notEqual, EXP.identity, EXP.notIdentity,
            EXP.lessThan, EXP.greaterThan, EXP.lessOrEqual, EXP.greaterOrEqual,
            EXP.negate, EXP.uadd, EXP.tilde, EXP.not, EXP.cast_:
            return true;
        default:
            return false;
    }
}

private bool ipTreeFoldable(Expression e, int depth = 0)
{
    if (depth > 32)
        return false;
    if (ipIsLiteral(e))
        return true;
    if (auto ce = e.isCallExp())
    {
        auto tf = ce.f && ce.f.type ? ce.f.type.isTypeFunction() : null;
        if (!tf || !ce.e1.isVarExp() || ce.f.isNested() || ce.f.needThis() || tf.isRef
            || tf.parameterList.varargs != VarArg.none)
            return false;
        foreach (i, p; tf.parameterList)
            if (p.storageClass & (STC.ref_ | STC.out_ | STC.lazy_))
                return false;
        if (ce.arguments)
            foreach (a; *ce.arguments)
                if (!ipTreeFoldable(a, depth + 1))
                    return false;
        return true;
    }
    if (auto ce = e.isCondExp())
        return ipTreeFoldable(ce.econd, depth + 1) && ipTreeFoldable(ce.e1, depth + 1)
            && ipTreeFoldable(ce.e2, depth + 1);
    if (auto le = e.isLogicalExp())
        return e.type.toBasetype().ty == Tbool && ipTreeFoldable(le.e1, depth + 1)
            && ipTreeFoldable(le.e2, depth + 1);
    if (!ipFoldableOp(e.op))
        return false;
    if (auto be = e.isBinExp())
        return ipTreeFoldable(be.e1, depth + 1) && ipTreeFoldable(be.e2, depth + 1);
    auto ue = e.isUnaExp();
    return ue && ipTreeFoldable(ue.e1, depth + 1);
}

private Expression ipFoldTree(Expression e)
{
    import dmd.expressionsem : toBool;
    if (ipIsLiteral(e))
        return e;
    if (auto ce = e.isCallExp())
    {
        Expression[] args;
        if (ce.arguments)
            foreach (a; *ce.arguments)
            {
                auto x = ipFoldTree(a);
                if (!x || x.isErrorExp())
                    return x;
                args ~= x;
            }
        auto savedRoot = ipRootCall;
        ipRootCall = ce;
        auto r = tryWasmCtfeInproc(ce.f, null, args, e.type, e.loc);
        ipRootCall = savedRoot;
        return r && (r.isErrorExp() || ipIsLiteral(r)) ? r : null;
    }
    if (auto ce = e.isCondExp())
    {
        auto c = ipFoldTree(ce.econd);
        if (!c || c.isErrorExp())
            return c;
        const b = c.toBool();
        return b.isPresent() ? ipFoldTree(b.get() ? ce.e1 : ce.e2) : null;
    }
    if (auto le = e.isLogicalExp())
    {
        const oror = e.op == EXP.orOr;
        foreach (x; [le.e1, le.e2])
        {
            auto c = ipFoldTree(x);
            if (!c || c.isErrorExp())
                return c;
            const b = c.toBool();
            if (b.isEmpty())
                return null;
            if (b.get() == oror || x is le.e2)
                return IntegerExp.createBool(b.get());
        }
        assert(0);
    }
    Expression n;
    if (auto be = e.isBinExp())
    {
        auto a = ipFoldTree(be.e1);
        if (!a || a.isErrorExp())
            return a;
        auto b = ipFoldTree(be.e2);
        if (!b || b.isErrorExp())
            return b;
        auto nb = cast(BinExp) be.copy();
        nb.e1 = a;
        nb.e2 = b;
        n = nb;
    }
    else
    {
        auto ue = e.isUnaExp();
        auto a = ipFoldTree(ue.e1);
        if (!a || a.isErrorExp())
            return a;
        auto nu = cast(UnaExp) ue.copy();
        nu.e1 = a;
        n = nu;
    }
    auto r = ipFoldedLiteral(ipOptimizeGagged(n));
    return r is n ? null : r;
}

private Expression ipSubstConstVars(Expression e, int depth)
{
    import dmd.typesem : equivalent;
    if (depth > 64)
        return null;
    if (auto ve = e.isVarExp())
    {
        auto v = ve.var.isVarDeclaration();
        if (!v)
            return e;
        if (!v.isDataseg() || !(v.isConst() || v.isImmutable()) || !v._init || !v._init.semanticDone)
            return null;
        auto ei = v._init.isExpInitializer();
        if (!ei || !ei.exp || !ei.exp.type || !ve.type || !ipIsLiteral(ei.exp) || !equivalent(ei.exp.type, ve.type))
            return null;
        auto r = ei.exp.copy();
        r.type = ve.type;
        return r;
    }
    Expressions* substElems(Expressions* es)
    {
        if (!es)
            return es;
        Expressions* res = es;
        foreach (i, el; *es)
        {
            if (!el)
                continue;
            auto x = ipSubstConstVars(el, depth + 1);
            if (!x)
                return null;
            if (x is el)
                continue;
            if (res is es)
                res = es.copy();
            (*res)[i] = x;
        }
        return res;
    }
    if (auto se = e.isSliceExp())
    {
        auto x = ipSubstConstVars(se.e1, depth + 1);
        auto l = se.lwr ? ipSubstConstVars(se.lwr, depth + 1) : null;
        auto u = se.upr ? ipSubstConstVars(se.upr, depth + 1) : null;
        if (!x || (se.lwr && !l) || (se.upr && !u))
            return null;
        if (x is se.e1 && l is se.lwr && u is se.upr)
            return e;
        auto n = cast(SliceExp) se.copy();
        n.e1 = x;
        n.lwr = l;
        n.upr = u;
        n.lengthVar = null;
        return n;
    }
    if (auto ie = e.isIndexExp())
    {
        auto x = ipSubstConstVars(ie.e1, depth + 1);
        auto i = ipSubstConstVars(ie.e2, depth + 1);
        if (!x || !i)
            return null;
        if (x is ie.e1 && i is ie.e2)
            return e;
        auto n = cast(IndexExp) ie.copy();
        n.e1 = x;
        n.e2 = i;
        n.lengthVar = null;
        return n;
    }
    if (auto ce = e.isCastExp())
    {
        auto x = ipSubstConstVars(ce.e1, depth + 1);
        if (!x)
            return null;
        if (x is ce.e1)
            return e;
        auto n = cast(CastExp) ce.copy();
        n.e1 = x;
        return n;
    }
    if (auto sle = e.isStructLiteralExp())
    {
        auto es = substElems(sle.elements);
        if (!es)
            return null;
        if (es is sle.elements)
            return e;
        auto n = cast(StructLiteralExp) sle.copy();
        n.elements = es;
        n.origin = n;
        return n;
    }
    if (auto ale = e.isArrayLiteralExp())
    {
        Expression basis = ale.basis;
        if (basis)
        {
            basis = ipSubstConstVars(basis, depth + 1);
            if (!basis)
                return null;
        }
        auto es = substElems(ale.elements);
        if (!es)
            return null;
        if (es is ale.elements && basis is ale.basis)
            return e;
        auto n = cast(ArrayLiteralExp) ale.copy();
        n.elements = es;
        n.basis = basis;
        return n;
    }
    return ipIsLiteral(e) ? e : null;
}

private Expression ipFoldLiteralCompare(Expression e)
{
    auto be = e.isBinExp();
    if (!be || !(e.isIdentityExp() || e.isEqualExp()))
        return null;
    const identity = e.isIdentityExp() !is null;
    auto e1 = ipOptimizeGagged(be.e1);
    auto e2 = e1 ? ipOptimizeGagged(be.e2) : null;
    if (!e2)
        return null;
    const r = ipLiteralCompare(e1, e2, identity);
    if (r < 0)
        return null;
    const eq = e.op == EXP.identity || e.op == EXP.equal;
    return new IntegerExp(e.loc, (r == 1) == eq ? 1 : 0, e.type);
}

private int ipLiteralCompare(Expression e1, Expression e2, bool identity)
{
    import dmd.expressionsem : isIdentical, toComplex;
    if (auto s1 = e1.isStructLiteralExp())
    {
        auto s2 = e2.isStructLiteralExp();
        if (!s2 || s1.sd !is s2.sd || !s1.elements || !s2.elements || s1.elements.length != s2.elements.length)
            return -1;
        foreach (i; 0 .. s1.elements.length)
        {
            auto a = (*s1.elements)[i];
            auto b = (*s2.elements)[i];
            if (!a || !b)
                return -1;
            const r = ipLiteralCompare(a, b, identity);
            if (r != 1)
                return r;
        }
        return 1;
    }
    if (auto c1 = e1.isComplexExp())
    {
        auto c2 = e2.isComplexExp();
        if (!c2)
            return -1;
        if (identity)
            return c1.isIdentical(c2) ? 1 : 0;
        return c1.toComplex() == c2.toComplex() ? 1 : 0;
    }
    if (auto r1 = e1.isRealExp())
    {
        auto r2 = e2.isRealExp();
        if (!r2)
            return -1;
        if (identity)
            return r1.isIdentical(r2) ? 1 : 0;
        return r1.value == r2.value ? 1 : 0;
    }
    if (auto i1 = e1.isIntegerExp())
    {
        auto i2 = e2.isIntegerExp();
        if (!i2)
            return -1;
        return i1.toInteger() == i2.toInteger() ? 1 : 0;
    }
    if (e1.isNullExp() && e2.isNullExp())
        return 1;
    return -1;
}

private size_t ipArrayDepth(Type t)
{
    size_t d;
    for (auto tb = t ? t.toBasetype() : null; tb && tb.isStaticOrDynamicArray(); tb = tb.nextOf().toBasetype())
        d++;
    return d;
}

private bool ipIsArrayOpNode(Expression e)
{
    if (!e.type || !e.type.toBasetype().isStaticOrDynamicArray())
        return false;
    switch (e.op)
    {
        case EXP.add, EXP.min, EXP.mul, EXP.div, EXP.mod,
             EXP.and, EXP.or, EXP.xor,
             EXP.leftShift, EXP.rightShift, EXP.unsignedRightShift,
             EXP.negate, EXP.tilde:
            return true;
        default:
            return false;
    }
}

private bool ipArrayOpLength(Expression e, size_t depth, ref size_t n)
{
    auto tb = e.type.toBasetype();
    if (ipArrayDepth(e.type) != depth)
        return false;
    if (auto ts = tb.isTypeSArray())
    {
        n = cast(size_t) ts.dim.toInteger();
        return true;
    }
    if (auto ale = e.isArrayLiteralExp())
    {
        n = ale.elements.length;
        return true;
    }
    if (auto se = e.isStringExp())
    {
        n = se.len;
        return true;
    }
    if (auto sle = e.isSliceExp())
    {
        if (sle.lwr && sle.upr && sle.lwr.isIntegerExp() && sle.upr.isIntegerExp())
        {
            n = cast(size_t) (sle.upr.toInteger() - sle.lwr.toInteger());
            return true;
        }
        return false;
    }
    if (ipIsArrayOpNode(e))
    {
        if (auto be = e.isBinExp())
            return ipArrayOpLength(be.e1, depth, n) || ipArrayOpLength(be.e2, depth, n);
        return ipArrayOpLength(e.isUnaExp().e1, depth, n);
    }
    return false;
}

private Expression ipArrayOpElem(Expression e, size_t depth, size_t i)
{
    if (ipIsArrayOpNode(e) && ipArrayDepth(e.type) == depth)
    {
        auto et = e.type.toBasetype().nextOf();
        Expression operand(Expression x)
        {
            if (ipArrayDepth(x.type) == depth)
                return ipArrayOpElem(x, depth, i);
            return x;
        }
        Expression fit(Expression x)
        {
            if (!x || ipArrayDepth(et) || x.type.equivalent(et))
                return x;
            auto c = new CastExp(x.loc, x, et);
            c.type = et;
            return c;
        }
        auto r = e.copy();
        if (auto be = r.isBinExp())
        {
            auto a = operand(be.e1);
            auto b = operand(be.e2);
            if (!a || !b)
                return null;
            if (e.op != EXP.leftShift && e.op != EXP.rightShift && e.op != EXP.unsignedRightShift)
                b = fit(b);
            be.e1 = fit(a);
            be.e2 = b;
        }
        else
        {
            auto ue = r.isUnaExp();
            ue.e1 = fit(operand(ue.e1));
            if (!ue.e1)
                return null;
        }
        r.type = et;
        if (ipArrayDepth(et))
            return ipLowerArrayOp(r);
        return r;
    }
    if (auto ale = e.isArrayLiteralExp())
        return ale[i];
    Expression base = e;
    Expression idx = new IntegerExp(e.loc, i, Type.tsize_t);
    if (auto sle = e.isSliceExp())
    {
        if (sle.lwr)
        {
            base = sle.e1;
            idx = new IntegerExp(e.loc, sle.lwr.toInteger() + i, Type.tsize_t);
        }
    }
    auto ie = new IndexExp(e.loc, base, idx);
    ie.type = e.type.toBasetype().nextOf();
    return ie;
}

private bool ipArrayOpCallFree(Expression e, size_t depth)
{
    if (!(ipIsArrayOpNode(e) && ipArrayDepth(e.type) == depth))
        return !ipHasCall(e);
    bool operand(Expression x)
    {
        return ipArrayDepth(x.type) != depth || ipArrayOpCallFree(x, depth);
    }
    if (auto be = e.isBinExp())
        return operand(be.e1) && operand(be.e2);
    return operand(e.isUnaExp().e1);
}

private Expression ipLowerArrayOp(Expression e)
{
    const depth = ipArrayDepth(e.type);
    size_t n;
    if (!ipArrayOpLength(e, depth, n) || n && !ipArrayOpCallFree(e, depth))
        return null;
    auto elems = new Expressions(n);
    foreach (i; 0 .. n)
    {
        auto x = ipArrayOpElem(e, depth, i);
        if (!x)
            return null;
        (*elems)[i] = x;
    }
    auto ale = new ArrayLiteralExp(e.loc, e.type, elems);
    return ale;
}

private Expression ipSubExpr(Expression e)
{
    import dmd.ctfeexpr : copyLiteral;
    auto r = tryWasmCtfeExpr(e);
    return r || !wasmCtfeIsLiteral(e) ? r : copyLiteral(e).copy();
}

Expression tryWasmCtfeExpr(Expression e)
{
    if (wasmCtfeIsLiteral(e))
        return null;
    if (auto te = e.isTupleExp())
    {
        if (te.e0 && !ipIsLiteral(te.e0))
            return ipFallback(e, "tuple");
        auto exps = te.exps.copy();
        foreach (ref el; *exps)
        {
            if (ipIsLiteral(el))
                continue;
            if (!el.type || el.type.toBasetype().ty == Terror)
                return ipFallback(e, "tuple");
            el = ipSubExpr(el);
            if (!el)
                return null;
        }
        auto nte = new TupleExp(te.loc, exps);
        nte.type = te.type;
        return nte;
    }
    if (!e.type)
        return ipFallback(e, "expr type");
    if (auto ne = e.isNotExp())
        if (ne.e1.isTypeExp())
            return IntegerExp.createBool(false);
    if (auto r = ipFoldConstVars(e))
        return r;
    if (auto ae = e.isAddrExp())
        if (ae.e1.isThisExp())
            return e;
    if (ipIsArrayOpNode(e))
    {
        auto lowered = ipLowerArrayOp(e);
        if (!lowered)
        {
            if (auto be = e.isBinExp())
                if (mode != WasmCtfeMode.verify)
                    if (auto r = ipReportStringArrayOp(be))
                        return r;
            return ipFallback(e, "expr unsupported [array binop]");
        }
        return ipSubExpr(lowered);
    }
    if (auto ie = e.isIdentityExp())
    {
        auto te1 = ie.e1.isTypeidExp();
        auto te2 = ie.e2.isTypeidExp();
        if (te1 && te2)
        {
            import dmd.dtemplate : isType;
            Type t1 = isType(te1.obj);
            Type t2 = isType(te2.obj);
            if (t1 && t2)
                return new IntegerExp(e.loc, (ie.op == EXP.identity) == (t1 is t2), e.type);
        }
    }
    if (auto r = ipFoldOptimize(e))
        return r;
    if (wasmCtfeIsLiteral(e))
        return null;
    if (!ipHasCall(e))
    {
        if (auto r = ipFoldLiteralCompare(e))
            return r;
    }
    else if (ipTreeFoldable(e))
    {
        import dmd.ctfeexpr : copyLiteral;
        import dmd.typesem : equivalent;
        auto r = ipFoldTree(e);
        if (r && r.isErrorExp())
            return r;
        if (r && equivalent(r.type, e.type))
        {
            r = copyLiteral(r).copy();
            r.type = e.type;
            return r;
        }
    }
    const isNoreturn = e.type.toBasetype().isTypeNoreturn() !is null;
    const discard = !ipResultType(e.type) && e.type.toBasetype().ty != Tvoid && !isNoreturn;
    char[160] typeWhy = void;
    if (discard)
    {
        snprintf(typeWhy.ptr, typeWhy.length, "expr type [%s]", e.type.toChars());
        if (mode == WasmCtfeMode.verify)
            return ipFallback(e, typeWhy.ptr);
    }
    const voidWrap = isNoreturn || discard;
    const(char)* unsupportedWhy;
    VarDeclarations declaredVars;
    VarDeclarations enclosingVars;
    VarDeclaration badVar;
    Expression failAt;
    if (!ipExprSupported(e, unsupportedWhy, &declaredVars, &enclosingVars, &badVar, &failAt))
    {
        if (mode != WasmCtfeMode.verify)
        {
            if (failAt && (failAt.op == EXP.this_ || failAt.op == EXP.super_))
            {
                global.errorSink.error(failAt.loc, "value of `this` is not known at compile time");
                return ErrorExp.get();
            }
            if (auto be = failAt ? failAt.isBinExp() : null)
                if (auto r = ipReportStringArrayOp(be))
                    return r;
            if (auto ce = failAt ? failAt.isCallExp() : null)
            {
                import dmd.hdrgen : toErrMsg;
                global.errorSink.error(ce.loc, "cannot call `%s` at compile time", ce.toErrMsg());
                return ErrorExp.get();
            }
            if (badVar)
                return ipReportUnreadable(e, badVar);
        }
        char[96] rb = void;
        snprintf(rb.ptr, rb.length, "expr unsupported [%s]", unsupportedWhy ? unsupportedWhy : "?".ptr);
        return ipFallback(e, rb.ptr);
    }
    auto mod = Module.rootModule;
    if (!mod)
        return ipFallback(e, "no root module");
    OutBuffer kb;
    kb.writestring("expr:");
    kb.writestring(e.loc.toChars());
    kb.writeByte(0);
    ipAppendExpKey(e, kb);
    if (auto sv = ipCacheFind(kb[]))
        return sv.value;
    auto tf = new TypeFunction(ParameterList(), voidWrap ? Type.tvoid : e.type, LINK.d);
    auto fd = new FuncDeclaration(e.loc, e.loc, Identifier.generateId("__wasmctfe_expr"), STC.none, tf);
    fd.parent = mod;
    fd._linkage = LINK.d;
    Statement ret = voidWrap ? new ExpStatement(e.loc, e) : new ReturnStatement(e.loc, e);
    if (enclosingVars.length)
    {
        auto cs = new CompoundStatement(e.loc);
        foreach (vd; enclosingVars)
            cs.statements.push(new ExpStatement(e.loc, new DeclarationExp(e.loc, vd)));
        cs.statements.push(ret);
        ret = cs;
    }
    fd.fbody = ret;
    fd.semanticRun = PASS.semantic3done;
    Dsymbols savedParents;
    foreach (vd; declaredVars)
    {
        savedParents.push(vd.parent);
        vd.parent = fd;
        vd.isdataseg = 0;
    }
    foreach (vd; enclosingVars)
    {
        savedParents.push(vd.parent);
        vd.parent = fd;
    }
    const writesBefore = ipCtfeWrites;
    auto savedDiscard = ipDiscardFd;
    if (discard)
        ipDiscardFd = fd;
    auto r = tryWasmCtfeInproc(fd, null, null, voidWrap ? Type.tvoid : e.type, e.loc);
    ipDiscardFd = savedDiscard;
    if (voidWrap && r && !r.isErrorExp())
        r = null;
    if (discard && !r)
        r = ipFallback(e, typeWhy.ptr);
    foreach (i, vd; declaredVars)
    {
        vd.parent = savedParents[i];
        vd.isdataseg = 0;
    }
    foreach (i, vd; enclosingVars)
        vd.parent = savedParents[declaredVars.length + i];
    ipCacheStore(kb[], r, writesBefore);
    return r;
}

private:

bool scanLegality(FuncDeclaration fd)
{
    bool[void*] inProgress;
    return scanLegalityImpl(fd, inProgress) == 1;
}

private void ipInitConstInitializer(VarDeclaration v)
{
    import dmd.initsem : initializerSemantic;
    import dmd.init : NeedInterpret;
    if (!v.type || !(v.type.isImmutable() || v.type.isConst()) || !v._init
        || v._init.semanticDone || !v._scope || v.inuse)
        return;
    auto old = v._init;
    const errs = global.startGagging();
    v.inuse++;
    auto ni = v._init.initializerSemantic(v._scope, v.type, NeedInterpret.INITinterpret, global.errorSink);
    v.inuse--;
    if (global.endGagging(errs))
        v._init = old;
    else
        v._init = ni;
}

private TemplateInstance ipEnclosingInstance(Dsymbol s)
{
    for (Dsymbol p = s; p; p = p.parent)
        if (auto ti = p.isTemplateInstance())
            return ti;
    return null;
}

__gshared bool[void*] legalityVerdicts;
__gshared bool[void*] forcedSem3Errors;

private void ipTypeInfoMember(ref FuncDeclaration fd, FuncDeclaration errFd)
{
    if (fd && fd._scope && fd.semanticRun < PASS.semantic3done && ipForceSemantic3Gagged(fd, true))
        fd = errFd;
}

public bool ipForceSemantic3Gagged(FuncDeclaration fd, bool keepGag = false)
{
    const oldGag = global.startGagging();
    const savedSuspend = buildActiveSuspended;
    buildActiveSuspended = 0;
    ++preSemDepth;
    ipForceSemantic3(fd, keepGag);
    --preSemDepth;
    buildActiveSuspended = savedSuspend;
    return global.endGagging(oldGag);
}

public void ipForceSemantic3(FuncDeclaration fd, bool keepGag = false)
{
    if (fd.semanticRun >= PASS.semantic3done)
        return;
    auto fdMod = fd.getModule();
    auto ti = ipEnclosingInstance(fd);
    const hostRooted = ti ? ti.minst !is null : fdMod && fdMod.isRoot();
    if (hostRooted)
        ++buildActiveSuspended;
    if ((keepGag || fd.deferred3) && fd._scope && fd.semanticRun < PASS.semantic3)
    {
        import dmd.semantic3 : semantic3;
        const oldGag = global.gag;
        if (!keepGag)
            global.gag = 0;
        semantic3(fd, fd._scope);
        global.gag = oldGag;
    }
    else
        fd.functionSemantic3();
    if (hostRooted)
        --buildActiveSuspended;
    if (fd.errors || fd.hasSemantic3Errors)
        forcedSem3Errors[cast(void*) fd] = true;
}

public bool wasmCtfeTakeForcedSem3Error(FuncDeclaration fd)
{
    return forcedSem3Errors.remove(cast(void*) fd);
}

int scanLegalityImpl(FuncDeclaration fd, ref bool[void*] inProgress)
{
    auto key = cast(void*) fd;
    if (auto p = key in legalityVerdicts)
        return *p;
    if (key in inProgress)
        return 1;
    inProgress[key] = true;

    int settle(bool ok)
    {
        legalityVerdicts[key] = ok;
        return ok;
    }

    int pending()
    {
        inProgress.remove(key);
        return 2;
    }

    if (trustedModule(fd) || wasmCtfeHostBuiltin(fd)
        || fd.semanticRun >= PASS.semantic3done && fd.hasSemantic3Errors)
        return settle(true);
    if (!fd.fbody || fd.errors)
        return settle(!fd.errors);
    if (fd.semanticRun < PASS.semantic3done)
    {
        auto ti = ipEnclosingInstance(fd);
        if (!ti || ti.semanticRun >= PASS.semanticdone && !ti.errors)
            ipForceSemantic3(fd);
    }
    if (fd.semanticRun < PASS.semantic3done)
        return pending();
    if (fd.hasSemantic3Errors)
        return settle(true);
    Module mod = fd.getModule();
    if (!mod || !mod.srcfile.toChars())
        return settle(false);

    scope scanner = new LegalityScanner();
    fd.fbody.accept(scanner);
    if (scanner.bad)
    {
        if (verbose && scanner.why)
            fprintf(stderr, "wasm-ctfe: reject %s: %s\n", fd.toPrettyChars(), scanner.why);
        return settle(false);
    }
    foreach (callee; scanner.callees)
    {
        const cv = scanLegalityImpl(callee, inProgress);
        if (cv == 1)
            continue;
        if (verbose)
            fprintf(stderr, "wasm-ctfe: reject %s: callee %s%s\n", fd.toPrettyChars(), callee.toPrettyChars(), cv == 2 ? " (pending)".ptr : "".ptr);
        return cv == 2 ? pending() : settle(false);
    }
    return settle(true);
}

__gshared bool[void*] overlapVerdicts;

public bool hasOverlaps(StructDeclaration sd)
{
    if (!sd)
        return false;
    auto key = cast(void*) sd;
    if (auto p = key in overlapVerdicts)
        return *p;
    overlapVerdicts[key] = false;

    bool compute()
    {
        if (sd.isUnionDeclaration())
            return true;
        foreach (v; sd.fields)
        {
            if (v.overlapped)
                return true;
            auto tb = v.type ? v.type.toBasetype() : null;
            while (tb && (tb.ty == Tarray || tb.ty == Tsarray))
                tb = tb.nextOf().toBasetype();
            if (tb && tb.ty == Tstruct && hasOverlaps(tb.isTypeStruct().sym))
                return true;
        }
        return false;
    }

    const result = compute();
    overlapVerdicts[key] = result;
    return result;
}

private __gshared bool[Module] ipTrustedModules;

public bool trustedModule(Dsymbol fd)
{
    Module mod = fd.getModule();
    if (!mod)
        return false;
    if (auto p = mod in ipTrustedModules)
        return *p;
    return ipTrustedModules[mod] = ipTrustedName(mod.toPrettyChars().toDString());
}

private bool ipTrustedName(const(char)[] name)
{
    static immutable string[] trusted = [
        "core.internal.", "core.lifetime", "core.math", "core.bitop",
        "core.checkedint", "core.int128", "object", "rt.",
    ];
    foreach (t; trusted)
        if (name.startsWith(t) && (t[$ - 1] == '.' || name.length == t.length || name[t.length] == '.'))
            return true;
    return false;
}

private bool ipStaticVar(VarDeclaration v)
{
    return v.isDataseg() && !(v.storage_class & (STC.manifest | STC.temp));
}

private bool ipMutableStatic(VarDeclaration v)
{
    return v.type && !v.type.isImmutable() && !v.type.isConst() && !ipZeroSizeArray(v.type);
}

extern (C++) class CalleeScanner : SemanticTimeTransitiveVisitor
{
    alias visit = SemanticTimeTransitiveVisitor.visit;

    bool bad;
    FuncDeclarations callees;

    override void visit(CallExp e)
    {
        if (bad)
            return;
        FuncDeclaration f = e.f;
        if (!f)
        {
            if (auto dve = e.e1.isDotVarExp())
                f = dve.var.isFuncDeclaration();
            else if (auto ve = e.e1.isVarExp())
                f = ve.var.isFuncDeclaration();
        }
        if (f)
            callees.push(f);
        super.visit(e);
    }

    override void visit(LogicalExp e)
    {
        if (bad)
            return;
        const c = ipCtfeCond(e.e1);
        if ((e.op == EXP.orOr && c > 0) || (e.op == EXP.andAnd && c < 0))
            return;
        super.visit(e);
    }

    override void visit(CondExp e)
    {
        if (bad)
            return;
        if (const c = ipCtfeCond(e.econd))
        {
            (c > 0 ? e.e1 : e.e2).accept(this);
            return;
        }
        super.visit(e);
    }

    override void visit(IfStatement s)
    {
        const c = ipCtfeCond(s.condition);
        if (!c)
            return super.visit(s);
        if (auto live = c > 0 ? s.ifbody : s.elsebody)
            live.accept(this);
    }

    override void visit(StructDeclaration) {}
    override void visit(UnionDeclaration) {}
    override void visit(ClassDeclaration) {}
    override void visit(InterfaceDeclaration) {}
    override void visit(TemplateDeclaration) {}
    override void visit(AliasDeclaration) {}
    override void visit(AliasAssign) {}

    override void visit(NewExp e)
    {
        if (bad)
            return;
        if (e.member)
            callees.push(e.member);
        if (e.arguments)
            foreach (arg; *e.arguments)
                if (arg)
                    arg.accept(this);
        if (e.lowering)
            e.lowering.accept(this);
    }
}

private __gshared bool[void*] preSemSeen;

extern (C++) final class PreSemScanner : CalleeScanner
{
    alias visit = CalleeScanner.visit;

    private void dataRef(FuncDeclaration f)
    {
        if (f && f.semanticRun >= PASS.semantic3done)
            callees.push(f);
    }

    private bool seen(Dsymbol s)
    {
        if (cast(void*) s in preSemSeen)
            return true;
        preSemSeen[cast(void*) s] = true;
        return false;
    }

    private void visitType(Type t)
    {
        if (!t)
            return;
        auto tb = t.toBasetype();
        while (tb.ty == Tarray || tb.ty == Tsarray)
            tb = tb.nextOf().toBasetype();
        if (auto ts = tb.isTypeStruct())
        {
            auto sd = ts.sym;
            if (seen(sd))
                return;
            ipTypeInfoMember(sd.xeq, sd.xerreq);
            ipTypeInfoMember(sd.xcmp, sd.xerrcmp);
            foreach (f; [sd.xhash, sd.xeq, sd.xcmp, sd.tidtor, sd.postblit])
                if (f)
                    callees.push(f);
        }
        else if (auto tc = tb.isTypeClass())
        {
            for (auto cd = tc.sym; cd && !seen(cd); cd = cd.baseClass)
            {
                foreach (m; cd.vtbl[])
                    dataRef(m.isFuncDeclaration());
                dataRef(cd.tidtor);
                dataRef(cd.defaultCtor);
                dataRef(cd.inv);
            }
        }
    }

    private void visitSymbol(Declaration d)
    {
        if (!d)
            return;
        if (auto f = d.isFuncDeclaration())
        {
            callees.push(f);
            return;
        }
        auto v = d.isVarDeclaration();
        if (v && v._init && ipStaticVar(v) && !seen(v))
            v._init.accept(this);
    }

    override void visit(VarExp e) { visitSymbol(e.var); }
    override void visit(SymOffExp e) { visitSymbol(e.var); }
    override void visit(FuncExp e) { visitSymbol(e.fd); }

    override void visit(DelegateExp e)
    {
        visitSymbol(e.func);
        super.visit(e);
    }

    override void visit(TypeidExp e)
    {
        import dmd.dtemplate : isType;
        visitType(isType(e.obj));
        super.visit(e);
    }

    override void visit(NewExp e)
    {
        visitType(e.newtype);
        super.visit(e);
    }

    override void visit(Catch c)
    {
        visitType(c.type);
        super.visit(c);
    }

    private void visitLowered(E)(E e)
    {
        if (e.lowering)
            e.lowering.accept(this);
        super.visit(e);
    }

    override void visit(CatExp e) { visitLowered(e); }
    override void visit(CatAssignExp e) { visitLowered(e); }
    override void visit(CatElemAssignExp e) { visitLowered(e); }
    override void visit(CatDcharAssignExp e) { visitLowered(e); }
    override void visit(LoweredAssignExp e) { visitLowered(e); }
    override void visit(ConstructExp e) { visitLowered(e); }
    override void visit(EqualExp e) { visitLowered(e); }
    override void visit(ArrayLiteralExp e) { visitLowered(e); }
    override void visit(AssocArrayLiteralExp e) { visitLowered(e); }

    override void visit(CastExp e)
    {
        visitType(e.to);
        visitLowered(e);
    }
}

public void wasmCtfeDirectCallees(FuncDeclaration fd, ref FuncDeclarations callees)
{
    scope scanner = new PreSemScanner();
    fd.fbody.accept(scanner);
    callees.append(&scanner.callees);
}

extern (C++) final class LegalityScanner : CalleeScanner
{
    alias visit = CalleeScanner.visit;

    const(char)* why;

    void reject(const(char)* reason)
    {
        bad = true;
        if (!why)
            why = reason;
    }

    override void visit(VarExp e)
    {
        if (bad)
            return;
        if (e.var && e.var.ident == Id.ctfe)
            return;
        if (auto v = e.var ? e.var.isVarDeclaration() : null)
        {
            if (auto ie = wasmCtfeDollarInit(v))
            {
                ie.accept(this);
                return;
            }
            if (ipStaticVar(v))
            {
                ipInitConstInitializer(v);
                if (ipMutableStatic(v))
                {
                    if (!ipNotePoisonGlobal(v))
                        reject("mutable global");
                    return;
                }
                if (v.inuse && v._init && !trustedModule(v))
                {
                    ipCircularVars[v] = true;
                    return;
                }
                if ((!v.type || !v._init || !v._init.semanticDone) && !ipZeroSizeArray(v.type))
                {
                    if (!v.type || !ipNotePoisonGlobal(v))
                        reject("mutable global");
                    return;
                }
                if (v.type && v.type.isImmutable())
                    ipNoteAddrGlobal(v);
            }
        }
    }

    override void visit(VarDeclaration v)
    {
        if (bad)
            return;
        if (v.storage_class & STC.manifest)
            return;
        if (v.semanticRun < PASS.semanticdone)
        {
            if (wasmCtfeTraceGen)
                fprintf(stderr, "wasm-ctfe unresolved declaration %s at %s run=%d\n", v.toChars(), v.loc.toChars(), cast(int) v.semanticRun);
            reject("unresolved declaration");
            return;
        }
        if (ipStaticVar(v))
        {
            if (ipMutableStatic(v))
            {
                if (!ipNotePoisonGlobal(v))
                    reject("static local");
            }
            else if ((!v.type || !v._init || !v._init.semanticDone) && !ipZeroSizeArray(v.type))
            {
                reject("static local");
                return;
            }
        }
        if (v._init)
            v._init.accept(this);
    }

    override void visit(SymOffExp e)
    {
        if (auto v = e.var ? e.var.isVarDeclaration() : null)
            if (ipStaticVar(v))
            {
                if (v.type && !v.type.isImmutable() && !v.type.isConst() && !ipNotePoisonGlobal(v))
                    reject("address of global");
                ipNoteAddrGlobal(v);
            }
    }

    override void visit(AsmStatement s)
    {
        reject("inline asm");
    }

    override void visit(GccAsmStatement s)
    {
        reject("gcc asm");
    }

    override void visit(ErrorStatement s)
    {
        reject("error statement");
    }

    override void visit(ErrorExp e)
    {
        reject("error expression");
    }
}

private __gshared
{
    import dmd.wasmtimec;
    import dmd.backend.wasm.selflink : WasmDataExtent, WasmImportInfo;
    import dmd.backend.wasm.obj : WasmSite;

    wasm_engine_t* ipEngine;

    enum HostKind : ubyte { fixed, stub, errorFunc, lazy_, noBody, unknown }

    struct IpHost
    {
        HostImport* hi;
        wasmtime_func_callback_t cb;
        HostKind kind;
        bool committed;
        bool direct;
        uint slot;
    }

    struct IpRoot
    {
        wasmtime_func_t func;
        bool temp;
        uint id;
        size_t imageLen;
        size_t extents;
        size_t poisonExtents;
        ulong prevOrders;
        ulong[] vtbls;
    }

    struct IpProgram
    {
        wasmtime_store_t* store;
        wasmtime_context_t* ctx;
        wasmtime_linker_t* linker;
        wasmtime_memory_t mem;
        wasmtime_table_t table;
        wasmtime_global_t sp;
        ulong memEnd;
        ulong tableSize;
        uint tableNext;
        uint dataEnd;
        uint liveEnd;
        uint poisonNext;
        ubyte[] image;
        uint[string] dataSyms;
        uint[string] slots;
        IpHost*[const(char)[]] hosts;
        FuncDeclaration[const(char)[]] funcs;
        WasmSite[][] sites;
        IpRoot*[void*] roots;
        bool flushPending;
        bool running;
    }

    IpProgram ipProg;
    enum uint ipStackLow = 0x1_0000;

    enum IpErrKind : ubyte { none, index, nullp, slice, assert_, assertMsg, errorFunc, uncaught, siteError }
    IpErrKind ipErrKind;
    ulong[3] ipErrVals;
    char[512] ipErrMsg;
    size_t ipErrMsgLen;
}

private enum CAlloc : ubyte
{
    malloc,
    calloc,
    realloc,
}

private struct HostImport
{
    char[128] name;
    size_t nameLen;
    SR softOp;
    FuncDeclaration fd;
    CAlloc cAlloc;
    const(char)* stubWhy;
    bool noBody;
}

private extern (C) wasm_trap_t* ipHostStubbed(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    auto hi = cast(HostImport*) env;
    return ipTrap(hi.stubWhy);
}

private __gshared FuncDeclaration ipLazyHit;
private __gshared FuncDeclaration ipErrFunc;

private extern (C) wasm_trap_t* ipHostErrorFunc(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    auto hi = cast(HostImport*) env;
    ipErrKind = IpErrKind.errorFunc;
    ipErrFunc = hi.fd;
    ipErrNoBody = hi.noBody;
    return ipTrap(hi.noBody ? "$nobody$callee has no body" : "$sem3$callee has semantic errors");
}

private __gshared bool ipErrNoBody;

private extern (C) wasm_trap_t* ipHostLazy(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    auto hi = cast(HostImport*) env;
    ipLazyHit = hi.fd;
    return ipTrap("wasm-ctfe: virtual function needs semantic");
}

public __gshared FuncDeclaration[const(char)[]] wasmCtfeBuiltinFds;

public bool wasmCtfeCppDowncast(ClassDeclaration from, ClassDeclaration to)
{
    return from.classKind == ClassKind.cpp && to.classKind == ClassKind.cpp
        && !from.isInterfaceDeclaration() && !to.isInterfaceDeclaration();
}

public bool wasmCtfeHostBuiltin(FuncDeclaration fd)
{
    return isBuiltin(fd) != BUILTIN.unimp;
}

private extern (C) wasm_trap_t* ipHostAppend(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    wasmtime_memory_t m;
    if (!ipCallerMemory(caller, m) || nargs != 4)
        return ipTrap("wasm-ctfe: append signature");
    auto mem = ipMemSlice(caller, m);
    const dst = ipValP(args[0]);
    const src = ipValP(args[1]);
    const esz = ipValP(args[2]);
    const isElem = ipValP(args[3]) != 0;
    if (dst > mem.length || 2 * ipPS > mem.length - dst || src > mem.length)
        return ipTrap("wasm-ctfe: append out of bounds");
    ulong n, sptr;
    ulong len = ipLdP(mem.ptr + dst);
    ulong ptr = ipLdP(mem.ptr + dst + ipPS);
    if (isElem)
    {
        n = 1;
        sptr = src;
    }
    else
    {
        if (2 * ipPS > mem.length - src)
            return ipTrap("wasm-ctfe: append out of bounds");
        n = ipLdP(mem.ptr + src);
        sptr = ipLdP(mem.ptr + src + ipPS);
    }
    if (esz && (len > (1UL << 40) / esz || n > (1UL << 40) / esz))
        return ipTrap("wasm-ctfe: append too large");
    const oldBytes = len * esz, addBytes = n * esz;
    if (ptr > mem.length || oldBytes > mem.length - ptr || sptr > mem.length || addBytes > mem.length - sptr)
        return ipTrap("wasm-ctfe: append out of bounds");
    ulong r;
    if (auto trap = ipGrowArray(caller, m, ptr, oldBytes, addBytes, r))
        return trap;
    mem = ipMemSlice(caller, m);
    memmove(mem.ptr + r + oldBytes, mem.ptr + sptr, cast(size_t) addBytes);
    ipTagCopy(r + oldBytes, sptr, addBytes);
    const nlen = len + n;
    ipStP(mem.ptr + dst, nlen);
    ipStP(mem.ptr + dst + ipPS, r);
    return null;
}

private __gshared size_t ipCtfeWrites;

private StringValue!(Expression)* ipCacheFind(const(char)[] key)
{
    auto sv = ipResultCache.lookup(key);
    if (sv)
        wasmCtfeStats.cacheHits++;
    return sv;
}

private void ipCacheStore(const(char)[] key, Expression r, size_t writesBefore)
{
    if (writesBefore == ipCtfeWrites)
        if (auto sv = ipResultCache.insert(key, null))
            sv.value = r;
}

private extern (C) wasm_trap_t* ipHostCtfeWrite(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    if (ipReplayAt || ipDiscardRun)
        return null;
    wasmtime_memory_t m;
    if (!ipCallerMemory(caller, m))
        return ipTrap("wasm-ctfe: no memory export");
    auto mem = ipMemSlice(caller, m);
    ulong len, ptr;
    if (nargs == 2)
    {
        len = ipValP(args[0]);
        ptr = ipValP(args[1]);
    }
    else if (nargs == 1)
    {
        const a = ipValP(args[0]);
        if (a > mem.length || 2 * ipPS > mem.length - a)
            return ipTrap("wasm-ctfe: __ctfeWrite out of bounds");
        len = ipLdP(mem.ptr + a);
        ptr = ipLdP(mem.ptr + a + ipPS);
    }
    else
        return ipTrap("wasm-ctfe: __ctfeWrite signature");
    if (ptr > mem.length || len > mem.length - ptr)
        return ipTrap("wasm-ctfe: __ctfeWrite out of bounds");
    ipCtfeWrites++;
    if (mode != WasmCtfeMode.verify)
        fprintf(stderr, "%.*s", cast(int) len, cast(const(char)*) mem.ptr + ptr);
    return null;
}

private extern (C) wasm_trap_t* ipHostBuiltin(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    alias Impl = wasm_trap_t* function(HostImport*, const(wasmtime_val_t)*, size_t, wasmtime_val_t*, size_t) nothrow @nogc;
    return (cast(Impl) &ipHostBuiltinImpl)(cast(HostImport*) env, args, nargs, results, nresults);
}

private wasm_trap_t* ipHostBuiltinImpl(HostImport* hi, const(wasmtime_val_t)* args, size_t nargs,
    wasmtime_val_t* results, size_t nresults)
{
    import dmd.builtin : eval_builtin;
    auto fd = hi.fd;
    auto tf = fd.type.isTypeFunction();
    const n = tf.parameterList.length;
    if (n != nargs)
        return ipTrap("wasm-ctfe: builtin arity");
    auto exps = new Expressions(n);
    foreach (i, p; tf.parameterList)
    {
        wasmtime_val_t v = args[i];
        auto e = ipDecodeScalar(v, p.type, fd.loc);
        if (!e)
            return ipTrap("wasm-ctfe: builtin argument");
        (*exps)[i] = e;
    }
    auto r = eval_builtin(fd.loc, fd, exps);
    if (!r)
        return nresults ? ipTrap("wasm-ctfe: builtin failed") : null;
    if (nresults && !ipMarshalScalar(r, results[0]))
        return ipTrap("wasm-ctfe: builtin result");
    return null;
}

private int ipRealRelop(int op, real a, real b) nothrow @nogc
{
    import dmd.backend.oper;
    if (a != a || b != b)
        return rel_unord(op);
    const iop = rel_integral(op);
    switch (iop)
    {
        case OPeqeq: return a == b;
        case OPne: return a != b;
        case OPlt: return a < b;
        case OPle: return a <= b;
        case OPgt: return a > b;
        case OPge: return a >= b;
        default: return iop;
    }
}

private extern (C) wasm_trap_t* ipHostSoftReal(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    static import core.math;
    auto hi = cast(HostImport*) env;
    static real ar(ref const wasmtime_val_t v) { return ipLdReal(v.of.v128.ptr); }
    void setR(real r) { ipSetReal(results[0], r); }
    void setL(long v)
    {
        results[0].kind = WASMTIME_I64;
        results[0].of.i64 = v;
    }
    void setI(int v)
    {
        results[0].kind = WASMTIME_I32;
        results[0].of.i32 = v;
    }
    final switch (hi.softOp)
    {
        case SR.add: setR(ar(args[0]) + ar(args[1])); break;
        case SR.sub: setR(ar(args[0]) - ar(args[1])); break;
        case SR.mul: setR(ar(args[0]) * ar(args[1])); break;
        case SR.div: setR(ar(args[0]) / ar(args[1])); break;
        case SR.mod: setR(ar(args[0]) % ar(args[1])); break;
        case SR.neg: setR(-ar(args[0])); break;
        case SR.abs: setR(CTFloat.fabs(ar(args[0]))); break;
        case SR.sqrt: setR(CTFloat.sqrt(ar(args[0]))); break;
        case SR.sin: setR(CTFloat.sin(ar(args[0]))); break;
        case SR.cos: setR(CTFloat.cos(ar(args[0]))); break;
        case SR.rint: setR(core.math.rint(ar(args[0]))); break;
        case SR.rndtol: setL(core.math.rndtol(ar(args[0]))); break;
        case SR.yl2x:
        case SR.yl2xp1:
        {
            const x = ar(args[0]);
            const y = ar(args[1]);
            real r;
            if (hi.softOp == SR.yl2x)
                CTFloat.yl2x(&x, &y, &r);
            else
                CTFloat.yl2xp1(&x, &y, &r);
            setR(r);
            break;
        }
        case SR.scale: setR(CTFloat.ldexp(ar(args[0]), args[1].of.i32)); break;
        case SR.cmp: setI(ipRealRelop(args[2].of.i32, ar(args[0]), ar(args[1]))); break;
        case SR.fromF64: setR(args[0].of.f64); break;
        case SR.toF64:
            results[0].kind = WASMTIME_F64;
            results[0].of.f64 = cast(double) ar(args[0]);
            break;
        case SR.fromI64: setR(cast(real) args[0].of.i64); break;
        case SR.fromU64: setR(cast(real) ipValP(args[0])); break;
        case SR.toI64: setL(cast(long) ar(args[0])); break;
        case SR.toU64: setL(cast(long) cast(ulong) ar(args[0])); break;
        case SR.toI32: setI(cast(int) ar(args[0])); break;
        case SR.toU32: setI(cast(int) cast(uint) ar(args[0])); break;
    }
    return null;
}

private extern (C) wasm_trap_t* ipHostLibm(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    static import core.math;
    import core.stdc.math : log1pl, log2l;
    auto hi = cast(HostImport*) env;
    const f32 = args[0].kind == WASMTIME_F32;
    real x = f32 ? args[0].of.f32 : args[0].of.f64;
    real r;
    switch (hi.softOp)
    {
        case SR.sin: r = CTFloat.sin(x); break;
        case SR.cos: r = CTFloat.cos(x); break;
        case SR.mod: r = x % (f32 ? args[1].of.f32 : args[1].of.f64); break;
        case SR.scale: r = CTFloat.ldexp(x, args[1].of.i32); break;
        case SR.rint: r = core.math.rint(x); break;
        case SR.yl2x: r = log2l(x); break;
        case SR.yl2xp1: r = log1pl(x); break;
        case SR.rndtol:
            results[0].kind = WASMTIME_I64;
            results[0].of.i64 = core.math.rndtol(x);
            return null;
        default: assert(0);
    }
    results[0].kind = args[0].kind;
    if (f32)
        results[0].of.f32 = cast(float) r;
    else
        results[0].of.f64 = cast(double) r;
    return null;
}

private immutable string[8] ipLibmNames = ["sin", "cos", "fmod", "ldexp", "rint", "llrint", "log2", "log1p"];
private immutable SR[8] ipLibmOps = [SR.sin, SR.cos, SR.mod, SR.scale, SR.rint, SR.rndtol, SR.yl2x, SR.yl2xp1];

private extern (C) wasm_trap_t* ipHostStub(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    auto hi = cast(HostImport*) env;
    return ipTrapf("wasm-ctfe: unimplemented runtime call %.*s", cast(int) hi.nameLen, hi.name.ptr);
}

private __gshared
{
    ulong ipHeapPtr;
    ulong ipHeapEnd;
    ulong ipErrnoCell;
    Barray!IpAlloc ipAllocs;
}

private struct IpAlloc
{
    ulong base, size, used;
}

private void ipRecordAlloc(ulong base, ulong sz) nothrow @nogc
{
    ipAllocs.push(IpAlloc(base, sz, sz));
}

private IpAlloc* ipAllocAt(ulong p) nothrow @nogc
{
    size_t lo = 0, hi = ipAllocs.length;
    while (lo < hi)
    {
        const mid = (lo + hi) / 2;
        if (ipAllocs[mid].base <= p)
            lo = mid + 1;
        else
            hi = mid;
    }
    return lo ? &ipAllocs[lo - 1] : null;
}

private int ipCtfeCond(Expression e)
{
    int sign = 1;
    while (auto ne = e.isNotExp())
    {
        sign = -sign;
        e = ne.e1;
    }
    if (auto ve = e.isVarExp())
        if (ve.var.ident == Id.ctfe)
            return sign;
    if (auto le = e.isLogicalExp())
    {
        const a = ipCtfeCond(le.e1);
        if (le.op == EXP.orOr && a > 0)
            return sign;
        if (le.op == EXP.andAnd && a < 0)
            return -sign;
    }
    return 0;
}

private __gshared VarDeclaration[string] ipAddrGlobals;

private __gshared string[VarDeclaration] ipAddrNoted;

private string ipNoteAddrGlobal(VarDeclaration v)
{
    if (auto p = v in ipAddrNoted)
        return *p;
    OutBuffer buf;
    mangleToBuffer(v, buf);
    auto m = cast(string) buf.extractSlice();
    ipAddrNoted[v] = m;
    ipAddrGlobals[m] = v;
    return m;
}

public enum CtfeSiteErr : uint
{
    none,
    staticRead,
    circularInit,
    switchNoCase,
    sliceCopy,
    reinterpretSlice,
    addrConvert,
    reinterpretPtr,
    importedAddr,
    nullThrow,
    arrayCast,
    noreturnCast,
    initSymAddr,
    hexStringLen,
    initErrors,
    circularNew,
    ptrToInt,
    placementNew,
    typeidField,
    noReturnValue,
    ptrSliceBounds,
    nullSliceBounds,
    unionReinterpret,
    shiftRange,
}

private __gshared bool[VarDeclaration] ipPoisonNoted;
private __gshared bool[VarDeclaration] ipCircularVars;
private __gshared bool ipCircularUsed;

public void wasmCtfeNoteExternGlobal(VarDeclaration v)
{
    import dmd.backend.wasm.selflink : wasmSelfLinkPoisonNames;
    ipPoisonNoted[v] = true;
    wasmSelfLinkPoisonNames[ipNoteAddrGlobal(v)] = true;
}

public CtfeSiteErr wasmCtfeUnreadableVar(VarDeclaration v)
{
    if (v in ipPoisonNoted || v.storage_class & STC.extern_)
        return CtfeSiteErr.staticRead;
    if (v.inuse && v in ipCircularVars)
    {
        ipCircularUsed = true;
        return CtfeSiteErr.circularInit;
    }
    return CtfeSiteErr.none;
}

public __gshared Expression wasmCtfeCastExempt;

public bool wasmCtfeFloatIntPaint(PtrExp e)
{
    import dmd.ctfeexpr : isFloatIntPaint;
    if (auto soe1 = e.e1.isSymOffExp())
        return soe1.offset == 0 && soe1.var.isVarDeclaration() && isFloatIntPaint(e.type, soe1.var.type);
    if (auto ce1 = e.e1.isCastExp())
        if (auto ae11 = ce1.e1.isAddrExp())
            return isFloatIntPaint(e.type, ae11.e1.type);
    return false;
}

public CtfeSiteErr wasmCtfeBadPointerCast(Expression e, FuncDeclaration fd)
{
    import dmd.astenums : FileType;
    if (e is wasmCtfeCastExempt)
        return CtfeSiteErr.none;
    if (fd && (trustedModule(fd) || fd.isGenerated()))
        return CtfeSiteErr.none;
    if (fd && fd.getModule() && fd.getModule().filetype == FileType.c)
        return CtfeSiteErr.none;
    Type a, b;
    return ipBadPointerCast(e, a, b);
}

private CtfeSiteErr ipBadPointerCast(Expression e, out Type from, out Type to)
{
    import dmd.ctfeexpr : isSafePointerCast, isTypeInfo_Class;
    import dmd.typesem : isIntegral, mutableOf, unSharedOf, baseElemOf;
    if (auto soe = e.isSymOffExp())
    {
        auto var = soe.var;
        if (var.isFuncDeclaration() && soe.offset == 0)
            return CtfeSiteErr.none;
        if (isTypeInfo_Class(soe.type) && soe.offset == 0)
            return CtfeSiteErr.none;
        if (soe.type.ty != Tpointer || var.isThreadlocal())
            return CtfeSiteErr.none;
        Type pointee = soe.type.nextOf();
        Type vt = var.type;
        Type fromType = vt.isStaticOrDynamicArray() ? vt.nextOf() : null;
        if (var.isDataseg() && ((soe.offset == 0 && isSafePointerCast(vt, pointee)) ||
                                (fromType && isSafePointerCast(fromType, pointee)) ||
                                (var.isCsymbol() && soe.offset + pointee.size() <= vt.size())))
            return CtfeSiteErr.none;
        from = vt;
        to = soe.type;
        if (fromType)
        {
            if (vt.ty == Tsarray && pointee.ty == Tsarray && fromType.size() == pointee.nextOf().size())
                return CtfeSiteErr.none;
            if (isSafePointerCast(fromType, pointee) || (soe.offset == 0 && isSafePointerCast(vt, pointee)))
                return CtfeSiteErr.none;
            return CtfeSiteErr.reinterpretSlice;
        }
        return soe.offset == 0 && isSafePointerCast(vt, pointee) ? CtfeSiteErr.none : CtfeSiteErr.addrConvert;
    }
    auto ce = e.isCastExp();
    if (!ce)
        return CtfeSiteErr.none;
    auto e1 = ce.e1;
    if (e1.type && e1.type.toBasetype().isTypeNoreturn() && ce.to.ty != Tvoid && !ce.to.toBasetype().isTypeNoreturn()
        && !e1.isCallExp() && !e1.isThrowExp() && !e1.isAssertExp() && !e1.isHaltExp() && !e1.isCommaExp() && !e1.isCondExp())
    {
        from = e1.type;
        to = ce.to;
        return CtfeSiteErr.noreturnCast;
    }
    if ((ce.to.ty == Tarray || ce.to.ty == Tsarray) && e1.type && e1.type.isStaticOrDynamicArray() && e1.op != EXP.null_)
    {
        Type ft = e1.type.nextOf();
        Type tt = ce.to.nextOf();
        auto se = e1.isStringExp();
        if (se && se.hexString && se.postfix == StringExp.NoPostfix && tt.isIntegral())
        {
            if (!isSafePointerCast(ft, tt) && se.len % cast(size_t) tt.size() != 0)
            {
                from = e1.type;
                to = ce.to;
                return CtfeSiteErr.hexStringLen;
            }
            return CtfeSiteErr.none;
        }
        if (ft.ty != Tvoid && !isSafePointerCast(ft, tt)
            && !ft.mutableOf().unSharedOf().equals(tt.mutableOf().unSharedOf()))
        {
            from = e1.type;
            if (auto sle = e1.isSliceExp())
                from = sle.e1.type;
            to = ce.to;
            return CtfeSiteErr.arrayCast;
        }
        return CtfeSiteErr.none;
    }
    if (!ce.lowering && e1.type && e1.type.toBasetype().ty == Tpointer && e1.op != EXP.null_
        && ce.to.toBasetype().isIntegral() && ce.to.toBasetype().ty != Tbool)
    {
        from = e1.type;
        to = ce.to;
        return CtfeSiteErr.ptrToInt;
    }
    if (ce.lowering || ce.to.ty != Tpointer || ce.type.ty != Tpointer)
        return CtfeSiteErr.none;
    if (e1.op == EXP.null_ || e1.isIntegerExp())
        return CtfeSiteErr.none;
    Type t1 = e1.type;
    if (!t1.isStaticOrDynamicArray() && t1.ty != Tpointer)
        return CtfeSiteErr.none;
    Type pointee = ce.type.nextOf();
    Type elemtype = t1.nextOf();
    if (auto se = e1.isSliceExp())
        elemtype = se.e1.type.nextOf();
    Type up = pointee;
    Type us = elemtype;
    while (up.ty == Tpointer && us.ty == Tpointer)
    {
        up = up.nextOf();
        us = us.nextOf();
    }
    if (up.ty == Tsarray && up.nextOf().equivalent(us))
        return CtfeSiteErr.none;
    if (us.ty == Tsarray && us.baseElemOf().mutableOf().unSharedOf().equals(up.baseElemOf().mutableOf().unSharedOf()))
        return CtfeSiteErr.none;
    if (up.ty == Tvoid || us.ty == Tvoid || isSafePointerCast(elemtype, pointee))
        return CtfeSiteErr.none;
    from = elemtype;
    to = pointee;
    return CtfeSiteErr.reinterpretPtr;
}

private __gshared bool[AggregateDeclaration] ipInitErrors;

public bool wasmCtfeInitErrors(AggregateDeclaration ad)
{
    if (auto p = ad in ipInitErrors)
        return *p;
    const gag = global.startGagging();
    auto e = ad.type.defaultInitLiteral(ad.loc);
    global.endGagging(gag);
    const bad = !e || e.op == EXP.error;
    ipInitErrors[ad] = bad;
    return bad;
}

public VarDeclaration wasmCtfeNewCircular(NewExp e)
{
    auto tc = e.newtype ? e.newtype.toBasetype().isTypeClass() : null;
    if (!tc)
        return null;
    for (ClassDeclaration c = tc.sym; c; c = c.baseClass)
        foreach (v; c.fields)
            if (v.inuse)
            {
                ipCircularVars[v] = true;
                ipCircularUsed = true;
                return v;
            }
    return null;
}

private bool ipNotePoisonGlobal(VarDeclaration v)
{
    import dmd.backend.wasm.selflink : wasmSelfLinkPoisonNames, wasmSelfLinkPoisonBase;
    if (v in ipPoisonNoted)
        return true;
    if (trustedModule(v))
        return false;
    ipPoisonNoted[v] = true;
    const name = ipNoteAddrGlobal(v);
    wasmSelfLinkPoisonNames[name] = true;
    if (auto p = name in ipProg.dataSyms)
        if (*p < wasmSelfLinkPoisonBase)
            ipProg.flushPending = true;
    return true;
}

private bool ipFindData(ulong p, out ulong base, out ulong sz, out const(char)[] name) nothrow @nogc
{
    import dmd.backend.wasm.selflink : wasmSelfLinkPoisonBase;
    const exts = p >= wasmSelfLinkPoisonBase ? ipPoisonExtents : ipDataExtents;
    size_t lo = 0, hi = exts.length;
    while (lo < hi)
    {
        const mid = (lo + hi) / 2;
        if (exts[mid].start <= p)
            lo = mid + 1;
        else
            hi = mid;
    }
    if (lo == 0)
        return false;
    const ext = exts[lo - 1];
    base = ext.start;
    sz = ext.size;
    name = ext.name;
    return p < base + sz;
}

private bool ipZeroSizeArray(Type t)
{
    auto tsa = t ? t.toBasetype().isTypeSArray() : null;
    return tsa && tsa.dim && tsa.dim.isIntegerExp() && tsa.dim.toInteger() == 0;
}

private bool ipAllZero(const(ubyte)[] b) nothrow @nogc
{
    foreach (x; b)
        if (x)
            return false;
    return true;
}

private bool ipFindAlloc(ulong p, out ulong base, out ulong sz) nothrow @nogc
{
    auto a = ipAllocAt(p);
    if (!a)
        return false;
    base = a.base;
    sz = a.size;
    return p < base + sz || p == base;
}

private wasm_trap_t* ipTrap(const(char)* msg) nothrow @nogc
{
    return wasmtime_trap_new(msg, strlen(msg));
}

private __gshared uint ipPS = 8;

private ulong ipValP(ref const wasmtime_val_t v) nothrow @nogc
{
    return v.kind == WASMTIME_I32 ? cast(ulong) cast(uint) v.of.i32 : cast(ulong) v.of.i64;
}

private void ipSetReal(ref wasmtime_val_t v, real r) nothrow @nogc
{
    v.kind = WASMTIME_V128;
    v.of.v128[] = 0;
    memcpy(v.of.v128.ptr, &r, 10);
}

private void ipSetP(ref wasmtime_val_t v, ulong x) nothrow @nogc
{
    if (ipPS == 4)
    {
        v.kind = WASMTIME_I32;
        v.of.i32 = cast(int) cast(uint) x;
    }
    else
    {
        v.kind = WASMTIME_I64;
        v.of.i64 = cast(long) x;
    }
}

private bool ipIsP(ref const wasmtime_val_t v) nothrow @nogc
{
    return v.kind == (ipPS == 4 ? WASMTIME_I32 : WASMTIME_I64);
}

private ulong ipLdP(const(ubyte)* p) nothrow @nogc
{
    ulong v = 0;
    memcpy(&v, p, ipPS);
    return v;
}

private bool ipRdP(const(ubyte)[] mem, ulong addr, out ulong v) nothrow @nogc
{
    if (addr > mem.length || ipPS > mem.length - addr)
        return false;
    v = ipLdP(mem.ptr + addr);
    return true;
}

private void ipStP(ubyte* p, ulong v) nothrow @nogc
{
    memcpy(p, &v, ipPS);
}

private bool ipCallerMemory(wasmtime_caller_t* caller, out wasmtime_memory_t m) nothrow @nogc
{
    m = ipProg.mem;
    return true;
}

private bool ipGrowMemory(ulong end) nothrow @nogc
{
    if (end <= ipProg.memEnd)
        return true;
    const need = ((end - ipProg.memEnd + 0xFFFF) >> 16) + 16;
    const eighth = ipProg.memEnd >> 19;
    ulong pages = need > eighth ? need : eighth;
    ulong prev;
    auto err = wasmtime_memory_grow(ipProg.ctx, &ipProg.mem, pages, &prev);
    if (err && pages != need)
    {
        wasmtime_error_delete(err);
        pages = need;
        err = wasmtime_memory_grow(ipProg.ctx, &ipProg.mem, pages, &prev);
    }
    if (err)
    {
        wasmtime_error_delete(err);
        return false;
    }
    ipProg.memEnd = (prev + pages) << 16;
    return true;
}

private bool ipHeapEnsure(ulong sz) nothrow @nogc
{
    if (ipHeapPtr + sz <= ipHeapEnd)
        return true;
    if (!ipGrowMemory(ipHeapPtr + sz))
        return false;
    ipHeapEnd = ipProg.memEnd;
    return true;
}

private wasm_trap_t* ipBumpAlloc(wasmtime_caller_t* caller, ref wasmtime_memory_t m, ulong sz, out ulong r) nothrow @nogc
{
    const reqSz = sz;
    sz = ipAlign16(sz);
    if (!sz)
        sz = 16;
    if (sz > (1UL << 32))
        return ipTrap("wasm-ctfe: allocation too large");
    if (!ipHeapEnsure(sz))
        return ipTrap("wasm-ctfe: out of memory");
    r = ipHeapPtr;
    ipHeapPtr += sz;
    ipRecordAlloc(r, reqSz);
    return null;
}

private extern (C) wasm_trap_t* ipHostGcMalloc(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    wasmtime_memory_t m;
    if (!ipCallerMemory(caller, m))
        return ipTrap("wasm-ctfe: no memory export");
    ulong r;
    if (auto trap = ipBumpAlloc(caller, m, ipValP(args[0]), r))
        return trap;
    ipSetP(results[0], r);
    return null;
}

private extern (C) wasm_trap_t* ipHostCAlloc(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    auto hi = cast(HostImport*) env;
    wasmtime_memory_t m;
    if (!ipCallerMemory(caller, m))
        return ipTrap("wasm-ctfe: no memory export");
    ulong old, oldSz, sz;
    final switch (hi.cAlloc)
    {
    case CAlloc.malloc:
        sz = ipValP(args[0]);
        break;
    case CAlloc.calloc:
        sz = ipValP(args[0]) * ipValP(args[1]);
        break;
    case CAlloc.realloc:
        old = ipValP(args[0]);
        sz = ipValP(args[1]);
        ulong base;
        if (old && (!ipFindAlloc(old, base, oldSz) || base != old))
            return ipTrap("wasm-ctfe: realloc of unknown pointer");
        break;
    }
    ulong r;
    if (auto trap = ipBumpAlloc(caller, m, sz, r))
        return trap;
    if (old)
    {
        auto mem = ipMemSlice(caller, m);
        memcpy(mem.ptr + r, mem.ptr + old, cast(size_t) (oldSz < sz ? oldSz : sz));
        ipTagCopy(r, old, oldSz < sz ? oldSz : sz);
    }
    ipSetP(results[0], r);
    return null;
}

private extern (C) wasm_trap_t* ipHostErrno(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    wasmtime_memory_t m;
    if (!ipCallerMemory(caller, m))
        return ipTrap("wasm-ctfe: no memory export");
    if (!ipErrnoCell)
        if (auto trap = ipBumpAlloc(caller, m, 4, ipErrnoCell))
            return trap;
    ipSetP(results[0], ipErrnoCell);
    return null;
}

private wasm_trap_t* ipCallTable(wasmtime_caller_t* caller, ulong idx, const(wasmtime_val_t)[] args,
    wasmtime_val_t[] results, const(char)* failMsg) nothrow @nogc
{
    auto ctx = wasmtime_caller_context(caller);
    wasmtime_val_t fv;
    if (!wasmtime_table_get(ctx, &ipProg.table, idx, &fv) || fv.kind != WASMTIME_FUNCREF)
        return ipTrap(failMsg);
    wasm_trap_t* trap;
    if (auto err = wasmtime_func_call(ctx, &fv.of.funcref, args.ptr, args.length, results.ptr, results.length, &trap))
    {
        wasmtime_error_delete(err);
        return ipTrap(failMsg);
    }
    return trap;
}

private extern (C) wasm_trap_t* ipHostAApply(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    import dmd.root.utf;
    auto hi = cast(HostImport*) env;
    const nm = hi.name[0 .. hi.nameLen];
    const rev = nm[7] == 'R';
    const sc = nm[rev ? 8 : 7];
    const dc = nm[rev ? 9 : 8];
    const two = nm[$ - 1] == '2';
    const int sw = sc == 'c' ? 1 : sc == 'w' ? 2 : 4;
    const int dw = dc == 'c' ? 1 : dc == 'w' ? 2 : 4;
    const len = cast(size_t) ipValP(args[0]);
    const ptr = ipValP(args[1]);
    const dctx = ipValP(args[2]);
    const fidx = ipValP(args[3]);
    wasmtime_memory_t m;
    if (!ipCallerMemory(caller, m))
        return ipTrap("wasm-ctfe: no memory export");
    ulong tmp;
    if (auto trap = ipBumpAlloc(caller, m, 16, tmp))
        return trap;
    {
        auto mem = ipMemSlice(caller, m);
        if (ptr > mem.length || len * sw > mem.length - ptr)
            return ipTrap("wasm-ctfe: foreach string out of bounds");
    }
    size_t pos = rev ? len : 0;
    int result = 0;
    while (!result && (rev ? pos > 0 : pos < len))
    {
        auto mem = ipMemSlice(caller, m);
        auto str = mem.ptr + cast(size_t) ptr;
        size_t start = pos;
        if (rev)
        {
            start = pos - 1;
            if (sw == 1)
                while (start > 0 && (str[start] & 0xC0) == 0x80 && pos - start < 4)
                    start--;
            else if (sw == 2)
            {
                const u = (cast(const(wchar)*) str)[start];
                if (u >= 0xDC00 && u <= 0xDFFF && start > 0)
                    start--;
            }
        }
        size_t next = start;
        dchar c;
        bool ok;
        if (sw == 1)
            ok = utf_decodeChar((cast(const(char)*) str)[0 .. len], next, c) is null;
        else if (sw == 2)
            ok = utf_decodeWchar((cast(const(wchar)*) str)[0 .. len], next, c) is null;
        else
        {
            c = (cast(const(dchar)*) str)[next++];
            ok = utf_isValidDchar(c);
        }
        if (!ok || (rev && next != pos))
            return ipTrap("wasm-ctfe: invalid UTF sequence in foreach");
        dchar[4] units;
        utf_encode(dw, units.ptr, c);
        foreach (k; 0 .. utf_codeLength(dw, c))
        {
            mem = ipMemSlice(caller, m);
            ipStP(mem.ptr + tmp, start);
            memcpy(mem.ptr + tmp + 8, cast(ubyte*) units.ptr + k * dw, dw);
            wasmtime_val_t[3] cargs;
            ipSetP(cargs[0], dctx);
            size_t na = 1;
            if (two)
                ipSetP(cargs[na++], tmp);
            ipSetP(cargs[na++], tmp + 8);
            wasmtime_val_t[1] res;
            if (auto trap = ipCallTable(caller, fidx, cargs[0 .. na], res[], "wasm-ctfe: foreach body call failed"))
                return trap;
            result = res[0].of.i32;
            if (result)
                break;
        }
        pos = rev ? start : next;
    }
    results[0].kind = WASMTIME_I32;
    results[0].of.i32 = result;
    return null;
}

private __gshared ulong ipTIBaseOffset;
private __gshared ulong ipTINameOffset;
private __gshared ulong ipTIInvOffset;

private ulong ipFieldOffset(ClassDeclaration cd, string name) nothrow
{
    if (cd)
        foreach (v; cd.fields)
            if (v.ident && v.ident.toString() == name)
                return v.offset;
    return 0;
}

private void ipComputeTIOffsets() nothrow
{
    if (ipTIBaseOffset || ipTINameOffset)
        return;
    auto cd = Type.typeinfoclass;
    ipTIBaseOffset = ipFieldOffset(cd, "base");
    ipTINameOffset = ipFieldOffset(cd, "name");
    ipTIInvOffset = ipFieldOffset(cd, "classInvariant");
}

private __gshared ulong ipThrowNextOffset;
private __gshared ulong ipErrorBypassOffset;

private void ipComputeThrowOffsets() nothrow
{
    ipComputeTIOffsets();
    if (ipThrowNextOffset)
        return;
    ipThrowNextOffset = ipFieldOffset(ClassDeclaration.throwable, "_nextInChainPtr");
    ipErrorBypassOffset = ipFieldOffset(ClassDeclaration.errorException, "bypassedException");
}

private __gshared bool ipDiscardRun;
private __gshared FuncDeclaration ipDiscardFd;
private __gshared uint ipThrowCount;
private __gshared uint ipReplayAt;
private __gshared uint ipReplayPending;

private extern (C) wasm_trap_t* ipHostThrow(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    ipSetP(results[0], ipValP(args[0]));
    if (!ipValP(args[0]))
        return ipSiteTrap(CtfeSiteErr.nullThrow, cast(uint) args[1].of.i32);
    ++ipThrowCount;
    if (ipReplayAt && ipThrowCount == ipReplayAt)
    {
        ipErrKind = IpErrKind.uncaught;
        ipErrVals[0] = ipValP(args[0]);
        ipErrVals[1] = cast(uint) args[1].of.i32;
        return ipTrap("$uncaught$");
    }
    return null;
}

private __gshared ulong[4] ipErrArgs;

private wasm_trap_t* ipSiteTrap(CtfeSiteErr kind, uint site) nothrow @nogc
{
    ipErrKind = IpErrKind.siteError;
    ipErrVals[0] = kind;
    ipErrVals[1] = site;
    return ipTrap("$site$");
}

private extern (C) wasm_trap_t* ipHostSiteError(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    ipErrArgs[] = 0;
    foreach (i; 2 .. nargs)
        ipErrArgs[i - 2] = ipValP(args[i]);
    return ipSiteTrap(cast(CtfeSiteErr) args[0].of.i32, cast(uint) args[1].of.i32);
}

private struct IpUnionInfo
{
    VarDeclaration v;
    AggregateDeclaration ad;
    uint site;
    ulong size;
    ulong off;
    ulong aggSize;
    ulong[] ptrOffs;
    bool known;
}

private __gshared IpUnionInfo[] ipUnionInfos;
private __gshared bool[VarDeclaration] ipMixedCache;

private struct IpUnionTag
{
    ulong addr;
    uint info;
}

private __gshared IpUnionTag* ipUnionTags;
private __gshared size_t ipUnionTagCount;
private __gshared size_t ipUnionTagCap;

private size_t ipTagLower(ulong addr) nothrow @nogc
{
    size_t lo = 0, hi = ipUnionTagCount;
    while (lo < hi)
    {
        const mid = (lo + hi) / 2;
        if (ipUnionTags[mid].addr < addr)
            lo = mid + 1;
        else
            hi = mid;
    }
    return lo;
}

private bool ipTagReserve(size_t n) nothrow @nogc
{
    if (ipUnionTagCount + n <= ipUnionTagCap)
        return true;
    size_t cap = ipUnionTagCap ? ipUnionTagCap : 64;
    while (cap < ipUnionTagCount + n)
        cap *= 2;
    auto p = cast(IpUnionTag*) realloc(ipUnionTags, cap * IpUnionTag.sizeof);
    if (!p)
        return false;
    ipUnionTags = p;
    ipUnionTagCap = cap;
    return true;
}

private void ipTagCut(size_t a, size_t b) nothrow @nogc
{
    memmove(ipUnionTags + a, ipUnionTags + b, (ipUnionTagCount - b) * IpUnionTag.sizeof);
    ipUnionTagCount -= b - a;
}

private void ipTagClear(ulong lo, ulong hi) nothrow @nogc
{
    if (ipUnionTagCount && lo < hi)
        ipTagCut(ipTagLower(lo), ipTagLower(hi));
}

private void ipTagInsert(ulong addr, uint info) nothrow @nogc
{
    if (!ipTagReserve(1))
        return;
    const i = ipTagLower(addr + 1);
    memmove(ipUnionTags + i + 1, ipUnionTags + i, (ipUnionTagCount - i) * IpUnionTag.sizeof);
    ipUnionTags[i] = IpUnionTag(addr, info);
    ipUnionTagCount++;
}

private void ipTagCopy(ulong dst, ulong src, ulong n) nothrow @nogc
{
    if (!ipUnionTagCount || dst == src || !n)
        return;
    const a = ipTagLower(src);
    const k = ipTagLower(src + n) - a;
    if (!k)
    {
        ipTagClear(dst, dst + n);
        return;
    }
    auto saved = cast(IpUnionTag*) malloc(k * IpUnionTag.sizeof);
    if (!saved)
        return;
    memcpy(saved, ipUnionTags + a, k * IpUnionTag.sizeof);
    ipTagClear(dst, dst + n);
    if (ipTagReserve(k))
    {
        const i = ipTagLower(dst);
        memmove(ipUnionTags + i + k, ipUnionTags + i, (ipUnionTagCount - i) * IpUnionTag.sizeof);
        foreach (j; 0 .. k)
            ipUnionTags[i + j] = IpUnionTag(saved[j].addr - src + dst, saved[j].info);
        ipUnionTagCount += k;
    }
    free(saved);
}

private void ipTagFill(ulong dst, ulong src, ulong sz, ulong n) nothrow @nogc
{
    if (!ipUnionTagCount)
        return;
    if (ipTagLower(src) == ipTagLower(src + sz))
    {
        ipTagClear(dst, dst + n * sz);
        return;
    }
    foreach (i; 0 .. n)
        ipTagCopy(dst + i * sz, src, sz);
}

private bool ipTagSibling(const(IpUnionInfo)* w, ulong wa, const(IpUnionInfo)* v, ulong va) nothrow @nogc
{
    return w.ad is v.ad && w.v !is v.v && wa - w.off == va - v.off
        && w.off < v.off + v.size && v.off < w.off + w.size;
}

private bool ipTagged(ulong addr, VarDeclaration v) nothrow @nogc
{
    for (size_t i = ipTagLower(addr); i < ipUnionTagCount && ipUnionTags[i].addr == addr; i++)
        if (ipUnionInfos[ipUnionTags[i].info].v is v)
            return true;
    return false;
}

private bool ipPtrOffsets(Type t, ulong base, ref ulong[] offs)
{
    import dmd.typesem : size, hasPointers;
    auto tb = t.toBasetype();
    if (offs.length > 256)
        return false;
    switch (tb.ty)
    {
        case Tpointer, Tclass, Taarray, Tnull:
            offs ~= base;
            return true;
        case Tarray:
            offs ~= base + ipPS;
            return true;
        case Tdelegate:
            offs ~= base;
            offs ~= base + ipPS;
            return true;
        case Tsarray:
        {
            auto tsa = tb.isTypeSArray();
            if (!tsa.next.hasPointers())
                return true;
            const n = tsa.dim.toInteger();
            const es = tsa.next.size();
            if (n > 64)
                return false;
            foreach (i; 0 .. n)
                if (!ipPtrOffsets(tsa.next, base + i * es, offs))
                    return false;
            return true;
        }
        case Tstruct:
        {
            auto sd = tb.isTypeStruct().sym;
            ulong[] tmp;
            foreach (f; sd.fields)
                if (!ipPtrOffsets(f.type, base + f.offset, tmp))
                    return false;
            foreach (i; 1 .. tmp.length)
                for (size_t j = i; j > 0 && tmp[j - 1] > tmp[j]; j--)
                {
                    const x = tmp[j];
                    tmp[j] = tmp[j - 1];
                    tmp[j - 1] = x;
                }
            foreach (i, o; tmp)
                if (i == 0 || tmp[i - 1] != o)
                    offs ~= o;
            return true;
        }
        default:
            return true;
    }
}

public bool wasmCtfeMixedOverlap(VarDeclaration v)
{
    import dmd.typesem : hasPointers, size;
    if (!v.overlapped)
        return false;
    if (auto p = v in ipMixedCache)
        return *p;
    bool mixed;
    auto ad = v.isMember2();
    if (ad)
    {
        const vs = v.type.size();
        const vp = v.type.hasPointers();
        foreach (w; ad.fields)
        {
            if (w is v)
                continue;
            const ws = w.type.size();
            if (w.offset >= v.offset + vs || v.offset >= w.offset + ws)
                continue;
            const wp = w.type.hasPointers();
            if (!vp && !wp)
                continue;
            ulong[] pv, pw;
            bool okv = ipPtrOffsets(v.type, v.offset, pv);
            bool okw = ipPtrOffsets(w.type, w.offset, pw);
            const lo = v.offset > w.offset ? v.offset : w.offset;
            const hi = v.offset + vs < w.offset + ws ? v.offset + vs : w.offset + ws;
            ulong[] rv, rw;
            foreach (o; pv)
                if (o >= lo && o < hi)
                    rv ~= o;
            foreach (o; pw)
                if (o >= lo && o < hi)
                    rw ~= o;
            if (!okv || !okw || rv != rw)
            {
                mixed = true;
                break;
            }
        }
    }
    ipMixedCache[v] = mixed;
    return mixed;
}

public bool wasmCtfeHasUnion(Type t)
{
    auto tb = t.toBasetype();
    while (auto tsa = tb.isTypeSArray())
        tb = tsa.next.toBasetype();
    auto ts = tb.isTypeStruct();
    return ts && hasOverlaps(ts.sym);
}

public uint wasmCtfeUnionInfo(VarDeclaration v, uint site, ulong size)
{
    IpUnionInfo info;
    info.v = v;
    info.site = site;
    info.size = size;
    if (v)
    {
        info.known = ipPtrOffsets(v.type, 0, info.ptrOffs);
        info.ad = v.isMember2();
        info.off = v.offset;
        info.aggSize = info.ad ? info.ad.structsize : size;
    }
    ipUnionInfos ~= info;
    return cast(uint) (ipUnionInfos.length - 1);
}

private bool ipSamePtrLayout(ulong wa, const(IpUnionInfo)* w, ulong va, const(IpUnionInfo)* v) nothrow @nogc
{
    if (!w.known || !v.known)
        return false;
    const lo = wa > va ? wa : va;
    const hi = wa + w.size < va + v.size ? wa + w.size : va + v.size;
    size_t i, j;
    while (true)
    {
        while (i < w.ptrOffs.length && (wa + w.ptrOffs[i] < lo || wa + w.ptrOffs[i] >= hi))
            i++;
        while (j < v.ptrOffs.length && (va + v.ptrOffs[j] < lo || va + v.ptrOffs[j] >= hi))
            j++;
        if (i == w.ptrOffs.length || j == v.ptrOffs.length)
            return i == w.ptrOffs.length && j == v.ptrOffs.length;
        if (wa + w.ptrOffs[i] != va + v.ptrOffs[j])
            return false;
        i++;
        j++;
    }
}

private extern (C) wasm_trap_t* ipHostUnion(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    const idx = cast(uint) args[0].of.i32;
    const op = cast(uint) args[1].of.i32;
    const addr = ipValP(args[2]);
    if (idx >= ipUnionInfos.length)
        return null;
    auto info = &ipUnionInfos[idx];
    const end = addr + info.size;
    if (op == 2)
    {
        ipTagClear(addr, end);
        return null;
    }
    const base = addr - info.off;
    const i0 = ipTagLower(base), i1 = ipTagLower(base + info.aggSize);
    if (op == 0)
    {
        foreach (ref t; ipUnionTags[i0 .. i1])
        {
            auto w = &ipUnionInfos[t.info];
            if (ipTagSibling(w, t.addr, info, addr) && !ipSamePtrLayout(t.addr, w, addr, info))
                return ipSiteTrap(CtfeSiteErr.unionReinterpret, info.site);
        }
        return null;
    }
    size_t n = i0;
    foreach (i; i0 .. i1)
    {
        auto t = ipUnionTags[i];
        if ((t.addr >= addr && t.addr < end) || ipTagSibling(&ipUnionInfos[t.info], t.addr, info, addr))
            continue;
        ipUnionTags[n++] = t;
    }
    ipTagCut(n, i1);
    ipTagInsert(addr, idx);
    return null;
}

private extern (C) wasm_trap_t* ipHostUnionCopy(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    ipTagCopy(ipValP(args[0]), ipValP(args[1]), ipValP(args[2]));
    return null;
}

private extern (C) wasm_trap_t* ipHostPtrSlice(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    const esz = cast(uint) args[1].of.i32;
    const lwr = ipValP(args[2]);
    const upr = ipValP(args[3]);
    const p = ipValP(args[4]);
    if (!p || !esz)
        return null;
    ulong base, sz;
    if (!ipFindAlloc(p, base, sz))
    {
        const(char)[] name;
        if (!ipFindData(p, base, sz, name))
            return null;
        wasmtime_memory_t m;
        if (esz <= 4 && sz >= esz && ipCallerMemory(caller, m))
        {
            auto mem = ipMemSlice(caller, m);
            if (base + sz <= mem.length && ipAllZero(mem[cast(size_t) (base + sz - esz) .. cast(size_t) (base + sz)]))
                sz -= esz;
        }
    }
    if ((p - base) % esz)
        return null;
    const off = (p - base) / esz;
    const blen = sz / esz;
    if (upr <= blen - (off < blen ? off : blen) || lwr > upr)
        return null;
    ipErrArgs[0] = off + lwr;
    ipErrArgs[1] = off + upr;
    ipErrArgs[2] = blen;
    return ipSiteTrap(CtfeSiteErr.ptrSliceBounds, cast(uint) args[0].of.i32);
}

private extern (C) wasm_trap_t* ipHostCov(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    if (ipReplayAt || ipDiscardRun)
        return null;
    alias Impl = void function(uint, uint) nothrow @nogc;
    (cast(Impl) &ipCovInc)(cast(uint) args[0].of.i32, cast(uint) args[1].of.i32);
    return null;
}

private void ipCovInc(uint mod, uint line) nothrow
{
    import dmd.glue.tocsym : wasmCtfeCovModules;
    if (mod < wasmCtfeCovModules.length)
        ++wasmCtfeCovModules[mod].ctfe_cov[line];
}

private extern (C) wasm_trap_t* ipHostChain(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    const e1 = ipValP(args[0]);
    const e2 = ipValP(args[1]);
    ipSetP(results[0], e1 ? e1 : e2);
    if (!e1 || !e2)
        return null;
    if (!ipThrowNextOffset || !ipErrorBypassOffset || !ipTIBaseOffset || !ipTINameOffset)
        return ipTrap("wasm-ctfe: no Throwable layout");
    wasmtime_memory_t m;
    if (!ipCallerMemory(caller, m))
        return ipTrap("wasm-ctfe: no memory export");
    auto mem = ipMemSlice(caller, m);
    int isError(ulong o) nothrow @nogc
    {
        ulong vtbl, ci;
        if (!ipRdP(mem, o, vtbl) || !ipRdP(mem, vtbl, ci))
            return -1;
        enum name = "object.Error";
        while (ci)
        {
            ulong nlen, nptr;
            if (!ipRdP(mem, ci + ipTINameOffset, nlen) || !ipRdP(mem, ci + ipTINameOffset + ipPS, nptr))
                return -1;
            if (nlen == name.length && nptr <= mem.length - nlen
                && mem[cast(size_t) nptr .. cast(size_t) (nptr + nlen)] == name)
                return 1;
            if (!ipRdP(mem, ci + ipTIBaseOffset, ci))
                return -1;
        }
        return 0;
    }
    const err1 = isError(e1), err2 = isError(e2);
    if (err1 < 0 || err2 < 0)
        return ipTrap("wasm-ctfe: exception chaining out of bounds");
    if (err2 && !err1)
    {
        if (e2 + ipErrorBypassOffset + ipPS > mem.length)
            return ipTrap("wasm-ctfe: exception chaining out of bounds");
        ipStP(mem.ptr + e2 + ipErrorBypassOffset, e1);
        ipSetP(results[0], e2);
        return null;
    }
    ulong e = e1;
    foreach (_; 0 .. 1 << 20)
    {
        ulong next;
        if (!ipRdP(mem, e + ipThrowNextOffset, next))
            return ipTrap("wasm-ctfe: exception chaining out of bounds");
        next &= ~1UL;
        if (!next)
        {
            ipStP(mem.ptr + e + ipThrowNextOffset, e2);
            return null;
        }
        e = next;
    }
    return ipTrap("wasm-ctfe: exception chain too long");
}

private extern (C) wasm_trap_t* ipHostInvariant(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    const o = ipValP(args[0]);
    if (!o)
        return ipTrap("$null$null this in invariant check");
    if (!ipTIBaseOffset || !ipTIInvOffset)
        return ipTrap("wasm-ctfe: no ClassInfo layout");
    wasmtime_memory_t m;
    if (!ipCallerMemory(caller, m))
        return ipTrap("wasm-ctfe: no memory export");
    ulong vtbl, ci;
    if (!ipRdP(ipMemSlice(caller, m), o, vtbl) || !ipRdP(ipMemSlice(caller, m), vtbl, ci))
        return ipTrap("wasm-ctfe: invariant check out of bounds");
    while (ci)
    {
        ulong fidx;
        if (!ipRdP(ipMemSlice(caller, m), ci + ipTIInvOffset, fidx))
            return ipTrap("wasm-ctfe: invariant check out of bounds");
        if (fidx)
        {
            wasmtime_val_t[1] cargs;
            ipSetP(cargs[0], o);
            if (auto trap = ipCallTable(caller, fidx, cargs[], null, "wasm-ctfe: invariant call failed"))
                return trap;
        }
        if (!ipRdP(ipMemSlice(caller, m), ci + ipTIBaseOffset, ci))
            return ipTrap("wasm-ctfe: invariant check out of bounds");
    }
    return null;
}

private extern (C) wasm_trap_t* ipHostCppCast(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    alias Impl = wasm_trap_t* function(wasmtime_caller_t*, const(wasmtime_val_t)*, wasmtime_val_t*) nothrow @nogc;
    return (cast(Impl) &ipHostCppCastImpl)(caller, args, results);
}

private wasm_trap_t* ipHostCppCastImpl(wasmtime_caller_t* caller, const(wasmtime_val_t)* args, wasmtime_val_t* results)
{
    wasmtime_memory_t m;
    if (!ipCallerMemory(caller, m))
        return ipTrap("wasm-ctfe: no memory export");
    auto mem = ipMemSlice(caller, m);
    const o = ipValP(args[0]);
    ulong r = 0;
    if (o)
    {
        ulong vtbl;
        if (!ipRdP(mem, o, vtbl))
            return ipTrap("wasm-ctfe: cast out of bounds");
        auto dyn = vtbl in ipVtbls;
        auto to = ipValP(args[1]) in ipVtbls;
        if (!dyn || !to)
            return ipTrap("wasm-ctfe: unknown C++ class in cast");
        if (*dyn is *to || (*to).isBaseOf(*dyn, null))
            r = o;
    }
    ipSetP(results[0], r);
    return null;
}

private extern (C) wasm_trap_t* ipHostEhMatch(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    wasmtime_memory_t m;
    if (!ipCallerMemory(caller, m))
        return ipTrap("wasm-ctfe: no memory export");
    auto mem = ipMemSlice(caller, m);
    const o = ipValP(args[0]);
    const ci = ipValP(args[1]);
    int found = 0;
    if (o && ipTIBaseOffset)
    {
        ulong vtbl, oc;
        if (!ipRdP(mem, o, vtbl) || !ipRdP(mem, vtbl, oc))
            return ipTrap("wasm-ctfe: eh match out of bounds");
        while (oc)
        {
            if (oc == ci)
            {
                found = 1;
                break;
            }
            if (!ipRdP(mem, oc + ipTIBaseOffset, oc))
                return ipTrap("wasm-ctfe: eh match out of bounds");
        }
    }
    results[0].kind = WASMTIME_I32;
    results[0].of.i32 = found;
    return null;
}

private extern (C) wasm_trap_t* ipHostArrayAppendC(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    auto hi = cast(HostImport*) env;
    const wide = hi.name[0 .. hi.nameLen] == "_d_arrayappendwd";
    wasmtime_memory_t m;
    if (!ipCallerMemory(caller, m))
        return ipTrap("wasm-ctfe: no memory export");
    auto mem = ipMemSlice(caller, m);
    const sret = ipValP(args[0]);
    const xptr = ipValP(args[1]);
    const c = cast(uint) args[2].of.i32;
    if (xptr + 2 * ipPS > mem.length || sret + 2 * ipPS > mem.length)
        return ipTrap("wasm-ctfe: appendc out of bounds");
    ulong len = ipLdP(mem.ptr + xptr);
    ulong ptr = ipLdP(mem.ptr + xptr + ipPS);
    ubyte[4] enc;
    ulong n;
    if (wide)
    {
        auto w = cast(ushort*) enc.ptr;
        if (c <= 0xFFFF)
        {
            w[0] = cast(ushort) c;
            n = 1;
        }
        else
        {
            w[0] = cast(ushort)((((c - 0x10000) >> 10) & 0x3FF) + 0xD800);
            w[1] = cast(ushort)(((c - 0x10000) & 0x3FF) + 0xDC00);
            n = 2;
        }
    }
    else
    {
        if (c < 0x80)
        {
            enc[0] = cast(ubyte) c;
            n = 1;
        }
        else if (c < 0x800)
        {
            enc[0] = cast(ubyte)(0xC0 | (c >> 6));
            enc[1] = cast(ubyte)(0x80 | (c & 0x3F));
            n = 2;
        }
        else if (c < 0x10000)
        {
            enc[0] = cast(ubyte)(0xE0 | (c >> 12));
            enc[1] = cast(ubyte)(0x80 | ((c >> 6) & 0x3F));
            enc[2] = cast(ubyte)(0x80 | (c & 0x3F));
            n = 3;
        }
        else
        {
            enc[0] = cast(ubyte)(0xF0 | (c >> 18));
            enc[1] = cast(ubyte)(0x80 | ((c >> 12) & 0x3F));
            enc[2] = cast(ubyte)(0x80 | ((c >> 6) & 0x3F));
            enc[3] = cast(ubyte)(0x80 | (c & 0x3F));
            n = 4;
        }
    }
    const esz = wide ? 2 : 1;
    if (ptr + len * esz > mem.length)
        return ipTrap("wasm-ctfe: appendc out of bounds");
    ulong np;
    if (auto trap = ipGrowArray(caller, m, ptr, len * esz, n * esz, np))
        return trap;
    mem = ipMemSlice(caller, m);
    memcpy(mem.ptr + np + len * esz, enc.ptr, cast(size_t)(n * esz));
    ipStP(mem.ptr + xptr, len + n);
    ipStP(mem.ptr + xptr + ipPS, np);
    ipStP(mem.ptr + sret, len + n);
    ipStP(mem.ptr + sret + ipPS, np);
    return null;
}

private ubyte[] ipMemSlice(wasmtime_context_t* ctx, ref wasmtime_memory_t m) nothrow @nogc
{
    return wasmtime_memory_data(ctx, &m)[0 .. wasmtime_memory_data_size(ctx, &m)];
}

private ubyte[] ipMemSlice(wasmtime_caller_t* caller, ref wasmtime_memory_t m) nothrow @nogc
{
    return ipMemSlice(wasmtime_caller_context(caller), m);
}

private ubyte[] ipCallerMem(wasmtime_caller_t* caller) nothrow @nogc
{
    wasmtime_memory_t m;
    return ipCallerMemory(caller, m) ? ipMemSlice(caller, m) : null;
}

pragma(printf)
private extern (C) wasm_trap_t* ipTrapf(const(char)* fmt, ...) nothrow @nogc
{
    import core.stdc.stdarg : va_list, va_start, va_end;
    char[512] buf = void;
    va_list ap;
    va_start(ap, fmt);
    const n = vsnprintf(buf.ptr, buf.length, fmt, ap);
    va_end(ap);
    return wasmtime_trap_new(buf.ptr, cast(size_t) n < buf.length ? n : buf.length - 1);
}

private bool ipNullRange(ulong p, ulong n) nothrow @nogc
{
    return n && p < 4;
}

private extern (C) wasm_trap_t* ipHostMemset(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    wasmtime_memory_t m;
    if (!ipCallerMemory(caller, m))
        return ipTrap("wasm-ctfe: no memory export");
    auto mem = ipMemSlice(caller, m);
    const d = ipValP(args[0]);
    const c = args[1].of.i32;
    const n = ipValP(args[2]);
    if (d > mem.length || n > mem.length - d)
        return ipTrap("wasm-ctfe: memset out of bounds");
    if (ipNullRange(d, n))
        return ipTrap("$null$null pointer dereference");
    memset(mem.ptr + d, c, cast(size_t) n);
    ipTagClear(d, d + n);
    results[0] = args[0];
    return null;
}

private extern (C) wasm_trap_t* ipHostMemcpy(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    wasmtime_memory_t m;
    if (!ipCallerMemory(caller, m))
        return ipTrap("wasm-ctfe: no memory export");
    auto mem = ipMemSlice(caller, m);
    const d = ipValP(args[0]);
    const s = ipValP(args[1]);
    const n = ipValP(args[2]);
    if (d > mem.length || n > mem.length - d || s > mem.length || n > mem.length - s)
        return ipTrap("wasm-ctfe: memcpy out of bounds");
    if (ipNullRange(d, n) || ipNullRange(s, n))
        return ipTrap("$null$null pointer dereference");
    memmove(mem.ptr + d, mem.ptr + s, cast(size_t) n);
    ipTagCopy(d, s, n);
    results[0] = args[0];
    return null;
}

private extern (C) wasm_trap_t* ipHostMemsetn(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    wasmtime_memory_t m;
    if (!ipCallerMemory(caller, m))
        return ipTrap("wasm-ctfe: no memory export");
    auto mem = ipMemSlice(caller, m);
    const p = ipValP(args[0]);
    const v = ipValP(args[1]);
    const n = ipValP(args[2]);
    const sz = ipValP(args[3]);
    if (sz > mem.length || n > mem.length / (sz ? sz : 1)
        || p > mem.length || n * sz > mem.length - p
        || v > mem.length || sz > mem.length - v)
        return ipTrap("wasm-ctfe: memsetn out of bounds");
    if (ipNullRange(p, n * sz) || ipNullRange(v, sz))
        return ipTrap("$null$null pointer dereference");
    foreach (i; 0 .. n)
        memmove(mem.ptr + cast(size_t)(p + i * sz), mem.ptr + cast(size_t) v, cast(size_t) sz);
    ipTagFill(p, v, sz, n);
    results[0] = args[0];
    return null;
}

private extern (C) wasm_trap_t* ipHostMemsetT(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    wasmtime_memory_t m;
    if (!ipCallerMemory(caller, m))
        return ipTrap("wasm-ctfe: no memory export");
    auto mem = ipMemSlice(caller, m);
    const p = ipValP(args[0]);
    const n = ipValP(args[2]);
    ubyte[16] valbuf;
    size_t sz;
    switch (args[1].kind)
    {
        case WASMTIME_I32: sz = 4; memcpy(valbuf.ptr, &args[1].of.i32, 4); break;
        case WASMTIME_I64: sz = 8; memcpy(valbuf.ptr, &args[1].of.i64, 8); break;
        case WASMTIME_F32: sz = 4; memcpy(valbuf.ptr, &args[1].of.f32, 4); break;
        case WASMTIME_F64: sz = 8; memcpy(valbuf.ptr, &args[1].of.f64, 8); break;
        case WASMTIME_V128: sz = 16; memcpy(valbuf.ptr, args[1].of.v128.ptr, 16); break;
        default: return ipTrap("wasm-ctfe: memset value kind");
    }
    if (p > mem.length || n > (mem.length - p) / sz)
        return ipTrap("wasm-ctfe: memset out of bounds");
    if (ipNullRange(p, n * sz))
        return ipTrap("$null$null pointer dereference");
    foreach (i; 0 .. n)
        memcpy(mem.ptr + cast(size_t)(p + i * sz), valbuf.ptr, sz);
    ipTagClear(p, p + n * sz);
    results[0] = args[0];
    return null;
}

private extern (C) wasm_trap_t* ipHostMemcmp(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    wasmtime_memory_t m;
    if (!ipCallerMemory(caller, m))
        return ipTrap("wasm-ctfe: no memory export");
    auto mem = ipMemSlice(caller, m);
    const a = ipValP(args[0]);
    const b = ipValP(args[1]);
    const n = ipValP(args[2]);
    if (a > mem.length || n > mem.length - a || b > mem.length || n > mem.length - b)
        return ipTrap("wasm-ctfe: memcmp out of bounds");
    if (ipNullRange(a, n) || ipNullRange(b, n))
        return ipTrap("$null$null pointer dereference");
    results[0].kind = WASMTIME_I32;
    results[0].of.i32 = memcmp(mem.ptr + a, mem.ptr + b, cast(size_t) n);
    return null;
}

private IpAlloc* ipArrayBlock(ulong len, ulong ptr, out ulong off) nothrow @nogc
{
    auto a = ptr ? ipAllocAt(ptr) : null;
    if (!a)
        return null;
    off = ptr - a.base;
    return off < a.size && a.used == off + len ? a : null;
}

private bool ipSetUsed(ulong len, ulong ptr, ulong newLen) nothrow @nogc
{
    ulong off;
    auto a = ipArrayBlock(len, ptr, off);
    if (!a || newLen > a.size - off)
        return false;
    a.used = off + newLen;
    return true;
}

private wasm_trap_t* ipGrowArray(wasmtime_caller_t* caller, ref wasmtime_memory_t m,
    ulong ptr, ulong oldBytes, ulong addBytes, out ulong r) nothrow @nogc
{
    if (ipSetUsed(oldBytes, ptr, oldBytes + addBytes))
    {
        r = ptr;
        return null;
    }
    const need = oldBytes + addBytes;
    if (auto trap = ipBumpAlloc(caller, m, need + (need >> 1), r))
        return trap;
    ipAllocs[$ - 1].used = need;
    auto mem = ipMemSlice(caller, m);
    memmove(mem.ptr + r, mem.ptr + ptr, cast(size_t) oldBytes);
    ipTagCopy(r, ptr, oldBytes);
    return null;
}

private extern (C) wasm_trap_t* ipHostExpandArray(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    results[0].kind = WASMTIME_I32;
    results[0].of.i32 = ipSetUsed(ipValP(args[0]), ipValP(args[1]), ipValP(args[2]));
    return null;
}

private extern (C) wasm_trap_t* ipHostReserveArray(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    ulong off;
    auto a = ipArrayBlock(ipValP(args[0]), ipValP(args[1]), off);
    ulong cap = a ? a.size - off : 0;
    if (ipValP(args[2]) > cap)
        cap = 0;
    ipSetP(results[0], cap);
    return null;
}

private extern (C) wasm_trap_t* ipHostZero64(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    if (nresults)
        ipSetP(results[0], 0);
    return null;
}

private extern (C) wasm_trap_t* ipHostShrinkArray(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    results[0].kind = WASMTIME_I32;
    results[0].of.i32 = ipSetUsed(ipValP(args[2]), ipValP(args[1]), ipValP(args[0]));
    return null;
}

private extern (C) wasm_trap_t* ipHostGcQuery(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    wasmtime_memory_t m;
    if (!ipCallerMemory(caller, m))
        return ipTrap("wasm-ctfe: no memory export");
    auto mem = ipMemSlice(caller, m);
    const d = ipValP(args[0]);
    if (d > mem.length || 3 * ipPS > mem.length - d)
        return ipTrap("wasm-ctfe: gc_query out of bounds");
    memset(mem.ptr + d, 0, 3 * ipPS);
    return null;
}

private const(char)* ipMemString(ubyte[] mem, ulong addr) nothrow @nogc
{
    if (addr == 0 || addr >= mem.length)
        return "?".ptr;
    auto s = cast(const(char)*) mem.ptr + addr;
    return memchr(s, 0, cast(size_t)(mem.length - addr)) ? s : "?".ptr;
}

private extern (C) wasm_trap_t* ipHostBoundsIndex(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    auto mem = ipCallerMem(caller);
    ipErrKind = IpErrKind.index;
    ipErrVals[0] = ipValP(args[2]);
    ipErrVals[1] = ipValP(args[3]);
    return ipTrapf(
        "$bounds$%s(%d): array index %llu exceeds array length %llu",
        ipMemString(mem, ipValP(args[0])), args[1].of.i32,
        ipValP(args[2]), ipValP(args[3]));
}

private extern (C) wasm_trap_t* ipHostNullPointer(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    auto mem = ipCallerMem(caller);
    ipErrKind = IpErrKind.nullp;
    return ipTrapf(
        "$null$%s(%d): null pointer dereference",
        ipMemString(mem, ipValP(args[0])), args[1].of.i32);
}

private extern (C) wasm_trap_t* ipHostBoundsSlice(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    auto mem = ipCallerMem(caller);
    ipErrKind = IpErrKind.slice;
    ipErrVals[0] = ipValP(args[2]);
    ipErrVals[1] = ipValP(args[3]);
    ipErrVals[2] = ipValP(args[4]);
    return ipTrapf(
        "$bounds$%s(%d): slice [%llu..%llu] exceeds array bounds [0..%llu]",
        ipMemString(mem, ipValP(args[0])), args[1].of.i32,
        ipValP(args[2]), ipValP(args[3]), ipValP(args[4]));
}

private extern (C) wasm_trap_t* ipHostAssertStr(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    ipErrKind = IpErrKind.assert_;
    return ipTrap("$assert$assertion failure");
}

private extern (C) wasm_trap_t* ipHostAssert(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    auto mem = ipCallerMem(caller);
    ipErrKind = IpErrKind.assert_;
    return ipTrapf(
        "$assert$%s(%d): assertion failure",
        ipMemString(mem, ipValP(args[0])), args[1].of.i32);
}

private const(char)[] ipMemChars(const(ubyte)[] mem, ulong len, ulong ptr) nothrow @nogc
{
    if (ptr > mem.length || len > mem.length - ptr || len > 512)
        return "?";
    return cast(const(char)[]) mem[cast(size_t) ptr .. cast(size_t)(ptr + len)];
}

private extern (C) wasm_trap_t* ipHostBounds(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    auto mem = ipCallerMem(caller);
    const file = ipMemChars(mem, ipValP(args[0]), ipValP(args[1]));
    return ipTrapf(
        "$bounds$%.*s(%d): array index out of bounds",
        cast(int) file.length, file.ptr, args[2].of.i32);
}

private extern (C) wasm_trap_t* ipHostAssertMsg(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    auto mem = ipCallerMem(caller);
    const msg = ipMemChars(mem, ipValP(args[0]), ipValP(args[1]));
    const file = ipMemChars(mem, ipValP(args[2]), ipValP(args[3]));
    ipErrKind = IpErrKind.assertMsg;
    ipErrMsgLen = msg.length < ipErrMsg.length ? msg.length : ipErrMsg.length;
    ipErrMsg[0 .. ipErrMsgLen] = msg[0 .. ipErrMsgLen];
    return ipTrapf(
        "$assert$%.*s(%d): %.*s",
        cast(int) file.length, file.ptr, args[4].of.i32,
        cast(int) msg.length, msg.ptr);
}

private wasm_engine_t* ipGetEngine()
{
    if (ipEngine)
        return ipEngine;
    auto cfg = wasm_config_new();
    wasmtime_config_wasm_memory64_set(cfg, true);
    wasmtime_config_wasm_exceptions_set(cfg, true);
    wasmtime_config_memory_init_cow_set(cfg, false);
    ipEngine = wasm_engine_new_with_config(cfg);
    return ipEngine;
}

private void ipLogError(const(char)* what, FuncDeclaration fd, const(wasmtime_error_t)* err)
{
    if (!verbose)
        return;
    wasm_name_t msg;
    wasmtime_error_message(err, &msg);
    fprintf(stderr, "wasm-ctfe inproc: %s %s: %.*s\n", what, fd ? fd.toPrettyChars() : "".ptr,
        cast(int) msg.size, msg.data);
    wasm_byte_vec_delete(&msg);
}

version (linux) private extern (C) int madvise(void*, size_t, int) nothrow @nogc;

private uint ipStackHigh() nothrow @nogc
{
    import dmd.backend.wasm.selflink : wasmSelfLinkStackSize;
    return ipStackLow + wasmSelfLinkStackSize;
}

private ulong ipPageAlign(ulong x) nothrow @nogc
{
    return (x + 0xFFFF) & ~0xFFFFUL;
}

private void ipZeroRange(ubyte* mem, ulong lo, ulong hi) nothrow @nogc
{
    if (lo >= hi)
        return;
    version (linux)
    {
        import core.sys.linux.sys.mman : MADV_DONTNEED;
        const a = ipPageAlign(lo);
        const b = hi & ~0xFFFFUL;
        if (a < b && madvise(mem + a, cast(size_t)(b - a), MADV_DONTNEED) == 0)
        {
            memset(mem + lo, 0, cast(size_t)(a - lo));
            memset(mem + b, 0, cast(size_t)(hi - b));
            return;
        }
    }
    memset(mem + lo, 0, cast(size_t)(hi - lo));
}

private bool ipProgramInit()
{
    if (ipProg.store)
        return true;
    import dmd.backend.wasm.selflink : wasmSelfLinkPoisonBase;
    import dmd.target : target;
    ipPS = target.ptrsize;
    const bool m64 = ipPS == 8;
    const ubyte pt = m64 ? 0x7E : 0x7F;
    const stackHigh = ipStackHigh();

    static void section(ref OutBuffer o, ubyte id, ref OutBuffer s)
    {
        o.writeByte(id);
        o.writeuLEB128(cast(uint) s.length);
        o.write(s[]);
        s.reset();
    }

    static void exportEntry(ref OutBuffer s, string name, ubyte kind)
    {
        s.writeuLEB128(cast(uint) name.length);
        s.writestring(name);
        s.writeByte(kind);
        s.writeByte(0);
    }

    OutBuffer o, s;
    o.write("\0asm\x01\0\0\0");
    s.writeByte(1);
    s.writeByte(0x60);
    s.writeByte(1);
    s.writeByte(pt);
    s.writeByte(0);
    section(o, 1, s);
    s.writeByte(1);
    s.writeByte(0x70);
    s.writeByte(0);
    s.writeByte(1);
    section(o, 4, s);
    s.writeByte(1);
    s.writeByte(m64 ? 0x05 : 0x01);
    s.writeuLEB128((stackHigh >> 16) + 1);
    s.writeuLEB128(wasmSelfLinkPoisonBase >> 16);
    section(o, 5, s);
    s.writeByte(1);
    s.writeByte(0);
    s.writeByte(0);
    section(o, 13, s);
    s.writeByte(1);
    s.writeByte(pt);
    s.writeByte(1);
    s.writeByte(m64 ? 0x42 : 0x41);
    s.writesLEB128(cast(int) stackHigh);
    s.writeByte(0x0B);
    section(o, 6, s);
    s.writeByte(4);
    exportEntry(s, "memory", 2);
    exportEntry(s, "__indirect_function_table", 1);
    exportEntry(s, "__stack_pointer", 3);
    exportEntry(s, "__d_exception", 4);
    section(o, 7, s);

    auto engine = ipGetEngine();
    wasmtime_module_t* mod;
    if (auto err = wasmtime_module_new(engine, cast(const(ubyte)*) o[].ptr, o.length, &mod))
    {
        ipLogError("base module", null, err);
        wasmtime_error_delete(err);
        return false;
    }
    scope (exit) wasmtime_module_delete(mod);
    auto store = wasmtime_store_new(engine, null, null);
    wasmtime_store_limiter(store, -1, -1, int.max, int.max, int.max);
    auto ctx = wasmtime_store_context(store);
    auto linker = wasmtime_linker_new(engine);
    wasmtime_linker_allow_shadowing(linker, true);
    wasmtime_instance_t inst;
    wasm_trap_t* trap;
    auto err = wasmtime_linker_instantiate(linker, ctx, mod, &inst, &trap);
    if (!err && !trap)
        err = wasmtime_linker_define_instance(linker, ctx, "env".ptr, 3, &inst);
    wasmtime_extern_t memExt, tableExt, spExt;
    if (err || trap
        || !wasmtime_instance_export_get(ctx, &inst, "memory".ptr, 6, &memExt)
        || !wasmtime_instance_export_get(ctx, &inst, "__indirect_function_table".ptr, 25, &tableExt)
        || !wasmtime_instance_export_get(ctx, &inst, "__stack_pointer".ptr, 15, &spExt))
    {
        if (err)
        {
            ipLogError("base instance", null, err);
            wasmtime_error_delete(err);
        }
        if (trap)
            wasm_trap_delete(trap);
        wasmtime_linker_delete(linker);
        wasmtime_store_delete(store);
        return false;
    }
    ipProg.store = store;
    ipProg.ctx = ctx;
    ipProg.linker = linker;
    ipProg.mem = memExt.of.memory;
    ipProg.table = tableExt.of.table;
    ipProg.sp = spExt.of.global;
    ipProg.memEnd = wasmtime_memory_data_size(ctx, &ipProg.mem);
    ipProg.tableSize = 1;
    ipProg.tableNext = 1;
    ipProg.dataEnd = stackHigh;
    ipProg.liveEnd = stackHigh;
    ipProg.poisonNext = wasmSelfLinkPoisonBase;
    return true;
}

private void ipFlush()
{
    import dmd.glue.tocsym : wasmCtfeResetLibrary;
    assert(!ipProg.running);
    if (!ipProg.store)
    {
        ipProg.flushPending = false;
        return;
    }
    if (verbose)
        fprintf(stderr, "wasm-ctfe inproc: flush after %zu modules\n", ipProg.sites.length);
    wasmtime_linker_delete(ipProg.linker);
    wasmtime_store_delete(ipProg.store);
    ipProg = IpProgram.init;
    ipTableFuncs = null;
    ipVtbls = null;
    ipDataExtents = null;
    ipPoisonExtents = null;
    ipCtfeOrdersAddr = 0;
    wasmCtfeResetLibrary();
    wasmCtfeStats.flushes++;
}

public void wasmCtfeLinkSetup()
{
    import dmd.backend.wasm.selflink : wasmSelfLinkShared, wasmSelfLinkDataBase, wasmSelfLinkDataSymbols,
        wasmSelfLinkSlots, wasmSelfLinkTableBase, wasmSelfLinkPoisonNext, wasmSelfLinkModuleId;
    if (ipProg.flushPending)
        ipFlush();
    ipProgramInit();
    ipCircularUsed = false;
    wasmSelfLinkShared = true;
    wasmSelfLinkDataBase = ipProg.dataEnd;
    wasmSelfLinkDataSymbols = ipProg.dataSyms;
    wasmSelfLinkSlots = ipProg.slots;
    wasmSelfLinkTableBase = ipProg.tableNext;
    wasmSelfLinkPoisonNext = ipProg.poisonNext;
    wasmSelfLinkModuleId = cast(uint) ipProg.sites.length;
}

private wasmtime_func_callback_t ipFixedHost(const(char)[] nm, ref HostImport hi)
{
    if (nm == "gc_malloc" || nm == "_d_allocmemory" || nm == "gc_mallocTrace" || nm == "gc_calloc" || nm == "gc_callocTrace")
        return &ipHostGcMalloc;
    if (nm == "malloc" || nm == "calloc" || nm == "realloc")
    {
        hi.cAlloc = nm == "malloc" ? CAlloc.malloc : nm == "calloc" ? CAlloc.calloc : CAlloc.realloc;
        return &ipHostCAlloc;
    }
    if (nm == "__errno_location")
        return &ipHostErrno;
    if (nm == "free" || nm == "gc_addRange" || nm == "gc_removeRange"
        || nm == "_d_criticalenter2" || nm == "_d_criticalexit"
        || nm == "_d_monitorenter" || nm == "_d_monitorexit" || nm == "gc_allocatedInCurrentThread")
        return &ipHostZero64;
    if (nm.length >= 10 && nm[0 .. 7] == "_aApply" && (nm[$ - 1] == '1' || nm[$ - 1] == '2')
        && (nm.length == 10 || (nm.length == 11 && nm[7] == 'R')))
        return &ipHostAApply;
    foreach (k, ln; ipLibmNames)
        if (nm == ln || nm.length == ln.length + 1 && nm[$ - 1] == 'f' && nm[0 .. $ - 1] == ln)
        {
            hi.softOp = ipLibmOps[k];
            return &ipHostLibm;
        }
    if (nm == "memset")
        return &ipHostMemset;
    if (nm == "memcpy")
        return &ipHostMemcpy;
    if (nm == "memcmp")
        return &ipHostMemcmp;
    if (nm == "_memsetn")
        return &ipHostMemsetn;
    if (nm == "_memsetFloat" || nm == "_memsetDouble" || nm == "_memset80"
        || nm == "_memset128" || nm == "_memset128ii" || nm == "_memset16"
        || nm == "_memset32" || nm == "_memset64")
        return &ipHostMemsetT;
    if (nm == "gc_expandArrayUsed")
        return &ipHostExpandArray;
    if (nm == "gc_shrinkArrayUsed")
        return &ipHostShrinkArray;
    if (nm == "gc_reserveArrayCapacity")
        return &ipHostReserveArray;
    if (nm == "gc_query")
        return &ipHostGcQuery;
    if (nm == "_d_arraybounds_indexp")
        return &ipHostBoundsIndex;
    if (nm == "_d_arraybounds_slicep")
        return &ipHostBoundsSlice;
    if (nm == "_d_assertp" || nm == "_d_arrayboundsp")
        return &ipHostAssert;
    if (nm == "_d_arraybounds")
        return &ipHostBounds;
    if (nm == "_d_assert")
        return &ipHostAssertStr;
    if (nm == "_d_assert_msg")
        return &ipHostAssertMsg;
    if (nm == "_d_arrayappendcd" || nm == "_d_arrayappendwd")
        return &ipHostArrayAppendC;
    if (nm == "__wasmctfe_append")
        return &ipHostAppend;
    if (nm == "_d_nullpointerp")
        return &ipHostNullPointer;
    if (nm == "__wasmctfe_error" || nm == "__wasmctfe_error2" || nm == "__wasmctfe_error64"
        || nm == "__wasmctfe_slicecopy")
        return &ipHostSiteError;
    if (nm == "__wasmctfe_ptrslice")
        return &ipHostPtrSlice;
    if (nm == "__wasmctfe_union")
        return &ipHostUnion;
    if (nm == "__wasmctfe_unioncopy")
        return &ipHostUnionCopy;
    if (nm == "__wasmctfe_throw")
        return &ipHostThrow;
    if (nm == "__wasmctfe_cov")
        return &ipHostCov;
    if (nm == "__wasmctfe_cppcast")
        return &ipHostCppCast;
    if (nm == "__wasmctfe_chain")
    {
        ipComputeThrowOffsets();
        return &ipHostChain;
    }
    if (nm == "_D2rt10invariant_12_d_invariantFC6ObjectZv")
    {
        ipComputeTIOffsets();
        return &ipHostInvariant;
    }
    if (nm == "_d_eh_wasm_match")
    {
        ipComputeTIOffsets();
        return &ipHostEhMatch;
    }
    if (auto bp = nm in wasmCtfeBuiltinFds)
    {
        hi.fd = *bp;
        return isBuiltin(*bp) == BUILTIN.ctfeWrite ? &ipHostCtfeWrite : &ipHostBuiltin;
    }
    if (nm.startsWith(softRealPrefix))
        foreach (k, sn; softRealNames)
            if (sn == nm)
            {
                hi.softOp = cast(SR) k;
                return &ipHostSoftReal;
            }
    return null;
}

private wasmtime_func_callback_t ipClassify(const(char)[] nm, ref HostImport hi, out HostKind kind)
{
    import dmd.glue.tocsym : wasmCtfeLazyFuncs, wasmCtfeStubFuncs, wasmCtfeErrorFuncs, wasmCtfeNoBodyFuncs;
    if (auto cb = ipFixedHost(nm, hi))
    {
        kind = HostKind.fixed;
        return cb;
    }
    if (auto sp = nm in wasmCtfeStubFuncs)
    {
        kind = HostKind.stub;
        hi.stubWhy = *sp;
        return &ipHostStubbed;
    }
    if (auto ep = nm in wasmCtfeErrorFuncs)
    {
        kind = HostKind.errorFunc;
        hi.fd = *ep;
        return &ipHostErrorFunc;
    }
    if (auto lp = nm in wasmCtfeLazyFuncs)
    {
        kind = HostKind.lazy_;
        hi.fd = *lp;
        return &ipHostLazy;
    }
    if (auto np = nm in wasmCtfeNoBodyFuncs)
    {
        kind = HostKind.noBody;
        hi.fd = *np;
        hi.noBody = true;
        return &ipHostErrorFunc;
    }
    kind = HostKind.unknown;
    return &ipHostStub;
}

private extern (C) void ipFreeHost(void* p) nothrow @nogc
{
    import core.stdc.stdlib : free;
    free(p);
}

private bool ipDefineHost(ref const WasmImportInfo imp, IpHost* h, ref HostImport tmp)
{
    import core.stdc.stdlib : malloc;
    import dmd.backend.wasm.enums : WASM_TYPE;

    static bool valtypes(const(WASM_TYPE)[] types, out wasm_valtype_vec_t vec)
    {
        foreach (t; types)
            if (t < WASM_TYPE.V128)
                return false;
        wasm_valtype_vec_new_uninitialized(&vec, types.length);
        foreach (i, t; types)
            vec.data[i] = wasm_valtype_new(cast(ubyte)(WASM_TYPE.I32 - t));
        return true;
    }

    wasm_valtype_vec_t params, results;
    if (!valtypes(imp.type.params, params) || !valtypes(imp.type.results, results))
        return false;
    auto ft = wasm_functype_new(&params, &results);
    scope (exit) wasm_functype_delete(ft);
    auto hi = cast(HostImport*) malloc(HostImport.sizeof);
    *hi = tmp;
    if (auto err = wasmtime_linker_define_func(ipProg.linker, imp.module_.ptr, imp.module_.length,
        imp.name.ptr, imp.name.length, ft, h.cb, hi, &ipFreeHost))
    {
        wasmtime_error_delete(err);
        return false;
    }
    h.hi = hi;
    return true;
}

private void ipRelease(IpRoot* r)
{
    const td = ipNow();
    auto mem = wasmtime_memory_data(ipProg.ctx, &ipProg.mem);
    const top = ipHeapPtr > ipProg.liveEnd ? ipHeapPtr : ipProg.liveEnd;
    if (r && r.temp)
    {
        ipProg.image = ipProg.image[0 .. r.imageLen].assumeSafeAppend;
        ipDataExtents = ipDataExtents[0 .. r.extents].assumeSafeAppend;
        ipPoisonExtents = ipPoisonExtents[0 .. r.poisonExtents].assumeSafeAppend;
        foreach (k; r.vtbls)
            ipVtbls.remove(k);
        ipCtfeOrdersAddr = r.prevOrders;
        ipTableFuncs = ipTableFuncs[0 .. ipProg.tableNext - 1].assumeSafeAppend;
        ipProg.sites[r.id] = null;
        ipProg.liveEnd = ipProg.dataEnd;
    }
    const stackHigh = ipStackHigh();
    memcpy(mem + stackHigh, ipProg.image.ptr, ipProg.image.length);
    ipZeroRange(mem, ipProg.dataEnd, top);
    ipZeroRange(mem, 0, stackHigh);
    ipHeapPtr = 0;
    version (linux) {}
    else
    {
        if (top - ipProg.dataEnd > 64 << 20)
            ipProg.flushPending = true;
    }
    wasmCtfeStats.ticks[WasmCtfeStats.Phase.teardown] += ipNow() - td;
}

private void ipEndRun(IpRoot* r)
{
    ipRelease(r);
    ipProg.running = false;
}

private IpRoot* ipLink(FuncDeclaration fd, ref OutBuffer buf, out bool retry)
{
    import dmd.glue : wasmCtfeBuiltFuncs;
    import dmd.glue.tocsym : wasmCtfeStubFuncs, wasmCtfeVtblClasses, wasmCtfeCommitEmitted;
    import dmd.backend.wasm.obj : wasmModuleSites;
    import dmd.backend.wasm.selflink : wasmSelfLinkDataExtents, wasmSelfLinkTableNames, wasmSelfLinkDataEnd,
        wasmSelfLinkPoisonEnd, wasmSelfLinkDefined, wasmSelfLinkImports, wasmSelfLinkTableBase,
        wasmSelfLinkPoisonBase, wasmSelfLinkNewData;

    if (!ipProg.store)
        return null;
    auto ctx = ipProg.ctx;
    const hasLibrary = ipProg.sites.length != 0;

    foreach (name; wasmSelfLinkDefined)
        if (auto ph = name in ipProg.hosts)
            if ((*ph).committed && ((*ph).kind != HostKind.lazy_ || (*ph).direct))
            {
                if (verbose)
                    fprintf(stderr, "wasm-ctfe inproc: stale import %.*s\n", cast(int) name.length, name.ptr);
                retry = true;
                return null;
            }
    FuncDeclaration[const(char)[]] byName;
    foreach (bf; wasmCtfeBuiltFuncs)
    {
        const name = mangleExact(bf).toDString;
        byName[name] = bf;
        auto pf = name in ipProg.funcs;
        if (pf && *pf && *pf !is bf && (*pf).loc != bf.loc)
        {
            if (verbose)
                fprintf(stderr, "wasm-ctfe inproc: name clash %s\n", bf.toPrettyChars());
            retry = true;
            return null;
        }
    }

    wasmtime_module_t* mod;
    const tc = ipNow();
    auto merr = wasmtime_module_new(ipGetEngine(), cast(const(ubyte)*) buf[].ptr, buf.length, &mod);
    wasmCtfeStats.ticks[WasmCtfeStats.Phase.compile] += ipNow() - tc;
    wasmCtfeStats.modules++;
    if (merr)
    {
        ipLogError("module error for", fd, merr);
        wasmtime_error_delete(merr);
        return null;
    }
    scope (exit) wasmtime_module_delete(mod);
    const tl = ipNow();
    scope (exit) wasmCtfeStats.ticks[WasmCtfeStats.Phase.link] += ipNow() - tl;

    auto imports = wasmSelfLinkImports;
    auto used = new IpHost*[](imports.length);
    foreach (i, ref imp; imports)
    {
        const nm = imp.name;
        if (nm in ipProg.funcs)
            continue;
        auto ph = nm in ipProg.hosts;
        auto h = ph ? *ph : null;
        used[i] = h;
        if (h && h.kind == HostKind.fixed)
            continue;
        HostImport tmp;
        HostKind kind;
        auto cb = ipClassify(nm, tmp, kind);
        if (h && h.cb is cb && h.hi.fd is tmp.fd && h.hi.stubWhy is tmp.stubWhy)
            continue;
        if (h && h.committed)
        {
            if (verbose)
                fprintf(stderr, "wasm-ctfe inproc: import %.*s changed kind\n", cast(int) nm.length, nm.ptr);
            retry = true;
            return null;
        }
        const nl = nm.length < tmp.name.length ? nm.length : tmp.name.length;
        tmp.name[0 .. nl] = nm[0 .. nl];
        tmp.nameLen = nl;
        if (!h)
        {
            h = new IpHost;
            ipProg.hosts[nm] = h;
            used[i] = h;
        }
        h.cb = cb;
        h.kind = kind;
        if (!ipDefineHost(imp, h, tmp))
            return null;
    }

    if (!ipGrowMemory(ipPageAlign(wasmSelfLinkDataEnd) + 0x1_0000))
        return null;
    const tableEnd = wasmSelfLinkTableBase + wasmSelfLinkTableNames.length;
    if (tableEnd > ipProg.tableSize)
    {
        ulong delta = tableEnd - ipProg.tableSize;
        if (delta < ipProg.tableSize)
            delta = ipProg.tableSize;
        wasmtime_val_t nul;
        nul.kind = WASMTIME_FUNCREF;
        ulong prev;
        if (auto err = wasmtime_table_grow(ctx, &ipProg.table, delta, &nul, &prev))
        {
            ipLogError("table grow for", fd, err);
            wasmtime_error_delete(err);
            return null;
        }
        ipProg.tableSize = prev + delta;
    }

    wasmtime_instance_t inst;
    wasm_trap_t* trap;
    auto err = wasmtime_linker_instantiate(ipProg.linker, ctx, mod, &inst, &trap);
    if (err && !trap)
    {
        ipLogError("instantiate (retrying with own import types)", fd, err);
        wasmtime_error_delete(err);
        foreach (i, ref imp; imports)
            if (auto h = used[i])
            {
                HostImport tmp = *h.hi;
                if (!ipDefineHost(imp, h, tmp))
                    return null;
            }
        err = wasmtime_linker_instantiate(ipProg.linker, ctx, mod, &inst, &trap);
    }
    if (err || trap)
    {
        if (err)
        {
            ipLogError("instantiate", fd, err);
            wasmtime_error_delete(err);
        }
        if (trap)
            wasm_trap_delete(trap);
        ipZeroRange(wasmtime_memory_data(ctx, &ipProg.mem), ipProg.dataEnd, wasmSelfLinkDataEnd);
        retry = hasLibrary;
        return null;
    }

    auto r = new IpRoot;
    r.id = cast(uint) ipProg.sites.length;
    r.imageLen = ipProg.image.length;
    r.extents = ipDataExtents.length;
    r.poisonExtents = ipPoisonExtents.length;
    r.prevOrders = ipCtfeOrdersAddr;
    r.temp = true;
    ipProg.sites ~= wasmModuleSites;
    ipProg.image ~= wasmtime_memory_data(ctx, &ipProg.mem)[ipProg.dataEnd .. wasmSelfLinkDataEnd];
    ipProg.liveEnd = wasmSelfLinkDataEnd;
    foreach (ref x; wasmSelfLinkDataExtents)
    {
        if (x.start >= wasmSelfLinkPoisonBase)
            ipPoisonExtents ~= x;
        else
            ipDataExtents ~= x;
        if (auto cd = x.name in wasmCtfeVtblClasses)
        {
            ipVtbls[x.start] = *cd;
            r.vtbls ~= x.start;
        }
        else if (x.name.startsWith("_D4core8internal5newaa10ctfeOrders"))
            ipCtfeOrdersAddr = x.start;
    }
    ipTableFuncs.length = wasmSelfLinkTableBase - 1 + wasmSelfLinkTableNames.length;
    foreach (i, n; wasmSelfLinkTableNames)
    {
        auto pf = n in byName;
        if (!pf)
            pf = n in ipProg.funcs;
        ipTableFuncs[wasmSelfLinkTableBase - 1 + i] = pf ? *pf : null;
    }

    const rootName = mangleExact(fd).toDString;
    wasmtime_extern_t rootExt;
    if (!wasmtime_instance_export_get(ctx, &inst, rootName.ptr, rootName.length, &rootExt)
        || rootExt.kind != WASMTIME_EXTERN_FUNC)
    {
        if (verbose)
            fprintf(stderr, "wasm-ctfe inproc: export %.*s not found for %s at %s\n",
                cast(int) rootName.length, rootName.ptr, fd.toPrettyChars(), fd.loc.toChars());
        ipRelease(r);
        return null;
    }
    r.func = rootExt.of.func;
    if (wasmCtfeStubFuncs.length || ipCircularUsed)
    {
        wasmCtfeStats.tempModules++;
        return r;
    }

    r.temp = false;
    r.vtbls = null;
    foreach (name; wasmSelfLinkDefined)
    {
        HostImport tmp;
        if (ipFixedHost(name, tmp))
            continue;
        wasmtime_extern_t fe;
        if (!wasmtime_instance_export_get(ctx, &inst, name.ptr, name.length, &fe))
            continue;
        if (auto derr = wasmtime_linker_define(ipProg.linker, ctx, "env".ptr, 3, name.ptr, name.length, &fe))
        {
            wasmtime_error_delete(derr);
            continue;
        }
        auto pf = name in byName;
        ipProg.funcs[name] = pf ? *pf : null;
        if (auto ph = name in ipProg.hosts)
        {
            if (const slot = (*ph).slot)
            {
                wasmtime_val_t v;
                v.kind = WASMTIME_FUNCREF;
                v.of.funcref = fe.of.func;
                if (auto serr = wasmtime_table_set(ctx, &ipProg.table, slot, &v))
                    wasmtime_error_delete(serr);
                ipTableFuncs[slot - 1] = pf ? *pf : null;
            }
            ipProg.hosts.remove(name);
        }
    }
    foreach (i, ref imp; imports)
        if (auto h = used[i])
        {
            h.committed = true;
            if (imp.called)
                h.direct = true;
        }
    foreach (i, n; wasmSelfLinkTableNames)
    {
        const slot = wasmSelfLinkTableBase + cast(uint) i;
        ipProg.slots[n] = slot;
        if (auto ph = n in ipProg.hosts)
            (*ph).slot = slot;
    }
    foreach (name, addr; wasmSelfLinkNewData)
        ipProg.dataSyms[name] = addr;
    ipProg.dataEnd = wasmSelfLinkDataEnd;
    ipProg.poisonNext = wasmSelfLinkPoisonEnd;
    ipProg.tableNext = cast(uint) tableEnd;
    wasmCtfeCommitEmitted();
    return r;
}

private IpRoot* ipBuild(FuncDeclaration fd)
{
    import dmd.glue : wasmCtfeGenerate;

    foreach (round; 0 .. 3)
    {
        OutBuffer buf;
        const(char)[][] unresolved;
        const savedSuspend = buildActiveSuspended;
        buildActiveSuspended = 0;
        const tg = ipNow();
        const genOk = wasmCtfeGenerate(fd, buf, unresolved);
        wasmCtfeStats.ticks[WasmCtfeStats.Phase.gen] += ipNow() - tg;
        buildActiveSuspended = savedSuspend;
        if (!genOk)
        {
            if (verbose)
            {
                import dmd.glue : wasmCtfeLastPoison;
                auto why = wasmCtfeLastPoison();
                fprintf(stderr, "wasm-ctfe inproc: codegen failed for %s at %s: %s\n",
                    fd.toPrettyChars(), fd.loc.toChars(), why ? why : "errors".ptr);
            }
            wasmCtfeStats.compileFailures++;
            return null;
        }
        if (keepFiles)
        {
            import dmd.utils : writeFile;
            char[256] name = void;
            snprintf(name.ptr, name.length, "wasmctfe_ip_%u.wasm", seq);
            seq++;
            writeFile(Loc.initial, name[0 .. strlen(name.ptr)], buf[]);
            fprintf(stderr, "wasm-ctfe inproc: kept %s = %s\n", name.ptr, fd.toPrettyChars());
        }
        if (ipProg.flushPending)
        {
            ipFlush();
            continue;
        }
        if (unresolved.length)
        {
            if (verbose)
            {
                fprintf(stderr, "wasm-ctfe inproc: %zu unresolved symbols for %s\n",
                    unresolved.length, fd.toPrettyChars());
                foreach (u; unresolved)
                    fprintf(stderr, "  undefined: %.*s\n", cast(int) u.length, u.ptr);
            }
            if (ipProg.sites.length)
            {
                ipFlush();
                continue;
            }
            wasmCtfeStats.compileFailures++;
            return null;
        }
        bool retry;
        auto r = ipLink(fd, buf, retry);
        if (!retry)
            return r;
        ipFlush();
    }
    return null;
}

private IpRoot* ipGetRoot(FuncDeclaration fd)
{
    import dmd.glue.tocsym : wasmCtfeInLibrary;

    if (ipProg.running)
    {
        if (verbose)
            fprintf(stderr, "wasm-ctfe inproc: nested run of %s refused\n", fd.toPrettyChars());
        wasmCtfeStats.nestedRuns++;
        ipNestedDeferred = true;
        return null;
    }
    if (ipProg.flushPending)
        ipFlush();
    if (auto p = cast(void*) fd in ipProg.roots)
        return *p;
    if (wasmCGCtfeBuild)
    {
        if (verbose)
            fprintf(stderr, "wasm-ctfe inproc: nested build for %s deferred\n", fd.toPrettyChars());
        ipNestedDeferred = true;
        return null;
    }
    if (!ipProgramInit())
        return null;
    IpRoot* r;
    if (wasmCtfeInLibrary(fd))
    {
        const nm = mangleExact(fd).toDString;
        wasmtime_extern_t ext;
        if (wasmtime_linker_get(ipProg.linker, ipProg.ctx, "env".ptr, 3, nm.ptr, nm.length, &ext)
            && ext.kind == WASMTIME_EXTERN_FUNC)
        {
            r = new IpRoot;
            r.func = ext.of.func;
        }
    }
    else
        r = ipBuild(fd);
    if (!r || !r.temp)
        ipProg.roots[cast(void*) fd] = r;
    return r;
}

private __gshared CallExp ipRootCall;

private void ipCalledFrom(Expression e)
{
    global.errorSink.errorSupplemental(e.loc, "called from here: `%s`", e.toChars());
}

private void ipPrintChain(uint errSite, const(uint)[] chain)
{
    import dmd.glue.tocsym : wasmCtfeSites, wasmCtfeSiteArgCalls;
    void argCalls(uint idx)
    {
        if (idx < wasmCtfeSiteArgCalls.length)
            foreach (ce; wasmCtfeSiteArgCalls[idx])
                ipCalledFrom(ce);
    }
    if (errSite)
        argCalls(errSite);
    foreach (c; chain)
    {
        if (auto ce = wasmCtfeSites[c].isCallExp())
            ipCalledFrom(ce);
        argCalls(c);
    }
    if (ipRootCall)
        ipCalledFrom(ipRootCall);
}

private Expression ipReportSiteError(const(uint)[] chain)
{
    import dmd.glue.tocsym : wasmCtfeSites;
    import dmd.hdrgen : toErrMsg;
    if (ipErrVals[1] >= wasmCtfeSites.length)
        return null;
    auto site = wasmCtfeSites[cast(size_t) ipErrVals[1]];
    auto eSink = global.errorSink;
    const kind = cast(CtfeSiteErr) ipErrVals[0];
    final switch (kind)
    {
        case CtfeSiteErr.none:
            return null;
        case CtfeSiteErr.sliceCopy:
        {
            auto ae = site.isAssignExp();
            if (!ae)
                return null;
            const lento = ipErrArgs[0];
            const lenfr = ipErrArgs[1];
            bool bounds(Expression x, ulong len, out ulong lo, out ulong hi)
            {
                if (auto se = x.isSliceExp())
                {
                    if (se.lwr && se.upr && se.lwr.isIntegerExp() && se.upr.isIntegerExp())
                    {
                        lo = se.lwr.isIntegerExp().toInteger();
                        hi = se.upr.isIntegerExp().toInteger();
                        return true;
                    }
                    return false;
                }
                lo = 0;
                hi = len;
                return true;
            }
            ulong lo1, hi1, lo2, hi2;
            const ok1 = bounds(ae.e1, lento, lo1, hi1);
            const ok2 = bounds(ae.e2, lenfr, lo2, hi2);
            const esz = ae.e1.type.nextOf() ? ae.e1.type.nextOf().size() : 1;
            const long d = esz ? (cast(long) ipErrArgs[3] - cast(long) ipErrArgs[2]) / cast(long) esz : 0;
            if (!ok1 && ok2)
            {
                lo1 = lo2 - d;
                hi1 = lo1 + lento;
            }
            else if (ok1 && !ok2)
            {
                lo2 = lo1 + d;
                hi2 = lo2 + lenfr;
            }
            else if (!ok1)
            {
                lo1 = d < 0 ? -d : 0;
                hi1 = lo1 + lento;
                lo2 = lo1 + d;
                hi2 = lo2 + lenfr;
            }
            if (lento != lenfr)
                eSink.error(ae.loc, "array length mismatch assigning `[0..%llu]` to `[%llu..%llu]`", lenfr, lo1, hi1);
            else
                eSink.error(ae.loc, "overlapping slice assignment `[%llu..%llu] = [%llu..%llu]`", lo1, hi1, lo2, hi2);
            break;
        }
        case CtfeSiteErr.switchNoCase:
            eSink.error(site.loc, "no `default` or `case` for `%s` in `switch` statement",
                new IntegerExp(site.loc, ipErrArgs[0], site.type).toErrMsg());
            break;
        case CtfeSiteErr.circularNew:
        {
            auto ne = site.isNewExp();
            auto v = ne ? wasmCtfeNewCircular(ne) : null;
            if (!v)
                return null;
            eSink.error(ne.loc, "circular reference to `%s`", v.toPrettyChars());
            break;
        }
        case CtfeSiteErr.initErrors:
        {
            auto sd = site.isVarExp() ? site.isVarExp().var.isSymbolDeclaration() : null;
            if (!sd)
                return null;
            eSink.error(site.loc, "CTFE failed because of previous errors in `%s.init`", sd.toErrMsg());
            break;
        }
        case CtfeSiteErr.initSymAddr:
            eSink.error(site.loc, "cannot determine the address of the initializer symbol during CTFE");
            break;
        case CtfeSiteErr.shiftRange:
        {
            auto be = site.isBinExp();
            if (!be)
                return null;
            eSink.error(be.loc, "shift by %lld is outside the range 0..%llu",
                cast(long) ipErrArgs[0], be.e1.type.size() * 8 - 1);
            break;
        }
        case CtfeSiteErr.unionReinterpret:
        {
            auto dve = site.isDotVarExp();
            if (!dve)
                return null;
            eSink.error(dve.loc, "reinterpretation through overlapped field `%s` is not allowed in CTFE", dve.var.toChars());
            break;
        }
        case CtfeSiteErr.nullSliceBounds:
        {
            auto se = site.isSliceExp();
            if (!se)
                return null;
            Loc loc = se.e1.loc;
            Expression x = se.e1;
            while (x.isIndexExp() || x.isDotVarExp() || x.isCastExp())
                x = x.isIndexExp() ? x.isIndexExp().e1 : x.isDotVarExp() ? x.isDotVarExp().e1 : x.isCastExp().e1;
            if (auto ve = x.isVarExp())
                if (ve.var.isVarDeclaration())
                    loc = ve.var.loc;
            eSink.error(loc, "slice `[%llu..%llu]` is out of bounds", ipErrArgs[0], ipErrArgs[1]);
            break;
        }
        case CtfeSiteErr.ptrSliceBounds:
            eSink.error(site.loc, "pointer slice `[%llu..%llu]` exceeds allocated memory block `[0..%llu]`",
                ipErrArgs[0], ipErrArgs[1], ipErrArgs[2]);
            break;
        case CtfeSiteErr.noReturnValue:
        {
            auto ve = site.isVarExp();
            auto fd = ve ? ve.var.isFuncDeclaration() : null;
            if (!fd)
                return null;
            eSink.error(fd.loc, "%s `%s` no return value from function", fd.kind, fd.toPrettyChars);
            break;
        }
        case CtfeSiteErr.typeidField:
        {
            auto dve = site.isDotVarExp();
            if (!dve)
                return null;
            eSink.error(dve.loc, "`%s.%s` is not yet implemented at compile time", dve.e1.toErrMsg(), dve.var.toErrMsg());
            break;
        }
        case CtfeSiteErr.placementNew:
        {
            auto ne = site.isNewExp();
            if (!ne || !ne.placement)
                return null;
            eSink.error(ne.placement.loc, "`new ( %s )` PlacementExpression cannot be evaluated at compile time", ne.placement.toErrMsg());
            break;
        }
        case CtfeSiteErr.nullThrow:
            eSink.error(site.loc, "to be thrown `%s` must be non-null", site.toErrMsg());
            break;
        case CtfeSiteErr.importedAddr:
        {
            auto ae = site.isAddrExp();
            if (!ae || !ae.e1.isVarExp())
                return null;
            eSink.error(ae.loc, "cannot take address of imported symbol `%s` at compile time", ae.e1.isVarExp().var.toErrMsg());
            break;
        }
        case CtfeSiteErr.reinterpretSlice:
        case CtfeSiteErr.addrConvert:
        case CtfeSiteErr.reinterpretPtr:
        case CtfeSiteErr.arrayCast:
        case CtfeSiteErr.noreturnCast:
        case CtfeSiteErr.hexStringLen:
        case CtfeSiteErr.ptrToInt:
        {
            Type from, to;
            if (ipBadPointerCast(site, from, to) != kind)
                return null;
            if (kind == CtfeSiteErr.reinterpretSlice)
                eSink.error(site.loc, "reinterpreting cast from `%s` to `%s` is not supported in CTFE", from.toErrMsg(), to.toErrMsg());
            else if (kind == CtfeSiteErr.addrConvert)
                eSink.error(site.loc, "cannot convert `&%s` to `%s` at compile time", from.toErrMsg(), to.toErrMsg());
            else if (kind == CtfeSiteErr.reinterpretPtr)
                eSink.error(site.loc, "reinterpreting cast from `%s*` to `%s*` is not supported in CTFE", from.toErrMsg(), to.toErrMsg());
            else if (kind == CtfeSiteErr.arrayCast)
            {
                eSink.error(site.loc, "array cast from `%s` to `%s` is not supported at compile time", from.toErrMsg(), to.toErrMsg());
                auto se = site.isCastExp().e1.isStringExp();
                if (se && se.hexString && se.postfix != StringExp.NoPostfix)
                    eSink.errorSupplemental(site.loc, "perhaps remove postfix `%.*s` from hex string", 1, &se.postfix);
            }
            else if (kind == CtfeSiteErr.hexStringLen)
            {
                auto se = site.isCastExp().e1.isStringExp();
                eSink.error(site.loc, "hex string length %d must be a multiple of %d to cast to `%s`",
                    cast(int) se.len, cast(int) to.nextOf().size(), to.toErrMsg());
            }
            else if (kind == CtfeSiteErr.noreturnCast)
                eSink.error(site.loc, "cannot cast `%s` to `%s` at compile time", site.isCastExp().e1.toErrMsg(), to.toErrMsg());
            else
            {
                Expression v = site.isCastExp().e1;
                while (v.isCastExp())
                    v = v.isCastExp().e1;
                eSink.error(site.loc, "cannot cast `%s` to `%s` at compile time", v.toErrMsg(), to.toErrMsg());
            }
            break;
        }
        case CtfeSiteErr.staticRead:
        case CtfeSiteErr.circularInit:
        {
            auto ve = site.isVarExp();
            auto v = ve ? ve.var.isVarDeclaration() : null;
            if (!v)
                return null;
            if (kind == CtfeSiteErr.staticRead)
                eSink.error(ve.loc, "static variable `%s` cannot be read at compile time", v.toErrMsg());
            else
                eSink.error(ve.loc, "circular initialization of %s `%s`", v.kind(), v.toPrettyChars());
            break;
        }
    }
    ipPrintChain(cast(uint) ipErrVals[1], chain);
    return ErrorExp.get();
}

private Expression ipReportRecursion(const(uint)[] chain)
{
    import dmd.hdrgen : toErrMsg;
    import dmd.glue.tocsym : wasmCtfeSites;
    CallExp[] calls;
    foreach (c; chain)
        if (auto ce = wasmCtfeSites[c].isCallExp())
            calls ~= ce;
    size_t i = 0;
    while (i + 1 < calls.length && calls[i] !is calls[i + 1])
        i++;
    if (i + 16 > calls.length || !calls[i].f)
        return null;
    auto rec = calls[i];
    auto fd = rec.f;
    size_t n = i;
    while (n < calls.length && calls[n] is rec)
        n++;
    if (n - i < 16)
        return null;
    auto eSink = global.errorSink;
    eSink.error(fd.loc, "%s `%s` CTFE recursion limit exceeded", fd.kind, fd.toPrettyChars);
    ipCalledFrom(rec);
    import dmd.dinterpret : CTFE_RECURSION_LIMIT;
    eSink.errorSupplemental(fd.loc, "%d recursive calls to function `%s`", CTFE_RECURSION_LIMIT, fd.toChars());
    foreach (ce; calls[n .. $])
        ipCalledFrom(ce);
    if (ipRootCall)
        ipCalledFrom(ipRootCall);
    return ErrorExp.get();
}

private Expression ipReportUncaught(const(uint)[] chain, const(ubyte)[] data)
{
    import dmd.glue.tocsym : wasmCtfeSites;
    import dmd.hdrgen : toErrMsg;
    if (ipErrVals[1] >= wasmCtfeSites.length || !ClassDeclaration.object)
        return null;
    auto site = wasmCtfeSites[cast(size_t) ipErrVals[1]];
    auto cre = ipDecodeClassRef(data, ipErrVals[0], ClassDeclaration.object.type, site.loc, 0);
    auto cr = cre ? cre.isClassReferenceExp() : null;
    if (!cr || !cr.value.elements || !cr.value.elements.length)
        return null;
    import dmd.expressionsem : toStringExp;
    auto e = (*cr.value.elements)[0];
    auto se = e.toStringExp();
    if (se && se.sz == 1 && ClassDeclaration.throwable && ClassDeclaration.throwable.fields.length)
    {
        const a = ipErrVals[0] + ClassDeclaration.throwable.fields[0].offset + ipPS;
        ulong base, sz;
        const(char)[] name;
        if (a + ipPS <= data.length && !ipFindData(ipRead(data, a, ipPS), base, sz, name))
            se.postfix = 'c';
    }
    auto eSink = global.errorSink;
    eSink.error(site.loc, "uncaught CTFE exception `%s(%s)`", cr.originalClass().type.toErrMsg(),
        se ? se.toErrMsg() : e.toErrMsg());
    if (ipRootCall)
        ipCalledFrom(ipRootCall);
    else
        foreach_reverse (c; chain)
            if (auto ce = wasmCtfeSites[c].isCallExp())
            {
                ipCalledFrom(ce);
                break;
            }
    return ErrorExp.get();
}

private Expression ipReportTrap(const(wasm_trap_t)* trap, const(wasmtime_error_t)* err, const(ubyte)[] data)
{
    import dmd.glue.tocsym : wasmCtfeSites;
    import dmd.hdrgen : toErrMsg;
    import dmd.dtemplate : isExpression;
    bool stackExhausted;
    if (ipErrKind == IpErrKind.none)
    {
        wasm_message_t msg;
        if (trap)
            wasm_trap_message(trap, &msg);
        else
            wasmtime_error_message(err, &msg);
        const m = msg.data[0 .. msg.size];
        enum pat = "call stack exhausted";
        foreach (k; 0 .. m.length >= pat.length ? m.length - pat.length + 1 : 0)
            if (m[k .. k + pat.length] == pat)
                stackExhausted = true;
        wasm_byte_vec_delete(&msg);
        if (!stackExhausted)
            return null;
    }
    wasm_frame_vec_t frames;
    if (trap)
        wasm_trap_trace(trap, &frames);
    else
        wasmtime_error_wasm_trace(err, &frames);
    scope (exit) wasm_frame_vec_delete(&frames);
    uint[] chain;
    foreach (i; 0 .. frames.size)
    {
        const off = wasm_frame_module_offset(frames.data[i]);
        size_t id;
        if (auto mn = wasmtime_frame_module_name(frames.data[i]))
            foreach (c; mn.data[0 .. mn.size])
                id = id * 10 + (c - '0');
        else
            id = size_t.max;
        const(WasmSite)[] sites = id < ipProg.sites.length ? ipProg.sites[id] : null;
        size_t lo = 0, hi = sites.length;
        while (lo < hi)
        {
            const mid = (lo + hi) / 2;
            if (sites[mid].offset < off)
                lo = mid + 1;
            else
                hi = mid;
        }
        if (lo < sites.length && sites[lo].offset == off)
        {
            if (sites[lo].site < wasmCtfeSites.length)
                chain ~= sites[lo].site;
        }
        else if (i == 0 && ipErrKind == IpErrKind.errorFunc)
        {
            chain ~= 0;
        }
        else if (i == 0 && ipErrKind != IpErrKind.uncaught && ipErrKind != IpErrKind.siteError && !stackExhausted)
            return null;
    }
    if (ipErrKind == IpErrKind.uncaught)
        return ipReportUncaught(chain, data);
    if (stackExhausted)
        return ipReportRecursion(chain);
    if (ipErrKind == IpErrKind.siteError)
        return ipReportSiteError(chain);
    if (!chain.length)
        return null;
    auto site = wasmCtfeSites[chain[0]];
    auto eSink = global.errorSink;
    final switch (ipErrKind)
    {
        case IpErrKind.none:
            return null;
        case IpErrKind.index:
            if (auto ie = site.isIndexExp())
                eSink.error(ie.loc, "array index %llu is out of bounds `%s[0 .. %llu]`",
                    ipErrVals[0], ie.e1.toErrMsg(), ipErrVals[1]);
            else
                return null;
            break;
        case IpErrKind.slice:
            eSink.error(site.loc, "slice `[%llu..%llu]` exceeds array bounds `[0..%llu]`",
                ipErrVals[0], ipErrVals[1], ipErrVals[2]);
            break;
        case IpErrKind.nullp:
            if (auto te = site.isTypeidExp())
            {
                auto ex = isExpression(te.obj);
                eSink.error(te.loc, "null pointer dereference evaluating typeid. `%s` is `null`",
                    ex ? ex.toErrMsg() : te.toErrMsg());
            }
            else if (auto pe = site.isPtrExp())
                eSink.error(pe.loc, "dereference of null pointer `%s`", pe.e1.toErrMsg());
            else if (auto ie = site.isIndexExp())
                eSink.error(ie.loc, "dereference of null pointer `%s`", ie.e1.toErrMsg());
            else if (auto dve = site.isDotVarExp())
                eSink.error(dve.loc, "dereference of null pointer `%s`", dve.e1.toErrMsg());
            else
                return null;
            break;
        case IpErrKind.assert_:
            eSink.error(site.loc, "`%s` failed", site.toErrMsg());
            break;
        case IpErrKind.assertMsg:
            eSink.error(site.loc, "%.*s", cast(int) ipErrMsgLen, ipErrMsg.ptr);
            break;
        case IpErrKind.uncaught:
        case IpErrKind.siteError:
            return null;
        case IpErrKind.errorFunc:
            if (ipErrNoBody)
            {
                if (!site || !site.isCallExp())
                    return null;
                eSink.error(site.loc, "`%s` cannot be interpreted at compile time, because it has no available source code", ipErrFunc.toErrMsg());
                return CTFEExp.showcontext;
            }
            if (!site || !site.isCallExp())
            {
                ipPrintChain(0, chain[1 .. $]);
                return ErrorExp.get();
            }
            if (!wasmCtfeTakeForcedSem3Error(ipErrFunc))
            {
                eSink.error(site.loc, "CTFE failed because of previous errors in `%s`", ipErrFunc.toErrMsg());
                break;
            }
            ipPrintChain(0, chain);
            return ErrorExp.get();
    }
    ipPrintChain(chain[0], chain[1 .. $]);
    return ErrorExp.get();
}

Expression tryWasmCtfeInproc(FuncDeclaration fd, Expression thisExp, Expression[] args, Type resultType, Loc loc)
{
    foreach (_; 0 .. 32)
    {
        ipLazyHit = null;
        ipReplayPending = 0;
        auto r = tryWasmCtfeInprocOnce(fd, thisExp, args, resultType, loc);
        if (ipReplayPending && !ipLazyHit)
        {
            ipReplayAt = ipReplayPending;
            ipReplayPending = 0;
            auto r2 = tryWasmCtfeInprocOnce(fd, thisExp, args, resultType, loc);
            ipReplayAt = 0;
            ipLazyHit = null;
            return r2 && r2.isErrorExp() ? r2 : r;
        }
        auto lf = ipLazyHit;
        ipLazyHit = null;
        if (!lf)
            return r;
        if (lf.semanticRun < PASS.semantic3done
            && (ipForceSemantic3Gagged(lf) || lf.semanticRun < PASS.semantic3done || lf.errors))
            return r;
        if (cast(void*) lf in ipProg.roots)
        {
            ipProg.flushPending = true;
            continue;
        }
        auto patch = ipGetRoot(lf);
        if (patch && !patch.temp)
            continue;
        if (patch)
            ipRelease(patch);
        ipProg.flushPending = true;
    }
    return null;
}

private Expression tryWasmCtfeInprocOnce(FuncDeclaration fd, Expression thisExp, Expression[] args, Type resultType, Loc loc)
{
    import dmd.target : target;
    ipPS = target.ptrsize;

    static Expression bail(FuncDeclaration fd, const(char)* why)
    {
        if (verbose)
            fprintf(stderr, "wasm-ctfe inproc: skip %s: %s\n", fd ? fd.toPrettyChars() : "?".ptr, why);
        return null;
    }

    if (!fd || !resultType)
        return bail(fd, "no fd/result type");
    if (!thisExp && wasmCtfeHostBuiltin(fd) && ipAllLiteral(args))
    {
        import dmd.builtin : eval_builtin;
        if (isBuiltin(fd) == BUILTIN.ctfeWrite)
        {
            ipCtfeWrites++;
            if (wasmCtfeMode() == WasmCtfeMode.verify)
                return CTFEExp.voidexp;
        }
        auto exps = new Expressions();
        exps.pushSlice(args);
        if (auto r = eval_builtin(loc, fd, exps))
            return r;
    }
    if (fd.semanticRun < PASS.semantic3done)
        ipForceSemantic3(fd);
    if (fd.semanticRun < PASS.semantic3done || !fd.fbody || fd.errors)
        return bail(fd, "not semantic3done");
    if (!scanLegality(fd))
        return bail(fd, "legality scan");
    auto tf = fd.type ? fd.type.isTypeFunction() : null;
    const bool isCtor = fd.isCtorDeclaration() !is null;
    if (!tf || (tf.isRef && !isCtor) || tf.parameterList.varargs != VarArg.none)
        return bail(fd, "func type shape");
    if (fd.isNested() && !ipNestedCallable(fd))
        return bail(fd, "nested/this");
    StructDeclaration thisSd;
    if (fd.needThis())
    {
        auto ad = fd.isThis();
        thisSd = ad ? ad.isStructDeclaration() : null;
        if (!thisSd || !thisExp)
            return bail(fd, "nested/this");
        if (!ipMemType(thisSd.type))
            return bail(fd, "this type");
        if (isCtor)
            thisExp = thisSd.type.defaultInitLiteral(loc);
        if (!thisExp || !thisExp.isStructLiteralExp())
            return bail(fd, "this not literal");
    }
    else
        thisExp = null;
    if (args.length != tf.parameterList.length)
        return bail(fd, "arg count");
    const rty = resultType.toBasetype().ty;
    if (isCtor ? !ipMemType(resultType) : rty != Tvoid && !ipResultType(resultType))
        return bail(fd, "result type");
    const bool zeroResult = !isCtor && rty == Tsarray && resultType.size() == 0;
    const bool sret = !isCtor && !zeroResult && (rty == Tstruct || rty == Tarray || rty == Tsarray || rty == Tdelegate);
    const bool refResult = !isCtor && (rty == Tclass || rty == Tpointer || rty == Taarray);

    wasmtime_val_t[32] vals;
    const bool nullCtx = !thisExp && fd.isNested();
    if (nullCtx)
    {
        import dmd.glue.e2ir : wasmCtfeNoFrame;
        ipSetP(vals[0], wasmCtfeNoFrame);
    }
    const size_t sretSlot = (thisExp || nullCtx) ? 1 : 0;
    const size_t argBase = sretSlot + (sret ? 1 : 0);
    size_t nvals = argBase;
    size_t memArgCount = 0;
    ulong memArgBytes = 0;
    enum ArgKind : ubyte { scalar, slice, block }
    ArgKind[vals.length] argKind;
    foreach (i, arg; args)
    {
        Parameter p = tf.parameterList[i];
        if (p.storageClass & (STC.ref_ | STC.out_ | STC.lazy_))
            return bail(fd, "param storage class");
        if (nvals + 2 > vals.length)
            return bail(fd, "too many args");
        if (ipArgType(p.type))
        {
            if (!ipArgMemSize(arg, memArgBytes))
                return bail(fd, "arg not literal");
            argKind[i] = ArgKind.slice;
            memArgCount++;
            nvals += 2;
        }
        else if (ipPtrArgType(p.type))
        {
            if (!arg.isStructLiteralExp() && !arg.isArrayLiteralExp() && !arg.isStringExp())
                return bail(fd, "arg not literal");
            memArgBytes += ipAlign16(p.type.size());
            if (!ipBlockTailSize(p.type, arg, memArgBytes))
                return bail(fd, "arg not literal");
            argKind[i] = ArgKind.block;
            memArgCount++;
            nvals += 1;
        }
        else if (!ipScalarType(p.type))
            return bail(fd, "param type");
        else if (!ipMarshalScalar(arg, vals[nvals++]))
            return bail(fd, "arg not literal scalar");
    }

    if (!isCtor)
        if (auto r = ipFoldConstBody(fd, resultType))
            return r;

    OutBuffer keyBuf;
    const exportName = mangleExact(fd).toDString;
    keyBuf.writestring(exportName);
    keyBuf.write((cast(const(void)*) &fd)[0 .. fd.sizeof]);
    if (thisExp)
    {
        ipAppendExpKey(thisExp, keyBuf);
        keyBuf.writeByte(0);
    }
    foreach (arg; args)
    {
        ipAppendExpKey(arg, keyBuf);
        keyBuf.writeByte(0);
    }
    if (auto sv = ipCacheFind(keyBuf[]))
        return sv.value;
    const writesBefore = ipCtfeWrites;

    wasmCtfeStats.attempts++;
    auto root = ipGetRoot(fd);
    if (!root)
        return null;
    auto ctx = ipProg.ctx;
    ipProg.running = true;
    scope (exit) ipEndRun(root);
    const tl = ipNow();
    wasm_trap_t* trap;

    wasmtime_memory_t mem = ipProg.mem;
    ulong sretAddr;
    ipHeapPtr = ipPageAlign(ipProg.liveEnd);
    ipHeapEnd = ipProg.memEnd;
    ulong sp = ipStackHigh();
    const ulong thisSize = thisExp ? cast(ulong) thisSd.type.size() : 0;
    if (sret || memArgCount || thisExp || refResult)
    {
        const size_t rsz = sret ? cast(size_t) resultType.size() : 0;
        const need = ipAlign16(rsz) + memArgBytes + ipAlign16(thisSize);
        import dmd.backend.wasm.selflink : wasmSelfLinkStackSize;
        ulong base;
        if (need + 65536 > wasmSelfLinkStackSize)
        {
            if (!ipHeapEnsure(need))
                return bail(fd, "arg memory");
            base = ipHeapPtr;
            ipHeapPtr = ipAlign16(base + need);
        }
        else
        {
            base = (sp - need) & ~15UL;
            sp = base;
        }
        auto data = ipMemSlice(ctx, mem);
        if (base + need > data.length)
            return bail(fd, "stack overflow");
        ulong cur = base;
        if (thisExp)
        {
            if (!ipEncodeVal(data, base, thisExp.type, thisExp))
                return bail(fd, "this encode");
            cur = base + ipAlign16(thisSize);
            ipSetP(vals[0], base);
        }
        size_t slot = argBase;
        foreach (i, arg; args)
        {
            final switch (argKind[i])
            {
                case ArgKind.scalar:
                    slot++;
                    break;
                case ArgKind.block:
                    auto pt = tf.parameterList[i].type;
                    ulong tail = cur + ipAlign16(pt.size());
                    if (!ipEncodeVal(data, cur, pt, arg, 0, &tail))
                        return bail(fd, "arg encode");
                    ipSetP(vals[slot++], cur);
                    cur = tail;
                    break;
                case ArgKind.slice:
                    ulong alen, aptr;
                    if (!ipEncodeArg(data, cur, arg, alen, aptr))
                        return bail(fd, "arg encode");
                    cur = ipAlign16(cur);
                    ipSetP(vals[slot++], alen);
                    ipSetP(vals[slot++], aptr);
                    break;
            }
        }
        if (sret)
        {
            sretAddr = cur;
            ipSetP(vals[sretSlot], sretAddr);
        }
    }

    ipErrKind = IpErrKind.none;
    ipErrNoBody = false;
    ipThrowCount = 0;
    ipErrnoCell = 0;
    ipAllocs.reset();
    ipUnionTagCount = 0;
    if (ipDecodeMemo.length)
    {
        ipDecodeMemo.setDim(0);
        ipMemoHead = null;
    }
    {
        wasmtime_val_t spVal;
        ipSetP(spVal, sp);
        if (auto err = wasmtime_global_set(ctx, &ipProg.sp, &spVal))
        {
            wasmtime_error_delete(err);
            return bail(fd, "stack pointer set");
        }
    }
    wasmtime_val_t[1] results;
    const nresults = (sret || zeroResult || rty == Tvoid) ? 0 : 1;
    ipDiscardRun = ipDiscardFd is fd;
    const tcall = ipNow();
    wasmCtfeStats.ticks[WasmCtfeStats.Phase.link] += tcall - tl;
    auto callErr = wasmtime_func_call(ctx, &root.func, vals.ptr, nvals, results.ptr, nresults, &trap);
    const tdec = ipNow();
    wasmCtfeStats.ticks[WasmCtfeStats.Phase.call] += tdec - tcall;
    scope (exit) wasmCtfeStats.ticks[WasmCtfeStats.Phase.decode] += ipNow() - tdec;
    ipDiscardRun = false;
    if (auto err = callErr)
    {
        ipLogError("call", fd, err);
        if (mode != WasmCtfeMode.verify && !ipLazyHit && ipErrKind == IpErrKind.none
            && ipThrowCount && !ipReplayAt)
        {
            wasmtime_error_delete(err);
            ipReplayPending = ipThrowCount;
            return null;
        }
        Expression ee;
        if (mode != WasmCtfeMode.verify && !ipLazyHit)
        {
            ee = ipReportTrap(null, err, ipMemSlice(ctx, mem));
        }
        wasmtime_error_delete(err);
        return ee;
    }
    if (trap)
    {
        if (verbose)
        {
            wasm_message_t msg;
            wasm_trap_message(trap, &msg);
            fprintf(stderr, "wasm-ctfe inproc: trap in %s: %.*s\n",
                fd.toPrettyChars(), cast(int) msg.size, msg.data);
            wasm_byte_vec_delete(&msg);
        }
        Expression ee;
        if (mode != WasmCtfeMode.verify && !ipLazyHit)
        {
            ee = ipReportTrap(trap, null, ipMemSlice(ctx, mem));
        }
        wasm_trap_delete(trap);
        return ee;
    }

    const(ubyte)[] memory()
    {
        return ipMemSlice(ctx, mem);
    }
    Expression resultExp;
    if (isCtor)
    {
        if (ipIsP(results[0]))
            resultExp = ipDecodeMem(memory(), ipValP(results[0]), resultType, loc);
    }
    else if (sret)
        resultExp = ipDecodeMem(memory(), sretAddr, resultType, loc);
    else if (zeroResult)
        resultExp = new ArrayLiteralExp(loc, resultType, new Expressions());
    else if (refResult)
    {
        if (ipIsP(results[0]))
            resultExp = ipDecodeRef(memory(), ipValP(results[0]), resultType, loc, 0);
    }
    else if (rty == Tvoid)
        resultExp = CTFEExp.voidexp;
    else if (rty == Tnull)
        resultExp = new NullExp(loc, resultType);
    else if (rty == Tvector)
    {
        if (results[0].kind == WASMTIME_V128)
            resultExp = ipDecodeMem(results[0].of.v128[], 0, resultType, loc);
    }
    else
        resultExp = ipDecodeScalar(results[0], resultType, loc);
    if (!resultExp)
    {
        if (verbose)
            fprintf(stderr, "wasm-ctfe inproc: result decode failed for %s\n", fd.toPrettyChars());
        return null;
    }
    wasmCtfeStats.successes++;
    ipCacheStore(keyBuf[], resultExp, writesBefore);
    if (verbose)
        fprintf(stderr, "wasm-ctfe inproc: ok %s -> %s\n", fd.toPrettyChars(), resultExp.toChars());
    return resultExp;
}

private bool ipScalarType(Type t)
{
    switch (t.toBasetype().ty)
    {
        case Tint8, Tuns8, Tint16, Tuns16, Tint32, Tuns32, Tint64, Tuns64,
             Tbool, Tchar, Twchar, Tdchar, Tfloat32, Tfloat64:
            return true;
        case Tfloat80:
            return wasmCtfeSoftRealTarget();
        default:
            return false;
    }
}

private bool ipMemType(Type t, int depth = 0)
{
    if (depth > 8)
        return false;
    auto tb = t.toBasetype();
    if (tb.ty == Tarray || tb.ty == Tsarray)
    {
        auto n = tb.nextOf();
        return ipScalarType(n) || ipMemType(n, depth + 1);
    }
    if (auto ts = tb.isTypeStruct())
    {
        auto sd = ts.sym;
        if (sd.sizeok != Sizeok.done || sd.isNested())
            return false;
        foreach (v; sd.fields)
        {
            if (v.overlapped)
                return false;
            if (!ipScalarType(v.type) && !ipMemType(v.type, depth + 1))
                return false;
        }
        return true;
    }
    return false;
}

private __gshared bool[void*] ipResultTypeOk;

private bool ipResultType(Type t)
{
    auto tb = t.toBasetype();
    if (ipScalarType(tb) || cast(void*) tb in ipResultTypeOk)
        return true;
    const ok = ipResultTypeAt(tb, 0);
    if (ok)
        ipResultTypeOk[cast(void*) tb] = true;
    return ok;
}

private bool ipResultTypeAt(Type t, int depth)
{
    if (depth > 8)
        return true;
    auto tb = t.toBasetype();
    if (ipScalarType(tb) || (depth && tb.ty == Tnoreturn))
        return true;
    switch (tb.ty)
    {
        case Tpointer:
            auto n = tb.nextOf().toBasetype();
            if (n.ty == Tvoid || n.ty == Tfunction)
                return true;
            return ipResultTypeAt(n, depth + 1);
        case Tdelegate, Tnull:
            return true;
        case Tclass:
            auto cd = tb.isTypeClass().sym;
            return !cd.isCPPinterface() && !cd.isCOMinterface();
        case Tarray:
            if (tb.nextOf().toBasetype().ty == Tvoid)
                return true;
            goto case Tsarray;
        case Tsarray:
            return ipResultTypeAt(tb.nextOf(), depth + 1);
        case Taarray:
            return ipResultTypeAt(tb.isTypeAArray().index, depth + 1) && ipResultTypeAt(tb.nextOf(), depth + 1);
        case Tvector:
            return ipScalarType(tb.isTypeVector().elementType());
        case Tstruct:
            auto sd = tb.isTypeStruct().sym;
            if (!sd.determineSize(sd.loc))
                return false;
            foreach (v; sd.fields)
                if (!ipResultTypeAt(v.type, depth + 1))
                    return false;
            return true;
        default:
            return false;
    }
}

private bool ipArgType(Type t)
{
    auto tb = t.toBasetype();
    return tb.ty == Tarray && ipScalarType(tb.nextOf());
}

private bool ipPtrArgType(Type t, int depth = 0)
{
    if (depth > 8)
        return false;
    auto tb = t.toBasetype();
    if (auto ts = tb.isTypeStruct())
    {
        return ts.sym.isPOD() && ipMemType(tb);
    }
    if (tb.ty == Tsarray)
    {
        auto n = tb.nextOf();
        return ipScalarType(n) || ipPtrArgType(n, depth + 1);
    }
    return false;
}

private ulong ipRead(const(ubyte)[] mem, ulong addr, size_t sz)
{
    ulong v;
    foreach (i; 0 .. sz)
        v |= (cast(ulong) mem[cast(size_t) addr + i]) << (8 * i);
    return v;
}

private Expression ipDecodeClassRef(const(ubyte)[] mem, ulong objAddr, Type type, Loc loc, int depth)
{
    import dmd.glue.tocsym : wasmCtfeFindClass, wasmCtfeHasSubclass;

    if (depth > ipDecodeMaxDepth)
        return null;
    if (objAddr == 0)
        return new NullExp(loc, type);
    ipComputeTIOffsets();
    auto tc = type.toBasetype().isTypeClass();
    if (!tc)
    {
        if (wasmCtfeTraceGen) fprintf(stderr, "wasm-ctfe classref: not class type\n");
        return null;
    }
    {
        import dmd.glue.tocsym : wasmCtfeTypeInfoByName;
        ulong base, sz;
        const(char)[] name;
        if (ipFindData(objAddr, base, sz, name) && base == objAddr)
            if (auto ptid = cast(string) name in wasmCtfeTypeInfoByName)
            {
                auto te = new TypeidExp(loc, (*ptid).tinfo);
                te.type = type;
                return te;
            }
    }
    const cpp = tc.sym.classKind == ClassKind.cpp;
    if (!cpp && !ipTINameOffset && (tc.sym.isInterfaceDeclaration() || wasmCtfeHasSubclass(tc.sym)))
    {
        if (wasmCtfeTraceGen) fprintf(stderr, "wasm-ctfe classref: no name offset\n");
        return null;
    }
    if (tc.sym.isInterfaceDeclaration())
    {
        if (tc.sym.isCPPinterface() || tc.sym.isCOMinterface())
            return null;
        ulong ivt, ii, off;
        if (!ipRdP(mem, objAddr, ivt) || !ipRdP(mem, ivt, ii) || !ipRdP(mem, ii + 3 * ipPS, off) || off > objAddr)
            return null;
        objAddr -= off;
    }
    ulong vtbl, ci, nlen, nptr;
    if (!ipRdP(mem, objAddr, vtbl) || (!cpp && !vtbl))
        return null;
    ClassDeclaration cd;
    if (auto p = vtbl in ipVtbls)
        cd = *p;
    else if (!cpp && ipTINameOffset)
    {
        if (!ipRdP(mem, vtbl, ci) || !ipRdP(mem, ci + ipTINameOffset, nlen) || !ipRdP(mem, ci + ipTINameOffset + ipPS, nptr))
        {
            if (wasmCtfeTraceGen) fprintf(stderr, "wasm-ctfe classref: read fail obj=%llx vtbl=%llx ci=%llx\n", objAddr, vtbl, ci);
            return null;
        }
        if (nlen > 1024 || nptr > mem.length || nlen > mem.length - nptr)
        {
            if (wasmCtfeTraceGen) fprintf(stderr, "wasm-ctfe classref: bad name slice len=%llx ptr=%llx\n", nlen, nptr);
            return null;
        }
        cd = wasmCtfeFindClass(cast(const(char)[]) mem[cast(size_t) nptr .. cast(size_t)(nptr + nlen)]);
    }
    else if (!wasmCtfeHasSubclass(tc.sym))
        cd = tc.sym;
    if (!cd)
    {
        if (wasmCtfeTraceGen) fprintf(stderr, "wasm-ctfe classref: no class for '%.*s'\n", cast(int) nlen, mem.ptr + nptr);
        return null;
    }
    for (auto c = cd; c; c = c.baseClass)
    {
        if (c.ident == Id.TypeInfo)
        {
            if (wasmCtfeTraceGen) fprintf(stderr, "wasm-ctfe classref: TypeInfo result\n");
            return null;
        }
    }
    if (auto memo = ipMemoFind(objAddr, cd.type))
        return new ClassReferenceExp(loc, cast(StructLiteralExp) memo, type);
    size_t total = 0;
    for (auto c = cd; c; c = c.baseClass)
        total += c.fields.length;
    if (total)
        total -= cd.hasMonitor();
    auto elems = ipNewExps(total);
    auto se = new StructLiteralExp(loc, cast(StructDeclaration) cd, elems, cd.type);
    se.type = cd.type;
    se.ownedByCtfe = OwnedBy.ctfe;
    ipMemoPush(objAddr, cd.type, se);
    ptrdiff_t soFar = total;
    for (auto c = cd; c; c = c.baseClass)
    {
        soFar -= c.fields.length;
        foreach (i, v; c.fields)
        {
            if (soFar + cast(ptrdiff_t) i < 0)
                break;
            if (ipOverlapSkipped(objAddr, c, i))
                continue;
            auto el = ipDecodeMem(mem, objAddr + v.offset, v.type, loc, depth + 1);
            if (!el)
            {
                if (wasmCtfeTraceGen) fprintf(stderr, "wasm-ctfe classref: field %s decode fail\n", v.toChars());
                return null;
            }
            (*elems)[soFar + i] = el;
        }
    }
    auto cre = new ClassReferenceExp(loc, se, type);
    return cre;
}

private struct IpMemo
{
    Type t;
    Expression e;
    uint next;
}

private __gshared Array!IpMemo ipDecodeMemo;
private __gshared uint[ulong] ipMemoHead;
private __gshared StringExp[][size_t] ipDataStrings;

public void wasmCtfeNoteString(StringExp se)
{
    if (wasmCGCtfeBuild)
        ipNoteDataString(se);
}

private void ipNoteDataString(StringExp se)
{
    if (se.type.nextOf().toBasetype().ty.isSomeChar())
        return;
    if (!ipDataString(se.peekData(), se.sz))
        ipDataStrings[se.peekData().length] ~= se;
}

private StringExp ipDataString(const(ubyte)[] bytes, size_t esz)
{
    if (auto l = bytes.length in ipDataStrings)
        foreach (se; *l)
            if (se.sz == esz && se.peekData() == bytes)
                return se;
    return null;
}

private enum ipDecodeMaxDepth = 400;

private __gshared ulong ipCtfeOrdersAddr;
private __gshared ClassDeclaration[ulong] ipVtbls;
private __gshared FuncDeclaration[] ipTableFuncs;
private __gshared WasmDataExtent[] ipDataExtents;
private __gshared WasmDataExtent[] ipPoisonExtents;

private Expression ipDecodeFuncPtr(ulong slot, ulong ctx, Type type, Loc loc)
{
    if (slot == 0 && ctx == 0)
        return new NullExp(loc, type);
    if (slot == 0 || slot > ipTableFuncs.length)
        return null;
    auto fd = ipTableFuncs[cast(size_t) slot - 1];
    if (!fd)
        return null;
    if (ctx && !(fd.isFuncLiteralDeclaration() && ipNestedFrameFree(fd)))
        return null;
    if (auto fld = fd.isFuncLiteralDeclaration())
    {
        auto fe = new FuncExp(loc, fld);
        fe.type = type;
        return fe;
    }
    if (type.toBasetype().ty == Tdelegate)
        return null;
    auto so = new SymOffExp(loc, fd, 0, false);
    so.type = type;
    return so;
}

private Expression ipDecodeAA(const(ubyte)[] mem, ulong impl, Type type, Loc loc, int depth)
{
    import dmd.typesem : alignsize;
    if (depth > ipDecodeMaxDepth)
        return null;
    auto taa = type.toBasetype().isTypeAArray();
    if (!taa)
        return null;
    if (impl == 0)
        return new NullExp(loc, type);
    if (auto memo = ipMemoFind(impl, taa))
        return memo;
    ulong[] ents;
    bool found;
    ulong olen, optr;
    if (ipCtfeOrdersAddr && ipRdP(mem, ipCtfeOrdersAddr, olen) && ipRdP(mem, ipCtfeOrdersAddr + ipPS, optr))
    {
        foreach (i; 0 .. olen)
        {
            ulong oimpl;
            if (!ipRdP(mem, optr + i * 3 * ipPS, oimpl))
                return null;
            if (oimpl == impl)
            {
                ulong elen, eptr;
                if (!ipRdP(mem, optr + i * 3 * ipPS + ipPS, elen) || !ipRdP(mem, optr + i * 3 * ipPS + 2 * ipPS, eptr))
                    return null;
                foreach (k; 0 .. elen)
                {
                    ulong ent;
                    if (!ipRdP(mem, eptr + k * ipPS, ent))
                        return null;
                    if (ent)
                        ents ~= ent;
                }
                found = true;
                break;
            }
        }
    }
    if (!found)
    {
        ulong blen, bptr;
        if (!ipRdP(mem, impl, blen) || !ipRdP(mem, impl + ipPS, bptr))
            return null;
        foreach (k; 0 .. blen)
        {
            ulong hash, ent;
            if (!ipRdP(mem, bptr + k * 2 * ipPS, hash) || !ipRdP(mem, bptr + k * 2 * ipPS + ipPS, ent))
                return null;
            if (ent && cast(long) hash < 0)
                ents ~= ent;
        }
    }
    auto kt = taa.index;
    auto vt = taa.next;
    const ksz = cast(ulong) kt.size();
    const va = cast(ulong) vt.alignsize();
    const voff = va ? (ksz + va - 1) / va * va : ksz;
    const n = ents.length;
    auto keys = ipNewExps(n);
    auto values = ipNewExps(n);
    auto aale = new AssocArrayLiteralExp(loc, keys, values);
    aale.type = type;
    aale.ownedByCtfe = OwnedBy.ctfe;
    ipMemoPush(impl, taa, aale);
    foreach (j, ent; ents)
    {
        auto k = ipDecodeMem(mem, ent, kt, loc, depth + 1);
        auto v = ipDecodeMem(mem, ent + voff, vt, loc, depth + 1);
        if (!k || !v)
            return null;
        (*keys)[j] = k;
        (*values)[j] = v;
    }
    return aale;
}

private void ipMemoPush(ulong addr, Type t, Expression e)
{
    auto head = addr in ipMemoHead;
    ipDecodeMemo.push(IpMemo(t, e, head ? *head : 0));
    ipMemoHead[addr] = cast(uint) ipDecodeMemo.length;
}

private Expression ipMemoFind(ulong addr, Type t)
{
    auto head = addr in ipMemoHead;
    for (uint i = head ? *head : 0; i; i = ipDecodeMemo[i - 1].next)
        if (ipDecodeMemo[i - 1].t.equivalent(t))
            return ipDecodeMemo[i - 1].e;
    return null;
}

private bool ipOverlapDominated(AggregateDeclaration sd, size_t i)
{
    auto v = sd.fields[i];
    if (!v.overlapped)
        return false;
    static bool explicitInit(VarDeclaration x)
    {
        return x._init && !x._init.isVoidInitializer();
    }
    foreach (j, w; sd.fields)
    {
        if (j == i || !v.isOverlappedWith(w))
            continue;
        if (explicitInit(w) != explicitInit(v) ? explicitInit(w) : j < i)
            return true;
    }
    return false;
}

private bool ipOverlapSkipped(ulong addr, AggregateDeclaration sd, size_t i)
{
    auto v = sd.fields[i];
    if (!v.overlapped)
        return false;
    if (ipTagged(addr + v.offset, v))
        return false;
    foreach (w; sd.fields)
        if (w !is v && w.overlapped && v.isOverlappedWith(w) && ipTagged(addr + w.offset, w))
            return true;
    return ipOverlapDominated(sd, i);
}

private bool ipFillStruct(const(ubyte)[] mem, ulong addr, StructDeclaration sd, Expressions* elems, Loc loc, int depth)
{
    foreach (i, v; sd.fields)
    {
        if (ipOverlapSkipped(addr, sd, i))
            continue;
        if (v.isThisDeclaration())
        {
            (*elems)[i] = new NullExp(loc, v.type);
            continue;
        }
        auto el = ipDecodeMem(mem, addr + v.offset, v.type, loc, depth + 1);
        if (!el)
        {
            if (wasmCtfeTraceGen) fprintf(stderr, "wasm-ctfe decode: field %s.%s failed\n", sd.toChars(), v.toChars());
            return false;
        }
        (*elems)[i] = el;
    }
    return true;
}

private Expression ipGlobalRef(const(char)[] name, ulong off, Type type, Loc loc)
{
    auto pv = cast(string) name in ipAddrGlobals;
    if (!pv)
        return null;
    auto soe = new SymOffExp(loc, *pv, off);
    soe.type = type;
    return soe;
}

private Expression ipDecodePtr(const(ubyte)[] mem, ulong p, Type type, Loc loc, int depth)
{
    if (depth > ipDecodeMaxDepth)
        return null;
    auto tb = type.toBasetype();
    import dmd.glue.e2ir : wasmCtfeIntPtrTag, wasmCtfeNoFrame;
    if (p == 0 || p == wasmCtfeNoFrame)
        return new NullExp(loc, type);
    if (p >= mem.length)
    {
        ulong base, asz;
        const(char)[] name;
        if (ipFindData(p, base, asz, name))
            if (auto g = ipGlobalRef(name, p - base, type, loc))
                return g;
        return new IntegerExp(loc, (ipPS == 4 ? p >= wasmCtfeIntPtrTag(4) : p >> 32 != 0) ? p ^ wasmCtfeIntPtrTag(ipPS) : p, type);
    }
    auto et = tb.nextOf();
    if (!et)
        return null;
    auto etb = et.toBasetype();
    if (etb.ty == Tvoid || etb.ty == Tfunction)
        return null;
    const esz = cast(ulong) etb.size();
    if (!esz)
        return null;
    ulong base, asz;
    bool isData;
    if (!ipFindAlloc(p, base, asz))
    {
        const(char)[] name;
        if (!ipFindData(p, base, asz, name))
            return null;
        isData = true;
        if (auto g = ipGlobalRef(name, p - base, type, loc))
            return g;
    }
    if ((p - base) % esz)
        return null;
    if (base > mem.length || asz > mem.length - base)
        return null;
    if (isData && etb.ty.isSomeChar() && asz >= esz + (p - base) && ipAllZero(mem[cast(size_t) (base + asz - esz) .. cast(size_t) (base + asz)]))
    {
        auto bytes = mem[cast(size_t) base .. cast(size_t) (base + asz)].dup;
        asz -= esz;
        auto se = new StringExp(loc, bytes[0 .. cast(size_t) asz], cast(size_t) (asz / esz), cast(ubyte) esz);
        se.ownedByCtfe = OwnedBy.ctfe;
        if (p == base)
        {
            se.type = type;
            return se;
        }
        se.type = et.immutableOf().arrayOf();
        auto ie = new IndexExp(loc, se, new IntegerExp(loc, (p - base) / esz, Type.tsize_t));
        ie.type = et;
        return new AddrExp(loc, ie, type);
    }
    if (auto ts = etb.isTypeStruct())
    {
        if (p == base && asz < 2 * esz)
        {
            auto sle = cast(StructLiteralExp) ipMemoFind(base, et);
            if (!sle)
            {
                auto sd = ts.sym;
                auto elems = ipNewExps(sd.fields.length);
                sle = new StructLiteralExp(loc, sd, elems, et);
                sle.type = et;
                sle.ownedByCtfe = OwnedBy.ctfe;
                ipMemoPush(base, et, sle);
                if (!ipFillStruct(mem, base, sd, elems, loc, depth))
                    return null;
            }
            auto ae = new AddrExp(loc, sle, type);
            return ae;
        }
    }
    const n = asz / esz;
    if (n == 0 || n > uint.max)
        return null;
    auto at = et.arrayOf();
    auto ale = cast(ArrayLiteralExp) ipMemoFind(base, at);
    if (!ale)
    {
        auto elems = ipNewExps(cast(size_t) n);
        ale = new ArrayLiteralExp(loc, at, elems);
        ale.ownedByCtfe = OwnedBy.ctfe;
        ipMemoPush(base, at, ale);
        if (!ipFillElems(mem, base, et, esz, elems, loc, depth))
            return null;
    }
    auto ie = new IndexExp(loc, ale, new IntegerExp(loc, (p - base) / esz, Type.tsize_t));
    ie.type = et;
    return new AddrExp(loc, ie, type);
}

private Expression ipDecodeRef(const(ubyte)[] mem, ulong p, Type type, Loc loc, int depth)
{
    auto tb = type.toBasetype();
    if (tb.ty == Tclass)
        return ipDecodeClassRef(mem, p, type, loc, depth);
    if (tb.ty == Taarray)
        return ipDecodeAA(mem, p, type, loc, depth);
    if (tb.nextOf().toBasetype().ty == Tfunction)
        return ipDecodeFuncPtr(p, 0, type, loc);
    return ipDecodePtr(mem, p, type, loc, depth);
}

private bool ipFillElems(const(ubyte)[] mem, ulong addr, Type et, ulong esz, Expressions* elems, Loc loc, int depth)
{
    foreach (i, ref el; (*elems)[])
    {
        el = ipDecodeMem(mem, addr + i * esz, et, loc, depth + 1);
        if (!el)
            return false;
    }
    return true;
}

private Expression ipDecodeMem(const(ubyte)[] mem, ulong addr, Type type, Loc loc, int depth = 0)
{
    if (depth > ipDecodeMaxDepth)
        return null;
    auto tb = type.toBasetype();
    const sz = cast(size_t) tb.size();
    if (addr > mem.length || sz > mem.length - addr)
        return null;
    if (tb.ty == Tnoreturn)
    {
        import dmd.typesem : defaultInit;
        return defaultInit(type, loc);
    }
    if (tb.ty == Tnull)
        return ipRead(mem, addr, ipPS) ? null : new NullExp(loc, type);
    if (tb.ty == Tclass || tb.ty == Tpointer || tb.ty == Taarray)
        return ipDecodeRef(mem, ipRead(mem, addr, ipPS), type, loc, depth + 1);
    if (tb.ty == Tdelegate)
        return ipDecodeFuncPtr(ipRead(mem, addr + ipPS, ipPS), ipRead(mem, addr, ipPS), type, loc);
    if (auto tv = tb.isTypeVector())
    {
        auto el = ipDecodeMem(mem, addr, tv.basetype, loc, depth + 1);
        if (!el)
            return null;
        auto ve = new VectorExp(loc, el, tb);
        ve.type = type;
        ve.dim = cast(uint) tv.basetype.isTypeSArray().dim.toInteger();
        ve.ownedByCtfe = OwnedBy.ctfe;
        return ve;
    }
    if (tb.ty == Tarray)
    {
        const len = ipRead(mem, addr, ipPS);
        const ptr = ipRead(mem, addr + ipPS, ipPS);
        if (len == 0 && ptr == 0)
        {
            auto ne = new NullExp(loc, type);
            return ne;
        }
        auto et = tb.nextOf();
        auto etb = et.toBasetype();
        const esz = cast(size_t) etb.size();
        if (len > uint.max)
            return null;
        const total = len * esz;
        if (ptr > mem.length || total > mem.length - ptr)
            return null;
        if (etb.ty.isSomeChar() || etb.ty == Tvoid)
        {
            auto bytes = cast(ubyte*) dmd.root.rmem.mem.xmalloc(cast(size_t) total + esz);
            bytes[0 .. cast(size_t) total] = mem[cast(size_t) ptr .. cast(size_t)(ptr + total)];
            bytes[cast(size_t) total .. cast(size_t) total + esz] = 0;
            auto se = new StringExp(loc, bytes[0 .. cast(size_t) total], cast(size_t) len, cast(ubyte) esz);
            se.type = type;
            se.committed = true;
            se.ownedByCtfe = OwnedBy.ctfe;
            return se;
        }
        if (auto ds = ipDataString(mem[cast(size_t) ptr .. cast(size_t)(ptr + total)], esz))
            if (ds.type.nextOf().toBasetype().ty == etb.ty)
                return ds.copy();
        auto elems = ipNewExps(cast(size_t) len);
        if (!ipFillElems(mem, ptr, et, esz, elems, loc, depth))
            return null;
        auto ale = new ArrayLiteralExp(loc, type, elems);
        ale.ownedByCtfe = OwnedBy.ctfe;
        return ale;
    }
    if (auto tsa = tb.isTypeSArray())
    {
        const n = cast(size_t) tsa.dim.toUInteger();
        auto et = tb.nextOf();
        const esz = cast(size_t) et.toBasetype().size();
        auto elems = ipNewExps(n);
        if (!ipFillElems(mem, addr, et, esz, elems, loc, depth))
            return null;
        auto ale = new ArrayLiteralExp(loc, type, elems);
        ale.ownedByCtfe = OwnedBy.ctfe;
        return ale;
    }
    if (auto ts = tb.isTypeStruct())
    {
        auto sd = ts.sym;
        auto elems = ipNewExps(sd.fields.length);
        if (!ipFillStruct(mem, addr, sd, elems, loc, depth))
            return null;
        auto sle = new StructLiteralExp(loc, sd, elems, type);
        sle.type = type;
        sle.ownedByCtfe = OwnedBy.ctfe;
        return sle;
    }
    if (tb.ty == Tfloat32)
    {
        float f;
        memcpy(&f, mem.ptr + cast(size_t) addr, 4);
        return new RealExp(loc, real_t(f), type);
    }
    if (tb.ty == Tfloat64)
    {
        double d;
        memcpy(&d, mem.ptr + cast(size_t) addr, 8);
        return new RealExp(loc, real_t(d), type);
    }
    if (tb.ty == Tfloat80)
    {
        if (!wasmCtfeSoftRealTarget())
            return null;
        return new RealExp(loc, ipLdReal(mem.ptr + cast(size_t) addr), type);
    }
    if (!ipScalarType(tb))
        return null;
    return new IntegerExp(loc, ipRead(mem, addr, sz), type);
}

private ulong ipAlign16(ulong n) nothrow @nogc
{
    return (n + 15) & ~15UL;
}

private bool ipArgMemSize(Expression arg, ref ulong total)
{
    if (arg.isNullExp())
        return true;
    if (auto se = arg.isStringExp())
    {
        total += ipAlign16(cast(ulong) se.len * se.sz);
        return true;
    }
    if (auto ale = arg.isArrayLiteralExp())
    {
        auto etb = arg.type.toBasetype().nextOf().toBasetype();
        const esz = cast(ulong) etb.size();
        const n = ale.elements ? ale.elements.length : 0;
        foreach (i; 0 .. n)
        {
            auto el = ale[i];
            if (!el || (!el.isIntegerExp() && !el.isRealExp()))
                return false;
        }
        total += ipAlign16(n * esz);
        return true;
    }
    return false;
}

private bool ipBlockTailSize(Type t, Expression e, ref ulong total, int depth = 0)
{
    if (depth > 64)
        return false;
    auto tb = t.toBasetype();
    if (tb.ty == Tarray)
        return ipArgMemSize(e, total);
    if (auto sle = e.isStructLiteralExp())
    {
        auto ts = tb.isTypeStruct();
        if (!ts)
            return false;
        const n = sle.elements ? sle.elements.length : 0;
        foreach (i, v; ts.sym.fields)
            if (i < n && (*sle.elements)[i] && !ipBlockTailSize(v.type, (*sle.elements)[i], total, depth + 1))
                return false;
    }
    else if (auto ale = e.isArrayLiteralExp())
    {
        foreach (i; 0 .. ale.elements ? ale.elements.length : 0)
            if (!ale[i] || !ipBlockTailSize(tb.nextOf(), ale[i], total, depth + 1))
                return false;
    }
    return true;
}

private void ipWrite(ubyte[] mem, ulong addr, ulong v, size_t sz)
{
    foreach (i; 0 .. sz)
        mem[cast(size_t) addr + i] = cast(ubyte)(v >> (8 * i));
}

private bool ipEncodeArg(ubyte[] mem, ref ulong cur, Expression arg, out ulong len, out ulong ptr)
{
    if (arg.isNullExp())
        return true;
    if (auto se = arg.isStringExp())
    {
        len = se.len;
        ptr = cur;
        const sz = se.sz;
        if (cur + len * sz > mem.length)
            return false;
        mem[cast(size_t) cur .. cast(size_t)(cur + len * sz)] = se.peekData();
        cur += len * sz;
        ipNoteDataString(se);
        return true;
    }
    if (auto ale = arg.isArrayLiteralExp())
    {
        auto etb = arg.type.toBasetype().nextOf().toBasetype();
        const esz = cast(size_t) etb.size();
        const n = ale.elements ? ale.elements.length : 0;
        len = n;
        ptr = cur;
        if (cur + n * esz > mem.length)
            return false;
        foreach (i; 0 .. n)
            if (!ipEncodeVal(mem, cur + i * esz, etb, ale[i]))
                return false;
        cur += n * esz;
        return true;
    }
    return false;
}

private bool ipEncodeVal(ubyte[] mem, ulong addr, Type t, Expression e, int depth = 0, ulong* tail = null)
{
    if (depth > 64)
        return false;
    auto tb = t.toBasetype();
    const sz = cast(size_t) tb.size();
    if (addr > mem.length || sz > mem.length - addr)
        return false;
    if (tail && tb.ty == Tarray)
    {
        ulong len, ptr;
        if (!ipEncodeArg(mem, *tail, e, len, ptr))
            return false;
        *tail = ipAlign16(*tail);
        ipWrite(mem, addr, len, ipPS);
        ipWrite(mem, addr + ipPS, ptr, ipPS);
        return true;
    }
    if (e.isNullExp())
    {
        mem[cast(size_t) addr .. cast(size_t) addr + sz] = 0;
        return true;
    }
    if (auto ie = e.isIntegerExp())
    {
        ipWrite(mem, addr, ie.toInteger(), sz);
        return true;
    }
    if (auto re = e.isRealExp())
    {
        if (sz > 8 && !(tb.ty == Tfloat80 && wasmCtfeSoftRealTarget()))
            return false;
        ipPutFloat(mem, addr, sz, re.value);
        return true;
    }
    if (auto sle = e.isStructLiteralExp())
    {
        auto ts = tb.isTypeStruct();
        if (!ts)
            return false;
        auto sd = ts.sym;
        mem[cast(size_t) addr .. cast(size_t) addr + sz] = 0;
        const n = sle.elements ? sle.elements.length : 0;
        foreach (i, v; sd.fields)
        {
            auto el = i < n ? (*sle.elements)[i] : null;
            if (!el)
                continue;
            if (!ipEncodeVal(mem, addr + v.offset, v.type, el, depth + 1, tail))
                return false;
        }
        return true;
    }
    if (auto se = e.isStringExp())
    {
        if (!tb.isTypeSArray())
            return false;
        const esz = se.sz;
        if (se.len * esz > sz)
            return false;
        mem[cast(size_t) addr .. cast(size_t) addr + se.len * esz] = se.peekData();
        return true;
    }
    if (auto ale = e.isArrayLiteralExp())
    {
        if (!tb.isTypeSArray())
            return false;
        auto et = tb.nextOf();
        const esz = cast(size_t) et.toBasetype().size();
        const n = ale.elements ? ale.elements.length : 0;
        if (n * esz > sz)
            return false;
        foreach (i; 0 .. n)
        {
            auto el = ale[i];
            if (!el || !ipEncodeVal(mem, addr + i * esz, et, el, depth + 1, tail))
                return false;
        }
        return true;
    }
    return false;
}

private bool ipMarshalScalar(Expression arg, ref wasmtime_val_t val)
{
    auto tb = arg.type ? arg.type.toBasetype() : null;
    if (!tb)
        return false;
    if (auto ie = arg.isIntegerExp())
    {
        if (tb.size() <= 4)
        {
            val.kind = WASMTIME_I32;
            val.of.i32 = cast(int) ie.toInteger();
        }
        else
        {
            val.kind = WASMTIME_I64;
            val.of.i64 = cast(long) ie.toInteger();
        }
        return true;
    }
    if (auto re = arg.isRealExp())
    {
        if (tb.ty == Tfloat32)
        {
            val.kind = WASMTIME_F32;
            val.of.f32 = cast(float) re.value;
        }
        else if (tb.ty == Tfloat64)
        {
            val.kind = WASMTIME_F64;
            val.of.f64 = cast(double) re.value;
        }
        else if (tb.ty == Tfloat80 && wasmCtfeSoftRealTarget())
            ipSetReal(val, re.value);
        else
            return false;
        return true;
    }
    return false;
}

private Expression ipDecodeScalar(ref wasmtime_val_t val, Type type, Loc loc)
{
    auto tb = type.toBasetype();
    if (!ipScalarType(tb))
        return null;
    const kind = tb.ty == Tfloat32 ? WASMTIME_F32 : tb.ty == Tfloat64 ? WASMTIME_F64
        : tb.ty == Tfloat80 ? WASMTIME_V128 : tb.size() <= 4 ? WASMTIME_I32 : WASMTIME_I64;
    return val.kind == kind ? ipDecodeMem(val.of.v128[], 0, type, loc) : null;
}

private Expressions* ipNewExps(size_t n)
{
    auto a = new Expressions(n);
    a.zero();
    return a;
}
}
