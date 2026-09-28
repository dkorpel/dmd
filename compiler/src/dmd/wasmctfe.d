module dmd.wasmctfe;

import core.stdc.stdio;
import core.stdc.string;
import core.stdc.stdlib : getenv;

import dmd.arraytypes;
import dmd.astenums;
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
import dmd.mangle : mangleExact;
import dmd.mtype;
import dmd.root.array;
import dmd.root.ctfloat;
import dmd.root.file;
import dmd.root.filename;
import dmd.root.rmem;
import dmd.root.string : toDString;
import dmd.root.stringtable;
import dmd.statement;
import dmd.typesem : toBasetype, size, nextOf, defaultInitLiteral;
import dmd.expressionsem : toInteger, toUInteger;
import dmd.funcsem : functionSemantic3, isVirtual, isVirtualMethod;
import dmd.dsymbolsem : isPOD;
import dmd.visitor;

enum WasmCtfeMode
{
    off,
    wasm,
    verify,
    codegen,
    inproc,
}

struct WasmCtfeStats
{
    uint calls;
    uint attempts;
    uint successes;
    uint runFailures;
    uint compileFailures;
    uint unsupported;
    uint illegal;
    uint cacheHits;
    uint mismatches;
}

__gshared WasmCtfeStats wasmCtfeStats;

bool wasmCtfeBuildActiveNow()
{
    if (wasmCtfeMode() == WasmCtfeMode.off)
        return false;
    import dmd.glue : wasmCtfeBuildInProgress;
    return wasmCtfeBuildInProgress();
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
    const(char)* workDir = null;
    uint seq = 0;
    StringTable!(const(char)[]) resultCache;
    StringTable!(bool) failCache;
    bool cachesInit = false;
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
            if (strcmp(p, "wasm") == 0)
                mode = WasmCtfeMode.wasm;
            else if (strcmp(p, "verify") == 0)
                mode = WasmCtfeMode.verify;
            else if (strcmp(p, "codegen") == 0)
                mode = WasmCtfeMode.codegen;
            else if (strcmp(p, "inproc") == 0)
                mode = WasmCtfeMode.inproc;
        }
        verbose = getenv("DMD_CTFE_VERBOSE") !is null;
        if (mode != WasmCtfeMode.off)
        {
            import core.stdc.stdlib : atexit;
            atexit(&wasmCtfeAtExit);
        }
        keepFiles = getenv("DMD_CTFE_KEEP") !is null;
        if (const d = getenv("DMD_CTFE_DIR"))
        {
            if (*d)
                workDir = strdupz(d.toDString());
        }
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
        fprintf(stderr, "wasm-ctfe: calls=%u attempts=%u ok=%u runfail=%u compilefail=%u unsupported=%u illegal=%u cachehit=%u mismatch=%u\n",
            calls, attempts, successes, runFailures, compileFailures, unsupported, illegal, cacheHits, mismatches);
}

