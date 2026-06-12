/**
 * Provides an AST printer for debugging.
 *
 * Copyright:   Copyright (C) 1999-2026 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 https://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/compiler/src/dmd/printast.d, _printast.d)
 * Documentation:  https://dlang.org/phobos/dmd_printast.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/compiler/src/dmd/printast.d
 */

module dmd.printast;

import core.stdc.stdio;

import dmd.astenums : TY, TMAX, STC, LINK;
import dmd.asttypename : astTypeName;
import dmd.attrib;
import dmd.common.outbuffer;
import dmd.ctfeexpr;
import dmd.declaration;
import dmd.dsymbol;
import dmd.dtemplate : TemplateInstance;
import dmd.expression;
import dmd.expressionsem : toInteger;
import dmd.func;
import dmd.init;
import dmd.location : Loc;
import dmd.mtype : Type;
import dmd.root.string: fTuple;
import dmd.rootobject : RootObject;
import dmd.statement;
import dmd.tokens;
import dmd.typesem : nextOf;
import dmd.visitor;

/********************
 * When set, `printAST` appends a source-line marker to the end of each node's
 * primary line: a SOH byte (0x01) followed by the decimal source line number.
 * Off by default so normal compiler output is unaffected; the wasm explorer
 * turns it on to map each printed AST line back to the source line that
 * produced it. A marker of `0` explicitly means "no source line".
 */
__gshared bool printASTLineMarkers = false;

/// Append the SOH line marker for `loc` to `buf` when `printASTLineMarkers` is on.
private void emitLineMarker(ref OutBuffer buf, Loc loc)
{
    if (printASTLineMarkers)
        buf.printf("\x01%u", loc.linnum);
}

/********************
 * Print expression AST data structure to stdout in a nice format.
 * Params:
 *  e = expression AST to print
 *  indent = indentation level
 */
void printAST(Expression e, int indent = 0)
{
    OutBuffer buf;
    printAST(e, buf, indent);
    printf("%.*s", cast(int) buf.length, buf.peekChars());
}

/********************
 * Print expression AST data structure into `buf` in a nice format.
 * Params:
 *  e = expression AST to print
 *  buf = sink the formatted tree is written to
 *  indent = indentation level
 */
void printAST(Expression e, ref OutBuffer buf, int indent = 0)
{
    if (!e)
        return;
    scope PrintASTVisitor pav = new PrintASTVisitor(&buf, indent);
    e.accept(pav);
}

/********************
 * Print the AST of a whole symbol (e.g. a `Module`) into `buf`, recursing
 * through declarations, statements and expressions. Intended for showing the
 * tree the parser produced (run before semantic for that view).
 * Params:
 *  s = symbol AST to print
 *  buf = sink the formatted tree is written to
 *  indent = indentation level
 */
void printAST(Dsymbol s, ref OutBuffer buf, int indent = 0)
{
    if (!s)
        return;
    printIndent(buf, indent);
    buf.writestring(s.astTypeName());

    if (auto ad = s.isAttribDeclaration())
    {
        printAttribDetail(ad, buf);
        emitLineMarker(buf, s.loc);
        buf.writeByte('\n');
        // UserAttributeDeclaration has no dedicated `is*` downcast; its `atts`
        // hold the `@(...)` argument expressions (which keep any `!(…)` template
        // arguments). Recurse into them with printAST rather than flattening to
        // toChars, so the full sub-tree of each UDA shows up.
        if (ad.dsym == DSYM.userAttributeDeclaration)
        {
            auto uad = cast(UserAttributeDeclaration) cast(void*) ad;
            if (uad.atts)
                foreach (att; (*uad.atts)[])
                    printAST(att, buf, indent + 2);
        }
        if (ad.decl)
            foreach (m; (*ad.decl)[])
                printAST(m, buf, indent + 2);
        return;
    }

    buf.printf(" `%s`", s.toChars());
    if (auto dec = s.isDeclaration())   // VarDeclaration, FuncDeclaration, ...
        if (dec.type)
            buf.printf(" type: %s", typeName(dec.type));
    emitLineMarker(buf, s.loc);
    buf.writeByte('\n');

    if (auto fd = s.isFuncDeclaration())
    {
        if (fd.fbody)
            printAST(fd.fbody, buf, indent + 2);
    }
    else if (auto vd = s.isVarDeclaration())
    {
        if (vd._init)
        {
            if (auto ei = vd._init.isExpInitializer())
            {
                printIndent(buf, indent + 2);
                buf.writestring("exp:\n");
                printAST(ei.exp, buf, indent + 4);
            }
        }
    }
    else if (auto sds = s.isScopeDsymbol())     // Module, aggregates, enums, templates
    {
        if (sds.members)
            foreach (m; (*sds.members)[])
                printAST(m, buf, indent + 2);
    }
}

