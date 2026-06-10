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
import dmd.statement;
import dmd.expression;
import dmd.expressionsem : toInteger;
import dmd.ctfeexpr;
import dmd.tokens;
import dmd.visitor;
import dmd.hdrgen;

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
    buf.printf("%s `%s`\n", s.kind(), s.toChars());

    if (auto ad = s.isAttribDeclaration())
    {
        if (ad.decl)
            foreach (m; (*ad.decl)[])
                printAST(m, buf, indent + 2);
    }
    else if (auto fd = s.isFuncDeclaration())
    {
        if (fd.fbody)
            printAST(fd.fbody, buf, indent + 2);
    }
    else if (auto vd = s.isVarDeclaration())
    {
        if (vd._init)
        {
            printIndent(buf, indent + 2);
            buf.printf(".init: %s\n", vd._init.toChars());
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

    void head(string name)
    {
        printIndent(buf, indent);
        buf.writestring(name);
        buf.writeByte('\n');
    }

    if (auto cs = s.isCompoundStatement())
    {
        head("Compound");
        if (cs.statements)
            foreach (st; (*cs.statements)[])
                printAST(st, buf, indent + 2);
    }
    else if (auto es = s.isExpStatement())
    {
        head("Exp");
        printAST(es.exp, buf, indent + 2);
    }
    else if (auto rs = s.isReturnStatement())
    {
        head("Return");
        printAST(rs.exp, buf, indent + 2);
    }
    else if (auto ifs = s.isIfStatement())
    {
        head("If");
        printAST(ifs.condition, buf, indent + 2);
        printAST(ifs.ifbody, buf, indent + 2);
        printAST(ifs.elsebody, buf, indent + 2);
    }
    else if (auto scs = s.isScopeStatement())
    {
        head("Scope");
        printAST(scs.statement, buf, indent + 2);
    }
    else if (auto ws = s.isWhileStatement())
    {
        head("While");
        printAST(ws.condition, buf, indent + 2);
        printAST(ws._body, buf, indent + 2);
    }
    else if (auto ds = s.isDoStatement())
    {
        head("Do");
        printAST(ds._body, buf, indent + 2);
        printAST(ds.condition, buf, indent + 2);
    }
    else if (auto fs = s.isForStatement())
    {
        head("For");
        printAST(fs._init, buf, indent + 2);
        printAST(fs.condition, buf, indent + 2);
        printAST(fs.increment, buf, indent + 2);
        printAST(fs._body, buf, indent + 2);
    }
    else if (auto fe = s.isForeachStatement())
    {
        head("Foreach");
        printAST(fe.aggr, buf, indent + 2);
        printAST(fe._body, buf, indent + 2);
    }
    else if (auto fr = s.isForeachRangeStatement())
    {
        head("ForeachRange");
        printAST(fr.lwr, buf, indent + 2);
        printAST(fr.upr, buf, indent + 2);
        printAST(fr._body, buf, indent + 2);
    }
    else if (auto sw = s.isSwitchStatement())
    {
        head("Switch");
        printAST(sw.condition, buf, indent + 2);
        printAST(sw._body, buf, indent + 2);
    }
    else if (auto cas = s.isCaseStatement())
    {
        head("Case");
        printAST(cas.exp, buf, indent + 2);
        printAST(cas.statement, buf, indent + 2);
    }
    else if (auto def = s.isDefaultStatement())
    {
        head("Default");
        printAST(def.statement, buf, indent + 2);
    }
    else
    {
        // Fall back to the regenerated source for statement kinds without a
        // dedicated tree dump above.
        printIndent(buf, indent);
        buf.printf("Statement `%s`\n", s.toChars());
    }
}

private void printIndent(ref OutBuffer buf, int indent)
{
    foreach (i; 0 .. indent)
        buf.writeByte(' ');
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

    override void visit(Expression e)
    {
        printIndent(indent);
        auto s = EXPtoString(e.op);
        buf.printf("%.*s %s\n", cast(int)s.length, s.ptr, e.type ? e.type.toChars() : "");
    }

    override void visit(IdentifierExp e)
    {
        printIndent(indent);
        buf.printf("Identifier `%s` %s\n", e.ident.toChars(), e.type ? e.type.toChars() : "");
    }

    override void visit(IntegerExp e)
    {
        printIndent(indent);
        buf.printf("Integer %lld %s\n", e.toInteger(), e.type ? e.type.toChars() : "");
    }

    override void visit(RealExp e)
    {
        printIndent(indent);

        import dmd.hdrgen : floatToBuffer;
        OutBuffer floatBuf;
        floatToBuffer(e.type, e.value, floatBuf, false);
        buf.printf("Real %s %s\n", floatBuf.peekChars(), e.type ? e.type.toChars() : "");
    }

    override void visit(StructLiteralExp e)
    {
        printIndent(indent);
        auto s = EXPtoString(e.op);
        buf.printf("%.*s %s, %s\n", cast(int)s.length, s.ptr, e.type ? e.type.toChars() : "", e.toChars());
    }

    override void visit(SymbolExp e)
    {
        printIndent(indent);
        buf.printf("Symbol %s\n", e.type ? e.type.toChars() : "");
        printIndent(indent + 2);
        buf.printf(".var: %s\n", e.var ? e.var.toChars() : "");
    }

    override void visit(SymOffExp e)
    {
        printIndent(indent);
        buf.printf("SymOff %s\n", e.type ? e.type.toChars() : "");
        printIndent(indent + 2);
        buf.printf(".var: %s\n", e.var ? e.var.toChars() : "");
        printIndent(indent + 2);
        buf.printf(".offset: %llx\n", e.offset);
    }

    override void visit(VarExp e)
    {
        printIndent(indent);
        buf.printf("Var %s\n", e.type ? e.type.toChars() : "");
        printIndent(indent + 2);
        buf.printf(".var: %s\n", e.var ? e.var.toChars() : "");
    }

    override void visit(DsymbolExp e)
    {
        visit(cast(Expression)e);
        printIndent(indent + 2);
        buf.printf(".s: %s\n", e.s ? e.s.toChars() : "");
    }

    override void visit(DotIdExp e)
    {
        printIndent(indent);
        buf.printf("DotId %s\n", e.type ? e.type.toChars() : "");
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
        printIndent(indent);
        auto s = EXPtoString(e.op);
        buf.printf("%.*s %s\n", cast(int)s.length, s.ptr, e.type ? e.type.toChars() : "");
        printIndent(indent + 2);
        buf.printf(".to: %s\n", e.to.toChars());
        .printAST(e.e1, *buf, indent + 2);
    }

    override void visit(VectorExp e)
    {
        printIndent(indent);
        buf.printf("Vector %s\n", e.type ? e.type.toChars() : "");
        printIndent(indent + 2);
        buf.printf(".to: %s\n", e.to.toChars());
        .printAST(e.e1, *buf, indent + 2);
    }

    override void visit(VectorArrayExp e)
    {
        printIndent(indent);
        buf.printf("VectorArray %s\n", e.type ? e.type.toChars() : "");
        .printAST(e.e1, *buf, indent + 2);
    }

    override void visit(DotVarExp e)
    {
        printIndent(indent);
        buf.printf("DotVar %s\n", e.type ? e.type.toChars() : "");
        printIndent(indent + 2);
        buf.printf(".var: %s\n", e.var.toChars());
        .printAST(e.e1, *buf, indent + 2);
    }

    override void visit(BinExp e)
    {
        visit(cast(Expression)e);
        .printAST(e.e1, *buf, indent + 2);
        .printAST(e.e2, *buf, indent + 2);
    }

    override void visit(AssignExp e)
    {
        printIndent(indent);
        buf.printf("Assign %s\n", e.type ? e.type.toChars() : "");
        .printAST(e.e1, *buf, indent + 2);
        .printAST(e.e2, *buf, indent + 2);
    }

    override void visit(ConstructExp e)
    {
        printIndent(indent);
        buf.printf("Construct %s\n", e.type ? e.type.toChars() : "");
        .printAST(e.e1, *buf, indent + 2);
        .printAST(e.e2, *buf, indent + 2);
    }

    override void visit(BlitExp e)
    {
        printIndent(indent);
        buf.printf("Blit %s\n", e.type ? e.type.toChars() : "");
        .printAST(e.e1, *buf, indent + 2);
        .printAST(e.e2, *buf, indent + 2);
    }

    override void visit(IndexExp e)
    {
        printIndent(indent);
        buf.printf("Index %s\n", e.type ? e.type.toChars() : "");
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
