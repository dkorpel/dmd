/**
 * Contains semantic routines specific to ImportC
 *
 * Specification: C11
 *
 * Copyright:   Copyright (C) 2021-2026 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 https://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/compiler/src/dmd/importc.d, _importc.d)
 * Documentation:  https://dlang.org/phobos/dmd_importc.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/compiler/src/dmd/importc.d
 */

module dmd.importc;

import core.stdc.stdio;

import dmd.arraytypes;
import dmd.astenums;
import dmd.dcast;
import dmd.denum;
import dmd.declaration;
import dmd.dscope;
import dmd.dstruct;
import dmd.dsymbol;
import dmd.dsymbolsem;
import dmd.dinterpret : ctfeInterpret;
import dmd.errorsink;
import dmd.expression;
import dmd.expressionsem;
import dmd.globals : global;
import dmd.hdrgen : toChars, toErrMsg;
import dmd.identifier;
import dmd.id : Id;
import dmd.init;
import dmd.initsem;
import dmd.intrange : IntRange;
import dmd.location;
import dmd.mtype;
import dmd.optimize : optimize;
import dmd.rootobject : DYNCAST;
import dmd.tokens;
import dmd.typesem;

/**************************************
 * C11 does not allow array or function parameters.
 * Hence, adjust those types per C11 6.7.6.3 rules.
 * Params:
 *      t = parameter type to adjust
 *      sc = context
 * Returns:
 *      adjusted type
 */
Type cAdjustParamType(Type t, Scope* sc)
{
    if (!sc.inCfile)
        return t;

    Type tb = t.toBasetype();

    /* C11 6.7.6.3-7 array of T is converted to pointer to T
     */
    if (auto ta = tb.isTypeDArray())
    {
        t = ta.next.pointerTo();
    }
    else if (auto ts = tb.isTypeSArray())
    {
        t = ts.next.pointerTo();
    }
    /* C11 6.7.6.3-8 function is converted to pointer to function
     */
    else if (tb.isTypeFunction())
    {
        t = tb.pointerTo();
    }
    return t;
}

/***********************************************
 * C11 6.3.2.1-3 Convert expression that is an array of type to a pointer to type.
 * C11 6.3.2.1-4 Convert expression that is a function to a pointer to a function.
 * Params:
 *  e = ImportC expression to possibly convert
 *  sc = context
 * Returns:
 *  converted expression
 */
Expression arrayFuncConv(Expression e, Scope* sc)
{
    //printf("arrayFuncConv() %s\n", e.toChars());
    if (!sc.inCfile)
        return e;

    auto t = e.type.toBasetype();
    if (auto ta = t.isTypeDArray())
    {
        if (!checkAddressable(e, sc, "take address of"))
            return ErrorExp.get();
        e = e.castTo(sc, ta.next.pointerTo());
    }
    else if (auto ts = t.isTypeSArray())
    {
        if (!checkAddressable(e, sc, "take address of"))
            return ErrorExp.get();
        e = e.castTo(sc, ts.next.pointerTo());
    }
    else if (t.isTypeFunction())
    {
        e = new AddrExp(e.loc, e);
    }
    else
        return e;
    return e.expressionSemantic(sc);
}

/****************************************
 * Run semantic on `e`.
 * Expression `e` evaluates to an instance of a struct.
 * Look up `ident` as a field of that struct.
 * Params:
 *   e = evaluates to an instance of a struct
 *   sc = context
 *   id = identifier of a field in that struct
 *   arrow = -> was used
 * Returns:
 *   if successful `e.ident`
 *   if not then `ErrorExp` and message is printed
 */
Expression fieldLookup(Expression e, Scope* sc, Identifier id, bool arrow)
{
    e = e.expressionSemantic(sc);
    if (e.isErrorExp())
        return e;
    if (arrow)
    {
        e = arrayFuncConv(e, sc);
        if (e.isErrorExp())
            return e;
    }

    auto eSink = global.errorSink;
    auto t = e.type;
    if (t.isTypePointer())
    {
        t = t.isTypePointer().next;
        auto pe = e.toChars();
        if (!arrow)
            eSink.error(e.loc, "since `%s` is a pointer, use `%s->%s` instead of `%s.%s`", pe, pe, id.toErrMsg(), pe, id.toErrMsg());
        e = new PtrExp(e.loc, e);
    }
    Dsymbol s;
    if (auto ts = t.isTypeStruct())
        s = ts.sym.search(e.loc, id, 0);
    if (!s)
    {
        eSink.error(e.loc, "`%s` is not a member of `%s`", id.toErrMsg(), t.toErrMsg());
        return ErrorExp.get();
    }
    Expression ef = new DotVarExp(e.loc, e, s.isDeclaration());
    return ef.expressionSemantic(sc);
}

/****************************************
 * C11 6.5.2.1-2
 * Apply C semantics to `E[I]` expression.
 * E1[E2] is lowered to *(E1 + E2)
 * Params:
 *      ae = ArrayExp to run semantics on
 *      sc = context
 * Returns:
 *      Expression if this was a C expression with completed semantic, null if not
 */
