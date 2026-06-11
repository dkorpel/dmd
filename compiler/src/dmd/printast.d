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

import dmd.common.outbuffer;
import dmd.dsymbol;
import dmd.declaration;
import dmd.func;
import dmd.attrib;
import dmd.init;
import dmd.statement;
import dmd.expression;
import dmd.expressionsem : toInteger;
import dmd.ctfeexpr;
import dmd.tokens;
import dmd.visitor;
import dmd.hdrgen;
import dmd.asttypename : astTypeName;
import dmd.location : Loc;
import dmd.mtype : Type;
import dmd.astenums : TY, TMAX;
import dmd.typesem : nextOf;

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
                buf.writestring(".init:\n");
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
        // Statement kinds without a dedicated tree dump above: show the AST
        // class name plus the regenerated source.
        printIndent(buf, indent);
        // Call hdrgen's free `toChars(const Statement)` explicitly: `s.toChars()`
        // would bind to the virtual `RootObject.toChars` (an `assert(0)` stub) since
        // a member always beats a UFCS free function, crashing on any statement kind
        // without an override (goto, labels, ErrorStatement from error recovery, ...).
        buf.printf("%s `%s`", s.astTypeName().ptr, toChars(s));
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
        buf.printf(" extern(%s)", linkageToString(ld.linkage).ptr);
    }
    else if (ad.dsym == DSYM.pragmaDeclaration)
    {
        auto pd = cast(PragmaDeclaration) cast(void*) ad;
        buf.printf(" pragma(%s)", pd.ident ? pd.ident.toChars() : "");
    }
    else if (auto vd = ad.isVisibilityDeclaration())
    {
        buf.writeByte(' ');
        visibilityToBuffer(buf, vd.visibility);
    }
    else if (auto sd = ad.isStorageClassDeclaration())  // also DeprecatedDeclaration
    {
        buf.writeByte(' ');
        if (!stcToBuffer(buf, sd.stc))
            buf.writestring("(no STC)");
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
        if (e.type)
            buf.printf("%s type: %s", e.astTypeName().ptr, typeName(e.type));
        else
            buf.printf("%s", e.astTypeName().ptr);
        emitLineMarker(*buf, e.loc);
        buf.writeByte('\n');
    }

    // Compact one-line form for leaf literals: "<ClassName> <value> [type: <TypeClass>]".
    void leaf(Expression e, const(char)* value)
    {
        printIndent(indent);
        if (e.type)
            buf.printf("%s %s type: %s", e.astTypeName().ptr, value, typeName(e.type));
        else
            buf.printf("%s %s", e.astTypeName().ptr, value);
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
}