/********************
 * Print a statement AST into `buf`, recursing into nested statements and
 * expressions.
 * Params:
 *  s = statement AST to print
 *  buf = sink the formatted tree is written to
 *  indent = indentation level
 */
void printAST(Statement s, ref OutBuffer buf, int indent = 0)
{
    if (!s)
        return;

    void head()
    {
        printIndent(buf, indent);
        buf.writestring(s.astTypeName());
        emitLineMarker(buf, s.loc);
        buf.writeByte('\n');
    }

    if (auto cs = s.isCompoundStatement())
    {
        head();
        if (cs.statements)
            foreach (st; (*cs.statements)[])
                printAST(st, buf, indent + 2);
    }
    else if (auto es = s.isExpStatement())
    {
        head();
        printAST(es.exp, buf, indent + 2);
    }
    else if (auto rs = s.isReturnStatement())
    {
        head();
        printAST(rs.exp, buf, indent + 2);
    }
    else if (auto ifs = s.isIfStatement())
    {
        head();
        printAST(ifs.condition, buf, indent + 2);
        printAST(ifs.ifbody, buf, indent + 2);
        printAST(ifs.elsebody, buf, indent + 2);
    }
    else if (auto scs = s.isScopeStatement())
    {
        head();
        printAST(scs.statement, buf, indent + 2);
    }
    else if (auto ws = s.isWhileStatement())
    {
        head();
        printAST(ws.condition, buf, indent + 2);
        printAST(ws._body, buf, indent + 2);
    }
    else if (auto ds = s.isDoStatement())
    {
        head();
        printAST(ds._body, buf, indent + 2);
        printAST(ds.condition, buf, indent + 2);
    }
    else if (auto fs = s.isForStatement())
    {
        head();
        printAST(fs._init, buf, indent + 2);
        printAST(fs.condition, buf, indent + 2);
        printAST(fs.increment, buf, indent + 2);
        printAST(fs._body, buf, indent + 2);
    }
    else if (auto fe = s.isForeachStatement())
    {
        head();
        printAST(fe.aggr, buf, indent + 2);
        printAST(fe._body, buf, indent + 2);
    }
    else if (auto fr = s.isForeachRangeStatement())
    {
        head();
        printAST(fr.lwr, buf, indent + 2);
        printAST(fr.upr, buf, indent + 2);
        printAST(fr._body, buf, indent + 2);
    }
    else if (auto sw = s.isSwitchStatement())
    {
        head();
        printAST(sw.condition, buf, indent + 2);
        printAST(sw._body, buf, indent + 2);
    }
    else if (auto cas = s.isCaseStatement())
    {
        head();
        printAST(cas.exp, buf, indent + 2);
        printAST(cas.statement, buf, indent + 2);
    }
    else if (auto def = s.isDefaultStatement())
    {
        head();
        printAST(def.statement, buf, indent + 2);
    }
    else
    {
        // Statement kinds without a dedicated tree dump above: show just the AST
        // class name. Avoid hdrgen's `toChars` so this stays self-contained; the
        // bare class name is enough to identify the node in the tree.
        printIndent(buf, indent);
        buf.printf("%s", s.astTypeName().ptr);
        emitLineMarker(buf, s.loc);
        buf.writeByte('\n');
    }
}

private void printIndent(ref OutBuffer buf, int indent)
{
    foreach (i; 0 .. indent)
        buf.writeByte(' ');
}

/********************
 * Print one template argument (an element of a `TemplateInstance.tiargs`).
 * Prefers the recursive `printAST` overloads for expression and symbol
 * arguments; type arguments have no AST printer, so fall back to the same
 * `typeName` class-name rendering used elsewhere. Tuples are expanded.
 */