Expression carraySemantic(ArrayExp ae, Scope* sc)
{
    if (!sc.inCfile)
        return null;

    auto e1 = ae.e1.expressionSemantic(sc);

    assert(ae.arguments.length == 1);
    Expression e2 = (*ae.arguments)[0];

    /* CTFE cannot do pointer arithmetic, but it can index arrays.
     * So, rewrite as an IndexExp if we can.
     */
    auto t1 = e1.type.toBasetype();
    if (t1.isStaticOrDynamicArray())
    {
        e2 = e2.expressionSemantic(sc).arrayFuncConv(sc);
        // C doesn't do array bounds checking, so `true` turns it off
        return new IndexExp(ae.loc, e1, e2, true).expressionSemantic(sc);
    }

    e1 = e1.arrayFuncConv(sc);   // e1 might still be a function call
    e2 = e2.expressionSemantic(sc);
    auto t2 = e2.type.toBasetype();
    if (t2.isStaticOrDynamicArray())
    {
        return new IndexExp(ae.loc, e2, e1, true).expressionSemantic(sc); // swap operands
    }

    e2 = e2.arrayFuncConv(sc);
    auto ep = new PtrExp(ae.loc, new AddExp(ae.loc, e1, e2));
    return ep.expressionSemantic(sc);
}

/******************************************
 * Determine default initializer for const global symbol.
 */
void addDefaultCInitializer(VarDeclaration dsym)
{
    //printf("addDefaultCInitializer() %s\n", dsym.toChars());
    if (!(dsym.storage_class & (STC.static_ | STC.gshared)))
        return;
    if (dsym.storage_class & (STC.extern_ | STC.field | STC.in_ | STC.foreach_ | STC.parameter | STC.result))
        return;

    Type t = dsym.type;
    if (t.isTypeSArray() && t.isTypeSArray().isIncomplete())
    {
        dsym._init = new VoidInitializer(dsym.loc);
        return; // incomplete arrays will be diagnosed later
    }

    if (t.isMutable())
        return;

    auto e = dsym.type.defaultInit(dsym.loc, true);
    dsym._init = new ExpInitializer(dsym.loc, e);
}

/***********************
 * Perform semantic analysis on a C initializer, rewriting it into an
 * `ExpInitializer`, `ArrayInitializer` or `StructInitializer`.
 * Params:
 *      ci = C initializer to analyze
 *      sc = context
 *      tx = type of the declaration being initialized
 *      needInterpret = if initializer must be CTFE'd
 *      eSink = error message sink
 * Returns:
 *      the rewritten initializer, or `ErrorInitializer` on error
 */
