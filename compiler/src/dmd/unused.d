/**
 * Emit warnings for unused declarations (enums, variables, functions).
 *
 * Run after semantic analysis is complete: by then every reference to a symbol
 * has gone through name resolution, which sets `Dsymbol.used`. Any candidate
 * declaration that is still unmarked is reported, unless it falls under one of
 * the exceptions (exported symbols, generic/documentation symbols, parameters).
 *
 * Copyright:   Copyright (C) 1999-2026 by The D Language Foundation, All Rights Reserved
 * License:     $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/compiler/src/dmd/unused.d, _unused.d)
 */
module dmd.unused;

import dmd.astenums;
import dmd.attrib;
import dmd.declaration;
import dmd.denum;
import dmd.dmodule;
import dmd.dsymbol;
import dmd.dsymbolsem : include;
import dmd.errors;
import dmd.func;
import dmd.funcsem : isVirtual;
import dmd.globals;
import dmd.identifier;
import dmd.typesem : toBasetype;
import dmd.visitor.foreachvar : foreachExpAndVar, foreachVar;

/****************************************
 * Scan a root module for unused declarations and warn about each one.
 * Params:
 *      m = module being compiled
 */
void checkUnused(Module m)
{
    if (!global.params.v.unused)
        return;
    if (!m.members)
        return;

    // These are warnings, but `-transition=unused` should surface them on its
    // own without also requiring `-w`/`-wi`. Temporarily enable warning display
    // if it is off; leave `-w` (warnings-as-errors) untouched.
    const save = global.errorSink.useWarnings;
    if (save == DiagnosticReporting.off)
        global.errorSink.useWarnings = DiagnosticReporting.inform;
    scope(exit) global.errorSink.useWarnings = save;

    foreach (s; *m.members)
        scanMember(s);
}

/****************************************
 * Recursively walk a declaration, warning about unused enums, variables and
 * functions and descending into the scopes that may contain more of them.
 */
private void scanMember(Dsymbol s)
{
    if (!s)
        return;

    // Generic / documentation symbols: never instantiated as written, so a
    // reference would never be recorded. Don't descend into them.
    if (s.isTemplateDeclaration() || s.isTemplateInstance() || s.isUnitTestDeclaration())
        return;

    // mixin templates and `mixin("...")` declarations: treat like templates
    if (s.isMixinDeclaration())
        return;

    if (auto ad = s.isAttribDeclaration())
    {
        // Descend through `private:`, `extern(C){}`, `static if`, `align` etc.
        if (auto d = ad.include(null))
            foreach (x; *d)
                scanMember(x);
        return;
    }

    if (auto ed = s.isEnumDeclaration())
    {
        warnIfUnused(ed);
        return;     // individual EnumMembers are too noisy to flag
    }

    if (auto fd = s.isFuncDeclaration())
    {
        warnIfUnused(fd);
        scanFuncBody(fd);
        return;
    }

    if (auto vd = s.isVarDeclaration())
    {
        warnIfUnused(vd);
        return;
    }

    if (auto agg = s.isAggregateDeclaration())
    {
        // Don't flag the aggregate itself, but look for unused members inside it.
        if (agg.members)
            foreach (x; *agg.members)
                scanMember(x);
        return;
    }
}

/****************************************
 * Walk a function body for unused local variables.
 */
private void scanFuncBody(FuncDeclaration fd)
{
    if (!fd.fbody)
        return;
    // Locals declared in statements arrive as DeclarationExps; foreachVar digs
    // them out of each expression, while foreachExpAndVar handles catch/with vars.
    foreachExpAndVar(fd.fbody,
        (e) { e.foreachVar((v) { warnIfUnused(v); }); },
        (v) { warnIfUnused(v); });
}

/****************************************
 * Report `s` as unused unless it is excepted.
 */
private void warnIfUnused(Dsymbol s)
{
    if (s.used || s.errors)
        return;
    if (isExcepted(s))
        return;
    warning(s.loc, "unused %s `%s`", s.kind(), s.toPrettyChars());
}

/****************************************
 * Determine whether an unused declaration should be left alone.
 */
private bool isExcepted(Dsymbol s)
{
    Identifier id = s.ident;
    if (!id)
        return true;

    const name = id.toString();

    // Compiler-generated symbols (e.g. `__result`, `__ctor`, `__lambda`).
    if (name.length >= 2 && name[0] == '_' && name[1] == '_')
        return true;

    if (auto fd = s.isFuncDeclaration())
    {
        // Special functions are part of the type's contract, not called by name.
        if (fd.isCtorDeclaration() || fd.isPostBlitDeclaration() ||
            fd.isDtorDeclaration() || fd.isInvariantDeclaration() ||
            fd.isStaticCtorDeclaration() || fd.isStaticDtorDeclaration() ||
            fd.isFuncLiteralDeclaration() || fd.isMain() || fd.isCMain())
            return true;
        // Virtual methods may be reached polymorphically through a base class.
        if (fd.isVirtual())
            return true;
        // Compiler-generated functions (e.g. `opAssign`, `opCmp`).
        if (fd.isGenerated)
            return true;
    }

    if (auto vd = s.isVarDeclaration())
    {
        // foreach loop variables (e.g. `i` in `foreach (i; 0 .. 2)`) and
        // compiler-generated temporaries are not meaningful to flag.
        if (vd.storage_class & (STC.foreach_ | STC.temp))
            return true;

        // Parameters: the function may need to honor a specific API.
        if (vd.isParameter() || vd.isResult())
            return true;

        // Manifest constants (`enum x = 5;`) behave like C `#define`s and are
        // commonly declared in named groups, e.g. translated C headers where
        // not every value is referenced (ELF relocations, config flags, ...).
        if (vd.storage_class & STC.manifest)
            return true;

        // RAII scope guards: a struct local whose type has a destructor is
        // declared for the destructor's side effect, not to be referenced.
        if (auto t = vd.type)
            if (auto ts = t.toBasetype().isTypeStruct())
                if (ts.sym.dtor)
                    return true;
    }

    // Symbols meant for export: `export`, `extern(C)`, `pragma(mangle)`.
    if (auto d = s.isDeclaration())
    {
        if (d.visibility.kind == Visibility.Kind.export_)
            return true;
        if (d.resolvedLinkage() != LINK.d)
            return true;
        if (d.mangleOverride.length)
            return true;
    }
    else if (s.visible().kind == Visibility.Kind.export_)
        return true;

    return false;
}
