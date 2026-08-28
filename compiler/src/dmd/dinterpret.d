/**
 * The entry point for CTFE.
 *
 * Specification: ($LINK2 https://dlang.org/spec/function.html#interpretation, Compile Time Function Execution (CTFE))
 *
 * Copyright:   Copyright (C) 1999-2026 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 https://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/compiler/src/dmd/dinterpret.d, _dinterpret.d)
 * Documentation:  https://dlang.org/phobos/dmd_dinterpret.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/compiler/src/dmd/dinterpret.d
 */

module dmd.dinterpret;

import core.stdc.stdio;
import core.stdc.stdlib;
import core.stdc.string;
import dmd.arraytypes;
import dmd.astenums;
import dmd.attrib;
import dmd.builtin;
import dmd.constfold;
import dmd.ctfeexpr;
import dmd.ctfememory;
import dmd.dcast;
import dmd.dclass;
import dmd.declaration;
import dmd.dstruct;
import dmd.dsymbol;
import dmd.dsymbolsem;
import dmd.dtemplate;
import dmd.errors;
import dmd.errorsink;
import dmd.expression;
import dmd.expressionsem;
import dmd.func;
import dmd.funcsem;
import dmd.globals;
import dmd.hdrgen;
import dmd.id;
import dmd.identifier;
import dmd.init;
import dmd.initsem;
import dmd.location;
import dmd.mtype;
import dmd.root.rmem;
import dmd.root.array;
import dmd.root.ctfloat;
import dmd.root.region;
import dmd.rootobject;
import dmd.root.utf;
import dmd.statement;
import dmd.semantic2 : findFunc;
import dmd.tokens;
import dmd.typesem;
import dmd.utils : arrayCastBigEndian;
import dmd.visitor;

/*************************************
 * Entry point for CTFE.
 * A compile-time result is required. Give an error if not possible.
 *
 * `e` must be semantically valid expression. In other words, it should not
 * contain any `ErrorExp`s in it. But, CTFE interpretation will cross over
 * functions and may invoke a function that contains `ErrorStatement` in its body.
 * If that, the "CTFE failed because of previous errors" error is raised.
 */
public Expression ctfeInterpret(Expression e)
{
    switch (e.op)
    {
        case EXP.int64:
        case EXP.float64:
        case EXP.complex80:
        case EXP.null_:
        case EXP.void_:
        case EXP.string_:
        case EXP.this_:
        case EXP.super_:
        case EXP.type:
        case EXP.typeid_:
        case EXP.template_:              // non-eponymous template/instance
        case EXP.scope_:                 // ditto
        case EXP.dotTemplateDeclaration: // ditto, e.e1 doesn't matter here
        case EXP.dotTemplateInstance:    // ditto
        case EXP.dot:                    // ditto
             if (e.type.ty == Terror)
                return ErrorExp.get();
            goto case EXP.error;

        case EXP.error:
            return e;

        default:
            break;
    }

    assert(e.type); // https://issues.dlang.org/show_bug.cgi?id=14642
    //assert(e.type.ty != Terror);    // FIXME
    if (e.type.ty == Terror)
        return ErrorExp.get();

    auto rgnpos = ctfeGlobals.region.savePos();
    // Nested CTFE invocations release LIFO, so a mark suffices to reclaim
    // linear memory of variables pushed outside any function frame.
    const linearMark = ctfeGlobals.linearMem.markStack();
    ++ctfeGlobals.linearNest;

    import dmd.timetrace;
    timeTraceBeginEvent(TimeTraceEventType.ctfe);
    scope (exit) timeTraceEndEvent(TimeTraceEventType.ctfe, e);

    Expression result = interpret(e, null);

    // Report an error if the expression contained a `ThrowException` and
    // hence generated an uncaught exception
    if (auto tee = result.isThrownExceptionExp())
    {
        tee.generateUncaughtError();
        result = CTFEExp.cantexp;
    }
    else
        result = copyRegionExp(result);

    if (!CTFEExp.isCantExp(result))
        result = scrubReturnValue(e.loc, result);
    if (CTFEExp.isCantExp(result))
        result = ErrorExp.get();

    ctfeGlobals.region.release(rgnpos);
    // Slice payloads live in the heap arena and survive function frames, so
    // they are only reclaimed when the outermost CTFE invocation ends. No
    // linear value can survive past this point: results were converted to
    // AST nodes and the stack slot tables were popped.
    if (--ctfeGlobals.linearNest == 0)
    {
        ctfeGlobals.linearMem.reset();
        ctfeGlobals.escapedPayloads.setDim(0);
    }
    else
        ctfeGlobals.linearMem.releaseStack(linearMark);

    return result;
}

/* Run CTFE on the expression, but allow the expression to be a TypeExp
 *  or a tuple containing a TypeExp. (This is required by pragma(msg)).
 */
public Expression ctfeInterpretForPragmaMsg(Expression e)
{
    if (e.op == EXP.error || e.op == EXP.type)
        return e;

    // It's also OK for it to be a function declaration (happens only with
    // __traits(getOverloads))
    if (auto ve = e.isVarExp())
        if (ve.var.isFuncDeclaration())
        {
            return e;
        }

    auto tup = e.isTupleExp();
    if (!tup)
        return e.ctfeInterpret();

    // Tuples need to be treated separately, since they are
    // allowed to contain a TypeExp in this case.

    Expressions* expsx = null;
    foreach (i, g; *tup.exps)
    {
        auto h = ctfeInterpretForPragmaMsg(g);
        if (h != g)
        {
            if (!expsx)
            {
                expsx = tup.exps.copy();
            }
            (*expsx)[i] = h;
        }
    }
    if (expsx)
    {
        auto te = new TupleExp(e.loc, expsx);
        expandTuples(te.exps);
        te.type = new TypeTuple(te.exps);
        return te;
    }
    return e;
}

public Expression getValue(VarDeclaration vd)
{
    return ctfeGlobals.stack.getValue(vd);
}

/*************************************************
 * Allocate an Expression in the ctfe region.
 * Params:
 *      T = type of Expression to allocate
 *      args = arguments to Expression's constructor
 * Returns:
 *      allocated Expression
 */
T ctfeEmplaceExp(T : Expression, Args...)(Args args)
{
    if (mem.isGCEnabled)
        return new T(args);
    auto p = ctfeGlobals.region.malloc(__traits(classInstanceSize, T));
    emplaceExp!T(p, args);
    return cast(T)p;
}

// CTFE diagnostic information
public extern (C++) void printCtfePerformanceStats()
{
    debug (SHOWPERFORMANCE)
    {
        printf("        ---- CTFE Performance ----\n");
        printf("max call depth = %d\tmax stack = %d\n", ctfeGlobals.maxCallDepth, ctfeGlobals.stack.maxStackUsage());
        printf("array allocs = %d\tassignments = %d\n\n", ctfeGlobals.numArrayAllocs, ctfeGlobals.numAssignments);
    }
}

/**************************
 */

void incArrayAllocs()
{
    ++ctfeGlobals.numArrayAllocs;
}

/* ================================================ Implementation ======================================= */

private:

/***************
 * Collect together globals used by CTFE
 */
/// A slice return value handed over as a linear handle (see
/// `CtfeGlobals.linearReturnDest`).
struct CtfeLinearReturn
{
    LinearSlice slice;
    bool set = false;
}

struct CtfeGlobals
{
    Region region;

    CtfeStack stack;

    CtfeMemory linearMem;     // linear (flat byte) storage for values, -preview=ctfeLinearMemory
    int linearNest = 0;       // nesting depth of ctfeInterpret invocations

    /* Payloads that were materialized as a canonical AST node ("escaped").
     * A payload's header holds `payloadEscaped` and the index into this
     * array; every handle to it is redirected to the canonical node before
     * its next use, so there is never more than one AST node per array.
     */
    Array!Expression escapedPayloads;

    /* Hand-over channel for slice return values: when a call's result is
     * about to be stored straight into a slice-eligible variable, the caller
     * points this at a local CtfeLinearReturn before interpreting the
     * CallExp; visit(CallExp) takes it (and clears it, so nested calls do
     * not see it) and the callee's return statement transfers the handle
     * instead of materializing an AST array. Payloads live in the heap
     * arena, so the handle outlives the callee's frame.
     */
    CtfeLinearReturn* linearReturnDest = null;

    int callDepth = 0;        // current number of recursive calls

    // When printing a stack trace, suppress this number of calls
    int stackTraceCallsToSuppress = 0;

    int maxCallDepth = 0;     // highest number of recursive calls
    int numArrayAllocs = 0;   // Number of allocated arrays
    int numAssignments = 0;   // total number of assignments executed
}

__gshared CtfeGlobals ctfeGlobals;

enum CTFEGoal : int
{
    RValue,     /// Must return an Rvalue (== CTFE value)
    LValue,     /// Must return an Lvalue (== CTFE reference)
    Nothing,    /// The return value is not required
}

//debug = LOG;
//debug = LOGASSIGN;
//debug = LOGCOMPILE;
//debug = SHOWPERFORMANCE;

// Maximum allowable recursive function calls in CTFE
enum CTFE_RECURSION_LIMIT = 1000;

/**
 The values of all CTFE variables
 */
struct CtfeStack
{
private:
    /* The stack. Every declaration we encounter is pushed here,
     * together with the VarDeclaration, and the previous
     * stack address of that variable, so that we can restore it
     * when we leave the stack frame.
     * Note that when a function is forward referenced, the interpreter must
     * run semantic3, and that may start CTFE again with a NULL istate. Thus
     * the stack might not be empty when CTFE begins.
     *
     * Ctfe Stack addresses are just 0-based integers, but we save
     * them as 'void *' because Array can only do pointers.
     */
    Expressions values;         // values on the stack
    VarDeclarations vars;       // corresponding variables
    Array!(void*) savedId;      // id of the previous state of that var

    /* With -preview=ctfeLinearMemory, scalar values are stored as raw bytes
     * in `ctfeGlobals.linearMem` rather than as AST nodes. For each stack
     * entry, either `values[i]` holds an AST value, or `slotPtrs[i]` points
     * at the variable's bytes (a null CtfePtr means no linear value).
     */
    Array!CtfePtr slotPtrs;     // linear memory slots, parallel to values[]

    Array!(void*) frames;       // all previous frame pointers
    Expressions savedThis;      // all previous values of localThis
    Array!StackMark frameMarks; // linear stack arena state at frame entry

    /* Global constants get saved here after evaluation, so we never
     * have to redo them. This saves a lot of time and memory.
     */
    Expressions globalValues;   // values of global constants

    size_t framepointer;        // current frame pointer
    size_t maxStackPointer;     // most stack we've ever used
    Expression localThis;       // value of 'this', or NULL if none

public:
    size_t stackPointer() @safe
    {
        return values.length;
    }

    // The current value of 'this', or NULL if none
    Expression getThis() @safe
    {
        return localThis;
    }

    // Largest number of stack positions we've used
    size_t maxStackUsage() @safe
    {
        return maxStackPointer;
    }

    // Start a new stack frame, using the provided 'this'.
    void startFrame(Expression thisexp)
    {
        startFrame(thisexp, ctfeGlobals.linearMem.markStack());
    }

    /* Start a new stack frame whose linear memory extends down to an
     * earlier mark (so staged arguments die with this frame).
     */
    void startFrame(Expression thisexp, StackMark linearMark)
    {
        frames.push(cast(void*)cast(size_t)framepointer);
        savedThis.push(localThis);
        frameMarks.push(linearMark);
        framepointer = stackPointer();
        localThis = thisexp;
    }

    void endFrame()
    {
        size_t oldframe = cast(size_t)frames[frames.length - 1];
        localThis = savedThis[savedThis.length - 1];
        popAll(framepointer);
        ctfeGlobals.linearMem.releaseStack(frameMarks[frameMarks.length - 1]);
        framepointer = oldframe;
        frames.setDim(frames.length - 1);
        savedThis.setDim(savedThis.length - 1);
        frameMarks.setDim(frameMarks.length - 1);
    }

    bool isInCurrentFrame(VarDeclaration v)
    {
        if (v.isDataseg() && !v.isCTFE())
            return false; // It's a global
        return v.ctfeAdrOnStack >= framepointer;
    }

    Expression getValue(VarDeclaration v)
    {
        //printf("getValue() %s\n", v.toChars());
        if ((v.isDataseg() || v.storage_class & STC.manifest) && !v.isCTFE())
        {
            assert(v.ctfeAdrOnStack < globalValues.length);
            return globalValues[v.ctfeAdrOnStack];
        }
        assert(v.ctfeAdrOnStack < stackPointer());
        if (auto e = values[v.ctfeAdrOnStack])
            return e;
        // The value may live in linear memory; materialize an AST node in the region
        UnionExp ue = void;
        if (auto e = getLinear(v, v.loc, v.type, &ue))
            return e == ue.exp() ? regionUeCopy(ue) : e;
        // A linear slice value flips to the AST representation when loaded,
        // because the loaded node could be aliased
        if (auto e = materializeLinearSlice(v))
            return e;
        return null;
    }

    void setValue(VarDeclaration v, Expression e)
    {
        //printf("setValue() %s : %s\n", v.toChars(), e.toChars());
        assert(!v.isDataseg() || v.isCTFE());
        assert(v.ctfeAdrOnStack < stackPointer());
        if (storeLinear(v, e))
            return;
        slotPtrs[v.ctfeAdrOnStack] = CtfePtr.init; // representation switches to AST
        values[v.ctfeAdrOnStack] = e;
    }

    /* How may v's value be stored in linear memory? The answer only depends
     * on the declaration, so it is cached on it (see the values of
     * `VarDeclaration.ctfeLinearKind`). Kinds 2 and 3 imply: local (indexes
     * values[], not globalValues[]) and not a reference, so v owns its
     * stack entry.
     */
    static ubyte linearKind(VarDeclaration v)
    {
        if (v.ctfeLinearKind == 0)
        {
            ubyte compute()
            {
                if (v.isBitFieldDeclaration())
                    return 1;
                const scalar = isLinearScalarType(v.type);
                const slice = !scalar && isLinearSliceType(v.type);
                if (!scalar && !slice)
                    return 1;
                // `ref`/`out` parameters do not own their entry, but the
                // aliased caller variable's entry may hold a slice handle
                if (v.storage_class & (STC.ref_ | STC.out_))
                    return slice ? 4 : 1;
                if (v.storage_class & (STC.lazy_ | STC.manifest))
                    return 1;
                if (v.isDataseg() && !v.isCTFE())
                    return 1; // indexes globalValues[], never linear
                return scalar ? 2 : 3;
            }
            v.ctfeLinearKind = compute();
        }
        return v.ctfeLinearKind;
    }

    // Is v a local whose value may be stored as raw scalar bytes in linear memory?
    bool canStoreLinear(VarDeclaration v)
    {
        if (!global.params.ctfeLinearMemory)
            return false;
        if (linearKind(v) != 2)
            return false;
        return v.ctfeAdrOnStack != VarDeclaration.AdrOnStackNone && v.ctfeAdrOnStack < stackPointer();
    }

    // Is v a local whose value may be stored as a linear slice handle?
    bool canStoreLinearSlice(VarDeclaration v)
    {
        if (!global.params.ctfeLinearMemory)
            return false;
        if (linearKind(v) != 3)
            return false;
        return v.ctfeAdrOnStack != VarDeclaration.AdrOnStackNone && v.ctfeAdrOnStack < stackPointer();
    }

    // Does v currently hold an AST-node value (as opposed to a linear-memory
    // value or nothing)?
    bool hasAstValue(VarDeclaration v)
    {
        return values[v.ctfeAdrOnStack] !is null;
    }

    /* v's raw scalar slot, or CtfePtr.init if v's value does not currently
     * live in linear memory as scalar bytes.
     */
    CtfePtr scalarSlot(VarDeclaration v)
    {
        // check the address first: linearKind() calls isDataseg(), which must
        // not run on special variables like __ctfe (never pushed)
        const adr = v.ctfeAdrOnStack;
        if (adr == VarDeclaration.AdrOnStackNone || adr >= values.length)
            return CtfePtr.init;
        if (linearKind(v) != 2) // kind 3 slots hold slice handles, not scalars
            return CtfePtr.init;
        if (values[adr] !is null)
            return CtfePtr.init;
        return slotPtrs[adr];
    }

    /* The AST value of v's entry, or null if v has no value or the value
     * lives in linear memory. Unlike getValue, never materializes a linear
     * value (no side effects).
     */
    Expression astValue(VarDeclaration v)
    {
        const adr = v.ctfeAdrOnStack;
        // check the address first: isDataseg() must not be called on
        // special variables like __ctfe (which are never pushed)
        if (adr == VarDeclaration.AdrOnStackNone || adr >= values.length)
            return null;
        if ((v.isDataseg() || v.storage_class & STC.manifest) && !v.isCTFE())
            return null;
        return values[adr];
    }

    /* Does v's value currently live in linear memory?
     *
     * Note: the representation is a property of the stack entry, not of the
     * declaration — a `ref` parameter can alias the entry of an eligible
     * caller variable (see the ref parameter aliasing in interpretFunction).
     */
    bool hasLinearValue(VarDeclaration v)
    {
        const adr = v.ctfeAdrOnStack;
        // check the address first: isDataseg() must not be called on
        // special variables like __ctfe (which are never pushed)
        if (adr == VarDeclaration.AdrOnStackNone || adr >= values.length)
            return false;
        if ((v.isDataseg() || v.storage_class & STC.manifest) && !v.isCTFE())
            return false; // indexes globalValues[], never linear
        if (values[adr] !is null)
            return false;
        return ctfeGlobals.linearMem.isValid(slotPtrs[adr]);
    }

    /* Try to store scalar literal e as raw bytes in v's linear memory slot.
     * Returns: false if v is not eligible or e is not a scalar literal;
     * the caller stores the AST node instead.
     */
    bool storeLinear(VarDeclaration v, Expression e)
    {
        if (e is null || (e.op != EXP.int64 && e.op != EXP.float64))
            return false;
        if (!canStoreLinear(v))
            return false;
        const adr = v.ctfeAdrOnStack;
        CtfePtr slot = slotPtrs[adr];
        if (slot.isNull)
        {
            if (adr < framepointer)
                return false; // a slot allocated now would die with the current frame
            slot = allocateSlot(v);
            if (slot.isNull)
                return false;
            slotPtrs[adr] = slot;
        }
        if (!encodeInto(ctfeGlobals.linearMem, e, v.type, slot))
            return false;
        values[adr] = null;
        return true;
    }

    /* Like storeLinear, but takes the value as raw bytes at src (encoded
     * with a type equivalent to v's). Used to bind staged arguments.
     */
    bool storeLinearRaw(VarDeclaration v, CtfePtr src, uint n)
    {
        if (!canStoreLinear(v))
            return false;
        const adr = v.ctfeAdrOnStack;
        CtfePtr slot = slotPtrs[adr];
        if (slot.isNull)
        {
            if (adr < framepointer)
                return false; // a slot allocated now would die with the current frame
            slot = allocateSlot(v);
            if (slot.isNull)
                return false;
            slotPtrs[adr] = slot;
        }
        if (!ctfeGlobals.linearMem.copy(slot, src, n))
            return false;
        values[adr] = null;
        return true;
    }

    private CtfePtr allocateSlot(VarDeclaration v)
    {
        const sz = v.type.size();
        if (sz == SIZE_INVALID || sz > 64)
            return CtfePtr.init;
        return CtfePtr(ctfeGlobals.linearMem.allocate(ArenaKind.stack, cast(uint) sz), 0);
    }

    /* If v's stack entry currently holds a linear slice handle, return the
     * slot it is stored in, otherwise a null pointer.
     *
     * Like getLinear, this is entry-based: a `ref` parameter (kind 4) may
     * alias the entry of an eligible caller variable.
     */
    CtfePtr sliceSlot(VarDeclaration v)
    {
        const adr = v.ctfeAdrOnStack;
        // check the address first: linearKind must not compute isDataseg()
        // on special variables like __ctfe (which are never pushed)
        if (adr == VarDeclaration.AdrOnStackNone || adr >= values.length)
            return CtfePtr.init;
        const kind = linearKind(v);
        if (kind != 3 && kind != 4)
            return CtfePtr.init;
        if (values[adr] !is null)
            return CtfePtr.init;
        const slot = slotPtrs[adr];
        if (!ctfeGlobals.linearMem.isValid(slot))
            return CtfePtr.init;
        // If the payload escaped to a canonical AST node, the raw bytes are
        // stale: fast paths must not use this handle. The regular path they
        // fall back to redirects it (see materializeLinearSlice).
        LinearSlice s;
        PayloadHeader h;
        if (readSlice(ctfeGlobals.linearMem, slot, s) && s.alloc != 0 &&
            readPayloadHeader(ctfeGlobals.linearMem, s.alloc, h) &&
            (h.flags & payloadEscaped))
            return CtfePtr.init;
        return slot;
    }

    // Does v's entry have a linear slot allocated (whatever the current
    // representation)? A handle can be stored without a new allocation.
    bool hasLinearSlot(VarDeclaration v)
    {
        const adr = v.ctfeAdrOnStack;
        return adr != VarDeclaration.AdrOnStackNone && adr < slotPtrs.length &&
               !slotPtrs[adr].isNull;
    }

    /* Store slice handle s as v's value. Allocates the (16 byte) slot on
     * first use. Returns: false if v is not eligible (the caller keeps the
     * AST representation).
     */
    bool storeLinearSlice(VarDeclaration v, LinearSlice s)
    {
        if (!canStoreLinearSlice(v))
            return false;
        const adr = v.ctfeAdrOnStack;
        CtfePtr slot = slotPtrs[adr];
        if (slot.isNull)
        {
            if (adr < framepointer)
                return false; // a slot allocated now would die with the current frame
            slot = CtfePtr(ctfeGlobals.linearMem.allocate(ArenaKind.stack, LinearSlice.sizeof), 0);
            if (slot.isNull)
                return false;
            slotPtrs[adr] = slot;
        }
        if (!writeSlice(ctfeGlobals.linearMem, slot, s))
            return false;
        values[adr] = null;
        return true;
    }

    /* If v's stack entry holds a linear slice handle, materialize the array
     * as an AST node, store that as the entry's value and abandon the handle
     * ("flip to AST"). The payload's canonical node is created at most once
     * and recorded in `ctfeGlobals.escapedPayloads`; other handles into the
     * same payload are redirected to it (as the node itself, or a SliceExp
     * of it) when they get here, which preserves reference semantics: there
     * is never more than one AST node per array object.
     * Returns: null if the entry does not hold a linear slice value.
     */
    Expression materializeLinearSlice(VarDeclaration v)
    {
        const adr = v.ctfeAdrOnStack;
        if (adr == VarDeclaration.AdrOnStackNone || adr >= values.length)
            return null;
        const kind = linearKind(v);
        if (kind != 3 && kind != 4)
            return null;
        if (values[adr] !is null)
            return null;
        const slot = slotPtrs[adr];
        LinearSlice s;
        if (!readSlice(ctfeGlobals.linearMem, slot, s))
            return null;

        Expression e;
        if (s.alloc == 0)
        {
            e = decodeSlice(ctfeGlobals.linearMem, s, v.type, v.loc); // NullExp
        }
        else
        {
            PayloadHeader h;
            if (!readPayloadHeader(ctfeGlobals.linearMem, s.alloc, h))
                return null;
            Expression eWhole;
            if (h.flags & payloadEscaped)
            {
                // once escaped, `capacity` holds the escapedPayloads index
                eWhole = ctfeGlobals.escapedPayloads[h.capacity];
            }
            else
            {
                const whole = LinearSlice(s.alloc, PayloadHeader.sizeof, h.used);
                eWhole = decodeSlice(ctfeGlobals.linearMem, whole, v.type, v.loc);
                if (eWhole is null)
                    return null;
                h.flags |= payloadEscaped;
                h.capacity = cast(uint) ctfeGlobals.escapedPayloads.length;
                writePayloadHeader(ctfeGlobals.linearMem, s.alloc, h);
                ctfeGlobals.escapedPayloads.push(eWhole);
            }
            if (s.offset == PayloadHeader.sizeof && s.length == h.used)
                e = eWhole;
            else
            {
                // a sub-slice of the array object
                const lo = (s.offset - PayloadHeader.sizeof) / h.elemSize;
                auto se = new SliceExp(v.loc, eWhole,
                    new IntegerExp(v.loc, lo, Type.tsize_t),
                    new IntegerExp(v.loc, lo + s.length, Type.tsize_t));
                se.type = v.type;
                e = se;
            }
        }
        if (e is null)
            return null;
        values[adr] = e;
        slotPtrs[adr] = CtfePtr.init;
        return e;
    }

    /* If v's value lives in linear memory, rebuild an AST node for it in
     * caller storage `*pue`, with type t painted on.
     * Returns: null if v's value does not live in linear memory.
     */
    Expression getLinear(VarDeclaration v, Loc loc, Type t, UnionExp* pue)
    {
        // entry-based, not declaration-based: a `ref` parameter may alias
        // the linear entry of an eligible caller variable
        const adr = v.ctfeAdrOnStack;
        // check the address first: isDataseg() must not be called on
        // special variables like __ctfe (which are never pushed)
        if (adr == VarDeclaration.AdrOnStackNone || adr >= values.length)
            return null;
        if ((v.isDataseg() || v.storage_class & STC.manifest) && !v.isCTFE())
            return null; // indexes globalValues[], never linear
        if (values[adr] !is null)
            return null;
        const slot = slotPtrs[adr];
        if (slot.isNull)
            return null;
        return decodeScalar(ctfeGlobals.linearMem, slot, t, loc, pue);
    }

    void push(VarDeclaration v)
    {
        //printf("push() %s\n", v.toChars());
        assert(!v.isDataseg() || v.isCTFE());
        if (v.ctfeAdrOnStack != VarDeclaration.AdrOnStackNone && v.ctfeAdrOnStack >= framepointer)
        {
            // Already exists in this frame, reuse it.
            values[v.ctfeAdrOnStack] = null;
            slotPtrs[v.ctfeAdrOnStack] = CtfePtr.init;
            return;
        }
        savedId.push(cast(void*)cast(size_t)v.ctfeAdrOnStack);
        v.ctfeAdrOnStack = cast(uint)values.length;
        vars.push(v);
        values.push(null);
        slotPtrs.push(CtfePtr.init);
    }

    void pop(VarDeclaration v)
    {
        assert(!v.isDataseg() || v.isCTFE());
        assert(!v.isReference());
        const oldid = v.ctfeAdrOnStack;
        v.ctfeAdrOnStack = cast(uint)cast(size_t)savedId[oldid];
        if (v.ctfeAdrOnStack == values.length - 1)
        {
            values.pop();
            vars.pop();
            savedId.pop();
            slotPtrs.pop();
        }
    }

    void popAll(size_t stackpointer)
    {
        if (stackPointer() > maxStackPointer)
            maxStackPointer = stackPointer();
        assert(values.length >= stackpointer);
        for (size_t i = stackpointer; i < values.length; ++i)
        {
            VarDeclaration v = vars[i];
            v.ctfeAdrOnStack = cast(uint)cast(size_t)savedId[i];
        }
        values.setDim(stackpointer);
        vars.setDim(stackpointer);
        savedId.setDim(stackpointer);
        slotPtrs.setDim(stackpointer);
    }

    void saveGlobalConstant(VarDeclaration v, Expression e)
    {
        assert(v._init && (v.isConst() || v.isImmutable() || v.storage_class & STC.manifest) && !v.isCTFE());
        v.ctfeAdrOnStack = cast(uint)globalValues.length;
        globalValues.push(copyRegionExp(e));
    }
}

/* If e is `v`, `v[]` or `v[l..u]` where v's slice value lives in linear
 * memory, evaluate it to handle `s` (bounds evaluated and checked).
 * Returns: 0 if not linear (guaranteed: nothing was evaluated yet), 1 if `s`
 * was set, -1 on an error or exception while evaluating the bounds (`*perr`
 * is set to the exception or CTFEExp.cantexp).
 */
private int readLinearSliceValue(Expression e, InterState* istate, out LinearSlice s, Expression* perr)
{
    Expression lwr;
    Expression upr;
    VarDeclaration lengthVar;
    Expression base = e;
    if (auto se = e.isSliceExp())
    {
        base = se.e1;
        lwr = se.lwr;
        upr = se.upr;
        lengthVar = se.lengthVar;
        if ((lwr is null) != (upr is null))
            return 0; // half-bounded slices should not occur; be safe
    }
    if (base.type.toBasetype().ty != Tarray)
        return 0;
    auto ve = base.isVarExp();
    if (!ve)
        return 0;
    auto v = ve.var.isVarDeclaration();
    if (!v)
        return 0;
    const slot = ctfeGlobals.stack.sliceSlot(v);
    if (slot.isNull || !readSlice(ctfeGlobals.linearMem, slot, s))
        return 0;
    if (lwr is null)
        return 1;

    // committed from here: evaluating the bounds may have side effects
    const esz = cast(uint) base.type.toBasetype().isTypeDArray().next.size();
    if (lengthVar)
    {
        Expression dollarExp = ctfeEmplaceExp!IntegerExp(e.loc, s.length, Type.tsize_t);
        ctfeGlobals.stack.push(lengthVar);
        setValue(lengthVar, dollarExp);
    }
    UnionExp ueLwr = void;
    UnionExp ueUpr = void;
    Expression elwr = interpret(&ueLwr, lwr, istate);
    Expression eupr = CTFEExp.cantexp;
    if (!exceptionOrCantInterpret(elwr))
        eupr = interpret(&ueUpr, upr, istate);
    if (lengthVar)
        ctfeGlobals.stack.pop(lengthVar); // $ is defined only inside [ ]
    if (exceptionOrCantInterpret(elwr))
    {
        *perr = elwr;
        return -1;
    }
    if (exceptionOrCantInterpret(eupr))
    {
        *perr = eupr;
        return -1;
    }
    if (elwr.op != EXP.int64 || eupr.op != EXP.int64)
    {
        error(e.loc, "CTFE internal error: non-integral slice bounds `%s`", e.toErrMsg());
        *perr = CTFEExp.cantexp;
        return -1;
    }
    const ilwr = elwr.toInteger();
    const iupr = eupr.toInteger();
    if (ilwr > iupr || iupr > s.length)
    {
        error(e.loc, "slice `[%llu..%llu]` exceeds array bounds `[0..%llu]`",
            ilwr, iupr, cast(ulong) s.length);
        *perr = CTFEExp.cantexp;
        return -1;
    }
    s.offset += cast(uint)(ilwr * esz);
    s.length = cast(uint)(iupr - ilwr);
    return 1;
}

/// Mark the payload of `s` as referenced by more than one handle.
private void markPayloadShared(ref LinearSlice s)
{
    if (s.alloc == 0)
        return;
    PayloadHeader h;
    if (!readPayloadHeader(ctfeGlobals.linearMem, s.alloc, h))
        return;
    if (h.flags & payloadShared)
        return;
    h.flags |= payloadShared;
    writePayloadHeader(ctfeGlobals.linearMem, s.alloc, h);
}

/* ------------- byte-native scalar expression evaluation -------------
 *
 * The linear representation's profiled time cost is intermediate node
 * traffic: every scalar read used to decode bytes into a fresh IntegerExp
 * so the generic (AST-based) evaluator could consume it. The functions
 * below evaluate whole side-effect-free integral expression trees directly
 * on raw 64-bit values instead, so `x + a[i] * 2 < n` builds no nodes at
 * all; only the root of a hooked expression materializes one result node.
 *
 * The safety discipline is total bail-out: every function returns false at
 * any node it does not fully understand, *before* anything observable
 * happens — no writes, no `$` binding, no errors. Error cases (division by
 * zero, out-of-range shift, out-of-bounds index) also return false: the
 * generic path re-evaluates the expression and reports. Since supported
 * nodes are all side-effect-free, re-evaluation is unobservable.
 */

/// Size in bytes of an integral basetype `ty` the raw tier supports, else 0.
/// (A `ty` switch avoids the generic Type.size()/isIntegral() dispatch, which
/// profiles as a large share of raw evaluation.)
private uint rawIntSize(TY ty)
{
    switch (ty)
    {
    case Tbool, Tint8, Tuns8, Tchar:  return 1;
    case Tint16, Tuns16, Twchar:      return 2;
    case Tint32, Tuns32, Tdchar:      return 4;
    case Tint64, Tuns64:              return 8;
    default:                          return 0;
    }
}

/// Is integral basetype `ty` unsigned (matching Type.isUnsigned)?
private bool rawIntUnsigned(TY ty)
{
    switch (ty)
    {
    case Tbool, Tuns8, Tchar, Tuns16, Twchar, Tuns32, Tdchar, Tuns64:
        return true;
    default:
        return false;
    }
}

/// Truncate + sign-extend `v` like `IntegerExp.normalize` for integral basetype `ty`.
private ulong normalizeRawInt(ulong v, TY ty)
{
    switch (ty)
    {
    case Tbool:           return v != 0;
    case Tint8:           return cast(ulong) cast(byte) v;
    case Tuns8, Tchar:    return cast(ubyte) v;
    case Tint16:          return cast(ulong) cast(short) v;
    case Tuns16, Twchar:  return cast(ushort) v;
    case Tint32:          return cast(ulong) cast(int) v;
    case Tuns32, Tdchar:  return cast(uint) v;
    default:              return v;
    }
}

/// Read the integral value of type `t` at `p`, normalized, into `val`.
private bool readRawScalar(CtfePtr p, Type t, out ulong val)
{
    const ty = t.toBasetype().ty;
    const sz = rawIntSize(ty);
    if (sz == 0)
        return false;
    auto s = ctfeGlobals.linearMem.slice(p, sz);
    if (s is null)
        return false;
    ulong raw = 0;
    memcpy(&raw, s.ptr, sz);
    val = normalizeRawInt(raw, ty);
    return true;
}

/// Read variable v's integral value, chasing `ref` bindings. No side effects.
private bool rawVarValue(VarDeclaration v, out ulong val)
{
    for (int depth = 0; depth < 8; ++depth)
    {
        if (v is null)
            return false;
        if (auto ev = ctfeGlobals.stack.astValue(v))
        {
            if (auto ie = ev.isIntegerExp())
            {
                val = ie.toInteger();
                return true;
            }
            if (auto ve2 = ev.isVarExp()) // a `ref` bound to a caller variable
            {
                v = ve2.var.isVarDeclaration();
                continue;
            }
            if (ev.op == EXP.index || ev.op == EXP.dotVariable)
            {
                // a `ref` bound to an array element or a field within one
                CtfePtr p;
                Type t;
                return tryResolveRawLoc(ev, p, t) && readRawScalar(p, t, val);
            }
            return false;
        }
        const slot = ctfeGlobals.stack.scalarSlot(v);
        return !slot.isNull && readRawScalar(slot, v.type, val);
    }
    return false;
}

/* Resolve a side-effect-free lvalue chain — IndexExp / DotVarExp nodes and
 * CTFE references held by `ref` variables, rooted in a slice in linear
 * memory — to a location, like tryResolveLinearLoc but committing to
 * nothing. `$` is not supported (its lengthVar is only bound on the
 * generic path).
 */
private bool tryResolveRawLoc(Expression e, out CtfePtr p, out Type t)
{
    if (auto ve = e.isVarExp())
    {
        auto v = ve.var.isVarDeclaration();
        if (!v || !(v.storage_class & (STC.ref_ | STC.out_)))
            return false;
        Expression ev = ctfeGlobals.stack.astValue(v);
        if (ev is null)
            return false;
        if (ev.op == EXP.index || ev.op == EXP.dotVariable || ev.op == EXP.variable)
            return tryResolveRawLoc(ev, p, t);
        return false;
    }

    if (auto ie = e.isIndexExp())
    {
        if (ie.e1.type.toBasetype().ty != Tarray)
            return false;
        auto bve = ie.e1.isVarExp();
        auto bv = bve ? bve.var.isVarDeclaration() : null;
        if (!bv)
            return false;
        const slot = ctfeGlobals.stack.sliceSlot(bv);
        LinearSlice s;
        if (slot.isNull || !readSlice(ctfeGlobals.linearMem, slot, s))
            return false;
        ulong idx;
        if (!tryEvalScalarRaw(ie.e2, idx))
            return false;
        if (idx >= s.length)
            return false; // the generic path reports the bounds error
        Type telem = bv.type.toBasetype().isTypeDArray().next;
        p = CtfePtr(s.alloc, cast(uint)(s.offset + idx * cast(uint) telem.size()));
        t = telem;
        return true;
    }

    if (auto dve = e.isDotVarExp())
    {
        if (dve.e1.type.toBasetype().ty != Tstruct)
            return false;
        auto fv = dve.var.isVarDeclaration();
        if (!fv || fv.isBitFieldDeclaration())
            return false;
        if (!tryResolveRawLoc(dve.e1, p, t))
            return false;
        if (t.toBasetype().isTypeStruct() is null)
            return false;
        p.offset += fv.offset;
        t = fv.type;
        return true;
    }

    return false;
}

/* The integer core of constfold's Add..Ushr on normalized raw values of
 * operand basetypes `ty1`/`ty2`; `val` is normalized to result basetype
 * `tyRes`. Returns false for anything constfold reports as an error
 * (division by zero, signed overflow, out-of-range shift) — the generic
 * path reports.
 */
private bool rawBinOp(EXP op, TY ty1, TY ty2, ulong u1, ulong u2, TY tyRes, out ulong val)
{
    switch (op)
    {
    case EXP.add: val = u1 + u2; break;
    case EXP.min: val = u1 - u2; break;
    case EXP.mul: val = u1 * u2; break;
    case EXP.and: val = u1 & u2; break;
    case EXP.or:  val = u1 | u2; break;
    case EXP.xor: val = u1 ^ u2; break;

    case EXP.div:
    case EXP.mod:
    {
        if (u2 == 0)
            return false;
        const uns = rawIntUnsigned(ty1) || rawIntUnsigned(ty2);
        if (!uns && u2 == cast(ulong)-1L)
            return false; // covers the int.min/-1 overflow errors
        if (op == EXP.div)
            val = uns ? u1 / u2 : cast(ulong)(cast(long) u1 / cast(long) u2);
        else
            val = uns ? u1 % u2 : cast(ulong)(cast(long) u1 % cast(long) u2);
        break;
    }

    case EXP.leftShift:
    case EXP.rightShift:
    case EXP.unsignedRightShift:
    {
        const bits = rawIntSize(ty1) * 8;
        if (u2 >= bits)
            return false;
        if (op == EXP.leftShift)
            val = u1 << u2;
        else if (op == EXP.rightShift)
            val = rawIntUnsigned(ty1) ? u1 >> u2 : cast(ulong)(cast(long) u1 >> u2);
        else // >>>: zero-extend to the operand type's width, then shift
            val = (bits >= 64 ? u1 : u1 & ((1UL << bits) - 1)) >> u2;
        break;
    }

    default:
        return false;
    }
    val = normalizeRawInt(val, tyRes);
    return true;
}

/* Evaluate the integral expression `e` byte-natively into `val`, normalized
 * like IntegerExp. Returns false at any unsupported node, having evaluated
 * nothing observable. Only reached under -preview=ctfeLinearMemory.
 */
private bool tryEvalScalarRaw(Expression e, out ulong val)
{
    Type tb = e.type ? e.type.toBasetype() : null;
    if (tb is null || rawIntSize(tb.ty) == 0)
        return false;

    switch (e.op)
    {
    case EXP.int64:
        val = e.isIntegerExp().toInteger();
        return true;

    case EXP.variable:
        return rawVarValue(e.isVarExp().var.isVarDeclaration(), val);

    case EXP.index:
    case EXP.dotVariable:
    {
        CtfePtr p;
        Type t;
        return tryResolveRawLoc(e, p, t) && readRawScalar(p, t, val);
    }

    case EXP.arrayLength:
    {
        auto ve = e.isArrayLengthExp().e1.isVarExp();
        auto v = ve ? ve.var.isVarDeclaration() : null;
        if (!v)
            return false;
        const slot = ctfeGlobals.stack.sliceSlot(v);
        LinearSlice s;
        if (slot.isNull || !readSlice(ctfeGlobals.linearMem, slot, s))
            return false;
        val = s.length;
        return true;
    }

    case EXP.negate:
    case EXP.tilde:
    case EXP.not:
    {
        ulong u;
        if (!tryEvalScalarRaw(e.isUnaExp().e1, u))
            return false;
        val = e.op == EXP.negate ? -u : e.op == EXP.tilde ? ~u : (u == 0);
        val = normalizeRawInt(val, tb.ty);
        return true;
    }

    case EXP.cast_:
    {
        // integral -> integral only: the operand's type is checked on recursion
        ulong u;
        if (!tryEvalScalarRaw(e.isCastExp().e1, u))
            return false;
        val = normalizeRawInt(u, tb.ty);
        return true;
    }

    case EXP.add:
    case EXP.min:
    case EXP.mul:
    case EXP.and:
    case EXP.or:
    case EXP.xor:
    case EXP.div:
    case EXP.mod:
    case EXP.leftShift:
    case EXP.rightShift:
    case EXP.unsignedRightShift:
    {
        auto be = e.isBinExp();
        ulong u1, u2;
        if (!tryEvalScalarRaw(be.e1, u1) || !tryEvalScalarRaw(be.e2, u2))
            return false;
        return rawBinOp(e.op, be.e1.type.toBasetype().ty, be.e2.type.toBasetype().ty,
            u1, u2, tb.ty, val);
    }

    case EXP.lessThan:
    case EXP.lessOrEqual:
    case EXP.greaterThan:
    case EXP.greaterOrEqual:
    case EXP.equal:
    case EXP.notEqual:
    case EXP.identity:
    case EXP.notIdentity:
    {
        auto be = e.isBinExp();
        auto t1 = be.e1.type.toBasetype();
        // semantic equalizes operand types; bail on anything unusual
        if (t1.ty != be.e2.type.toBasetype().ty)
            return false;
        ulong u1, u2;
        if (!tryEvalScalarRaw(be.e1, u1) || !tryEvalScalarRaw(be.e2, u2))
            return false;
        bool r;
        switch (e.op)
        {
        case EXP.equal:
        case EXP.identity:
            r = u1 == u2; // normalized values of equal types
            break;
        case EXP.notEqual:
        case EXP.notIdentity:
            r = u1 != u2;
            break;
        default:
        {
            const lt = rawIntUnsigned(t1.ty) ? u1 < u2 : cast(long) u1 < cast(long) u2;
            const eq = u1 == u2;
            r = e.op == EXP.lessThan ? lt :
                e.op == EXP.lessOrEqual ? lt || eq :
                e.op == EXP.greaterThan ? !lt && !eq : !lt;
            break;
        }
        }
        val = r;
        return true;
    }

    case EXP.andAnd:
    case EXP.orOr:
    {
        auto be = e.isLogicalExp();
        ulong u1;
        if (!tryEvalScalarRaw(be.e1, u1))
            return false;
        if (e.op == EXP.andAnd ? u1 == 0 : u1 != 0)
        {
            // short-circuit: e2 is not evaluated, exactly like the language
            val = e.op == EXP.orOr;
            return true;
        }
        ulong u2;
        if (!tryEvalScalarRaw(be.e2, u2)) // bails when e2 is void-typed (assert)
            return false;
        val = u2 != 0;
        return true;
    }

    case EXP.question:
    {
        auto ce = e.isCondExp();
        ulong uc;
        if (!tryEvalScalarRaw(ce.econd, uc))
            return false;
        return tryEvalScalarRaw(uc ? ce.e1 : ce.e2, val);
    }

    default:
        return false;
    }
}

private struct InterState
{
    InterState* caller;     // calling function's InterState
    FuncDeclaration fd;     // function being interpreted
    Statement start;        // if !=NULL, start execution at this statement

    /* target of CTFEExp result; also
     * target of labelled CTFEExp or
     * CTFEExp. (null if no label).
     */
    Statement gotoTarget;

    /* If non-null, the caller stores this function's slice return value
     * straight into a slice-eligible variable: a return statement may hand
     * the value over as a linear handle here instead of materializing it
     * (returning CTFEExp.voidexp as the marker).
     */
    CtfeLinearReturn* returnSlice;
}

/*************************************
 * Attempt to interpret a function given the arguments.
 * Params:
 *      pue       = storage for result
 *      fd        = function being called
 *      istate    = state for calling function (NULL if none)
 *      arguments = function arguments
 *      thisarg   = 'this', if a needThis() function, NULL if not.
 *
 * Returns:
 * result expression if successful, EXP.cantExpression if not,
 * or CTFEExp if function returned void.
 */
private Expression interpretFunction(UnionExp* pue, FuncDeclaration fd, InterState* istate, Expressions* arguments, Expression thisarg,
    CtfeLinearReturn* linearReturn = null)
{
    debug (LOG)
    {
        printf("\n********\n%s FuncDeclaration::interpret(istate = %p) %s\n", fd.loc.toChars(), istate, fd.toChars());
    }

    scope dlg = () {
        import dmd.common.outbuffer;
        auto strbuf = OutBuffer(20);
        strbuf.writestring(fd.toPrettyChars());
        strbuf.write("(");
        if (arguments)
        {
            foreach (i, arg; *arguments)
            {
                if (i > 0)
                    strbuf.write(", ");
                strbuf.writestring(arg.toChars());
            }
        }
        strbuf.write(")");
        return strbuf.extractSlice();
    };
    import dmd.timetrace;
    timeTraceBeginEvent(TimeTraceEventType.ctfeCall);
    scope (exit) timeTraceEndEvent(TimeTraceEventType.ctfeCall, fd, dlg);

    auto eSink = global.errorSink;

    void fdError(const(char)* msg)
    {
        eSink.error(fd.loc, "%s `%s` %s", fd.kind, fd.toPrettyChars, msg);
    }

    assert(pue);
    if (fd.semanticRun == PASS.semantic3)
    {
        fdError("circular dependency. Functions cannot be interpreted while being compiled");
        return CTFEExp.cantexp;
    }
    if (!functionSemantic3(fd))
        return CTFEExp.cantexp;
    if (fd.semanticRun < PASS.semantic3done)
    {
        fdError("circular dependency. Functions cannot be interpreted while being compiled");
        return CTFEExp.cantexp;
    }

    auto tf = fd.type.toBasetype().isTypeFunction();
    if (tf.parameterList.varargs != VarArg.none && arguments &&
        ((fd.parameters && arguments.length != fd.parameters.length) || (!fd.parameters && arguments.length)))
    {
        fdError("C-style variadic functions are not yet implemented in CTFE");
        return CTFEExp.cantexp;
    }

    // Nested functions always inherit the 'this' pointer from the parent,
    // except for delegates. (Note that the 'this' pointer may be null).
    // Func literals report isNested() even if they are in global scope,
    // so we need to check that the parent is a function.
    if (fd.isNested() && fd.toParentLocal().isFuncDeclaration() && !thisarg && istate)
        thisarg = ctfeGlobals.stack.getThis();

    if (fd.needThis() && !thisarg)
    {
        // error, no this. Prevent segfault.
        // Here should be unreachable by the strict 'this' check in front-end.
        eSink.error(fd.loc, "%s `%s` need `this` to access member `%s`", fd.kind, fd.toPrettyChars, fd.toErrMsg());
        return CTFEExp.cantexp;
    }

    // Place to hold all the arguments to the function while
    // we are evaluating them.
    size_t dim = arguments ? arguments.length : 0;
    assert((fd.parameters ? fd.parameters.length : 0) == dim);

    /* Evaluate all the arguments to the function,
     * store the results in eargs[]
     */
    Expressions eargs = Expressions(dim);

    /* With -preview=ctfeLinearMemory, scalar argument values are staged as
     * raw bytes in the caller's linear stack frame instead of AST nodes in
     * the region (a staged arg has eargs[i] set to null). They are copied
     * into the parameters' slots once the new frame has started.
     */
    CtfePtr argStage;
    enum argStageSlotSize = 16; // bytes per staged argument, fits any scalar
    const linearMark = ctfeGlobals.linearMem.markStack(); // staging dies with the new frame
    if (global.params.ctfeLinearMemory && dim > 0)
        argStage = CtfePtr(ctfeGlobals.linearMem.allocate(ArenaKind.stack,
            cast(uint)(dim * argStageSlotSize)), 0);

    for (size_t i = 0; i < dim; i++)
    {
        Expression earg = (*arguments)[i];
        Parameter fparam = tf.parameterList[i];

        if (fparam.isReference())
        {
            if (!istate && (fparam.storageClass & STC.out_))
            {
                // initializing an out parameter involves writing to it.
                eSink.error(earg.loc, "global `%s` cannot be passed as an `out` parameter at compile time", earg.toErrMsg());
                return CTFEExp.cantexp;
            }
            // Convert all reference arguments into lvalue references
            earg = interpretRegion(earg, istate, CTFEGoal.LValue);
            if (CTFEExp.isCantExp(earg))
                return earg;
        }
        else if (fparam.isLazy())
        {
        }
        else if (!argStage.isNull && isLinearScalarType(fparam.type))
        {
            /* Scalar value parameters: evaluate into stack storage and stage
             * the value as raw bytes, so no AST node has to be allocated
             */
            const stageSlot = CtfePtr(argStage.alloc, cast(uint)(i * argStageSlotSize));

            // integral arguments byte-natively, without even a temporary node
            const pty = fparam.type.toBasetype().ty;
            const psz = rawIntSize(pty);
            ulong rawArg = void;
            if (psz && tryEvalScalarRaw(earg, rawArg))
            {
                rawArg = normalizeRawInt(rawArg, pty);
                if (auto sb = ctfeGlobals.linearMem.slice(stageSlot, psz))
                {
                    memcpy(sb.ptr, &rawArg, psz);
                    eargs[i] = null; // marks the arg as staged
                    continue;
                }
            }

            UnionExp ue = void;
            earg = interpret(&ue, earg, istate);
            if (CTFEExp.isCantExp(earg))
                return earg;
            if (!exceptionOrCantInterpret(earg) &&
                encodeInto(ctfeGlobals.linearMem, earg, fparam.type, stageSlot))
            {
                eargs[i] = null; // marks the arg as staged
                continue;
            }
            if (earg == ue.exp())
                earg = regionUeCopy(ue);
        }
        else if (!argStage.isNull && isLinearSliceType(fparam.type) &&
                 earg.type.toBasetype().isTypeDArray() &&
                 earg.type.toBasetype().isTypeDArray().next.size() ==
                     fparam.type.toBasetype().isTypeDArray().next.size())
        {
            /* Slice value parameters whose argument value lives in linear
             * memory: stage the 16-byte handle; the payload becomes shared
             * between the caller's and the callee's handle
             */
            LinearSlice s;
            Expression err;
            const rc = readLinearSliceValue(earg, istate, s, &err);
            if (rc < 0)
            {
                if (CTFEExp.isCantExp(err))
                    return err;
                earg = err; // a thrown exception, handled below
            }
            else if (rc > 0)
            {
                const stageSlot = CtfePtr(argStage.alloc, cast(uint)(i * argStageSlotSize));
                if (writeSlice(ctfeGlobals.linearMem, stageSlot, s))
                {
                    markPayloadShared(s);
                    eargs[i] = null; // marks the arg as staged
                    continue;
                }
                error(fd.loc, "%s `%s` CTFE internal error: cannot stage argument %zu", fd.kind, fd.toPrettyChars, i);
                return CTFEExp.cantexp;
            }
            else
            {
                // not a linear value; evaluate normally
                earg = interpretRegion(earg, istate);
                if (CTFEExp.isCantExp(earg))
                    return earg;
            }
        }
        else
        {
            /* Value parameters
             */
            Type ta = fparam.type.toBasetype();
            if (ta.ty == Tsarray)
                if (auto eaddr = earg.isAddrExp())
                {
                    /* Static arrays are passed by a simple pointer.
                     * Skip past this to get at the actual arg.
                     */
                    earg = eaddr.e1;
                }

            earg = interpretRegion(earg, istate);
            if (CTFEExp.isCantExp(earg))
                return earg;

            /* Struct literals are passed by value, but we don't need to
             * copy them if they are passed as const
             */
            if (earg.op == EXP.structLiteral && !(fparam.storageClass & (STC.const_ | STC.immutable_)))
                earg = copyLiteral(earg).copy();
        }
        if (auto tee = earg.isThrownExceptionExp())
        {
            if (istate)
                return tee;
            tee.generateUncaughtError();
            return CTFEExp.cantexp;
        }
        eargs[i] = earg;
    }

    // Now that we've evaluated all the arguments, we can start the frame
    // (this is the moment when the 'call' actually takes place).
    InterState istatex;
    istatex.caller = istate;
    istatex.fd = fd;
    if (linearReturn && !tf.isRef && tf.next && isLinearSliceType(tf.next))
        istatex.returnSlice = linearReturn;

    if (fd.hasDualContext)
    {
        Expression arg0 = thisarg;
        if (arg0 && arg0.type.ty == Tstruct)
        {
            Type t = arg0.type.pointerTo();
            arg0 = ctfeEmplaceExp!AddrExp(arg0.loc, arg0);
            arg0.type = t;
        }
        auto elements = new Expressions(2);
        (*elements)[0] = arg0;
        (*elements)[1] = ctfeGlobals.stack.getThis();
        Type t2 = Type.tvoidptr.sarrayOf(2);
        const loc = thisarg ? thisarg.loc : fd.loc;
        thisarg = ctfeEmplaceExp!ArrayLiteralExp(loc, t2, elements);
        thisarg = ctfeEmplaceExp!AddrExp(loc, thisarg);
        thisarg.type = t2.pointerTo();
    }

    ctfeGlobals.stack.startFrame(thisarg, linearMark);
    if (fd.vthis && thisarg)
    {
        ctfeGlobals.stack.push(fd.vthis);
        setValue(fd.vthis, thisarg);
    }

    for (size_t i = 0; i < dim; i++)
    {
        Expression earg = eargs[i];
        Parameter fparam = tf.parameterList[i];
        VarDeclaration v = (*fd.parameters)[i];

        if (earg is null)
        {
            // Staged argument: move the bytes into the parameter's linear
            // memory slot
            ctfeGlobals.stack.push(v);
            const stageSlot = CtfePtr(argStage.alloc, cast(uint)(i * argStageSlotSize));
            if (isLinearSliceType(v.type))
            {
                LinearSlice s;
                if (readSlice(ctfeGlobals.linearMem, stageSlot, s) &&
                    ctfeGlobals.stack.storeLinearSlice(v, s))
                    continue;
                error(fd.loc, "%s `%s` CTFE internal error: cannot bind staged argument %zu", fd.kind, fd.toPrettyChars, i);
                return CTFEExp.cantexp;
            }
            const vsize = v.type.size();
            if (vsize == SIZE_INVALID ||
                !ctfeGlobals.stack.storeLinearRaw(v, stageSlot, cast(uint) vsize))
            {
                // fall back to an AST value in the region
                UnionExp ue = void;
                Expression ev = decodeScalar(ctfeGlobals.linearMem, stageSlot, v.type, v.loc, &ue);
                if (!ev)
                {
                    error(fd.loc, "%s `%s` CTFE internal error: cannot bind staged argument %zu", fd.kind, fd.toPrettyChars, i);
                    return CTFEExp.cantexp;
                }
                setValueWithoutChecking(v, ev == ue.exp() ? regionUeCopy(ue) : ev);
            }
            continue;
        }

        debug (LOG)
        {
            printf("arg[%u] = %s\n", cast(uint)i, earg.toChars());
        }
        ctfeGlobals.stack.push(v);

        if (fparam.isReference() && earg.op == EXP.variable &&
            earg.isVarExp().var.toParent2() == fd)
        {
            VarDeclaration vx = earg.isVarExp().var.isVarDeclaration();
            if (!vx)
            {
                eSink.error(fd.loc, "%s `%s` cannot interpret `%s` as a `ref` parameter", fd.kind, fd.toPrettyChars, earg.toErrMsg());
                return CTFEExp.cantexp;
            }

            /* vx is a variable that is declared in fd.
             * It means that fd is recursively called. e.g.
             *
             *  void fd(int n, ref int v = dummy) {
             *      int vx;
             *      if (n == 1) fd(2, vx);
             *  }
             *  fd(1);
             *
             * The old value of vx on the stack in fd(1)
             * should be saved at the start of fd(2, vx) call.
             */
            const oldadr = vx.ctfeAdrOnStack;

            ctfeGlobals.stack.push(vx);
            assert(!hasValue(vx)); // vx is made uninitialized

            // https://issues.dlang.org/show_bug.cgi?id=14299
            // v.ctfeAdrOnStack should be saved already
            // in the stack before the overwrite.
            v.ctfeAdrOnStack = oldadr;
            assert(hasValue(v)); // ref parameter v should refer existing value.
        }
        else
        {
            // Value parameters and non-trivial references
            setValueWithoutChecking(v, earg);
        }
        debug (LOG)
        {
            printf("interpreted arg[%u] = %s\n", cast(uint)i, earg.toChars());
            showCtfeExpr(earg);
        }
        debug (LOGASSIGN)
        {
            printf("interpreted arg[%u] = %s\n", cast(uint)i, earg.toChars());
            showCtfeExpr(earg);
        }
    }

    if (fd.vresult)
        ctfeGlobals.stack.push(fd.vresult);

    // Enter the function
    ++ctfeGlobals.callDepth;
    if (ctfeGlobals.callDepth > ctfeGlobals.maxCallDepth)
        ctfeGlobals.maxCallDepth = ctfeGlobals.callDepth;

    Expression e = null;
    while (1)
    {
        if (ctfeGlobals.callDepth > CTFE_RECURSION_LIMIT)
        {
            fdError("CTFE recursion limit exceeded");
            e = CTFEExp.cantexp;
            break;
        }
        e = interpretStatement(pue, fd.fbody, &istatex);
        if (CTFEExp.isCantExp(e))
        {
            debug (LOG)
            {
                printf("function body failed to interpret\n");
            }
        }

        if (istatex.start)
        {
            eSink.error(fd.loc, "%s `%s` CTFE internal error: failed to resume at statement `%s`", fd.kind, fd.toPrettyChars, istatex.start.toErrMsg());
            return CTFEExp.cantexp;
        }

        /* This is how we deal with a recursive statement AST
         * that has arbitrary goto statements in it.
         * Bubble up a 'result' which is the target of the goto
         * statement, then go recursively down the AST looking
         * for that statement, then execute starting there.
         */
        if (CTFEExp.isGotoExp(e))
        {
            istatex.start = istatex.gotoTarget; // set starting statement
            istatex.gotoTarget = null;
        }
        else
        {
            assert(!e || (e.op != EXP.continue_ && e.op != EXP.break_));
            break;
        }
    }
    // If fell off the end of a void function, return void
    if (!e)
    {
        if (tf.next.ty == Tvoid)
            e = CTFEExp.voidexp;
        else
        {
            /* missing a return statement can happen with C functions
             * https://issues.dlang.org/show_bug.cgi?id=23056
             */
            fdError("no return value from function");
            e = CTFEExp.cantexp;
        }
    }

    if (tf.isRef && e.op == EXP.variable && e.isVarExp().var == fd.vthis)
        e = thisarg;
    if (tf.isRef && fd.hasDualContext && e.op == EXP.index)
    {
        auto ie = e.isIndexExp();
        auto pe = ie.e1.isPtrExp();
        auto ve = !pe ?  null : pe.e1.isVarExp();
        if (ve && ve.var == fd.vthis)
        {
            auto ne = ie.e2.isIntegerExp();
            assert(ne);
            auto ale = thisarg.isAddrExp().e1.isArrayLiteralExp();
            e = ale[cast(size_t)ne.getInteger()];
            if (auto ae = e.isAddrExp())
            {
                e = ae.e1;
            }
        }
    }

    // Leave the function
    --ctfeGlobals.callDepth;

    ctfeGlobals.stack.endFrame();

    // If it generated an uncaught exception, report error.
    if (!istate && e.isThrownExceptionExp())
    {
        if (e == pue.exp())
            e = pue.copy();
        e.isThrownExceptionExp().generateUncaughtError();
        e = CTFEExp.cantexp;
    }

    return e;
}

/// used to collect coverage information in ctfe
void incUsageCtfe(InterState* istate, Loc loc)
{
    if (global.params.ctfe_cov && istate)
    {
        auto line = loc.linnum;
        auto mod = istate.fd.getModule();

        ++mod.ctfe_cov[line];
    }
}

/***********************************
 * Interpret the statement.
 * Params:
 *    s = Statement to interpret
 *    istate = context
 * Returns:
 *      NULL    continue to next statement
 *      EXP.cantExpression      cannot interpret statement at compile time
 *      !NULL   expression from return statement, or thrown exception
 */

Expression interpretStatement(Statement s, InterState* istate)
{
    UnionExp ue = void;
    auto result = interpretStatement(&ue, s, istate);
    if (result == ue.exp())
        result = ue.copy();
    return result;
}

///
Expression interpretStatement(UnionExp* pue, Statement s, InterState* istate)
{
    auto eSink = global.errorSink;
    Expression result;

    // If e is EXP.throw_exception or EXP.cantExpression,
    // set it to 'result' and returns true.
    bool exceptionOrCant(Expression e)
    {
        if (exceptionOrCantInterpret(e))
        {
            // Make sure e is not pointing to a stack temporary
            result = (e.op == EXP.cantExpression) ? CTFEExp.cantexp : e;
            return true;
        }
        return false;
    }

    /******************************** Statement ***************************/

    void visitDefaultCase(Statement s)
    {
        debug (LOG)
        {
            printf("%s Statement::interpret() %s\n", s.loc.toChars(), s.toChars());
        }
        if (istate.start)
        {
            if (istate.start != s)
                return;
            istate.start = null;
        }

        eSink.error(s.loc, "statement `%s` cannot be interpreted at compile time", s.toErrMsg());
        result = CTFEExp.cantexp;
    }

    void visitExp(ExpStatement s)
    {
        debug (LOG)
        {
            printf("%s ExpStatement::interpret(%s)\n", s.loc.toChars(), s.exp ? s.exp.toChars() : "");
        }
        if (istate.start)
        {
            if (istate.start != s)
                return;
            istate.start = null;
        }
        if (s.exp && s.exp.hasCode)
            incUsageCtfe(istate, s.loc);

        Expression e = interpret(pue, s.exp, istate, CTFEGoal.Nothing);
        if (exceptionOrCant(e))
            return;
    }

    void visitDtorExp(DtorExpStatement s)
    {
        visitExp(s);
    }

    void visitCompound(CompoundStatement s)
    {
        debug (LOG)
        {
            printf("%s CompoundStatement::interpret()\n", s.loc.toChars());
        }
        if (istate.start == s)
            istate.start = null;

        const dim = s.statements.length;
        foreach (i; 0 .. dim)
        {
            Statement sx = s.statements[i];
            result = interpretStatement(pue, sx, istate);
            if (result)
                break;
        }
        debug (LOG)
        {
            printf("%s -CompoundStatement::interpret() %p\n", s.loc.toChars(), result);
        }
    }

    void visitCompoundAsm(CompoundAsmStatement s)
    {
        visitCompound(s);
    }

    void visitUnrolledLoop(UnrolledLoopStatement s)
    {
        debug (LOG)
        {
            printf("%s UnrolledLoopStatement::interpret()\n", s.loc.toChars());
        }
        if (istate.start == s)
            istate.start = null;

        const dim = s.statements.length;
        foreach (i; 0 .. dim)
        {
            Statement sx = s.statements[i];
            Expression e = interpretStatement(pue, sx, istate);
            if (!e) // succeeds to interpret, or goto target was not found
                continue;
            if (exceptionOrCant(e))
                return;
            if (e.op == EXP.break_)
            {
                if (istate.gotoTarget && istate.gotoTarget != s)
                {
                    result = e; // break at a higher level
                    return;
                }
                istate.gotoTarget = null;
                result = null;
                return;
            }
            if (e.op == EXP.continue_)
            {
                if (istate.gotoTarget && istate.gotoTarget != s)
                {
                    result = e; // continue at a higher level
                    return;
                }
                istate.gotoTarget = null;
                continue;
            }

            // expression from return statement, or thrown exception
            result = e;
            break;
        }
    }

    void visitIf(IfStatement s)
    {
        debug (LOG)
        {
            printf("%s IfStatement::interpret(%s)\n", s.loc.toChars(), s.condition.toChars());
        }
        incUsageCtfe(istate, s.loc);
        if (istate.start == s)
            istate.start = null;
        if (istate.start)
        {
            Expression e = null;
            e = interpretStatement(s.ifbody, istate);
            if (!e && istate.start)
                e = interpretStatement(s.elsebody, istate);
            result = e;
            return;
        }

        UnionExp ue = void;
        Expression e = interpret(&ue, s.condition, istate);
        assert(e);
        if (exceptionOrCant(e))
            return;

        if (isTrueBool(e))
            result = interpretStatement(pue, s.ifbody, istate);
        else if (e.toBool().hasValue(false))
            result = interpretStatement(pue, s.elsebody, istate);
        else
        {
            // no error, or assert(0)?
            result = CTFEExp.cantexp;
        }
    }

    void visitScope(ScopeStatement s)
    {
        debug (LOG)
        {
            printf("%s ScopeStatement::interpret()\n", s.loc.toChars());
        }
        if (istate.start == s)
            istate.start = null;

        result = interpretStatement(pue, s.statement, istate);
    }

    void visitReturn(ReturnStatement s)
    {
        debug (LOG)
        {
            printf("%s ReturnStatement::interpret(%s)\n", s.loc.toChars(), s.exp ? s.exp.toChars() : "");
        }
        if (istate.start)
        {
            if (istate.start != s)
                return;
            istate.start = null;
        }

        if (!s.exp)
        {
            result = CTFEExp.voidexp;
            return;
        }

        incUsageCtfe(istate, s.loc);
        assert(istate && istate.fd && istate.fd.type && istate.fd.type.ty == Tfunction);
        TypeFunction tf = cast(TypeFunction)istate.fd.type;

        /* If the function returns a ref AND it's been called from an assignment,
         * we need to return an lvalue. Otherwise, just do an (rvalue) interpret.
         */
        if (tf.isRef)
        {
            result = interpret(pue, s.exp, istate, CTFEGoal.LValue);
            return;
        }
        if (tf.next && tf.next.ty == Tdelegate && istate.fd.closureVars.length > 0)
        {
            // To support this, we need to copy all the closure vars
            // into the delegate literal.
            eSink.error(s.loc, "closures are not yet supported in CTFE");
            result = CTFEExp.cantexp;
            return;
        }

        /* Hand a slice return value over as a linear handle instead of
         * materializing an AST array, when the caller asked for it (see
         * CtfeGlobals.linearReturnDest). Payloads live in the heap arena,
         * so the handle stays valid after this frame is popped. Semantics
         * match the AST path: a return does not copy CTFE-owned literals,
         * so both representations return a live reference to the same
         * array object.
         */
        if (istate.returnSlice)
        {
            if (auto ve = s.exp.isVarExp())
            {
                if (auto v = ve.var.isVarDeclaration())
                {
                    const slot = ctfeGlobals.stack.sliceSlot(v);
                    LinearSlice lsl;
                    if (!slot.isNull && readSlice(ctfeGlobals.linearMem, slot, lsl))
                    {
                        istate.returnSlice.slice = lsl;
                        istate.returnSlice.set = true;
                        result = CTFEExp.voidexp;
                        return;
                    }
                }
            }
            else if (s.exp.op == EXP.call)
            {
                // `return f(...)`: let the inner call return through the
                // same channel (e.g. thin wrappers around builders)
                ctfeGlobals.linearReturnDest = istate.returnSlice;
                Expression ce = interpret(pue, s.exp, istate);
                ctfeGlobals.linearReturnDest = null;
                if (exceptionOrCant(ce))
                    return;
                if (istate.returnSlice.set)
                {
                    result = CTFEExp.voidexp;
                    return;
                }
                // The inner call produced a normal value; finish like the
                // generic path below
                if (!stopPointersEscaping(s.loc, ce))
                {
                    result = CTFEExp.cantexp;
                    return;
                }
                if (needToCopyLiteral(ce))
                    ce = copyLiteral(ce).copy();
                result = ce;
                return;
            }
        }

        // We need to treat pointers specially, because EXP.symbolOffset can be used to
        // return a value OR a pointer
        Expression e = interpret(pue, s.exp, istate);
        if (exceptionOrCant(e))
            return;

        /**
         * Interpret `return a ~= b` (i.e. `return _d_arrayappendT(a, b)`) as:
         *     a ~= b;
         *     return a;
         * This is needed because `a ~= b` has to be interpreted as an lvalue, in order to avoid
         * assigning a larger array into a smaller one, such as:
         *    `a = [1, 2], a ~= [3]` => `[1, 2] ~= [3]` => `[1, 2] = [1, 2, 3]`
         */

        // Disallow returning pointers to stack-allocated variables (bug 7876)
        if (!stopPointersEscaping(s.loc, e))
        {
            result = CTFEExp.cantexp;
            return;
        }

        if (needToCopyLiteral(e))
            e = copyLiteral(e).copy();
        debug (LOGASSIGN)
        {
            printf("RETURN %s\n", s.loc.toChars());
            showCtfeExpr(e);
        }
        result = e;
    }

    void visitBreak(BreakStatement s)
    {
        debug (LOG)
        {
            printf("%s BreakStatement::interpret()\n", s.loc.toChars());
        }
        incUsageCtfe(istate, s.loc);
        if (istate.start)
        {
            if (istate.start != s)
                return;
            istate.start = null;
        }

        istate.gotoTarget = findGotoTarget(istate, s.ident);
        result = CTFEExp.breakexp;
    }

    void visitContinue(ContinueStatement s)
    {
        debug (LOG)
        {
            printf("%s ContinueStatement::interpret()\n", s.loc.toChars());
        }
        incUsageCtfe(istate, s.loc);
        if (istate.start)
        {
            if (istate.start != s)
                return;
            istate.start = null;
        }

        istate.gotoTarget = findGotoTarget(istate, s.ident);
        result = CTFEExp.continueexp;
    }

    void visitWhile(WhileStatement s)
    {
        debug (LOG)
        {
            printf("WhileStatement::interpret()\n");
        }
        assert(0); // rewritten to ForStatement
    }

    void visitDo(DoStatement s)
    {
        debug (LOG)
        {
            printf("%s DoStatement::interpret()\n", s.loc.toChars());
        }
        if (istate.start == s)
            istate.start = null;

        while (1)
        {
            Expression e = interpretStatement(s._body, istate);
            if (!e && istate.start) // goto target was not found
                return;
            assert(!istate.start);

            if (exceptionOrCant(e))
                return;
            if (e && e.op == EXP.break_)
            {
                if (istate.gotoTarget && istate.gotoTarget != s)
                {
                    result = e; // break at a higher level
                    return;
                }
                istate.gotoTarget = null;
                break;
            }
            if (e && e.op == EXP.continue_)
            {
                if (istate.gotoTarget && istate.gotoTarget != s)
                {
                    result = e; // continue at a higher level
                    return;
                }
                istate.gotoTarget = null;
                e = null;
            }
            if (e)
            {
                result = e; // bubbled up from ReturnStatement
                return;
            }

            UnionExp ue = void;
            incUsageCtfe(istate, s.condition.loc);
            e = interpret(&ue, s.condition, istate);
            if (exceptionOrCant(e))
                return;
            if (!e.isConst())
            {
                result = CTFEExp.cantexp;
                return;
            }
            if (e.toBool().hasValue(false))
                break;
            assert(isTrueBool(e));
        }
        assert(result is null);
    }

    void visitFor(ForStatement s)
    {
        debug (LOG)
        {
            printf("%s ForStatement::interpret()\n", s.loc.toChars());
        }
        if (istate.start == s)
            istate.start = null;

        UnionExp ueinit = void;
        Expression ei = interpretStatement(&ueinit, s._init, istate);
        if (exceptionOrCant(ei))
            return;
        assert(!ei); // s.init never returns from function, or jumps out from it

        while (1)
        {
            if (s.condition && !istate.start)
            {
                UnionExp ue = void;
                incUsageCtfe(istate, s.condition.loc);
                Expression e = interpret(&ue, s.condition, istate);
                if (exceptionOrCant(e))
                    return;
                if (e.toBool().hasValue(false))
                    break;
                assert(isTrueBool(e));
            }

            Expression e = interpretStatement(pue, s._body, istate);
            if (!e && istate.start) // goto target was not found
                return;
            assert(!istate.start);

            if (exceptionOrCant(e))
                return;
            if (e && e.op == EXP.break_)
            {
                if (istate.gotoTarget && istate.gotoTarget != s)
                {
                    result = e; // break at a higher level
                    return;
                }
                istate.gotoTarget = null;
                break;
            }
            if (e && e.op == EXP.continue_)
            {
                if (istate.gotoTarget && istate.gotoTarget != s)
                {
                    result = e; // continue at a higher level
                    return;
                }
                istate.gotoTarget = null;
                e = null;
            }
            if (e)
            {
                result = e; // bubbled up from ReturnStatement
                return;
            }

            UnionExp uei = void;
            if (s.increment)
                incUsageCtfe(istate, s.increment.loc);
            e = interpret(&uei, s.increment, istate, CTFEGoal.Nothing);
            if (exceptionOrCant(e))
                return;
        }
        assert(result is null);
    }

    void visitForeach(ForeachStatement s)
    {
        assert(0); // rewritten to ForStatement
    }

    void visitForeachRange(ForeachRangeStatement s)
    {
        assert(0); // rewritten to ForStatement
    }

    void visitSwitch(SwitchStatement s)
    {
        debug (LOG)
        {
            printf("%s SwitchStatement::interpret()\n", s.loc.toChars());
        }
        incUsageCtfe(istate, s.loc);
        if (istate.start == s)
            istate.start = null;
        if (istate.start)
        {
            Expression e = interpretStatement(s._body, istate);
            if (istate.start) // goto target was not found
                return;
            if (exceptionOrCant(e))
                return;
            if (e && e.op == EXP.break_)
            {
                if (istate.gotoTarget && istate.gotoTarget != s)
                {
                    result = e; // break at a higher level
                    return;
                }
                istate.gotoTarget = null;
                e = null;
            }
            result = e;
            return;
        }

        UnionExp uecond = void;
        Expression econdition = interpret(&uecond, s.condition, istate);
        if (exceptionOrCant(econdition))
            return;

        Statement scase = null;
        if (s.cases)
            foreach (cs; *s.cases)
            {
                UnionExp uecase = void;
                Expression ecase = interpret(&uecase, cs.exp, istate);
                if (exceptionOrCant(ecase))
                    return;
                if (ctfeEqual(cs.exp.loc, EXP.equal, econdition, ecase))
                {
                    scase = cs;
                    break;
                }
            }
        if (!scase)
        {
            if (!s.hasDefault)
            {
                eSink.error(s.loc, "no `default` or `case` for `%s` in `switch` statement", econdition.toErrMsg());
                result = CTFEExp.cantexp;
                return;
            }
            scase = s.sdefault;
        }

        assert(scase);

        /* Jump to scase
         */
        istate.start = scase;
        Expression e = interpretStatement(pue, s._body, istate);
        assert(!istate.start); // jump must not fail
        if (e && e.op == EXP.break_)
        {
            if (istate.gotoTarget && istate.gotoTarget != s)
            {
                result = e; // break at a higher level
                return;
            }
            istate.gotoTarget = null;
            e = null;
        }
        result = e;
    }

    void visitCase(CaseStatement s)
    {
        debug (LOG)
        {
            printf("%s CaseStatement::interpret(%s) this = %p\n", s.loc.toChars(), s.exp.toChars(), s);
        }
        incUsageCtfe(istate, s.loc);
        if (istate.start == s)
            istate.start = null;

        result = interpretStatement(pue, s.statement, istate);
    }

    void visitDefault(DefaultStatement s)
    {
        debug (LOG)
        {
            printf("%s DefaultStatement::interpret()\n", s.loc.toChars());
        }
        incUsageCtfe(istate, s.loc);
        if (istate.start == s)
            istate.start = null;

        result = interpretStatement(pue, s.statement, istate);
    }

    void visitGoto(GotoStatement s)
    {
        debug (LOG)
        {
            printf("%s GotoStatement::interpret()\n", s.loc.toChars());
        }
        if (istate.start)
        {
            if (istate.start != s)
                return;
            istate.start = null;
        }
        incUsageCtfe(istate, s.loc);

        assert(s.label && s.label.statement);
        istate.gotoTarget = s.label.statement;
        result = CTFEExp.gotoexp;
    }

    void visitGotoCase(GotoCaseStatement s)
    {
        debug (LOG)
        {
            printf("%s GotoCaseStatement::interpret()\n", s.loc.toChars());
        }
        if (istate.start)
        {
            if (istate.start != s)
                return;
            istate.start = null;
        }
        incUsageCtfe(istate, s.loc);

        assert(s.cs);
        istate.gotoTarget = s.cs;
        result = CTFEExp.gotoexp;
    }

    void visitGotoDefault(GotoDefaultStatement s)
    {
        debug (LOG)
        {
            printf("%s GotoDefaultStatement::interpret()\n", s.loc.toChars());
        }
        if (istate.start)
        {
            if (istate.start != s)
                return;
            istate.start = null;
        }
        incUsageCtfe(istate, s.loc);

        assert(s.sw && s.sw.sdefault);
        istate.gotoTarget = s.sw.sdefault;
        result = CTFEExp.gotoexp;
    }

    void visitLabel(LabelStatement s)
    {
        debug (LOG)
        {
            printf("%s LabelStatement::interpret()\n", s.loc.toChars());
        }
        if (istate.start == s)
            istate.start = null;

        result = interpretStatement(pue, s.statement, istate);
    }

    void visitTryCatch(TryCatchStatement s)
    {
        debug (LOG)
        {
            printf("%s TryCatchStatement::interpret()\n", s.loc.toChars());
        }
        if (istate.start == s)
            istate.start = null;
        if (istate.start)
        {
            Expression e = null;
            e = interpretStatement(pue, s._body, istate);
            foreach (ca; *s.catches)
            {
                if (e || !istate.start) // goto target was found
                    break;
                e = interpretStatement(pue, ca.handler, istate);
            }
            result = e;
            return;
        }

        Expression e = interpretStatement(s._body, istate);

        // An exception was thrown
        if (e && e.isThrownExceptionExp())
        {
            ThrownExceptionExp ex = e.isThrownExceptionExp();
            Type extype = ex.thrown.originalClass().type;

            // Search for an appropriate catch clause.
            foreach (ca; *s.catches)
            {
                Type catype = ca.type;
                import dmd.typesem : isBaseOf;
                if (!catype.equals(extype) && !catype.isBaseOf(extype, null))
                    continue;

                // Execute the handler
                if (ca.var)
                {
                    ctfeGlobals.stack.push(ca.var);
                    setValue(ca.var, ex.thrown);
                }
                e = interpretStatement(ca.handler, istate);
                while (CTFEExp.isGotoExp(e))
                {
                    /* This is an optimization that relies on the locality of the jump target.
                     * If the label is in the same catch handler, the following scan
                     * would find it quickly and can reduce jump cost.
                     * Otherwise, the catch block may be unnnecessary scanned again
                     * so it would make CTFE speed slower.
                     */
                    InterState istatex = *istate;
                    istatex.start = istate.gotoTarget; // set starting statement
                    istatex.gotoTarget = null;
                    Expression eh = interpretStatement(ca.handler, &istatex);
                    if (istatex.start)
                    {
                        // The goto target is outside the current scope.
                        break;
                    }
                    // The goto target was within the body.
                    if (CTFEExp.isCantExp(eh))
                    {
                        e = eh;
                        break;
                    }
                    *istate = istatex;
                    e = eh;
                }
                break;
            }
        }
        result = e;
    }

    void visitTryFinally(TryFinallyStatement s)
    {
        debug (LOG)
        {
            printf("%s TryFinallyStatement::interpret()\n", s.loc.toChars());
        }
        if (istate.start == s)
            istate.start = null;
        if (istate.start)
        {
            Expression e = null;
            e = interpretStatement(pue, s._body, istate);
            // Jump into/out from finalbody is disabled in semantic analysis.
            // and jump inside will be handled by the ScopeStatement == finalbody.
            result = e;
            return;
        }

        Expression ex = interpretStatement(s._body, istate);
        if (CTFEExp.isCantExp(ex))
        {
            result = ex;
            return;
        }
        while (CTFEExp.isGotoExp(ex))
        {
            // If the goto target is within the body, we must not interpret the finally statement,
            // because that will call destructors for objects within the scope, which we should not do.
            InterState istatex = *istate;
            istatex.start = istate.gotoTarget; // set starting statement
            istatex.gotoTarget = null;
            Expression bex = interpretStatement(s._body, &istatex);
            if (istatex.start)
            {
                // The goto target is outside the current scope.
                break;
            }
            // The goto target was within the body.
            if (CTFEExp.isCantExp(bex))
            {
                result = bex;
                return;
            }
            *istate = istatex;
            ex = bex;
        }

        Expression ey = interpretStatement(s.finalbody, istate);
        if (CTFEExp.isCantExp(ey))
        {
            result = ey;
            return;
        }
        if (ey && ey.isThrownExceptionExp())
        {
            // Check for collided exceptions
            if (ex && ex.isThrownExceptionExp())
                ex = chainExceptions(ex.isThrownExceptionExp(), ey.isThrownExceptionExp());
            else
                ex = ey;
        }
        result = ex;
    }

    void visitThrow(ThrowStatement s)
    {
        debug (LOG)
        {
            printf("%s ThrowStatement::interpret()\n", s.loc.toChars());
        }
        if (istate.start)
        {
            if (istate.start != s)
                return;
            istate.start = null;
        }

        interpretThrow(result, s.exp, s.loc, istate);
    }

    void visitScopeGuard(ScopeGuardStatement s)
    {
        assert(0);
    }

    void visitWith(WithStatement s)
    {
        debug (LOG)
        {
            printf("%s WithStatement::interpret()\n", s.loc.toChars());
        }
        if (istate.start == s)
            istate.start = null;
        if (istate.start)
        {
            result = s._body ? interpretStatement(s._body, istate) : null;
            return;
        }

        // If it is with(Enum) {...}, just execute the body.
        if (s.exp.op == EXP.scope_ || s.exp.op == EXP.type)
        {
            result = interpretStatement(pue, s._body, istate);
            return;
        }

        incUsageCtfe(istate, s.loc);

        Expression e = interpret(s.exp, istate);
        if (exceptionOrCant(e))
            return;

        if (s.wthis.type.ty == Tpointer && s.exp.type.ty != Tpointer)
        {
            e = ctfeEmplaceExp!AddrExp(s.loc, e, s.wthis.type);
        }
        ctfeGlobals.stack.push(s.wthis);
        setValue(s.wthis, e);
        e = interpretStatement(s._body, istate);
        while (CTFEExp.isGotoExp(e))
        {
            /* This is an optimization that relies on the locality of the jump target.
             * If the label is in the same WithStatement, the following scan
             * would find it quickly and can reduce jump cost.
             * Otherwise, the statement body may be unnnecessary scanned again
             * so it would make CTFE speed slower.
             */
            InterState istatex = *istate;
            istatex.start = istate.gotoTarget; // set starting statement
            istatex.gotoTarget = null;
            Expression ex = interpretStatement(s._body, &istatex);
            if (istatex.start)
            {
                // The goto target is outside the current scope.
                break;
            }
            // The goto target was within the body.
            if (CTFEExp.isCantExp(ex))
            {
                e = ex;
                break;
            }
            *istate = istatex;
            e = ex;
        }
        ctfeGlobals.stack.pop(s.wthis);
        result = e;
    }

    void visitAsm(AsmStatement s)
    {
        debug (LOG)
        {
            printf("%s AsmStatement::interpret()\n", s.loc.toChars());
        }
        if (istate.start)
        {
            if (istate.start != s)
                return;
            istate.start = null;
        }
        eSink.error(s.loc, "`asm` statements cannot be interpreted at compile time");
        result = CTFEExp.cantexp;
    }

    void visitInlineAsm(InlineAsmStatement s)
    {
        visitAsm(s);
    }

    void visitGccAsm(GccAsmStatement s)
    {
        visitAsm(s);
    }

    void visitImport(ImportStatement s)
    {
        debug (LOG)
        {
            printf("ImportStatement::interpret()\n");
        }
        if (istate.start)
        {
            if (istate.start != s)
                return;
            istate.start = null;
        }
    }

    if (!s)
        return null;

    mixin VisitStatement!void visit;
    visit.VisitStatement(s);
    return result;
}

///

private extern (C++) final class Interpreter : Visitor
{
    alias visit = Visitor.visit;
public:
    InterState* istate;
    CTFEGoal goal;
    Expression result;
    UnionExp* pue;              // storage for `result`
    ErrorSink eSink;            // sink for error messages

    extern (D) this(UnionExp* pue, InterState* istate, CTFEGoal goal) scope
    {
        this.pue = pue;
        this.istate = istate;
        this.goal = goal;
	this.eSink = global.errorSink;
    }

    // If e is EXP.throw_exception or EXP.cantExpression,
    // set it to 'result' and returns true.
    bool exceptionOrCant(Expression e)
    {
        if (exceptionOrCantInterpret(e))
        {
            // Make sure e is not pointing to a stack temporary
            result = (e.op == EXP.cantExpression) ? CTFEExp.cantexp : e;
            return true;
        }
        return false;
    }

    /******************************** Expression ***************************/

    override void visit(Expression e)
    {
        debug (LOG)
        {
            printf("%s Expression::interpret() '%s' %s\n", e.loc.toChars(), EXPtoString(e.op).ptr, e.toChars());
            printf("type = %s\n", e.type.toChars());
            showCtfeExpr(e);
        }
        eSink.error(e.loc, "cannot interpret `%s` at compile time", e.toErrMsg());
        result = CTFEExp.cantexp;
    }

    override void visit(TypeExp e)
    {
        debug (LOG)
        {
            printf("%s TypeExp.interpret() %s\n", e.loc.toChars(), e.toChars());
        }
        result = e;
    }

    override void visit(ThisExp e)
    {
        debug (LOG)
        {
            printf("%s ThisExp::interpret() %s\n", e.loc.toChars(), e.toChars());
        }
        if (goal == CTFEGoal.LValue)
        {
            // We might end up here with istate being zero
            // https://issues.dlang.org/show_bug.cgi?id=16382
            if (istate && istate.fd.vthis)
            {
                result = ctfeEmplaceExp!VarExp(e.loc, istate.fd.vthis);
                if (istate.fd.hasDualContext)
                {
                    result = ctfeEmplaceExp!PtrExp(e.loc, result);
                    result.type = Type.tvoidptr.sarrayOf(2);
                    result = ctfeEmplaceExp!IndexExp(e.loc, result, IntegerExp.literal!0);
                }
                result.type = e.type;
            }
            else
                result = e;
            return;
        }

        result = ctfeGlobals.stack.getThis();
        if (result)
        {
            if (istate && istate.fd.hasDualContext)
            {
                assert(result.op == EXP.address);
                result = result.isAddrExp().e1;
                assert(result.op == EXP.arrayLiteral);
                auto ale = result.isArrayLiteralExp();
                result = ale[0];
                if (e.type.ty == Tstruct)
                {
                    result = result.isAddrExp().e1;
                }
                return;
            }
            assert(result.op == EXP.structLiteral || result.op == EXP.classReference || result.op == EXP.type);
            return;
        }
        eSink.error(e.loc, "value of `this` is not known at compile time");
        result = CTFEExp.cantexp;
    }

    override void visit(NullExp e)
    {
        result = e;
    }

    override void visit(IntegerExp e)
    {
        debug (LOG)
        {
            printf("%s IntegerExp::interpret() %s\n", e.loc.toChars(), e.toChars());
        }
        result = e;
    }

    override void visit(RealExp e)
    {
        debug (LOG)
        {
            printf("%s RealExp::interpret() %s\n", e.loc.toChars(), e.toChars());
        }
        result = e;
    }

    override void visit(ComplexExp e)
    {
        result = e;
    }

    override void visit(StringExp e)
    {
        debug (LOG)
        {
            printf("%s StringExp::interpret() %s\n", e.loc.toChars(), e.toChars());
        }
        if (e.ownedByCtfe >= OwnedBy.ctfe) // We've already interpreted the string
        {
            result = e;
            return;
        }

        if (e.type.ty != Tsarray ||
            (cast(TypeNext)e.type).next.mod & (MODFlags.const_ | MODFlags.immutable_))
        {
            // If it's immutable, we don't need to dup it. Attempts to modify
            // string literals are prevented in BinExp::interpretAssignCommon.
            result = e;
        }
        else
        {
            // https://issues.dlang.org/show_bug.cgi?id=20811
            // Create a copy of mutable string literals, so that any change in
            // value via an index or slice will not survive CTFE.
            *pue = copyLiteral(e);
            result = pue.exp();
        }
    }

    override void visit(FuncExp e)
    {
        debug (LOG)
        {
            printf("%s FuncExp::interpret() %s\n", e.loc.toChars(), e.toChars());
        }
        result = e;
    }

    override void visit(SymOffExp e)
    {
        debug (LOG)
        {
            printf("%s SymOffExp::interpret() %s\n", e.loc.toChars(), e.toChars());
        }
        if (e.var.isFuncDeclaration() && e.offset == 0)
        {
            result = e;
            return;
        }
        if (isTypeInfo_Class(e.type) && e.offset == 0)
        {
            result = e;
            return;
        }
        if (e.type.ty != Tpointer)
        {
            // Probably impossible
            eSink.error(e.loc, "cannot interpret `%s` at compile time", e.toErrMsg());
            result = CTFEExp.cantexp;
            return;
        }
        Type pointee = (cast(TypePointer)e.type).next;
        if (e.var.isThreadlocal())
        {
            eSink.error(e.loc, "cannot take address of thread-local variable %s at compile time", e.var.toErrMsg());
            result = CTFEExp.cantexp;
            return;
        }
        // Check for taking an address of a shared variable.
        // If the shared variable is an array, the offset might not be zero.
        Type fromType = null;
        if (e.var.type.isStaticOrDynamicArray())
        {
            fromType = (cast(TypeArray)e.var.type).next;
        }
        if (e.var.isDataseg() && ((e.offset == 0 && isSafePointerCast(e.var.type, pointee)) ||
                                  (fromType && isSafePointerCast(fromType, pointee)) ||
                                  (e.var.isCsymbol() && e.offset + pointee.size() <= e.var.type.size())))
        {
            result = e;
            return;
        }

        Expression val = getVarExp(e.loc, istate, e.var, goal);
        if (exceptionOrCant(val))
            return;
        if (val.type.isStaticOrDynamicArray())
        {
            // Check for unsupported type painting operations
            Type elemtype = (cast(TypeArray)val.type).next;
            const elemsize = elemtype.size();

            // It's OK to cast from fixed length to fixed length array, eg &int[n] to int[d]*.
            if (val.type.ty == Tsarray && pointee.ty == Tsarray && elemsize == pointee.nextOf().size())
            {
                size_t d = cast(size_t)(cast(TypeSArray)pointee).dim.toInteger();
                Expression elwr = ctfeEmplaceExp!IntegerExp(e.loc, e.offset / elemsize, Type.tsize_t);
                Expression eupr = ctfeEmplaceExp!IntegerExp(e.loc, e.offset / elemsize + d, Type.tsize_t);

                // Create a CTFE pointer &val[ofs..ofs+d]
                auto se = ctfeEmplaceExp!SliceExp(e.loc, val, elwr, eupr);
                se.type = pointee;
                emplaceExp!(AddrExp)(pue, e.loc, se, e.type);
                result = pue.exp();
                return;
            }

            if (!isSafePointerCast(elemtype, pointee))
            {
                // It's also OK to cast from &string to string*.
                if (e.offset == 0 && isSafePointerCast(e.var.type, pointee))
                {
                    // Create a CTFE pointer &var
                    auto ve = ctfeEmplaceExp!VarExp(e.loc, e.var);
                    ve.type = elemtype;
                    emplaceExp!(AddrExp)(pue, e.loc, ve, e.type);
                    result = pue.exp();
                    return;
                }
                eSink.error(e.loc, "reinterpreting cast from `%s` to `%s` is not supported in CTFE", val.type.toErrMsg(), e.type.toErrMsg());
                result = CTFEExp.cantexp;
                return;
            }

            const dinteger_t sz = pointee.size();
            dinteger_t indx = e.offset / sz;
            assert(sz * indx == e.offset);
            Expression aggregate = null;
            if (val.op == EXP.arrayLiteral || val.op == EXP.string_)
            {
                aggregate = val;
            }
            else if (auto se = val.isSliceExp())
            {
                aggregate = se.e1;
                UnionExp uelwr = void;
                Expression lwr = interpret(&uelwr, se.lwr, istate);
                indx += lwr.toInteger();
            }
            if (aggregate)
            {
                // Create a CTFE pointer &aggregate[ofs]
                auto ofs = ctfeEmplaceExp!IntegerExp(e.loc, indx, Type.tsize_t);
                auto ei = ctfeEmplaceExp!IndexExp(e.loc, aggregate, ofs);
                ei.type = elemtype;
                emplaceExp!(AddrExp)(pue, e.loc, ei, e.type);
                result = pue.exp();
                return;
            }
        }
        else if (e.offset == 0 && isSafePointerCast(e.var.type, pointee))
        {
            // Create a CTFE pointer &var
            auto ve = ctfeEmplaceExp!VarExp(e.loc, e.var);
            ve.type = e.var.type;
            emplaceExp!(AddrExp)(pue, e.loc, ve, e.type);
            result = pue.exp();
            return;
        }

        eSink.error(e.loc, "cannot convert `&%s` to `%s` at compile time", e.var.type.toErrMsg(), e.type.toErrMsg());
        result = CTFEExp.cantexp;
    }

    override void visit(AddrExp e)
    {
        debug (LOG)
        {
            printf("%s AddrExp::interpret() %s\n", e.loc.toChars(), e.toChars());
        }
        if (auto ve = e.e1.isVarExp())
        {
            Declaration decl = ve.var;

            // We cannot take the address of an imported symbol at compile time
            if (decl.isImportedSymbol())
            {
                eSink.error(e.loc, "cannot take address of imported symbol `%s` at compile time", decl.toErrMsg());
                result = CTFEExp.cantexp;
                return;
            }

            if (decl.isDataseg())
            {
                // Normally this is already done by optimize()
                // Do it here in case optimize(WANTvalue) wasn't run before CTFE
                emplaceExp!(SymOffExp)(pue, e.loc, e.e1.isVarExp().var, 0);
                result = pue.exp();
                result.type = e.type;
                return;
            }
        }
        auto er = interpret(e.e1, istate, CTFEGoal.LValue);
        if (auto ve = er.isVarExp())
            if (istate && ve.var == istate.fd.vthis)
                er = interpret(er, istate);

        if (exceptionOrCant(er))
            return;

        // A reference into a linear slice keeps the variable as aggregate,
        // but pointer arithmetic needs an array literal to point into:
        // materialize the array and rebase the reference on it
        if (global.params.ctfeLinearMemory)
        {
            if (auto ie = er.isIndexExp())
                if (auto bve = ie.e1.isVarExp())
                    if (bve.type.toBasetype().ty == Tarray && ie.e2.op == EXP.int64)
                        if (auto v = bve.var.isVarDeclaration())
                        {
                            if (Expression ev = getValue(v)) // flips to AST
                            {
                                uinteger_t ofs = ie.e2.toInteger();
                                if (auto se = ev.isSliceExp())
                                {
                                    ofs += se.lwr.toInteger();
                                    ev = se.e1;
                                }
                                auto ei = ctfeEmplaceExp!IntegerExp(ie.e2.loc, ofs, Type.tsize_t);
                                auto nie = ctfeEmplaceExp!IndexExp(ie.loc, ev, ei);
                                nie.type = ie.type;
                                er = nie;
                            }
                        }
        }

        // Return a simplified address expression
        emplaceExp!(AddrExp)(pue, e.loc, er, e.type);
        result = pue.exp();
    }

    override void visit(DelegateExp e)
    {
        debug (LOG)
        {
            printf("%s DelegateExp::interpret() %s\n", e.loc.toChars(), e.toChars());
        }
        // TODO: Really we should create a CTFE-only delegate expression
        // of a pointer and a funcptr.

        // If it is &nestedfunc, just return it
        // TODO: We should save the context pointer
        if (auto ve1 = e.e1.isVarExp())
            if (ve1.var == e.func)
            {
                result = e;
                return;
            }

        auto er = interpret(pue, e.e1, istate);
        if (exceptionOrCant(er))
            return;
        if (er == e.e1)
        {
            // If it has already been CTFE'd, just return it
            result = e;
        }
        else
        {
            er = (er == pue.exp()) ? pue.copy() : er;
            emplaceExp!(DelegateExp)(pue, e.loc, er, e.func, false);
            result = pue.exp();
            result.type = e.type;
        }
    }

    static Expression interpretInitializerExpression(VarDeclaration v)
    {
        // It is a bit strange that the interpreter has to deal with initializers
        // at all as they should have been converted to ConstructExp or similar
        // during semantic analysis.
        // Static array initialization from an element expression is a special
        // case that used to be dealt with in initializerToExpression(), but
        // is duplicated in ExpressionSemanticVisitor.visit(AssignExp exp). Until
        // initializer semantics are removed from the interpreter, it has been
        // moved here.
        Expression iexp = v._init.initializerToExpression(v.type);

        Type tb = v.type.toBasetype();
        Expression e = (iexp.op == EXP.construct || iexp.op == EXP.blit) ? (cast(AssignExp)iexp).e2 : iexp;
        if (tb.ty == Tsarray && e.implicitConvTo(tb.nextOf()))
        {
            TypeSArray tsa = cast(TypeSArray)tb;
            size_t d = cast(size_t)tsa.dim.toInteger();
            auto elements = new Expressions(d);
            for (size_t j = 0; j < d; j++)
                (*elements)[j] = e;
            auto ae = new ArrayLiteralExp(e.loc, v.type, elements);
            return ae;
        }
        return iexp;
    }

    Expression getVarExp(Loc loc, InterState* istate, Declaration d, CTFEGoal goal)
    {
        Expression e = CTFEExp.cantexp;
        if (VarDeclaration v = d.isVarDeclaration())
        {
            /* Magic variable __ctfe always returns true when interpreting
             */
            if (v.ident == Id.ctfe)
                return IntegerExp.createBool(true);

            if (!v.originalType && v.semanticRun < PASS.semanticdone) // semantic() not yet run
            {
                v.dsymbolSemantic(null);
                if (v.type.ty == Terror)
                    return CTFEExp.cantexp;
            }

            if ((v.isConst() || v.isImmutable() || v.storage_class & STC.manifest) && !hasValue(v) && v._init && !v.isCTFE())
            {
                if (v.inuse)
                {
                    eSink.error(loc, "circular initialization of %s `%s`", v.kind(), v.toPrettyChars());
                    return CTFEExp.cantexp;
                }
                if (v._scope)
                {
                    v.inuse++;
                    v._init = v._init.initializerSemantic(v._scope, v.type, INITinterpret, global.errorSink); // might not be run on aggregate members
                    v.inuse--;
                }
                e = interpretInitializerExpression(v);
                if (!e)
                    return CTFEExp.cantexp;
                assert(e.type);

                // There's a terrible hack in `dmd.dsymbolsem` that special case
                // a struct with all zeros to an `ExpInitializer(BlitExp(IntegerExp(0)))`
                // There's matching code for it in e2ir (toElem's visitAssignExp),
                // so we need the same hack here.
                // This does not trigger for global as they get a normal initializer.
                if (auto ts = e.type.isTypeStruct())
                    if (auto ae = e.isBlitExp())
                        if (ae.e2.op == EXP.int64)
                            e = ts.defaultInitLiteral(loc);

                if (e.op == EXP.construct || e.op == EXP.blit)
                {
                    AssignExp ae = cast(AssignExp)e;
                    e = ae.e2;
                }

                if (e.op == EXP.error)
                {
                    // FIXME: Ultimately all errors should be detected in prior semantic analysis stage.
                }
                else if (v.isDataseg() || (v.storage_class & STC.manifest))
                {
                    /* https://issues.dlang.org/show_bug.cgi?id=14304
                     * e is a value that is not yet owned by CTFE.
                     * Mark as "cached", and use it directly during interpretation.
                     */
                    e = scrubCacheValue(e);
                    ctfeGlobals.stack.saveGlobalConstant(v, e);
                }
                else
                {
                    v.inuse++;
                    e = interpret(e, istate);
                    v.inuse--;
                    if (CTFEExp.isCantExp(e) && !global.gag && !ctfeGlobals.stackTraceCallsToSuppress)
                        eSink.errorSupplemental(loc, "while evaluating %s.init", v.toChars());
                    if (exceptionOrCantInterpret(e))
                        return e;
                }
            }
            else if (v.isCTFE() && !hasValue(v))
            {
                if (v._init && v.type.size() != 0)
                {
                    if (v._init.isVoidInitializer())
                    {
                        // var should have been initialized when it was created
                        eSink.error(loc, "CTFE internal error: trying to access uninitialized var");
                        assert(0);
                    }
                    e = v._init.initializerToExpression();
                }
                else
                    // Zero-length arrays don't have an initializer
                    e = v.type.defaultInitLiteral(e.loc);

                e = interpret(e, istate);
            }
            else if (!(v.isDataseg() || v.storage_class & STC.manifest) && !v.isCTFE() && !istate)
            {
                eSink.error(loc, "variable `%s` cannot be read at compile time", v.toErrMsg());
                return CTFEExp.cantexp;
            }
            else
            {
                e = hasValue(v) ? getValue(v) : null;
                if (!e)
                {
                    // Zero-length arrays don't have an initializer
                    if (v.type.size() == 0)
                        e = v.type.defaultInitLiteral(loc);
                    else if (!v.isCTFE() && v.isDataseg())
                    {
                        eSink.error(loc, "static variable `%s` cannot be read at compile time", v.toErrMsg());
                        return CTFEExp.cantexp;
                    }
                    else
                    {
                        assert(!(v._init && v._init.isVoidInitializer()));
                        // CTFE initiated from inside a function
                        eSink.error(loc, "variable `%s` cannot be read at compile time", v.toErrMsg());
                        return CTFEExp.cantexp;
                    }
                }
                if (auto vie = e.isVoidInitExp())
                {
                    eSink.error(loc, "cannot read uninitialized variable `%s` in ctfe", v.toPrettyChars());
                    eSink.errorSupplemental(vie.var.loc, "`%s` was uninitialized and used before set", vie.var.toChars());
                    return CTFEExp.cantexp;
                }
                if (goal != CTFEGoal.LValue && v.isReference())
                    e = interpret(e, istate, goal);
            }
            if (!e)
                e = CTFEExp.cantexp;
        }
        else if (SymbolDeclaration s = d.isSymbolDeclaration())
        {
            // exclude void[]-typed `__traits(initSymbol)`
            if (auto ta = s.type.toBasetype().isTypeDArray())
            {
                assert(ta.next.ty == Tvoid);
                eSink.error(loc, "cannot determine the address of the initializer symbol during CTFE");
                return CTFEExp.cantexp;
            }

            // Struct static initializers, for example
            e = s.dsym.type.defaultInitLiteral(loc);
            if (e.op == EXP.error)
                eSink.error(loc, "CTFE failed because of previous errors in `%s.init`", s.toErrMsg());
            e = e.expressionSemantic(null);
            if (e.op == EXP.error)
                e = CTFEExp.cantexp;
            else // Convert NULL to CTFEExp
                e = interpret(e, istate, goal);
        }
        else
            eSink.error(loc, "cannot interpret declaration `%s` at compile time", d.toErrMsg());
        return e;
    }

    override void visit(VarExp e)
    {
        debug (LOG)
        {
            printf("%s VarExp::interpret() `%s`, goal = %d\n", e.loc.toChars(), e.toChars(), goal);
        }
        if (e.var.isFuncDeclaration())
        {
            result = e;
            return;
        }

        if (goal == CTFEGoal.LValue)
        {
            if (auto v = e.var.isVarDeclaration())
            {
                if (!hasValue(v))
                {
                    // Compile-time known non-CTFE variable from an outer context
                    // e.g. global or from a ref argument
                    if (v.isConst() || v.isImmutable())
                    {
                        result = getVarExp(e.loc, istate, v, goal);
                        return;
                    }

                    if (!v.isCTFE() && v.isDataseg())
                        eSink.error(e.loc, "static variable `%s` cannot be read at compile time", v.toErrMsg());
                    else // CTFE initiated from inside a function
                        eSink.error(e.loc, "variable `%s` cannot be read at compile time", v.toErrMsg());
                    result = CTFEExp.cantexp;
                    return;
                }

                if (v.storage_class & (STC.out_ | STC.ref_))
                {
                    // Strip off the nest of ref variables
                    Expression ev = getValue(v);
                    if (ev.op == EXP.variable ||
                        ev.op == EXP.index ||
                        (ev.op == EXP.slice && ev.type.toBasetype().ty == Tsarray) ||
                        ev.op == EXP.dotVariable)
                    {
                        result = interpret(pue, ev, istate, goal);
                        return;
                    }
                }
            }
            result = e;
            return;
        }
        // Linear-memory fast path: decode the value into caller storage
        // `*pue`, so a load performs no allocation at all
        result = null;
        if (global.params.ctfeLinearMemory)
            if (auto v = e.var.isVarDeclaration())
                result = ctfeGlobals.stack.getLinear(v, e.loc, e.type, pue);
        if (!result)
        {
            result = getVarExp(e.loc, istate, e.var, goal);
            if (exceptionOrCant(result))
                return;

            // Visit the default initializer for noreturn variables
            // (Custom initializers would abort the current function call and exit above)
            if (result.type.ty == Tnoreturn)
            {
                result.accept(this);
                return;
            }
        }

        if ((e.var.storage_class & (STC.ref_ | STC.out_)) == 0 && e.type.baseElemOf().ty != Tstruct)
        {
            /* Ultimately, STC.ref_|STC.out_ check should be enough to see the
             * necessity of type repainting. But currently front-end paints
             * non-ref struct variables by the const type.
             *
             *  auto foo(ref const S cs);
             *  S s;
             *  foo(s); // VarExp('s') will have const(S)
             */
            // A VarExp may include an implicit cast. It must be done explicitly.
            result = paintTypeOntoLiteral(pue, e.type, result);
        }
    }

    override void visit(DeclarationExp e)
    {
        debug (LOG)
        {
            printf("%s DeclarationExp::interpret() %s\n", e.loc.toChars(), e.toChars());
        }
        Dsymbol s = e.declaration;
        while (s.isAttribDeclaration())
        {
            auto ad = cast(AttribDeclaration)s;
            assert(ad.decl && ad.decl.length == 1); // Currently, only one allowed when parsing
            s = (*ad.decl)[0];
        }
        if (VarDeclaration v = s.isVarDeclaration())
        {
            if (TupleDeclaration td = v.toAlias().isTupleDeclaration())
            {
                result = null;

                // Reserve stack space for all tuple members
                td.foreachVar((s)
                {
                    VarDeclaration v2 = s.isVarDeclaration();
                    assert(v2);
                    if (v2.isDataseg() && !v2.isCTFE())
                        return 0;

                    ctfeGlobals.stack.push(v2);
                    if (v2._init)
                    {
                        Expression einit;
                        if (ExpInitializer ie = v2._init.isExpInitializer())
                        {
                            einit = interpretRegion(ie.exp, istate, goal);
                            if (exceptionOrCant(einit))
                                return 1;
                        }
                        else if (v2._init.isVoidInitializer())
                        {
                            einit = voidInitLiteral(v2.type, v2).copy();
                        }
                        else
                        {
                            eSink.error(e.loc, "declaration `%s` is not yet implemented in CTFE", e.toErrMsg());
                            result = CTFEExp.cantexp;
                            return 1;
                        }
                        setValue(v2, einit);
                    }
                    return 0;
                });
                return;
            }
            if (v.isStatic())
            {
                // Just ignore static variables which aren't read or written yet
                result = null;
                return;
            }
            if (!(v.isDataseg() || v.storage_class & STC.manifest) || v.isCTFE())
                ctfeGlobals.stack.push(v);
            if (v._init)
            {
                if (ExpInitializer ie = v._init.isExpInitializer())
                {
                    UnionExp ue = void;
                    result = interpret(&ue, ie.exp, istate, goal);
                    if (result !is null && v.ctfeAdrOnStack != VarDeclaration.AdrOnStackNone)
                        if (!hasValue(v))
                        {
                            if (result == ue.exp())
                                result = regionUeCopy(ue);
                            setValueWithoutChecking(v, result); // a temporary from extractSideEffects can be a ref
                        }
                    if (result == ue.exp())
                    {
                        // initialization was stored by the assignment; only
                        // persist the node if the caller wants a value
                        if (goal == CTFEGoal.Nothing && !exceptionOrCantInterpret(result))
                            result = null;
                        else
                            result = regionUeCopy(ue);
                    }
                    return;
                }
                else if (v._init.isVoidInitializer())
                {
                    result = voidInitLiteral(v.type, v).copy();
                    // There is no AssignExp for void initializers,
                    // so set it here.
                    setValue(v, result);
                    return;
                }
                else if (v._init.isArrayInitializer())
                {
                    result = interpretInitializerExpression(v);
                    if (result !is null)
                    {
                        if (v.ctfeAdrOnStack != VarDeclaration.AdrOnStackNone)
                            if (!getValue(v))
                                setValueWithoutChecking(v, result); // a temporary from extractSideEffects can be a ref
                        return;
                    }
                }
                eSink.error(e.loc, "declaration `%s` is not yet implemented in CTFE", e.toErrMsg());
                result = CTFEExp.cantexp;
            }
            else if (v.type.size() == 0)
            {
                // Zero-length arrays don't need an initializer
                result = v.type.defaultInitLiteral(e.loc);
            }
            else
            {
                eSink.error(e.loc, "variable `%s` cannot be modified at compile time", v.toErrMsg());
                result = CTFEExp.cantexp;
            }
            return;
        }
        if (s.isTemplateMixin() || s.isTupleDeclaration())
        {
            // These can be made to work, too lazy now
            eSink.error(e.loc, "declaration `%s` is not yet implemented in CTFE", e.toErrMsg());
            result = CTFEExp.cantexp;
            return;
        }

        // Others should not contain executable code, so are trivial to evaluate
        result = null;
        debug (LOG)
        {
            printf("-DeclarationExp::interpret(%s): %p\n", e.toChars(), result);
        }
    }

    override void visit(TypeidExp e)
    {
        debug (LOG)
        {
            printf("%s TypeidExp::interpret() %s\n", e.loc.toChars(), e.toChars());
        }
        if (Type t = isType(e.obj))
        {
            result = e;
            return;
        }
        if (Expression ex = isExpression(e.obj))
        {
            result = interpret(pue, ex, istate);
            if (exceptionOrCant(ex))
                return;

            if (result.op == EXP.null_)
            {
                eSink.error(e.loc, "null pointer dereference evaluating typeid. `%s` is `null`", ex.toErrMsg());
                result = CTFEExp.cantexp;
                return;
            }
            if (result.op != EXP.classReference)
            {
                eSink.error(e.loc, "CTFE internal error: determining classinfo");
                result = CTFEExp.cantexp;
                return;
            }

            ClassDeclaration cd = result.isClassReferenceExp().originalClass();
            assert(cd);

            emplaceExp!(TypeidExp)(pue, e.loc, cd.type);
            result = pue.exp();
            result.type = e.type;
            return;
        }
        visit(cast(Expression)e);
    }

    override void visit(TupleExp e)
    {
        debug (LOG)
        {
            printf("%s TupleExp::interpret() %s\n", e.loc.toChars(), e.toChars());
        }
        if (exceptionOrCant(interpretRegion(e.e0, istate, CTFEGoal.Nothing)))
            return;

        auto expsx = e.exps;
        foreach (i, exp; *expsx)
        {
            Expression ex = interpretRegion(exp, istate);
            if (exceptionOrCant(ex))
                return;

            // A tuple of assignments can contain void (Bug 5676).
            if (goal == CTFEGoal.Nothing)
                continue;
            if (ex.op == EXP.voidExpression)
            {
                eSink.error(e.loc, "CTFE internal error: void element `%s` in sequence", exp.toErrMsg());
                assert(0);
            }

            /* If any changes, do Copy On Write
             */
            if (ex !is exp)
            {
                expsx = copyArrayOnWrite(expsx, e.exps);
                (*expsx)[i] = copyRegionExp(ex);
            }
        }

        if (expsx !is e.exps)
        {
            expandTuples(expsx);
            emplaceExp!(TupleExp)(pue, e.loc, expsx);
            result = pue.exp();
            result.type = new TypeTuple(expsx);
        }
        else
            result = e;
    }

    override void visit(ArrayLiteralExp e)
    {
        debug (LOG)
        {
            printf("%s ArrayLiteralExp::interpret() %s, %s\n", e.loc.toChars(), e.type.toChars(), e.toChars());
        }
        if (e.ownedByCtfe >= OwnedBy.ctfe) // We've already interpreted all the elements
        {
            result = e;
            return;
        }

        Type tb = e.type.toBasetype();
        Type tn = tb.nextOf().toBasetype();
        bool wantCopy = (tn.ty == Tsarray || tn.ty == Tstruct);

        auto basis = interpretRegion(e.basis, istate);
        if (exceptionOrCant(basis))
            return;

        auto expsx = e.elements;
        size_t dim = e.length;

        for (size_t i = 0; i < dim; i++)
        {
            Expression exp = (*expsx)[i];
            Expression ex;
            if (!exp)
            {
                ex = copyLiteral(basis).copy();
            }
            else
            {
                // segfault bug 6250
                assert(exp.op != EXP.index || exp.isIndexExp().e1 != e);

                ex = interpretRegion(exp, istate);
                if (exceptionOrCant(ex))
                    return;

                /* Each elements should have distinct CTFE memory.
                 *  int[1] z = 7;
                 *  int[1][] pieces = [z,z];    // here
                 */
                if (wantCopy)
                    ex = copyLiteral(ex).copy();
            }

            /* If any changes, do Copy On Write
             */
            if (ex !is exp)
            {
                expsx = copyArrayOnWrite(expsx, e.elements);
                (*expsx)[i] = ex;
            }
        }

        // Only create new ArrayLiteralExp if needed (don't forget to check basis as well!)
        // https://github.com/dlang/dmd/issues/21039
        if (expsx !is e.elements || basis !is e.basis)
        {
            // todo: all tuple expansions should go in semantic phase.
            expandTuples(expsx);
            if (expsx.length != dim)
            {
                eSink.error(e.loc, "CTFE internal error: invalid array literal");
                result = CTFEExp.cantexp;
                return;
            }
            emplaceExp!(ArrayLiteralExp)(pue, e.loc, e.type, basis, expsx);
            auto ale = pue.exp().isArrayLiteralExp();
            ale.ownedByCtfe = OwnedBy.ctfe;
            result = ale;
        }
        else if ((cast(TypeNext)e.type).next.mod & (MODFlags.const_ | MODFlags.immutable_))
        {
            // If it's immutable, we don't need to dup it
            result = e;
        }
        else
        {
            *pue = copyLiteral(e);
            result = pue.exp();
        }
    }

    override void visit(AssocArrayLiteralExp e)
    {
        debug (LOG)
        {
            printf("%s AssocArrayLiteralExp::interpret() %s\n", e.loc.toChars(), e.toChars());
        }
        if (e.ownedByCtfe >= OwnedBy.ctfe) // We've already interpreted all the elements
        {
            result = e;
            return;
        }

        auto keysx = e.keys;
        auto valuesx = e.values;
        foreach (i, ekey; *keysx)
        {
            auto evalue = (*valuesx)[i];

            auto ek = interpretRegion(ekey, istate);
            if (exceptionOrCant(ek))
                return;
            auto ev = interpretRegion(evalue, istate);
            if (exceptionOrCant(ev))
                return;

            /* If any changes, do Copy On Write
             */
            if (ek !is ekey ||
                ev !is evalue)
            {
                keysx = copyArrayOnWrite(keysx, e.keys);
                valuesx = copyArrayOnWrite(valuesx, e.values);
                (*keysx)[i] = ek;
                (*valuesx)[i] = ev;
            }
        }
        if (keysx !is e.keys)
            expandTuples(keysx);
        if (valuesx !is e.values)
            expandTuples(valuesx);
        if (keysx.length != valuesx.length)
        {
            eSink.error(e.loc, "CTFE internal error: invalid AA");
            result = CTFEExp.cantexp;
            return;
        }

        /* Remove duplicate keys
         */
        for (size_t i = 1; i < keysx.length; i++)
        {
            auto ekey = (*keysx)[i - 1];
            for (size_t j = i; j < keysx.length; j++)
            {
                auto ekey2 = (*keysx)[j];
                if (!ctfeEqual(e.loc, EXP.equal, ekey, ekey2))
                    continue;

                // Remove ekey
                keysx = copyArrayOnWrite(keysx, e.keys);
                valuesx = copyArrayOnWrite(valuesx, e.values);
                keysx.remove(i - 1);
                valuesx.remove(i - 1);

                i -= 1; // redo the i'th iteration
                break;
            }
        }

        if (keysx !is e.keys ||
            valuesx !is e.values)
        {
            assert(keysx !is e.keys &&
                   valuesx !is e.values);
            auto aae = ctfeEmplaceExp!AssocArrayLiteralExp(e.loc, keysx, valuesx);
            aae.type = e.type;
            aae.lowering = e.lowering;
            aae.loweringCtfe = e.loweringCtfe;
            aae.ownedByCtfe = OwnedBy.ctfe;
            result = aae;
        }
        else
        {
            *pue = copyLiteral(e);
            result = pue.exp();
        }
    }

    override void visit(StructLiteralExp e)
    {
        debug (LOG)
        {
            printf("%s StructLiteralExp::interpret() %s ownedByCtfe = %d\n", e.loc.toChars(), e.toChars(), e.ownedByCtfe);
        }
        if (e.ownedByCtfe >= OwnedBy.ctfe)
        {
            result = e;
            return;
        }

        size_t dim = e.elements ? e.elements.length : 0;
        auto expsx = e.elements;

        if (dim != e.sd.fields.length)
        {
            // guaranteed by AggregateDeclaration.fill and TypeStruct.defaultInitLiteral
            const nvthis = e.sd.fields.length - e.sd.nonHiddenFields();
            assert(e.sd.fields.length - dim == nvthis);

            /* If a nested struct has no initialized hidden pointer,
             * set it to null to match the runtime behaviour.
             */
            foreach (const i; 0 .. nvthis)
            {
                auto ne = ctfeEmplaceExp!NullExp(e.loc);
                auto vthis = i == 0 ? e.sd.vthis : e.sd.vthis2;
                ne.type = vthis.type;

                expsx = copyArrayOnWrite(expsx, e.elements);
                expsx.push(ne);
                ++dim;
            }
        }
        assert(dim == e.sd.fields.length);

        foreach (i; 0 .. dim)
        {
            auto v = e.sd.fields[i];
            Expression exp = (*expsx)[i];
            Expression ex;
            if (!exp)
            {
                ex = voidInitLiteral(v.type, v).copy();
            }
            else
            {
                ex = interpretRegion(exp, istate);
                if (exceptionOrCant(ex))
                    return;
                if ((v.type.ty != ex.type.ty) && v.type.ty == Tsarray)
                {
                    // Block assignment from inside struct literals
                    auto tsa = cast(TypeSArray)v.type;
                    auto len = cast(size_t)tsa.dim.toInteger();
                    UnionExp ue = void;
                    ex = createBlockDuplicatedArrayLiteral(&ue, ex.loc, v.type, ex, len);
                    if (ex == ue.exp())
                        ex = ue.copy();
                }
            }

            /* If any changes, do Copy On Write
             */
            if (ex !is exp)
            {
                expsx = copyArrayOnWrite(expsx, e.elements);
                (*expsx)[i] = ex;
            }
        }

        if (expsx !is e.elements)
        {
            expandTuples(expsx);
            if (expsx.length != e.sd.fields.length)
            {
                eSink.error(e.loc, "CTFE internal error: invalid struct literal");
                result = CTFEExp.cantexp;
                return;
            }
            emplaceExp!(StructLiteralExp)(pue, e.loc, e.sd, expsx);
            auto sle = pue.exp().isStructLiteralExp();
            sle.type = e.type;
            sle.ownedByCtfe = OwnedBy.ctfe;
            sle.origin = e.origin;
            result = sle;
        }
        else
        {
            *pue = copyLiteral(e);
            result = pue.exp();
        }
    }

    // Create an array literal of type 'newtype' with dimensions given by
    // 'arguments'[argnum..$]
    static Expression recursivelyCreateArrayLiteral(UnionExp* pue, Loc loc, Type newtype, InterState* istate, Expressions* arguments, int argnum)
    {
        Expression lenExpr = interpret(pue, (*arguments)[argnum], istate);
        if (exceptionOrCantInterpret(lenExpr))
            return lenExpr;
        size_t len = cast(size_t)lenExpr.toInteger();
        Type elemType = (cast(TypeArray)newtype).next;
        if (elemType.ty == Tarray && argnum < arguments.length - 1)
        {
            Expression elem = recursivelyCreateArrayLiteral(pue, loc, elemType, istate, arguments, argnum + 1);
            if (exceptionOrCantInterpret(elem))
                return elem;

            auto elements = new Expressions(len);
            foreach (ref element; *elements)
                element = copyLiteral(elem).copy();
            emplaceExp!(ArrayLiteralExp)(pue, loc, newtype, elements);
            auto ae = pue.exp().isArrayLiteralExp();
            ae.ownedByCtfe = OwnedBy.ctfe;
            return ae;
        }
        assert(argnum == arguments.length - 1);
        if (elemType.ty.isSomeChar)
        {
            const ch = cast(dchar)elemType.defaultInitLiteral(loc).toInteger();
            const sz = cast(ubyte)elemType.size();
            return createBlockDuplicatedStringLiteral(pue, loc, newtype, ch, len, sz);
        }
        else
        {
            auto el = interpret(elemType.defaultInitLiteral(loc), istate);
            return createBlockDuplicatedArrayLiteral(pue, loc, newtype, el, len);
        }
    }

    override void visit(NewExp e)
    {
        debug (LOG)
        {
            printf("%s NewExp::interpret() %s\n", e.loc.toChars(), e.toChars());
        }

        if (e.placement)
        {
            eSink.error(e.placement.loc, "`new ( %s )` PlacementExpression cannot be evaluated at compile time", e.placement.toErrMsg());
            result = CTFEExp.cantexp;
            return;
        }

        Expression epre = interpret(pue, e.argprefix, istate, CTFEGoal.Nothing);
        if (exceptionOrCant(epre))
            return;

        if (e.newtype.ty == Tarray && e.arguments)
        {
            result = recursivelyCreateArrayLiteral(pue, e.loc, e.newtype, istate, e.arguments, 0);
            return;
        }
        if (auto ts = e.newtype.toBasetype().isTypeStruct())
        {
            if (e.member)
            {
                Expression se = e.newtype.defaultInitLiteral(e.loc);
                se = interpret(se, istate);
                if (exceptionOrCant(se))
                    return;
                result = interpretFunction(pue, e.member, istate, e.arguments, se);

                // Repaint as same as CallExp::interpret() does.
                result.loc = e.loc;
            }
            else
            {
                StructDeclaration sd = ts.sym;
                auto exps = new Expressions();
                exps.reserve(sd.fields.length);
                if (e.arguments)
                {
                    exps.setDim(e.arguments.length);
                    foreach (i, ex; *e.arguments)
                    {
                        ex = interpretRegion(ex, istate);
                        if (exceptionOrCant(ex))
                            return;
                        (*exps)[i] = ex;
                    }
                }
                sd.fill(e.loc, *exps, false);

                auto se = ctfeEmplaceExp!StructLiteralExp(e.loc, sd, exps, e.newtype);
                se.origin = se;
                se.type = e.newtype;
                se.ownedByCtfe = OwnedBy.ctfe;
                result = interpret(pue, se, istate);
            }
            if (exceptionOrCant(result))
                return;
            Expression ev = (result == pue.exp()) ? pue.copy() : result;
            emplaceExp!(AddrExp)(pue, e.loc, ev, e.type);
            result = pue.exp();
            return;
        }
        if (auto tc = e.newtype.toBasetype().isTypeClass())
        {
            ClassDeclaration cd = tc.sym;
            size_t totalFieldCount = 0;
            for (ClassDeclaration c = cd; c; c = c.baseClass)
                totalFieldCount += c.fields.length;

            totalFieldCount -= cd.hasMonitor(); // skip __monitor field

            auto elems = new Expressions(totalFieldCount);
            ptrdiff_t fieldsSoFar = totalFieldCount;
            for (ClassDeclaration c = cd; c; c = c.baseClass)
            {
                fieldsSoFar -= c.fields.length;
                foreach (i, v; c.fields)
                {
                    if (v.inuse)
                    {
                        eSink.error(e.loc, "circular reference to `%s`", v.toPrettyChars());
                        result = CTFEExp.cantexp;
                        return;
                    }
                    if (fieldsSoFar + ptrdiff_t(i) < 0) // field -1 = __monitor which we skip
                        break;

                    Expression m;
                    if (v._init)
                    {
                        if (v._init.isVoidInitializer())
                            m = voidInitLiteral(v.type, v).copy();
                        else
                            m = v.getConstInitializer(true);
                    }
                    else if (v.type.isTypeNoreturn())
                    {
                        // Noreturn field with default initializer
                        (*elems)[fieldsSoFar + i] = null;
                        continue;
                    }
                    else
                        m = v.type.defaultInitLiteral(e.loc);
                    if (exceptionOrCant(m))
                        return;
                    (*elems)[fieldsSoFar + i] = copyLiteral(m).copy();
                }
            }
            // Hack: we store a ClassDeclaration instead of a StructDeclaration.
            // We probably won't get away with this.
//            auto se = new StructLiteralExp(e.loc, cast(StructDeclaration)cd, elems, e.newtype);
            auto se = ctfeEmplaceExp!StructLiteralExp(e.loc, cast(StructDeclaration)cd, elems, e.newtype);
            se.origin = se;
            se.ownedByCtfe = OwnedBy.ctfe;
            Expression eref = ctfeEmplaceExp!ClassReferenceExp(e.loc, se, e.type);
            if (e.member)
            {
                // Call constructor
                if (!e.member.fbody)
                {
                    Expression ctorfail = evaluateIfBuiltin(pue, istate, e.loc, e.member, e.arguments, eref);
                    if (ctorfail)
                    {
                        if (exceptionOrCant(ctorfail))
                            return;
                        result = eref;
                        return;
                    }
                    auto m = e.member;
                    eSink.error(m.loc, "%s `%s` `%s` cannot be constructed at compile time, because the constructor has no available source code",
                        m.kind, m.toPrettyChars, e.newtype.toErrMsg());
                    result = CTFEExp.cantexp;
                    return;
                }
                UnionExp ue = void;
                Expression ctorfail = interpretFunction(&ue, e.member, istate, e.arguments, eref);
                if (exceptionOrCant(ctorfail))
                    return;

                /* https://issues.dlang.org/show_bug.cgi?id=14465
                 * Repaint the loc, because a super() call
                 * in the constructor modifies the loc of ClassReferenceExp
                 * in CallExp::interpret().
                 */
                eref.loc = e.loc;
            }
            result = eref;
            return;
        }
        if (e.newtype.toBasetype().isScalar())
        {
            Expression newval;
            if (e.arguments && e.arguments.length)
                newval = (*e.arguments)[0];
            else
                newval = e.newtype.defaultInitLiteral(e.loc);
            newval = interpretRegion(newval, istate);
            if (exceptionOrCant(newval))
                return;

            // Create a CTFE pointer &[newval][0]
            auto elements = new Expressions(1);
            (*elements)[0] = newval;
            auto ae = ctfeEmplaceExp!ArrayLiteralExp(e.loc, e.newtype.arrayOf(), elements);
            ae.ownedByCtfe = OwnedBy.ctfe;

            auto ei = ctfeEmplaceExp!IndexExp(e.loc, ae, ctfeEmplaceExp!IntegerExp(Loc.initial, 0, Type.tsize_t));
            ei.type = e.newtype;
            emplaceExp!(AddrExp)(pue, e.loc, ei, e.type);
            result = pue.exp();
            return;
        }
        eSink.error(e.loc, "cannot interpret `%s` at compile time", e.toErrMsg());
        result = CTFEExp.cantexp;
    }

    /* Byte-native fast path for a whole integral expression tree over
     * linear memory (see tryEvalScalarRaw): one result node, no
     * intermediates. Returns false having evaluated nothing.
     */
    private bool rawScalarResult(Expression e)
    {
        ulong rawVal = void;
        if (!global.params.ctfeLinearMemory || !tryEvalScalarRaw(e, rawVal))
            return false;
        emplaceExp!(IntegerExp)(pue, e.loc, rawVal, e.type);
        result = pue.exp();
        return true;
    }

    override void visit(UnaExp e)
    {
        debug (LOG)
        {
            printf("%s UnaExp::interpret() %s\n", e.loc.toChars(), e.toChars());
        }
        if (rawScalarResult(e))
            return;
        UnionExp ue = void;
        Expression e1 = interpret(&ue, e.e1, istate);
        if (exceptionOrCant(e1))
            return;
        switch (e.op)
        {
        case EXP.negate:
            *pue = Neg(e.type, e1);
            break;

        case EXP.tilde:
            *pue = Com(e.type, e1);
            break;

        case EXP.not:
            *pue = Not(e.type, e1);
            break;

        default:
            assert(0);
        }
        result = (*pue).exp();
    }

    override void visit(DotTypeExp e)
    {
        debug (LOG)
        {
            printf("%s DotTypeExp::interpret() %s\n", e.loc.toChars(), e.toChars());
        }
        UnionExp ue = void;
        Expression e1 = interpret(&ue, e.e1, istate);
        if (exceptionOrCant(e1))
            return;
        if (e1 == e.e1)
            result = e; // optimize: reuse this CTFE reference
        else
        {
            auto edt = e.copy().isDotTypeExp();
            edt.e1 = (e1 == ue.exp()) ? e1.copy() : e1; // don't return pointer to ue
            result = edt;
        }
    }

    private alias fp_t = extern (D) UnionExp function(Loc loc, Type, Expression, Expression);
    private alias fp2_t = extern (D) bool function(Loc loc, EXP, Expression, Expression);

    extern (D) private void interpretCommon(BinExp e, fp_t fp)
    {
        debug (LOG)
        {
            printf("%s BinExp::interpretCommon() %s\n", e.loc.toChars(), e.toChars());
        }
        if (rawScalarResult(e))
            return;
        if (e.e1.type.ty == Tpointer && e.e2.type.ty == Tpointer && e.op == EXP.min)
        {
            UnionExp ue1 = void;
            Expression e1 = interpret(&ue1, e.e1, istate);
            if (exceptionOrCant(e1))
                return;
            UnionExp ue2 = void;
            Expression e2 = interpret(&ue2, e.e2, istate);
            if (exceptionOrCant(e2))
                return;
            result = pointerDifference(pue, e.loc, e.type, e1, e2);
            return;
        }
        if (e.e1.type.ty == Tpointer && e.e2.type.isIntegral())
        {
            UnionExp ue1 = void;
            Expression e1 = interpret(&ue1, e.e1, istate);
            if (exceptionOrCant(e1))
                return;
            UnionExp ue2 = void;
            Expression e2 = interpret(&ue2, e.e2, istate);
            if (exceptionOrCant(e2))
                return;
            result = pointerArithmetic(pue, e.loc, e.op, e.type, e1, e2);
            return;
        }
        if (e.e2.type.ty == Tpointer && e.e1.type.isIntegral() && e.op == EXP.add)
        {
            UnionExp ue1 = void;
            Expression e1 = interpret(&ue1, e.e1, istate);
            if (exceptionOrCant(e1))
                return;
            UnionExp ue2 = void;
            Expression e2 = interpret(&ue2, e.e2, istate);
            if (exceptionOrCant(e2))
                return;
            result = pointerArithmetic(pue, e.loc, e.op, e.type, e2, e1);
            return;
        }
        if (e.e1.type.ty == Tpointer || e.e2.type.ty == Tpointer)
        {
            eSink.error(e.loc, "pointer expression `%s` cannot be interpreted at compile time", e.toErrMsg());
            result = CTFEExp.cantexp;
            return;
        }

        bool evalOperand(UnionExp* pue, Expression ex, out Expression er)
        {
            er = interpret(pue, ex, istate);
            if (exceptionOrCant(er))
                return false;
            return true;
        }

        UnionExp ue1 = void;
        Expression e1;
        if (!evalOperand(&ue1, e.e1, e1))
            return;

        UnionExp ue2 = void;
        Expression e2;
        if (!evalOperand(&ue2, e.e2, e2))
            return;

        if (e.op == EXP.rightShift || e.op == EXP.leftShift || e.op == EXP.unsignedRightShift)
        {
            const sinteger_t i2 = e2.toInteger();
            const uinteger_t sz = e1.type.size() * 8;
            if (i2 < 0 || i2 >= sz)
            {
                eSink.error(e.loc, "shift by %lld is outside the range 0..%llu", i2, cast(ulong)sz - 1);
                result = CTFEExp.cantexp;
                return;
            }
        }

        /******************************************
         * Perform the operation fp on operands e1 and e2.
         */
        UnionExp evaluate(Loc loc, Type type, Expression e1, Expression e2)
        {
            UnionExp ue = void;
            auto ae1 = e1.isArrayLiteralExp();
            auto ae2 = e2.isArrayLiteralExp();
            if (ae1 || ae2)
            {
                /* Cases:
                 * 1. T[] op T[]
                 * 2. T op T[]
                 * 3. T[] op T
                 */
                if (ae1 && e2.implicitConvTo(e1.type.toBasetype().nextOf())) // case 3
                    ae2 = null;
                else if (ae2 && e1.implicitConvTo(e2.type.toBasetype().nextOf())) // case 2
                    ae1 = null;
                // else case 1

                auto aex = ae1 ? ae1 : ae2;
                if (!aex.elements)
                {
                    emplaceExp!ArrayLiteralExp(&ue, loc, type, cast(Expressions*) null);
                    return ue;
                }
                const length = aex.length;
                Expressions* elements = new Expressions(length);

                emplaceExp!ArrayLiteralExp(&ue, loc, type, elements);
                foreach (i; 0 .. length)
                {
                    Expression e1x = ae1 ? ae1[i] : e1;
                    Expression e2x = ae2 ? ae2[i] : e2;
                    UnionExp uex = evaluate(loc, e1x.type, e1x, e2x);
                    // This can be made more efficient by making use of ue.basis
                    (*elements)[i] = uex.copy();
                }
                return ue;
            }

            if (e1.isConst() != 1)
            {
                // The following should really be an assert()
                eSink.error(e1.loc, "CTFE internal error: non-constant value `%s`", e1.toErrMsg());
                emplaceExp!CTFEExp(&ue, EXP.cantExpression);
                return ue;
            }
            if (e2.isConst() != 1)
            {
                eSink.error(e2.loc, "CTFE internal error: non-constant value `%s`", e2.toErrMsg());
                emplaceExp!CTFEExp(&ue, EXP.cantExpression);
                return ue;
            }

            return (*fp)(loc, type, e1, e2);
        }

        *pue = evaluate(e.loc, e.type, e1, e2);
        result = (*pue).exp();
        if (CTFEExp.isCantExp(result))
            eSink.error(e.loc, "`%s` cannot be interpreted at compile time", e.toErrMsg());
    }

    extern (D) private void interpretCompareCommon(BinExp e, fp2_t fp)
    {
        debug (LOG)
        {
            printf("%s BinExp::interpretCompareCommon() %s\n", e.loc.toChars(), e.toChars());
        }
        if (rawScalarResult(e))
            return;
        UnionExp ue1 = void;
        UnionExp ue2 = void;
        if (e.e1.type.ty == Tpointer && e.e2.type.ty == Tpointer)
        {
            Expression e1 = interpret(&ue1, e.e1, istate);
            if (exceptionOrCant(e1))
                return;
            Expression e2 = interpret(&ue2, e.e2, istate);
            if (exceptionOrCant(e2))
                return;
            //printf("e1 = %s %s, e2 = %s %s\n", e1.type.toChars(), e1.toChars(), e2.type.toChars(), e2.toChars());
            dinteger_t ofs1, ofs2;
            Expression agg1 = getAggregateFromPointer(e1, &ofs1);
            Expression agg2 = getAggregateFromPointer(e2, &ofs2);
            //printf("agg1 = %p %s, agg2 = %p %s\n", agg1, agg1.toChars(), agg2, agg2.toChars());
            const cmp = comparePointers(e.op, agg1, ofs1, agg2, ofs2);
            if (cmp == -1)
            {
                char dir = (e.op == EXP.greaterThan || e.op == EXP.greaterOrEqual) ? '<' : '>';
                eSink.error(e.loc, "the ordering of pointers to unrelated memory blocks is indeterminate in CTFE.");
                eSink.errorSupplemental(e.loc, "to check if they point to the same memory block, use both `>` and `<` inside `&&` or `||`, eg `%s && %s %c= %s + 1`", e.toChars(), e.e1.toChars(), dir, e.e2.toChars());
                result = CTFEExp.cantexp;
                return;
            }
            if (e.type.equals(Type.tbool))
                result = IntegerExp.createBool(cmp != 0);
            else
            {
                emplaceExp!(IntegerExp)(pue, e.loc, cmp, e.type);
                result = (*pue).exp();
            }
            return;
        }
        Expression e1 = interpret(&ue1, e.e1, istate);
        if (exceptionOrCant(e1))
            return;
        if (!isCtfeComparable(e1))
        {
            eSink.error(e.loc, "cannot compare `%s` at compile time", e1.toErrMsg());
            result = CTFEExp.cantexp;
            return;
        }
        Expression e2 = interpret(&ue2, e.e2, istate);
        if (exceptionOrCant(e2))
            return;
        if (!isCtfeComparable(e2))
        {
            eSink.error(e.loc, "cannot compare `%s` at compile time", e2.toErrMsg());
            result = CTFEExp.cantexp;
            return;
        }
        const cmp = (*fp)(e.loc, e.op, e1, e2);
        if (e.type.equals(Type.tbool))
            result = IntegerExp.createBool(cmp);
        else
        {
            emplaceExp!(IntegerExp)(pue, e.loc, cmp, e.type);
            result = (*pue).exp();
        }
    }

    override void visit(BinExp e)
    {
        switch (e.op)
        {
        case EXP.add:
            interpretCommon(e, &Add);
            return;

        case EXP.min:
            interpretCommon(e, &Min);
            return;

        case EXP.mul:
            interpretCommon(e, &Mul);
            return;

        case EXP.div:
            interpretCommon(e, &Div);
            return;

        case EXP.mod:
            interpretCommon(e, &Mod);
            return;

        case EXP.leftShift:
            interpretCommon(e, &Shl);
            return;

        case EXP.rightShift:
            interpretCommon(e, &Shr);
            return;

        case EXP.unsignedRightShift:
            interpretCommon(e, &Ushr);
            return;

        case EXP.and:
            interpretCommon(e, &And);
            return;

        case EXP.or:
            interpretCommon(e, &Or);
            return;

        case EXP.xor:
            interpretCommon(e, &Xor);
            return;

        case EXP.pow:
            interpretCommon(e, &Pow);
            return;

        case EXP.equal:
        case EXP.notEqual:
            interpretCompareCommon(e, &ctfeEqual);
            return;

        case EXP.identity:
        case EXP.notIdentity:
            interpretCompareCommon(e, &ctfeIdentity);
            return;

        case EXP.lessThan:
        case EXP.lessOrEqual:
        case EXP.greaterThan:
        case EXP.greaterOrEqual:
            interpretCompareCommon(e, &ctfeCmp);
            return;

        default:
            printf("be = '%s' %s at [%s]\n", EXPtoString(e.op).ptr, e.toChars(), e.loc.toChars());
            assert(0);
        }
    }

    /* Helper functions for BinExp::interpretAssignCommon
     */
    // Returns the variable which is eventually modified, or NULL if an rvalue.
    // thisval is the current value of 'this'.
    static VarDeclaration findParentVar(Expression e) @safe
    {
        for (;;)
        {
            if (auto ve = e.isVarExp())
            {
                VarDeclaration v = ve.var.isVarDeclaration();
                assert(v);
                return v;
            }
            if (auto ie = e.isIndexExp())
                e = ie.e1;
            else if (auto dve = e.isDotVarExp())
                e = dve.e1;
            else if (auto dtie = e.isDotTemplateInstanceExp())
                e = dtie.e1;
            else if (auto se = e.isSliceExp())
                e = se.e1;
            else
                return null;
        }
    }

    extern (D) private void interpretAssignCommon(BinExp e, fp_t fp, int post = 0)
    {
        debug (LOG)
        {
            printf("%s BinExp::interpretAssignCommon() %s\n", e.loc.toChars(), e.toChars());
        }
        result = CTFEExp.cantexp;

        Expression e1 = e.e1;
        if (!istate)
        {
            eSink.error(e.loc, "value of `%s` is not known at compile time", e1.toErrMsg());
            return;
        }

        ++ctfeGlobals.numAssignments;

        /* Before we begin, we need to know if this is a reference assignment
         * (dynamic array, AA, or class) or a value assignment.
         * Determining this for slice assignments are tricky: we need to know
         * if it is a block assignment (a[] = e) rather than a direct slice
         * assignment (a[] = b[]). Note that initializers of multi-dimensional
         * static arrays can have 2D block assignments (eg, int[7][7] x = 6;).
         * So we need to recurse to determine if it is a block assignment.
         */
        bool isBlockAssignment = false;
        if (e1.op == EXP.slice)
        {
            // a[] = e can have const e. So we compare the naked types.
            Type tdst = e1.type.toBasetype();
            Type tsrc = e.e2.type.toBasetype();
            while (tdst.isStaticOrDynamicArray())
            {
                tdst = (cast(TypeArray)tdst).next.toBasetype();
                if (tsrc.equivalent(tdst))
                {
                    isBlockAssignment = true;
                    break;
                }
            }
        }

        // ---------------------------------------
        //      Deal with reference assignment
        // ---------------------------------------
        // If it is a construction of a ref variable, it is a ref assignment
        if ((e.op == EXP.construct || e.op == EXP.blit) &&
            ((cast(AssignExp)e).memset == MemorySet.referenceInit))
        {
            assert(!fp);

            Expression newval = interpretRegion(e.e2, istate, CTFEGoal.LValue);
            if (exceptionOrCant(newval))
                return;

            VarDeclaration v = e1.isVarExp().var.isVarDeclaration();
            setValue(v, newval);

            // Get the value to return. Note that 'newval' is an Lvalue,
            // so if we need an Rvalue, we have to interpret again.
            if (goal == CTFEGoal.RValue)
                result = interpretRegion(newval, istate);
            else
                result = e1; // VarExp is a CTFE reference
            return;
        }

        if (fp)
        {
            while (e1.op == EXP.cast_)
            {
                CastExp ce = e1.isCastExp();
                e1 = ce.e1;
            }
        }

        // Linear-memory fast paths (only when no cast was stripped off above):
        // `v = e2`, `v op= e2`, `v++` on scalar locals, and scalar stores
        // through element/field chains rooted in a linear slice
        if (global.params.ctfeLinearMemory && e1 is e.e1)
        {
            if (auto ve = e1.isVarExp())
            {
                if (interpretScalarVarAssign(e, ve, fp, post))
                    return;
                if (fp is null && interpretSliceHandleAssign(e, ve))
                    return;
            }
            else if (e1.op == EXP.index || e1.op == EXP.dotVariable)
            {
                if (interpretLinearLocAssign(e, fp, post))
                    return;
            }
        }

        // ---------------------------------------
        //      Interpret left hand side
        // ---------------------------------------
        Expression oldval = null;
        if (e1.op == EXP.index && e1.isIndexExp().e1.type.toBasetype().ty == Taarray)
        {
            assert(false, "indexing AA should have been lowered in semantic analysis");
        }
        else if (e1.op == EXP.arrayLength)
        {
            oldval = interpretRegion(e1, istate);
            if (exceptionOrCant(oldval))
                return;
        }
        else if (e.op == EXP.construct || e.op == EXP.blit)
        {
            // Unless we have a simple var assignment, we're
            // only modifying part of the variable. So we need to make sure
            // that the parent variable exists.
            VarDeclaration ultimateVar = findParentVar(e1);
            if (auto ve = e1.isVarExp())
            {
                VarDeclaration v = ve.var.isVarDeclaration();
                assert(v);
                if (v.storage_class & STC.out_)
                    goto L1;
            }
            else if (ultimateVar && !getValue(ultimateVar))
            {
                Expression ex = interpretRegion(ultimateVar.type.defaultInitLiteral(e.loc), istate);
                if (exceptionOrCant(ex))
                    return;
                setValue(ultimateVar, ex);
            }
            else
                goto L1;
        }
        else
        {
        L1:
            e1 = interpretRegion(e1, istate, CTFEGoal.LValue);
            if (exceptionOrCant(e1))
                return;

            if (e1.op == EXP.index && e1.isIndexExp().e1.type.toBasetype().ty == Taarray)
            {
                assert(false, "indexing AA should have been lowered in semantic analysis");
            }
        }

        // ---------------------------------------
        //      Interpret right hand side
        // ---------------------------------------
        /* `v = f(...)` where v is a slice-eligible local: ask the callee to
         * hand its slice return value over as a linear handle, avoiding the
         * whole-array AST materialization and re-encode round trip. When the
         * callee does not take the offer (lr.set stays false), newval holds
         * the normally evaluated result and the generic path continues
         * unchanged.
         */
        CtfeLinearReturn lr;
        VarDeclaration linearRetVar = null;
        if (global.params.ctfeLinearMemory && fp is null &&
            e.e2.op == EXP.call &&
            (e.op == EXP.assign || e.op == EXP.construct || e.op == EXP.blit))
        {
            if (auto ve = e1.isVarExp())
            {
                VarDeclaration v = ve.var.isVarDeclaration();
                // Assignment through a ref/out parameter assigns the caller's
                // variable: follow the CTFE reference to the ultimate entry
                for (int depth = 0; v && depth < 8; ++depth)
                {
                    if (!(v.storage_class & (STC.ref_ | STC.out_)))
                        break;
                    auto ev = ctfeGlobals.stack.astValue(v);
                    if (ev is null || ev.op != EXP.variable)
                    {
                        v = null;
                        break;
                    }
                    v = ev.isVarExp().var.isVarDeclaration();
                }
                if (v && ctfeGlobals.stack.canStoreLinearSlice(v) &&
                    (ctfeGlobals.stack.hasLinearSlot(v) || ctfeGlobals.stack.isInCurrentFrame(v)))
                {
                    linearRetVar = v;
                    ctfeGlobals.linearReturnDest = &lr;
                }
            }
        }
        Expression newval = interpretRegion(e.e2, istate);
        ctfeGlobals.linearReturnDest = null; // taken by visit(CallExp); clear on error paths
        if (exceptionOrCant(newval))
            return;
        if (lr.set)
        {
            if (interpretLinearReturnAssign(e, e1.isVarExp(), linearRetVar, lr.slice))
                return;
            // fall back: materialize the handed-over value and continue the
            // generic assignment with it
            newval = decodeSlice(ctfeGlobals.linearMem, lr.slice, linearRetVar.type, e.loc);
            if (newval is null)
            {
                error(e.loc, "CTFE internal error: cannot interpret `%s` at compile time", e.toErrMsg());
                result = CTFEExp.cantexp;
                return;
            }
        }
        if (e.op == EXP.blit && newval.op == EXP.int64)
        {
            Type tbn = e.type.baseElemOf();
            if (tbn.ty == Tstruct)
            {
                /* Look for special case of struct being initialized with 0.
                 */
                newval = e.type.defaultInitLiteral(e.loc);
                if (newval.op == EXP.error)
                {
                    result = CTFEExp.cantexp;
                    return;
                }
                newval = interpretRegion(newval, istate); // copy and set ownedByCtfe flag
                if (exceptionOrCant(newval))
                    return;
            }
        }

        // ----------------------------------------------------
        //  Deal with read-modify-write assignments.
        //  Set 'newval' to the final assignment value
        //  Also determine the return value (except for slice
        //  assignments, which are more complicated)
        // ----------------------------------------------------
        if (fp)
        {
            // Linear-memory fast path for `v ~= e2` on eligible slice locals:
            // append to the payload instead of copying the whole array.
            // Bailing out (false) is always safe: nothing was mutated yet and
            // loading `oldval` below flips any linear value back to an AST node.
            if (global.params.ctfeLinearMemory && e1 is e.e1 && !oldval &&
                (e.op == EXP.concatenateAssign || e.op == EXP.concatenateElemAssign))
                if (auto ve = e1.isVarExp())
                    if (interpretSliceCatAssign(e, ve, newval))
                        return;

            if (!oldval)
            {
                // Load the left hand side after interpreting the right hand side.
                oldval = interpretRegion(e1, istate);
                if (exceptionOrCant(oldval))
                    return;
            }

            if (e.e1.type.ty != Tpointer)
            {
                // ~= can create new values (see bug 6052)
                if (e.op == EXP.concatenateAssign || e.op == EXP.concatenateElemAssign || e.op == EXP.concatenateDcharAssign)
                {
                    // We need to dup it and repaint the type. For a dynamic array
                    // we can skip duplication, because it gets copied later anyway.
                    if (newval.type.ty != Tarray)
                    {
                        newval = copyLiteral(newval).copy();
                        newval.type = e.e2.type; // repaint type
                    }
                    else
                    {
                        newval = paintTypeOntoLiteral(e.e2.type, newval);
                        newval = resolveSlice(newval);
                    }
                }
                oldval = resolveSlice(oldval);

                newval = (*fp)(e.loc, e.type, oldval, newval).copy();
            }
            else if (e.e2.type.isIntegral() &&
                     (e.op == EXP.addAssign ||
                      e.op == EXP.minAssign ||
                      e.op == EXP.plusPlus ||
                      e.op == EXP.minusMinus))
            {
                newval = pointerArithmetic(pue, e.loc, e.op, e.type, oldval, newval).copy();
                if (newval == pue.exp())
                    newval = pue.copy();
            }
            else
            {
                eSink.error(e.loc, "pointer expression `%s` cannot be interpreted at compile time", e.toErrMsg());
                result = CTFEExp.cantexp;
                return;
            }
            if (exceptionOrCant(newval))
            {
                if (CTFEExp.isCantExp(newval))
                    eSink.error(e.loc, "cannot interpret `%s` at compile time", e.toErrMsg());
                return;
            }
        }

        if (e1.op == EXP.arrayLength)
        {
            /* Change the assignment from:
             *  arr.length = n;
             * into:
             *  arr = new_length_array; (result is n)
             */

            // Determine the return value
            result = ctfeCast(pue, e.loc, e.type, e.type, fp && post ? oldval : newval);
            if (exceptionOrCant(result))
                return;

            if (result == pue.exp())
                result = pue.copy();

            size_t oldlen = cast(size_t)oldval.toInteger();
            size_t newlen = cast(size_t)newval.toInteger();
            if (oldlen == newlen) // no change required -- we're done!
                return;

            // We have changed it into a reference assignment
            // Note that returnValue is still the new length.
            e1 = e1.isArrayLengthExp().e1;
            Type t = e1.type.toBasetype();
            if (t.ty != Tarray)
            {
                eSink.error(e.loc, "`%s` is not yet supported at compile time", e.toErrMsg());
                result = CTFEExp.cantexp;
                return;
            }

            // Linear-memory fast path: resize the payload in place instead
            // of building a new array literal (result was determined above)
            if (global.params.ctfeLinearMemory)
                if (auto ve = e1.isVarExp())
                    if (interpretLinearLengthAssign(e, ve, cast(size_t) oldlen, cast(size_t) newlen))
                        return;

            e1 = interpretRegion(e1, istate, CTFEGoal.LValue);
            if (exceptionOrCant(e1))
                return;

            if (oldlen != 0) // Get the old array literal.
                oldval = interpretRegion(e1, istate);
            UnionExp utmp = void;
            oldval = resolveSlice(oldval, &utmp);

            newval = changeArrayLiteralLength(pue, e.loc, cast(TypeArray)t, oldval, oldlen, newlen);
            if (newval == pue.exp())
                newval = pue.copy();

            e1 = assignToLvalue(e, e1, newval, istate);
            if (exceptionOrCant(e1))
                return;

            return;
        }

        if (!isBlockAssignment)
        {
            newval = ctfeCast(pue, e.loc, e.type, e.type, newval);
            if (exceptionOrCant(newval))
                return;
            if (newval == pue.exp())
                newval = pue.copy();

            // Determine the return value
            if (goal == CTFEGoal.LValue) // https://issues.dlang.org/show_bug.cgi?id=14371
                result = e1;
            else
            {
                result = ctfeCast(pue, e.loc, e.type, e.type, fp && post ? oldval : newval);
                if (result == pue.exp())
                    result = pue.copy();
            }
            if (exceptionOrCant(result))
                return;
        }
        if (exceptionOrCant(newval))
            return;

        debug (LOGASSIGN)
        {
            printf("ASSIGN: %s=%s\n", e1.toChars(), newval.toChars());
            showCtfeExpr(newval);
        }

        /* Block assignment or element-wise assignment.
         */
        if (e1.op == EXP.slice ||
            e1.op == EXP.vector ||
            e1.op == EXP.arrayLiteral ||
            e1.op == EXP.string_ ||
            e1.op == EXP.null_ && e1.type.toBasetype().ty == Tarray)
        {
            // Note that slice assignments don't support things like ++, so
            // we don't need to remember 'returnValue'.
            result = interpretAssignToSlice(pue, e, e1, newval, isBlockAssignment);
            if (exceptionOrCant(result))
                return;
            if (auto se = e.e1.isSliceExp())
            {
                Expression e1x = interpretRegion(se.e1, istate, CTFEGoal.LValue);
                if (auto dve = e1x.isDotVarExp())
                {
                    auto ex = dve.e1;
                    auto sle = ex.op == EXP.structLiteral ? ex.isStructLiteralExp()
                             : ex.op == EXP.classReference ? ex.isClassReferenceExp().value
                             : null;
                    auto v = dve.var.isVarDeclaration();
                    if (!sle || !v)
                    {
                        eSink.error(e.loc, "CTFE internal error: dotvar slice assignment");
                        result = CTFEExp.cantexp;
                        return;
                    }
                    stompOverlappedFields(sle, v);
                }
            }
            return;
        }
        assert(result);

        /* Assignment to a CTFE reference.
         */
        if (Expression ex = assignToLvalue(e, e1, newval, istate))
            result = ex;

        return;
    }

    /* Assignment fast path for a scalar variable whose value lives in linear
     * memory (or is still uninitialized): evaluates everything through
     * stack-allocated UnionExps and stores raw bytes, so a scalar assignment
     * makes no allocation at all.
     *
     * Returns: false if not eligible (nothing was evaluated yet, the caller
     * continues on the regular path), true if fully handled — `result` is
     * set, possibly to a thrown exception.
     */
    private bool interpretScalarVarAssign(BinExp e, VarExp ve, fp_t fp, int post)
    {
        VarDeclaration v = ve.var.isVarDeclaration();
        if (!v || !ctfeGlobals.stack.canStoreLinear(v))
            return false;
        // If an AST value is stored (e.g. void initialization), the regular
        // path handles the diagnostics
        if (ctfeGlobals.stack.hasAstValue(v))
            return false;

        if (interpretRawScalarAssign(e, ve, v, fp, post))
            return true;

        // Interpret the right hand side
        UnionExp ueRhs = void;
        Expression newval = interpret(&ueRhs, e.e2, istate);
        if (exceptionOrCant(newval))
            return true;

        // Read-modify-write assignments; load the left hand side after
        // interpreting the right hand side
        UnionExp ueOld = void;
        UnionExp ueFp = void;
        Expression oldval = null;
        if (fp)
        {
            oldval = interpret(&ueOld, ve, istate);
            if (exceptionOrCant(oldval))
                return true;
            // concatenation and pointer arithmetic cannot get here:
            // the variable's type is scalar
            ueFp = (*fp)(e.loc, e.type, oldval, newval);
            newval = ueFp.exp();
            if (exceptionOrCant(newval))
                return true;
        }

        UnionExp ueCast = void;
        newval = ctfeCast(&ueCast, e.loc, e.type, e.type, newval);
        if (exceptionOrCant(newval))
            return true;

        if (!ctfeGlobals.stack.storeLinear(v, newval))
        {
            // Not a scalar literal after all; persist the node and store it
            // as an AST value
            newval = persistUe(newval, ueCast);
            newval = persistUe(newval, ueFp);
            newval = persistUe(newval, ueRhs);
            setValue(v, newval);
        }

        // Determine the return value
        if (goal == CTFEGoal.LValue) // https://issues.dlang.org/show_bug.cgi?id=14371
            result = ve;
        else
        {
            result = ctfeCast(pue, e.loc, e.type, e.type, fp && post ? oldval : newval);
            if (exceptionOrCant(result))
                return true;
            result = relocateUe(result, ueOld);
            result = relocateUe(result, ueFp);
            result = relocateUe(result, ueCast);
            result = relocateUe(result, ueRhs);
        }
        return true;
    }

    /* `x = expr`, `x op= expr` and ++/-- entirely on raw bytes: eligible
     * when v's value already lives in a linear scalar slot, the type is
     * integral, and the RHS evaluates byte-natively — then no AST node is
     * built at all (except a result node when one is demanded). Bails with
     * false having evaluated nothing (supported RHS trees are
     * side-effect-free), so the caller runs the regular path.
     */
    private bool interpretRawScalarAssign(BinExp e, VarExp ve, VarDeclaration v, fp_t fp, int post)
    {
        const tyRes = e.type.toBasetype().ty;
        if (rawIntSize(tyRes) == 0)
            return false;
        const slot = ctfeGlobals.stack.scalarSlot(v);
        if (slot.isNull)
            return false; // no linear value bound yet: regular path allocates
        ulong rhs;
        if (!tryEvalScalarRaw(e.e2, rhs))
            return false;
        ulong oldval;
        ulong newval;
        if (fp)
        {
            EXP binop;
            switch (e.op)
            {
            case EXP.addAssign:
            case EXP.plusPlus:                 binop = EXP.add;                break;
            case EXP.minAssign:
            case EXP.minusMinus:               binop = EXP.min;                break;
            case EXP.mulAssign:                binop = EXP.mul;                break;
            case EXP.divAssign:                binop = EXP.div;                break;
            case EXP.modAssign:                binop = EXP.mod;                break;
            case EXP.andAssign:                binop = EXP.and;                break;
            case EXP.orAssign:                 binop = EXP.or;                 break;
            case EXP.xorAssign:                binop = EXP.xor;                break;
            case EXP.leftShiftAssign:          binop = EXP.leftShift;          break;
            case EXP.rightShiftAssign:         binop = EXP.rightShift;         break;
            case EXP.unsignedRightShiftAssign: binop = EXP.unsignedRightShift; break;
            default:
                return false;
            }
            if (!readRawScalar(slot, v.type, oldval))
                return false;
            // operand types as the regular path's IntegerExps would carry them
            if (!rawBinOp(binop, v.type.toBasetype().ty, e.e2.type.toBasetype().ty,
                    oldval, rhs, tyRes, newval))
                return false;
        }
        else
            newval = normalizeRawInt(rhs, tyRes); // ctfeCast to the same type = paint

        const sz = rawIntSize(v.type.toBasetype().ty);
        if (sz == 0)
            return false;
        auto s = ctfeGlobals.linearMem.slice(slot, sz);
        if (s is null)
            return false;
        memcpy(s.ptr, &newval, sz); // little endian

        if (goal == CTFEGoal.LValue) // https://issues.dlang.org/show_bug.cgi?id=14371
            result = ve;
        else
        {
            emplaceExp!(IntegerExp)(pue, e.loc, fp && post ? oldval : newval, e.type);
            result = pue.exp();
        }
        return true;
    }

    /* Try to resolve the lvalue chain `e` — IndexExp / DotVarExp nodes and
     * CTFE references held by `ref` variables, rooted in a slice whose value
     * lives in linear memory — to the location `p` of a value of type `t`
     * (an array element, or a field within one).
     *
     * Returns: 1 if resolved; 0 if the chain is not rooted in linear memory
     * (guaranteed: nothing was evaluated yet, so the caller can safely fall
     * back to the regular path); -1 on an error or exception while
     * evaluating an index (`result` is set, the caller returns).
     */
    private int tryResolveLinearLoc(Expression e, out CtfePtr p, out Type t)
    {
        if (auto ve = e.isVarExp())
        {
            // a `ref` variable holds a CTFE reference expression; chase it
            auto v = ve.var.isVarDeclaration();
            if (!v || !(v.storage_class & (STC.ref_ | STC.out_)))
                return 0;
            Expression ev = ctfeGlobals.stack.astValue(v);
            if (ev is null)
                return 0;
            if (ev.op == EXP.index || ev.op == EXP.dotVariable || ev.op == EXP.variable)
                return tryResolveLinearLoc(ev, p, t);
            return 0;
        }

        if (auto ie = e.isIndexExp())
        {
            if (ie.e1.type.toBasetype().ty != Tarray)
                return 0;
            auto bve = ie.e1.isVarExp();
            if (!bve)
                return 0;
            auto bv = bve.var.isVarDeclaration();
            if (!bv)
                return 0;
            const slot = ctfeGlobals.stack.sliceSlot(bv);
            LinearSlice s;
            if (slot.isNull || !readSlice(ctfeGlobals.linearMem, slot, s))
                return 0;
            Type telem = bv.type.toBasetype().isTypeDArray().next;

            // committed from here: evaluating the index may have side effects
            if (ie.lengthVar)
            {
                Expression dollarExp = ctfeEmplaceExp!IntegerExp(ie.loc, s.length, Type.tsize_t);
                ctfeGlobals.stack.push(ie.lengthVar);
                setValue(ie.lengthVar, dollarExp);
            }
            UnionExp ue2 = void;
            Expression e2 = interpret(&ue2, ie.e2, istate);
            if (ie.lengthVar)
                ctfeGlobals.stack.pop(ie.lengthVar); // $ is defined only inside []
            if (exceptionOrCant(e2))
                return -1;
            if (e2.op != EXP.int64)
            {
                error(ie.loc, "CTFE internal error: non-integral index `[%s]`", ie.e2.toErrMsg());
                result = CTFEExp.cantexp;
                return -1;
            }
            const idx = e2.toInteger();
            if (idx >= s.length)
            {
                error(ie.loc, "array index %lld is out of bounds `[0..%lld]`", idx, cast(ulong) s.length);
                result = CTFEExp.cantexp;
                return -1;
            }
            const esz = cast(uint) telem.size();
            p = CtfePtr(s.alloc, cast(uint)(s.offset + idx * esz));
            t = telem;
            return 1;
        }

        if (auto dve = e.isDotVarExp())
        {
            // a field within a struct element
            if (dve.e1.type.toBasetype().ty != Tstruct)
                return 0;
            // overlapped (union) members are fine: the bytes at the member's
            // offset are the value, reads just reinterpret them
            auto fv = dve.var.isVarDeclaration();
            if (!fv || fv.isBitFieldDeclaration())
                return 0;
            const rc = tryResolveLinearLoc(dve.e1, p, t);
            if (rc != 1)
                return rc;
            if (t.toBasetype().isTypeStruct() is null)
            {
                error(e.loc, "CTFE internal error: `%s`", e.toErrMsg());
                result = CTFEExp.cantexp;
                return -1;
            }
            p.offset += fv.offset;
            t = fv.type;
            return 1;
        }

        return 0;
    }

    /* Fast path for scalar assignments through an lvalue chain rooted in a
     * slice whose value lives in linear memory: `a[i] = e2`, `a[i] op= e2`,
     * `a[i].field op= e2`, `p.field = e2` (p a ref into an element),
     * including ++/--. Mirrors interpretScalarVarAssign: everything runs
     * through stack-allocated UnionExps and raw byte stores.
     *
     * Returns: false if not eligible (nothing evaluated yet, the caller
     * continues on the regular path), true if fully handled — `result` is
     * set, possibly to a thrown exception.
     */
    private bool interpretLinearLocAssign(BinExp e, fp_t fp, int post)
    {
        // Scalar-typed lvalues, and plain assignments of whole POD struct
        // elements; decided by shape before anything runs
        const scalar = isLinearScalarType(e.e1.type);
        if (!scalar && !(fp is null && isLinearPodStruct(e.e1.type)))
            return false;
        CtfePtr p;
        Type t;
        const rc = tryResolveLinearLoc(e.e1, p, t);
        if (rc == 0)
            return false;
        if (rc < 0)
            return true; // result is set

        // The left hand side is resolved (indexes evaluated);
        // interpret the right hand side
        UnionExp ueRhs = void;
        Expression newval = interpret(&ueRhs, e.e2, istate);
        if (exceptionOrCant(newval))
            return true;

        UnionExp ueOld = void;
        UnionExp ueFp = void;
        Expression oldval = null;
        if (fp)
        {
            oldval = decodeScalar(ctfeGlobals.linearMem, p, e.e1.type, e.e1.loc, &ueOld);
            if (oldval is null)
            {
                error(e.loc, "cannot interpret `%s` at compile time", e.toErrMsg());
                result = CTFEExp.cantexp;
                return true;
            }
            // concatenation and pointer arithmetic cannot get here:
            // the lvalue's type is scalar
            ueFp = (*fp)(e.loc, e.type, oldval, newval);
            newval = ueFp.exp();
            if (exceptionOrCant(newval))
                return true;
        }

        UnionExp ueCast = void;
        newval = ctfeCast(&ueCast, e.loc, e.type, e.type, newval);
        if (exceptionOrCant(newval))
            return true;

        if (!encodeInto(ctfeGlobals.linearMem, newval, t, p))
        {
            error(e.loc, "cannot interpret `%s` at compile time", e.toErrMsg());
            result = CTFEExp.cantexp;
            return true;
        }

        // Determine the return value
        if (goal == CTFEGoal.LValue)
            result = e.e1; // the chain is a CTFE reference
        else
        {
            result = ctfeCast(pue, e.loc, e.type, e.type, fp && post ? oldval : newval);
            if (exceptionOrCant(result))
                return true;
            result = relocateUe(result, ueOld);
            result = relocateUe(result, ueFp);
            result = relocateUe(result, ueCast);
            result = relocateUe(result, ueRhs);
        }
        return true;
    }

    /* Fast path for reference assignments producing linear slice values:
     * `b = a`, `b = a[]`, `b = a[l..u]` (a's value linear) copy or narrow the
     * 16-byte handle and mark the payload shared — the payload itself is not
     * copied, preserving aliasing. `b = new T[](n)` creates a payload of
     * default-initialized elements without ever building an array node.
     *
     * Returns: false if not eligible (nothing evaluated yet, the caller
     * continues on the regular path), true if fully handled — `result` is
     * set, possibly to a thrown exception.
     */
    private bool interpretSliceHandleAssign(BinExp e, VarExp ve)
    {
        if (e.op != EXP.assign && e.op != EXP.construct && e.op != EXP.blit)
            return false;
        VarDeclaration v = ve.var.isVarDeclaration();
        if (!v || !ctfeGlobals.stack.canStoreLinearSlice(v))
            return false;
        // the handle store below must not need a new slot in an outer frame
        if (!ctfeGlobals.stack.hasLinearSlot(v) && !ctfeGlobals.stack.isInCurrentFrame(v))
            return false;
        auto ta = v.type.toBasetype().isTypeDArray();
        if (!ta)
            return false;
        const eszl = ta.next.size();
        if (eszl == SIZE_INVALID || eszl == 0)
            return false;
        const esz = cast(uint) eszl;
        auto lmem = &ctfeGlobals.linearMem;

        LinearSlice s;
        bool stored = false;

        // Case 1: the right hand side is an existing linear slice value
        if (auto ta2 = e.e2.type.toBasetype().isTypeDArray())
        {
            if (ta2.next.size() == esz)
            {
                Expression err;
                const rc = readLinearSliceValue(e.e2, istate, s, &err);
                if (rc < 0)
                {
                    result = err;
                    return true;
                }
                if (rc > 0)
                {
                    // both v and the source now reference the payload
                    markPayloadShared(s);
                    if (!ctfeGlobals.stack.storeLinearSlice(v, s))
                    {
                        error(e.loc, "cannot interpret `%s` at compile time", e.toErrMsg());
                        result = CTFEExp.cantexp;
                        return true;
                    }
                    stored = true;
                }
            }
        }

        // Case 2: the right hand side is `new T[](n)`
        if (!stored)
        {
            auto ne = e.e2.isNewExp();
            if (ne is null || ne.placement !is null || ne.member !is null ||
                ne.arguments is null || ne.arguments.length != 1)
                return false;
            auto tan = ne.newtype.toBasetype().isTypeDArray();
            if (!tan || tan.next.size() != esz || !isLinearSliceType(ne.newtype))
                return false;
            Type telem = tan.next;

            // committed from here
            UnionExp uePre = void;
            Expression epre = interpret(&uePre, ne.argprefix, istate, CTFEGoal.Nothing);
            if (exceptionOrCant(epre))
                return true;
            UnionExp ueLen = void;
            Expression elen = interpret(&ueLen, (*ne.arguments)[0], istate);
            if (exceptionOrCant(elen))
                return true;
            if (elen.op != EXP.int64)
            {
                error(e.loc, "CTFE internal error: non-integral array length `%s`", e.toErrMsg());
                result = CTFEExp.cantexp;
                return true;
            }
            const len = elen.toInteger();
            if (ulong(esz) * len + PayloadHeader.sizeof > CtfeMemory.maxAllocSize)
            {
                error(e.loc, "array dimension %llu exceeds maximum CTFE array size", cast(ulong) len);
                result = CTFEExp.cantexp;
                return true;
            }
            s = allocatePayload(*lmem, esz, cast(uint) len, cast(uint) len);
            Expression defaultElem = telem.defaultInitLiteral(e.loc);
            if (s.alloc == 0 || defaultElem is null || defaultElem.op == EXP.error)
            {
                error(e.loc, "cannot interpret `%s` at compile time", e.toErrMsg());
                result = CTFEExp.cantexp;
                return true;
            }
            foreach (i; 0 .. cast(size_t) len)
            {
                const dst = CtfePtr(s.alloc, cast(uint)(PayloadHeader.sizeof + i * esz));
                if (!encodeInto(*lmem, defaultElem, telem, dst))
                {
                    error(e.loc, "cannot interpret `%s` at compile time", e.toErrMsg());
                    result = CTFEExp.cantexp;
                    return true;
                }
            }
            if (!ctfeGlobals.stack.storeLinearSlice(v, s))
            {
                error(e.loc, "cannot interpret `%s` at compile time", e.toErrMsg());
                result = CTFEExp.cantexp;
                return true;
            }
        }

        // Determine the return value
        if (goal == CTFEGoal.RValue)
        {
            // The array value escapes into the expression; flipping to the
            // AST representation keeps aliasing correct
            result = ctfeGlobals.stack.getValue(v);
            if (result is null)
                result = CTFEExp.cantexp;
        }
        else
            result = ve; // VarExp is a CTFE reference
        return true;
    }

    /* Store a slice return value handed over as a linear handle (see
     * CtfeGlobals.linearReturnDest) into v. No sharing mark is needed: any
     * aliasing event before the hand-over (handle assignment, argument
     * staging) already set the sticky payloadShared flag on the payload.
     *
     * Returns: false if the handle could not be stored (the caller
     * materializes the value and continues generically); true if the
     * assignment completed (result is set).
     */
    private bool interpretLinearReturnAssign(BinExp e, VarExp ve, VarDeclaration v, LinearSlice s)
    {
        auto ta = v.type.toBasetype().isTypeDArray();
        if (!ta)
            return false;
        if (s.alloc != 0)
        {
            PayloadHeader h;
            if (!readPayloadHeader(ctfeGlobals.linearMem, s.alloc, h) ||
                h.elemSize != ta.next.size())
                return false;
        }
        if (!ctfeGlobals.stack.storeLinearSlice(v, s))
            return false;
        if (goal == CTFEGoal.RValue)
        {
            // The array value escapes into the expression; flipping to the
            // AST representation keeps aliasing correct
            result = ctfeGlobals.stack.getValue(v);
            if (result is null)
                result = CTFEExp.cantexp;
        }
        else
            result = ve; // VarExp is a CTFE reference
        return true;
    }

    /* Fast path for `v.length = n` when v's value can live in linear memory:
     * shrinks by adjusting the handle, grows in place (or by moving the
     * payload), filling new elements with the element type's default
     * initializer. The caller has already determined `result`.
     *
     * Returns: false if not eligible or a value shape is unsupported;
     * nothing observable was mutated in that case, so the caller continues
     * on the regular path.
     */
    private bool interpretLinearLengthAssign(BinExp e, VarExp ve, size_t oldlen, size_t newlen)
    {
        VarDeclaration v = ve.var.isVarDeclaration();
        if (!v || !ctfeGlobals.stack.canStoreLinearSlice(v))
            return false;
        auto ta = v.type.toBasetype().isTypeDArray();
        if (!ta)
            return false;
        Type telem = ta.next;
        const esz = cast(uint) telem.size();
        auto lmem = &ctfeGlobals.linearMem;

        if (ulong(esz) * newlen + PayloadHeader.sizeof > CtfeMemory.maxAllocSize)
            return false; // out of linear memory; the regular path errors out

        // Get the current value, like in interpretSliceCatAssign
        LinearSlice s;
        const slot = ctfeGlobals.stack.sliceSlot(v);
        if (!slot.isNull)
        {
            if (!readSlice(*lmem, slot, s))
                return false;
        }
        else
        {
            if (!ctfeGlobals.stack.isInCurrentFrame(v))
                return false;
            /* Only adopt empty arrays into linear memory here. Encoding an
             * existing AST array would pay off only if later operations stay
             * linear, but the common shape of resize-and-return functions is
             * that the result escapes straight back to an AST consumer (a
             * struct field, a global), turning every call into a whole-array
             * encode + decode round trip that loses to the plain AST resize.
             */
            if (oldlen != 0)
                return false;
            Expression oldval = ctfeGlobals.stack.getValue(v);
            if (oldval is null)
                return false;
            if (!encodeSlice(*lmem, oldval, v.type, s))
                return false;
        }
        if (s.length != oldlen)
            return false; // e.g. modified by a side effect of the length expression

        PayloadHeader h;
        if (s.alloc != 0)
        {
            if (!readPayloadHeader(*lmem, s.alloc, h))
                return false;
            // must cover the whole array object
            if (s.offset != PayloadHeader.sizeof || s.length != h.used || h.elemSize != esz)
                return false;
            if (h.flags & payloadShared)
            {
                /* Detach with a copy. This matches the AST semantics of
                 * changeArrayLiteralLength, which gives the resized array
                 * fresh element storage: element nodes stay shared, but for
                 * scalar elements node sharing is unobservable (assignment
                 * replaces the node). Struct/sarray elements keep observable
                 * node aliasing, so those stay on the AST path.
                 */
                if (!isLinearScalarType(telem))
                    return false;
                const keep = oldlen < newlen ? oldlen : newlen;
                auto ns = allocatePayload(*lmem, esz, cast(uint) keep, cast(uint) newlen);
                if (ns.alloc == 0)
                    return false;
                if (keep && !lmem.copy(CtfePtr(ns.alloc, ns.offset), CtfePtr(s.alloc, s.offset), cast(uint)(keep * esz)))
                    return false;
                s = LinearSlice(ns.alloc, ns.offset, cast(uint) keep);
                if (!readPayloadHeader(*lmem, s.alloc, h))
                    return false;
            }
        }

        if (newlen > oldlen)
        {
            // Grow, and default-initialize the new elements
            Expression defaultElem = telem.defaultInitLiteral(e.loc);
            if (defaultElem is null || defaultElem.op == EXP.error)
                return false;
            if (s.alloc == 0)
            {
                s = allocatePayload(*lmem, esz, cast(uint) newlen, cast(uint) newlen);
                if (s.alloc == 0 || !readPayloadHeader(*lmem, s.alloc, h))
                    return false;
            }
            else if (newlen > h.capacity)
            {
                const newBytes = cast(uint)(ulong(esz) * newlen + PayloadHeader.sizeof);
                if (lmem.extendInPlace(s.alloc, newBytes))
                {
                    h.capacity = cast(uint) newlen;
                }
                else
                {
                    auto ns = allocatePayload(*lmem, esz, cast(uint) newlen, cast(uint) newlen);
                    if (ns.alloc == 0)
                        return false;
                    if (!lmem.copy(CtfePtr(ns.alloc, ns.offset), CtfePtr(s.alloc, s.offset), cast(uint)(oldlen * esz)))
                        return false;
                    s.alloc = ns.alloc;
                    s.offset = ns.offset;
                    if (!readPayloadHeader(*lmem, s.alloc, h))
                        return false;
                }
            }
            foreach (i; oldlen .. newlen)
            {
                const dst = CtfePtr(s.alloc, cast(uint)(PayloadHeader.sizeof + i * esz));
                if (!encodeInto(*lmem, defaultElem, telem, dst))
                    return false; // header/slot untouched, safe to fall back
            }
        }
        // else: shrink, just narrow the handle and the header below

        // Publish the new array object
        h.used = cast(uint) newlen;
        if (!writePayloadHeader(*lmem, s.alloc, h))
            return false;
        s.offset = PayloadHeader.sizeof;
        s.length = cast(uint) newlen;
        if (!slot.isNull)
        {
            if (!writeSlice(*lmem, slot, s))
                return false;
        }
        else if (!ctfeGlobals.stack.storeLinearSlice(v, s))
            return false;
        return true;
    }

    /* Fast path for `v ~= e2` when v's value can live in linear memory:
     * appends to the slice payload in place (amortizing reallocations with
     * capacity doubling) instead of concatenating into a whole new array node.
     *
     * `newval` is the already interpreted right hand side. Returns: false if
     * not eligible or a value shape is unsupported; nothing observable was
     * mutated in that case (at worst payload bytes not yet published to the
     * variable's slot), so the caller continues on the regular path, which
     * flips any linear value of v back to an AST node when loading it.
     */
    private bool interpretSliceCatAssign(BinExp e, VarExp ve, Expression newval)
    {
        VarDeclaration v = ve.var.isVarDeclaration();
        if (!v || !ctfeGlobals.stack.canStoreLinearSlice(v))
            return false;
        auto ta = v.type.toBasetype().isTypeDArray();
        if (!ta)
            return false;
        Type telem = ta.next;
        const esz = cast(uint) telem.size();
        auto lmem = &ctfeGlobals.linearMem;

        // Get the current value: either already a linear handle, or an AST
        // value worth encoding because subsequent appends then stay linear
        LinearSlice s;
        const slot = ctfeGlobals.stack.sliceSlot(v);
        if (!slot.isNull)
        {
            if (!readSlice(*lmem, slot, s))
                return false;
        }
        else
        {
            // The slot has yet to be allocated, which storeLinearSlice below
            // only does for entries of the current frame
            if (!ctfeGlobals.stack.isInCurrentFrame(v))
                return false;
            Expression oldval = ctfeGlobals.stack.getValue(v);
            if (oldval is null)
                return false; // not initialized; let the regular path diagnose
            if (!encodeSlice(*lmem, oldval, v.type, s))
                return false; // e.g. a SliceExp value, keep the AST representation
        }

        PayloadHeader h;
        if (s.alloc != 0)
        {
            if (!readPayloadHeader(*lmem, s.alloc, h))
                return false;
            // must be the sole handle, covering the whole array object
            if (s.offset != PayloadHeader.sizeof || s.length != h.used || h.elemSize != esz)
                return false;
        }

        // Classify the right hand side before mutating anything
        uint n;
        StringExp rhsStr = null;
        ArrayLiteralExp rhsArr = null;
        UnionExp ueSlice = void;
        if (e.op == EXP.concatenateElemAssign)
        {
            n = 1;
        }
        else
        {
            newval = resolveSlice(newval, &ueSlice);
            if (newval.op == EXP.null_)
                n = 0;
            else if (auto se = newval.isStringExp())
            {
                if (se.sz != esz)
                    return false;
                n = cast(uint) se.len;
                rhsStr = se;
            }
            else if (auto ale = newval.isArrayLiteralExp())
            {
                n = cast(uint)(ale.elements ? ale.elements.length : 0);
                rhsArr = ale;
            }
            else
                return false;
        }

        const oldUsed = s.length;
        const newUsed = ulong(oldUsed) + n;
        if (ulong(esz) * newUsed + PayloadHeader.sizeof > CtfeMemory.maxAllocSize)
            return false; // out of linear memory; the regular path errors out

        // Make room for the new elements. A shared payload must be detached
        // first: `~=` gives the variable a new array object, like the AST
        // representation's concatenation does.
        const mustDetach = (h.flags & payloadShared) != 0;
        if (s.alloc == 0)
        {
            s = allocatePayload(*lmem, esz, cast(uint) newUsed, cast(uint)(newUsed < 8 ? 8 : newUsed));
            if (s.alloc == 0 || !readPayloadHeader(*lmem, s.alloc, h))
                return false;
        }
        else if (mustDetach || newUsed > h.capacity)
        {
            ulong newCapL = ulong(h.capacity) * 2;
            if (newCapL < newUsed)
                newCapL = newUsed;
            if (newCapL < 8)
                newCapL = 8;
            if (ulong(esz) * newCapL + PayloadHeader.sizeof > CtfeMemory.maxAllocSize)
                newCapL = newUsed; // known to fit from the check above
            const newCap = cast(uint) newCapL;
            const newBytes = cast(uint)(ulong(esz) * newCap + PayloadHeader.sizeof);
            if (!mustDetach && lmem.extendInPlace(s.alloc, newBytes))
            {
                h.capacity = newCap;
            }
            else
            {
                // detach from other handles, or move a full payload
                auto ns = allocatePayload(*lmem, esz, cast(uint) newUsed, newCap);
                if (ns.alloc == 0)
                    return false;
                if (!lmem.copy(CtfePtr(ns.alloc, ns.offset), CtfePtr(s.alloc, s.offset), oldUsed * esz))
                    return false;
                s.alloc = ns.alloc;
                s.offset = ns.offset;
                if (!readPayloadHeader(*lmem, s.alloc, h))
                    return false;
            }
        }

        // Serialize the new elements after the existing ones
        const dstOff = cast(uint)(PayloadHeader.sizeof + oldUsed * esz);
        if (e.op == EXP.concatenateElemAssign)
        {
            if (!encodeInto(*lmem, newval, telem, CtfePtr(s.alloc, dstOff)))
                return false;
        }
        else if (rhsStr)
        {
            auto b = lmem.slice(CtfePtr(s.alloc, dstOff), n * esz);
            if (b is null)
                return false;
            const data = rhsStr.peekData();
            memcpy(b.ptr, data.ptr, n * esz);
        }
        else if (rhsArr)
        {
            foreach (i; 0 .. n)
            {
                Expression el = (*rhsArr.elements)[i];
                if (el is null)
                    el = rhsArr.basis;
                if (el is null ||
                    !encodeInto(*lmem, el, telem, CtfePtr(s.alloc, dstOff + i * esz)))
                    return false;
            }
        }

        // Publish the new array object
        h.used = cast(uint) newUsed;
        if (!writePayloadHeader(*lmem, s.alloc, h))
            return false;
        s.offset = PayloadHeader.sizeof;
        s.length = h.used;
        if (!slot.isNull)
        {
            if (!writeSlice(*lmem, slot, s))
                return false;
        }
        else if (!ctfeGlobals.stack.storeLinearSlice(v, s))
            return false;

        // Determine the return value
        if (goal == CTFEGoal.RValue)
        {
            // The array value escapes into the expression; flipping to the
            // AST representation keeps aliasing correct
            result = ctfeGlobals.stack.getValue(v);
            if (result is null)
                result = CTFEExp.cantexp;
        }
        else
            result = ve; // VarExp is a CTFE reference
        return true;
    }

    // If x still lives in local UnionExp u, move it into the caller-owned
    // result storage `*pue` (expression nodes are relocatable).
    private Expression relocateUe(Expression x, ref UnionExp u)
    {
        if (x != u.exp())
            return x;
        *pue = u;
        return pue.exp();
    }

    // If x lives in local UnionExp u, copy it into the CTFE region so it
    // survives this call.
    private static Expression persistUe(Expression x, ref UnionExp u)
    {
        return x == u.exp() ? regionUeCopy(u) : x;
    }

    /* Set all sibling fields which overlap with v to VoidExp.
     */
    private static void stompOverlappedFields(StructLiteralExp sle, VarDeclaration v)
    {
        if (!v.overlapped)
            return;
        foreach (size_t i, v2; sle.sd.fields)
        {
            if (v is v2 || !v.isOverlappedWith(v2))
                continue;
            auto e = (*sle.elements)[i];
            if (e !is null && e.op != EXP.void_)
                (*sle.elements)[i] = voidInitLiteral(e.type, v2).copy();
        }
    }

    private static Expression assignToLvalue(BinExp e, Expression e1, Expression newval, InterState* istate)
    {
        //printf("assignToLvalue() e: %s e1: %s newval: %s\n", e.toChars(), e1.toChars(), newval.toChars());
        VarDeclaration vd = null;
        Expression* payload = null; // dead-store to prevent spurious warning
        Expression oldval;
        auto eSink = global.errorSink;

        if (auto ve = e1.isVarExp())
        {
            vd = ve.var.isVarDeclaration();
            oldval = getValue(vd);
        }
        else if (auto dve = e1.isDotVarExp())
        {
            /* Assignment to member variable of the form:
             *  e.v = newval
             */
            auto ex = dve.e1;
            auto sle = ex.op == EXP.structLiteral ? ex.isStructLiteralExp()
                     : ex.op == EXP.classReference ? ex.isClassReferenceExp().value
                     : null;
            auto v = e1.isDotVarExp().var.isVarDeclaration();
            if (!sle || !v)
            {
                eSink.error(e.loc, "CTFE internal error: dotvar assignment");
                return CTFEExp.cantexp;
            }
            if (sle.ownedByCtfe != OwnedBy.ctfe)
            {
                eSink.error(e.loc, "cannot modify read-only constant `%s`", sle.toErrMsg());
                return CTFEExp.cantexp;
            }

            int fieldi = ex.op == EXP.structLiteral ? findFieldIndexByName(sle.sd, v)
                       : ex.isClassReferenceExp().findFieldIndexByName(v);
            if (fieldi == -1)
            {
                eSink.error(e.loc, "CTFE internal error: cannot find field `%s` in `%s`", v.toErrMsg(), ex.toErrMsg());
                return CTFEExp.cantexp;
            }
            assert(0 <= fieldi && fieldi < sle.elements.length);

            // If it's a union, set all other members of this union to void
            stompOverlappedFields(sle, v);

            payload = &(*sle.elements)[fieldi];
            oldval = *payload;
            if (auto ival = newval.isIntegerExp())
            {
                if (auto bf = v.isBitFieldDeclaration())
                {
                    sinteger_t value = ival.toInteger();
                    if (bf.type.isUnsigned())
                        value &= (1L << bf.fieldWidth) - 1; // zero extra bits
                    else
                    {   // sign extend extra bits
                        value = value << (64 - bf.fieldWidth);
                        value = value >> (64 - bf.fieldWidth);
                    }
                    ival.setInteger(value);
                }
            }
        }
        else if (auto ie = e1.isIndexExp())
        {
            assert(ie.e1.type.toBasetype().ty != Taarray);

            Expression aggregate;
            uinteger_t indexToModify;
            if (!resolveIndexing(ie, istate, &aggregate, &indexToModify, true))
            {
                return CTFEExp.cantexp;
            }
            size_t index = cast(size_t)indexToModify;

            if (auto existingSE = aggregate.isStringExp())
            {
                if (existingSE.ownedByCtfe != OwnedBy.ctfe)
                {
                    eSink.error(e.loc, "cannot modify read-only string literal `%s`", ie.e1.toErrMsg());
                    return CTFEExp.cantexp;
                }
                existingSE.setCodeUnit(index, cast(dchar)newval.toInteger());
                return null;
            }
            if (aggregate.op != EXP.arrayLiteral)
            {
                eSink.error(e.loc, "index assignment `%s` is not yet supported in CTFE ", e.toErrMsg());
                return CTFEExp.cantexp;
            }

            ArrayLiteralExp existingAE = aggregate.isArrayLiteralExp();
            if (existingAE.ownedByCtfe != OwnedBy.ctfe)
            {
                Expression literal = existingAE.aaLiteral ? existingAE.aaLiteral : existingAE;
                eSink.error(e.loc, "cannot modify read-only constant `%s`", literal.toErrMsg());
                return CTFEExp.cantexp;
            }

            payload = &(*existingAE.elements)[index];
            oldval = *payload;
        }
        else
        {
            eSink.error(e.loc, "`%s` cannot be evaluated at compile time", e.toErrMsg());
            return CTFEExp.cantexp;
        }

        Type t1b = e1.type.toBasetype();
        bool wantCopy = t1b.baseElemOf().ty == Tstruct;

        if (auto ve = newval.isVectorExp())
        {
            // Ensure ve is an array literal, and not a broadcast
            if (ve.e1.op == EXP.int64 || ve.e1.op == EXP.float64) // if broadcast
            {
                UnionExp ue = void;
                Expression ex = interpretVectorToArray(&ue, ve);
                ve.e1 = (ex == ue.exp()) ? ue.copy() : ex;
            }
        }

        if (newval.op == EXP.structLiteral && oldval)
        {
            assert(oldval.op == EXP.structLiteral || oldval.op == EXP.arrayLiteral || oldval.op == EXP.string_);
            newval = copyLiteral(newval).copy();
            assignInPlace(oldval, newval);
        }
        else if (wantCopy && (e.op == EXP.assign || e.op == EXP.loweredAssignExp))
        {
            // Currently postblit/destructor calls on static array are done
            // in the druntime internal functions so they don't appear in AST.
            // Therefore interpreter should handle them specially.

            assert(oldval);
            version (all) // todo: instead we can directly access to each elements of the slice
            {
                newval = resolveSlice(newval);
                if (CTFEExp.isCantExp(newval))
                {
                    eSink.error(e.loc, "CTFE internal error: assignment `%s`", e.toErrMsg());
                    return CTFEExp.cantexp;
                }
            }
            assert(oldval.op == EXP.arrayLiteral);
            assert(newval.op == EXP.arrayLiteral);

            Expressions* oldelems = oldval.isArrayLiteralExp().elements;
            Expressions* newelems = newval.isArrayLiteralExp().elements;
            assert(oldelems.length == newelems.length);

            Type elemtype = oldval.type.nextOf();
            foreach (i, ref oldelem; *oldelems)
            {
                Expression newelem = paintTypeOntoLiteral(elemtype, (*newelems)[i]);
                // https://issues.dlang.org/show_bug.cgi?id=9245
                if (e.e2.isLvalue())
                {
                    if (Expression ex = evaluatePostblit(istate, newelem))
                        return ex;
                }
                // https://issues.dlang.org/show_bug.cgi?id=13661
                if (Expression ex = evaluateDtor(istate, oldelem))
                    return ex;
                oldelem = newelem;
            }
        }
        else
        {
            // e1 has its own payload, so we have to create a new literal.
            if (wantCopy)
                newval = copyLiteral(newval).copy();

            if (t1b.ty == Tsarray && e.op == EXP.construct && e.e2.isLvalue())
            {
                // https://issues.dlang.org/show_bug.cgi?id=9245
                if (Expression ex = evaluatePostblit(istate, newval))
                    return ex;
            }

            oldval = newval;
        }

        if (vd)
            setValue(vd, oldval);
        else
            *payload = oldval;

        // Blit assignment should return the newly created value.
        if (e.op == EXP.blit)
            return oldval;

        return null;
    }

    /*************
     * Deal with assignments of the form:
     *  dest[] = newval
     *  dest[low..upp] = newval
     * where newval has already been interpreted
     *
     * This could be a slice assignment or a block assignment, and
     * dest could be either an array literal, or a string.
     *
     * Returns EXP.cantExpression on failure. If there are no errors,
     * it returns aggregate[low..upp], except that as an optimisation,
     * if goal == CTFEGoal.Nothing, it will return NULL
     */
    private Expression interpretAssignToSlice(UnionExp* pue, BinExp e, Expression e1, Expression newval, bool isBlockAssignment)
    {
        //printf("interpretAssignToSlice(e: %s e1: %s newval: %s\n", e.toChars(), e1.toChars(), newval.toChars());

        dinteger_t lowerbound;
        dinteger_t upperbound;
        dinteger_t firstIndex;

        Expression aggregate;

        if (auto se = e1.isSliceExp())
        {
            // ------------------------------
            //   aggregate[] = newval
            //   aggregate[low..upp] = newval
            // ------------------------------
            aggregate = interpretRegion(se.e1, istate);
            lowerbound = se.lwr ? se.lwr.toInteger() : 0;
            upperbound = se.upr ? se.upr.toInteger() : resolveArrayLength(aggregate);

            // Slice of a slice --> change the bounds
            if (auto oldse = aggregate.isSliceExp())
            {
                aggregate = oldse.e1;
                firstIndex = lowerbound + oldse.lwr.toInteger();
            }
            else
                firstIndex = lowerbound;
        }
        else
        {
            if (auto ale = e1.isArrayLiteralExp())
            {
                lowerbound = 0;
                upperbound = ale.length;
            }
            else if (auto se = e1.isStringExp())
            {
                lowerbound = 0;
                upperbound = se.len;
            }
            else if (e1.op == EXP.null_)
            {
                lowerbound = 0;
                upperbound = 0;
            }
            else if (VectorExp ve = e1.isVectorExp())
            {
                // ve is not handled but a proper error message is returned
                // this is to prevent https://issues.dlang.org/show_bug.cgi?id=20042
                lowerbound = 0;
                upperbound = ve.dim;
            }
            else
                assert(0);

            aggregate = e1;
            firstIndex = lowerbound;
        }
        if (upperbound == lowerbound)
            return newval;

        // For slice assignment, we check that the lengths match.
        if (!isBlockAssignment && e1.type.ty != Tpointer)
        {
            const srclen = resolveArrayLength(newval);
            if (srclen != (upperbound - lowerbound))
            {
                eSink.error(e.loc, "array length mismatch assigning `[0..%llu]` to `[%llu..%llu]`",
                    ulong(srclen), ulong(lowerbound), ulong(upperbound));
                return CTFEExp.cantexp;
            }
        }

        if (auto existingSE = aggregate.isStringExp())
        {
            if (existingSE.ownedByCtfe != OwnedBy.ctfe)
            {
                eSink.error(e.loc, "cannot modify read-only string literal `%s`", existingSE.toErrMsg());
                return CTFEExp.cantexp;
            }

            if (auto se = newval.isSliceExp())
            {
                auto aggr2 = se.e1;
                const srclower = se.lwr.toInteger();
                const srcupper = se.upr.toInteger();

                if (aggregate == aggr2 &&
                    lowerbound < srcupper && srclower < upperbound)
                {
                    eSink.error(e.loc, "overlapping slice assignment `[%llu..%llu] = [%llu..%llu]`",
                        ulong(lowerbound), ulong(upperbound), ulong(srclower), ulong(srcupper));
                    return CTFEExp.cantexp;
                }
                version (all) // todo: instead we can directly access to each elements of the slice
                {
                    Expression orignewval = newval;
                    newval = resolveSlice(newval);
                    if (CTFEExp.isCantExp(newval))
                    {
                        eSink.error(e.loc, "CTFE internal error: slice `%s`", orignewval.toErrMsg());
                        return CTFEExp.cantexp;
                    }
                }
                assert(newval.op != EXP.slice);
            }
            if (auto se = newval.isStringExp())
            {
                sliceAssignStringFromString(existingSE, se, cast(size_t)firstIndex);
                return newval;
            }
            if (auto ale = newval.isArrayLiteralExp())
            {
                /* Mixed slice: it was initialized as a string literal.
                 * Now a slice of it is being set with an array literal.
                 */
                sliceAssignStringFromArrayLiteral(existingSE, ale, cast(size_t)firstIndex);
                return newval;
            }

            // String literal block slice assign
            const value = cast(dchar)newval.toInteger();
            foreach (i; 0 .. upperbound - lowerbound)
            {
                existingSE.setCodeUnit(cast(size_t)(i + firstIndex), value);
            }
            if (goal == CTFEGoal.Nothing)
                return null; // avoid creating an unused literal
            auto retslice = ctfeEmplaceExp!SliceExp(e.loc, existingSE,
                        ctfeEmplaceExp!IntegerExp(e.loc, firstIndex, Type.tsize_t),
                        ctfeEmplaceExp!IntegerExp(e.loc, firstIndex + upperbound - lowerbound, Type.tsize_t));
            retslice.type = e.type;
            return interpret(pue, retslice, istate);
        }
        if (auto existingAE = aggregate.isArrayLiteralExp())
        {
            if (existingAE.ownedByCtfe != OwnedBy.ctfe)
            {
                eSink.error(e.loc, "cannot modify read-only constant `%s`", existingAE.toErrMsg());
                return CTFEExp.cantexp;
            }

            if (newval.op == EXP.slice && !isBlockAssignment)
            {
                auto se = newval.isSliceExp();
                auto ale2 = se.e1.isArrayLiteralExp();
                const srclower = se.lwr.toInteger();
                const srcupper = se.upr.toInteger();
                const wantCopy = (newval.type.toBasetype().nextOf().baseElemOf().ty == Tstruct);

                //printf("oldval = %p %s[%d..%u]\nnewval = %p %s[%llu..%llu] wantCopy = %d\n",
                //    aggregate, aggregate.toChars(), lowerbound, upperbound,
                //    ale2, ale2.toChars(), srclower, srcupper, wantCopy);
                if (wantCopy)
                {
                    // Currently overlapping for struct array is allowed.
                    // The order of elements processing depends on the overlapping.
                    // https://issues.dlang.org/show_bug.cgi?id=14024

                    Type elemtype = aggregate.type.nextOf();
                    bool needsPostblit = e.e2.isLvalue();

                    if (aggregate == ale2 && srclower < lowerbound && lowerbound < srcupper)
                    {
                        // reverse order
                        for (auto i = upperbound - lowerbound; 0 < i--;)
                        {
                            Expression oldelem = existingAE[cast(size_t)(i + firstIndex)];
                            Expression newelem = ale2[cast(size_t)(i + srclower)];
                            newelem = copyLiteral(newelem).copy();
                            newelem.type = elemtype;
                            if (needsPostblit)
                            {
                                if (Expression x = evaluatePostblit(istate, newelem))
                                    return x;
                            }
                            if (Expression x = evaluateDtor(istate, oldelem))
                                return x;
                            existingAE[cast(size_t)(lowerbound + i)] = newelem;
                        }
                    }
                    else
                    {
                        // normal order
                        for (auto i = 0; i < upperbound - lowerbound; i++)
                        {
                            Expression oldelem = existingAE[cast(size_t)(i + firstIndex)];
                            Expression newelem = ale2[cast(size_t)(i + srclower)];
                            newelem = copyLiteral(newelem).copy();
                            newelem.type = elemtype;
                            if (needsPostblit)
                            {
                                if (Expression x = evaluatePostblit(istate, newelem))
                                    return x;
                            }
                            if (Expression x = evaluateDtor(istate, oldelem))
                                return x;
                            existingAE[cast(size_t)(lowerbound + i)] = newelem;
                        }
                    }

                    //assert(0);
                    return newval; // oldval?
                }
                if (aggregate == ale2 &&
                    lowerbound < srcupper && srclower < upperbound)
                {
                    eSink.error(e.loc, "overlapping slice assignment `[%llu..%llu] = [%llu..%llu]`",
                        ulong(lowerbound), ulong(upperbound), ulong(srclower), ulong(srcupper));
                    return CTFEExp.cantexp;
                }
                version (all) // todo: instead we can directly access to each elements of the slice
                {
                    Expression orignewval = newval;
                    newval = resolveSlice(newval);
                    if (CTFEExp.isCantExp(newval))
                    {
                        eSink.error(e.loc, "CTFE internal error: slice `%s`", orignewval.toErrMsg());
                        return CTFEExp.cantexp;
                    }
                }
                // no overlapping
                //length?
                assert(newval.op != EXP.slice);
            }
            if (newval.op == EXP.string_ && !isBlockAssignment)
            {
                /* Mixed slice: it was initialized as an array literal of chars/integers.
                 * Now a slice of it is being set with a string.
                 */
                sliceAssignArrayLiteralFromString(existingAE, newval.isStringExp(), cast(size_t)firstIndex);
                return newval;
            }
            if (newval.op == EXP.arrayLiteral && !isBlockAssignment)
            {
                Expressions* oldelems = existingAE.elements;
                Expressions* newelems = newval.isArrayLiteralExp().elements;
                Type elemtype = existingAE.type.nextOf();
                bool needsPostblit = e.op != EXP.blit && e.e2.isLvalue();
                foreach (j, newelem; *newelems)
                {
                    newelem = paintTypeOntoLiteral(elemtype, newelem);
                    if (needsPostblit)
                    {
                        Expression x = evaluatePostblit(istate, newelem);
                        if (exceptionOrCantInterpret(x))
                            return x;
                    }
                    (*oldelems)[cast(size_t)(j + firstIndex)] = newelem;
                }
                return newval;
            }

            /* Block assignment, initialization of static arrays
             *   x[] = newval
             *  x may be a multidimensional static array. (Note that this
             *  only happens with array literals, never with strings).
             */
            struct RecursiveBlock
            {
                InterState* istate;
                Expression newval;
                bool refCopy;
                bool needsPostblit;
                bool needsDtor;

                Expression assignTo(ArrayLiteralExp ale)
                {
                    return assignTo(ale, 0, ale.length);
                }

                Expression assignTo(ArrayLiteralExp ae, size_t lwr, size_t upr)
                {
                    Expressions* w = ae.elements;
                    assert(ae.type.isStaticOrDynamicArray() || ae.type.ty == Tpointer);
                    bool directblk = (cast(TypeNext)ae.type).next.equivalent(newval.type);
                    for (size_t k = lwr; k < upr; k++)
                    {
                        if (!directblk && (*w)[k].op == EXP.arrayLiteral)
                        {
                            // Multidimensional array block assign
                            if (Expression ex = assignTo((*w)[k].isArrayLiteralExp()))
                                return ex;
                        }
                        else if (refCopy)
                        {
                            (*w)[k] = newval;
                        }
                        else if (!needsPostblit && !needsDtor)
                        {
                            assignInPlace((*w)[k], newval);
                        }
                        else
                        {
                            Expression oldelem = (*w)[k];
                            Expression tmpelem = needsDtor ? copyLiteral(oldelem).copy() : null;
                            assignInPlace(oldelem, newval);
                            if (needsPostblit)
                            {
                                if (Expression ex = evaluatePostblit(istate, oldelem))
                                    return ex;
                            }
                            if (needsDtor)
                            {
                                // https://issues.dlang.org/show_bug.cgi?id=14860
                                if (Expression ex = evaluateDtor(istate, tmpelem))
                                    return ex;
                            }
                        }
                    }
                    return null;
                }
            }

            Type tn = newval.type.toBasetype();
            bool wantRef = (tn.ty == Tarray || isAssocArray(tn) || tn.ty == Tclass);
            bool cow = newval.op != EXP.structLiteral && newval.op != EXP.arrayLiteral && newval.op != EXP.string_;
            Type tb = tn.baseElemOf();
            StructDeclaration sd = (tb.ty == Tstruct ? (cast(TypeStruct)tb).sym : null);

            RecursiveBlock rb;
            rb.istate = istate;
            rb.newval = newval;
            rb.refCopy = wantRef || cow;
            rb.needsPostblit = sd && sd.postblit && e.op != EXP.blit && e.e2.isLvalue();
            rb.needsDtor = sd && sd.dtor && (e.op == EXP.assign || e.op == EXP.loweredAssignExp);
            if (Expression ex = rb.assignTo(existingAE, cast(size_t)lowerbound, cast(size_t)upperbound))
                return ex;

            if (goal == CTFEGoal.Nothing)
                return null; // avoid creating an unused literal
            auto retslice = ctfeEmplaceExp!SliceExp(e.loc, existingAE,
                ctfeEmplaceExp!IntegerExp(e.loc, firstIndex, Type.tsize_t),
                ctfeEmplaceExp!IntegerExp(e.loc, firstIndex + upperbound - lowerbound, Type.tsize_t));
            retslice.type = e.type;
            return interpret(pue, retslice, istate);
        }

        eSink.error(e.loc, "slice operation `%s = %s` cannot be evaluated at compile time", e1.toErrMsg(), newval.toErrMsg());
        return CTFEExp.cantexp;
    }

    override void visit(AssignExp e)
    {
        interpretAssignCommon(e, null);
    }

    override void visit(BinAssignExp e)
    {
        switch (e.op)
        {
        case EXP.addAssign:
            interpretAssignCommon(e, &Add);
            return;

        case EXP.minAssign:
            interpretAssignCommon(e, &Min);
            return;

        case EXP.concatenateAssign:
        case EXP.concatenateElemAssign:
        case EXP.concatenateDcharAssign:
            interpretAssignCommon(e, &ctfeCat);
            return;

        case EXP.mulAssign:
            interpretAssignCommon(e, &Mul);
            return;

        case EXP.divAssign:
            interpretAssignCommon(e, &Div);
            return;

        case EXP.modAssign:
            interpretAssignCommon(e, &Mod);
            return;

        case EXP.leftShiftAssign:
            interpretAssignCommon(e, &Shl);
            return;

        case EXP.rightShiftAssign:
            interpretAssignCommon(e, &Shr);
            return;

        case EXP.unsignedRightShiftAssign:
            interpretAssignCommon(e, &Ushr);
            return;

        case EXP.andAssign:
            interpretAssignCommon(e, &And);
            return;

        case EXP.orAssign:
            interpretAssignCommon(e, &Or);
            return;

        case EXP.xorAssign:
            interpretAssignCommon(e, &Xor);
            return;

        case EXP.powAssign:
            interpretAssignCommon(e, &Pow);
            return;

        default:
            assert(0);
        }
    }

    override void visit(PostExp e)
    {
        debug (LOG)
        {
            printf("%s PostExp::interpret() %s\n", e.loc.toChars(), e.toChars());
        }
        if (e.op == EXP.plusPlus)
            interpretAssignCommon(e, &Add, 1);
        else
            interpretAssignCommon(e, &Min, 1);
        debug (LOG)
        {
            if (CTFEExp.isCantExp(result))
                printf("PostExp::interpret() CANT\n");
        }
    }

    /* Return 1 if e is a p1 > p2 or p1 >= p2 pointer comparison;
     *       -1 if e is a p1 < p2 or p1 <= p2 pointer comparison;
     *        0 otherwise
     */
    static int isPointerCmpExp(Expression e, Expression* p1, Expression* p2)
    {
        int ret = 1;
        while (e.op == EXP.not)
        {
            ret *= -1;
            e = e.isNotExp().e1;
        }
        switch (e.op)
        {
        case EXP.lessThan:
        case EXP.lessOrEqual:
            ret *= -1;
            goto case; /+ fall through +/
        case EXP.greaterThan:
        case EXP.greaterOrEqual:
            *p1 = e.isBinExp().e1;
            *p2 = e.isBinExp().e2;
            if (!(isPointer((*p1).type) && isPointer((*p2).type)))
                ret = 0;
            break;

        default:
            ret = 0;
            break;
        }
        return ret;
    }

    /** If this is a four pointer relation, evaluate it, else return NULL.
     *
     *  This is an expression of the form (p1 > q1 && p2 < q2) or (p1 < q1 || p2 > q2)
     *  where p1, p2 are expressions yielding pointers to memory block p,
     *  and q1, q2 are expressions yielding pointers to memory block q.
     *  This expression is valid even if p and q are independent memory
     *  blocks and are therefore not normally comparable; the && form returns true
     *  if [p1..p2] lies inside [q1..q2], and false otherwise; the || form returns
     *  true if [p1..p2] lies outside [q1..q2], and false otherwise.
     *
     *  Within the expression, any ordering of p1, p2, q1, q2 is permissible;
     *  the comparison operators can be any of >, <, <=, >=, provided that
     *  both directions (p > q and p < q) are checked. Additionally the
     *  relational sub-expressions can be negated, eg
     *  (!(q1 < p1) && p2 <= q2) is valid.
     */
    private void interpretFourPointerRelation(UnionExp* pue, BinExp e)
    {
        assert(e.op == EXP.andAnd || e.op == EXP.orOr);

        /*  It can only be an isInside expression, if both e1 and e2 are
         *  directional pointer comparisons.
         *  Note that this check can be made statically; it does not depends on
         *  any runtime values. This allows a JIT implementation to compile a
         *  special AndAndPossiblyInside, keeping the normal AndAnd case efficient.
         */

        // Save the pointer expressions and the comparison directions,
        // so we can use them later.
        Expression p1 = null;
        Expression p2 = null;
        Expression p3 = null;
        Expression p4 = null;
        int dir1 = isPointerCmpExp(e.e1, &p1, &p2);
        int dir2 = isPointerCmpExp(e.e2, &p3, &p4);
        if (dir1 == 0 || dir2 == 0)
        {
            result = null;
            return;
        }

        //printf("FourPointerRelation %s\n", toChars());

        UnionExp ue1 = void;
        UnionExp ue2 = void;
        UnionExp ue3 = void;
        UnionExp ue4 = void;

        // Evaluate the first two pointers
        p1 = interpret(&ue1, p1, istate);
        if (exceptionOrCant(p1))
            return;
        p2 = interpret(&ue2, p2, istate);
        if (exceptionOrCant(p2))
            return;
        dinteger_t ofs1, ofs2;
        Expression agg1 = getAggregateFromPointer(p1, &ofs1);
        Expression agg2 = getAggregateFromPointer(p2, &ofs2);

        if (!pointToSameMemoryBlock(agg1, agg2) && agg1.op != EXP.null_ && agg2.op != EXP.null_)
        {
            // Here it is either CANT_INTERPRET,
            // or an IsInside comparison returning false.
            p3 = interpret(&ue3, p3, istate);
            if (CTFEExp.isCantExp(p3))
                return;
            // Note that it is NOT legal for it to throw an exception!
            Expression except = null;
            if (exceptionOrCantInterpret(p3))
                except = p3;
            else
            {
                p4 = interpret(&ue4, p4, istate);
                if (CTFEExp.isCantExp(p4))
                {
                    result = p4;
                    return;
                }
                if (exceptionOrCantInterpret(p4))
                    except = p4;
            }
            if (except)
            {
                eSink.error(e.loc, "comparison `%s` of pointers to unrelated memory blocks remains indeterminate at compile time because exception `%s` was thrown while evaluating `%s`", e.e1.toErrMsg(), except.toErrMsg(), e.e2.toErrMsg());
                result = CTFEExp.cantexp;
                return;
            }
            dinteger_t ofs3, ofs4;
            Expression agg3 = getAggregateFromPointer(p3, &ofs3);
            Expression agg4 = getAggregateFromPointer(p4, &ofs4);
            // The valid cases are:
            // p1 > p2 && p3 > p4  (same direction, also for < && <)
            // p1 > p2 && p3 < p4  (different direction, also < && >)
            // Changing any > into >= doesn't affect the result
            if ((dir1 == dir2 && pointToSameMemoryBlock(agg1, agg4) && pointToSameMemoryBlock(agg2, agg3)) ||
                (dir1 != dir2 && pointToSameMemoryBlock(agg1, agg3) && pointToSameMemoryBlock(agg2, agg4)))
            {
                // it's a legal two-sided comparison
                emplaceExp!(IntegerExp)(pue, e.loc, (e.op == EXP.andAnd) ? 0 : 1, e.type);
                result = pue.exp();
                return;
            }
            // It's an invalid four-pointer comparison. Either the second
            // comparison is in the same direction as the first, or else
            // more than two memory blocks are involved (either two independent
            // invalid comparisons are present, or else agg3 == agg4).
            eSink.error(e.loc, "comparison `%s` of pointers to unrelated memory blocks is indeterminate at compile time, even when combined with `%s`.", e.e1.toErrMsg(), e.e2.toErrMsg());
            result = CTFEExp.cantexp;
            return;
        }
        // The first pointer expression didn't need special treatment, so we
        // we need to interpret the entire expression exactly as a normal && or ||.
        // This is easy because we haven't evaluated e2 at all yet, and we already
        // know it will return a bool.
        // But we mustn't evaluate the pointer expressions in e1 again, in case
        // they have side-effects.
        bool nott = false;
        Expression ex = e.e1;
        while (1)
        {
            if (auto ne = ex.isNotExp())
            {
                nott = !nott;
                ex = ne.e1;
            }
            else
                break;
        }

        /** Negate relational operator, eg >= becomes <
         * Params:
         *      op = comparison operator to negate
         * Returns:
         *      negate operator
         */
        static EXP negateRelation(EXP op) pure
        {
            switch (op)
            {
                case EXP.greaterOrEqual:  op = EXP.lessThan;       break;
                case EXP.greaterThan:     op = EXP.lessOrEqual;    break;
                case EXP.lessOrEqual:     op = EXP.greaterThan;    break;
                case EXP.lessThan:        op = EXP.greaterOrEqual; break;
                default:                  assert(0);
            }
            return op;
        }

        const EXP cmpop = nott ? negateRelation(ex.op) : ex.op;
        const cmp = comparePointers(cmpop, agg1, ofs1, agg2, ofs2);
        // We already know this is a valid comparison.
        assert(cmp >= 0);
        if (e.op == EXP.andAnd && cmp == 1 || e.op == EXP.orOr && cmp == 0)
        {
            result = interpret(pue, e.e2, istate);
            return;
        }
        emplaceExp!(IntegerExp)(pue, e.loc, (e.op == EXP.andAnd) ? 0 : 1, e.type);
        result = pue.exp();
    }

    override void visit(LogicalExp e)
    {
        debug (LOG)
        {
            printf("%s LogicalExp::interpret() %s\n", e.loc.toChars(), e.toChars());
        }
        // Check for an insidePointer expression, evaluate it if so
        interpretFourPointerRelation(pue, e);
        if (result)
            return;

        UnionExp ue1 = void;
        result = interpret(&ue1, e.e1, istate);
        if (exceptionOrCant(result))
            return;

        bool res;
        const andand = e.op == EXP.andAnd;
        if (andand ? result.toBool().hasValue(false) : isTrueBool(result))
            res = !andand;
        else if (andand ? isTrueBool(result) : result.toBool().hasValue(false))
        {
            UnionExp ue2 = void;
            result = interpret(&ue2, e.e2, istate);
            if (exceptionOrCant(result))
                return;
            if (result.op == EXP.voidExpression)
            {
                assert(e.type.ty == Tvoid);
                result = null;
                return;
            }
            if (result.toBool().hasValue(false))
                res = false;
            else if (isTrueBool(result))
                res = true;
            else
            {
                eSink.error(e.loc, "`%s` does not evaluate to a `bool`", result.toErrMsg());
                result = CTFEExp.cantexp;
                return;
            }
        }
        else
        {
            eSink.error(e.loc, "`%s` cannot be interpreted as a `bool`", result.toErrMsg());
            result = CTFEExp.cantexp;
            return;
        }
        incUsageCtfe(istate, e.e2.loc);

        if (goal != CTFEGoal.Nothing)
        {
            if (e.type.equals(Type.tbool))
                result = IntegerExp.createBool(res);
            else
            {
                emplaceExp!(IntegerExp)(pue, e.loc, res, e.type);
                result = pue.exp();
            }
        }
    }


    // Print a stack trace, starting from callingExp which called fd.
    // To shorten the stack trace, try to detect recursion.
    private void showCtfeBackTrace(CallExp callingExp, FuncDeclaration fd)
    {
        if (ctfeGlobals.stackTraceCallsToSuppress > 0)
        {
            --ctfeGlobals.stackTraceCallsToSuppress;
            return;
        }
        eSink.errorSupplemental(callingExp.loc, "called from here: `%s`", callingExp.toChars());
        // Quit if it's not worth trying to compress the stack trace
        if (ctfeGlobals.callDepth < 6 || global.params.v.verbose)
            return;
        // Recursion happens if the current function already exists in the call stack.
        int numToSuppress = 0;
        int recurseCount = 0;
        int depthSoFar = 0;
        InterState* lastRecurse = istate;
        for (InterState* cur = istate; cur; cur = cur.caller)
        {
            if (cur.fd == fd)
            {
                ++recurseCount;
                numToSuppress = depthSoFar;
                lastRecurse = cur;
            }
            ++depthSoFar;
        }
        // We need at least three calls to the same function, to make compression worthwhile
        if (recurseCount < 2)
            return;
        // We found a useful recursion.  Print all the calls involved in the recursion
        eSink.errorSupplemental(fd.loc, "%d recursive calls to function `%s`", recurseCount, fd.toChars());
        for (InterState* cur = istate; cur.fd != fd; cur = cur.caller)
        {
            eSink.errorSupplemental(cur.fd.loc, "recursively called from function `%s`", cur.fd.toChars());
        }
        // We probably didn't enter the recursion in this function.
        // Go deeper to find the real beginning.
        InterState* cur = istate;
        while (lastRecurse.caller && cur.fd == lastRecurse.caller.fd)
        {
            cur = cur.caller;
            lastRecurse = lastRecurse.caller;
            ++numToSuppress;
        }
        ctfeGlobals.stackTraceCallsToSuppress = numToSuppress;
    }

    override void visit(CallExp e)
    {
        debug (LOG)
        {
            printf("%s CallExp::interpret() %s\n", e.loc.toChars(), e.toChars());
        }
        // Take the linear-return destination before anything else is
        // interpreted, so nested calls (in e1 or the arguments) cannot
        // consume it; it applies to this call only.
        CtfeLinearReturn* linearRet = ctfeGlobals.linearReturnDest;
        ctfeGlobals.linearReturnDest = null;

        Expression pthis = null;
        FuncDeclaration fd = null;

        Expression ecall = interpretRegion(e.e1, istate);
        if (exceptionOrCant(ecall))
            return;

        if (auto dve = ecall.isDotVarExp())
        {
            // Calling a member function
            pthis = dve.e1;
            fd = dve.var.isFuncDeclaration();
            assert(fd);

            if (auto dte = pthis.isDotTypeExp())
                pthis = dte.e1;
        }
        else if (auto ve = ecall.isVarExp())
        {
            fd = ve.var.isFuncDeclaration();
            assert(fd);

            // If `_d_HookTraceImpl` is found, resolve the underlying hook and replace `e` and `fd` with it.
            removeHookTraceImpl(e, fd);

            if (fd.ident == Id.__ArrayPostblit || fd.ident == Id.__ArrayDtor)
            {
                assert(e.arguments.length == 1);
                Expression ea = (*e.arguments)[0];
                // printf("1 ea = %s %s\n", ea.type.toChars(), ea.toChars());
                if (auto se = ea.isSliceExp())
                    ea = se.e1;
                if (auto ce = ea.isCastExp())
                    ea = ce.e1;

                // printf("2 ea = %s, %s %s\n", ea.type.toChars(), EXPtoString(ea.op).ptr, ea.toChars());
                if (ea.op == EXP.variable || ea.op == EXP.symbolOffset)
                    result = getVarExp(e.loc, istate, (cast(SymbolExp)ea).var, CTFEGoal.RValue);
                else if (auto ae = ea.isAddrExp())
                    result = interpretRegion(ae.e1, istate);

                // https://issues.dlang.org/show_bug.cgi?id=18871
                // https://issues.dlang.org/show_bug.cgi?id=18819
                else if (auto ale = ea.isArrayLiteralExp())
                    result = interpretRegion(ale, istate);

                else
                    assert(0);
                if (CTFEExp.isCantExp(result))
                    return;

                if (fd.ident == Id.__ArrayPostblit)
                    result = evaluatePostblit(istate, result);
                else
                    result = evaluateDtor(istate, result);
                if (!result)
                    result = CTFEExp.voidexp;
                return;
            }
        }
        else if (auto soe = ecall.isSymOffExp())
        {
            fd = soe.var.isFuncDeclaration();
            assert(fd && soe.offset == 0);
        }
        else if (auto de = ecall.isDelegateExp())
        {
            // Calling a delegate
            fd = de.func;
            pthis = de.e1;

            // Special handling for: &nestedfunc --> DelegateExp(VarExp(nestedfunc), nestedfunc)
            if (auto ve = pthis.isVarExp())
                if (ve.var == fd)
                    pthis = null; // context is not necessary for CTFE
        }
        else if (auto fe = ecall.isFuncExp())
        {
            // Calling a delegate literal
            fd = fe.fd;
        }
        else
        {
            // delegate.funcptr()
            // others
            eSink.error(e.loc, "cannot call `%s` at compile time", e.toErrMsg());
            result = CTFEExp.cantexp;
            return;
        }
        if (!fd)
        {
            eSink.error(e.loc, "CTFE internal error: cannot evaluate `%s` at compile time", e.toErrMsg());
            result = CTFEExp.cantexp;
            return;
        }
        if (pthis)
        {
            // Member function call

            // Currently this is satisfied because closure is not yet supported.
            assert(!fd.isNested() || fd.needThis());

            if (pthis.op == EXP.typeid_)
            {
                eSink.error(pthis.loc, "static variable `%s` cannot be read at compile time", pthis.toErrMsg());
                result = CTFEExp.cantexp;
                return;
            }
            assert(pthis);

            if (pthis.op == EXP.null_)
            {
                assert(pthis.type.toBasetype().ty == Tclass);
                eSink.error(e.loc, "function call through null class reference `%s`", pthis.toErrMsg());
                result = CTFEExp.cantexp;
                return;
            }

            assert(pthis.op == EXP.structLiteral || pthis.op == EXP.classReference || pthis.op == EXP.type);

            if (fd.isVirtual() && !e.directcall)
            {
                // Make a virtual function call.
                // Get the function from the vtable of the original class
                ClassDeclaration cd = pthis.isClassReferenceExp().originalClass();

                // We can't just use the vtable index to look it up, because
                // vtables for interfaces don't get populated until the glue layer.
                fd = cd.findFunc(fd.ident, fd.type.isTypeFunction());
                assert(fd);
            }
        }

        if (fd && fd.semanticRun >= PASS.semantic3done && fd.hasSemantic3Errors)
        {
            eSink.error(e.loc, "CTFE failed because of previous errors in `%s`", fd.toErrMsg());
            result = CTFEExp.cantexp;
            return;
        }

        // Check for built-in functions
        result = evaluateIfBuiltin(pue, istate, e.loc, fd, e.arguments, pthis);
        if (result)
            return;

        if (!fd.fbody)
        {
            eSink.error(e.loc, "`%s` cannot be interpreted at compile time, because it has no available source code", fd.toErrMsg());
            result = CTFEExp.showcontext;
            return;
        }

        result = interpretFunction(pue, fd, istate, e.arguments, pthis, linearRet);
        if (result.op == EXP.voidExpression)
            return;
        if (!exceptionOrCantInterpret(result))
        {
            if (goal != CTFEGoal.LValue) // Peel off CTFE reference if it's unnecessary
            {
                if (result == pue.exp())
                    result = pue.copy();
                result = interpret(pue, result, istate);
            }
        }
        if (!exceptionOrCantInterpret(result))
        {
            result = paintTypeOntoLiteral(pue, e.type, result);
            result.loc = e.loc;
        }
        else if (CTFEExp.isCantExp(result) && !global.gag)
            showCtfeBackTrace(e, fd); // Print a stack trace.
    }

    override void visit(CommaExp e)
    {
        /****************************************
         * Find the first non-comma expression.
         * Params:
         *      e = Expressions connected by commas
         * Returns:
         *      left-most non-comma expression
         */
        static inout(Expression) firstComma(inout Expression e)
        {
            Expression ex = cast()e;
            while (ex.op == EXP.comma)
                ex = (cast(CommaExp)ex).e1;
            return cast(inout)ex;

        }

        debug (LOG)
        {
            printf("%s CommaExp::interpret() %s\n", e.loc.toChars(), e.toChars());
        }

        // If it creates a variable, and there's no context for
        // the variable to be created in, we need to create one now.
        InterState istateComma;
        if (!istate && firstComma(e.e1).op == EXP.declaration)
        {
            ctfeGlobals.stack.startFrame(null);
            istate = &istateComma;
        }

        void endTempStackFrame()
        {
            // If we created a temporary stack frame, end it now.
            if (istate == &istateComma)
                ctfeGlobals.stack.endFrame();
        }

        result = CTFEExp.cantexp;

        // If the comma returns a temporary variable, it needs to be an lvalue
        // (this is particularly important for struct constructors)
        if (e.e1.op == EXP.declaration &&
            e.e2.op == EXP.variable &&
            e.e1.isDeclarationExp().declaration == e.e2.isVarExp().var &&
            e.e2.isVarExp().var.storage_class & STC.ctfe)
        {
            VarExp ve = e.e2.isVarExp();
            VarDeclaration v = ve.var.isVarDeclaration();
            ctfeGlobals.stack.push(v);
            if (!v._init && !getValue(v))
            {
                setValue(v, copyLiteral(v.type.defaultInitLiteral(e.loc)).copy());
            }
            if (!getValue(v))
            {
                Expression newval = v._init.initializerToExpression();
                // Bug 4027. Copy constructors are a weird case where the
                // initializer is a void function (the variable is modified
                // through a reference parameter instead).
                newval = interpretRegion(newval, istate);
                if (exceptionOrCant(newval))
                    return endTempStackFrame();
                if (newval.op != EXP.voidExpression)
                {
                    // v isn't necessarily null.
                    setValueWithoutChecking(v, copyLiteral(newval).copy());
                }
            }
        }
        else
        {
            UnionExp ue = void;
            auto e1 = interpret(&ue, e.e1, istate, CTFEGoal.Nothing);
            if (exceptionOrCant(e1))
                return endTempStackFrame();
        }
        result = interpret(pue, e.e2, istate, goal);
        return endTempStackFrame();
    }

    override void visit(CondExp e)
    {
        debug (LOG)
        {
            printf("%s CondExp::interpret() %s\n", e.loc.toChars(), e.toChars());
        }
        UnionExp uecond = void;
        Expression econd;
        econd = interpret(&uecond, e.econd, istate);
        if (exceptionOrCant(econd))
            return;

        if (isPointer(e.econd.type))
        {
            if (econd.op != EXP.null_)
            {
                econd = IntegerExp.createBool(true);
            }
        }

        if (isTrueBool(econd))
        {
            result = interpret(pue, e.e1, istate, goal);
            incUsageCtfe(istate, e.e1.loc);
        }
        else if (econd.toBool().hasValue(false))
        {
            result = interpret(pue, e.e2, istate, goal);
            incUsageCtfe(istate, e.e2.loc);
        }
        else
        {
            eSink.error(e.loc, "`%s` does not evaluate to boolean result at compile time", e.econd.toErrMsg());
            result = CTFEExp.cantexp;
        }
    }

    override void visit(ArrayLengthExp e)
    {
        debug (LOG)
        {
            printf("%s ArrayLengthExp::interpret() %s\n", e.loc.toChars(), e.toChars());
        }
        // Linear-memory fast path: read the length from the slice handle
        // without materializing the array
        if (global.params.ctfeLinearMemory)
        {
            if (auto ve = e.e1.isVarExp())
                if (auto v = ve.var.isVarDeclaration())
                {
                    const slot = ctfeGlobals.stack.sliceSlot(v);
                    LinearSlice s;
                    if (!slot.isNull && readSlice(ctfeGlobals.linearMem, slot, s))
                    {
                        emplaceExp!(IntegerExp)(pue, e.loc, s.length, e.type);
                        result = pue.exp();
                        return;
                    }
                }
        }
        UnionExp ue1;
        Expression e1 = interpret(&ue1, e.e1, istate);
        assert(e1);
        if (exceptionOrCant(e1))
            return;
        if (e1.op != EXP.string_ && e1.op != EXP.arrayLiteral && e1.op != EXP.slice && e1.op != EXP.null_)
        {
            eSink.error(e.loc, "`%s` cannot be evaluated at compile time", e.toErrMsg());
            result = CTFEExp.cantexp;
            return;
        }
        emplaceExp!(IntegerExp)(pue, e.loc, resolveArrayLength(e1), e.type);
        result = pue.exp();
    }

    /**
     * Interpret the vector expression as an array literal.
     * Params:
     *    pue = non-null pointer to temporary storage that can be used to store the return value
     *    e = Expression to interpret
     * Returns:
     *    resulting array literal or 'e' if unable to interpret
     */
    static Expression interpretVectorToArray(UnionExp* pue, VectorExp e)
    {
        if (auto ale = e.e1.isArrayLiteralExp())
            return ale;         // it's already an array literal
        if (e.e1.op == EXP.int64 || e.e1.op == EXP.float64)
        {
            // Convert literal __vector(int) -> __vector([array])
            auto elements = new Expressions(e.dim);
            foreach (ref element; *elements)
                element = copyLiteral(e.e1).copy();
            auto type = (e.type.ty == Tvector) ? e.type.isTypeVector().basetype : e.type.isTypeSArray();
            assert(type);
            emplaceExp!(ArrayLiteralExp)(pue, e.loc, type, elements);
            auto ale = pue.exp().isArrayLiteralExp();
            ale.ownedByCtfe = OwnedBy.ctfe;
            return ale;
        }
        return e;
    }

    override void visit(VectorExp e)
    {
        debug (LOG)
        {
            printf("%s VectorExp::interpret() %s\n", e.loc.toChars(), e.toChars());
        }
        if (e.ownedByCtfe >= OwnedBy.ctfe) // We've already interpreted all the elements
        {
            result = e;
            return;
        }
        Expression e1 = interpret(pue, e.e1, istate);
        assert(e1);
        if (exceptionOrCant(e1))
            return;
        if (e1.op != EXP.arrayLiteral && e1.op != EXP.int64 && e1.op != EXP.float64)
        {
            eSink.error(e.loc, "`%s` cannot be evaluated at compile time", e.toErrMsg());
            result = CTFEExp.cantexp;
            return;
        }
        if (e1 == pue.exp())
            e1 = pue.copy();
        emplaceExp!(VectorExp)(pue, e.loc, e1, e.to);
        auto ve = pue.exp().isVectorExp();
        ve.type = e.type;
        ve.dim = e.dim;
        ve.ownedByCtfe = OwnedBy.ctfe;
        result = ve;
    }

    override void visit(VectorArrayExp e)
    {
        debug (LOG)
        {
            printf("%s VectorArrayExp::interpret() %s\n", e.loc.toChars(), e.toChars());
        }
        Expression e1 = interpret(pue, e.e1, istate);
        assert(e1);
        if (exceptionOrCant(e1))
            return;
        if (auto ve = e1.isVectorExp())
        {
            result = interpretVectorToArray(pue, ve);
            if (result.op != EXP.vector)
                return;
        }
        eSink.error(e.loc, "`%s` cannot be evaluated at compile time", e.toErrMsg());
        result = CTFEExp.cantexp;
    }

    override void visit(DelegatePtrExp e)
    {
        debug (LOG)
        {
            printf("%s DelegatePtrExp::interpret() %s\n", e.loc.toChars(), e.toChars());
        }
        Expression e1 = interpret(pue, e.e1, istate);
        assert(e1);
        if (exceptionOrCant(e1))
            return;
        eSink.error(e.loc, "`%s` cannot be evaluated at compile time", e.toErrMsg());
        result = CTFEExp.cantexp;
    }

    override void visit(DelegateFuncptrExp e)
    {
        debug (LOG)
        {
            printf("%s DelegateFuncptrExp::interpret() %s\n", e.loc.toChars(), e.toChars());
        }
        Expression e1 = interpret(pue, e.e1, istate);
        assert(e1);
        if (exceptionOrCant(e1))
            return;
        eSink.error(e.loc, "`%s` cannot be evaluated at compile time", e.toErrMsg());
        result = CTFEExp.cantexp;
    }

    static bool resolveIndexing(IndexExp e, InterState* istate, Expression* pagg, uinteger_t* pidx, bool modify)
    {
	auto eSink = global.errorSink;
        assert(e.e1.type.toBasetype().ty != Taarray);

        if (e.e1.type.toBasetype().ty == Tpointer)
        {
            // Indexing a pointer. Note that there is no $ in this case.
            Expression e1 = interpretRegion(e.e1, istate);
            if (exceptionOrCantInterpret(e1))
                return false;

            // the index doesn't escape this function, no need to persist it
            UnionExp ue2 = void;
            Expression e2 = interpret(&ue2, e.e2, istate);
            if (exceptionOrCantInterpret(e2))
                return false;
            sinteger_t indx = e2.toInteger();

            dinteger_t ofs;
            Expression agg = getAggregateFromPointer(e1, &ofs);

            // Pointer to a non-array variable
            if (agg.op == EXP.symbolOffset)
            {
                eSink.error(e.loc, "mutable variable `%s` cannot be %s at compile time, even through a pointer", cast(char*)(modify ? "modified" : "read"), agg.isSymOffExp().var.toErrMsg());
                return false;
            }

            if (agg.op == EXP.arrayLiteral || agg.op == EXP.string_)
            {
                dinteger_t len = resolveArrayLength(agg);
                if (ofs + indx >= len)
                {
                    eSink.error(e.loc, "pointer index `[%lld]` exceeds allocated memory block `[0..%lld]`", ofs + indx, len);
                    return false;
                }
            }
            else
            {
                // agg is the value accessed, it is not dereferenced again, so offset 0 is always ok
                if (ofs + indx != 0)
                {
                    if (agg.op == EXP.null_)
                        eSink.error(e.loc, "cannot index through null pointer `%s`", e.e1.toErrMsg());
                    else if (agg.op == EXP.int64)
                        eSink.error(e.loc, "cannot index through invalid pointer `%s` of value `%s`", e.e1.toErrMsg(), e1.toErrMsg());
                    else
                        eSink.error(e.loc, "pointer index `[%lld]` lies outside memory block `[0..1]`", ofs + indx);
                    return false;
                }
            }
            *pagg = agg;
            *pidx = ofs + indx;
            return true;
        }

        Expression e1 = interpretRegion(e.e1, istate);
        if (exceptionOrCantInterpret(e1))
            return false;
        if (e1.op == EXP.null_)
        {
            eSink.error(e.loc, "cannot index null array `%s`", e.e1.toErrMsg());
            return false;
        }
        if (auto ve = e1.isVectorExp())
        {
            UnionExp ue = void;
            e1 = interpretVectorToArray(&ue, ve);
            e1 = (e1 == ue.exp()) ? ue.copy() : e1;
        }

        // Set the $ variable, and find the array literal to modify
        dinteger_t len;
        if (e1.op == EXP.variable && e1.type.toBasetype().ty == Tsarray)
            len = e1.type.toBasetype().isTypeSArray().dim.toInteger();
        else
        {
            if (e1.op != EXP.arrayLiteral && e1.op != EXP.string_ && e1.op != EXP.slice && e1.op != EXP.vector)
            {
                eSink.error(e.loc, "cannot determine length of `%s` at compile time", e.e1.toErrMsg());
                return false;
            }
            len = resolveArrayLength(e1);
        }

        if (e.lengthVar)
        {
            Expression dollarExp = ctfeEmplaceExp!IntegerExp(e.loc, len, Type.tsize_t);
            ctfeGlobals.stack.push(e.lengthVar);
            setValue(e.lengthVar, dollarExp);
        }
        // the index doesn't escape this function, no need to persist it
        UnionExp ue2 = void;
        Expression e2 = interpret(&ue2, e.e2, istate);
        if (e.lengthVar)
            ctfeGlobals.stack.pop(e.lengthVar); // $ is defined only inside []
        if (exceptionOrCantInterpret(e2))
            return false;
        if (e2.op != EXP.int64)
        {
            eSink.error(e.loc, "CTFE internal error: non-integral index `[%s]`", e.e2.toErrMsg());
            return false;
        }

        if (auto se = e1.isSliceExp())
        {
            // Simplify index of slice: agg[lwr..upr][indx] --> agg[indx']
            uinteger_t index = e2.toInteger();
            uinteger_t ilwr = se.lwr.toInteger();
            uinteger_t iupr = se.upr.toInteger();

            if (index > iupr - ilwr)
            {
                eSink.error(e.loc, "index %llu exceeds array length %llu", index, iupr - ilwr);
                return false;
            }
            *pagg = e1.isSliceExp().e1;
            *pidx = index + ilwr;
        }
        else
        {
            *pagg = e1;
            *pidx = e2.toInteger();
            if (len <= *pidx)
            {
                eSink.error(e.loc, "array index %lld is out of bounds `[0..%lld]`", *pidx, len);
                return false;
            }
        }
        return true;
    }

    override void visit(IndexExp e)
    {
        debug (LOG)
        {
            printf("%s IndexExp::interpret() %s, goal = %d\n", e.loc.toChars(), e.toChars(), goal);
        }
        if (e.e1.type.toBasetype().ty == Tpointer)
        {
            Expression agg;
            uinteger_t indexToAccess;
            if (!resolveIndexing(e, istate, &agg, &indexToAccess, false))
            {
                result = CTFEExp.cantexp;
                return;
            }
            if (agg.op == EXP.arrayLiteral || agg.op == EXP.string_)
            {
                if (goal == CTFEGoal.LValue)
                {
                    // if we need a reference, IndexExp shouldn't be interpreting
                    // the expression to a value, it should stay as a reference
                    emplaceExp!(IndexExp)(pue, e.loc, agg, ctfeEmplaceExp!IntegerExp(e.e2.loc, indexToAccess, e.e2.type));
                    result = pue.exp();
                    result.type = e.type;
                    return;
                }
                result = ctfeIndex(pue, e.loc, e.type, agg, indexToAccess);
                return;
            }
            else
            {
                assert(indexToAccess == 0);
                result = interpretRegion(agg, istate, goal);
                if (exceptionOrCant(result))
                    return;
                result = paintTypeOntoLiteral(pue, e.type, result);
                return;
            }
        }

        if (e.e1.type.toBasetype().ty == Taarray)
        {
            assert(false, "indexing AA should have been lowered in semantic analysis");
        }

        // Linear-memory fast paths: index into a slice whose value lives in
        // linear memory without materializing the array
        if (global.params.ctfeLinearMemory && e.e1.type.toBasetype().ty == Tarray)
        {
            if (goal == CTFEGoal.LValue)
            {
                auto ve = e.e1.isVarExp();
                auto v = ve ? ve.var.isVarDeclaration() : null;
                const slot = v ? ctfeGlobals.stack.sliceSlot(v) : CtfePtr.init;
                LinearSlice s;
                if (!slot.isNull && readSlice(ctfeGlobals.linearMem, slot, s))
                {
                    // committed: evaluate the index against the handle
                    if (e.lengthVar)
                    {
                        Expression dollarExp = ctfeEmplaceExp!IntegerExp(e.loc, s.length, Type.tsize_t);
                        ctfeGlobals.stack.push(e.lengthVar);
                        setValue(e.lengthVar, dollarExp);
                    }
                    UnionExp ue2 = void;
                    Expression e2 = interpret(&ue2, e.e2, istate);
                    if (e.lengthVar)
                        ctfeGlobals.stack.pop(e.lengthVar); // $ is defined only inside []
                    if (exceptionOrCant(e2))
                        return;
                    if (e2.op != EXP.int64)
                    {
                        error(e.loc, "CTFE internal error: non-integral index `[%s]`", e.e2.toErrMsg());
                        result = CTFEExp.cantexp;
                        return;
                    }
                    const idx = e2.toInteger();
                    if (idx >= s.length)
                    {
                        error(e.loc, "array index %lld is out of bounds `[0..%lld]`", idx, cast(ulong) s.length);
                        result = CTFEExp.cantexp;
                        return;
                    }
                    // A reference to the element, re-interpretable later; the
                    // base stays the variable so its value can stay linear
                    Expression ei = ctfeEmplaceExp!IntegerExp(e.e2.loc, idx, Type.tsize_t);
                    emplaceExp!(IndexExp)(pue, e.loc, e.e1, ei);
                    result = pue.exp();
                    result.type = e.type;
                    return;
                }
            }
            else
            {
                CtfePtr p;
                Type t;
                const rc = tryResolveLinearLoc(e, p, t);
                if (rc < 0)
                    return; // result is set (error or exception)
                if (rc > 0)
                {
                    result = decodeScalar(ctfeGlobals.linearMem, p, e.type, e.loc, pue);
                    if (result)
                        return;
                    // non-scalar element (e.g. a struct): materialize a copy,
                    // fine for an rvalue
                    result = decode(ctfeGlobals.linearMem, p, t, e.loc);
                    if (result)
                    {
                        result = paintTypeOntoLiteral(pue, e.type, result);
                        return;
                    }
                    error(e.loc, "cannot interpret `%s` at compile time", e.toErrMsg());
                    result = CTFEExp.cantexp;
                    return;
                }
            }
        }

        Expression agg;
        uinteger_t indexToAccess;
        if (!resolveIndexing(e, istate, &agg, &indexToAccess, false))
        {
            result = CTFEExp.cantexp;
            return;
        }

        if (goal == CTFEGoal.LValue)
        {
            Expression e2 = ctfeEmplaceExp!IntegerExp(e.e2.loc, indexToAccess, Type.tsize_t);
            emplaceExp!(IndexExp)(pue, e.loc, agg, e2);
            result = pue.exp();
            result.type = e.type;
            return;
        }

        result = ctfeIndex(pue, e.loc, e.type, agg, indexToAccess);
        if (exceptionOrCant(result))
            return;
        if (result.op == EXP.void_)
        {
            eSink.error(e.loc, "`%s` is used before initialized", e.toErrMsg());
            eSink.errorSupplemental(result.loc, "originally uninitialized here");
            result = CTFEExp.cantexp;
            return;
        }
        if (result == pue.exp())
            result = result.copy();
    }

    override void visit(SliceExp e)
    {
        debug (LOG)
        {
            printf("%s SliceExp::interpret() %s\n", e.loc.toChars(), e.toChars());
        }
        if (e.e1.type.toBasetype().ty == Tpointer)
        {
            // Slicing a pointer. Note that there is no $ in this case.
            Expression e1 = interpretRegion(e.e1, istate);
            if (exceptionOrCant(e1))
                return;
            if (e1.op == EXP.int64)
            {
                eSink.error(e.loc, "cannot slice invalid pointer `%s` of value `%s`", e.e1.toErrMsg(), e1.toErrMsg());
                result = CTFEExp.cantexp;
                return;
            }

            /* Evaluate lower and upper bounds of slice
             */
            Expression lwr = interpretRegion(e.lwr, istate);
            if (exceptionOrCant(lwr))
                return;
            Expression upr = interpretRegion(e.upr, istate);
            if (exceptionOrCant(upr))
                return;
            uinteger_t ilwr = lwr.toInteger();
            uinteger_t iupr = upr.toInteger();

            dinteger_t ofs;
            Expression agg = getAggregateFromPointer(e1, &ofs);
            ilwr += ofs;
            iupr += ofs;
            if (agg.op == EXP.null_)
            {
                if (iupr == ilwr)
                {
                    result = ctfeEmplaceExp!NullExp(e.loc);
                    result.type = e.type;
                    return;
                }
                eSink.error(e.loc, "cannot slice null pointer `%s`", e.e1.toErrMsg());
                result = CTFEExp.cantexp;
                return;
            }
            if (agg.op == EXP.symbolOffset)
            {
                eSink.error(e.loc, "slicing pointers to static variables is not supported in CTFE");
                result = CTFEExp.cantexp;
                return;
            }
            if (agg.op != EXP.arrayLiteral && agg.op != EXP.string_)
            {
                eSink.error(e.loc, "pointer `%s` cannot be sliced at compile time (it does not point to an array)", e.e1.toErrMsg());
                result = CTFEExp.cantexp;
                return;
            }
            assert(agg.op == EXP.arrayLiteral || agg.op == EXP.string_);
            dinteger_t len = ArrayLength(Type.tsize_t, agg).exp().toInteger();
            //Type *pointee = ((TypePointer *)agg.type)->next;
            if (sliceBoundsCheck(0, len, ilwr, iupr))
            {
                eSink.error(e.loc, "pointer slice `[%lld..%lld]` exceeds allocated memory block `[0..%lld]`", ilwr, iupr, len);
                result = CTFEExp.cantexp;
                return;
            }
            if (ofs != 0)
            {
                lwr = ctfeEmplaceExp!IntegerExp(e.loc, ilwr, lwr.type);
                upr = ctfeEmplaceExp!IntegerExp(e.loc, iupr, upr.type);
            }
            emplaceExp!(SliceExp)(pue, e.loc, agg, lwr, upr);
            result = pue.exp();
            result.type = e.type;
            return;
        }

        CTFEGoal goal1 = CTFEGoal.RValue;
        if (goal == CTFEGoal.LValue)
        {
            if (e.e1.type.toBasetype().ty == Tsarray)
                if (auto ve = e.e1.isVarExp())
                    if (auto vd = ve.var.isVarDeclaration())
                        if (vd.storage_class & STC.ref_)
                            goal1 = CTFEGoal.LValue;
        }
        Expression e1 = interpret(e.e1, istate, goal1);
        if (exceptionOrCant(e1))
            return;

        if (!e.lwr)
        {
            result = paintTypeOntoLiteral(pue, e.type, e1);
            return;
        }
        if (auto ve = e1.isVectorExp())
        {
            e1 = interpretVectorToArray(pue, ve);
            e1 = (e1 == pue.exp()) ? pue.copy() : e1;
        }

        /* Set dollar to the length of the array
         */
        uinteger_t dollar;
        if ((e1.op == EXP.variable || e1.op == EXP.dotVariable) && e1.type.toBasetype().ty == Tsarray)
            dollar = e1.type.toBasetype().isTypeSArray().dim.toInteger();
        else
        {
            if (e1.op != EXP.arrayLiteral && e1.op != EXP.string_ && e1.op != EXP.null_ && e1.op != EXP.slice && e1.op != EXP.vector)
            {
                eSink.error(e.loc, "cannot determine length of `%s` at compile time", e1.toErrMsg());
                result = CTFEExp.cantexp;
                return;
            }
            dollar = resolveArrayLength(e1);
        }

        /* Set the $ variable
         */
        if (e.lengthVar)
        {
            auto dollarExp = ctfeEmplaceExp!IntegerExp(e.loc, dollar, Type.tsize_t);
            ctfeGlobals.stack.push(e.lengthVar);
            setValue(e.lengthVar, dollarExp);
        }

        /* Evaluate lower and upper bounds of slice
         */
        Expression lwr = interpretRegion(e.lwr, istate);
        if (exceptionOrCant(lwr))
        {
            if (e.lengthVar)
                ctfeGlobals.stack.pop(e.lengthVar);
            return;
        }
        Expression upr = interpretRegion(e.upr, istate);
        if (exceptionOrCant(upr))
        {
            if (e.lengthVar)
                ctfeGlobals.stack.pop(e.lengthVar);
            return;
        }
        if (e.lengthVar)
            ctfeGlobals.stack.pop(e.lengthVar); // $ is defined only inside [L..U]

        uinteger_t ilwr = lwr.toInteger();
        uinteger_t iupr = upr.toInteger();
        if (e1.op == EXP.null_)
        {
            if (ilwr == 0 && iupr == 0)
            {
                result = e1;
                return;
            }
            eSink.error(e1.loc, "slice `[%llu..%llu]` is out of bounds", ilwr, iupr);
            result = CTFEExp.cantexp;
            return;
        }
        if (auto se = e1.isSliceExp())
        {
            // Simplify slice of slice:
            //  aggregate[lo1..up1][lwr..upr] ---> aggregate[lwr'..upr']
            uinteger_t lo1 = se.lwr.toInteger();
            uinteger_t up1 = se.upr.toInteger();
            if (sliceBoundsCheck(0, up1 - lo1, ilwr, iupr))
            {
                eSink.error(e.loc, "slice `[%llu..%llu]` exceeds array bounds `[0..%llu]`", ilwr, iupr, up1 - lo1);
                result = CTFEExp.cantexp;
                return;
            }
            ilwr += lo1;
            iupr += lo1;
            emplaceExp!(SliceExp)(pue, e.loc, se.e1,
                ctfeEmplaceExp!IntegerExp(e.loc, ilwr, lwr.type),
                ctfeEmplaceExp!IntegerExp(e.loc, iupr, upr.type));
            result = pue.exp();
            result.type = e.type;
            return;
        }
        if (e1.op == EXP.arrayLiteral || e1.op == EXP.string_)
        {
            if (sliceBoundsCheck(0, dollar, ilwr, iupr))
            {
                eSink.error(e.loc, "slice `[%lld..%lld]` exceeds array bounds `[0..%lld]`", ilwr, iupr, dollar);
                result = CTFEExp.cantexp;
                return;
            }
        }
        emplaceExp!(SliceExp)(pue, e.loc, e1, lwr, upr);
        result = pue.exp();
        result.type = e.type;
    }

    override void visit(CatExp e)
    {
        debug (LOG)
        {
            printf("%s CatExp::interpret() %s\n", e.loc.toChars(), e.toChars());
        }

        UnionExp ue1 = void;
        Expression e1 = interpret(&ue1, e.e1, istate);
        if (exceptionOrCant(e1))
            return;

        UnionExp ue2 = void;
        Expression e2 = interpret(&ue2, e.e2, istate);
        if (exceptionOrCant(e2))
            return;

        UnionExp e1tmp = void;
        e1 = resolveSlice(e1, &e1tmp);

        UnionExp e2tmp = void;
        e2 = resolveSlice(e2, &e2tmp);

        /* e1 and e2 can't go on the stack because of x~[y] and [x]~y will
         * result in [x,y] and then x or y is on the stack.
         * But if they are both strings, we can, because it isn't the x~[y] case.
         */
        if (!(e1.op == EXP.string_ && e2.op == EXP.string_))
        {
            if (e1 == ue1.exp())
                e1 = ue1.copy();
            if (e2 == ue2.exp())
                e2 = ue2.copy();
        }

        Expression prepareCatOperand(Expression exp)
        {
            /* Convert `elem ~ array` to `[elem] ~ array` if `elem` is itself an
             * array. This is needed because interpreting the `CatExp` calls
             * `Cat()`, which cannot handle concatenations between different
             * types, except for strings and chars.
             */
            auto tb = e.type.toBasetype();
            auto tbNext = tb.nextOf();
            auto expTb = exp.type.toBasetype();

            if (exp.type.implicitConvTo(tbNext) >= MATCH.convert &&
                tb.isStaticOrDynamicArray() && expTb.isStaticOrDynamicArray())
                return new ArrayLiteralExp(exp.loc, e.type, exp);
            return exp;
        }

        *pue = ctfeCat(e.loc, e.type, prepareCatOperand(e1), prepareCatOperand(e2));
        result = pue.exp();

        if (CTFEExp.isCantExp(result))
        {
            eSink.error(e.loc, "`%s` cannot be interpreted at compile time", e.toErrMsg());
            return;
        }
        // We know we still own it, because we interpreted both e1 and e2
        if (auto ale = result.isArrayLiteralExp())
        {
            ale.ownedByCtfe = OwnedBy.ctfe;

            // https://issues.dlang.org/show_bug.cgi?id=14686
            foreach (elem; *ale.elements)
            {
                if (!elem) continue;
                Expression ex = evaluatePostblit(istate, elem);
                if (exceptionOrCant(ex))
                    return;
            }
        }
        else if (auto se = result.isStringExp())
            se.ownedByCtfe = OwnedBy.ctfe;
    }

    override void visit(DeleteExp e)
    {
        debug (LOG)
        {
            printf("%s DeleteExp::interpret() %s\n", e.loc.toChars(), e.toChars());
        }
        result = interpretRegion(e.e1, istate);
        if (exceptionOrCant(result))
            return;

        if (result.op == EXP.null_)
        {
            result = CTFEExp.voidexp;
            return;
        }

        auto tb = e.e1.type.toBasetype();
        switch (tb.ty)
        {
        case Tclass:
            if (result.op != EXP.classReference)
            {
                eSink.error(e.loc, "`delete` on invalid class reference `%s`", result.toErrMsg());
                result = CTFEExp.cantexp;
                return;
            }

            auto cre = result.isClassReferenceExp();
            auto cd = cre.originalClass();

            // Find dtor(s) in inheritance chain
            do
            {
                if (cd.dtor)
                {
                    result = interpretFunction(pue, cd.dtor, istate, null, cre);
                    if (exceptionOrCant(result))
                        return;

                    // Dtors of Non-extern(D) classes use implicit chaining (like structs)
                    import dmd.aggregate : ClassKind;
                    if (cd.classKind != ClassKind.d)
                        break;
                }

                // Emulate manual chaining as done in rt_finalize2
                cd = cd.baseClass;

            } while (cd); // Stop after Object

            break;

        default:
            assert(0);
        }
        result = CTFEExp.voidexp;
    }

    override void visit(CastExp e)
    {
        debug (LOG)
        {
            printf("%s CastExp::interpret() %s\n", e.loc.toChars(), e.toChars());
        }
        if (goal != CTFEGoal.LValue && rawScalarResult(e))
            return;
        Expression e1 = interpretRegion(e.e1, istate, goal);
        if (exceptionOrCant(e1))
            return;
        // If the expression has been cast to void, do nothing.
        if (e.to.ty == Tvoid)
        {
            result = CTFEExp.voidexp;
            return;
        }
        if (e.to.ty == Tpointer && e1.op != EXP.null_)
        {
            Type pointee = (cast(TypePointer)e.type).next;
            // Implement special cases of normally-unsafe casts
            if (e1.op == EXP.int64)
            {
                // Happens with Windows HANDLEs, for example.
                result = paintTypeOntoLiteral(pue, e.to, e1);
                return;
            }

            bool castToSarrayPointer = false;
            bool castBackFromVoid = false;
            if (e1.type.isStaticOrDynamicArray() || e1.type.ty == Tpointer)
            {
                // Check for unsupported type painting operations
                // For slices, we need the type being sliced,
                // since it may have already been type painted
                Type elemtype = e1.type.nextOf();
                if (auto se = e1.isSliceExp())
                    elemtype = se.e1.type.nextOf();

                // Allow casts from X* to void *, and X** to void** for any X.
                // But don't allow cast from X* to void**.
                // So, we strip all matching * from source and target to find X.
                // Allow casts to X* from void* only if the 'void' was originally an X;
                // we check this later on.
                Type ultimatePointee = pointee;
                Type ultimateSrc = elemtype;
                while (ultimatePointee.ty == Tpointer && ultimateSrc.ty == Tpointer)
                {
                    ultimatePointee = ultimatePointee.nextOf();
                    ultimateSrc = ultimateSrc.nextOf();
                }
                if (ultimatePointee.ty == Tsarray && ultimatePointee.nextOf().equivalent(ultimateSrc))
                {
                    castToSarrayPointer = true;
                }
                else if (ultimatePointee.ty != Tvoid && ultimateSrc.ty != Tvoid && !isSafePointerCast(elemtype, pointee))
                {
                    eSink.error(e.loc, "reinterpreting cast from `%s*` to `%s*` is not supported in CTFE", elemtype.toErrMsg(), pointee.toErrMsg());
                    result = CTFEExp.cantexp;
                    return;
                }
                if (ultimateSrc.ty == Tvoid)
                    castBackFromVoid = true;
            }

            if (auto se = e1.isSliceExp())
            {
                if (se.e1.op == EXP.null_)
                {
                    result = paintTypeOntoLiteral(pue, e.type, se.e1);
                    return;
                }
                // Create a CTFE pointer &aggregate[1..2]
                auto ei = ctfeEmplaceExp!IndexExp(e.loc, se.e1, se.lwr);
                ei.type = e.type.nextOf();
                emplaceExp!(AddrExp)(pue, e.loc, ei, e.type);
                result = pue.exp();
                return;
            }
            if (e1.op == EXP.arrayLiteral || e1.op == EXP.string_)
            {
                // Create a CTFE pointer &[1,2,3][0] or &"abc"[0]
                auto ei = ctfeEmplaceExp!IndexExp(e.loc, e1, ctfeEmplaceExp!IntegerExp(e.loc, 0, Type.tsize_t));
                ei.type = e.type.nextOf();
                emplaceExp!(AddrExp)(pue, e.loc, ei, e.type);
                result = pue.exp();
                return;
            }
            if (e1.op == EXP.index && !e1.isIndexExp().e1.type.equals(e1.type))
            {
                // type painting operation
                IndexExp ie = e1.isIndexExp();
                if (castBackFromVoid)
                {
                    // get the original type. For strings, it's just the type...
                    Type origType = ie.e1.type.nextOf();
                    // ..but for arrays of type void*, it's the type of the element
                    if (ie.e1.op == EXP.arrayLiteral && ie.e2.op == EXP.int64)
                    {
                        ArrayLiteralExp ale = ie.e1.isArrayLiteralExp();
                        const indx = cast(size_t)ie.e2.toInteger();
                        if (indx < ale.length)
                        {
                            if (Expression xx = ale[indx])
                            {
                                if (auto iex = xx.isIndexExp())
                                    origType = iex.e1.type.nextOf();
                                else if (auto ae = xx.isAddrExp())
                                    origType = ae.e1.type;
                                else if (auto ve = xx.isVarExp())
                                    origType = ve.var.type;
                            }
                        }
                    }
                    if (!isSafePointerCast(origType, pointee))
                    {
                        eSink.error(e.loc, "using `void*` to reinterpret cast from `%s*` to `%s*` is not supported in CTFE", origType.toErrMsg(), pointee.toErrMsg());
                        result = CTFEExp.cantexp;
                        return;
                    }
                }
                emplaceExp!(IndexExp)(pue, e1.loc, ie.e1, ie.e2);
                result = pue.exp();
                result.type = e.type;
                return;
            }

            if (auto ae = e1.isAddrExp())
            {
                Type origType = ae.e1.type;
                if (isSafePointerCast(origType, pointee))
                {
                    emplaceExp!(AddrExp)(pue, e.loc, ae.e1, e.type);
                    result = pue.exp();
                    return;
                }

                if (castToSarrayPointer && pointee.toBasetype().ty == Tsarray && ae.e1.op == EXP.index)
                {
                    // &val[idx]
                    dinteger_t dim = (cast(TypeSArray)pointee.toBasetype()).dim.toInteger();
                    IndexExp ie = ae.e1.isIndexExp();
                    Expression lwr = ie.e2;
                    Expression upr = ctfeEmplaceExp!IntegerExp(ie.e2.loc, ie.e2.toInteger() + dim, Type.tsize_t);

                    // Create a CTFE pointer &val[idx..idx+dim]
                    auto er = ctfeEmplaceExp!SliceExp(e.loc, ie.e1, lwr, upr);
                    er.type = pointee;
                    emplaceExp!(AddrExp)(pue, e.loc, er, e.type);
                    result = pue.exp();
                    return;
                }
            }

            if (e1.op == EXP.variable || e1.op == EXP.symbolOffset)
            {
                // type painting operation
                Type origType = (cast(SymbolExp)e1).var.type;
                if (castBackFromVoid && !isSafePointerCast(origType, pointee))
                {
                    eSink.error(e.loc, "using `void*` to reinterpret cast from `%s*` to `%s*` is not supported in CTFE", origType.toErrMsg(), pointee.toErrMsg());
                    result = CTFEExp.cantexp;
                    return;
                }
                if (auto ve = e1.isVarExp())
                    emplaceExp!(VarExp)(pue, e.loc, ve.var);
                else
                    emplaceExp!(SymOffExp)(pue, e.loc, e1.isSymOffExp().var, e1.isSymOffExp().offset);
                result = pue.exp();
                result.type = e.to;
                return;
            }

            // Check if we have a null pointer (eg, inside a struct)
            e1 = interpretRegion(e1, istate);
            if (e1.op != EXP.null_)
            {
                eSink.error(e.loc, "pointer cast from `%s` to `%s` is not supported at compile time", e1.type.toErrMsg(), e.to.toErrMsg());
                result = CTFEExp.cantexp;
                return;
            }
        }
        if (e.to.ty == Tsarray && e.e1.type.ty == Tvector)
        {
            // Special handling for: cast(float[4])__vector([w, x, y, z])
            e1 = interpretRegion(e.e1, istate);
            if (exceptionOrCant(e1))
                return;
            assert(e1.op == EXP.vector);
            e1 = interpretVectorToArray(pue, e1.isVectorExp());
        }
        if (e.to.ty == Tarray && e1.op == EXP.slice)
        {
            // Note that the slice may be void[], so when checking for dangerous
            // casts, we need to use the original type, which is se.e1.
            SliceExp se = e1.isSliceExp();
            if (!isSafePointerCast(se.e1.type.nextOf(), e.to.nextOf()))
            {
                eSink.error(e.loc, "array cast from `%s` to `%s` is not supported at compile time", se.e1.type.toErrMsg(), e.to.toErrMsg());
                result = CTFEExp.cantexp;
                return;
            }
            emplaceExp!(SliceExp)(pue, e1.loc, se.e1, se.lwr, se.upr);
            result = pue.exp();
            result.type = e.to;
            return;
        }

        // Disallow array type painting, except for conversions between built-in
        // types of identical size.
        if (e.to.isStaticOrDynamicArray() && e1.type.isStaticOrDynamicArray() && !isSafePointerCast(e1.type.nextOf(), e.to.nextOf()))
        {
            auto se = e1.isStringExp();
            // Allow casting a hex string literal to short[], int[] or long[]
            if (se && se.hexString && se.postfix == StringExp.NoPostfix && e.to.nextOf().isIntegral)
            {
                const sz = cast(size_t) e.to.nextOf().size;
                if ((se.len % sz) != 0)
                {
                    eSink.error(e.loc, "hex string length %d must be a multiple of %d to cast to `%s`",
                        cast(int) se.len, cast(int) sz, e.to.toErrMsg());
                    result = CTFEExp.cantexp;
                    return;
                }

                auto str = arrayCastBigEndian(se.peekData(), sz);
                emplaceExp!(StringExp)(pue, e1.loc, str, se.len / sz, cast(ubyte) sz);
                result = pue.exp();
                result.type = e.to;
                return;
            }
            eSink.error(e.loc, "array cast from `%s` to `%s` is not supported at compile time", e1.type.toErrMsg(), e.to.toErrMsg());
            if (se && se.hexString && se.postfix != StringExp.NoPostfix)
                eSink.errorSupplemental(e.loc, "perhaps remove postfix `%.*s` from hex string", 1, &se.postfix);

            result = CTFEExp.cantexp;
            return;
        }
        if (e.to.ty == Tsarray)
            e1 = resolveSlice(e1);

        auto tobt = e.to.toBasetype();
        if (tobt.ty == Tbool && e1.type.ty == Tpointer)
        {
            emplaceExp!(IntegerExp)(pue, e.loc, e1.op != EXP.null_, e.to);
            result = pue.exp();
            return;
        }
        else if (tobt.isTypeBasic() && e1.op == EXP.null_)
        {
            if (tobt.isIntegral())
                emplaceExp!(IntegerExp)(pue, e.loc, 0, e.to);
            else if (tobt.isReal())
                emplaceExp!(RealExp)(pue, e.loc, CTFloat.zero, e.to);
            result = pue.exp();
            return;
        }
        result = ctfeCast(pue, e.loc, e.type, e.to, e1, true);
    }

    override void visit(AssertExp e)
    {
        debug (LOG)
        {
            printf("%s AssertExp::interpret() %s\n", e.loc.toChars(), e.toChars());
        }
        Expression e1 = interpret(pue, e.e1, istate);
        if (exceptionOrCant(e1))
            return;
        if (isTrueBool(e1))
        {
        }
        else if (e1.toBool().hasValue(false))
        {
            if (e.msg)
            {
                UnionExp ue = void;
                result = interpret(&ue, e.msg, istate);
                if (exceptionOrCant(result))
                    return;
                result = scrubReturnValue(e.loc, result);
                if (StringExp se = result.toStringExp())
                    eSink.error(e.loc, "%s", se.toStringz().ptr);
                else
                    eSink.error(e.loc, "%s", result.toErrMsg());
            }
            else
                eSink.error(e.loc, "`%s` failed", e.toErrMsg());
            result = CTFEExp.cantexp;
            return;
        }
        else
        {
            eSink.error(e.loc, "`%s` is not a compile time boolean expression", e1.toErrMsg());
            result = CTFEExp.cantexp;
            return;
        }
        result = e1;
        return;
    }

    override void visit(ThrowExp te)
    {
        debug (LOG)
        {
            printf("%s ThrowExpression::interpret()\n", te.loc.toChars());
        }
        interpretThrow(result, te.e1, te.loc, istate);
    }

    override void visit(PtrExp e)
    {
        // Called for both lvalues and rvalues
        const lvalue = goal == CTFEGoal.LValue;
        debug (LOG)
        {
            printf("%s PtrExp::interpret(%d) %s, %s\n", e.loc.toChars(), lvalue, e.type.toChars(), e.toChars());
        }

        // Check for int<->float and long<->double casts.
        if (auto soe1 = e.e1.isSymOffExp())
            if (soe1.offset == 0 && soe1.var.isVarDeclaration() && isFloatIntPaint(e.type, soe1.var.type))
            {
                // *(cast(int*)&v), where v is a float variable
                result = paintFloatInt(pue, getVarExp(e.loc, istate, soe1.var, CTFEGoal.RValue), e.type);
                return;
            }

        if (auto ce1 = e.e1.isCastExp())
            if (auto ae11 = ce1.e1.isAddrExp())
            {
                // *(cast(int*)&x), where x is a float expression
                Expression x = ae11.e1;
                if (isFloatIntPaint(e.type, x.type))
                {
                    result = paintFloatInt(pue, interpretRegion(x, istate), e.type);
                    return;
                }
            }

        // Constant fold *(&structliteral + offset)
        if (auto ae = e.e1.isAddExp())
        {
            if (ae.e1.op == EXP.address && ae.e2.op == EXP.int64)
            {
                AddrExp ade = ae.e1.isAddrExp();
                Expression ex = interpretRegion(ade.e1, istate);
                if (exceptionOrCant(ex))
                    return;
                if (auto se = ex.isStructLiteralExp())
                {
                    dinteger_t offset = ae.e2.toInteger();
                    result = se.getField(e.type, cast(uint)offset);
                    if (result)
                        return;
                }
            }
        }

        // It's possible we have an array bounds error. We need to make sure it
        // errors with this line number, not the one where the pointer was set.
        result = interpretRegion(e.e1, istate);
        if (exceptionOrCant(result))
            return;

        if (result.op == EXP.function_)
            return;
        if (auto soe = result.isSymOffExp())
        {
            if (soe.offset == 0 && soe.var.isFuncDeclaration())
                return;
            if (soe.offset == 0 && soe.var.isVarDeclaration() && soe.var.isImmutable())
            {
                result = getVarExp(e.loc, istate, soe.var, CTFEGoal.RValue);
                return;
            }
            eSink.error(e.loc, "cannot dereference pointer to static variable `%s` at compile time", soe.var.toErrMsg());
            result = CTFEExp.cantexp;
            return;
        }

        if (!lvalue && result.isArrayLiteralExp() &&
            result.type.isTypePointer())
        {
            /* A pointer variable can point to an array literal like `[3]`.
             * Dereferencing it means accessing the first element value.
             * Dereference it only if result should be an rvalue
             */
            auto ae = result.isArrayLiteralExp();
            if (ae.length == 1)
            {
                result = ae[0];
                return;
            }
        }
        if (result.isStringExp() || result.isArrayLiteralExp())
            return;

        if (result.op != EXP.address)
        {
            if (result.op == EXP.null_)
                eSink.error(e.loc, "dereference of null pointer `%s`", e.e1.toErrMsg());
            else
                eSink.error(e.loc, "dereference of invalid pointer `%s`", result.toErrMsg());
            result = CTFEExp.cantexp;
            return;
        }

        // *(&x) ==> x
        result = result.isAddrExp().e1;

        if (result.op == EXP.slice && e.type.toBasetype().ty == Tsarray)
        {
            /* aggr[lwr..upr]
             * upr may exceed the upper boundary of aggr, but the check is deferred
             * until those out-of-bounds elements will be touched.
             */
            return;
        }
        result = interpret(pue, result, istate, goal);
        if (exceptionOrCant(result))
            return;

        debug (LOG)
        {
            if (CTFEExp.isCantExp(result))
                printf("PtrExp::interpret() %s = CTFEExp::cantexp\n", e.toChars());
        }
    }

    override void visit(DotVarExp e)
    {
        void notImplementedYet()
        {
            eSink.error(e.loc, "`%s.%s` is not yet implemented at compile time", e.e1.toErrMsg(), e.var.toErrMsg());
            result = CTFEExp.cantexp;
            return;
        }

        debug (LOG)
        {
            printf("%s DotVarExp::interpret() %s, goal = %d\n", e.loc.toChars(), e.toChars(), goal);
        }
        // Linear-memory fast path: read a scalar field of a struct stored in
        // a linear slice payload (e.g. `arr[i].x`, or through a `ref`
        // element) without materializing the array
        if (global.params.ctfeLinearMemory && goal != CTFEGoal.LValue &&
            isLinearScalarType(e.type))
        {
            CtfePtr p;
            Type t;
            const rc = tryResolveLinearLoc(e, p, t);
            if (rc < 0)
                return; // result is set (error or exception)
            if (rc > 0)
            {
                result = decodeScalar(ctfeGlobals.linearMem, p, e.type, e.loc, pue);
                if (result)
                    return;
                error(e.loc, "cannot interpret `%s` at compile time", e.toErrMsg());
                result = CTFEExp.cantexp;
                return;
            }
        }
        Expression ex = interpretRegion(e.e1, istate);
        if (exceptionOrCant(ex))
            return;

        if (FuncDeclaration f = e.var.isFuncDeclaration())
        {
            if (ex == e.e1)
                result = e; // optimize: reuse this CTFE reference
            else
            {
                emplaceExp!(DotVarExp)(pue, e.loc, ex, f, false);
                result = pue.exp();
                result.type = e.type;
            }
            return;
        }

        VarDeclaration v = e.var.isVarDeclaration();
        if (!v)
        {
            eSink.error(e.loc, "CTFE internal error: `%s`", e.toErrMsg());
            result = CTFEExp.cantexp;
            return;
        }

        if (ex.op == EXP.null_)
        {
            if (ex.type.toBasetype().ty == Tclass)
                eSink.error(e.loc, "class `%s` is `null` and cannot be dereferenced", e.e1.toErrMsg());
            else
                eSink.error(e.loc, "CTFE internal error: null this `%s`", e.e1.toErrMsg());
            result = CTFEExp.cantexp;
            return;
        }

        StructLiteralExp se;
        int i;

        if (ex.op != EXP.structLiteral && ex.op != EXP.classReference && ex.op != EXP.typeid_)
        {
            return notImplementedYet();
        }

        // We can't use getField, because it makes a copy
        if (ex.op == EXP.classReference)
        {
            se = ex.isClassReferenceExp().value;
            i = ex.isClassReferenceExp().findFieldIndexByName(v);
        }
        else if (ex.op == EXP.typeid_)
        {
            if (v.ident == Identifier.idPool("name"))
            {
                if (auto t = isType(ex.isTypeidExp().obj))
                {
                    import dmd.typesem : toDsymbol;
                    auto sym = t.toDsymbol(null);
                    if (auto ident = (sym ? sym.ident : null))
                    {
                        result = new StringExp(e.loc, ident.toString());
                        result.expressionSemantic(null);
                        return ;
                    }
                }
            }
            return notImplementedYet();
        }
        else
        {
            se = ex.isStructLiteralExp();
            i = findFieldIndexByName(se.sd, v);
        }
        if (i == -1)
        {
            eSink.error(e.loc, "couldn't find field `%s` of type `%s` in `%s`", v.toErrMsg(), e.type.toErrMsg(), se.toErrMsg());
            result = CTFEExp.cantexp;
            return;
        }

        // https://issues.dlang.org/show_bug.cgi?id=19897
        // https://issues.dlang.org/show_bug.cgi?id=20710
        // Zero-elements fields don't have an initializer. See: scrubArray function
        if ((*se.elements)[i] is null)
            (*se.elements)[i] = voidInitLiteral(e.type, v).copy();

        if (goal == CTFEGoal.LValue)
        {
            // just return the (simplified) dotvar expression as a CTFE reference
            if (e.e1 == ex)
                result = e;
            else
            {
                emplaceExp!(DotVarExp)(pue, e.loc, ex, v);
                result = pue.exp();
                result.type = e.type;
            }
            return;
        }

        result = (*se.elements)[i];
        if (!result)
        {
            eSink.error(e.loc, "internal compiler error: null field `%s`", v.toErrMsg());
            result = CTFEExp.cantexp;
            return;
        }
        if (auto vie = result.isVoidInitExp())
        {
            const s = vie.var.toChars();
            if (v.overlapped)
            {
                eSink.error(e.loc, "reinterpretation through overlapped field `%s` is not allowed in CTFE", s);
                result = CTFEExp.cantexp;
                return;
            }
            eSink.error(e.loc, "cannot read uninitialized variable `%s` in CTFE", s);
            result = CTFEExp.cantexp;
            return;
        }

        if (v.type.ty != result.type.ty && v.type.ty == Tsarray)
        {
            // Block assignment from inside struct literals
            auto tsa = cast(TypeSArray)v.type;
            auto len = cast(size_t)tsa.dim.toInteger();
            UnionExp ue = void;
            result = createBlockDuplicatedArrayLiteral(&ue, e.loc, v.type, result, len);
            if (result == ue.exp())
                result = ue.copy();
            (*se.elements)[i] = result;
        }
        debug (LOG)
        {
            if (CTFEExp.isCantExp(result))
                printf("DotVarExp::interpret() %s = CTFEExp::cantexp\n", e.toChars());
        }
    }

    override void visit(ClassReferenceExp e)
    {
        //printf("ClassReferenceExp::interpret() %s\n", e.value.toChars());
        result = e;
    }

    override void visit(VoidInitExp e)
    {
        eSink.error(e.loc, "CTFE internal error: trying to read uninitialized variable");
        assert(0);
    }

    override void visit(ThrownExceptionExp e)
    {
        assert(0); // This should never be interpreted
    }
}

/// Interpret `throw <exp>` found at the specified location `loc`
private
void interpretThrow(ref Expression result, Expression exp, Loc loc, InterState* istate)
{
    incUsageCtfe(istate, loc);

    Expression e = interpretRegion(exp, istate);
    if (exceptionOrCantInterpret(e))
    {
        // Make sure e is not pointing to a stack temporary
        result = (e.op == EXP.cantExpression) ? CTFEExp.cantexp : e;
    }
    else if (e.op == EXP.classReference)
    {
        result = ctfeEmplaceExp!ThrownExceptionExp(loc, e.isClassReferenceExp());
    }
    else
    {
	auto eSink = global.errorSink;
        eSink.error(exp.loc, "to be thrown `%s` must be non-null", exp.toErrMsg());
        result = ErrorExp.get();
    }
}

/*********************************************
 * Checks if the given expresion is a call to the runtime hook `id`.
 *
 * Params:
 *    e = the expression to check
 *    id = the identifier of the runtime hook
 * Returns:
 *    `e` cast to `CallExp` if it's the hook, `null` otherwise
 */
public CallExp isRuntimeHook(Expression e, Identifier id)
{
    if (auto ce = e.isCallExp())
    {
        if (auto ve = ce.e1.isVarExp())
        {
            if (auto fd = ve.var.isFuncDeclaration())
            {
                // If `_d_HookTraceImpl` is found, resolve the underlying hook
                // and replace `e` and `fd` with it.
                removeHookTraceImpl(ce, fd);
                return fd.ident == id ? ce : null;
            }
        }
    }

    return null;
}

/********************************************
 * Interpret the expression.
 * Params:
 *    pue = non-null pointer to temporary storage that can be used to store the return value
 *    e = Expression to interpret
 *    istate = context
 *    goal = what the result will be used for
 * Returns:
 *    resulting expression
 */

Expression interpret(UnionExp* pue, Expression e, InterState* istate, CTFEGoal goal = CTFEGoal.RValue)
{
    if (!e)
        return null;
    //printf("+interpret() e : %s, %s\n", e.type.toChars(), e.toChars());
    scope Interpreter v = new Interpreter(pue, istate, goal);
    e.accept(v);
    Expression ex = v.result;
    assert(goal == CTFEGoal.Nothing || ex !is null);
    //if (ex) printf("-interpret() ex: %s, %s\n", ex.type.toChars(), ex.toChars()); else printf("-interpret()\n");
    return ex;
}

///
Expression interpret(Expression e, InterState* istate, CTFEGoal goal = CTFEGoal.RValue)
{
    UnionExp ue = void;
    auto result = interpret(&ue, e, istate, goal);
    if (result == ue.exp())
        result = ue.copy();
    return result;
}

/*****************************
 * Same as interpret(), but return result allocated in Region.
 * Params:
 *    e = Expression to interpret
 *    istate = context
 *    goal = what the result will be used for
 * Returns:
 *    resulting expression
 */
Expression interpretRegion(Expression e, InterState* istate, CTFEGoal goal = CTFEGoal.RValue)
{
    UnionExp ue = void;
    auto result = interpret(&ue, e, istate, goal);
    if (result != ue.exp())
        return result;
    return regionUeCopy(ue);
}

/*****************************
 * Copy the expression in `ue` into the CTFE region, mimicking UnionExp.copy
 * but with region allocation.
 */
private Expression regionUeCopy(ref UnionExp ue)
{
    auto uexp = ue.exp();
    if (mem.isGCEnabled)
        return ue.copy();

    switch (uexp.op)
    {
        case EXP.cantExpression: return CTFEExp.cantexp;
        case EXP.voidExpression: return CTFEExp.voidexp;
        case EXP.break_:         return CTFEExp.breakexp;
        case EXP.continue_:      return CTFEExp.continueexp;
        case EXP.goto_:          return CTFEExp.gotoexp;
        default:                 break;
    }
    auto p = ctfeGlobals.region.malloc(uexp.size);
    return cast(Expression)memcpy(p, cast(void*)uexp, uexp.size);
}

private
Expressions* copyArrayOnWrite(Expressions* exps, Expressions* original)
{
    if (exps is original)
    {
        if (!original)
            exps = new Expressions();
        else
            exps = original.copy();
        ++ctfeGlobals.numArrayAllocs;
    }
    return exps;
}

/**
 Given an expression e which is about to be returned from the current
 function, generate an error if it contains pointers to local variables.

 Only checks expressions passed by value (pointers to local variables
 may already be stored in members of classes, arrays, or AAs which
 were passed as mutable function parameters).
 Returns:
    true if it is safe to return, false if an error was generated.
 */
private
bool stopPointersEscaping(Loc loc, Expression e)
{
    import dmd.typesem : hasPointers;
    if (!e.type.hasPointers())
        return true;
    if (isPointer(e.type))
    {
        Expression x = e;
        if (auto eaddr = e.isAddrExp())
            x = eaddr.e1;
        VarDeclaration v;
        while (x.op == EXP.variable && (v = x.isVarExp().var.isVarDeclaration()) !is null)
        {
            if (v.storage_class & STC.ref_)
            {
                x = getValue(v);
                if (auto eaddr = e.isAddrExp())
                    eaddr.e1 = x;
                continue;
            }
            if (ctfeGlobals.stack.isInCurrentFrame(v))
            {
                auto eSink = global.errorSink;
                eSink.error(loc, "returning a pointer to a local stack variable");
                return false;
            }
            else
                break;
        }
        // TODO: If it is a EXP.dotVariable or EXP.index, we should check that it is not
        // pointing to a local struct or static array.
    }
    if (auto se = e.isStructLiteralExp())
    {
        return stopPointersEscapingFromArray(loc, se.elements);
    }
    if (auto ale = e.isArrayLiteralExp())
    {
        return stopPointersEscapingFromArray(loc, ale.elements);
    }
    if (auto aae = e.isAssocArrayLiteralExp())
    {
        if (!stopPointersEscapingFromArray(loc, aae.keys))
            return false;
        return stopPointersEscapingFromArray(loc, aae.values);
    }
    return true;
}

// Check all elements of an array for escaping local variables. Return false if error
private
bool stopPointersEscapingFromArray(Loc loc, Expressions* elems)
{
    foreach (e; *elems)
    {
        if (e && !stopPointersEscaping(loc, e))
            return false;
    }
    return true;
}

private
Statement findGotoTarget(InterState* istate, Identifier ident)
{
    Statement target = null;
    if (ident)
    {
        LabelDsymbol label = istate.fd.searchLabel(ident, Loc.initial);
        assert(label && label.statement);
        LabelStatement ls = label.statement;
        target = ls.gotoTarget ? ls.gotoTarget : ls.statement;
    }
    return target;
}

private
ThrownExceptionExp chainExceptions(ThrownExceptionExp oldest, ThrownExceptionExp newest)
{
    debug (LOG)
    {
        printf("Collided exceptions %s %s\n", oldest.thrown.toChars(), newest.thrown.toChars());
    }
    // Little sanity check to make sure it's really a Throwable
    ClassReferenceExp boss = oldest.thrown;
    const next = 5;                          // index of Throwable._nextInChainPtr
    with ((*boss.value.elements)[next].type) // Throwable._nextInChainPtr
        assert(ty == Tpointer || ty == Tclass);
    ClassReferenceExp collateral = newest.thrown;
    if (collateral.originalClass().isErrorException() && !boss.originalClass().isErrorException())
    {
        /* Find the index of the Error.bypassException field
         */
        auto bypass = next + 1;
        if ((*collateral.value.elements)[bypass].type.ty == Tuns32)
            bypass += 1;  // skip over _refcount field
        assert((*collateral.value.elements)[bypass].type.ty == Tclass);

        // The new exception bypass the existing chain
        (*collateral.value.elements)[bypass] = boss;
        return newest;
    }
    while ((*boss.value.elements)[next].op == EXP.classReference)
    {
        boss = (*boss.value.elements)[next].isClassReferenceExp();
    }
    (*boss.value.elements)[next] = collateral;
    return oldest;
}

/**
 * All results destined for use outside of CTFE need to have their CTFE-specific
 * features removed.
 * In particular,
 * 1. all slices must be resolved.
 * 2. all .ownedByCtfe set to OwnedBy.code
 */
private Expression scrubReturnValue(Loc loc, Expression e)
{
    auto eSink = global.errorSink;

    /* Returns: true if e is void,
     * or is an array literal or struct literal of void elements.
     */
    static bool isVoid(const Expression e, bool checkArrayType = false) pure
    {
        if (e.op == EXP.void_)
            return true;

        static bool isEntirelyVoid(const Expressions* elems)
        {
            foreach (e; *elems)
            {
                // It can be NULL for performance reasons,
                // see StructLiteralExp::interpret().
                if (e && !isVoid(e))
                    return false;
            }
            return true;
        }

        if (auto sle = e.isStructLiteralExp())
            return isEntirelyVoid(sle.elements);

        if (checkArrayType && e.type.ty != Tsarray)
            return false;

        if (auto ale = e.isArrayLiteralExp())
            return isEntirelyVoid(ale.elements);

        return false;
    }


    /* Scrub all elements of elems[].
     * Returns: null for success, error Expression for failure
     */
    Expression scrubArray(Expressions* elems, bool structlit = false)
    {
        foreach (ref e; *elems)
        {
            // It can be NULL for performance reasons,
            // see StructLiteralExp::interpret().
            if (!e)
                continue;

            // A struct .init may contain void members.
            // Static array members are a weird special case https://issues.dlang.org/show_bug.cgi?id=10994
            if (structlit && isVoid(e, true))
            {
                e = null;
            }
            else
            {
                e = scrubReturnValue(loc, e);
                if (CTFEExp.isCantExp(e) || e.op == EXP.error)
                    return e;
            }
        }
        return null;
    }

    Expression scrubSE(StructLiteralExp sle)
    {
        sle.ownedByCtfe = OwnedBy.code;
        if (!(sle.stageflags & StructLiteralExp.StageFlags.scrub))
        {
            const old = sle.stageflags;
            sle.stageflags |= StructLiteralExp.StageFlags.scrub; // prevent infinite recursion
            if (auto ex = scrubArray(sle.elements, true))
                return ex;
            sle.stageflags = old;
        }
        return null;
    }

    if (e.op == EXP.classReference)
    {
        StructLiteralExp sle = e.isClassReferenceExp().value;
        if (auto ex = scrubSE(sle))
            return ex;
    }
    else if (auto vie = e.isVoidInitExp())
    {
        eSink.error(loc, "uninitialized variable `%s` cannot be returned from CTFE", vie.var.toErrMsg());
        return ErrorExp.get();
    }

    e = resolveSlice(e);

    if (auto sle = e.isStructLiteralExp())
    {
        if (auto ex = scrubSE(sle))
            return ex;
    }
    else if (auto se = e.isStringExp())
    {
        se.ownedByCtfe = OwnedBy.code;
    }
    else if (auto ale = e.isArrayLiteralExp())
    {
        ale.ownedByCtfe = OwnedBy.code;
        if (auto ex = scrubArray(ale.elements))
            return ex;
    }
    else if (auto aae = e.isAssocArrayLiteralExp())
    {
        aae.ownedByCtfe = OwnedBy.code;
        if (auto ex = scrubArray(aae.keys))
            return ex;
        if (auto ex = scrubArray(aae.values))
            return ex;
        aae.type = toBuiltinAAType(aae.type);
    }
    else if (auto ve = e.isVectorExp())
    {
        ve.ownedByCtfe = OwnedBy.code;
        if (auto ale = ve.e1.isArrayLiteralExp())
        {
            ale.ownedByCtfe = OwnedBy.code;
            if (auto ex = scrubArray(ale.elements))
                return ex;
        }
    }
    return e;
}

/**************************************
 * Transitively set all .ownedByCtfe to OwnedBy.cache
 */
private Expression scrubCacheValue(Expression e)
{
    if (!e)
        return e;

    Expression scrubArrayCache(Expressions* elems)
    {
        foreach (ref e; *elems)
            e = scrubCacheValue(e);
        return null;
    }

    Expression scrubSE(StructLiteralExp sle)
    {
        sle.ownedByCtfe = OwnedBy.cache;
        if (!(sle.stageflags & StructLiteralExp.StageFlags.scrub))
        {
            const old = sle.stageflags;
            sle.stageflags |= StructLiteralExp.StageFlags.scrub;  // prevent infinite recursion
            if (auto ex = scrubArrayCache(sle.elements))
                return ex;
            sle.stageflags = old;
        }
        return null;
    }

    if (e.op == EXP.classReference)
    {
        if (auto ex = scrubSE(e.isClassReferenceExp().value))
            return ex;
    }
    else if (auto sle = e.isStructLiteralExp())
    {
        if (auto ex = scrubSE(sle))
            return ex;
    }
    else if (auto se = e.isStringExp())
    {
        se.ownedByCtfe = OwnedBy.cache;
    }
    else if (auto ale = e.isArrayLiteralExp())
    {
        ale.ownedByCtfe = OwnedBy.cache;
        if (Expression ex = scrubArrayCache(ale.elements))
            return ex;
    }
    else if (auto aae = e.isAssocArrayLiteralExp())
    {
        aae.ownedByCtfe = OwnedBy.cache;
        if (auto ex = scrubArrayCache(aae.keys))
            return ex;
        if (auto ex = scrubArrayCache(aae.values))
            return ex;
    }
    else if (auto ve = e.isVectorExp())
    {
        ve.ownedByCtfe = OwnedBy.cache;
        if (auto ale = ve.e1.isArrayLiteralExp())
        {
            ale.ownedByCtfe = OwnedBy.cache;
            if (auto ex = scrubArrayCache(ale.elements))
                return ex;
        }
    }
    return e;
}

/********************************************
 * Transitively replace all Expressions allocated in ctfeGlobals.region
 * with Mem owned copies.
 * Params:
 *      e = possible ctfeGlobals.region owned expression
 * Returns:
 *      Mem owned expression
 */
private Expression copyRegionExp(Expression e)
{
    if (!e)
        return e;

    static void copyArray(Expressions* elems)
    {
        foreach (ref e; *elems)
        {
            auto ex = e;
            e = null;
            e = copyRegionExp(ex);
        }
    }

    static void copySE(StructLiteralExp sle)
    {
        if (1 || !(sle.stageflags & StructLiteralExp.StageFlags.scrub))
        {
            const old = sle.stageflags;
            sle.stageflags |= StructLiteralExp.StageFlags.scrub; // prevent infinite recursion
            copyArray(sle.elements);
            sle.stageflags = old;
        }
    }

    switch (e.op)
    {
        case EXP.classReference:
        {
            auto cre = e.isClassReferenceExp();
            cre.value = copyRegionExp(cre.value).isStructLiteralExp();
            break;
        }

        case EXP.structLiteral:
        {
            auto sle = e.isStructLiteralExp();

            /* The following is to take care of updating sle.origin correctly,
             * which may have multiple objects pointing to it.
             */
            if (sle.isOriginal && !ctfeGlobals.region.contains(cast(void*)sle.origin))
            {
                /* This means sle has already been moved out of the region,
                 * and sle.origin is the new location.
                 */
                return sle.origin;
            }
            // Track whether copySE triggers a recursive copy of this
            // same SLE via a self-reference. If so, sle.origin will
            // have been updated to a GC copy, and we must use that
            // instead of creating a duplicate.
            auto savedOrigin = sle.origin;
            copySE(sle);

            sle.isOriginal = sle is sle.origin;

            if (sle.origin != savedOrigin)
                return sle.origin;

            auto slec = ctfeGlobals.region.contains(cast(void*)e)
                ? e.copy().isStructLiteralExp()         // move sle out of region to slec
                : sle;

            if (ctfeGlobals.region.contains(cast(void*)sle.origin))
            {
                auto sleo = sle.origin == sle ? slec : sle.origin.copy().isStructLiteralExp();
                sle.origin = sleo;
                slec.origin = sleo;
            }
            return slec;
        }

        case EXP.arrayLiteral:
        {
            auto ale = e.isArrayLiteralExp();
            ale.basis = copyRegionExp(ale.basis);
            copyArray(ale.elements);
            break;
        }

        case EXP.assocArrayLiteral:
            copyArray(e.isAssocArrayLiteralExp().keys);
            copyArray(e.isAssocArrayLiteralExp().values);
            break;

        case EXP.slice:
        {
            auto se = e.isSliceExp();
            se.e1  = copyRegionExp(se.e1);
            se.upr = copyRegionExp(se.upr);
            se.lwr = copyRegionExp(se.lwr);
            break;
        }

        case EXP.tuple:
        {
            auto te = e.isTupleExp();
            te.e0 = copyRegionExp(te.e0);
            copyArray(te.exps);
            break;
        }

        case EXP.address:
        case EXP.delegate_:
        case EXP.vector:
        case EXP.dotVariable:
        {
            UnaExp ue = e.isUnaExp();
            ue.e1 = copyRegionExp(ue.e1);
            break;
        }

        case EXP.index:
        {
            BinExp be = e.isBinExp();
            be.e1 = copyRegionExp(be.e1);
            be.e2 = copyRegionExp(be.e2);
            break;
        }

        case EXP.this_:
        case EXP.super_:
        case EXP.variable:
        case EXP.type:
        case EXP.function_:
        case EXP.typeid_:
        case EXP.string_:
        case EXP.int64:
        case EXP.error:
        case EXP.float64:
        case EXP.complex80:
        case EXP.null_:
        case EXP.void_:
        case EXP.symbolOffset:
            break;

        case EXP.cantExpression:
        case EXP.voidExpression:
        case EXP.showCtfeContext:
            return e;

        default:
            printf("e: %s, %s\n", EXPtoString(e.op).ptr, e.toChars());
            assert(0);
    }

    if (ctfeGlobals.region.contains(cast(void*)e))
    {
        return e.copy();
    }
    return e;
}

/******************************* Special Functions ***************************/

private Expression interpret_length(UnionExp* pue, InterState* istate, Expression earg)
{
    //printf("interpret_length()\n");
    earg = interpret(pue, earg, istate);
    if (exceptionOrCantInterpret(earg))
        return earg;
    dinteger_t len = 0;
    if (auto aae = earg.isAssocArrayLiteralExp())
        len = aae.keys.length;
    else
        assert(earg.op == EXP.null_);
    emplaceExp!(IntegerExp)(pue, earg.loc, len, Type.tsize_t);
    return pue.exp();
}

private Expression interpret_keys(UnionExp* pue, InterState* istate, Expression earg, Type returnType)
{
    debug (LOG)
    {
        printf("interpret_keys()\n");
    }
    earg = interpret(pue, earg, istate);
    if (exceptionOrCantInterpret(earg))
        return earg;
    if (earg.op == EXP.null_)
    {
        emplaceExp!(NullExp)(pue, earg.loc, returnType);
        return pue.exp();
    }
    if (earg.op != EXP.assocArrayLiteral && earg.type.toBasetype().ty != Taarray)
        return null;
    AssocArrayLiteralExp aae = earg.isAssocArrayLiteralExp();
    auto ae = ctfeEmplaceExp!ArrayLiteralExp(aae.loc, returnType, aae.keys);
    ae.ownedByCtfe = aae.ownedByCtfe;
    *pue = copyLiteral(ae);
    return pue.exp();
}

private Expression interpret_values(UnionExp* pue, InterState* istate, Expression earg, Type returnType)
{
    debug (LOG)
    {
        printf("interpret_values()\n");
    }
    earg = interpret(pue, earg, istate);
    if (exceptionOrCantInterpret(earg))
        return earg;
    if (earg.op == EXP.null_)
    {
        emplaceExp!(NullExp)(pue, earg.loc, returnType);
        return pue.exp();
    }
    if (earg.op != EXP.assocArrayLiteral && earg.type.toBasetype().ty != Taarray)
        return null;
    auto aae = earg.isAssocArrayLiteralExp();
    auto ae = ctfeEmplaceExp!ArrayLiteralExp(aae.loc, returnType, aae.values);
    ae.ownedByCtfe = aae.ownedByCtfe;
    //printf("result is %s\n", e.toChars());
    *pue = copyLiteral(ae);
    return pue.exp();
}

// signature is bool _d_aaDel(V[K] aa, K key)
private Expression interpret_aaDel(UnionExp* pue, InterState* istate, Expression aa, Expression key)
{
    Expression agg = interpret(aa, istate);
    if (exceptionOrCantInterpret(agg))
        return agg;
    Expression index = interpret(key, istate);
    if (exceptionOrCantInterpret(index))
        return index;
    if (agg.op == EXP.null_)
        return CTFEExp.voidexp; //???

    AssocArrayLiteralExp aae = agg.isAssocArrayLiteralExp();
    Expressions* keysx = aae.keys;
    Expressions* valuesx = aae.values;
    uint removed = 0;
    foreach (j, evalue; *valuesx)
    {
        Expression ekey = (*keysx)[j];
        int eq = ctfeEqual(aa.loc, EXP.equal, ekey, index);
        if (eq)
            ++removed;
        else if (removed != 0)
        {
            (*keysx)[j - removed] = ekey;
            (*valuesx)[j - removed] = evalue;
        }
    }
    valuesx.length = valuesx.length - removed;
    keysx.length = keysx.length - removed;
    return IntegerExp.createBool(removed != 0);
}

// signature is bool _d_aaDel(V[K] aa1, V[K] aa2)
private Expression interpret_aaEqual(UnionExp* pue, InterState* istate, Expression aa1, Expression aa2)
{
    Expression e1 = interpret(aa1, istate);
    if (exceptionOrCantInterpret(e1))
        return e1;
    Expression e2 = interpret(aa2, istate);
    if (exceptionOrCantInterpret(e2))
        return e2;

    bool equal = ctfeEqual(aa1.loc, EXP.equal, e1, e2);
    return IntegerExp.createBool(equal);
}

private Expression interpret_dup(UnionExp* pue, InterState* istate, Expression earg)
{
    debug (LOG)
    {
        printf("interpret_dup()\n");
    }
    earg = interpret(pue, earg, istate);
    if (exceptionOrCantInterpret(earg))
        return earg;
    if (earg.op == EXP.null_)
    {
        emplaceExp!(NullExp)(pue, earg.loc, earg.type);
        return pue.exp();
    }
    if (earg.op != EXP.assocArrayLiteral && earg.type.toBasetype().ty != Taarray)
        return null;
    auto aae = copyLiteral(earg).copy().isAssocArrayLiteralExp();
    for (size_t i = 0; i < aae.keys.length; i++)
    {
        if (Expression e = evaluatePostblit(istate, (*aae.keys)[i]))
            return e;
        if (Expression e = evaluatePostblit(istate, (*aae.values)[i]))
            return e;
    }
    // repaint type from const(int[int]) to int[int]
    if (auto taa = earg.type.toBasetype().isTypeAArray())
    {
        auto aatype = new TypeAArray(taa.next.mutableOf(), taa.index);
        aae.type = aatype.merge();
    }
    else
        aae.type = earg.type.mutableOf();
    //printf("result is %s\n", aae.toChars());
    return aae;
}

// signature is bool V* _d_aaIn(V[K] aa, K key)
private Expression interpret_aaIn(UnionExp* pue, InterState* istate, Expression aa, Expression key)
{
    debug (LOG)
    {
        printf("%s _d_aaIn::interpret() %s in %s\n", aa.loc.toChars(), key.toChars(), aa.toChars());
    }
    Expression eaa = interpretRegion(aa, istate);
    if (exceptionOrCantInterpret(eaa))
        return eaa;
    Expression ekey = interpretRegion(key, istate);
    if (exceptionOrCantInterpret(ekey))
        return ekey;

    if (eaa.op != EXP.null_)
    {
        auto aalit = eaa.isAssocArrayLiteralExp();
        if (!aalit)
        {
            auto eSink = global.errorSink;
            eSink.error(aa.loc, "`%s` cannot be interpreted at compile time", aa.toErrMsg());
            return CTFEExp.cantexp;
        }

        size_t idx;
        auto result = findKeyInAA(aa.loc, aalit, ekey, &idx);
        if (exceptionOrCantInterpret(result))
            return result;
        if (result)
            return pointerToAAValue(pue, aa, aalit, idx);
    }
    emplaceExp!(NullExp)(pue, aa.loc, aa.type.nextOf().pointerTo());
    return pue.exp();
}

// signature is V* _d_aaGetRvalueX(V[K] aa, K key)
private Expression interpret_aaGetRvalueX(UnionExp* pue, InterState* istate, Expression aa, Expression key)
{
    Expression e1 = interpret(aa, istate);
    if (exceptionOrCantInterpret(e1))
        return e1;
    Expression e2 = interpretRegion(key, istate);
    if (exceptionOrCantInterpret(e2))
        return e2;

    auto eSink = global.errorSink;
    auto aalit = e1.isAssocArrayLiteralExp();
    if (!aalit)
    {
        eSink.error(aa.loc, "cannot index null array `%s`", aa.toErrMsg());
        return CTFEExp.cantexp;
    }
    size_t idx;
    Expression result = findKeyInAA(aa.loc, aalit, e2, &idx);
    if (!result)
    {
        eSink.error(aa.loc, "key `%s` not found in associative array `%s`", key.toErrMsg(), aa.toErrMsg());
        return  CTFEExp.cantexp;
    }

    return pointerToAAValue(pue, aa, aalit, idx);
}

// signature is V* _d_aaGetY(ref V[K] aa, K key, out bool found)
private Expression interpret_aaGetY(UnionExp* pue, InterState* istate, Expression aa, Expression key, Expression found)
{
    Expression eaa = interpretRegion(aa, istate, CTFEGoal.LValue);
    if (exceptionOrCantInterpret(eaa))
        return eaa;
    Expression ekey = interpretRegion(key, istate);
    if (exceptionOrCantInterpret(ekey))
        return ekey;
    Expression efound = interpretRegion(found, istate, CTFEGoal.LValue);
    if (exceptionOrCantInterpret(efound))
        return efound;

    auto ie = ctfeEmplaceExp!IndexExp(aa.loc, aa, key); // any BinExp for location in assignToLvalue
    Expression evalaa = interpretRegion(eaa, istate);
    auto aalit = evalaa.isAssocArrayLiteralExp();
    if (!aalit)
    {
        auto keysx = new Expressions();
        auto valuesx = new Expressions();
        aalit = ctfeEmplaceExp!AssocArrayLiteralExp(aa.loc, keysx, valuesx);
        aalit.type = aa.type;
        aalit.ownedByCtfe = OwnedBy.ctfe;
        Interpreter.assignToLvalue(ie, eaa, aalit, istate);
    }
    size_t idx;
    auto result = findKeyInAA(aa.loc, aalit, ekey, &idx);
    if (found)
        Interpreter.assignToLvalue(ie, efound, IntegerExp.createBool(result !is null), istate);
    if (!result)
    {
        aalit.keys.push(ekey);
        result = copyLiteral(aa.type.nextOf().defaultInitLiteral(aa.loc)).copy();
        idx = aalit.values.length;
        aalit.values.push(result);
    }
    return pointerToAAValue(pue, aa, aalit, idx);
}

private Expression pointerToAAValue(UnionExp* pue, Expression aa, AssocArrayLiteralExp aalit, size_t idx)
{
    auto arr = ctfeEmplaceExp!(ArrayLiteralExp)(aa.loc, aa.type.nextOf().arrayOf(), aalit.values);
    arr.ownedByCtfe = aalit.ownedByCtfe;
    arr.aaLiteral = aalit;
    auto len = ctfeEmplaceExp!(IntegerExp)(aa.loc, idx, Type.tsize_t);
    auto idxexp = ctfeEmplaceExp!(IndexExp)(aa.loc, arr, len);
    idxexp.type = arr.type.nextOf();
    emplaceExp!(AddrExp)(pue, aa.loc, idxexp);
    pue.exp().type = idxexp.type.pointerTo();
    return pue.exp();
}

// signature is int delegate(ref Value) OR int delegate(ref Key, ref Value)
private Expression interpret_aaApply(UnionExp* pue, InterState* istate, Expression aa, Expression deleg)
{
    aa = interpret(aa, istate);
    if (exceptionOrCantInterpret(aa))
        return aa;
    if (aa.op != EXP.assocArrayLiteral)
    {
        emplaceExp!(IntegerExp)(pue, deleg.loc, 0, Type.tsize_t);
        return pue.exp();
    }

    FuncDeclaration fd = null;
    Expression pthis = null;
    if (auto de = deleg.isDelegateExp())
    {
        fd = de.func;
        pthis = de.e1;
    }
    else if (auto fe = deleg.isFuncExp())
        fd = fe.fd;

    assert(fd && fd.fbody);
    assert(fd.parameters);
    size_t numParams = fd.parameters.length;
    assert(numParams == 1 || numParams == 2);

    Parameter fparam = fd.type.isTypeFunction().parameterList[numParams - 1];
    const wantRefValue = fparam.isReference();

    Expressions args = Expressions(numParams);

    AssocArrayLiteralExp ae = aa.isAssocArrayLiteralExp();
    if (!ae.keys || ae.keys.length == 0)
        return ctfeEmplaceExp!IntegerExp(deleg.loc, 0, Type.tsize_t);
    Expression eresult;

    for (size_t i = 0; i < ae.keys.length; ++i)
    {
        Expression ekey = (*ae.keys)[i];
        Expression evalue = (*ae.values)[i];
        if (wantRefValue)
        {
            Type t = evalue.type;
            auto arr = ctfeEmplaceExp!(ArrayLiteralExp)(aa.loc, t.arrayOf(), ae.values);
            arr.ownedByCtfe = ae.ownedByCtfe;
            auto idx = ctfeEmplaceExp!(IntegerExp)(aa.loc, i, Type.tsize_t);
            evalue = ctfeEmplaceExp!(IndexExp)(aa.loc, arr, idx);
            evalue.type = t;
        }
        args[numParams - 1] = evalue;
        if (numParams == 2)
            args[0] = ekey;

        UnionExp ue = void;
        eresult = interpretFunction(&ue, fd, istate, &args, pthis);
        if (eresult == ue.exp())
            eresult = ue.copy();
        if (exceptionOrCantInterpret(eresult))
            return eresult;

        if (eresult.isIntegerExp().getInteger() != 0)
            return eresult;
    }
    return eresult;
}

/// Returns: equivalent `StringExp` from `ArrayLiteralExp ale` containing only `IntegerExp` elements
StringExp arrayLiteralToString(ArrayLiteralExp ale)
{
    const len = ale.length;
    const size = ale.type.nextOf().size();

    StringExp impl(T)()
    {
        T[] result = new T[len];
        foreach (i; 0 .. len)
        {
            auto el = ale[i];
            result[i] = cast(T) el.isIntegerExp().getInteger();
        }
        return new StringExp(ale.loc, result[], len, cast(ubyte) size);
    }

    switch (size)
    {
        case 1:
            return impl!char();
        case 2:
            return impl!wchar();
        case 4:
            return impl!dchar();
        default:
            assert(0);
    }
}

/* Decoding UTF strings for foreach loops. Duplicates the functionality of
 * the twelve _aApplyXXn functions in aApply.d in the runtime.
 */
private Expression foreachApplyUtf(UnionExp* pue, InterState* istate, Expression str, Expression deleg, bool rvs)
{
    debug (LOG)
    {
        printf("foreachApplyUtf(%s, %s)\n", str.toChars(), deleg.toChars());
    }
    FuncDeclaration fd = null;
    Expression pthis = null;
    if (auto de = deleg.isDelegateExp())
    {
        fd = de.func;
        pthis = de.e1;
    }
    else if (auto fe = deleg.isFuncExp())
        fd = fe.fd;

    assert(fd && fd.fbody);
    assert(fd.parameters);
    size_t numParams = fd.parameters.length;
    assert(numParams == 1 || numParams == 2);
    Type charType = (*fd.parameters)[numParams - 1].type;
    Type indexType = numParams == 2 ? (*fd.parameters)[0].type : Type.tsize_t;
    size_t len = cast(size_t)resolveArrayLength(str);
    if (len == 0)
    {
        emplaceExp!(IntegerExp)(pue, deleg.loc, 0, indexType);
        return pue.exp();
    }

    UnionExp strTmp = void;
    str = resolveSlice(str, &strTmp);

    auto se = str.isStringExp();
    if (auto ale = str.isArrayLiteralExp())
        se = arrayLiteralToString(ale);

    auto eSink = global.errorSink;

    if (!se)
    {
        eSink.error(str.loc, "CTFE internal error: cannot foreach `%s`", str.toErrMsg());
        return CTFEExp.cantexp;
    }
    Expressions args = Expressions(numParams);

    Expression eresult = null; // ded-store to prevent spurious warning

    // Buffers for encoding
    char[4] utf8buf = void;
    wchar[2] utf16buf = void;

    size_t start = rvs ? len : 0;
    size_t end = rvs ? 0 : len;
    for (size_t indx = start; indx != end;)
    {
        // Step 1: Decode the next dchar from the string.

        string errmsg = null; // Used for reporting decoding errors
        dchar rawvalue; // Holds the decoded dchar
        size_t currentIndex = indx; // The index of the decoded character

        // String literals
        size_t saveindx; // used for reverse iteration

        switch (se.sz)
        {
            case 1:
            {
                if (rvs)
                {
                    // find the start of the string
                    --indx;
                    while (indx > 0 && ((se.getCodeUnit(indx) & 0xC0) == 0x80))
                        --indx;
                    saveindx = indx;
                }
                auto slice = se.peekString();
                errmsg = utf_decodeChar(slice, indx, rawvalue);
                if (rvs)
                    indx = saveindx;
                break;
            }

            case 2:
                if (rvs)
                {
                    // find the start
                    --indx;
                    auto wc = se.getCodeUnit(indx);
                    if (wc >= 0xDC00 && wc <= 0xDFFF)
                        --indx;
                    saveindx = indx;
                }
                const slice = se.peekWstring();
                errmsg = utf_decodeWchar(slice, indx, rawvalue);
                if (rvs)
                    indx = saveindx;
                break;

            case 4:
                if (rvs)
                    --indx;
                rawvalue = se.getCodeUnit(indx);
                if (!rvs)
                    ++indx;
                break;

            default:
                assert(0);
        }

        if (errmsg)
        {
            eSink.error(deleg.loc, "`%.*s`", cast(int)errmsg.length, errmsg.ptr);
            return CTFEExp.cantexp;
        }

        // Step 2: encode the dchar in the target encoding

        int charlen = 1; // How many codepoints are involved?
        switch (charType.size())
        {
        case 1:
            charlen = utf_codeLengthChar(rawvalue);
            utf_encodeChar(&utf8buf[0], rawvalue);
            break;
        case 2:
            charlen = utf_codeLengthWchar(rawvalue);
            utf_encodeWchar(&utf16buf[0], rawvalue);
            break;
        case 4:
            break;
        default:
            assert(0);
        }
        if (rvs)
            currentIndex = indx;

        // Step 3: call the delegate once for each code point

        // The index only needs to be set once
        if (numParams == 2)
            args[0] = ctfeEmplaceExp!IntegerExp(deleg.loc, currentIndex, indexType);

        Expression val = null;

        foreach (k; 0 .. charlen)
        {
            dchar codepoint;
            switch (charType.size())
            {
            case 1:
                codepoint = utf8buf[k];
                break;
            case 2:
                codepoint = utf16buf[k];
                break;
            case 4:
                codepoint = rawvalue;
                break;
            default:
                assert(0);
            }
            val = ctfeEmplaceExp!IntegerExp(str.loc, codepoint, charType);

            args[numParams - 1] = val;

            UnionExp ue = void;
            eresult = interpretFunction(&ue, fd, istate, &args, pthis);
            if (eresult == ue.exp())
                eresult = ue.copy();
            if (exceptionOrCantInterpret(eresult))
                return eresult;
            if (eresult.isIntegerExp().getInteger() != 0)
                return eresult;
        }
    }
    return eresult;
}

/* If this is a built-in function, return the interpreted result,
 * Otherwise, return NULL.
 */
private Expression evaluateIfBuiltin(UnionExp* pue, InterState* istate, Loc loc, FuncDeclaration fd, Expressions* arguments, Expression pthis)
{
    Expression e = null;
    size_t nargs = arguments ? arguments.length : 0;
    if (!pthis)
    {
        if (isBuiltin(fd) != BUILTIN.unimp)
        {
            Expressions args = Expressions(nargs);
            foreach (i, ref arg; args)
            {
                Expression earg = (*arguments)[i];
                earg = interpret(earg, istate);
                if (exceptionOrCantInterpret(earg))
                    return earg;
                arg = earg;
            }
            e = eval_builtin(loc, fd, &args);
            if (!e)
            {
                auto eSink = global.errorSink;
                eSink.error(loc, "cannot evaluate unimplemented builtin `%s` at compile time", fd.toErrMsg());
                e = CTFEExp.cantexp;
            }
        }
    }
    if (!pthis)
    {
        if (nargs >= 1 && nargs <= 3)
        {
            Expression firstarg = (*arguments)[0];
            if (auto firstAAtype = firstarg.type.toBasetype().isTypeAArray())
            {
                const id = fd.ident;
                if (nargs == 1)
                {
                    if (id == Id._d_aaLen)
                        return interpret_length(pue, istate, firstarg);

                    if (fd.toParent2().ident == Id.object)
                    {
                        if (id == Id.keys)
                            return interpret_keys(pue, istate, firstarg, firstAAtype.index.arrayOf());
                        if (id == Id.values)
                            return interpret_values(pue, istate, firstarg, firstAAtype.nextOf().arrayOf());
                        if (id == Id.rehash)
                            return interpret(pue, firstarg, istate);
                        if (id == Id.dup)
                            return interpret_dup(pue, istate, firstarg);
                    }
                }
                else if (nargs == 2)
                {
                    if (id == Id._d_aaGetRvalueX)
                        return interpret_aaGetRvalueX(pue, istate, firstarg, (*arguments)[1]);
                    if (id == Id._d_aaIn)
                        return interpret_aaIn(pue, istate, firstarg, (*arguments)[1]);
                    if (id == Id._d_aaDel)
                        return interpret_aaDel(pue, istate, firstarg, (*arguments)[1]);
                    if (id == Id._d_aaEqual)
                        return interpret_aaEqual(pue, istate, firstarg, (*arguments)[1]);
                    if (id == Id._d_aaApply)
                        return interpret_aaApply(pue, istate, firstarg, (*arguments)[1]);
                    if (id == Id._d_aaApply2)
                        return interpret_aaApply(pue, istate, firstarg, (*arguments)[1]);
                }
                else // (nargs == 3)
                {
                    if (id == Id._d_aaGetY)
                        return interpret_aaGetY(pue, istate, firstarg, (*arguments)[1], (*arguments)[2]);
                }
            }
        }
    }
    if (pthis && !fd.fbody && fd.isCtorDeclaration() && fd.parent && fd.parent.parent && fd.parent.parent.ident == Id.object)
    {
        if (pthis.op == EXP.classReference && fd.parent.ident == Id.Throwable)
        {
            // At present, the constructors just copy their arguments into the struct.
            // But we might need some magic if stack tracing gets added to druntime.
            StructLiteralExp se = pthis.isClassReferenceExp().value;
            assert(arguments.length <= se.elements.length);
            foreach (i, arg; *arguments)
            {
                auto elem = interpret(arg, istate);
                if (exceptionOrCantInterpret(elem))
                    return elem;
                (*se.elements)[i] = elem;
            }
            return CTFEExp.voidexp;
        }
    }
    if (nargs == 1 && !pthis && (fd.ident == Id.criticalenter || fd.ident == Id.criticalexit))
    {
        // Support synchronized{} as a no-op
        return CTFEExp.voidexp;
    }
    if (!pthis)
    {
        const idlen = fd.ident.toString().length;
        const id = fd.ident.toChars();
        if (nargs == 2 && (idlen == 10 || idlen == 11) && !strncmp(id, "_aApply", 7))
        {
            // Functions from aApply.d and aApplyR.d in the runtime
            bool rvs = (idlen == 11); // true if foreach_reverse
            char c = id[idlen - 3]; // char width: 'c', 'w', or 'd'
            char s = id[idlen - 2]; // string width: 'c', 'w', or 'd'
            char n = id[idlen - 1]; // numParams: 1 or 2.
            // There are 12 combinations
            if ((n == '1' || n == '2') &&
                (c == 'c' || c == 'w' || c == 'd') &&
                (s == 'c' || s == 'w' || s == 'd') &&
                c != s)
            {
                Expression str = (*arguments)[0];
                str = interpret(str, istate);
                if (exceptionOrCantInterpret(str))
                    return str;
                return foreachApplyUtf(pue, istate, str, (*arguments)[1], rvs);
            }
        }
    }
    return e;
}

private Expression evaluatePostblit(InterState* istate, Expression e)
{
    auto ts = e.type.baseElemOf().isTypeStruct();
    if (!ts)
        return null;
    StructDeclaration sd = ts.sym;
    if (!sd.postblit)
        return null;

    if (auto ale = e.isArrayLiteralExp())
    {
        foreach (elem; *ale.elements)
        {
            if (!elem) continue;
            if (auto ex = evaluatePostblit(istate, elem))
                return ex;
        }
        return null;
    }
    if (e.op == EXP.structLiteral)
    {
        // e.__postblit()
        UnionExp ue = void;
        e = interpretFunction(&ue, sd.postblit, istate, null, e);
        if (e == ue.exp())
            e = ue.copy();
        if (exceptionOrCantInterpret(e))
            return e;
        return null;
    }
    assert(0);
}

private Expression evaluateDtor(InterState* istate, Expression e)
{
    auto ts = e.type.baseElemOf().isTypeStruct();
    if (!ts)
        return null;
    StructDeclaration sd = ts.sym;
    if (!sd.dtor)
        return null;

    UnionExp ue = void;
    if (auto ale = e.isArrayLiteralExp())
    {
        foreach_reverse (elem; *ale.elements)
        {
            if (!elem) continue;
            e = evaluateDtor(istate, elem);
        }
    }
    else if (e.op == EXP.structLiteral)
    {
        // e.__dtor()
        e = interpretFunction(&ue, sd.dtor, istate, null, e);
    }
    else
        assert(0);
    if (exceptionOrCantInterpret(e))
    {
        if (e == ue.exp())
            e = ue.copy();
        return e;
    }
    return null;
}

/*************************** CTFE Sanity Checks ***************************/
/* Setter functions for CTFE variable values.
 * These functions exist to check for compiler CTFE bugs.
 */
private bool hasValue(VarDeclaration vd)
{
    if (vd.ctfeAdrOnStack == VarDeclaration.AdrOnStackNone)
        return false;
    // Check for a linear-memory value first so no AST node gets materialized
    if (ctfeGlobals.stack.hasLinearValue(vd))
        return true;
    return getValue(vd) !is null;
}

// Don't check for validity
private void setValueWithoutChecking(VarDeclaration vd, Expression newval)
{
    ctfeGlobals.stack.setValue(vd, newval);
}

private void setValue(VarDeclaration vd, Expression newval)
{
    //printf("setValue() vd: %s newval: %s\n", vd.toChars(), newval.toChars());
    version (none)
    {
        if (!((vd.storage_class & (STC.out_ | STC.ref_)) ? isCtfeReferenceValid(newval) : isCtfeValueValid(newval)))
        {
            printf("[%s] vd = %s %s, newval = %s\n", vd.loc.toChars(), vd.type.toChars(), vd.toChars(), newval.toChars());
        }
    }
    assert((vd.storage_class & (STC.out_ | STC.ref_)) ? isCtfeReferenceValid(newval) : isCtfeValueValid(newval));
    ctfeGlobals.stack.setValue(vd, newval);
}

/**
 * Removes `_d_HookTraceImpl` if found from `ce` and `fd`.
 * This is needed for the CTFE interception code to be able to find hooks that are called though the hook's `*Trace`
 * wrapper.
 *
 * This is done by replacing `_d_HookTraceImpl!(T, Hook, errMsg)(..., parameters)` with `Hook(parameters)`.
 * Parameters:
 *  ce = The CallExp that possible will be be replaced
 *  fd = Fully resolve function declaration that `ce` would call
 */
private void removeHookTraceImpl(ref CallExp ce, ref FuncDeclaration fd)
{
    if (fd.ident != Id._d_HookTraceImpl)
        return;

    auto oldCE = ce;

    // Get the Hook from the second template parameter
    TemplateInstance templateInstance = fd.parent.isTemplateInstance;
    RootObject hook = (*templateInstance.tiargs)[1];
    assert(hook.isDsymbol(), "Expected _d_HookTraceImpl's second template parameter to be an alias to the hook!");
    fd = (cast(Dsymbol)hook).isFuncDeclaration;

    // Remove the last three trace parameters
    auto arguments = new Expressions();
    arguments.reserve(ce.arguments.length - 3);
    arguments.pushSlice((*ce.arguments)[0 .. $ - 3]);

    ce = ctfeEmplaceExp!CallExp(ce.loc, ctfeEmplaceExp!VarExp(ce.loc, fd, false), arguments);

    if (global.params.v.verbose)
    {
        auto eSink = global.errorSink;
        eSink.message(Loc.initial, "strip     %s =>\n          %s", oldCE.toChars(), ce.toChars());
    }
}
