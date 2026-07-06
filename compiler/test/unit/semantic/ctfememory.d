// See ../README.md for information about DMD unit tests.

// Round-trip tests for the CTFE linear memory representation:
// AST literal -> linear memory bytes -> AST literal.
module semantic.ctfememory;

import support : afterEach, beforeEach, defaultImportPaths;

@beforeEach initializeFrontend()
{
    import dmd.frontend : initDMD;
    initDMD();
}

@afterEach deinitializeFrontend()
{
    import dmd.frontend : deinitializeDMD;
    deinitializeDMD();
}

@("scalar round trip")
unittest
{
    import dmd.ctfememory;
    import dmd.expression : IntegerExp, RealExp;
    import dmd.location : Loc;
    import dmd.mtype : Type;

    CtfeMemory mem;
    scope (exit) mem.destroy();

    // signed value: bytes are truncated on encode, sign restored on decode
    auto ie = IntegerExp.create(Loc.initial, -42, Type.tint16);
    auto p = encode(mem, ie, Type.tint16, ArenaKind.stack);
    assert(!p.isNull);
    auto back = decode(mem, p, Type.tint16, Loc.initial);
    assert(back !is null);
    assert(back.isIntegerExp().getInteger() == -42);

    auto re = RealExp.create(Loc.initial, 2.75, Type.tfloat64);
    p = encode(mem, re, Type.tfloat64, ArenaKind.heap);
    assert(!p.isNull);
    back = decode(mem, p, Type.tfloat64, Loc.initial);
    assert(back !is null);
    assert(back.isRealExp().value == 2.75);
}

@("union reinterpretation of POD bytes")
unittest
{
    import dmd.ctfememory;
    import dmd.expression : IntegerExp;
    import dmd.location : Loc;
    import dmd.mtype : Type;

    CtfeMemory mem;
    scope (exit) mem.destroy();

    // store a float's bytes, reread them as a uint: allowed in linear
    // memory (little endian), which the AST representation forbids
    auto id = mem.allocate(ArenaKind.stack, 4);
    assert(mem.write(CtfePtr(id, 0), 1.0f));
    auto back = decode(mem, CtfePtr(id, 0), Type.tuns32, Loc.initial);
    assert(back !is null);
    assert(back.isIntegerExp().getInteger() == 0x3F80_0000); // bits of 1.0f
}

@("struct and static array round trip")
unittest
{
    import std.algorithm : each;

    import dmd.ctfememory;
    import dmd.declaration : VarDeclaration;
    import dmd.dsymbol : Dsymbol;
    import dmd.expression : ArrayLiteralExp, Expression, IntegerExp,
        StructLiteralExp, StringExp;
    import dmd.frontend : addImport, fullSemantic, parseModule;
    import dmd.initsem : initializerToExpression;
    import dmd.location : Loc;

    defaultImportPaths.each!addImport;

    auto t = parseModule("test.d", q{
        struct Pair { int i; double d; char[4] tag; }
        enum Pair p = Pair(-7, 1.5, "hey!");
        enum int[3] a = [10, 20, 30];
    });
    assert(!t.diagnostics.hasErrors);
    t.module_.fullSemantic();

    Expression initializerOf(const(char)[] name)
    {
        foreach (member; *t.module_.members)
        {
            auto vd = member.isVarDeclaration();
            if (vd && vd.ident && vd.ident.toString() == name)
                return vd._init.initializerToExpression();
        }
        return null;
    }

    CtfeMemory mem;
    scope (exit) mem.destroy();

    auto sle = initializerOf("p");
    assert(sle !is null && sle.isStructLiteralExp());
    auto p = encode(mem, sle, sle.type, ArenaKind.heap);
    assert(!p.isNull);
    auto back = decode(mem, p, sle.type, Loc.initial);
    assert(back !is null);
    auto bsle = back.isStructLiteralExp();
    assert(bsle !is null);
    assert((*bsle.elements)[0].isIntegerExp().getInteger() == -7);
    assert((*bsle.elements)[1].isRealExp().value == 1.5);
    assert((*bsle.elements)[2].isStringExp().peekString() == "hey!");

    auto ale = initializerOf("a");
    assert(ale !is null && ale.isArrayLiteralExp());
    p = encode(mem, ale, ale.type, ArenaKind.heap);
    assert(!p.isNull);
    back = decode(mem, p, ale.type, Loc.initial);
    assert(back !is null);
    auto bale = back.isArrayLiteralExp();
    assert(bale !is null);
    assert((*bale.elements)[2].isIntegerExp().getInteger() == 30);
}