Initializer cInitializerSemantic(CInitializer ci, Scope* sc, ref Type tx, NeedInterpret needInterpret, ErrorSink eSink)
{
    Type t = tx;

    static Initializer err()
    {
        return new ErrorInitializer();
    }
    //printf("CInitializer::semantic() tx: %s t: %s ci: %s\n", (tx ? tx.toChars() : "".ptr), t.toChars(), toChars(ci));
    static if (0)
        if (auto ts = tx.isTypeStruct())
        {
            OutBuffer buf;
            HdrGenState hgs;
            toCBuffer(ts.sym, buf, hgs);
            printf("%s\n", buf.peekChars());
        }

    /* Rewrite CInitializer into ExpInitializer, ArrayInitializer, or StructInitializer
     */
    t = t.toBasetype();

    bool isComplexInitilaizer()
    {
        switch (t.ty)
        {
            case Tcomplex32:
            case Tcomplex64:
            case Tcomplex80:
                return true;
            default:
                return false;
        }
    }

    if (auto tv = t.isTypeVector())
        t = tv.basetype;

    /* If `{ expression }` return the expression initializer
     */
    ExpInitializer isBraceExpression()
    {
        auto dil = ci.initializerList[];
        return (dil.length == 1 && !dil[0].designatorList)
                ? dil[0].initializer.isExpInitializer()
                : null;
    }

    /********************************
     */
    bool overlaps(VarDeclaration field, VarDeclaration[] fields, StructInitializer si)
    {
        foreach (fld; fields)
        {
            if (field.isOverlappedWith(fld))
            {
                // look for initializer corresponding with fld
                foreach (i, ident; si.field[])
                {
                    if (ident == fld.ident && si.value[i])
                        return true;   // already an initializer for `field`
                }
            }
        }
        return false;
    }

    /* Run semantic on ExpInitializer, see if it represents entire struct ts
     */
    bool representsStruct(ExpInitializer ei, TypeStruct ts)
    {
        if (needInterpret)
            sc = sc.startCTFE();
        ei.exp = ei.exp.expressionSemantic(sc);
        ei.exp = resolveProperties(sc, ei.exp);
        if (needInterpret)
            sc = sc.endCTFE();
        return ei.exp.implicitConvTo(ts) != MATCH.nomatch; // initializer represents the entire struct
    }

    /* If { } are omitted from substructs, use recursion to reconstruct where
     * brackets go
     * Params:
     *  ts = substruct to initialize
     *  index = index into ci.initializer, updated
     * Returns: struct initializer for this substruct
     */
    Initializer subStruct()(TypeStruct ts, ref size_t index)
    {
        //printf("subStruct(ts: %s, index %d)\n", ts.toChars(), cast(int)index);

        auto si = new StructInitializer(ci.loc);
        StructDeclaration sd = ts.sym;
        sd.size(ci.loc);
        if (sd.sizeok != Sizeok.done)
        {
            index = ci.initializerList.length;
            return err();
        }
        const nfields = sd.fields.length;

        foreach (fieldi; 0 .. nfields)
        {
            if (index >= ci.initializerList.length)
                break;          // ran out of initializers
            auto di = ci.initializerList[index];
            if (di.designatorList && fieldi != 0)
                break;          // back to top level

            VarDeclaration field;
            while (1)   // skip field if it overlaps with previously seen fields
            {
                field = sd.fields[fieldi];
                ++fieldi;
                if (!overlaps(field, sd.fields[], si))
                    break;
                if (fieldi == nfields)
                    break;
            }
            auto tn = field.type.toBasetype();
            auto tnsa = tn.isTypeSArray();
            auto tns = tn.isTypeStruct();
            auto ix = di.initializer;
            if (tnsa && ix.isExpInitializer())
            {
                ExpInitializer ei = ix.isExpInitializer();
                if (ei.exp.isStringExp() && tnsa.nextOf().isIntegral())
                {
                    si.addInit(field.ident, ei);
                    ++index;
                }
                else
                    si.addInit(field.ident, subArray(tnsa, index)); // fwd ref of subArray is why subStruct is a template
            }
            else if (tns && ix.isExpInitializer())
            {
                /* Disambiguate between an exp representing the entire
                 * struct, and an exp representing the first field of the struct
                 */
                if (representsStruct(ix.isExpInitializer(), tns)) // initializer represents the entire struct
                {
                    si.addInit(field.ident, initializerSemantic(ix, sc, tn, needInterpret, eSink));
                    ++index;
                }
                else                                // field initializers for struct
                    si.addInit(field.ident, subStruct(tns, index)); // the first field
            }
            else
            {
                si.addInit(field.ident, ix);
                ++index;
            }
        }
        //printf("subStruct() returns ai: %s, index: %d\n", si.toChars(), cast(int)index);
        return si;
    }

    /* If { } are omitted from subarrays, use recursion to reconstruct where
     * brackets go
     * Params:
     *  tsa = subarray to initialize
     *  index = index into ci.initializer, updated
     * Returns: array initializer for this subarray
     */
    Initializer subArray(TypeSArray tsa, ref size_t index)
    {
        //printf("array(tsa: %s, index %d)\n", tsa.toChars(), cast(int)index);
        if (tsa.isIncomplete())
        {
            // C11 6.2.5-20 "element type shall be complete whenever the array type is specified"
            assert(0); // should have been detected by parser
        }
        auto bt = tsa.nextOf().toBasetype();

        if (auto tnss = bt.isTypeStruct())
        {
            return subStruct(tnss, index);
        }
        auto tnsa = bt.isTypeSArray();
        auto ai = new ArrayInitializer(ci.loc);
        ai.isCarray = true;

        foreach (n; 0 .. cast(size_t)tsa.dim.toInteger())
        {
            if (index >= ci.initializerList.length)
                break;          // ran out of initializers
            auto di = ci.initializerList[index];
            if (di.designatorList)
                break;          // back to top level
            else if (tnsa && di.initializer.isExpInitializer())
            {
                ExpInitializer ei = di.initializer.isExpInitializer();
                if (ei.exp.isStringExp() && tnsa.nextOf().isIntegral())
                {
                    ai.addValue(ei);
                    ++index;
                }
                else
                    ai.addValue(subArray(tnsa, index));
            }
            else
            {
                ai.addValue(di.initializer);
                ++index;
            }
        }
        //printf("array() returns ai: %s, index: %d\n", ai.toChars(), cast(int)index);
        return ai;
    }

    if (auto ts = t.isTypeStruct())
    {
        auto si = new StructInitializer(ci.loc);
        StructDeclaration sd = ts.sym;
        sd.size(ci.loc);            // run semantic() on sd to get fields
        if (sd.sizeok != Sizeok.done)
        {
            return err();
        }
        const nfields = sd.fields.length;
        size_t fieldi = 0;

    Loop1:
        for (size_t index = 0; index < ci.initializerList.length; )
        {
            DesigInit di = ci.initializerList[index];
            Designators* dlist = di.designatorList;
            VarDeclaration field;
            if (dlist)
            {
                const length = (*dlist).length;
                auto id = (*dlist)[0].ident;
                if (length == 0 || !(*dlist)[0].ident)
                {
                    eSink.error(ci.loc, "`.identifier` expected for C struct field initializer `%s`", toChars(ci));
                    return err();
                }

                if (length > 1)
                {
                    StructDeclaration nstsd = sd; // use this for member structs we wish to traverse
                    auto subsi = si;
                    /*
                     * run this for each designator in the chain until you hit the last
                     * then perform semantic analysis on the last field in the chain using the previous struct initializer
                     */
                    for (size_t i = 0; i < length; i++)
                    {
                        int found;
                        id = (*dlist)[i].ident;
                        foreach (f; nstsd.fields[])
                        {
                            if (f.ident == id)
                            {
                                field = f;
                                ++found;
                                break;
                            }
                        }
                        if (!found)
                        {
                            eSink.error(ci.loc, "`.%s` is not a field of `%s`\n", id.toErrMsg(), nstsd.toErrMsg());
                            return err();
                        }

                        auto base = field.type.toBasetype();

                        if (i >= length -1)
                        {
                            subsi.addInit(id, di.initializer);
                            ++index;
                            continue Loop1;
                        }

                        auto tstr = base.isTypeStruct();
                        auto tarr = base.isTypeSArray();

                        if (tstr)
                        {
                            if (!overlaps(field, nstsd.fields[], subsi))
                            {
                                auto innersi = new StructInitializer(ci.loc);
                                subsi.addInit(id, innersi);
                                subsi = innersi;
                            }
                            else {
                                foreach(k, ident; subsi.field[])
                                {
                                    if (ident == id && subsi.value[k])
                                        subsi = subsi.value[k].isStructInitializer();
                                }
                            }
                            nstsd = tstr.sym;
                        }
                        /*
                         * once we hit an array, check & attach the array initializer to the struct initializer
                         * move to the next initializer id and run initializer semantics on it
                         */
                        else if (tarr)
                        {
                            /*
                             * so tempting to check for null cases for field._init.
                             * but if your object is set to null on decl, you can't use designators anymore
                             * and D does well to default initialize for us
                             */
                            auto ai = field._init.isArrayInitializer();

                            if (ai is null)
                            {
                                ai = new ArrayInitializer(ci.loc);
                                subsi.addInit(id, ai);
                                field._init = ai;
                            }

                            auto ndx = (*dlist)[i+1].exp;
                            ai.addInit(ndx, di.initializer);
                            ++index;
                            continue Loop1;
                        }
                        else
                        {
                            eSink.error(ci.loc, "only 1 designated initializer allowed for C struct field of type `%s`", toChars(base));
                            return err();
                        }
                    }
                }
                foreach (k, f; sd.fields[])         // linear search for now
                {
                    if (f.ident == id)
                    {
                        fieldi = k;
                        si.addInit(id, di.initializer);
                        ++fieldi;
                        ++index;
                        continue Loop1;
                    }
                }
                eSink.error(ci.loc, "`.%s` is not a field of `%s`\n", id.toErrMsg(), sd.toErrMsg());
                return err();
            }

            if (fieldi == nfields)
                break;

            auto ix = di.initializer;

            /* If a C initializer is wrapped in a C initializer, with no designators,
             * peel off the outer one
             */
            if (ix.isCInitializer())
            {
                CInitializer cix = ix.isCInitializer();
                if (cix.initializerList.length == 1)
                {
                    DesigInit dix = cix.initializerList[0];
                    if (!dix.designatorList)
                    {
                        Initializer inix = dix.initializer;
                        if (inix.isCInitializer())
                            ix = inix;
                    }
                }
            }

            if (auto cix = ix.isCInitializer())
            {
                /* ImportC loses the structure from anonymous structs, but this is retained
                 * by the initializer syntax. if a CInitializer has a Designator, it is probably
                 * a nested anonymous struct
                 */
                int found;
                foreach (dix; cix.initializerList)
                {
                    Designators* dlistx = dix.designatorList;
                    if (!dlistx)
                        continue;
                    if ((*dlistx).length == 1 && (*dlistx)[0].ident)
                    {
                        auto id = (*dlistx)[0].ident;
                        foreach (k, f; sd.fields[])         // linear search for now
                        {
                            if (f.ident == id)
                            {
                                fieldi = k;
                                si.addInit(id, dix.initializer);
                                ++fieldi;
                                ++index;
                                ++found;
                                break;
                            }
                        }
                    }
                    else {
                        eSink.error(ci.loc, "only 1 designator currently allowed for C struct field initializer `%s`", toChars(ci));
                    }
                }

                if (found == cix.initializerList.length)
                    continue Loop1;
            }

            while (1)   // skip field if it overlaps with previously seen fields
            {
                field = sd.fields[fieldi];
                ++fieldi;
                if (!overlaps(field, sd.fields[], si))
                    break;
                if (fieldi == nfields)
                    break;
            }

            auto tn = field.type.toBasetype();
            auto tnsa = tn.isTypeSArray();
            auto tns = tn.isTypeStruct();

            if (tnsa && ix.isExpInitializer())
            {
                ExpInitializer ei = ix.isExpInitializer();
                if (ei.exp.isStringExp() && tnsa.nextOf().isIntegral())
                {
                    si.addInit(field.ident, ei);
                    ++index;
                }
                else
                    si.addInit(field.ident, subArray(tnsa, index));
            }
            else if (tns && ix.isExpInitializer())
            {
                /* Disambiguate between an exp representing the entire
                 * struct, and an exp representing the first field of the struct
                 */
                if (representsStruct(ix.isExpInitializer(), tns)) // initializer represents the entire struct
                {
                    si.addInit(field.ident, initializerSemantic(ix, sc, tn, needInterpret, eSink));
                    ++index;
                }
                else                                // field initializers for struct
                    si.addInit(field.ident, subStruct(tns, index)); // the first field
            }
            else
            {
                si.addInit(field.ident, di.initializer);
                ++index;
            }
        }
        return initializerSemantic(si, sc, t, needInterpret, eSink);
    }
    else if (auto ta = t.isTypeSArray())
    {
        auto tn = t.nextOf().toBasetype();  // element type of array

        /* If it's an array of integral being initialized by `{ string }`
         * replace with `string`
         */
        if (tn.isIntegral())
        {
            if (ExpInitializer ei = isBraceExpression())
            {
                if (ei.exp.isStringExp())
                    return ei.initializerSemantic(sc, t, needInterpret, eSink);
            }
        }

        auto tnsa = tn.isTypeSArray();      // array of array
        auto tns = tn.isTypeStruct();       // array of struct

        auto ai = new ArrayInitializer(ci.loc);
        ai.isCarray = true;
        for (size_t index = 0; index < ci.initializerList.length; )
        {
            auto di = ci.initializerList[index];
            if (auto dlist = di.designatorList)
            {
                const length = (*dlist).length;
                if (length == 0 || !(*dlist)[0].exp)
                {
                    eSink.error(ci.loc, "`[ constant-expression ]` expected for C array element initializer `%s`", toChars(ci));
                    return err();
                }
                if (length > 1)
                {
                    eSink.error(ci.loc, "only 1 designator currently allowed for C array element initializer `%s`", toChars(ci));
                    return err();
                }
                //printf("tn: %s, di.initializer: %s\n", tn.toChars(), di.initializer.toChars());
                auto ix = di.initializer;
                if (tnsa && ix.isExpInitializer())
                {
                    // Wrap initializer in [ ]
                    auto ain = new ArrayInitializer(ci.loc);
                    ain.addValue(di.initializer);
                    ix = ain;
                    ai.addInit((*dlist)[0].exp, initializerSemantic(ix, sc, tn, needInterpret, eSink));
                    ++index;
                }
                else if (tns && ix.isExpInitializer())
                {
                    /* Disambiguate between an exp representing the entire
                     * struct, and an exp representing the first field of the struct
                     */
                    if (representsStruct(ix.isExpInitializer(), tns)) // initializer represents the entire struct
                    {
                        ai.addInit((*dlist)[0].exp, initializerSemantic(ix, sc, tn, needInterpret, eSink));
                        ++index;
                    }
                    else                                // field initializers for struct
                        ai.addInit((*dlist)[0].exp, subStruct(tns, index)); // the first field
                }
                else
                {
                    ai.addInit((*dlist)[0].exp, initializerSemantic(ix, sc, tn, needInterpret, eSink));
                    ++index;
                }
            }
            else if (tnsa && di.initializer.isExpInitializer())
            {
                ExpInitializer ei = di.initializer.isExpInitializer();
                if (ei.exp.isStringExp() && tnsa.nextOf().isIntegral())
                {
                    ai.addValue(ei);
                    ++index;
                }
                else
                    ai.addValue(subArray(tnsa, index));
            }
            else if (tns && di.initializer.isExpInitializer())
            {
                /* Disambiguate between an exp representing the entire
                 * struct, and an exp representing the first field of the struct
                 */
                if (representsStruct(di.initializer.isExpInitializer(), tns)) // initializer represents the entire struct
                {
                    ai.addValue(initializerSemantic(di.initializer, sc, tn, needInterpret, eSink));
                    ++index;
                }
                else                                // field initializers for struct
                    ai.addValue(subStruct(tns, index)); // the first field
            }
            else
            {
                ai.addValue(initializerSemantic(di.initializer, sc, tn, needInterpret, eSink));
                ++index;
            }
        }
        return initializerSemantic(ai, sc, tx, needInterpret, eSink);
    }
    else if (ExpInitializer ei = isBraceExpression())
    {
        Type te = t;
        auto res = initializerSemantic(ei, sc, te, needInterpret, eSink);
        if (te !is t)
            tx = te;
        return res;
    }
    else if (isComplexInitilaizer())
    {
        /* just convert _Complex = { a, b} to _Complex =. a + b*i */
        if (ci.initializerList[].length != 2)
        {
            eSink.error(ci.loc, "only two initializers required for complex type `%s`", t.toErrMsg());
            return err();
        }
        auto rexp = ci.initializerList[0].initializer.initializerToExpression(sc, null, eSink);
        auto imexp = ci.initializerList[1].initializer.initializerToExpression(sc, null, eSink);

        import dmd.root.ctfloat;
        auto newExpr = new AddExp(ci.loc, rexp,
        new MulExp(ci.loc, imexp, new RealExp(ci.loc, CTFloat.one, Type.timaginary64)));

        auto ce = new ExpInitializer(ci.loc, newExpr);
        return ce.initializerSemantic(sc, t, needInterpret, eSink);
    }
    else
    {
        eSink.error(ci.loc, "unrecognized C initializer `%s` for type `%s`", toChars(ci), t.toErrMsg());
        return err();
    }
}

