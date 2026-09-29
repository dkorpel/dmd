module dmd.wasmctfe;

version (NoBackend)
{
    import dmd.expression;
    import dmd.func;
    import dmd.location;
    import dmd.mtype;

    enum WasmCtfeMode
    {
        off,
        verify,
        inproc,
        strict,
    }

    WasmCtfeMode wasmCtfeMode() { return WasmCtfeMode.off; }
    bool wasmCtfeIsLiteral(Expression e) { return true; }
    const(char)* wasmCtfeLastReason() { return null; }
    bool wasmCtfeBuildActiveNow() { return false; }
    bool wasmCtfeCtfeBlockLowering() pure nothrow @nogc @trusted { return false; }
    bool wasmCtfeLoweringActive() pure nothrow @nogc @trusted { return false; }
    void wasmCtfeCompare(Expression e, Expression astResult, Expression wasmResult) { }
    Expression tryWasmCtfe(Expression e) { return null; }
    bool wasmCtfeTakeForcedSem3Error(FuncDeclaration fd) { return false; }
    void wasmCtfeSuspendMinstNull() { }
    void wasmCtfeResumeMinstNull() { }
}
else
{

import core.stdc.stdio;
import core.stdc.string;
import core.stdc.stdlib : getenv;

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
import dmd.root.file;
import dmd.root.filename;
import dmd.root.rmem;
import dmd.root.string : toDString;
import dmd.root.stringtable;
import dmd.statement;
import dmd.typesem : toBasetype, size, nextOf, defaultInitLiteral, arrayOf, equivalent, immutableOf;
import dmd.expressionsem : toInteger, toUInteger;
import dmd.funcsem : functionSemantic3, isVirtual, isVirtualMethod;
import dmd.dsymbolsem : isPOD, size;
import dmd.visitor;

enum WasmCtfeMode
{
    off,
    verify,
    inproc,
    strict,
}

struct WasmCtfeStats
{
    uint calls;
    uint attempts;
    uint successes;
    uint compileFailures;
    uint unsupported;
    uint illegal;
    uint cacheHits;
    uint mismatches;
}

__gshared WasmCtfeStats wasmCtfeStats;

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
private __gshared uint[] preSemSavedSuspend;

public void wasmCtfePreSemEnter()
{
    preSemSavedSuspend ~= buildActiveSuspended;
    buildActiveSuspended = 0;
    ++preSemDepth;
}

public void wasmCtfePreSemLeave()
{
    --preSemDepth;
    buildActiveSuspended = preSemSavedSuspend[$ - 1];
    preSemSavedSuspend = preSemSavedSuspend[0 .. $ - 1];
}

bool wasmCtfeBuildActiveNow()
{
    if (buildActiveSuspended)
        return false;
    if (wasmCtfeMode() == WasmCtfeMode.off)
        return false;
    if (preSemDepth)
        return true;
    import dmd.glue : wasmCtfeBuildInProgress;
    return wasmCtfeBuildInProgress();
}

bool wasmCtfeLoweringActive() pure nothrow @nogc @trusted
{
    alias FP = WasmCtfeMode function() pure nothrow @nogc;
    auto fp = cast(FP) &wasmCtfeMode;
    return fp() != WasmCtfeMode.off;
}

private bool wasmCtfeCtfeBlockLoweringImpl()
{
    return wasmCtfeMode() != WasmCtfeMode.off;
}

bool wasmCtfeCtfeBlockLowering() pure nothrow @nogc @trusted
{
    alias FP = bool function() pure nothrow @nogc;
    auto fp = cast(FP) &wasmCtfeCtfeBlockLoweringImpl;
    return fp();
}

private __gshared
{
    WasmCtfeMode mode = WasmCtfeMode.off;
    bool modeChecked = false;
    bool verbose = false;
    bool keepFiles = false;
    uint seq = 0;
    StringTable!(Expression) ipResultCache;
    bool ipCacheInit = false;
}

WasmCtfeMode wasmCtfeMode()
{
    if (modeChecked)
        return mode;
    modeChecked = true;
    version (Posix)
    {
        if (const p = getenv("DMD_CTFE"))
        {
            if (strcmp(p, "verify") == 0)
                mode = WasmCtfeMode.verify;
            else if (strcmp(p, "inproc") == 0)
                mode = WasmCtfeMode.inproc;
            else if (strcmp(p, "strict") == 0)
                mode = WasmCtfeMode.strict;
        }
        verbose = getenv("DMD_CTFE_VERBOSE") !is null;
        if (mode != WasmCtfeMode.off)
        {
            import core.stdc.stdlib : atexit;
            atexit(&wasmCtfeAtExit);
        }
        keepFiles = getenv("DMD_CTFE_KEEP") !is null;
    }
    return mode;
}

extern (C) void wasmCtfeAtExit()
{
    wasmCtfePrintStats();
}

void wasmCtfePrintStats()
{
    if (mode == WasmCtfeMode.off || !getenv("DMD_CTFE_STATS"))
        return;
    with (wasmCtfeStats)
        fprintf(stderr, "wasm-ctfe: calls=%u attempts=%u ok=%u compilefail=%u unsupported=%u illegal=%u cachehit=%u mismatch=%u\n",
            calls, attempts, successes, compileFailures, unsupported, illegal, cacheHits, mismatches);
}

private __gshared StructLiteralExp[2][] ipCmpStack;

private bool ipIsVthisField(AggregateDeclaration ad, size_t i, size_t n)
{
    auto cd = ad.isClassDeclaration();
    if (!cd)
        return i < ad.fields.length && ad.fields[i].isThisDeclaration() !is null;
    ptrdiff_t soFar = n;
    for (auto c = cd; c; c = c.baseClass)
    {
        soFar -= c.fields.length;
        if (cast(ptrdiff_t) i >= soFar && i < soFar + c.fields.length)
            return c.fields[i - soFar] is c.vthis || c.fields[i - soFar] is c.vthis2;
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
    if (auto wse = wasmResult.isStringExp())
    {
        if (auto ale = astResult.isArrayLiteralExp())
        {
            const n = ale.elements ? ale.elements.length : 0;
            if (n == wse.len)
            {
                bool same = true;
                foreach (i; 0 .. n)
                {
                    auto el = ale[i];
                    auto ie = el ? el.isIntegerExp() : null;
                    if (!ie || cast(ulong) ie.toInteger() != wse.getIndex(i))
                    {
                        same = false;
                        break;
                    }
                }
                if (same)
                    return true;
            }
        }
    }
    if (auto ase = astResult.isStringExp())
    {
        if (auto wale = wasmResult.isArrayLiteralExp())
        {
            const n = wale.elements ? wale.elements.length : 0;
            if (n == ase.len)
            {
                bool same = true;
                foreach (i; 0 .. n)
                {
                    auto el = wale[i];
                    auto ie = el ? el.isIntegerExp() : null;
                    if (!ie || cast(ulong) ie.toInteger() != ase.getIndex(i))
                    {
                        same = false;
                        break;
                    }
                }
                if (same)
                    return true;
            }
        }
    }
    if (auto wsl = wasmResult.isStructLiteralExp())
    {
        auto asl = astResult.isStructLiteralExp();
        foreach (p; ipCmpStack)
            if (p[0] is asl && p[1] is wsl)
                return true;
        ipCmpStack ~= [asl, wsl];
        scope (exit) ipCmpStack.length--;
        if (asl && asl.sd is wsl.sd && wsl.sd.isClassDeclaration())
        {
            auto cd = wsl.sd.isClassDeclaration();
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
        if (asl)
        {
            if (asl.sd is wsl.sd)
            {
                const n = wsl.elements ? wsl.elements.length : 0;
                const na = asl.elements ? asl.elements.length : 0;
                bool same = na <= n;
                foreach (i; 0 .. n)
                {
                    auto ael = i < na ? (*asl.elements)[i] : null;
                    if (!ael || !(*wsl.elements)[i] || ael.isVoidInitExp())
                        continue;
                    if (ael.isNullExp() && ipIsVthisField(wsl.sd, i, n))
                        continue;
                    if (!same || !ipResultEqual(ael, (*wsl.elements)[i], depth + 1))
                    {
                        same = false;
                        break;
                    }
                }
                if (same)
                    return true;
            }
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
            const na = aal.elements ? aal.elements.length : 0;
            if (n == na)
            {
                bool same = true;
                foreach (i; 0 .. n)
                {
                    auto ael = aal[i];
                    auto wel = wal[i];
                    if (!ael || !wel || !ipResultEqual(ael, wel, depth + 1))
                    {
                        same = false;
                        break;
                    }
                }
                if (same)
                    return true;
            }
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

private bool ipEncodeClassFields(ubyte[] buf, ClassDeclaration cd, Expressions* elems)
{
    bool overlaps;
    size_t total;
    for (auto c = cd; c; c = c.baseClass)
    {
        total += c.fields.length;
        foreach (v; c.fields)
            if (v.overlapped)
                overlaps = true;
    }
    if (!overlaps || !elems)
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
    wasmCtfeStats.calls++;
    if (auto v = ipCircularVar(e))
    {
        if (mode == WasmCtfeMode.verify)
            return null;
        global.errorSink.error(e.loc, "circular initialization of %s `%s`", v.kind(), v.toPrettyChars());
        return ErrorExp.get();
    }
    auto ce = e.isCallExp();
    if (ce && ce.f)
    {
        Expression thisExp;
        if (auto dve = ce.e1.isDotVarExp())
            thisExp = dve.e1;
        if (auto r = tryWasmCtfeInproc(ce.f, thisExp, ce.arguments ? (*ce.arguments)[] : null, e.type, e.loc))
            return r;
    }
    return tryWasmCtfeExpr(e);
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

import dmd.aggregate : AggregateDeclaration;
import dmd.dclass : ClassDeclaration, InterfaceDeclaration;
import dmd.dtemplate : TemplateDeclaration;
import dmd.aggregate : ClassKind;


private bool ipSoftReal()
{
    import dmd.target : target;
    return real.mant_dig == 64 && (target.realsize == 16 && target.realpad == 6
        || target.realsize == 12 && target.realpad == 2);
}

private void ipPutReal(ubyte[] mem, ulong addr, real r)
{
    import dmd.target : target;
    mem[cast(size_t) addr .. cast(size_t) addr + target.realsize] = 0;
    memcpy(mem.ptr + cast(size_t) addr, &r, 10);
}

private bool ipTypeBlocksEngine(Type t, int depth = 0)
{
    import dmd.typesem : isComplex, isImaginary;
    if (!t || depth > 8)
        return false;
    auto tb = t.toBasetype();
    if (tb.isComplex() || tb.isImaginary() || (tb.ty == Tfloat80 && !ipSoftReal()))
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
    if (f.hasDualContext || f.needThis() || ipReadsOuterLocals(f))
        return false;
    for (Dsymbol p = f.toParent2(); p; p = p.toParent2())
    {
        auto pf = p.isFuncDeclaration();
        if (!pf)
            return true;
        if (pf.hasNestedFrameRefs() || pf.hasDualContext)
            return false;
        if (!pf.isNested())
            return true;
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
        bool collect;
        bool[void*] declared;
        extern (D) void check(Declaration d)
        {
            auto v = d ? d.isVarDeclaration() : null;
            if (collect || !v || v.isDataseg() || (v.storage_class & STC.manifest))
                return;
            if (cast(void*) v in declared || wasmCtfeOuterConstInit(v))
                return;
            auto p = v.toParent2();
            if (p && p.isFuncDeclaration() && p !is f)
                stop = true;
        }
        override void visit(Expression) {}
        override void visit(VarExp e) { check(e.var); }
        override void visit(SymOffExp e) { check(e.var); }
        override void visit(DeclarationExp e)
        {
            if (auto vd = e.declaration ? e.declaration.isVarDeclaration() : null)
            {
                if (collect)
                    declared[cast(void*) vd] = true;
                if (auto ei = vd._init ? vd._init.isExpInitializer() : null)
                    if (ei.exp)
                        walkPostorder(ei.exp, this);
            }
        }
    }
    scope v = new OuterScan();
    v.f = f;
    foreach (collect; [true, false])
    {
        v.collect = collect;
        foreachExpAndVar(f.fbody, (Expression e) { if (!v.stop) walkPostorder(e, v); }, (VarDeclaration vd) {
            if (collect)
                v.declared[cast(void*) vd] = true;
            if (auto ei = !v.stop && vd._init ? vd._init.isExpInitializer() : null)
                if (ei.exp)
                    walkPostorder(ei.exp, v);
        });
    }
    return v.stop;
}

Expression wasmCtfeOuterConstInit(VarDeclaration v)
{
    import dmd.tokens : EXP;
    if (!v || !(v.isConst() || v.isImmutable()) || v.isReference() || v.isDataseg() || v.inuse)
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
    VarDeclarations* enclosingOut = null)
{
    import dmd.visitor.postorder : walkPostorder;
    extern (C++) final class Scan : StoppableVisitor
    {
        alias visit = typeof(super).visit;
        VarDeclarations declared;
        VarDeclarations funcLocals;
        const(char)* why;
        extern (D) void fail(const(char)* r)
        {
            if (!why)
                why = r;
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
        override void visit(VarExp e)
        {
            visit(cast(Expression) e);
            if (stop)
                return;
            auto vd = e.var ? e.var.isVarDeclaration() : null;
            if (vd && !vd.isDataseg() && !(vd.storage_class & STC.manifest)
                && vd.parent && vd.parent.isFuncDeclaration())
                funcLocals.push(vd);
        }
        override void visit(Expression e)
        {
            if (!e.type)
                return;
            if (ipTypeBlocksEngine(e.type))
                fail("blocked type");
        }
        override void visit(BinExp e)
        {
            import dmd.tokens : EXP;
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
                fail("array binop");
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
        override void visit(ThisExp)
        {
            fail("ThisExp");
        }
        override void visit(SuperExp)
        {
            fail("SuperExp");
        }
        override void visit(CallExp e)
        {
            visit(cast(Expression) e);
            if (stop || !e.f)
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
                if (ct.classKind == ClassKind.cpp && cf.classKind == ClassKind.cpp
                    && !ct.isInterfaceDeclaration() && !cf.isInterfaceDeclaration())
                    return;
                if (!ct.isBaseOf(cf, null))
                    fail("class or array cast");
            }
            else if (tb.ty == Tclass || fb.ty == Tclass)
                fail("class or array cast");
            else if (tb.ty == Tarray && fb.ty == Tarray
                && tb.nextOf().size() != fb.nextOf().size())
                fail("class or array cast");
        }
    }
    scope v = new Scan();
    if (walkPostorder(e, v))
    {
        why = v.why;
        return false;
    }
    if (declaredOut)
        foreach (dv; v.declared)
            declaredOut.push(dv);
    foreach (vd; v.funcLocals)
    {
        bool found = false;
        foreach (dv; v.declared)
            if (dv is vd)
            {
                found = true;
                break;
            }
        if (found)
            continue;
        if (!enclosingOut || !ipHoistEnclosing(vd, why, declaredOut, enclosingOut))
        {
            if (!why)
                why = "enclosing local";
            return false;
        }
    }
    return true;
}

private bool ipHoistEnclosing(VarDeclaration vd, out const(char)* why, VarDeclarations* declaredOut,
    VarDeclarations* enclosingOut)
{
    import dmd.init : ExpInitializer;
    foreach (ev; *enclosingOut)
        if (ev is vd)
            return true;
    if (!(vd.isConst() || vd.isImmutable()) || (vd.storage_class & (STC.parameter | STC.ref_ | STC.out_ | STC.lazy_)))
        return false;
    auto ei = vd._init ? vd._init.isExpInitializer() : null;
    if (!ei || !ei.exp || enclosingOut.length > 16)
        return false;
    enclosingOut.push(vd);
    if (!ipExprSupported(ei.exp, why, declaredOut, enclosingOut))
        return false;
    foreach (i, ev; *enclosingOut)
        if (ev is vd)
        {
            enclosingOut.remove(i);
            break;
        }
    enclosingOut.push(vd);
    return true;
}

private void ipAppendSymKey(Expression e, ref OutBuffer kb)
{
    import dmd.visitor.postorder : walkPostorder;
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
        override void visit(StringExp e) { lit(e); }
        override void visit(IntegerExp e) { lit(e); }
        override void visit(RealExp e) { lit(e); }
        extern (D) void lit(Expression e)
        {
            kb.writeByte(0);
            kb.writestring(e.toChars());
        }
        extern (D) void put(Dsymbol s)
        {
            kb.writeByte(0);
            kb.writestring(s.toPrettyChars());
            kb.printf("@%p", cast(void*) s);
        }
    }
    scope v = new SymKey();
    v.kb = &kb;
    walkPostorder(e, v);
}

private __gshared bool traceFallback = false;
private __gshared bool traceFallbackChecked = false;

private Expression ipFallback(Expression e, const(char)* reason)
{
    if (!traceFallbackChecked)
    {
        traceFallbackChecked = true;
        traceFallback = getenv("DMD_CTFE_TRACEFB") !is null;
    }
    if (traceFallback)
        fprintf(stderr, "wasm-ctfe fallback %s: %s: %s\n", reason, e.loc.toChars(), e.toChars());
    snprintf(ipLastReason.ptr, ipLastReason.length, "%s", reason);
    return null;
}

private __gshared char[128] ipLastReason;

const(char)* wasmCtfeLastReason()
{
    return ipLastReason[0] ? ipLastReason.ptr : null;
}

bool wasmCtfeIsLiteral(Expression e)
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

private bool ipIsLiteral(Expression e)
{
    return ipIsLiteralDeep(e, 0);
}

private bool ipIsLiteralElems(Expressions* es, int depth)
{
    if (es)
        foreach (el; *es)
            if (el && !ipIsLiteralDeep(el, depth + 1))
                return false;
    return true;
}

private bool ipIsLiteralDeep(Expression e, int depth)
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
        return (!ale.basis || ipIsLiteralDeep(ale.basis, depth + 1)) && ipIsLiteralElems(ale.elements, depth);
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

private Expression ipFoldNoCall(Expression e)
{
    import dmd.optimize : optimize;
    const oldGagged = global.startGagging();
    auto r = e.optimize(WANTvalue);
    if (global.endGagging(oldGagged))
        return null;
    if (r && r !is e && r.type && ipIsLiteral(r))
        return r;
    return null;
}

private Expression ipFoldLiteralCompare(Expression e)
{
    import dmd.optimize : optimize;
    import dmd.tokens : EXP;
    auto be = e.isBinExp();
    if (!be || !(e.isIdentityExp() || e.isEqualExp()))
        return null;
    const identity = e.isIdentityExp() !is null;
    const oldGagged = global.startGagging();
    auto e1 = be.e1.optimize(WANTvalue);
    auto e2 = be.e2.optimize(WANTvalue);
    if (global.endGagging(oldGagged))
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
    import dmd.tokens : EXP;
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
        import dmd.tokens : EXP;
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
        Expression r;
        auto ue = e.isUnaExp();
        if (!e.isBinExp())
        {
            auto a = fit(operand(ue.e1));
            if (!a)
                return null;
            r = e.op == EXP.negate ? new NegExp(e.loc, a) : new ComExp(e.loc, a);
        }
        else
        {
            auto be = e.isBinExp();
            auto a = operand(be.e1);
            auto b = operand(be.e2);
            if (!a || !b)
                return null;
            if (e.op != EXP.leftShift && e.op != EXP.rightShift && e.op != EXP.unsignedRightShift)
                b = fit(b);
            a = fit(a);
            switch (e.op)
            {
                case EXP.add: r = new AddExp(e.loc, a, b); break;
                case EXP.min: r = new MinExp(e.loc, a, b); break;
                case EXP.mul: r = new MulExp(e.loc, a, b); break;
                case EXP.div: r = new DivExp(e.loc, a, b); break;
                case EXP.mod: r = new ModExp(e.loc, a, b); break;
                case EXP.and: r = new AndExp(e.loc, a, b); break;
                case EXP.or: r = new OrExp(e.loc, a, b); break;
                case EXP.xor: r = new XorExp(e.loc, a, b); break;
                case EXP.leftShift: r = new ShlExp(e.loc, a, b); break;
                case EXP.rightShift: r = new ShrExp(e.loc, a, b); break;
                case EXP.unsignedRightShift: r = new UshrExp(e.loc, a, b); break;
                default: return null;
            }
        }
        r.type = et;
        if (ipArrayDepth(et))
            return ipLowerArrayOp(r);
        return r;
    }
    if (ipHasCall(e))
        return null;
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

private Expression ipLowerArrayOp(Expression e)
{
    const depth = ipArrayDepth(e.type);
    size_t n;
    if (!ipArrayOpLength(e, depth, n))
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

Expression tryWasmCtfeExpr(Expression e)
{
    if (ipIsLiteral(e))
        return null;
    if (auto te = e.isTupleExp())
    {
        if (te.e0 && !ipIsLiteral(te.e0))
            return ipFallback(e, "tuple");
        bool allLit = true;
        foreach (el; *te.exps)
            if (!ipIsLiteral(el))
                allLit = false;
        if (allLit)
            return null;
        auto exps = new Expressions(te.exps.length);
        foreach (i, el; *te.exps)
        {
            if (ipIsLiteral(el))
            {
                (*exps)[i] = el;
                continue;
            }
            if (!el.type || el.type.toBasetype().ty == Terror)
                return ipFallback(e, "tuple");
            auto r = tryWasmCtfeExpr(el);
            if (!r)
                return null;
            (*exps)[i] = r;
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
    if (auto ve = e.isVarExp())
        if (auto v = ve.var.isVarDeclaration())
            if (v.isDataseg() && (v.isConst() || v.isImmutable()) && v._init && v._init.semanticDone)
                if (auto ei = v._init.isExpInitializer())
                    if (ei.exp && ei.exp.isStringExp() && ei.exp.type && ei.exp.type.equals(e.type))
                        return ei.exp.copy();
    if (auto ae = e.isAddrExp())
        if (ae.e1.isThisExp())
            return e;
    if (ipIsArrayOpNode(e))
    {
        auto lowered = ipLowerArrayOp(e);
        if (!lowered)
            return ipFallback(e, "expr unsupported [array binop]");
        return tryWasmCtfeExpr(lowered);
    }
    if (auto ie = e.isIdentityExp())
    {
        auto te1 = ie.e1.isTypeidExp();
        auto te2 = ie.e2.isTypeidExp();
        if (te1 && te2)
        {
            import dmd.dtemplate : isType;
            import dmd.tokens : EXP;
            Type t1 = isType(te1.obj);
            Type t2 = isType(te2.obj);
            if (t1 && t2)
            {
                const same = t1 is t2;
                return new IntegerExp(e.loc, (ie.op == EXP.identity) == same ? 1 : 0, e.type);
            }
        }
    }
    if (!ipHasCall(e))
        if (auto r = ipFoldNoCall(e))
            return r;
    if (!ipHasCall(e))
        if (auto r = ipFoldLiteralCompare(e))
            return r;
    if (!ipResultType(e.type) && e.type.toBasetype().ty != Tvoid)
    {
        char[160] rb = void;
        snprintf(rb.ptr, rb.length, "expr type [%s]", e.type.toChars());
        return ipFallback(e, rb.ptr);
    }
    const(char)* unsupportedWhy;
    VarDeclarations declaredVars;
    VarDeclarations enclosingVars;
    if (!ipExprSupported(e, unsupportedWhy, &declaredVars, &enclosingVars))
    {
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
    kb.writestring(e.toChars());
    ipAppendSymKey(e, kb);
    if (!ipCacheInit)
    {
        ipResultCache._init(64);
        ipCacheInit = true;
    }
    if (auto sv = ipResultCache.lookup(kb[]))
    {
        wasmCtfeStats.cacheHits++;
        return sv.value;
    }
    auto tf = new TypeFunction(ParameterList(), e.type, LINK.d);
    auto fd = new FuncDeclaration(e.loc, e.loc, Identifier.generateId("__wasmctfe_expr"), STC.none, tf);
    fd.parent = mod;
    fd._linkage = LINK.d;
    Statement ret = new ReturnStatement(e.loc, e);
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
    ubyte[] savedDataseg;
    foreach (vd; declaredVars)
    {
        savedParents.push(vd.parent);
        savedDataseg ~= vd.isdataseg;
        vd.parent = fd;
        vd.isdataseg = 0;
    }
    foreach (vd; enclosingVars)
    {
        savedParents.push(vd.parent);
        vd.parent = fd;
    }
    const writesBefore = ipCtfeWrites;
    auto r = tryWasmCtfeInproc(fd, null, null, e.type, e.loc);
    foreach (i, vd; declaredVars)
    {
        vd.parent = savedParents[i];
        vd.isdataseg = savedDataseg[i];
    }
    foreach (i, vd; enclosingVars)
        vd.parent = savedParents[declaredVars.length + i];
    if (writesBefore == ipCtfeWrites)
        if (auto sv = ipResultCache.insert(kb[], null))
            sv.value = r;
    return r;
}

private:

bool scanLegality(FuncDeclaration fd, bool relaxed = false)
{
    bool[void*] inProgress;
    return scanLegalityImpl(fd, inProgress, relaxed) == 1;
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

private bool ipInstanceReady(Dsymbol s)
{
    for (Dsymbol p = s; p; p = p.parent)
        if (auto ti = p.isTemplateInstance())
            return ti.semanticRun >= PASS.semanticdone && !ti.errors;
    return false;
}

bool insideTemplateInstance(Dsymbol s)
{
    for (Dsymbol p = s; p; p = p.parent)
    {
        if (p.isTemplateInstance())
            return true;
    }
    return false;
}

__gshared byte[void*] legalityVerdicts;
__gshared byte[void*] legalityVerdictsRelaxed;
__gshared bool[void*] forcedSem3Errors;

public void ipForceSemantic3(FuncDeclaration fd)
{
    if (fd.semanticRun >= PASS.semantic3done)
        return;
    auto fdMod = fd.getModule();
    bool hostRooted = fdMod && fdMod.isRoot();
    for (Dsymbol p = fd; p; p = p.parent)
    {
        if (auto ti = p.isTemplateInstance())
        {
            hostRooted = ti.minst !is null;
            break;
        }
    }
    if (hostRooted)
        ++buildActiveSuspended;
    if (fd.deferred3 && fd._scope && fd.semanticRun < PASS.semantic3)
    {
        import dmd.semantic3 : semantic3;
        const oldGag = global.gag;
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
    if (cast(void*) fd in forcedSem3Errors)
    {
        forcedSem3Errors.remove(cast(void*) fd);
        return true;
    }
    return false;
}
enum attemptBudgetMax = 16;

int scanLegalityImpl(FuncDeclaration fd, ref bool[void*] inProgress, bool relaxed = false)
{
    auto verdicts = relaxed ? &legalityVerdictsRelaxed : &legalityVerdicts;
    if (auto p = cast(void*) fd in *verdicts)
        return *p == 1 ? 1 : 0;
    if (cast(void*) fd in inProgress)
        return 1;
    inProgress[cast(void*) fd] = true;

    if (trustedModule(fd) || wasmCtfeHostBuiltin(fd))
    {
        (*verdicts)[cast(void*) fd] = 1;
        return 1;
    }
    if (!fd.fbody || fd.errors)
    {
        const ok = isBuiltin(fd) != BUILTIN.unimp || (relaxed && !fd.fbody && !fd.errors);
        (*verdicts)[cast(void*) fd] = ok ? 1 : 0;
        return ok ? 1 : 0;
    }
    if (fd.semanticRun < PASS.semantic3done && (!insideTemplateInstance(fd) || ipInstanceReady(fd)))
        ipForceSemantic3(fd);
    if (fd.semanticRun < PASS.semantic3done)
    {
        inProgress.remove(cast(void*) fd);
        return 2;
    }
    Module mod = fd.getModule();
    if (!mod || !mod.srcfile.toChars())
    {
        (*verdicts)[cast(void*) fd] = 0;
        return 0;
    }

    scope scanner = new LegalityScanner();
    scanner.relaxed = relaxed;
    fd.fbody.accept(scanner);
    int verdict = scanner.bad ? 0 : 1;
    if (verdict == 1)
    {
        foreach (callee; scanner.callees)
        {
            const cv = scanLegalityImpl(callee, inProgress, relaxed);
            if (cv != 1)
            {
                verdict = cv;
                if (verbose)
                    fprintf(stderr, "wasm-ctfe: reject %s: callee %s%s\n", fd.toPrettyChars(), callee.toPrettyChars(), cv == 2 ? " (pending)".ptr : "".ptr);
                break;
            }
        }
    }
    else if (verbose && scanner.why)
        fprintf(stderr, "wasm-ctfe: reject %s: %s\n", fd.toPrettyChars(), scanner.why);
    if (verdict != 2)
        (*verdicts)[cast(void*) fd] = verdict == 1 ? 1 : 0;
    else
        inProgress.remove(cast(void*) fd);
    return verdict;
}

__gshared byte[void*] overlapVerdicts;

bool hasOverlaps(StructDeclaration sd)
{
    if (!sd)
        return false;
    if (auto p = cast(void*) sd in overlapVerdicts)
        return *p == 1;
    overlapVerdicts[cast(void*) sd] = 0;
    bool result = sd.isUnionDeclaration() !is null;
    if (!result)
    {
        foreach (v; sd.fields)
        {
            if (v.overlapped)
            {
                result = true;
                break;
            }
            auto tb = v.type ? v.type.toBasetype() : null;
            while (tb && (tb.ty == Tarray || tb.ty == Tsarray))
                tb = tb.nextOf().toBasetype();
            if (tb && tb.ty == Tstruct && hasOverlaps(tb.isTypeStruct().sym))
            {
                result = true;
                break;
            }
        }
    }
    overlapVerdicts[cast(void*) sd] = result ? 1 : 0;
    return result;
}

bool trustedModule(Dsymbol fd)
{
    Module mod = fd.getModule();
    if (!mod)
        return false;
    const name = mod.toPrettyChars().toDString();
    static immutable string[] trusted = [
        "core.internal.", "core.lifetime", "core.math", "core.bitop",
        "core.checkedint", "core.int128", "object", "rt.",
    ];
    foreach (t; trusted)
    {
        if (name.length >= t.length && name[0 .. t.length] == t)
        {
            if (t[$ - 1] == '.' || name.length == t.length || name[t.length] == '.')
                return true;
        }
    }
    return false;
}

extern (C++) final class LegalityScanner : SemanticTimeTransitiveVisitor
{
    alias visit = SemanticTimeTransitiveVisitor.visit;

    bool bad;
    bool relaxed;
    const(char)* why;
    FuncDeclarations callees;

    extern (D) this() scope
    {
    }

    void reject(const(char)* reason)
    {
        bad = true;
        if (!why)
            why = reason;
    }

    bool badType(Type t)
    {
        if (!t)
            return false;
        auto tb = t.toBasetype();
        if (relaxed)
            return false;
        switch (tb.ty)
        {
        case Tpointer:
        case Tfloat80, Timaginary32, Timaginary64, Timaginary80:
        case Tcomplex32, Tcomplex64, Tcomplex80:
        case Taarray:
        case Tclass:
        case Tdelegate:
            return true;
        case Tstruct:
            return hasOverlaps(tb.isTypeStruct().sym);
        default:
            return false;
        }
    }

    void checkExpType(Expression e)
    {
        if (e.isThisExp())
            return;
        if (badType(e.type))
            reject("unsupported type in body");
    }

    override void visit(Expression e)
    {
        checkExpType(e);
    }

    override void visit(CallExp e)
    {
        if (bad)
            return;
        checkExpType(e);
        FuncDeclaration f = e.f;
        if (!f)
        {
            if (auto dve = e.e1.isDotVarExp())
                f = dve.var.isFuncDeclaration();
            else if (auto ve = e.e1.isVarExp())
                f = ve.var.isFuncDeclaration();
        }
        if (!f)
        {
            if (!relaxed)
            {
                reject("indirect call");
                return;
            }
        }
        else if (f.isVirtualMethod() && !relaxed)
        {
            reject("virtual call");
            return;
        }
        if (f)
            callees.push(f);
        if (e.e1)
            e.e1.accept(this);
        if (e.arguments)
            foreach (arg; *e.arguments)
                if (arg)
                    arg.accept(this);
    }

    override void visit(VarExp e)
    {
        if (bad)
            return;
        if (e.var && e.var.ident == Id.ctfe)
            return;
        if (auto v = e.var ? e.var.isVarDeclaration() : null)
        {
            if (v.ident == Id.dollar && (v.storage_class & STC.ctfe) && v.isDataseg() && v._init)
            {
                if (auto ie = v._init.isExpInitializer())
                {
                    ie.exp.accept(this);
                    return;
                }
            }
            if (v.isDataseg() && !(v.storage_class & STC.manifest) && !(v.storage_class & STC.temp))
            {
                ipInitConstInitializer(v);
                if (v.type && !v.type.isImmutable() && !v.type.isConst() && !ipZeroSizeArray(v.type))
                {
                    if (!ipNotePoisonGlobal(v))
                        reject("mutable global");
                    checkExpType(e);
                    return;
                }
                if ((!v.type || !v._init || !v._init.semanticDone) && !ipZeroSizeArray(v.type))
                {
                    reject("mutable global");
                    return;
                }
                if (v.type && v.type.isImmutable())
                    ipNoteAddrGlobal(v);
            }
        }
        checkExpType(e);
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
        int ctfeCond = s.isIfCtfeBlock() ? 1 : 0;
        if (!ctfeCond)
            ctfeCond = ipCtfeCond(s.condition);
        if (!ctfeCond)
            return super.visit(s);
        if (auto live = ctfeCond > 0 ? s.ifbody : s.elsebody)
            live.accept(this);
    }

    override void visit(StructDeclaration) {}
    override void visit(UnionDeclaration) {}
    override void visit(ClassDeclaration) {}
    override void visit(InterfaceDeclaration) {}
    override void visit(TemplateDeclaration) {}

    override void visit(VarDeclaration v)
    {
        if (bad)
            return;
        if (v.storage_class & STC.manifest)
            return;
        if (v.semanticRun < PASS.semanticdone)
        {
            if (getenv("DMD_CTFE_TRACEGEN"))
                fprintf(stderr, "wasm-ctfe unresolved declaration %s at %s run=%d\n", v.toChars(), v.loc.toChars(), cast(int) v.semanticRun);
            reject("unresolved declaration");
            return;
        }
        if (v.isDataseg() && !(v.storage_class & STC.manifest) && !(v.storage_class & STC.temp))
        {
            if (v.type && !v.type.isImmutable() && !v.type.isConst() && !ipZeroSizeArray(v.type))
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
        if (badType(v.type))
        {
            reject("unsupported local type");
            return;
        }
        if (v._init)
            v._init.accept(this);
    }

    override void visit(SymOffExp e)
    {
        if (relaxed)
        {
            if (auto v = e.var ? e.var.isVarDeclaration() : null)
                if (v.isDataseg() && !(v.storage_class & STC.manifest) && !(v.storage_class & STC.temp))
                {
                    if (v.type && !v.type.isImmutable() && !v.type.isConst() && !ipNotePoisonGlobal(v))
                        reject("address of global");
                    ipNoteAddrGlobal(v);
                }
            return;
        }
        reject("address of symbol");
    }

    override void visit(AddrExp e)
    {
        if (relaxed)
        {
            super.visit(e);
            return;
        }
        reject("address taken");
    }

    override void visit(PtrExp e)
    {
        if (relaxed)
        {
            super.visit(e);
            return;
        }
        reject("pointer dereference");
    }

    override void visit(DeleteExp e)
    {
        if (!relaxed)
            reject("delete");
        else
            super.visit(e);
    }

    override void visit(NewExp e)
    {
        if (bad)
            return;
        if (!relaxed && e.type && e.type.toBasetype().ty == Tclass)
        {
            reject("class new");
            return;
        }
        if (e.member)
            callees.push(e.member);
        if (e.arguments)
            foreach (arg; *e.arguments)
                if (arg)
                    arg.accept(this);
        if (e.lowering)
            e.lowering.accept(this);
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

    wasm_engine_t* ipEngine;

    struct IpModule
    {
        wasmtime_module_t* mod;
        const(char)[] exportName;
        HostImport*[] hostImports;
        ulong ctfeOrdersAddr;
        FuncDeclaration[] tableFuncs;
        ClassDeclaration[ulong] cppVtbls;
    }

    IpModule*[void*] ipModuleCache;
    bool[void*] ipModuleFailed;

    char[512] ipTrapBuf;
}

private struct HostImport
{
    char[128] name;
    size_t nameLen;
    int softOp = -1;
    FuncDeclaration builtinFd;
    FuncDeclaration lazyFd;
    int cAlloc;
    const(char)* stubWhy;
}

private extern (C) wasm_trap_t* ipHostStubbed(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    auto hi = cast(HostImport*) env;
    return ipTrap(hi.stubWhy);
}

private __gshared FuncDeclaration ipLazyHit;

private extern (C) wasm_trap_t* ipHostLazy(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    auto hi = cast(HostImport*) env;
    ipLazyHit = hi.lazyFd;
    return ipTrap("wasm-ctfe: virtual function needs semantic");
}

public __gshared FuncDeclaration[string] wasmCtfeBuiltinFds;

public bool wasmCtfeHostBuiltin(FuncDeclaration fd)
{
    const b = isBuiltin(fd);
    return b != BUILTIN.unimp && b != BUILTIN.unknown;
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
    if (dst > mem.length || 16 > mem.length - dst || src > mem.length)
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
        if (16 > mem.length - src)
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
    if (auto trap = ipBumpAlloc(caller, m, oldBytes + addBytes, r))
        return trap;
    mem = ipMemSlice(caller, m);
    memmove(mem.ptr + r, mem.ptr + ptr, cast(size_t) oldBytes);
    memmove(mem.ptr + r + oldBytes, mem.ptr + sptr, cast(size_t) addBytes);
    const nlen = len + n;
    ipStP(mem.ptr + dst, nlen);
    ipStP(mem.ptr + dst + ipPS, r);
    return null;
}

private __gshared size_t ipCtfeWrites;

private extern (C) wasm_trap_t* ipHostCtfeWrite(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
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
        if (a > mem.length || 16 > mem.length - a)
            return ipTrap("wasm-ctfe: __ctfeWrite out of bounds");
        len = ipLdP(mem.ptr + a);
        ptr = ipLdP(mem.ptr + a + ipPS);
    }
    else
        return ipTrap("wasm-ctfe: __ctfeWrite signature");
    if (ptr > mem.length || len > mem.length - ptr)
        return ipTrap("wasm-ctfe: __ctfeWrite out of bounds");
    ipCtfeWrites++;
    alias ModeFn = WasmCtfeMode function() nothrow @nogc;
    if ((cast(ModeFn) &wasmCtfeMode)() != WasmCtfeMode.verify)
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
    auto fd = hi.builtinFd;
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
    const un = a != a || b != b;
    switch (op)
    {
        case OPeqeq: return a == b;
        case OPne: return a != b;
        case OPlt: return a < b;
        case OPle: return a <= b;
        case OPgt: return a > b;
        case OPge: return a >= b;
        case OPunord, OPnleg: return un;
        case OPord, OPleg: return !un;
        case OPlg, OPnue: return !un && a != b;
        case OPue, OPnlg: return un || a == b;
        case OPule, OPngt: return un || a <= b;
        case OPul, OPnge: return un || a < b;
        case OPuge, OPnlt: return un || a >= b;
        case OPug, OPnle: return un || a > b;
        case OPnule: return !un && a > b;
        case OPnul: return !un && a >= b;
        case OPnuge: return !un && a < b;
        case OPnug: return !un && a <= b;
        default: return 0;
    }
}

private extern (C) wasm_trap_t* ipHostSoftReal(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    import dmd.wasmtimec;
    import dmd.backend.wasm.softreal : SR;
    static import core.math;
    auto hi = cast(HostImport*) env;
    static real ar(ref const wasmtime_val_t v)
    {
        real r = 0;
        memcpy(&r, v.of.v128.ptr, 10);
        return r;
    }
    void setR(real r)
    {
        results[0].kind = WASMTIME_V128;
        results[0].of.v128[] = 0;
        memcpy(results[0].of.v128.ptr, &r, 10);
    }
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
    switch (cast(SR) hi.softOp)
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
        default: return ipTrap("wasm-ctfe: bad soft real op");
    }
    return null;
}

private extern (C) wasm_trap_t* ipHostStub(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    auto hi = cast(HostImport*) env;
    const n = snprintf(ipTrapBuf.ptr, ipTrapBuf.length,
        "wasm-ctfe: unimplemented runtime call %.*s",
        cast(int) hi.nameLen, hi.name.ptr);
    return wasmtime_trap_new(ipTrapBuf.ptr, n);
}

private __gshared
{
    ulong ipHeapPtr;
    ulong ipHeapEnd;
    ulong ipErrnoCell;
    ulong* ipAllocBase;
    ulong* ipAllocSize;
    size_t ipAllocCount;
    size_t ipAllocCap;
}

private void ipRecordAlloc(ulong base, ulong sz) nothrow @nogc
{
    import core.stdc.stdlib : realloc;
    if (ipAllocCount == ipAllocCap)
    {
        ipAllocCap = ipAllocCap ? ipAllocCap * 2 : 256;
        ipAllocBase = cast(ulong*) realloc(ipAllocBase, ipAllocCap * ulong.sizeof);
        ipAllocSize = cast(ulong*) realloc(ipAllocSize, ipAllocCap * ulong.sizeof);
    }
    ipAllocBase[ipAllocCount] = base;
    ipAllocSize[ipAllocCount] = sz;
    ipAllocCount++;
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

private __gshared bool[VarDeclaration] ipAddrNoted;

private void ipNoteAddrGlobal(VarDeclaration v)
{
    if (v in ipAddrNoted)
        return;
    ipAddrNoted[v] = true;
    OutBuffer buf;
    mangleToBuffer(v, buf);
    ipAddrGlobals[cast(string) buf.extractSlice()] = v;
}

private __gshared bool[VarDeclaration] ipPoisonNoted;

private bool ipNotePoisonGlobal(VarDeclaration v)
{
    import dmd.backend.wasm.selflink : wasmSelfLinkPoisonNames;
    if (v in ipPoisonNoted)
        return true;
    if (trustedModule(v))
        return false;
    ipPoisonNoted[v] = true;
    ipNoteAddrGlobal(v);
    OutBuffer buf;
    mangleToBuffer(v, buf);
    wasmSelfLinkPoisonNames[cast(string) buf.extractSlice()] = true;
    return true;
}

private bool ipFindData(ulong p, out ulong base, out ulong sz, out const(char)[] name)
{
    import dmd.backend.wasm.selflink : wasmSelfLinkDataExtents;
    size_t lo = 0, hi = wasmSelfLinkDataExtents.length;
    while (lo < hi)
    {
        const mid = (lo + hi) / 2;
        if (wasmSelfLinkDataExtents[mid].start <= p)
            lo = mid + 1;
        else
            hi = mid;
    }
    if (lo == 0)
        return false;
    base = wasmSelfLinkDataExtents[lo - 1].start;
    sz = wasmSelfLinkDataExtents[lo - 1].size;
    name = wasmSelfLinkDataExtents[lo - 1].name;
    return p < base + sz;
}

private bool ipZeroSizeArray(Type t)
{
    auto tsa = t ? t.toBasetype().isTypeSArray() : null;
    return tsa && tsa.dim && tsa.dim.isIntegerExp() && tsa.dim.toInteger() == 0;
}

private bool ipIsCharType(Type t)
{
    return t.ty == Tchar || t.ty == Twchar || t.ty == Tdchar;
}

private bool ipAllZero(const(ubyte)[] b)
{
    foreach (x; b)
        if (x)
            return false;
    return true;
}

private bool ipFindAlloc(ulong p, out ulong base, out ulong sz) nothrow @nogc
{
    size_t lo = 0, hi = ipAllocCount;
    while (lo < hi)
    {
        const mid = (lo + hi) / 2;
        if (ipAllocBase[mid] <= p)
            lo = mid + 1;
        else
            hi = mid;
    }
    if (lo == 0)
        return false;
    base = ipAllocBase[lo - 1];
    sz = ipAllocSize[lo - 1];
    return p < base + sz || p == base;
}

private wasm_trap_t* ipTrap(const(char)* msg) nothrow @nogc
{
    import dmd.wasmtimec;
    return wasmtime_trap_new(msg, strlen(msg));
}

private __gshared uint ipPS = 8;

private ulong ipValP(ref const wasmtime_val_t v) nothrow @nogc
{
    return v.kind == WASMTIME_I32 ? cast(ulong) cast(uint) v.of.i32 : cast(ulong) v.of.i64;
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

private void ipStP(ubyte* p, ulong v) nothrow @nogc
{
    memcpy(p, &v, ipPS);
}

private bool ipCallerMemory(wasmtime_caller_t* caller, out wasmtime_memory_t m) nothrow @nogc
{
    import dmd.wasmtimec;
    wasmtime_extern_t ext;
    if (!wasmtime_caller_export_get(caller, "memory".ptr, "memory".length, &ext)
        || ext.kind != WASMTIME_EXTERN_MEMORY)
        return false;
    m = ext.of.memory;
    return true;
}

private wasm_trap_t* ipBumpAlloc(wasmtime_caller_t* caller, ref wasmtime_memory_t m, ulong sz, out ulong r) nothrow @nogc
{
    import dmd.wasmtimec;
    auto ctx = wasmtime_caller_context(caller);
    const reqSz = sz;
    sz = (sz + 15) & ~15UL;
    if (!sz)
        sz = 16;
    if (sz > (1UL << 32))
        return ipTrap("wasm-ctfe: allocation too large");
    if (!ipHeapPtr || ipHeapPtr + sz > ipHeapEnd)
    {
        ulong pages = (sz >> 16) + 16;
        ulong prevPages;
        if (auto err = wasmtime_memory_grow(ctx, &m, pages, &prevPages))
        {
            wasmtime_error_delete(err);
            return ipTrap("wasm-ctfe: out of memory");
        }
        ipHeapPtr = prevPages << 16;
        ipHeapEnd = (prevPages + pages) << 16;
    }
    r = ipHeapPtr;
    ipHeapPtr += sz;
    ipRecordAlloc(r, reqSz);
    return null;
}

private extern (C) wasm_trap_t* ipHostGcMalloc(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    import dmd.wasmtimec;
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
    import dmd.wasmtimec;
    auto hi = cast(HostImport*) env;
    wasmtime_memory_t m;
    if (!ipCallerMemory(caller, m))
        return ipTrap("wasm-ctfe: no memory export");
    ulong old, oldSz, sz;
    if (hi.cAlloc == 1)
        sz = ipValP(args[0]);
    else if (hi.cAlloc == 2)
        sz = ipValP(args[0]) * ipValP(args[1]);
    else if (hi.cAlloc == 3)
    {
        old = ipValP(args[0]);
        sz = ipValP(args[1]);
        ulong base;
        if (old && (!ipFindAlloc(old, base, oldSz) || base != old))
            return ipTrap("wasm-ctfe: realloc of unknown pointer");
    }
    else
    {
        if (!ipErrnoCell)
        {
            if (auto trap = ipBumpAlloc(caller, m, 4, ipErrnoCell))
                return trap;
            memset(ipMemSlice(caller, m).ptr + ipErrnoCell, 0, 4);
        }
        ipSetP(results[0], ipErrnoCell);
        return null;
    }
    ulong r;
    if (auto trap = ipBumpAlloc(caller, m, sz, r))
        return trap;
    auto mem = ipMemSlice(caller, m);
    memset(mem.ptr + r, 0, cast(size_t) sz);
    if (old)
        memcpy(mem.ptr + r, mem.ptr + old, cast(size_t) (oldSz < sz ? oldSz : sz));
    ipSetP(results[0], r);
    return null;
}

private extern (C) wasm_trap_t* ipHostAApply(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    alias Impl = wasm_trap_t* function(HostImport*, wasmtime_caller_t*, const(wasmtime_val_t)*, wasmtime_val_t*) nothrow @nogc;
    return (cast(Impl) &ipHostAApplyImpl)(cast(HostImport*) env, caller, args, results);
}

private bool ipDecodeAt(const(ubyte)[] mem, ulong base, ulong len, int w, ref ulong i, out dchar c)
{
    ulong unit(ulong k)
    {
        const a = base + k * w;
        return w == 1 ? mem[cast(size_t) a] : w == 2 ? *cast(ushort*)(mem.ptr + a) : *cast(uint*)(mem.ptr + a);
    }
    const u = unit(i);
    if (w == 4)
    {
        c = cast(dchar) u;
        i++;
        return u < 0xD800 || (u > 0xDFFF && u <= 0x10FFFF);
    }
    if (w == 2)
    {
        if (u < 0xD800 || u > 0xDFFF)
        {
            c = cast(dchar) u;
            i++;
            return true;
        }
        if (u > 0xDBFF || i + 1 >= len)
            return false;
        const u2 = unit(i + 1);
        if (u2 < 0xDC00 || u2 > 0xDFFF)
            return false;
        c = cast(dchar)(((u - 0xD800) << 10) + (u2 - 0xDC00) + 0x10000);
        i += 2;
        return true;
    }
    if (u < 0x80)
    {
        c = cast(dchar) u;
        i++;
        return true;
    }
    int n = u >= 0xF0 && u < 0xF8 ? 3 : u >= 0xE0 ? 2 : u >= 0xC2 ? 1 : 0;
    if (!n || u >= 0xF8 || i + n >= len)
        return false;
    ulong v = u & (0x3F >> n);
    foreach (k; 1 .. n + 1)
    {
        const b = unit(i + k);
        if ((b & 0xC0) != 0x80)
            return false;
        v = (v << 6) | (b & 0x3F);
    }
    if ((n == 2 && v < 0x800) || (n == 3 && (v < 0x10000 || v > 0x10FFFF)) || (v >= 0xD800 && v <= 0xDFFF))
        return false;
    c = cast(dchar) v;
    i += n + 1;
    return true;
}

private wasm_trap_t* ipHostAApplyImpl(HostImport* hi, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, wasmtime_val_t* results)
{
    import dmd.wasmtimec;
    const nm = hi.name[0 .. hi.nameLen];
    const rev = nm[7] == 'R';
    const sc = nm[rev ? 8 : 7];
    const dc = nm[rev ? 9 : 8];
    const two = nm[$ - 1] == '2';
    const int sw = sc == 'c' ? 1 : sc == 'w' ? 2 : 4;
    const int dw = dc == 'c' ? 1 : dc == 'w' ? 2 : 4;
    const len = ipValP(args[0]);
    const ptr = ipValP(args[1]);
    const dctx = ipValP(args[2]);
    const fidx = ipValP(args[3]);
    auto ctx = wasmtime_caller_context(caller);
    wasmtime_memory_t m;
    if (!ipCallerMemory(caller, m))
        return ipTrap("wasm-ctfe: no memory export");
    wasmtime_extern_t ext;
    if (!wasmtime_caller_export_get(caller, "__indirect_function_table".ptr, "__indirect_function_table".length, &ext)
        || ext.kind != WASMTIME_EXTERN_TABLE)
        return ipTrap("wasm-ctfe: no table export");
    wasmtime_val_t fv;
    if (!wasmtime_table_get(ctx, &ext.of.table, fidx, &fv) || fv.kind != WASMTIME_FUNCREF)
        return ipTrap("wasm-ctfe: bad delegate in foreach");
    ulong tmp;
    if (auto trap = ipBumpAlloc(caller, m, 16, tmp))
        return trap;
    {
        auto mem = ipMemSlice(caller, m);
        if (ptr > mem.length || len * sw > mem.length - ptr)
            return ipTrap("wasm-ctfe: foreach string out of bounds");
    }
    ulong pos = rev ? len : 0;
    int result = 0;
    while (rev ? pos > 0 : pos < len)
    {
        auto mem = ipMemSlice(caller, m);
        ulong start = pos;
        if (rev)
        {
            start = pos - 1;
            if (sw == 1)
                while (start > 0 && (mem[cast(size_t)(ptr + start)] & 0xC0) == 0x80 && pos - start < 4)
                    start--;
            else if (sw == 2)
            {
                const u = *cast(ushort*)(mem.ptr + ptr + start * 2);
                if (u >= 0xDC00 && u <= 0xDFFF && start > 0)
                    start--;
            }
        }
        ulong next = start;
        dchar c;
        if (!ipDecodeAt(mem, ptr, len, sw, next, c) || (rev && next != pos))
            return ipTrap("wasm-ctfe: invalid UTF sequence in foreach");
        uint[4] units;
        int nunits;
        if (dw == 4)
            units[nunits++] = c;
        else if (dw == 2)
        {
            if (c <= 0xFFFF)
                units[nunits++] = c;
            else
            {
                units[nunits++] = 0xD800 + ((c - 0x10000) >> 10);
                units[nunits++] = 0xDC00 + ((c - 0x10000) & 0x3FF);
            }
        }
        else if (c < 0x80)
            units[nunits++] = c;
        else if (c < 0x800)
        {
            units[nunits++] = 0xC0 | (c >> 6);
            units[nunits++] = 0x80 | (c & 0x3F);
        }
        else if (c < 0x10000)
        {
            units[nunits++] = 0xE0 | (c >> 12);
            units[nunits++] = 0x80 | ((c >> 6) & 0x3F);
            units[nunits++] = 0x80 | (c & 0x3F);
        }
        else
        {
            units[nunits++] = 0xF0 | (c >> 18);
            units[nunits++] = 0x80 | ((c >> 12) & 0x3F);
            units[nunits++] = 0x80 | ((c >> 6) & 0x3F);
            units[nunits++] = 0x80 | (c & 0x3F);
        }
        foreach (k; 0 .. nunits)
        {
            mem = ipMemSlice(caller, m);
            ipStP(mem.ptr + tmp, start);
            if (dw == 1)
                mem[cast(size_t)(tmp + 8)] = cast(ubyte) units[k];
            else if (dw == 2)
                *cast(ushort*)(mem.ptr + tmp + 8) = cast(ushort) units[k];
            else
                *cast(uint*)(mem.ptr + tmp + 8) = units[k];
            wasmtime_val_t[3] cargs;
            ipSetP(cargs[0], dctx);
            size_t na = 1;
            if (two)
                ipSetP(cargs[na++], tmp);
            ipSetP(cargs[na++], tmp + 8);
            wasmtime_val_t[1] res;
            wasm_trap_t* trap;
            if (auto err = wasmtime_func_call(ctx, &fv.of.funcref, cargs.ptr, na, res.ptr, 1, &trap))
            {
                wasmtime_error_delete(err);
                return ipTrap("wasm-ctfe: foreach body call failed");
            }
            if (trap)
                return trap;
            result = res[0].of.i32;
            if (result)
                break;
        }
        if (result)
            break;
        pos = rev ? start : next;
    }
    results[0].kind = WASMTIME_I32;
    results[0].of.i32 = result;
    return null;
}

private __gshared ulong ipTIBaseOffset;
private __gshared ulong ipTINameOffset;
private __gshared ulong ipTIInvOffset;

private void ipComputeTIOffsets() nothrow
{
    if (ipTIBaseOffset || ipTINameOffset)
        return;
    auto cd = Type.typeinfoclass;
    if (!cd)
        return;
    foreach (v; cd.fields)
    {
        if (!v.ident)
            continue;
        if (strcmp(v.ident.toChars(), "base") == 0)
            ipTIBaseOffset = v.offset;
        else if (strcmp(v.ident.toChars(), "name") == 0)
            ipTINameOffset = v.offset;
        else if (strcmp(v.ident.toChars(), "classInvariant") == 0)
            ipTIInvOffset = v.offset;
    }
}

private __gshared ulong ipThrowNextOffset;
private __gshared ulong ipErrorBypassOffset;

private void ipComputeThrowOffsets() nothrow
{
    ipComputeTIOffsets();
    if (ipThrowNextOffset)
        return;
    if (auto cd = ClassDeclaration.throwable)
        foreach (v; cd.fields)
            if (v.ident && strcmp(v.ident.toChars(), "_nextInChainPtr") == 0)
                ipThrowNextOffset = v.offset;
    if (auto cd = ClassDeclaration.errorException)
        foreach (v; cd.fields)
            if (v.ident && strcmp(v.ident.toChars(), "bypassedException") == 0)
                ipErrorBypassOffset = v.offset;
}

private extern (C) wasm_trap_t* ipHostCov(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
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
    import dmd.wasmtimec;
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
    bool rd(ulong addr, out ulong v) nothrow @nogc
    {
        if (addr + ipPS > mem.length)
            return false;
        v = ipLdP(mem.ptr + addr);
        return true;
    }
    int isError(ulong o) nothrow @nogc
    {
        ulong vtbl, ci;
        if (!rd(o, vtbl) || !rd(vtbl, ci))
            return -1;
        enum name = "object.Error";
        while (ci)
        {
            ulong nlen, nptr;
            if (!rd(ci + ipTINameOffset, nlen) || !rd(ci + ipTINameOffset + ipPS, nptr))
                return -1;
            if (nlen == name.length && nptr <= mem.length - nlen
                && mem[cast(size_t) nptr .. cast(size_t) (nptr + nlen)] == name)
                return 1;
            if (!rd(ci + ipTIBaseOffset, ci))
                return -1;
        }
        return 0;
    }
    const err1 = isError(e1), err2 = isError(e2);
    if (err1 < 0 || err2 < 0)
        return ipTrap("wasm-ctfe: exception chaining out of bounds");
    if (err2 && !err1)
    {
        if (e2 + ipErrorBypassOffset + 8 > mem.length)
            return ipTrap("wasm-ctfe: exception chaining out of bounds");
        ipStP(mem.ptr + e2 + ipErrorBypassOffset, e1);
        ipSetP(results[0], e2);
        return null;
    }
    ulong e = e1;
    foreach (_; 0 .. 1 << 20)
    {
        ulong next;
        if (!rd(e + ipThrowNextOffset, next))
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
    import dmd.wasmtimec;
    const o = ipValP(args[0]);
    if (!o)
        return ipTrap("$null$null this in invariant check");
    if (!ipTIBaseOffset || !ipTIInvOffset)
        return ipTrap("wasm-ctfe: no ClassInfo layout");
    wasmtime_memory_t m;
    if (!ipCallerMemory(caller, m))
        return ipTrap("wasm-ctfe: no memory export");
    auto ctx = wasmtime_caller_context(caller);
    wasmtime_extern_t ext;
    if (!wasmtime_caller_export_get(caller, "__indirect_function_table".ptr, "__indirect_function_table".length, &ext)
        || ext.kind != WASMTIME_EXTERN_TABLE)
        return ipTrap("wasm-ctfe: no table export");
    bool rd(ulong addr, out ulong v) nothrow @nogc
    {
        auto mem = ipMemSlice(caller, m);
        if (addr + ipPS > mem.length)
            return false;
        v = ipLdP(mem.ptr + addr);
        return true;
    }
    ulong vtbl, ci;
    if (!rd(o, vtbl) || !rd(vtbl, ci))
        return ipTrap("wasm-ctfe: invariant check out of bounds");
    while (ci)
    {
        ulong fidx;
        if (!rd(ci + ipTIInvOffset, fidx))
            return ipTrap("wasm-ctfe: invariant check out of bounds");
        if (fidx)
        {
            wasmtime_val_t fv;
            if (!wasmtime_table_get(ctx, &ext.of.table, fidx, &fv) || fv.kind != WASMTIME_FUNCREF)
                return ipTrap("wasm-ctfe: bad invariant function");
            wasmtime_val_t[1] cargs;
            ipSetP(cargs[0], o);
            wasm_trap_t* trap;
            if (auto err = wasmtime_func_call(ctx, &fv.of.funcref, cargs.ptr, 1, null, 0, &trap))
            {
                wasmtime_error_delete(err);
                return ipTrap("wasm-ctfe: invariant call failed");
            }
            if (trap)
                return trap;
        }
        if (!rd(ci + ipTIBaseOffset, ci))
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
        if (o + ipPS > mem.length)
            return ipTrap("wasm-ctfe: cast out of bounds");
        const vtbl = ipLdP(mem.ptr + o);
        auto dyn = vtbl in ipCppVtbls;
        auto to = ipValP(args[1]) in ipCppVtbls;
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
    import dmd.wasmtimec;
    wasmtime_memory_t m;
    if (!ipCallerMemory(caller, m))
        return ipTrap("wasm-ctfe: no memory export");
    auto mem = ipMemSlice(caller, m);
    const o = ipValP(args[0]);
    const ci = ipValP(args[1]);
    int found = 0;
    if (o && ipTIBaseOffset)
    {
        bool rd(ulong addr, out ulong v) nothrow @nogc
        {
            if (addr + ipPS > mem.length)
                return false;
            v = ipLdP(mem.ptr + addr);
            return true;
        }
        ulong vtbl, oc;
        if (!rd(o, vtbl) || !rd(vtbl, oc))
            return ipTrap("wasm-ctfe: eh match out of bounds");
        while (oc)
        {
            if (oc == ci)
            {
                found = 1;
                break;
            }
            if (!rd(oc + ipTIBaseOffset, oc))
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
    import dmd.wasmtimec;
    auto hi = cast(HostImport*) env;
    const wide = hi.nameLen && hi.name[hi.nameLen - 1] == 'w';
    wasmtime_memory_t m;
    if (!ipCallerMemory(caller, m))
        return ipTrap("wasm-ctfe: no memory export");
    auto mem = ipMemSlice(caller, m);
    const sret = ipValP(args[0]);
    const xptr = ipValP(args[1]);
    const c = cast(uint) args[2].of.i32;
    if (xptr + 16 > mem.length || sret + 16 > mem.length)
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
    if (auto trap = ipBumpAlloc(caller, m, (len + n) * esz, np))
        return trap;
    mem = ipMemSlice(caller, m);
    memcpy(mem.ptr + np, mem.ptr + ptr, cast(size_t)(len * esz));
    memcpy(mem.ptr + np + len * esz, enc.ptr, cast(size_t)(n * esz));
    ipStP(mem.ptr + xptr, len + n);
    ipStP(mem.ptr + xptr + ipPS, np);
    ipStP(mem.ptr + sret, len + n);
    ipStP(mem.ptr + sret + ipPS, np);
    return null;
}

private ubyte[] ipMemSlice(wasmtime_caller_t* caller, ref wasmtime_memory_t m) nothrow @nogc
{
    import dmd.wasmtimec;
    auto ctx = wasmtime_caller_context(caller);
    auto data = wasmtime_memory_data(ctx, &m);
    const len = wasmtime_memory_data_size(ctx, &m);
    return data[0 .. len];
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
    results[0] = args[0];
    return null;
}

private extern (C) wasm_trap_t* ipHostMemsetT(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    import dmd.wasmtimec;
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

private extern (C) wasm_trap_t* ipHostExpandArray(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    results[0].kind = WASMTIME_I32;
    results[0].of.i32 = 0;
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
    results[0].of.i32 = 1;
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
    foreach (i; addr .. mem.length)
        if (mem[cast(size_t) i] == 0)
            return cast(const(char)*) mem.ptr + addr;
    return "?".ptr;
}

private extern (C) wasm_trap_t* ipHostBoundsIndex(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    wasmtime_memory_t m;
    ubyte[] mem;
    if (ipCallerMemory(caller, m))
        mem = ipMemSlice(caller, m);
    const n = snprintf(ipTrapBuf.ptr, ipTrapBuf.length,
        "$bounds$%s(%d): array index %llu exceeds array length %llu",
        ipMemString(mem, ipValP(args[0])), args[1].of.i32,
        ipValP(args[2]), ipValP(args[3]));
    return wasmtime_trap_new(ipTrapBuf.ptr, n);
}

private extern (C) wasm_trap_t* ipHostShiftError(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    wasmtime_memory_t m;
    ubyte[] mem;
    if (ipCallerMemory(caller, m))
        mem = ipMemSlice(caller, m);
    const n = snprintf(ipTrapBuf.ptr, ipTrapBuf.length,
        "$shift$%s(%d): shift by %lld is outside the range 0..%lld",
        ipMemString(mem, ipValP(args[0])), args[1].of.i32,
        cast(long) args[2].of.i64, cast(long) args[3].of.i64);
    return wasmtime_trap_new(ipTrapBuf.ptr, n);
}

private extern (C) wasm_trap_t* ipHostNullPointer(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    wasmtime_memory_t m;
    ubyte[] mem;
    if (ipCallerMemory(caller, m))
        mem = ipMemSlice(caller, m);
    const n = snprintf(ipTrapBuf.ptr, ipTrapBuf.length,
        "$null$%s(%d): null pointer dereference",
        ipMemString(mem, ipValP(args[0])), args[1].of.i32);
    return wasmtime_trap_new(ipTrapBuf.ptr, n);
}

private extern (C) wasm_trap_t* ipHostBoundsSlice(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    wasmtime_memory_t m;
    ubyte[] mem;
    if (ipCallerMemory(caller, m))
        mem = ipMemSlice(caller, m);
    const n = snprintf(ipTrapBuf.ptr, ipTrapBuf.length,
        "$bounds$%s(%d): slice [%llu..%llu] exceeds array bounds [0..%llu]",
        ipMemString(mem, ipValP(args[0])), args[1].of.i32,
        ipValP(args[2]), ipValP(args[3]), ipValP(args[4]));
    return wasmtime_trap_new(ipTrapBuf.ptr, n);
}

private extern (C) wasm_trap_t* ipHostAssert(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    wasmtime_memory_t m;
    ubyte[] mem;
    if (ipCallerMemory(caller, m))
        mem = ipMemSlice(caller, m);
    const n = snprintf(ipTrapBuf.ptr, ipTrapBuf.length,
        "$assert$%s(%d): assertion failure",
        ipMemString(mem, ipValP(args[0])), args[1].of.i32);
    return wasmtime_trap_new(ipTrapBuf.ptr, n);
}

private extern (C) wasm_trap_t* ipHostBounds(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    wasmtime_memory_t m;
    ubyte[] mem;
    if (ipCallerMemory(caller, m))
        mem = ipMemSlice(caller, m);
    const(char)[] file = "?";
    const flen = ipValP(args[0]);
    const fptr = ipValP(args[1]);
    if (fptr < mem.length && flen <= mem.length - fptr && flen <= 512)
        file = cast(const(char)[])(mem.ptr[cast(size_t) fptr .. cast(size_t)(fptr + flen)]);
    const n = snprintf(ipTrapBuf.ptr, ipTrapBuf.length,
        "$bounds$%.*s(%d): array index out of bounds",
        cast(int) file.length, file.ptr, args[2].of.i32);
    return wasmtime_trap_new(ipTrapBuf.ptr, n);
}

private extern (C) wasm_trap_t* ipHostAssertMsg(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    wasmtime_memory_t m;
    ubyte[] mem;
    if (ipCallerMemory(caller, m))
        mem = ipMemSlice(caller, m);
    const(char)[] str(ulong len, ulong ptr) nothrow @nogc
    {
        if (ptr > mem.length || len > mem.length - ptr || len > 512)
            return "?";
        return cast(const(char)[])(mem.ptr[cast(size_t) ptr .. cast(size_t)(ptr + len)]);
    }
    const msg = str(ipValP(args[0]), ipValP(args[1]));
    const file = str(ipValP(args[2]), ipValP(args[3]));
    const n = snprintf(ipTrapBuf.ptr, ipTrapBuf.length,
        "$assert$%.*s(%d): %.*s",
        cast(int) file.length, file.ptr, args[4].of.i32,
        cast(int) msg.length, msg.ptr);
    return wasmtime_trap_new(ipTrapBuf.ptr, n);
}

private wasm_engine_t* ipGetEngine()
{
    import dmd.wasmtimec;
    if (ipEngine)
        return ipEngine;
    auto cfg = wasm_config_new();
    wasmtime_config_wasm_memory64_set(cfg, true);
    wasmtime_config_wasm_exceptions_set(cfg, true);
    wasmtime_config_consume_fuel_set(cfg, true);
    ipEngine = wasm_engine_new_with_config(cfg);
    return ipEngine;
}

private IpModule* ipGetModule(FuncDeclaration fd)
{
    import dmd.wasmtimec;
    import dmd.glue : wasmCtfeGenerate;

    if (auto p = cast(void*) fd in ipModuleCache)
        return *p;
    if (cast(void*) fd in ipModuleFailed)
        return null;
    {
        import dmd.glue : wasmCtfeBuildInProgress;
        if (wasmCtfeBuildInProgress())
        {
            if (verbose)
                fprintf(stderr, "wasm-ctfe inproc: nested build for %s deferred\n", fd.toPrettyChars());
            return null;
        }
    }

    OutBuffer buf;
    const(char)[][] unresolved;
    const savedSuspend = buildActiveSuspended;
    buildActiveSuspended = 0;
    import dmd.backend.wasm.selflink : wasmSelfLinkProbeData, wasmSelfLinkProbeAddr;
    wasmSelfLinkProbeData = "_D4core8internal5newaa10ctfeOrders";
    const genOk = wasmCtfeGenerate(fd, buf, unresolved);
    wasmSelfLinkProbeData = null;
    const ordersAddr = wasmSelfLinkProbeAddr;
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
        ipModuleFailed[cast(void*) fd] = true;
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
    if (unresolved.length)
    {
        if (verbose)
        {
            fprintf(stderr, "wasm-ctfe inproc: %zu unresolved symbols for %s\n",
                unresolved.length, fd.toPrettyChars());
            foreach (u; unresolved)
                fprintf(stderr, "  undefined: %.*s\n", cast(int) u.length, u.ptr);
        }
        wasmCtfeStats.compileFailures++;
        ipModuleFailed[cast(void*) fd] = true;
        return null;
    }

    wasmtime_module_t* mod;
    if (auto err = wasmtime_module_new(ipGetEngine(), cast(const(ubyte)*) buf[].ptr, buf.length, &mod))
    {
        if (verbose)
        {
            wasm_name_t msg;
            wasmtime_error_message(err, &msg);
            fprintf(stderr, "wasm-ctfe inproc: module error for %s: %.*s\n",
                fd.toPrettyChars(), cast(int) msg.size, msg.data);
            wasm_byte_vec_delete(&msg);
        }
        wasmtime_error_delete(err);
        ipModuleFailed[cast(void*) fd] = true;
        return null;
    }

    auto im = new IpModule;
    im.mod = mod;
    const mangled = mangleExact(fd);
    im.exportName = mangled[0 .. strlen(mangled)];
    im.ctfeOrdersAddr = ordersAddr;
    {
        import dmd.glue.tocsym : wasmCtfeClassList;
        import dmd.backend.wasm.selflink : wasmSelfLinkVtblAddrs;
        foreach (cd; wasmCtfeClassList())
        {
            OutBuffer vb;
            vb.writestring("_D");
            mangleToBuffer(cd, vb);
            vb.writestring("6__vtblZ");
            if (auto a = vb[] in wasmSelfLinkVtblAddrs)
                im.cppVtbls[*a] = cd;
        }
    }
    {
        import dmd.glue : wasmCtfeBuiltFuncs;
        import dmd.backend.wasm.selflink : wasmSelfLinkTableNames;
        FuncDeclaration[const(char)[]] byName;
        foreach (bf; wasmCtfeBuiltFuncs)
        {
            const mn = mangleExact(bf);
            byName[mn[0 .. strlen(mn)]] = bf;
        }
        im.tableFuncs = new FuncDeclaration[](wasmSelfLinkTableNames.length);
        foreach (i, n; wasmSelfLinkTableNames)
            if (auto p = n in byName)
                im.tableFuncs[i] = *p;
        wasmCtfeBuiltFuncs = null;
    }
    import dmd.glue : wasmCtfeHasStubs;
    if (!wasmCtfeHasStubs())
        ipModuleCache[cast(void*) fd] = im;
    return im;
}

public Expression tryWasmCtfeTraced(Expression e)
{
    import dmd.timetrace;
    auto ce = e.isCallExp();
    if (!ce || !ce.f)
        return tryWasmCtfe(e);
    scope dlg = () {
        import dmd.common.outbuffer;
        auto buf = OutBuffer(20);
        buf.writestring(ce.f.toPrettyChars());
        buf.writeByte('(');
        if (ce.arguments)
            foreach (i, arg; *ce.arguments)
            {
                if (i > 0)
                    buf.writestring(", ");
                buf.writestring(arg.toChars());
            }
        buf.writeByte(')');
        return buf.extractSlice();
    };
    timeTraceBeginEvent(TimeTraceEventType.ctfeCall);
    scope (exit) timeTraceEndEvent(TimeTraceEventType.ctfeCall, ce.f, dlg);
    return tryWasmCtfe(e);
}

Expression tryWasmCtfeInproc(FuncDeclaration fd, Expression thisExp, Expression[] args, Type resultType, Loc loc)
{
    foreach (attempt; 0 .. 32)
    {
        ipLazyHit = null;
        auto r = tryWasmCtfeInprocOnce(fd, thisExp, args, resultType, loc);
        auto lf = ipLazyHit;
        ipLazyHit = null;
        if (!lf || lf.semanticRun >= PASS.semantic3done)
            return r;
        const oldGag = global.startGagging();
        wasmCtfePreSemEnter();
        ipForceSemantic3(lf);
        wasmCtfePreSemLeave();
        const failed = global.endGagging(oldGag) || lf.semanticRun < PASS.semantic3done || lf.errors;
        if (failed)
            return r;
        ipModuleCache.remove(cast(void*) fd);
        ipModuleFailed.remove(cast(void*) fd);
    }
    return null;
}

private Expression tryWasmCtfeInprocOnce(FuncDeclaration fd, Expression thisExp, Expression[] args, Type resultType, Loc loc)
{
    import dmd.wasmtimec;
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
    if (!thisExp && wasmCtfeHostBuiltin(fd))
    {
        import dmd.builtin : eval_builtin;
        if (isBuiltin(fd) == BUILTIN.ctfeWrite)
        {
            ipCtfeWrites++;
            if (wasmCtfeMode() == WasmCtfeMode.verify)
                return CTFEExp.voidexp;
        }
        auto exps = new Expressions(args.length);
        foreach (i, a; args)
            (*exps)[i] = a;
        if (auto r = eval_builtin(loc, fd, exps))
            return r;
    }
    if (fd.semanticRun < PASS.semantic3done)
        ipForceSemantic3(fd);
    if (fd.semanticRun < PASS.semantic3done || !fd.fbody || fd.errors)
        return bail(fd, "not semantic3done");
    if (!scanLegality(fd, true))
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
    const bool resultOk = ipResultType(resultType);
    const bool zeroResult = !isCtor && resultOk && rty == Tsarray && resultType.size() == 0;
    const bool sret = !isCtor && resultOk && !zeroResult && (rty == Tstruct || rty == Tarray || rty == Tsarray || rty == Tdelegate);
    const bool classResult = !isCtor && resultOk && rty == Tclass;
    const bool ptrResult = !isCtor && resultOk && (rty == Tpointer || rty == Taarray);
    const bool vecResult = !isCtor && resultOk && rty == Tvector;
    const bool voidResult = !isCtor && rty == Tvoid;
    if (isCtor)
    {
        if (!ipMemType(resultType))
            return bail(fd, "result type");
    }
    else if (!sret && !zeroResult && !classResult && !ptrResult && !vecResult && !voidResult && !ipScalarType(resultType))
        return bail(fd, "result type");
    foreach (size_t i, Parameter p; tf.parameterList)
    {
        if (p.storageClass & (STC.ref_ | STC.out_ | STC.lazy_))
            return bail(fd, "param storage class");
        if (!ipScalarType(p.type) && !ipArgType(p.type) && !ipPtrArgType(p.type))
            return bail(fd, "param type");
    }

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
    auto memArgVal = new size_t[](args.length);
    auto ptrArg = new bool[](args.length);
    foreach (i, arg; args)
    {
        Parameter p = tf.parameterList[i];
        if (nvals + 2 > vals.length)
            return bail(fd, "too many args");
        if (ipArgType(p.type))
        {
            if (!ipArgMemSize(arg, memArgBytes))
                return bail(fd, "arg not literal");
            memArgVal[i] = nvals;
            memArgCount++;
            nvals += 2;
        }
        else if (ipPtrArgType(p.type))
        {
            if (!arg.isStructLiteralExp() && !arg.isArrayLiteralExp() && !arg.isStringExp())
                return bail(fd, "arg not literal");
            memArgBytes += (cast(ulong) p.type.size() + 15) & ~15UL;
            memArgVal[i] = nvals;
            ptrArg[i] = true;
            memArgCount++;
            nvals += 1;
        }
        else
        {
            memArgVal[i] = size_t.max;
            if (!ipMarshalScalar(arg, vals[nvals]))
                return bail(fd, "arg not literal scalar");
            nvals++;
        }
    }

    OutBuffer keyBuf;
    keyBuf.writestring(mangleExact(fd));
    keyBuf.writeByte(0);
    if (thisExp)
    {
        keyBuf.writestring(thisExp.toChars());
        ipAppendSymKey(thisExp, keyBuf);
        keyBuf.writeByte(0);
    }
    foreach (arg; args)
    {
        keyBuf.writestring(arg.toChars());
        ipAppendSymKey(arg, keyBuf);
        keyBuf.writeByte(0);
    }
    if (!ipCacheInit)
    {
        ipResultCache._init(64);
        ipCacheInit = true;
    }
    if (auto sv = ipResultCache.lookup(keyBuf[]))
    {
        wasmCtfeStats.cacheHits++;
        return sv.value;
    }
    const writesBefore = ipCtfeWrites;

    wasmCtfeStats.attempts++;
    auto im = ipGetModule(fd);
    if (!im)
        return null;

    auto store = wasmtime_store_new(ipGetEngine(), null, null);
    scope (exit) wasmtime_store_delete(store);
    auto ctx = wasmtime_store_context(store);

    auto linker = wasmtime_linker_new(ipGetEngine());
    scope (exit) wasmtime_linker_delete(linker);

    {
        wasm_importtype_vec_t imports;
        wasmtime_module_imports(im.mod, &imports);
        scope (exit) wasm_importtype_vec_delete(&imports);
        foreach (i; 0 .. imports.size)
        {
            auto it = imports.data[i];
            const modName = wasm_importtype_module(it);
            const name = wasm_importtype_name(it);
            const ftc = wasm_externtype_as_functype_const(wasm_importtype_type(it));
            if (!ftc)
                return null;

            auto hi = new HostImport;
            const nl = name.size < hi.name.length ? name.size : hi.name.length;
            hi.name[0 .. nl] = name.data[0 .. nl];
            hi.nameLen = nl;
            im.hostImports ~= hi;

            const pv = wasm_functype_params(ftc);
            const rv = wasm_functype_results(ftc);
            wasm_valtype_t*[16] pk;
            if (pv.size > pk.length || rv.size > 1)
                return null;
            foreach (j; 0 .. pv.size)
                pk[j] = wasm_valtype_new(wasm_valtype_kind(pv.data[j]));
            wasm_valtype_vec_t pvec, rvec;
            wasm_valtype_vec_new(&pvec, pv.size, pk.ptr);
            if (rv.size == 1)
            {
                wasm_valtype_t*[1] rk = [wasm_valtype_new(wasm_valtype_kind(rv.data[0]))];
                wasm_valtype_vec_new(&rvec, 1, rk.ptr);
            }
            else
                wasm_valtype_vec_new_empty(&rvec);
            auto ft = wasm_functype_new(&pvec, &rvec);
            import dmd.glue.tocsym : wasmCtfeLazyFuncs, wasmCtfeStubFuncs;
            wasmtime_func_callback_t cb = &ipHostStub;
            const nm = name.data[0 .. name.size];
            if (nm == "gc_malloc" || nm == "_d_allocmemory" || nm == "gc_mallocTrace" || nm == "gc_calloc" || nm == "gc_callocTrace")
                cb = &ipHostGcMalloc;
            else if (nm == "malloc" || nm == "calloc" || nm == "realloc" || nm == "__errno_location")
            {
                hi.cAlloc = nm == "malloc" ? 1 : nm == "calloc" ? 2 : nm == "realloc" ? 3 : 4;
                cb = &ipHostCAlloc;
            }
            else if (nm == "free" || nm == "gc_addRange" || nm == "gc_removeRange"
                || nm == "_d_criticalenter2" || nm == "_d_criticalexit"
                || nm == "_d_monitorenter" || nm == "_d_monitorexit")
                cb = &ipHostZero64;
            else if (nm.length >= 10 && nm[0 .. 7] == "_aApply" && (nm[$ - 1] == '1' || nm[$ - 1] == '2')
                && (nm.length == 10 || (nm.length == 11 && nm[7] == 'R')))
                cb = &ipHostAApply;
            else if (nm == "memset")
                cb = &ipHostMemset;
            else if (nm == "memcpy")
                cb = &ipHostMemcpy;
            else if (nm == "memcmp")
                cb = &ipHostMemcmp;
            else if (nm == "_memsetn")
                cb = &ipHostMemsetn;
            else if (nm == "_memsetFloat" || nm == "_memsetDouble" || nm == "_memset80"
                || nm == "_memset128" || nm == "_memset128ii" || nm == "_memset16"
                || nm == "_memset32" || nm == "_memset64")
                cb = &ipHostMemsetT;
            else if (nm == "gc_expandArrayUsed")
                cb = &ipHostExpandArray;
            else if (nm == "gc_shrinkArrayUsed")
                cb = &ipHostShrinkArray;
            else if (nm == "gc_query")
                cb = &ipHostGcQuery;
            else if (nm == "gc_allocatedInCurrentThread")
                cb = &ipHostZero64;
            else if (nm == "_d_arraybounds_indexp")
                cb = &ipHostBoundsIndex;
            else if (nm == "_d_arraybounds_slicep")
                cb = &ipHostBoundsSlice;
            else if (nm == "_d_assertp" || nm == "_d_arrayboundsp")
                cb = &ipHostAssert;
            else if (nm == "_d_arraybounds")
                cb = &ipHostBounds;
            else if (nm == "_d_assert_msg")
                cb = &ipHostAssertMsg;
            else if (nm == "_d_arrayappendcd" || nm == "_d_arrayappendcw")
                cb = &ipHostArrayAppendC;
            else if (nm == "__wasmctfe_append")
                cb = &ipHostAppend;
            else if (nm == "_d_nullpointerp")
                cb = &ipHostNullPointer;
            else if (nm == "__wasmctfe_cov")
                cb = &ipHostCov;
            else if (nm == "__wasmctfe_chain")
            {
                cb = &ipHostChain;
                ipComputeThrowOffsets();
            }
            else if (nm == "_D2rt10invariant_12_d_invariantFC6ObjectZv")
            {
                cb = &ipHostInvariant;
                ipComputeTIOffsets();
            }
            else if (nm == "__wasmctfe_shift_error")
                cb = &ipHostShiftError;
            else if (nm.length > 14 && nm[0 .. 14] == "__wasmctfe_bi_")
            {
                if (auto bp = (cast(string) nm) in wasmCtfeBuiltinFds)
                {
                    hi.builtinFd = *bp;
                    cb = isBuiltin(*bp) == BUILTIN.ctfeWrite ? &ipHostCtfeWrite : &ipHostBuiltin;
                }
            }
            else if (nm.length > 16 && nm[0 .. 16] == "__wasmctfe_real_")
            {
                import dmd.backend.wasm.softreal : softRealNames;
                foreach (k, sn; softRealNames)
                    if (sn == nm)
                    {
                        hi.softOp = cast(int) k;
                        cb = &ipHostSoftReal;
                    }
            }
            else if (auto sp = nm in wasmCtfeStubFuncs)
            {
                hi.stubWhy = *sp;
                cb = &ipHostStubbed;
            }
            else if (auto lp = nm in wasmCtfeLazyFuncs)
            {
                hi.lazyFd = *lp;
                cb = &ipHostLazy;
            }
            else if (nm == "__wasmctfe_cppcast")
                cb = &ipHostCppCast;
            else if (nm == "_d_eh_wasm_match")
            {
                cb = &ipHostEhMatch;
                ipComputeTIOffsets();
            }
            auto err = wasmtime_linker_define_func(linker,
                modName.data, modName.size, name.data, name.size,
                ft, cb, cast(void*) hi, null);
            wasm_functype_delete(ft);
            if (err)
            {
                wasmtime_error_delete(err);
                return null;
            }
        }
    }

    wasmtime_instance_t inst;
    wasm_trap_t* trap;
    if (auto err = wasmtime_linker_instantiate(linker, ctx, im.mod, &inst, &trap))
    {
        if (verbose)
        {
            wasm_name_t msg;
            wasmtime_error_message(err, &msg);
            fprintf(stderr, "wasm-ctfe inproc: instantiate %s: %.*s\n",
                fd.toPrettyChars(), cast(int) msg.size, msg.data);
            wasm_byte_vec_delete(&msg);
        }
        wasmtime_error_delete(err);
        return null;
    }
    if (trap)
    {
        wasm_trap_delete(trap);
        return null;
    }

    wasmtime_extern_t fnExt;
    if (!wasmtime_instance_export_get(ctx, &inst, im.exportName.ptr, im.exportName.length, &fnExt)
        || fnExt.kind != WASMTIME_EXTERN_FUNC)
    {
        if (verbose)
            fprintf(stderr, "wasm-ctfe inproc: export %.*s not found for %s at %s\n",
                cast(int) im.exportName.length, im.exportName.ptr, fd.toPrettyChars(), fd.loc.toChars());
        return null;
    }

    wasmtime_memory_t mem;
    ulong sretAddr;
    const ulong thisSize = thisExp ? cast(ulong) thisSd.type.size() : 0;
    if (sret || memArgCount || thisExp || classResult || ptrResult)
    {
        wasmtime_extern_t memExt, spExt;
        if (!wasmtime_instance_export_get(ctx, &inst, "memory".ptr, "memory".length, &memExt)
            || memExt.kind != WASMTIME_EXTERN_MEMORY)
            return bail(fd, "no memory export");
        if (!wasmtime_instance_export_get(ctx, &inst, "__stack_pointer".ptr, "__stack_pointer".length, &spExt)
            || spExt.kind != WASMTIME_EXTERN_GLOBAL)
            return bail(fd, "no stack pointer export");
        mem = memExt.of.memory;
        wasmtime_val_t spVal;
        wasmtime_global_get(ctx, &spExt.of.global, &spVal);
        if (!ipIsP(spVal))
            return bail(fd, "stack pointer kind");
        const size_t rsz = sret ? cast(size_t) resultType.size() : 0;
        ulong need = (rsz + 15) & ~15UL;
        need += (memArgBytes + 15) & ~15UL;
        need += (thisSize + 15) & ~15UL;
        const base = (ipValP(spVal) - need) & ~15UL;
        ipSetP(spVal, base);
        if (auto err = wasmtime_global_set(ctx, &spExt.of.global, &spVal))
        {
            wasmtime_error_delete(err);
            return bail(fd, "stack pointer set");
        }
        auto data = wasmtime_memory_data(ctx, &mem);
        const dataLen = wasmtime_memory_data_size(ctx, &mem);
        if (base + need > dataLen)
            return bail(fd, "stack overflow");
        ulong cur = base;
        if (thisExp)
        {
            if (!ipEncodeVal(data[0 .. dataLen], base, thisExp.type, thisExp))
                return bail(fd, "this encode");
            cur = base + ((thisSize + 15) & ~15UL);
            ipSetP(vals[0], base);
        }
        foreach (i, arg; args)
        {
            if (memArgVal[i] == size_t.max)
                continue;
            if (ptrArg[i])
            {
                auto pt = tf.parameterList[i].type;
                if (!ipEncodeVal(data[0 .. dataLen], cur, pt, arg))
                    return bail(fd, "arg encode");
                ipSetP(vals[memArgVal[i]], cur);
                cur += (cast(ulong) pt.size() + 15) & ~15UL;
                continue;
            }
            ulong alen, aptr;
            if (!ipEncodeArg(data[0 .. dataLen], cur, arg, alen, aptr))
                return bail(fd, "arg encode");
            cur = (cur + 15) & ~15UL;
            ipSetP(vals[memArgVal[i]], alen);
            ipSetP(vals[memArgVal[i] + 1], aptr);
        }
        if (sret)
        {
            sretAddr = base + ((thisSize + 15) & ~15UL) + ((memArgBytes + 15) & ~15UL);
            ipSetP(vals[sretSlot], sretAddr);
        }
    }

    ipHeapPtr = 0;
    ipErrnoCell = 0;
    ipHeapEnd = 0;
    ipAllocCount = 0;
    ipDecodeMemo.setDim(0);
    ipCtfeOrdersAddr = im.ctfeOrdersAddr;
    ipTableFuncs = im.tableFuncs;
    ipCppVtbls = im.cppVtbls;
    if (auto err = wasmtime_context_set_fuel(ctx, 2_000_000_000))
        wasmtime_error_delete(err);
    wasmtime_val_t[1] results;
    const nresults = (sret || zeroResult || resultType.toBasetype().ty == Tvoid) ? 0 : 1;
    if (auto err = wasmtime_func_call(ctx, &fnExt.of.func, vals.ptr, nvals,
        results.ptr, nresults, &trap))
    {
        if (verbose)
        {
            wasm_name_t msg;
            wasmtime_error_message(err, &msg);
            fprintf(stderr, "wasm-ctfe inproc: call %s: %.*s\n",
                fd.toPrettyChars(), cast(int) msg.size, msg.data);
            wasm_byte_vec_delete(&msg);
        }
        wasmtime_error_delete(err);
        return null;
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
        wasm_trap_delete(trap);
        return null;
    }

    Expression resultExp;
    if (isCtor)
    {
        const data = wasmtime_memory_data(ctx, &mem);
        const dataLen = wasmtime_memory_data_size(ctx, &mem);
        if (ipIsP(results[0]))
            resultExp = ipDecodeMem(data[0 .. dataLen], ipValP(results[0]), resultType, loc);
    }
    else if (sret)
    {
        const data = wasmtime_memory_data(ctx, &mem);
        const dataLen = wasmtime_memory_data_size(ctx, &mem);
        resultExp = ipDecodeMem(data[0 .. dataLen], sretAddr, resultType, loc);
    }
    else if (zeroResult)
        resultExp = new ArrayLiteralExp(loc, resultType, new Expressions());
    else if (classResult)
    {
        const data = wasmtime_memory_data(ctx, &mem);
        const dataLen = wasmtime_memory_data_size(ctx, &mem);
        if (ipIsP(results[0]))
            resultExp = ipDecodeClassRef(data[0 .. dataLen], ipValP(results[0]), resultType, loc, 0);
    }
    else if (voidResult)
    {
        resultExp = CTFEExp.voidexp;
    }
    else if (vecResult)
    {
        if (results[0].kind == WASMTIME_V128)
            resultExp = ipDecodeMem(results[0].of.v128[], 0, resultType, loc);
    }
    else if (ptrResult)
    {
        const data = wasmtime_memory_data(ctx, &mem);
        const dataLen = wasmtime_memory_data_size(ctx, &mem);
        if (ipIsP(results[0]))
            resultExp = rty == Taarray
                ? ipDecodeAA(data[0 .. dataLen], ipValP(results[0]), resultType, loc, 0)
                : resultType.toBasetype().nextOf().toBasetype().ty == Tfunction
                ? ipDecodeFuncPtr(ipValP(results[0]), 0, resultType, loc)
                : ipDecodePtr(data[0 .. dataLen], ipValP(results[0]), resultType, loc, 0);
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
    if (writesBefore == ipCtfeWrites)
        if (auto sv = ipResultCache.insert(keyBuf[], null))
            sv.value = resultExp;
    if (verbose)
        fprintf(stderr, "wasm-ctfe inproc: ok %s -> %s\n", fd.toPrettyChars(), resultExp.toChars());
    return resultExp;
}

private bool ipScalarType(Type t)
{
    auto tb = t.toBasetype();
    if (tb.isTypeEnum())
        return false;
    switch (tb.ty)
    {
        case Tint8, Tuns8, Tint16, Tuns16, Tint32, Tuns32, Tint64, Tuns64,
             Tbool, Tchar, Twchar, Tdchar:
            return true;
        case Tfloat32, Tfloat64:
            return true;
        case Tfloat80:
            return ipSoftReal();
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

private bool ipResultType(Type t, int depth = 0)
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
            return ipResultType(n, depth + 1);
        case Tdelegate:
            return true;
        case Tclass:
            auto cd = tb.isTypeClass().sym;
            return !cd.isCPPinterface() && !cd.isCOMinterface();
        case Tarray, Tsarray:
            return ipResultType(tb.nextOf(), depth + 1);
        case Taarray:
            return ipResultType(tb.isTypeAArray().index, depth + 1) && ipResultType(tb.nextOf(), depth + 1);
        case Tvector:
            return ipScalarType(tb.isTypeVector().elementType());
        case Tstruct:
            auto sd = tb.isTypeStruct().sym;
            if (sd.sizeok != Sizeok.done)
                sd.size(sd.loc);
            if (sd.sizeok != Sizeok.done)
                return false;
            foreach (i, v; sd.fields)
                if (!ipOverlapDominated(sd, i) && !ipResultType(v.type, depth + 1))
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
        if (!ts.sym.isPOD())
            return false;
        return ipMemType(tb);
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

    const dbg = getenv("DMD_CTFE_TRACEGEN") !is null;
    if (depth > ipDecodeMaxDepth)
        return null;
    if (objAddr == 0)
        return new NullExp(loc, type);
    ipComputeTIOffsets();
    auto tc = type.toBasetype().isTypeClass();
    if (!tc)
    {
        if (dbg) fprintf(stderr, "wasm-ctfe classref: not class type\n");
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
        if (dbg) fprintf(stderr, "wasm-ctfe classref: no name offset\n");
        return null;
    }
    bool rd(ulong a, out ulong v)
    {
        if (a > mem.length || ipPS > mem.length - a)
            return false;
        v = ipRead(mem, a, ipPS);
        return true;
    }
    if (tc.sym.isInterfaceDeclaration())
    {
        if (tc.sym.isCPPinterface() || tc.sym.isCOMinterface())
            return null;
        ulong ivt, ii, off;
        if (!rd(objAddr, ivt) || !rd(ivt, ii) || !rd(ii + 3 * ipPS, off) || off > objAddr)
            return null;
        objAddr -= off;
    }
    ulong vtbl, ci, nlen, nptr;
    ClassDeclaration cd;
    if (cpp)
    {
        if (!rd(objAddr, vtbl))
            return null;
        if (auto p = vtbl in ipCppVtbls)
            cd = *p;
        else if (!wasmCtfeHasSubclass(tc.sym))
            cd = tc.sym;
    }
    else if (!ipTINameOffset)
    {
        if (!rd(objAddr, vtbl) || !vtbl)
            return null;
    }
    else if (!rd(objAddr, vtbl) || !rd(vtbl, ci)
        || !rd(ci + ipTINameOffset, nlen) || !rd(ci + ipTINameOffset + ipPS, nptr))
    {
        if (dbg) fprintf(stderr, "wasm-ctfe classref: read fail obj=%llx vtbl=%llx ci=%llx\n", objAddr, vtbl, ci);
        return null;
    }
    if (!cpp && ipTINameOffset && (nlen > 1024 || nptr > mem.length || nlen > mem.length - nptr))
    {
        if (dbg) fprintf(stderr, "wasm-ctfe classref: bad name slice len=%llx ptr=%llx\n", nlen, nptr);
        return null;
    }
    if (!cpp && vtbl)
        if (auto p = vtbl in ipCppVtbls)
            cd = *p;
    if (!cpp && !cd)
        cd = ipTINameOffset ? wasmCtfeFindClass(cast(const(char)[]) mem[cast(size_t) nptr .. cast(size_t)(nptr + nlen)])
            : tc.sym;
    if (!cd)
    {
        if (dbg) fprintf(stderr, "wasm-ctfe classref: no class for '%.*s'\n", cast(int) nlen, mem.ptr + nptr);
        return null;
    }
    for (auto c = cd; c; c = c.baseClass)
    {
        if (c.ident == Id.TypeInfo)
        {
            if (dbg) fprintf(stderr, "wasm-ctfe classref: TypeInfo result\n");
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
    se.origin = se;
    se.ownedByCtfe = OwnedBy.ctfe;
    ipDecodeMemo.push(IpMemo(objAddr, cd.type, se));
    ptrdiff_t soFar = total;
    for (auto c = cd; c; c = c.baseClass)
    {
        soFar -= c.fields.length;
        foreach (i, v; c.fields)
        {
            if (soFar + cast(ptrdiff_t) i < 0)
                break;
            if (ipOverlapDominated(c, i))
                continue;
            auto el = ipDecodeMem(mem, objAddr + v.offset, v.type, loc, depth + 1);
            if (!el)
            {
                if (dbg) fprintf(stderr, "wasm-ctfe classref: field %s decode fail\n", v.toChars());
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
    ulong addr;
    Type t;
    Expression e;
}

private __gshared Array!IpMemo ipDecodeMemo;

private enum ipDecodeMaxDepth = 400;

private __gshared ulong ipCtfeOrdersAddr;
private __gshared ClassDeclaration[ulong] ipCppVtbls;
private __gshared FuncDeclaration[] ipTableFuncs;

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
    bool rd(ulong a, out ulong v)
    {
        if (a > mem.length || ipPS > mem.length - a)
            return false;
        v = ipRead(mem, a, ipPS);
        return true;
    }
    ulong[] ents;
    bool found;
    ulong olen, optr;
    if (ipCtfeOrdersAddr && rd(ipCtfeOrdersAddr, olen) && rd(ipCtfeOrdersAddr + ipPS, optr))
    {
        foreach (i; 0 .. olen)
        {
            ulong oimpl;
            if (!rd(optr + i * 3 * ipPS, oimpl))
                return null;
            if (oimpl == impl)
            {
                ulong elen, eptr;
                if (!rd(optr + i * 3 * ipPS + ipPS, elen) || !rd(optr + i * 3 * ipPS + 2 * ipPS, eptr))
                    return null;
                foreach (k; 0 .. elen)
                {
                    ulong ent;
                    if (!rd(eptr + k * ipPS, ent))
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
        if (!rd(impl, blen) || !rd(impl + ipPS, bptr))
            return null;
        foreach (k; 0 .. blen)
        {
            ulong hash, ent;
            if (!rd(bptr + k * 2 * ipPS, hash) || !rd(bptr + k * 2 * ipPS + ipPS, ent))
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
    ipDecodeMemo.push(IpMemo(impl, taa, aale));
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

private Expression ipMemoFind(ulong addr, Type t)
{
    import dmd.typesem : equivalent;
    foreach (ref m; ipDecodeMemo[])
        if (m.addr == addr && m.t.equivalent(t))
            return m.e;
    return null;
}

private bool ipOverlapDominated(AggregateDeclaration sd, size_t i)
{
    auto v = sd.fields[i];
    if (!v.overlapped)
        return false;
    const vs = cast(ulong) v.type.size();
    foreach (j, w; sd.fields)
    {
        if (j == i)
            continue;
        const ws = cast(ulong) w.type.size();
        if (w.offset >= v.offset + vs || v.offset >= w.offset + ws)
            continue;
        if (ws > vs || (ws == vs && j < i))
            return true;
    }
    return false;
}

private bool ipFillStruct(const(ubyte)[] mem, ulong addr, StructDeclaration sd, Expressions* elems, Loc loc, int depth)
{
    foreach (i, v; sd.fields)
    {
        if (ipOverlapDominated(sd, i))
            continue;
        if (v.isThisDeclaration())
        {
            (*elems)[i] = new NullExp(loc, v.type);
            continue;
        }
        auto el = ipDecodeMem(mem, addr + v.offset, v.type, loc, depth + 1);
        if (!el)
            return false;
        (*elems)[i] = el;
    }
    return true;
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
            if (auto pv = cast(string) name in ipAddrGlobals)
            {
                auto soe = new SymOffExp(loc, *pv, p - base);
                soe.type = type;
                return soe;
            }
        return new IntegerExp(loc, (ipPS == 4 ? p >= 0xF800_0000 : p >> 32 != 0) ? p ^ wasmCtfeIntPtrTag(ipPS) : p, type);
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
        if (auto pv = cast(string) name in ipAddrGlobals)
        {
            auto soe = new SymOffExp(loc, *pv, p - base);
            soe.type = type;
            return soe;
        }
    }
    if ((p - base) % esz)
        return null;
    if (base > mem.length || asz > mem.length - base)
        return null;
    if (isData && ipIsCharType(etb) && asz >= esz + (p - base) && ipAllZero(mem[cast(size_t) (base + asz - esz) .. cast(size_t) (base + asz)]))
    {
        auto bytes = mem[cast(size_t) base .. cast(size_t) (base + asz)].dup;
        asz -= esz;
        auto se = new StringExp(loc, bytes[0 .. cast(size_t) asz], cast(size_t) (asz / esz), cast(ubyte) esz);
        se.type = et.immutableOf().arrayOf();
        se.ownedByCtfe = OwnedBy.ctfe;
        if (p == base)
        {
            auto pse = cast(StringExp) se.copy();
            pse.type = type;
            return pse;
        }
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
                ipDecodeMemo.push(IpMemo(base, et, sle));
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
        ipDecodeMemo.push(IpMemo(base, at, ale));
        foreach (i; 0 .. cast(size_t) n)
        {
            auto el = ipDecodeMem(mem, base + i * esz, et, loc, depth + 1);
            if (!el)
                return null;
            (*elems)[i] = el;
        }
    }
    auto ie = new IndexExp(loc, ale, new IntegerExp(loc, (p - base) / esz, Type.tsize_t));
    ie.type = et;
    return new AddrExp(loc, ie, type);
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
    if (tb.ty == Tclass)
        return ipDecodeClassRef(mem, ipRead(mem, addr, ipPS), type, loc, depth + 1);
    if (tb.ty == Tpointer && tb.nextOf().toBasetype().ty == Tfunction)
        return ipDecodeFuncPtr(ipRead(mem, addr, ipPS), 0, type, loc);
    if (tb.ty == Tdelegate)
        return ipDecodeFuncPtr(ipRead(mem, addr + ipPS, ipPS), ipRead(mem, addr, ipPS), type, loc);
    if (tb.ty == Tpointer)
        return ipDecodePtr(mem, ipRead(mem, addr, ipPS), type, loc, depth + 1);
    if (tb.ty == Taarray)
        return ipDecodeAA(mem, ipRead(mem, addr, ipPS), type, loc, depth + 1);
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
        if (etb.ty == Tchar || etb.ty == Twchar || etb.ty == Tdchar)
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
        auto elems = ipNewExps(cast(size_t) len);
        foreach (i; 0 .. cast(size_t) len)
        {
            auto el = ipDecodeMem(mem, ptr + i * esz, et, loc, depth + 1);
            if (!el)
                return null;
            (*elems)[i] = el;
        }
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
        foreach (i; 0 .. n)
        {
            auto el = ipDecodeMem(mem, addr + i * esz, et, loc, depth + 1);
            if (!el)
                return null;
            (*elems)[i] = el;
        }
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
        if (!ipSoftReal())
            return null;
        real r = 0;
        memcpy(&r, mem.ptr + cast(size_t) addr, 10);
        return new RealExp(loc, r, type);
    }
    if (!ipScalarType(tb))
        return null;
    ulong v = ipRead(mem, addr, sz);
    switch (tb.ty)
    {
        case Tint8: v = cast(ulong) cast(byte) v; break;
        case Tint16: v = cast(ulong) cast(short) v; break;
        case Tint32: v = cast(ulong) cast(int) v; break;
        default: break;
    }
    return new IntegerExp(loc, v, type);
}

private bool ipArgMemSize(Expression arg, ref ulong total)
{
    if (arg.isNullExp())
        return true;
    if (auto se = arg.isStringExp())
    {
        total += ((cast(ulong) se.len * se.sz) + 15) & ~15UL;
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
        total += ((n * esz) + 15) & ~15UL;
        return true;
    }
    return false;
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
        foreach (i; 0 .. se.len)
            ipWrite(mem, cur + i * sz, se.getIndex(i), sz);
        cur += len * sz;
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
        {
            auto el = ale[i];
            if (auto ie = el.isIntegerExp())
                ipWrite(mem, cur + i * esz, ie.toInteger(), esz);
            else if (auto re = el.isRealExp())
            {
                if (esz == 4)
                {
                    const f = cast(float) re.value;
                    uint u;
                    memcpy(&u, &f, 4);
                    ipWrite(mem, cur + i * esz, u, 4);
                }
                else if (esz > 8)
                    ipPutReal(mem, cur + i * esz, re.value);
                else
                {
                    const d = cast(double) re.value;
                    ulong u;
                    memcpy(&u, &d, 8);
                    ipWrite(mem, cur + i * esz, u, 8);
                }
            }
            else
                return false;
        }
        cur += n * esz;
        return true;
    }
    return false;
}

private bool ipEncodeVal(ubyte[] mem, ulong addr, Type t, Expression e, int depth = 0)
{
    if (depth > 64)
        return false;
    auto tb = t.toBasetype();
    const sz = cast(size_t) tb.size();
    if (addr > mem.length || sz > mem.length - addr)
        return false;
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
        if (sz == 4)
        {
            const f = cast(float) re.value;
            uint u;
            memcpy(&u, &f, 4);
            ipWrite(mem, addr, u, 4);
            return true;
        }
        if (sz == 8)
        {
            const d = cast(double) re.value;
            ulong u;
            memcpy(&u, &d, 8);
            ipWrite(mem, addr, u, 8);
            return true;
        }
        if (sz > 8 && tb.ty == Tfloat80 && ipSoftReal())
        {
            ipPutReal(mem, addr, re.value);
            return true;
        }
        return false;
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
            if (!ipEncodeVal(mem, addr + v.offset, v.type, el, depth + 1))
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
        foreach (i; 0 .. se.len)
            ipWrite(mem, addr + i * esz, se.getIndex(i), esz);
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
            if (!el || !ipEncodeVal(mem, addr + i * esz, et, el, depth + 1))
                return false;
        }
        return true;
    }
    return false;
}

private bool ipMarshalScalar(Expression arg, ref wasmtime_val_t val)
{
    import dmd.wasmtimec;
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
        else if (tb.ty == Tfloat80 && ipSoftReal())
        {
            const real r = re.value;
            val.kind = WASMTIME_V128;
            val.of.v128[] = 0;
            memcpy(val.of.v128.ptr, &r, 10);
        }
        else
            return false;
        return true;
    }
    return false;
}

private Expression ipDecodeScalar(ref wasmtime_val_t val, Type type, Loc loc)
{
    import dmd.wasmtimec;
    auto tb = type.toBasetype();
    switch (tb.ty)
    {
        case Tint8, Tuns8, Tint16, Tuns16, Tint32, Tuns32, Tbool, Tchar, Twchar, Tdchar:
            if (val.kind != WASMTIME_I32)
                return null;
            ulong v = cast(uint) val.of.i32;
            switch (tb.ty)
            {
                case Tint8: v = cast(ulong) cast(byte) v; break;
                case Tint16: v = cast(ulong) cast(short) v; break;
                case Tint32: v = cast(ulong) cast(int) v; break;
                case Tuns8, Tbool, Tchar: v &= 0xFF; break;
                case Tuns16, Twchar: v &= 0xFFFF; break;
                default: v &= 0xFFFF_FFFF; break;
            }
            return new IntegerExp(loc, v, type);
        case Tint64, Tuns64:
            if (val.kind != WASMTIME_I64)
                return null;
            return new IntegerExp(loc, cast(ulong) val.of.i64, type);
        case Tfloat32:
            if (val.kind != WASMTIME_F32)
                return null;
            return new RealExp(loc, real_t(val.of.f32), type);
        case Tfloat64:
            if (val.kind != WASMTIME_F64)
                return null;
            return new RealExp(loc, real_t(val.of.f64), type);
        case Tfloat80:
        {
            if (val.kind != WASMTIME_V128)
                return null;
            real r = 0;
            memcpy(&r, val.of.v128.ptr, 10);
            return new RealExp(loc, r, type);
        }
        default:
            return null;
    }
}

private Expressions* ipNewExps(size_t n)
{
    auto a = new Expressions(n);
    foreach (ref x; *a)
        x = null;
    return a;
}
}
