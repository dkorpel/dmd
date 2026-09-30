module dmd.backend.wasm.softreal;

import dmd.backend.cc;
import dmd.backend.cdef : SC;
import dmd.backend.symbol : Symbol, SYMIDX, symbol_calloc;
import dmd.backend.ty;
import dmd.backend.type;

nothrow:

__gshared bool wasmSoftReal;

enum SR : ubyte
{
    add,
    sub,
    mul,
    div,
    mod,
    neg,
    abs,
    sqrt,
    sin,
    cos,
    rint,
    rndtol,
    yl2x,
    yl2xp1,
    scale,
    cmp,
    fromF64,
    toF64,
    fromI64,
    fromU64,
    toI64,
    toU64,
    toI32,
    toU32,
}

immutable string[SR.max + 1] softRealNames = [
    "__wasmctfe_real_add",
    "__wasmctfe_real_sub",
    "__wasmctfe_real_mul",
    "__wasmctfe_real_div",
    "__wasmctfe_real_mod",
    "__wasmctfe_real_neg",
    "__wasmctfe_real_abs",
    "__wasmctfe_real_sqrt",
    "__wasmctfe_real_sin",
    "__wasmctfe_real_cos",
    "__wasmctfe_real_rint",
    "__wasmctfe_real_rndtol",
    "__wasmctfe_real_yl2x",
    "__wasmctfe_real_yl2xp1",
    "__wasmctfe_real_scale",
    "__wasmctfe_real_cmp",
    "__wasmctfe_real_fromF64",
    "__wasmctfe_real_toF64",
    "__wasmctfe_real_fromI64",
    "__wasmctfe_real_fromU64",
    "__wasmctfe_real_toI64",
    "__wasmctfe_real_toU64",
    "__wasmctfe_real_toI32",
    "__wasmctfe_real_toU32",
];

private __gshared Symbol*[SR.max + 1] softRealSyms;

void softRealReset()
{
    softRealSyms[] = null;
}

bool isSoftRealTy(tym_t ty)
{
    if (!wasmSoftReal)
        return false;
    const tb = tybasic(ty);
    return tb == TYreal || tb == TYireal;
}

Symbol* softRealSym(SR op)
{
    if (auto s = softRealSyms[op])
        return s;
    type* tr = tstypes[TYreal];
    type* td = tstypes[TYdouble];
    type* tl = tstypes[TYllong];
    type* tul = tstypes[TYullong];
    type* ti = tstypes[TYint];

    static type* fn(scope type*[] params, type* ret) { return type_function(TYnfunc, params, false, ret); }

    type* t;
    final switch (op)
    {
    case SR.add, SR.sub, SR.mul, SR.div, SR.mod, SR.yl2x, SR.yl2xp1:
        t = fn([tr, tr], tr);
        break;
    case SR.neg, SR.abs, SR.sqrt, SR.sin, SR.cos, SR.rint:
        t = fn([tr], tr);
        break;
    case SR.rndtol, SR.toI64:
        t = fn([tr], tl);
        break;
    case SR.toU64:
        t = fn([tr], tul);
        break;
    case SR.scale:
        t = fn([tr, ti], tr);
        break;
    case SR.cmp:
        t = fn([tr, tr, ti], ti);
        break;
    case SR.toI32, SR.toU32:
        t = fn([tr], ti);
        break;
    case SR.fromF64:
        t = fn([td], tr);
        break;
    case SR.toF64:
        t = fn([tr], td);
        break;
    case SR.fromI64:
        t = fn([tl], tr);
        break;
    case SR.fromU64:
        t = fn([tul], tr);
        break;
    }
    Symbol* s = symbol_calloc(softRealNames[op]);
    s.Stype = t;
    s.Ssymnum = SYMIDX.max;
    s.Sclass = SC.extern_;
    s.Sfl = FL.func;
    softRealSyms[op] = s;
    return s;
}