/********************************************
 * Implement the C11 notion of function equivalence,
 * which allows prototyped functions to match K+R functions,
 * even though they are different.
 * Params:
 *      tf1 = type of first function
 *      tf2 = type of second function
 * Returns:
 *      true if C11 considers them equivalent
 */

bool cFuncEquivalence(TypeFunction tf1, TypeFunction tf2)
{
    //printf("cFuncEquivalence()\n  %s\n  %s\n", tf1.toChars(), tf2.toChars());
    if (tf1.equals(tf2))
        return true;

    if (tf1.linkage != tf2.linkage)
        return false;

    // Allow func(void) to match func()
    if (tf1.parameterList.length == 0 && tf2.parameterList.length == 0)
        return true;

    if (!cTypeEquivalence(tf1.next, tf2.next))
        return false;   // function return types don't match

    if (tf1.parameterList.length != tf2.parameterList.length)
        return false;

    if (!tf1.parameterList.hasIdentifierList && !tf2.parameterList.hasIdentifierList) // if both are prototyped
    {
        if (tf1.parameterList.varargs != tf2.parameterList.varargs)
            return false;
    }

    foreach (i, fparam ; tf1.parameterList)
    {
        Type t1 = fparam.type;
        Type t2 = tf2.parameterList[i].type;

        /* Strip off head const.
         * Not sure if this is C11, but other compilers treat
         * `void fn(int)` and `fn(const int x)`
         * as equivalent.
         */
        t1 = t1.mutableOf();
        t2 = t2.mutableOf();

        if (!t1.equals(t2))
            return false;
    }

    //printf("t1: %s\n", tf1.toChars());
    //printf("t2: %s\n", tf2.toChars());
    return true;
}