private void printTemplateArg(RootObject o, ref OutBuffer buf, int indent)
{
    import dmd.dtemplate : isExpression, isDsymbol, isType, isTuple;
    if (auto e = isExpression(o))
        printAST(e, buf, indent);
    else if (auto s = isDsymbol(o))
        printAST(s, buf, indent);
    else if (auto t = isType(o))
    {
        printIndent(buf, indent);
        buf.printf("%s\n", typeName(t));
    }
    else if (auto tup = isTuple(o))
    {
        foreach (obj; tup.objects[])
            printTemplateArg(obj, buf, indent);
    }
    else
    {
        printIndent(buf, indent);
        buf.writestring("(null arg)\n");
    }
}

/********************
 * Render a type by its AST class name (e.g. `TypeBasic`, `TypeDArray`) rather
 * than as D source syntax, matching how expressions/statements are shown, and
 * recursing into the wrapped types so the full structure is visible.
 * Returns a pointer into a reused scratch buffer, valid only until the next
 * call — use it immediately (as `head`/`leaf` do, in a single `printf`).
 */
private const(char)* typeName(Type t)
{
    static __gshared OutBuffer scratch;
    scratch.setsize(0);
    typeToBuffer(scratch, t);
    return scratch.peekChars();
}

/// Append `t` to `buf` as `TypeClass(<wrapped...>)`, recursing into element,
/// key, return and parameter types. Leaf/named types append their source name.
private void typeToBuffer(ref OutBuffer buf, Type t)
{
    if (!t)
    {
        buf.writestring("null");
        return;
    }
    buf.writestring(astTypeName(t));
    if (auto tf = t.isTypeFunction())
    {
        buf.writeByte('(');
        typeToBuffer(buf, tf.next);             // return type
        buf.writestring(" function(");
        foreach (i, p; tf.parameterList)
        {
            if (i)
                buf.writestring(", ");
            typeToBuffer(buf, p.type);
        }
        buf.writestring("))");
    }
    else if (auto tsa = t.isTypeSArray())
    {
        buf.writeByte('(');
        typeToBuffer(buf, tsa.next);            // element type
        buf.printf("[%s])", tsa.dim ? tsa.dim.toChars() : "?");
    }
    else if (auto taa = t.isTypeAArray())
    {
        buf.writeByte('(');
        typeToBuffer(buf, taa.next);            // value type
        buf.writeByte('[');
        typeToBuffer(buf, taa.index);           // key type
        buf.writestring("])");
    }
    else if (auto n = t.nextOf())               // pointer, ref, slice, dynamic array, delegate
    {
        // `nextOf` uses checked `ty`-based downcasts; a plain `cast(TypeNext)`
        // would not, since extern(C++) classes have no D RTTI and the cast just
        // reinterprets the pointer, reading garbage for non-`TypeNext` types.
        buf.writeByte('(');
        typeToBuffer(buf, n);
        buf.writeByte(')');
    }
    else
    {
        // Leaf / named types (TypeBasic, TypeStruct, TypeIdentifier, ...): show the
        // `TY` enum tag (`Tint32`, `Tstruct`, ...) in parens rather than the D
        // keyword, so e.g. `int` vs `long` stays distinguishable by its tag.
        buf.writeByte('(');
        buf.writestring(tyToString(t.ty));
        buf.writeByte(')');
    }
}

/// The `TY` enum member name (e.g. `Tint32`, `Tstruct`) for `ty`, for debug dumps.
private string tyToString(TY ty)
{
    static immutable string[TMAX] names = () {
        string[TMAX] n;
        static foreach (m; __traits(allMembers, TY))
            n[__traits(getMember, TY, m)] = m;
        return n;
    }();
    return names[ty];
}

/********************
 * Append the distinguishing fields of an `AttribDeclaration` to `buf`, e.g. the
 * linkage of a `LinkDeclaration` or the storage classes of a
 * `StorageClassDeclaration`, so the dump shows more than the bare class name.
 */