private bool ipResultEqual(Expression astResult, Expression wasmResult)
{
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
        if (auto asl = astResult.isStructLiteralExp())
        {
            if (asl.sd is wsl.sd)
            {
                const n = wsl.elements ? wsl.elements.length : 0;
                const na = asl.elements ? asl.elements.length : 0;
                bool same = na <= n;
                foreach (i; 0 .. n)
                {
                    auto ael = i < na ? (*asl.elements)[i] : null;
                    if (!ael)
                        continue;
                    if (!same || !ipResultEqual(ael, (*wsl.elements)[i]))
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
            if (n && wal[0] && ipResultEqual(astResult, wal[0]))
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
                    if (!ael || !wel || !ipResultEqual(ael, wel))
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
    return strcmp(astResult.toChars(), wasmResult.toChars()) == 0;
}

void wasmCtfeCompare(Expression e, Expression astResult, Expression wasmResult)
{
    if (ipResultEqual(astResult, wasmResult))
        return;
    wasmCtfeStats.mismatches++;
    fprintf(stderr, "wasm-ctfe MISMATCH at %s: `%s`\n  ast:  %s\n  wasm: %s\n",
        e.loc.toChars(), e.toChars(), astResult.toChars(), wasmResult.toChars());
}

Expression tryWasmCtfe(Expression e)
{
    auto ce = e.isCallExp();
    if (mode == WasmCtfeMode.codegen)
    {
        if (ce && ce.f)
            wasmCtfeCodegenTest(ce.f);
        return null;
    }
    if (mode == WasmCtfeMode.inproc || mode == WasmCtfeMode.verify)
    {
        wasmCtfeStats.calls++;
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
    if (!ce || !ce.f)
        return null;
    return tryWasmCtfeCall(ce.f, ce.arguments ? (*ce.arguments)[] : null, e.type, e.loc);
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

private bool ipExprSupported(Expression e)
{
    import dmd.visitor.postorder : walkPostorder;
    extern (C++) final class Scan : StoppableVisitor
    {
        alias visit = typeof(super).visit;
        VarDeclarations declared;
        VarDeclarations funcLocals;
        override void visit(DeclarationExp e)
        {
            if (auto vd = e.declaration ? e.declaration.isVarDeclaration() : null)
                declared.push(vd);
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
            const ty = e.type.toBasetype().ty;
            if (ty == Taarray || ty == Tclass || ty == Tfloat80
                || ty == Timaginary80 || ty == Tcomplex80)
                stop = true;
        }
        override void visit(ArrayLiteralExp e)
        {
            visit(cast(Expression) e);
            if (stop)
                return;
            auto tb = e.type ? e.type.toBasetype() : null;
            if (tb && tb.ty == Tarray && e.elements && e.elements.length && !e.onstack && !e.lowering)
                stop = true;
        }
        override void visit(CatExp e)
        {
            if (!e.lowering)
                stop = true;
        }
        override void visit(CatAssignExp e)
        {
            if (!e.lowering)
                stop = true;
        }
        override void visit(NewExp e)
        {
            if (!e.lowering)
                stop = true;
        }
        override void visit(AssignExp e)
        {
            if (e.e1.isArrayLengthExp())
                stop = true;
        }
        override void visit(FuncExp)
        {
            stop = true;
        }
        override void visit(CallExp e)
        {
            visit(cast(Expression) e);
            if (stop || !e.f)
                return;
            if (e.f.isNested())
                stop = true;
            if (auto m = e.f.getModule())
                if (m.filetype == FileType.c)
                    stop = true;
        }
        override void visit(DelegateExp)
        {
            stop = true;
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
            if (tb.ty == Tclass || fb.ty == Tclass)
                stop = true;
            else if (tb.ty == Tarray && fb.ty == Tarray
                && tb.nextOf().size() != fb.nextOf().size())
                stop = true;
        }
    }
    scope v = new Scan();
    if (walkPostorder(e, v))
        return false;
    foreach (vd; v.funcLocals)
    {
        bool found = false;
        foreach (dv; v.declared)
            if (dv is vd)
            {
                found = true;
                break;
            }
        if (!found)
            return false;
    }
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
        extern (D) void put(Dsymbol s)
        {
            kb.writeByte(0);
            kb.writestring(s.toPrettyChars());
        }
    }
    scope v = new SymKey();
    v.kb = &kb;
    walkPostorder(e, v);
}

Expression tryWasmCtfeExpr(Expression e)
{
    if (!e.type || (!ipScalarType(e.type) && !ipMemType(e.type)))
        return null;
    if (e.isIntegerExp() || e.isRealExp() || e.isStringExp() || e.isNullExp()
        || e.isArrayLiteralExp() || e.isStructLiteralExp() || e.isVarExp()
        || e.isSymOffExp() || e.isFuncExp())
        return null;
    if (!ipHasCall(e))
        return null;
    if (!ipExprSupported(e))
        return null;
    auto mod = Module.rootModule;
    if (!mod)
        return null;
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
    fd.fbody = new ReturnStatement(e.loc, e);
    fd.semanticRun = PASS.semantic3done;
    auto r = tryWasmCtfeInproc(fd, null, null, e.type, e.loc);
    if (auto sv = ipResultCache.insert(kb[], null))
        sv.value = r;
    return r;
}

void wasmCtfeCodegenTest(FuncDeclaration fd)
{
    import dmd.common.outbuffer : OutBuffer;
    import dmd.glue : wasmCtfeGenerate;

    __gshared bool[void*] done;
    if (cast(void*) fd in done)
        return;
    done[cast(void*) fd] = true;

    OutBuffer buf;
    const(char)[][] unresolved;
    const ok = wasmCtfeGenerate(fd, buf, unresolved);
    char[256] name = void;
    snprintf(name.ptr, name.length, "wasmctfe_%u.wasm", seq);
    seq++;
    if (ok)
    {
        import dmd.utils : writeFile;
        import dmd.location : Loc;
        writeFile(Loc.initial, name[0 .. strlen(name.ptr)], buf[]);
    }
    fprintf(stderr, "wasm-ctfe codegen %s: fn=%s size=%zu unresolved=%zu\n",
        ok ? name.ptr : "FAILED".ptr, fd.toPrettyChars(), buf.length, unresolved.length);
    foreach (u; unresolved)
        fprintf(stderr, "  undefined: %.*s\n", cast(int) u.length, u.ptr);
}

Expression tryWasmCtfeCall(FuncDeclaration fd, Expression[] args, Type resultType, Loc loc)
{
    version (Posix)
    {
        wasmCtfeStats.calls++;
        if (!fd || !resultType)
            return null;
        if (fd.isNested() || fd.needThis() || fd.isInstantiated() || fd.isVirtual())
            return null;
        auto tf = fd.type ? fd.type.isTypeFunction() : null;
        if (!tf || tf.isRef || tf.parameterList.varargs != VarArg.none)
            return null;
        if (fd.semanticRun < PASS.semantic3done)
            return null;
        if (!fd.fbody || fd.errors)
            return null;
        Module mod = fd.getModule();
        if (!mod || !mod.srcfile.toChars() || mod.filetype == FileType.c)
            return null;
        if (!isSupportedType(resultType) || resultType.toBasetype().ty == Tvoid)
        {
            wasmCtfeStats.unsupported++;
            return null;
        }
        bool paramHasDynArray = false;
        foreach (size_t _i, Parameter p; tf.parameterList)
        {
            if (p.storageClass & (STC.ref_ | STC.out_ | STC.lazy_))
                return null;
            if (!isSupportedType(p.type))
            {
                wasmCtfeStats.unsupported++;
                return null;
            }
            if (containsDynArray(p.type))
                paramHasDynArray = true;
        }
        if (paramHasDynArray && containsMutableDynArray(resultType))
        {
            wasmCtfeStats.unsupported++;
            return null;
        }
        if (args.length != tf.parameterList.length)
            return null;

        ShimState shimState;
        auto st = &shimState;
        OutBuffer argsrc;
        foreach (i; 0 .. args.length)
        {
            if (i)
                argsrc.writestring(", ");
            if (!renderArg(args[i], argsrc, st))
            {
                wasmCtfeStats.unsupported++;
                return null;
            }
        }

        const gagged = global.startGagging();
        const legal = scanLegality(fd);
        if (global.endGagging(gagged))
        {
            legalityVerdicts[cast(void*) fd] = 0;
            wasmCtfeStats.illegal++;
            return null;
        }
        if (!legal)
        {
            wasmCtfeStats.illegal++;
            if (verbose)
                fprintf(stderr, "wasm-ctfe: illegal body: %s\n", fd.toPrettyChars());
            return null;
        }

        const mangled = mangleExact(fd);
        OutBuffer keybuf;
        keybuf.writestring(mangled);
        keybuf.writeByte(0);
        keybuf.writestring(argsrc[]);
        const key = keybuf[];

        initCaches();
        if (auto sv = failCache.lookup(key))
        {
            wasmCtfeStats.cacheHits++;
            return null;
        }
        if (auto sv = resultCache.lookup(key))
        {
            wasmCtfeStats.cacheHits++;
            auto payload = sv.value;
            return decodePayload(payload, resultType, loc);
        }

        {
            auto bp = cast(void*) fd in attemptBudget;
            const spent = bp ? *bp : 0;
            if (spent >= attemptBudgetMax)
                return null;
            attemptBudget[cast(void*) fd] = spent + 1;
        }
        wasmCtfeStats.attempts++;
        if (verbose)
            fprintf(stderr, "wasm-ctfe: attempt %s(%s)\n", fd.toPrettyChars(), argsrc.peekChars());

        const(char)[] payload = compileAndRun(fd, tf, mangled, argsrc[], mod, st);
        if (payload is null)
        {
            failCache.insert(key, true);
            return null;
        }
        auto result = decodePayload(payload, resultType, loc);
        if (result is null)
        {
            failCache.insert(key, true);
            return null;
        }
        resultCache.insert(key, payload);
        wasmCtfeStats.successes++;
        if (verbose)
            fprintf(stderr, "wasm-ctfe: success -> %s\n", result.toChars());
        return result;
    }
    else
        return null;
}

private:

void initCaches()
{
    if (cachesInit)
        return;
    cachesInit = true;
    resultCache._init(64);
    failCache._init(64);
}

const(char)* strdupz(const(char)[] s)
{
    auto p = cast(char*) mem.xmalloc(s.length + 1);
    p[0 .. s.length] = s[];
    p[s.length] = 0;
    return p;
}

bool isCharTy(TY ty)
{
    return ty == Tchar || ty == Twchar || ty == Tdchar;
}

bool isSupportedScalar(Type t)
{
    auto tb = t.toBasetype();
    switch (tb.ty)
    {
    case Tint8, Tuns8, Tint16, Tuns16, Tint32, Tuns32, Tint64, Tuns64:
    case Tbool, Tchar, Twchar, Tdchar:
    case Tfloat32, Tfloat64:
        return true;
    default:
        return false;
    }
}

bool isSupportedType(Type t)
{
    if (!t)
        return false;
    auto tb = t.toBasetype();
    if (tb.ty == Tarray || tb.ty == Tsarray)
        return isSupportedType(tb.nextOf());
    if (auto ts = tb.isTypeStruct())
        return isSupportedStruct(ts.sym);
    return isSupportedScalar(tb);
}

__gshared byte[void*] structVerdicts;

bool isSupportedStruct(StructDeclaration sd)
{
    if (!sd)
        return false;
    if (auto p = cast(void*) sd in structVerdicts)
        return *p == 1;
    structVerdicts[cast(void*) sd] = 0;
    if (!sd.isPOD() || sd.isUnionDeclaration() || sd.sizeok != Sizeok.done)
        return false;
    if (!sd.alignment.isDefault())
        return false;
    foreach (v; sd.fields)
    {
        if (v.overlapped || !v.alignment.isDefault() || v.isBitFieldDeclaration())
            return false;
        if (!isSupportedType(v.type) || !isLayoutStableType(v.type))
            return false;
    }
    structVerdicts[cast(void*) sd] = 1;
    return true;
}

bool isLayoutStableType(Type t)
{
    auto tb = t.toBasetype();
    if (tb.ty == Tint64 || tb.ty == Tuns64)
        return false;
    if (tb.ty == Tarray || tb.ty == Tsarray)
        return isLayoutStableType(tb.nextOf());
    if (auto ts = tb.isTypeStruct())
    {
        foreach (v; ts.sym.fields)
        {
            if (!isLayoutStableType(v.type))
                return false;
        }
    }
    return true;
}

bool containsDynArray(Type t)
{
    auto tb = t.toBasetype();
    if (tb.ty == Tarray)
        return true;
    if (tb.ty == Tsarray)
        return containsDynArray(tb.nextOf());
    if (auto ts = tb.isTypeStruct())
    {
        foreach (v; ts.sym.fields)
            if (containsDynArray(v.type))
                return true;
    }
    return false;
}

bool containsMutableDynArray(Type t)
{
    auto tb = t.toBasetype();
    if (tb.ty == Tarray)
    {
        auto et = tb.nextOf();
        if (!(et.isImmutable() || et.isConst()))
            return true;
        return containsMutableDynArray(et);
    }
    if (tb.ty == Tsarray)
        return containsMutableDynArray(tb.nextOf());
    if (auto ts = tb.isTypeStruct())
    {
        foreach (v; ts.sym.fields)
            if (containsMutableDynArray(v.type))
                return true;
    }
    return false;
}

struct ShimState
{
    OutBuffer mirrors;
    size_t[void*] structIds;
}

void writeScalarTypeSrc(Type t, ref OutBuffer buf)
{
    auto tb = t.toBasetype();
    switch (tb.ty)
    {
    case Tint8:     buf.writestring("byte"); break;
    case Tuns8:     buf.writestring("ubyte"); break;
    case Tint16:    buf.writestring("short"); break;
    case Tuns16:    buf.writestring("ushort"); break;
    case Tint32:    buf.writestring("int"); break;
    case Tuns32:    buf.writestring("uint"); break;
    case Tint64:    buf.writestring("long"); break;
    case Tuns64:    buf.writestring("ulong"); break;
    case Tbool:     buf.writestring("bool"); break;
    case Tchar:     buf.writestring("char"); break;
    case Twchar:    buf.writestring("wchar"); break;
    case Tdchar:    buf.writestring("dchar"); break;
    case Tfloat32:  buf.writestring("float"); break;
    case Tfloat64:  buf.writestring("double"); break;
    default: assert(0);
    }
}

void writeTypeSrc(Type t, ref OutBuffer buf, ShimState* st)
{
    auto tb = t.toBasetype();
    if (tb.ty == Tarray)
    {
        buf.writestring("const(");
        writeTypeSrc(tb.nextOf(), buf, st);
        buf.writestring(")[]");
        return;
    }
    if (auto tsa = tb.isTypeSArray())
    {
        writeTypeSrc(tsa.nextOf(), buf, st);
        buf.printf("[%llu]", cast(ulong) tsa.dim.toInteger());
        return;
    }
    if (auto ts = tb.isTypeStruct())
    {
        const id = structMirror(ts.sym, st);
        buf.printf("__S%llu", cast(ulong) id);
        return;
    }
    writeScalarTypeSrc(tb, buf);
}

size_t structMirror(StructDeclaration sd, ShimState* st)
{
    if (auto p = cast(void*) sd in st.structIds)
        return *p;
    const id = st.structIds.length;
    st.structIds[cast(void*) sd] = id;
    OutBuffer def;
    def.printf("struct __S%llu\n{\n", cast(ulong) id);
    foreach (i, v; sd.fields)
    {
        def.writestring("    ");
        writeTypeSrc(v.type, def, st);
        def.printf(" f%llu;\n", cast(ulong) i);
    }
    def.writestring("}\n");
    st.mirrors.writestring(def[]);
    return id;
}

bool renderArg(Expression arg, ref OutBuffer buf, ShimState* st)
{
    auto tb = arg.type ? arg.type.toBasetype() : null;
    if (!tb)
        return false;
    if (auto ie = arg.isIntegerExp())
    {
        if (!isSupportedScalar(tb))
            return false;
        buf.writestring("cast(");
        writeScalarTypeSrc(tb, buf);
        buf.printf(")0x%llxLU", cast(ulong) ie.toInteger());
        return true;
    }
    if (auto re = arg.isRealExp())
    {
        if (tb.ty != Tfloat32 && tb.ty != Tfloat64)
            return false;
        buf.writestring("cast(");
        writeScalarTypeSrc(tb, buf);
        buf.writestring(")");
        const d = cast(double) re.value;
        if (d != d)
            buf.writestring("(double.nan)");
        else if (d == cast(double) real_t.infinity)
            buf.writestring("(double.infinity)");
        else if (d == -cast(double) real_t.infinity)
            buf.writestring("(-double.infinity)");
        else
        {
            char[64] tmp = void;
            const n = snprintf(tmp.ptr, tmp.length, "%a", d);
            buf.writestring(tmp[0 .. n]);
        }
        return true;
    }
    if (auto se = arg.isStringExp())
    {
        if (tb.ty != Tarray && tb.ty != Tsarray)
            return false;
        if (se.sz == 1)
        {
            if (tb.ty == Tarray)
            {
                buf.writestring("cast(");
                writeTypeSrc(tb, buf, st);
                buf.writestring(")");
            }
            buf.writestring("x\"");
            foreach (i; 0 .. se.len)
                buf.printf("%02X", (cast(const ubyte*) se.peekData().ptr)[i]);
            buf.writestring("\"");
            return true;
        }
        if (tb.ty == Tarray)
        {
            buf.writestring("cast(");
            writeTypeSrc(tb, buf, st);
            buf.writestring(")");
        }
        buf.writestring("[");
        foreach (i; 0 .. se.len)
        {
            if (i)
                buf.writestring(", ");
            buf.writestring("cast(");
            writeScalarTypeSrc(tb.nextOf(), buf);
            buf.printf(")0x%llxLU", cast(ulong) se.getIndex(i));
        }
        buf.writestring("]");
        return true;
    }
    if (auto ne = arg.isNullExp())
    {
        if (tb.ty != Tarray)
            return false;
        buf.writestring("cast(");
        writeTypeSrc(tb, buf, st);
        buf.writestring(")null");
        return true;
    }
    if (auto ale = arg.isArrayLiteralExp())
    {
        if (tb.ty != Tarray && tb.ty != Tsarray)
            return false;
        if (tb.ty == Tarray)
        {
            buf.writestring("cast(");
            writeTypeSrc(tb, buf, st);
            buf.writestring(")");
        }
        buf.writestring("[");
        foreach (i; 0 .. ale.elements ? ale.elements.length : 0)
        {
            if (i)
                buf.writestring(", ");
            auto el = (*ale.elements)[i] ? (*ale.elements)[i] : ale.basis;
            if (!el || !renderArg(el, buf, st))
                return false;
        }
        buf.writestring("]");
        return true;
    }
    if (auto sle = arg.isStructLiteralExp())
    {
        auto ts = tb.isTypeStruct();
        if (!ts || !isSupportedStruct(ts.sym))
            return false;
        const id = structMirror(ts.sym, st);
        buf.printf("__S%llu(", cast(ulong) id);
        const nfields = ts.sym.fields.length;
        foreach (i; 0 .. nfields)
        {
            if (i)
                buf.writestring(", ");
            Expression el = sle.elements && i < sle.elements.length ? (*sle.elements)[i] : null;
            if (!el)
                return false;
            if (!renderArg(el, buf, st))
                return false;
        }
        buf.writestring(")");
        return true;
    }
    return false;
}

bool scanLegality(FuncDeclaration fd, bool relaxed = false)
{
    bool[void*] inProgress;
    return scanLegalityImpl(fd, inProgress, relaxed) == 1;
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
__gshared uint[void*] attemptBudget;
__gshared bool[void*] forcedSem3Errors;

public void ipForceSemantic3(FuncDeclaration fd)
{
    if (fd.semanticRun >= PASS.semantic3done)
        return;
    fd.functionSemantic3();
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

    if (trustedModule(fd))
    {
        (*verdicts)[cast(void*) fd] = 1;
        return 1;
    }
    if (!fd.fbody || fd.errors)
    {
        const ok = isBuiltin(fd) != BUILTIN.unimp;
        (*verdicts)[cast(void*) fd] = ok ? 1 : 0;
        return ok ? 1 : 0;
    }
    if (fd.semanticRun < PASS.semantic3done && !insideTemplateInstance(fd))
        ipForceSemantic3(fd);
    if (fd.semanticRun < PASS.semantic3done)
    {
        inProgress.remove(cast(void*) fd);
        return 2;
    }
    Module mod = fd.getModule();
    if (!mod || !mod.srcfile.toChars() || mod.filetype == FileType.c)
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

bool trustedModule(FuncDeclaration fd)
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
        {
            if (auto ts = tb.isTypeStruct())
                return hasOverlaps(ts.sym);
            return false;
        }
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
        {
            reject("__ctfe");
            return;
        }
        if (auto v = e.var ? e.var.isVarDeclaration() : null)
        {
            if (v.isDataseg() && !(v.storage_class & STC.manifest))
            {
                if (!v.type || !(v.type.isImmutable() || v.type.isConst()) || !v._init)
                {
                    reject("mutable global");
                    return;
                }
            }
        }
        checkExpType(e);
    }

    override void visit(VarDeclaration v)
    {
        if (bad)
            return;
        if (v.semanticRun < PASS.semanticdone)
        {
            reject("unresolved declaration");
            return;
        }
        if (v.isDataseg() && !(v.storage_class & STC.manifest))
        {
            reject("static local");
            return;
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
                if (v.isDataseg() && !(v.storage_class & STC.manifest))
                    reject("address of global");
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
        reject("delete");
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

const(char)[] compileAndRun(FuncDeclaration fd, TypeFunction tf, const(char)* mangled,
    const(char)[] argsrc, Module mod, ShimState* st)
{
    const dir = ensureWorkDir();
    if (!dir)
    {
        if (verbose)
            fprintf(stderr, "wasm-ctfe: no work dir\n");
        return null;
    }
    const id = seq++;

    OutBuffer decl;
    decl.printf("pragma(mangle, \"%s\")\n", mangled);
    writeTypeSrc(tf.next, decl, st);
    decl.writestring(" __wctfe_fn(");
    foreach (size_t i, Parameter p; tf.parameterList)
    {
        if (i)
            decl.writestring(", ");
        writeTypeSrc(p.type, decl, st);
        decl.printf(" p%llu", cast(ulong) i);
    }
    decl.writestring(");\n");
    OutBuffer shim;
    shim.writestring("module __wctfe;\n");
    shim.writestring("import core.stdc.stdio;\n");
    shim.writestring(st.mirrors[]);
    shim.writestring(decl[]);
    shim.writestring(q{
private void __w(T)(T v)
{
    static if (is(immutable T == immutable U[], U))
    {
        if (v is null) { printf("N\n"); return; }
        printf("A %llu\n", cast(ulong) v.length);
        static if (U.sizeof == 1 && !is(U == struct))
        {
            fwrite(v.ptr, 1, v.length, stdout);
            printf("\n");
        }
        else
        {
            foreach (i; 0 .. v.length)
                __w(v[i]);
        }
    }
    else static if (is(T == struct))
    {
        foreach (ref f; v.tupleof)
            __w(f);
    }
    else static if (__traits(isStaticArray, T))
    {
        printf("A %llu\n", cast(ulong) v.length);
        static if (typeof(v[0]).sizeof == 1 && !is(typeof(v[0]) == struct))
        {
            fwrite(v.ptr, 1, v.length, stdout);
            printf("\n");
        }
        else
        {
            foreach (ref e; v)
                __w(e);
        }
    }
    else static if (__traits(isFloating, T))
        printf("F %a\n", cast(double) v);
    else
        printf("I %lld\n", cast(long) v);
}
});
    shim.writestring("void main()\n{\n    printf(\"\\n__WCTFE_B__\\n\");\n");
    shim.writestring("    __w(__wctfe_fn(");
    shim.writestring(argsrc);
    shim.writestring("));\n");
    shim.writestring("    printf(\"__WCTFE_E__\\n\");\n}\n");

    import core.sys.posix.unistd : getpid;
    import core.sys.posix.sys.stat : mkdir;
    OutBuffer subDir;
    subDir.printf("%s/r%d_%u", dir, getpid(), id);
    const subDirz = strdupz(subDir[]);
    mkdir(subDirz, octal!775);
    OutBuffer shimPath, wasmPath;
    shimPath.printf("%s/shim.d", subDirz);
    wasmPath.printf("%s/out.wasm", subDirz);
    const shimPathz = strdupz(shimPath[]);
    const wasmPathz = strdupz(wasmPath[]);

    if (!File.write(shimPathz, shim[]))
    {
        if (verbose)
            fprintf(stderr, "wasm-ctfe: cannot write %s\n", shimPathz);
        return null;
    }

    Array!(const(char)*) argv;
    argv.push(strdupz(global.params.argv0));
    argv.push("-mwasm32");
    argv.push("-os=wasi");
    argv.push("-i");
    OutBuffer ofArg, odArg;
    ofArg.printf("-of=%s", wasmPathz);
    odArg.printf("-od=%s", subDirz);
    argv.push(strdupz(ofArg[]));
    argv.push(strdupz(odArg[]));
    argv.push(shimPathz);
    argv.push(strdupz(mod.srcfile.toChars().toDString()));
    addImportPath(argv, FileName.path(mod.srcfile.toChars()).toDString());
    foreach (m; Module.amodules)
    {
        if (m.srcfile.toChars())
            addImportPath(argv, FileName.path(m.srcfile.toChars()).toDString());
    }
    foreach (p; global.params.imppath)
        addImportPath(argv, p.path.toDString());
    argv.push(null);

    OutBuffer output;
    int status = runProcess(argv[], output);
    if (status != 0)
    {
        wasmCtfeStats.compileFailures++;
        if (verbose)
            fprintf(stderr, "wasm-ctfe: compile failed (%d):\n%s\n", status, output.peekChars());
        cleanup(subDirz);
        return null;
    }

    Array!(const(char)*) rargv;
    rargv.push("wasmtime");
    rargv.push(wasmPathz);
    rargv.push(null);
    OutBuffer routput;
    status = runProcess(rargv[], routput);
    cleanup(subDirz);
    if (status != 0)
    {
        wasmCtfeStats.runFailures++;
        if (verbose)
            fprintf(stderr, "wasm-ctfe: run failed (%d):\n%s\n", status, routput.peekChars());
        if (find(routput[], "unknown import") >= 0)
            legalityVerdicts[cast(void*) fd] = 0;
        return null;
    }

    const outs = routput[];
    enum beginMarker = "\n__WCTFE_B__\n";
    enum endMarker = "__WCTFE_E__\n";
    const bpos = find(outs, beginMarker);
    if (bpos < 0)
        return null;
    const after = outs[bpos + beginMarker.length .. $];
    const epos = find(after, endMarker);
    if (epos < 0)
        return null;
    auto payload = after[0 .. epos];
    auto copy = cast(char*) mem.xmalloc(payload.length);
    copy[0 .. payload.length] = payload[];
    return copy[0 .. payload.length];
}

void cleanup(const(char)* subDir)
{
    if (keepFiles)
        return;
    import core.sys.posix.dirent : opendir, readdir, closedir, dirent;
    import core.sys.posix.unistd : unlink, rmdir;
    auto d = opendir(subDir);
    if (!d)
        return;
    while (auto ent = readdir(d))
    {
        const name = ent.d_name.ptr.toDString();
        if (name == "." || name == "..")
            continue;
        OutBuffer b;
        b.printf("%s/%.*s", subDir, cast(int) name.length, name.ptr);
        unlink(strdupz(b[]));
    }
    closedir(d);
    rmdir(subDir);
}

ptrdiff_t find(const(char)[] haystack, const(char)[] needle)
{
    if (needle.length > haystack.length)
        return -1;
    foreach (i; 0 .. haystack.length - needle.length + 1)
    {
        if (haystack[i .. i + needle.length] == needle)
            return i;
    }
    return -1;
}

void addImportPath(ref Array!(const(char)*) argv, const(char)[] path)
{
    if (path.length == 0)
        return;
    OutBuffer b;
    b.printf("-I%.*s", cast(int) path.length, path.ptr);
    foreach (existing; argv[])
    {
        if (existing && existing.toDString() == b[])
            return;
    }
    argv.push(strdupz(b[]));
}

const(char)* ensureWorkDir()
{
    __gshared const(char)* cached = null;
    __gshared bool tried = false;
    if (tried)
        return cached;
    tried = true;
    import core.sys.posix.sys.stat : mkdir;
    OutBuffer b;
    if (workDir)
        b.writestring(workDir.toDString());
    else
        b.printf("./__wasmctfe");
    const dirz = strdupz(b[]);
    import core.stdc.errno : errno, EEXIST;
    if (mkdir(dirz, octal!775) != 0 && errno != EEXIST)
        return null;
    cached = dirz;
    return cached;
}

template octal(uint n)
{
    enum octal = (n / 1000 % 10) * 512 + (n / 100 % 10) * 64 + (n / 10 % 10) * 8 + (n % 10);
}

int runProcess(const(char)*[] argv, ref OutBuffer sink)
{
    import core.sys.posix.unistd : fork, close, dup2, execvp, pipe, read, _exit;
    import core.sys.posix.sys.wait : waitpid, WIFEXITED, WEXITSTATUS, WIFSIGNALED;
    import core.sys.posix.fcntl;

    int[2] fds;
    if (pipe(fds) == -1)
        return -1;
    const pid = fork();
    if (pid == 0)
    {
        import core.sys.posix.stdlib : unsetenv;
        unsetenv("DMD_CTFE");
        dup2(fds[1], 1);
        dup2(fds[1], 2);
        close(fds[0]);
        close(fds[1]);
        execvp(argv[0], cast(char**) argv.ptr);
        _exit(127);
    }
    if (pid == -1)
    {
        close(fds[0]);
        close(fds[1]);
        return -1;
    }
    close(fds[1]);
    char[4096] buf = void;
    while (true)
    {
        const n = read(fds[0], buf.ptr, buf.length);
        if (n <= 0)
            break;
        sink.writestring(buf[0 .. n]);
    }
    close(fds[0]);
    int status;
    waitpid(pid, &status, 0);
    if (WIFEXITED(status))
        return WEXITSTATUS(status);
    if (WIFSIGNALED(status))
        return -2;
    return -1;
}

Expression decodePayload(const(char)[] payload, Type type, Loc loc)
{
    auto s = payload;
    auto e = decodeValue(s, type, loc);
    if (!e)
        return null;
    while (s.length && (s[0] == '\n' || s[0] == '\r'))
        s = s[1 .. $];
    if (s.length)
        return null;
    return e;
}

bool eat(ref const(char)[] s, const(char)[] prefix)
{
    if (s.length < prefix.length || s[0 .. prefix.length] != prefix)
        return false;
    s = s[prefix.length .. $];
    return true;
}

bool eatLine(ref const(char)[] s, out const(char)[] line)
{
    const p = find(s, "\n");
    if (p < 0)
        return false;
    line = s[0 .. p];
    s = s[p + 1 .. $];
    return true;
}

bool parseUlong(const(char)[] s, out ulong val)
{
    if (!s.length)
        return false;
    bool neg = false;
    if (s[0] == '-')
    {
        neg = true;
        s = s[1 .. $];
    }
    if (!s.length)
        return false;
    ulong v = 0;
    foreach (c; s)
    {
        if (c < '0' || c > '9')
            return false;
        v = v * 10 + (c - '0');
    }
    val = neg ? -v : v;
    return true;
}

Expression decodeValue(ref const(char)[] s, Type type, Loc loc)
{
    auto tb = type.toBasetype();
    if (tb.ty == Tarray)
    {
        if (eat(s, "N\n"))
            return null;
        const(char)[] line;
        if (!eat(s, "A "))
            return null;
        if (!eatLine(s, line))
            return null;
        ulong n;
        if (!parseUlong(line, n))
            return null;
        auto elemType = tb.nextOf();
        auto etb = elemType.toBasetype();
        const esz = cast(uint) etb.size();
        if (esz == 1)
        {
            if (s.length < n + 1)
                return null;
            auto bytes = s[0 .. cast(size_t) n];
            s = s[cast(size_t) n .. $];
            if (!eat(s, "\n"))
                return null;
            if (etb.ty == Tchar)
            {
                auto data = cast(char*) mem.xmalloc(cast(size_t) n);
                data[0 .. cast(size_t) n] = bytes[];
                auto se = new StringExp(loc, data[0 .. cast(size_t) n], cast(size_t) n, 1);
                se.type = type;
                se.committed = true;
                se.ownedByCtfe = OwnedBy.ctfe;
                return se;
            }
            auto elems = new Expressions(cast(size_t) n);
            foreach (i; 0 .. cast(size_t) n)
                (*elems)[i] = new IntegerExp(loc, cast(ubyte) bytes[i], elemType);
            auto ale = new ArrayLiteralExp(loc, type, elems);
            ale.ownedByCtfe = OwnedBy.ctfe;
            return ale;
        }
        if (isCharTy(etb.ty))
        {
            auto data = cast(ubyte*) mem.xmalloc(cast(size_t) n * esz);
            foreach (i; 0 .. cast(size_t) n)
            {
                const(char)[] l;
                if (!eat(s, "I ") || !eatLine(s, l))
                    return null;
                ulong v;
                if (!parseUlong(l, v))
                    return null;
                if (esz == 2)
                    (cast(ushort*) data)[i] = cast(ushort) v;
                else
                    (cast(uint*) data)[i] = cast(uint) v;
            }
            auto se = new StringExp(loc, data[0 .. cast(size_t) n * esz], cast(size_t) n, cast(ubyte) esz);
            se.type = type;
            se.committed = true;
            se.ownedByCtfe = OwnedBy.ctfe;
            return se;
        }
        auto elems = new Expressions(cast(size_t) n);
        foreach (i; 0 .. cast(size_t) n)
        {
            auto el = decodeValue(s, elemType, loc);
            if (!el)
                return null;
            (*elems)[i] = el;
        }
        { auto a = new ArrayLiteralExp(loc, type, elems); a.ownedByCtfe = OwnedBy.ctfe; return a; }
    }
    if (auto tsa = tb.isTypeSArray())
    {
        const(char)[] line;
        if (!eat(s, "A ") || !eatLine(s, line))
            return null;
        ulong n;
        if (!parseUlong(line, n))
            return null;
        if (n != cast(ulong) tsa.dim.toInteger())
            return null;
        auto elemType = tsa.nextOf();
        auto etb = elemType.toBasetype();
        const esz = cast(uint) etb.size();
        if (esz == 1 && !etb.isTypeStruct())
        {
            if (s.length < n + 1)
                return null;
            auto bytes = s[0 .. cast(size_t) n];
            s = s[cast(size_t) n .. $];
            if (!eat(s, "\n"))
                return null;
            if (etb.ty == Tchar)
            {
                auto data = cast(char*) mem.xmalloc(cast(size_t) n);
                data[0 .. cast(size_t) n] = bytes[];
                auto se = new StringExp(loc, data[0 .. cast(size_t) n], cast(size_t) n, 1);
                se.type = type;
                se.committed = true;
                se.ownedByCtfe = OwnedBy.ctfe;
                return se;
            }
            auto elems = new Expressions(cast(size_t) n);
            foreach (i; 0 .. cast(size_t) n)
                (*elems)[i] = new IntegerExp(loc, cast(ubyte) bytes[i], elemType);
            { auto a = new ArrayLiteralExp(loc, type, elems); a.ownedByCtfe = OwnedBy.ctfe; return a; }
        }
        auto elems = new Expressions(cast(size_t) n);
        foreach (i; 0 .. cast(size_t) n)
        {
            auto el = decodeValue(s, elemType, loc);
            if (!el)
                return null;
            (*elems)[i] = el;
        }
        auto ale2 = new ArrayLiteralExp(loc, type, elems);
        ale2.ownedByCtfe = OwnedBy.ctfe;
        return ale2;
    }
    if (auto ts = tb.isTypeStruct())
    {
        auto sd = ts.sym;
        auto elems = new Expressions(sd.fields.length);
        foreach (i, v; sd.fields)
        {
            auto el = decodeValue(s, v.type, loc);
            if (!el)
                return null;
            (*elems)[i] = el;
        }
        auto sle = new StructLiteralExp(loc, sd, elems, type);
        sle.type = type;
        sle.ownedByCtfe = OwnedBy.ctfe;
        return sle;
    }
    if (tb.ty == Tfloat32 || tb.ty == Tfloat64)
    {
        const(char)[] line;
        if (!eat(s, "F ") || !eatLine(s, line))
            return null;
        real_t r;
        if (line == "nan" || line == "-nan" || (line.length > 4 && line[0 .. 4] == "nan(") ||
            (line.length > 5 && line[0 .. 5] == "-nan("))
            r = real_t.nan;
        else if (line == "inf")
            r = real_t.infinity;
        else if (line == "-inf")
            r = -real_t.infinity;
        else
        {
            const linez = strdupz(line);
            bool oor;
            r = CTFloat.parse(linez, oor);
        }
        if (tb.ty == Tfloat32)
            r = real_t(cast(float) cast(double) r);
        return new RealExp(loc, r, type);
    }
    if (isSupportedScalar(tb))
    {
        const(char)[] line;
        if (!eat(s, "I ") || !eatLine(s, line))
            return null;
        ulong v;
        if (!parseUlong(line, v))
            return null;
        return new IntegerExp(loc, v, type);
    }
    return null;
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
    }

    IpModule*[void*] ipModuleCache;
    bool[void*] ipModuleFailed;

    char[512] ipTrapBuf;
}

private struct HostImport
{
    char[128] name;
    size_t nameLen;
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
}

private wasm_trap_t* ipTrap(const(char)* msg) nothrow @nogc
{
    import dmd.wasmtimec;
    return wasmtime_trap_new(msg, strlen(msg));
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
    if (auto trap = ipBumpAlloc(caller, m, cast(ulong) args[0].of.i64, r))
        return trap;
    results[0].kind = WASMTIME_I64;
    results[0].of.i64 = cast(long) r;
    return null;
}

private __gshared ulong ipTIBaseOffset;

private extern (C) wasm_trap_t* ipHostEhMatch(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    import dmd.wasmtimec;
    wasmtime_memory_t m;
    if (!ipCallerMemory(caller, m))
        return ipTrap("wasm-ctfe: no memory export");
    auto mem = ipMemSlice(caller, m);
    const o = cast(ulong) args[0].of.i64;
    const ci = cast(ulong) args[1].of.i64;
    int found = 0;
    if (o && ipTIBaseOffset)
    {
        bool rd(ulong addr, out ulong v) nothrow @nogc
        {
            if (addr + 8 > mem.length)
                return false;
            v = *cast(ulong*)(mem.ptr + addr);
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
    const sret = cast(ulong) args[0].of.i64;
    const xptr = cast(ulong) args[1].of.i64;
    const c = cast(uint) args[2].of.i32;
    if (xptr + 16 > mem.length || sret + 16 > mem.length)
        return ipTrap("wasm-ctfe: appendc out of bounds");
    ulong len = *cast(ulong*)(mem.ptr + xptr);
    ulong ptr = *cast(ulong*)(mem.ptr + xptr + 8);
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
    *cast(ulong*)(mem.ptr + xptr) = len + n;
    *cast(ulong*)(mem.ptr + xptr + 8) = np;
    *cast(ulong*)(mem.ptr + sret) = len + n;
    *cast(ulong*)(mem.ptr + sret + 8) = np;
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

private extern (C) wasm_trap_t* ipHostMemset(void* env, wasmtime_caller_t* caller,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults) nothrow @nogc
{
    wasmtime_memory_t m;
    if (!ipCallerMemory(caller, m))
        return ipTrap("wasm-ctfe: no memory export");
    auto mem = ipMemSlice(caller, m);
    const d = cast(ulong) args[0].of.i64;
    const c = args[1].of.i32;
    const n = cast(ulong) args[2].of.i64;
    if (d > mem.length || n > mem.length - d)
        return ipTrap("wasm-ctfe: memset out of bounds");
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
    const d = cast(ulong) args[0].of.i64;
    const s = cast(ulong) args[1].of.i64;
    const n = cast(ulong) args[2].of.i64;
    if (d > mem.length || n > mem.length - d || s > mem.length || n > mem.length - s)
        return ipTrap("wasm-ctfe: memcpy out of bounds");
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
    const p = cast(ulong) args[0].of.i64;
    const v = cast(ulong) args[1].of.i64;
    const n = cast(ulong) args[2].of.i64;
    const sz = cast(ulong) args[3].of.i64;
    if (sz > mem.length || n > mem.length / (sz ? sz : 1)
        || p > mem.length || n * sz > mem.length - p
        || v > mem.length || sz > mem.length - v)
        return ipTrap("wasm-ctfe: memsetn out of bounds");
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
    const p = cast(ulong) args[0].of.i64;
    const n = cast(ulong) args[2].of.i64;
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
    const a = cast(ulong) args[0].of.i64;
    const b = cast(ulong) args[1].of.i64;
    const n = cast(ulong) args[2].of.i64;
    if (a > mem.length || n > mem.length - a || b > mem.length || n > mem.length - b)
        return ipTrap("wasm-ctfe: memcmp out of bounds");
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
    const d = cast(ulong) args[0].of.i64;
    if (d > mem.length || 24 > mem.length - d)
        return ipTrap("wasm-ctfe: gc_query out of bounds");
    memset(mem.ptr + d, 0, 24);
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
        ipMemString(mem, cast(ulong) args[0].of.i64), args[1].of.i32,
        cast(ulong) args[2].of.i64, cast(ulong) args[3].of.i64);
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
        ipMemString(mem, cast(ulong) args[0].of.i64), args[1].of.i32,
        cast(ulong) args[2].of.i64, cast(ulong) args[3].of.i64, cast(ulong) args[4].of.i64);
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
        ipMemString(mem, cast(ulong) args[0].of.i64), args[1].of.i32);
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
    if (!wasmCtfeGenerate(fd, buf, unresolved))
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
    ipModuleCache[cast(void*) fd] = im;
    return im;
}

Expression tryWasmCtfeInproc(FuncDeclaration fd, Expression thisExp, Expression[] args, Type resultType, Loc loc)
{
    import dmd.wasmtimec;

    static Expression bail(FuncDeclaration fd, const(char)* why)
    {
        if (verbose)
            fprintf(stderr, "wasm-ctfe inproc: skip %s: %s\n", fd ? fd.toPrettyChars() : "?".ptr, why);
        return null;
    }

    if (!fd || !resultType)
        return bail(fd, "no fd/result type");
    if (fd.semanticRun < PASS.semantic3done)
        ipForceSemantic3(fd);
    if (fd.semanticRun < PASS.semantic3done || !fd.fbody || fd.errors)
        return bail(fd, "not semantic3done");
    if (auto m = fd.getModule())
        if (m.filetype == FileType.c)
            return bail(fd, "importc");
    if (!scanLegality(fd, true))
        return bail(fd, "legality scan");
    auto tf = fd.type ? fd.type.isTypeFunction() : null;
    const bool isCtor = fd.isCtorDeclaration() !is null;
    if (!tf || (tf.isRef && !isCtor) || tf.parameterList.varargs != VarArg.none)
        return bail(fd, "func type shape");
    if (fd.isNested())
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
    const bool sret = !isCtor && !ipScalarType(resultType) && ipMemType(resultType);
    if (isCtor)
    {
        if (!ipMemType(resultType))
            return bail(fd, "result type");
    }
    else if (!sret && !ipScalarType(resultType))
        return bail(fd, "result type");
    foreach (size_t i, Parameter p; tf.parameterList)
    {
        if (p.storageClass & (STC.ref_ | STC.out_ | STC.lazy_))
            return bail(fd, "param storage class");
        if (!ipScalarType(p.type) && !ipArgType(p.type) && !ipPtrArgType(p.type))
            return bail(fd, "param type");
    }

    wasmtime_val_t[32] vals;
    const size_t sretSlot = thisExp ? 1 : 0;
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
        keyBuf.writeByte(0);
    }
    foreach (arg; args)
    {
        keyBuf.writestring(arg.toChars());
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
            wasmtime_func_callback_t cb = &ipHostStub;
            const nm = name.data[0 .. name.size];
            if (nm == "gc_malloc" || nm == "_d_allocmemory")
                cb = &ipHostGcMalloc;
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
            else if (nm == "_d_arraybounds_indexp")
                cb = &ipHostBoundsIndex;
            else if (nm == "_d_arraybounds_slicep")
                cb = &ipHostBoundsSlice;
            else if (nm == "_d_assertp" || nm == "_d_arrayboundsp")
                cb = &ipHostAssert;
            else if (nm == "_d_arrayappendcd" || nm == "_d_arrayappendcw")
                cb = &ipHostArrayAppendC;
            else if (nm == "_d_eh_wasm_match")
            {
                cb = &ipHostEhMatch;
                if (!ipTIBaseOffset)
                {
                    if (auto cd = Type.typeinfoclass)
                        foreach (v; cd.fields)
                            if (v.ident && strcmp(v.ident.toChars(), "base") == 0)
                            {
                                ipTIBaseOffset = v.offset;
                                break;
                            }
                }
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
            fprintf(stderr, "wasm-ctfe inproc: export %.*s not found for %s\n",
                cast(int) im.exportName.length, im.exportName.ptr, fd.toPrettyChars());
        return null;
    }

    wasmtime_memory_t mem;
    ulong sretAddr;
    const ulong thisSize = thisExp ? cast(ulong) thisSd.type.size() : 0;
    if (sret || memArgCount || thisExp)
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
        if (spVal.kind != WASMTIME_I64)
            return bail(fd, "stack pointer kind");
        const size_t rsz = sret ? cast(size_t) resultType.size() : 0;
        ulong need = (rsz + 15) & ~15UL;
        need += (memArgBytes + 15) & ~15UL;
        need += (thisSize + 15) & ~15UL;
        const base = (cast(ulong) spVal.of.i64 - need) & ~15UL;
        spVal.of.i64 = cast(long) base;
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
            vals[0].kind = WASMTIME_I64;
            vals[0].of.i64 = cast(long) base;
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
                vals[memArgVal[i]].kind = WASMTIME_I64;
                vals[memArgVal[i]].of.i64 = cast(long) cur;
                cur += (cast(ulong) pt.size() + 15) & ~15UL;
                continue;
            }
            ulong alen, aptr;
            if (!ipEncodeArg(data[0 .. dataLen], cur, arg, alen, aptr))
                return bail(fd, "arg encode");
            cur = (cur + 15) & ~15UL;
            vals[memArgVal[i]].kind = WASMTIME_I64;
            vals[memArgVal[i]].of.i64 = cast(long) alen;
            vals[memArgVal[i] + 1].kind = WASMTIME_I64;
            vals[memArgVal[i] + 1].of.i64 = cast(long) aptr;
        }
        if (sret)
        {
            sretAddr = base + ((thisSize + 15) & ~15UL) + ((memArgBytes + 15) & ~15UL);
            vals[sretSlot].kind = WASMTIME_I64;
            vals[sretSlot].of.i64 = cast(long) sretAddr;
        }
    }

    ipHeapPtr = 0;
    ipHeapEnd = 0;
    if (auto err = wasmtime_context_set_fuel(ctx, 2_000_000_000))
        wasmtime_error_delete(err);
    wasmtime_val_t[1] results;
    const nresults = (sret || resultType.toBasetype().ty == Tvoid) ? 0 : 1;
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
        if (results[0].kind == WASMTIME_I64)
            resultExp = ipDecodeMem(data[0 .. dataLen], cast(ulong) results[0].of.i64, resultType, loc);
    }
    else if (sret)
    {
        const data = wasmtime_memory_data(ctx, &mem);
        const dataLen = wasmtime_memory_data_size(ctx, &mem);
        resultExp = ipDecodeMem(data[0 .. dataLen], sretAddr, resultType, loc);
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

private Expression ipDecodeMem(const(ubyte)[] mem, ulong addr, Type type, Loc loc, int depth = 0)
{
    if (depth > 64)
        return null;
    auto tb = type.toBasetype();
    const sz = cast(size_t) tb.size();
    if (addr > mem.length || sz > mem.length - addr)
        return null;
    if (tb.ty == Tarray)
    {
        const len = ipRead(mem, addr, 8);
        const ptr = ipRead(mem, addr + 8, 8);
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
        auto elems = new Expressions(cast(size_t) len);
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
        auto elems = new Expressions(n);
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
        auto elems = new Expressions(sd.fields.length);
        foreach (i, v; sd.fields)
        {
            auto el = ipDecodeMem(mem, addr + v.offset, v.type, loc, depth + 1);
            if (!el)
                return null;
            (*elems)[i] = el;
        }
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
        default:
            return null;
    }
}