/*******************************
 * Types haven't been merged yet, because we haven't done
 * semantic() yet.
 * But we still need to see if t1 and t2 are the same type.
 * Params:
 *      t1 = first type
 *      t2 = second type
 * Returns:
 *      true if they are equivalent types
 */
bool cTypeEquivalence(Type t1, Type t2)
{
    if (t1.equals(t2))
        return true;    // that was easy

    if (t1.ty != t2.ty || t1.mod != t2.mod)
        return false;

    if (auto tp = t1.isTypePointer())
        return cTypeEquivalence(tp.next, t2.nextOf());

    if (auto ta = t1.isTypeSArray())
        // Bug: should check array dimension
        return cTypeEquivalence(ta.next, t2.nextOf());

    if (auto ts = t1.isTypeStruct())
        return ts.sym is t2.isTypeStruct().sym;

    if (auto te = t1.isTypeEnum())
        return te.sym is t2.isTypeEnum().sym;

    if (auto tf = t1.isTypeFunction())
        return cFuncEquivalence(tf, tf.isTypeFunction());

    return false;
}

/**********************************************
 * ImportC tag symbols sit in a parallel symbol table,
 * so that this C code works:
 * ---
 * struct S { a; };
 * int S;
 * struct S s;
 * ---
 * But there are relatively few such tag symbols, so that would be
 * a waste of memory and complexity. An additional problem is we'd like the D side
 * to find the tag symbols with ordinary lookup, not lookup in both
 * tables, if the tag symbol is not conflicting with an ordinary symbol.
 * The solution is to put the tag symbols that conflict into an associative
 * array, indexed by the address of the ordinary symbol that conflicts with it.
 * C has no modules, so this associative array is tagSymTab[] in ModuleDeclaration.
 * A side effect of our approach is that D code cannot access a tag symbol that is
 * hidden by an ordinary symbol. This is more of a theoretical problem, as nobody
 * has mentioned it when importing C headers. If someone wants to do it,
 * too bad so sad. Change the C code.
 * This function fixes up the symbol table when faced with adding a new symbol
 * `s` when there is an existing symbol `s2` with the same name.
 * C also allows forward and prototype declarations of tag symbols,
 * this function merges those.
 * Params:
 *      sc = context
 *      s = symbol to add to symbol table
 *      s2 = existing declaration
 *      sds = symbol table
 * Returns:
 *      if s and s2 are successfully put in symbol table then return the merged symbol,
 *      null if they conflict
 */