private void printAttribDetail(AttribDeclaration ad, ref OutBuffer buf)
{
    // LinkDeclaration / PragmaDeclaration have no dedicated `is*` downcast, so
    // dispatch on the DSYM tag (the same trick the `is*` helpers use).
    if (ad.dsym == DSYM.linkDeclaration)
    {
        auto ld = cast(LinkDeclaration) cast(void*) ad;
        buf.printf(" extern(%.*s)", enumName(ld.linkage).fTuple.expand);
    }
    else if (ad.dsym == DSYM.pragmaDeclaration)
    {
        auto pd = cast(PragmaDeclaration) cast(void*) ad;
        buf.printf(" pragma(%s)", pd.ident ? pd.ident.toChars() : "");
    }
    else if (auto vd = ad.isVisibilityDeclaration())
    {
        buf.put(" ");
        buf.put(enumName(vd.visibility.kind));
    }
    else if (auto sd = ad.isStorageClassDeclaration())  // also DeprecatedDeclaration
    {
        if (!stcNames(buf, sd.stc))
            buf.writestring(" (no STC)");
    }
    else if (auto al = ad.isAlignDeclaration())
    {
        if (al.exps && al.exps.length)
            buf.printf(" align(%s)", (*al.exps)[0].toChars());
        else
            buf.writestring(" align");
    }
    else if (auto an = ad.isAnonDeclaration())
    {
        buf.writestring(an.isunion ? " union" : " struct");
    }
    else if (ad.ident)
    {
        buf.printf(" `%s`", ad.ident.toChars());
    }
}

/********************
 * Render an enum value as its internal member name (e.g. `LINK.cpp` -> "cpp"),
 * stripping a single trailing underscore added to dodge keywords (`default_`).
 * Avoids hdrgen's pretty-printers so this module stays self-contained. Only
 * valid for enums whose members have distinct values (LINK, Visibility.Kind).
 */
private string enumName(E)(E value) if (is(E == enum))
{
    final switch (value)
    {
        static foreach (m; __traits(allMembers, E))
        {
            case __traits(getMember, E, m):
                return m;
        }
    }
}

/********************
 * Append each set storage-class flag of `stc` to `buf` by its internal member
 * name (` static`, ` const`, ...). Composite STC aliases (multi-bit) are skipped
 * so only the individual flags show. Returns false if no flag was set.
 */
private bool stcNames(ref OutBuffer buf, ulong stc)
{
    bool any;
    static foreach (m; __traits(allMembers, STC))
    {{
        enum ulong v = __traits(getMember, STC, m);
        static if (v != 0 && (v & (v - 1)) == 0) // single-bit flag only
        {
            if (stc & v)
            {
                buf.put(m);
                buf.put(" | ");
                any = true;
            }
        }
    }}
    return any;
}

private:

extern (C++) final class PrintASTVisitor : Visitor
{
    alias visit = Visitor.visit;

    OutBuffer* buf;
    int indent;

    extern (D) this(OutBuffer* buf, int indent) scope @safe
    {
        this.buf = buf;
        this.indent = indent;
    }

    void printIndent(int indent)
    {
        .printIndent(*buf, indent);
    }

    // Print "<ClassName> [type: <TypeClass>]" for `e` at the current indent (the
    // `type:` part is omitted when the node has no type yet, e.g. pre-semantic).
    void head(Expression e)
    {
        printIndent(indent);
        buf.put(e.astTypeName());
        if (e.type)
            buf.printf(" : %s", typeName(e.type));

        emitLineMarker(*buf, e.loc);
        buf.writeByte('\n');
    }

    // Compact one-line form for leaf literals: "<ClassName> <value> [type: <TypeClass>]".
    void leaf(Expression e, const(char)* value)
    {
        printIndent(indent);
        buf.put(e.astTypeName());
        buf.printf("(%s)", value);
        if (e.type)
            buf.printf(": %s", typeName(e.type));

        emitLineMarker(*buf, e.loc);
        buf.writeByte('\n');
    }

    override void visit(Expression e)
    {
        head(e);
    }

    override void visit(IdentifierExp e)
    {
        leaf(e, e.ident.toChars());
    }

    override void visit(IntegerExp e)
    {
        OutBuffer v;
        v.printf("%lld", e.toInteger());
        leaf(e, v.peekChars());
    }

    override void visit(RealExp e)
    {
        import dmd.hdrgen : floatToBuffer;
        OutBuffer v;
        floatToBuffer(e.type, e.value, v, false);
        leaf(e, v.peekChars());
    }

    override void visit(StructLiteralExp e)
    {
        head(e);
        printIndent(indent + 2);
        buf.printf(".value: %s\n", e.toChars());
    }

    override void visit(SymbolExp e)
    {
        head(e);
        printIndent(indent + 2);
        buf.printf(".var: %s\n", e.var ? e.var.toChars() : "");
    }

    override void visit(SymOffExp e)
    {
        head(e);
        printIndent(indent + 2);
        buf.printf(".var: %s\n", e.var ? e.var.toChars() : "");
        printIndent(indent + 2);
        buf.printf(".offset: %llx\n", e.offset);
    }

    override void visit(VarExp e)
    {
        leaf(e, e.var ? e.var.toChars() : "");
    }

    override void visit(DsymbolExp e)
    {
        visit(cast(Expression)e);
        printIndent(indent + 2);
        buf.printf(".s: %s\n", e.s ? e.s.toChars() : "");
    }

    override void visit(DotIdExp e)
    {
        head(e);
        printIndent(indent + 2);
        buf.printf(".ident: %s\n", e.ident.toChars());
        .printAST(e.e1, *buf, indent + 2);
    }

    override void visit(UnaExp e)
    {
        visit(cast(Expression)e);
        .printAST(e.e1, *buf, indent + 2);
    }

    override void visit(CastExp e)
    {
        head(e);
        printIndent(indent + 2);
        // `e.to` is null for modifier-only casts (`cast()`, `cast(const)`, …) until
        // semantic infers the target; don't dereference it in the raw parse tree.
        buf.printf(".to: %s\n", e.to ? typeName(e.to) : "(inferred)");
        .printAST(e.e1, *buf, indent + 2);
    }

    override void visit(VectorExp e)
    {
        head(e);
        printIndent(indent + 2);
        buf.printf(".to: %s\n", typeName(e.to));
        .printAST(e.e1, *buf, indent + 2);
    }

    override void visit(VectorArrayExp e)
    {
        head(e);
        .printAST(e.e1, *buf, indent + 2);
    }

    override void visit(DotVarExp e)
    {
        head(e);
        printIndent(indent + 2);
        buf.printf(".var: %s\n", e.var.toChars());
        .printAST(e.e1, *buf, indent + 2);
    }

    override void visit(BinExp e)
    {
        head(e);
        .printAST(e.e1, *buf, indent + 2);
        .printAST(e.e2, *buf, indent + 2);
    }

    override void visit(DelegateExp e)
    {
        visit(cast(Expression)e);
        printIndent(indent + 2);
        buf.printf(".func: %s\n", e.func ? e.func.toChars() : "");
    }

    override void visit(CompoundLiteralExp e)
    {
        visit(cast(Expression)e);
        printIndent(indent + 2);
        buf.printf(".init: %s\n", e.initializer ? e.initializer.toChars() : "");
    }

    override void visit(ClassReferenceExp e)
    {
        visit(cast(Expression)e);
        printIndent(indent + 2);
        buf.printf(".value: %s\n", e.value ? e.value.toChars() : "");
        .printAST(e.value, *buf, indent + 2);
    }

    override void visit(ArrayLiteralExp e)
    {
        visit(cast(Expression)e);
        printIndent(indent + 2);
        buf.printf(".basis : %s\n", e.basis ? e.basis.toChars() : "");
        if (e.elements)
        {
            printIndent(indent + 2);
            buf.writeByte('[');
            foreach (i, element; (*e.elements)[])
            {
                if (i)
                    buf.writestring(", ");
                buf.printf("%s", element.toChars());
            }
            buf.writestring("]\n");
        }
    }

    override void visit(ScopeExp e)
    {
        head(e);
        if (auto ti = e.sds ? e.sds.isTemplateInstance() : null)
        {
            // Show the instance name and recurse into each template argument
            // (`Foo!(int, 3)`), which the bare `ScopeExp` head line omits.
            printIndent(indent + 2);
            buf.printf(".ti: %s\n", ti.name ? ti.name.toChars() : "");
            if (ti.tiargs)
                foreach (arg; (*ti.tiargs)[])
                    printTemplateArg(arg, *buf, indent + 4);
        }
        else if (e.sds)
            .printAST(cast(Dsymbol) e.sds, *buf, indent + 2);
    }

    override void visit(DeclarationExp e)
    {
        head(e);
        // Recurse into the wrapped declaration so e.g. a local `VarDeclaration`
        // and its `.init:` initializer show up under the expression.
        .printAST(e.declaration, *buf, indent + 2);
    }
}
