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
import dmd.typesem : toBasetype, size, nextOf;
import dmd.expressionsem : toInteger;
import dmd.funcsem : functionSemantic3, isVirtual, isVirtualMethod;
import dmd.dsymbolsem : isPOD;
import dmd.visitor;

enum WasmCtfeMode
{
    off,
    wasm,
    verify,
    codegen,
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

void wasmCtfeCompare(Expression e, Expression astResult, Expression wasmResult)
{
    const a = astResult.toChars();
    const w = wasmResult.toChars();
    if (strcmp(a, w) != 0)
    {
        wasmCtfeStats.mismatches++;
        fprintf(stderr, "wasm-ctfe MISMATCH at %s: `%s`\n  ast:  %s\n  wasm: %s\n",
            e.loc.toChars(), e.toChars(), a, w);
    }
}

Expression tryWasmCtfe(Expression e)
{
    auto ce = e.isCallExp();
    if (!ce || !ce.f)
        return null;
    if (mode == WasmCtfeMode.codegen)
    {
        wasmCtfeCodegenTest(ce.f);
        return null;
    }
    return tryWasmCtfeCall(ce.f, ce.arguments ? (*ce.arguments)[] : null, e.type, e.loc);
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

bool scanLegality(FuncDeclaration fd)
{
    bool[void*] inProgress;
    return scanLegalityImpl(fd, inProgress) == 1;
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
__gshared uint[void*] attemptBudget;
enum attemptBudgetMax = 16;

int scanLegalityImpl(FuncDeclaration fd, ref bool[void*] inProgress)
{
    if (auto p = cast(void*) fd in legalityVerdicts)
        return *p == 1 ? 1 : 0;
    if (cast(void*) fd in inProgress)
        return 1;
    inProgress[cast(void*) fd] = true;

    if (trustedModule(fd))
    {
        legalityVerdicts[cast(void*) fd] = 1;
        return 1;
    }
    if (!fd.fbody || fd.errors)
    {
        const ok = isBuiltin(fd) != BUILTIN.unimp;
        legalityVerdicts[cast(void*) fd] = ok ? 1 : 0;
        return ok ? 1 : 0;
    }
    if (fd.semanticRun < PASS.semantic3done && !insideTemplateInstance(fd))
        fd.functionSemantic3();
    if (fd.semanticRun < PASS.semantic3done)
    {
        inProgress.remove(cast(void*) fd);
        return 2;
    }
    Module mod = fd.getModule();
    if (!mod || !mod.srcfile.toChars() || mod.filetype == FileType.c)
    {
        legalityVerdicts[cast(void*) fd] = 0;
        return 0;
    }

    scope scanner = new LegalityScanner();
    fd.fbody.accept(scanner);
    int verdict = scanner.bad ? 0 : 1;
    if (verdict == 1)
    {
        foreach (callee; scanner.callees)
        {
            const cv = scanLegalityImpl(callee, inProgress);
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
        legalityVerdicts[cast(void*) fd] = verdict == 1 ? 1 : 0;
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
            reject("indirect call");
            return;
        }
        if (f.isVirtualMethod())
        {
            reject("virtual call");
            return;
        }
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
        reject("address of symbol");
    }

    override void visit(AddrExp e)
    {
        reject("address taken");
    }

    override void visit(PtrExp e)
    {
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
        if (e.type && e.type.toBasetype().ty == Tclass)
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