Dsymbol handleTagSymbols(ref Scope sc, Dsymbol s, Dsymbol s2, ScopeDsymbol sds)
{
    enum log = false;
    if (log) printf("handleTagSymbols('%s') add %p existing %p\n", s.toChars(), s, s2);
    if (log) printf("  add %s %s, existing %s %s\n", s.kind(), s.toChars(), s2.kind(), s2.toChars());
    auto sd = s.isScopeDsymbol(); // new declaration
    auto sd2 = s2.isScopeDsymbol(); // existing declaration

    static if (log) void print(EnumDeclaration sd)
    {
        printf("members: %p\n", sd.members);
        printf("symtab: %p\n", sd.symtab);
        printf("endlinnum: %d\n", sd.endloc.linnum);
        printf("type: %s\n", sd.type.toChars());
        printf("memtype: %s\n", sd.memtype.toChars());
    }

    if (!sd2)
    {
        /* Look in tag table
         */
        if (log) printf(" look in tag table\n");
        if (auto p = cast(void*)s2 in sc._module.tagSymTab)
        {
            Dsymbol s2tag = *p;
            sd2 = s2tag.isScopeDsymbol();
            assert(sd2);        // only tags allowed in tag symbol table
        }
    }

    if (sd && sd2) // `s` is a tag, `sd2` is the same tag
    {
        if (log) printf(" tag is already defined\n");

        if (sd.kind() != sd2.kind())  // being enum/struct/union must match
            return null;              // conflict

        /* Not a redeclaration if one is a forward declaration.
         * Move members to the first declared type, which is sd2.
         */
        if (sd2.members)
        {
            if (!sd.members)
                return sd2;  // ignore the sd redeclaration
        }
        else if (sd.members)
        {
            sd2.members = sd.members; // transfer definition to sd2
            sd.members = null;
            if (auto ed2 = sd2.isEnumDeclaration())
            {
                auto ed = sd.isEnumDeclaration();
                if (ed.memtype != ed2.memtype)
                    return null;        // conflict

                // transfer ed's members to sd2
                ed2.members.foreachDsymbol( (s)
                {
                    if (auto em = s.isEnumMember())
                        em.ed = ed2;
                });

                ed2.type = ed.type;
                ed2.memtype = ed.memtype;
                ed2.added = false;
            }
            return sd2;
        }
        else
            return sd2; // ignore redeclaration
    }
    else if (sd) // `s` is a tag, `s2` is not
    {
        if (log) printf(" s is tag, s2 is not\n");
        /* add `s` as tag indexed by s2
         */
        sc._module.tagSymTab[cast(void*)s2] = s;
        return s;
    }
    else if (s2 is sd2) // `s2` is a tag, `s` is not
    {
        if (log) printf(" s2 is tag, s is not\n");
        /* replace `s2` in symbol table with `s`,
         * then add `s2` as tag indexed by `s`
         */
        sds.symtab.update(s);
        sc._module.tagSymTab[cast(void*)s] = s2;
        return s;
    }
    // neither s2 nor s is a tag
    if (log) printf(" collision\n");
    return null;
}


/**********************************************
 * ImportC allows redeclarations of C variables, functions and typedefs.
 *    extern int x;
 *    int x = 3;
 * and:
 *    extern void f();
 *    void f() { }
 * Attempt to merge them.
 * Params:
 *      sc = context
 *      s = symbol to add to symbol table
 *      s2 = existing declaration
 *      sds = symbol table
 * Returns:
 *      if s and s2 are successfully put in symbol table then return the merged symbol,
 *      null if they conflict
 */
Dsymbol handleSymbolRedeclarations(ref Scope sc, Dsymbol s, Dsymbol s2, ScopeDsymbol sds)
{
    enum log = false;
    if (log) printf("handleSymbolRedeclarations('%s')\n", s.toChars());
    if (log) printf("  add %s %s, existing %s %s\n", s.kind(), s.toChars(), s2.kind(), s2.toChars());

    auto eSink = global.errorSink;

    static Dsymbol collision()
    {
        if (log) printf(" collision\n");
        return null;
    }
    /*
    Handle merging declarations with asm("foo") and their definitions
    */
    static void mangleWrangle(Declaration oldDecl, Declaration newDecl)
    {
        if (oldDecl && newDecl)
        {
            newDecl.mangleOverride = oldDecl.mangleOverride ? oldDecl.mangleOverride : null;
        }
    }

    // Don't let macros shadow real symbols
    if (auto td = s.isTemplateDeclaration())
    {
        if (td.isCmacro) return s2;
    }

    auto vd = s.isVarDeclaration(); // new declaration
    auto vd2 = s2.isVarDeclaration(); // existing declaration

    if (vd && vd.isCmacro)
        return s2;

    assert(!(vd2 && vd2.isCmacro));

    if (vd && vd2)
    {
        /* if one is `static` and the other isn't, the result is undefined
         * behavior, C11 6.2.2.7
         */
        if ((vd.storage_class ^ vd2.storage_class) & STC.static_)
            return collision();

        const i1 =  vd._init && ! vd._init.isVoidInitializer();
        const i2 = vd2._init && !vd2._init.isVoidInitializer();

        if (i1 && i2)
            return collision();         // can't both have initializers

        mangleWrangle(vd2, vd);

        if (i1)                         // vd is the definition
        {
            vd2.storage_class |= STC.extern_;  // so toObjFile() won't emit it
            sds.symtab.update(vd);      // replace vd2 with the definition
            return vd;
        }
        else if (!i1 && !(vd2.storage_class & STC.extern_)) /* incoming has void void definition */
        {
            vd.storage_class |= STC.extern_;
        }

        /* BUG: the types should match, which needs semantic() to be run on it
         *    extern int x;
         *    int x;  // match
         *    typedef int INT;
         *    INT x;  // match
         *    long x; // collision
         * We incorrectly ignore these collisions
         * when their types are not matching, err on type differences
         */

        if (!cTypeEquivalence(vd.type, vd2.type))
        {
            eSink.error(vd.loc, "redefinition of `%s` with different type: `%s` vs `%s`",
                vd2.ident.toErrMsg(), vd2.type.toErrMsg(), vd.type.toErrMsg());
        }
        return vd2;
    }

    auto fd = s.isFuncDeclaration(); // new declaration
    auto fd2 = s2.isFuncDeclaration(); // existing declaration
    if (fd && fd2)
    {
        /* if one is `static` and the other isn't, the result is undefined
         * behavior, C11 6.2.2.7
         * However, match what gcc allows:
         *    static int sun1(); int sun1() { return 0; }
         * and:
         *    static int sun2() { return 0; } int sun2();
         * Both produce a static function.
         *
         * Both of these should fail:
         *    int sun3(); static int sun3() { return 0; }
         * and:
         *    int sun4() { return 0; } static int sun4();
         */
        // if adding `static`
        if (   fd.storage_class & STC.static_ &&
            !(fd2.storage_class & STC.static_))
        {
            return collision();
        }

        if (fd.fbody && fd2.fbody)
            return collision();         // can't both have bodies

        mangleWrangle(fd2, fd);

        if (fd.fbody)                   // fd is the definition
        {
            if (log) printf(" replace existing with new\n");
            sds.symtab.update(fd);  // replace fd2 in symbol table with fd
            fd.overnext = fd2;

            /* If fd2 is covering a tag symbol, then fd has to cover the same one
             */
            auto ps = cast(void*)fd2 in sc._module.tagSymTab;
            if (ps)
                sc._module.tagSymTab[cast(void*)fd] = *ps;

            return fd;
        }

        /* Just like with VarDeclaration, the types should match, which needs semantic() to be run on it.
         * FuncDeclaration::semantic() detects this, but it relies on .overnext being set.
         */
        fd2.overloadInsert(fd);

        //for the sake of functions declared in function scope.
        // check for return type equivalence also
        auto tf1 = fd.type.isTypeFunction();
        auto tf2 = fd2.type.isTypeFunction();
        if (sc.func &&  !cTypeEquivalence(tf1.next, tf2.next) )
        {
            eSink.error(fd.loc, "%s `%s` redeclaration with different type", fd.kind, fd.toPrettyChars);
        }

        return fd2;
    }

    auto td  = s.isAliasDeclaration();  // new declaration
    auto td2 = s2.isAliasDeclaration(); // existing declaration
    if (td && td2)
    {
        /* BUG: just like with variables and functions, the types should match, which needs semantic() to be run on it.
         * FuncDeclaration::semantic2() can detect this, but it relies overnext being set.
         */
        return td2;
    }

    return collision();
}

/*********************************
 * ImportC-specific semantic analysis on enum declaration `ed`
 */
void cEnumSemantic(Scope* sc, EnumDeclaration ed)
{
    // C11 6.7.2.2
    Type commonType = ed.memtype;
    if (!commonType)
        commonType = Type.tint32;
    ulong nextValue = 0;        // C11 6.7.2.2-3 first member value defaults to 0
    auto eSink = global.errorSink;

    // C11 6.7.2.2-2 value must be representable as an int.
    // The sizemask represents all values that int will fit into,
    // from 0..uint.max.  We want to cover int.min..uint.max.
    IntRange ir = intRangeFromType(commonType);

    void emSemantic(EnumMember em, ref ulong nextValue)
    {
        static void errorReturn(EnumMember em)
        {
            em.value = ErrorExp.get();
            em.errors = true;
            em.semanticRun = PASS.semanticdone;
        }

        em.semanticRun = PASS.semantic;
        em.type = commonType;
        em._linkage = LINK.c;
        em.storage_class |= STC.manifest;
        if (em.value)
        {
            Expression e = em.value;
            assert(e.dyncast() == DYNCAST.expression);

            /* To merge the type of e with commonType, add 0 of type commonType
                */
            if (!ed.memtype)
                e = new AddExp(em.loc, e, new IntegerExp(em.loc, 0, commonType));

            e = e.expressionSemantic(sc);
            e = resolveProperties(sc, e);
            e = e.integralPromotions(sc);
            e = e.ctfeInterpret();
            if (e.op == EXP.error)
                return errorReturn(em);
            auto ie = e.isIntegerExp();
            if (!ie)
            {
                // C11 6.7.2.2-2
                eSink.error(em.loc, "%s `%s` enum member must be an integral constant expression, not `%s` of type `%s`", em.kind, em.toPrettyChars, e.toErrMsg(), e.type.toErrMsg());
                return errorReturn(em);
            }
            if (ed.memtype && !ir.contains(getIntRange(ie)))
            {
                // C11 6.7.2.2-2
                eSink.error(em.loc, "%s `%s` enum member value `%s` does not fit in `%s`", em.kind, em.toPrettyChars, e.toErrMsg(), commonType.toErrMsg());
                return errorReturn(em);
            }
            nextValue = ie.toInteger();
            if (!ed.memtype)
                commonType = e.type;
            em.value = new IntegerExp(em.loc, nextValue, commonType);
        }
        else
        {
            // C11 6.7.2.2-3 add 1 to value of previous enumeration constant
            bool first = (em == (*em.ed.members)[0]);
            if (!first)
            {
                Expression max = getProperty(commonType, null, em.loc, Id.max, 0);
                if (nextValue == max.toInteger())
                {
                    eSink.error(em.loc, "%s `%s` initialization with `%s+1` causes overflow for type `%s`", em.kind, em.toPrettyChars, max.toErrMsg(), commonType.toErrMsg());
                    return errorReturn(em);
                }
                nextValue += 1;
            }
            em.value = new IntegerExp(em.loc, nextValue, commonType);
        }
        em.type = commonType;
        em.semanticRun = PASS.semanticdone;
    }

    ed.members.foreachDsymbol( (s)
    {
        if (EnumMember em = s.isEnumMember())
            emSemantic(em, nextValue);
    });

    if (!ed.memtype)
    {
        // cast all members to commonType
        ed.members.foreachDsymbol( (s)
        {
            if (EnumMember em = s.isEnumMember())
            {
                em.type = commonType;
                // optimize out the cast so that other parts of the compiler can
                // assume that an integral enum's members are `IntegerExp`s.
                // https://issues.dlang.org/show_bug.cgi?id=24504
                em.value = em.value.castTo(sc, commonType).optimize(WANTvalue);
            }
        });
    }

    ed.memtype = commonType;
    // Set semantic2done to mark C enums as fully processed
    // Prevents issues with final switch statements that reference C enums
    ed.semanticRun = PASS.semantic2done;
    return;
}
