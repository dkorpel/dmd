module dmd.backend.wasm.blocks;

import dmd.backend.cc;
import dmd.backend.cdef;
import dmd.backend.el;
import dmd.backend.oper;
import dmd.backend.ty;
import dmd.backend.type;
import dmd.backend.symbol : globsym;
import dmd.backend.wasm.enums;
import dmd.backend.wasm.codgen;

nothrow:

alias _compare_fp_t = extern(C) nothrow int function(const void*, const void*);
extern(C) void qsort(void* base, size_t nmemb, size_t size, _compare_fp_t compar);

private extern(C) int cmpInt(scope const void* p1, scope const void* p2)
{
    return *cast(const(int)*)p1 - *cast(const(int)*)p2;
}

// Per-block metadata computed during analysis
private struct BlkInfo
{
    int idx; // sequential index (0-based)
    bool isLoopHeader; // targeted by a back edge
    int loopEnd; // for loop headers: index of the block that closes the loop
    int[] jmptabDests; // for BC.jmptab: unique sorted destination block indices
}

private int blockIdx(block* b)
{
    return b ? b.Bdfoidx : int.max;
}

// Successor index in Bsucc list
private block* succ(block* b, int n)
{
    if (n < b.Bsucc.length)
        return b.Bsucc[n];
    return null;
}

/// Structured control flow synthesis (block CFG => WASM)
void genBlocksProper(ref WasmCG cg, block* startblock, bool hasReturn)
{
    static block*[] collectBlocks(block* start)
    {
        block*[] v;
        for (block* b = start; b; b = b.Bnext)
            v ~= b;
        return v;
    }

    block*[] blocks = collectBlocks(startblock);
    const int N = cast(int) blocks.length;
    if (N == 0)
        return;

    // Assign sequential indices
    foreach (size_t i, b; blocks)
        b.Bdfoidx = cast(int) i;

    // A back edge B => A (A.idx <= B.idx) makes A a loop header.
    BlkInfo[] info = new BlkInfo[N];
    foreach (size_t i, b; blocks)
    {
        info[i].idx = cast(int) i;
        if (b.bc == BC.goto_ || b.bc == BC.iftrue)
        {
            foreach (int si; 0 .. cast(int) b.Bsucc.length)
            {
                block* s = b.Bsucc[si];
                if (s && s.Bdfoidx <= cast(int) i) // back edge
                {
                    info[s.Bdfoidx].isLoopHeader = true;
                    if (info[s.Bdfoidx].loopEnd < cast(int) i)
                        info[s.Bdfoidx].loopEnd = cast(int) i;
                }
            }
        }
    }

    // Nesting stack of open block/loop frames; frames must close in LIFO order.
    struct Frame
    {
        bool isLoop;
        int closeAfter; // OP_END is emitted after this block index
    }

    // WASM_BLOCKS=1: dump the block graph for debugging structuring bugs
    {
        import core.stdc.stdlib : getenv;
        import core.stdc.stdio : printf;
        if (getenv("WASM_BLOCKS"))
        {
            printf("=== block graph (%d blocks) ===\n", N);
            foreach (size_t i, b; blocks)
            {
                printf("  b%d bc=%d succ=[", cast(int) i, cast(int) b.bc);
                foreach (int si; 0 .. cast(int) b.Bsucc.length)
                    printf("%s%d", si ? ",".ptr : "".ptr, blockIdx(b.Bsucc[si]));
                printf("]\n");
            }
        }
    }

    Frame[] stack;

    // br depth to reach a given stack frame (0 = innermost)
    uint brDepth(size_t frameIdx)
    {
        return cast(uint)(stack.length - 1 - frameIdx);
    }

    // Find the stack frame for a loop whose header is at idx.
    // These lookups return stack.length as a not-found sentinel.
    size_t loopFrame(int headerIdx)
    {
        foreach_reverse (size_t fi, ref const Frame f; stack)
            if (f.isLoop && f.closeAfter >= headerIdx)
                return fi;
        return stack.length;
    }

    // Innermost block frame that covers a forward branch target
    size_t blockFrame(int targetIdx)
    {
        foreach_reverse (size_t fi, ref const Frame f; stack)
            if (!f.isLoop && f.closeAfter >= targetIdx - 1)
                return fi;
        return stack.length;
    }

    // Innermost block frame closing exactly where targetIdx begins,
    // so a br to it lands on targetIdx
    size_t exactFrame(int targetIdx)
    {
        foreach_reverse (size_t fi, ref const Frame f; stack)
            if (!f.isLoop && f.closeAfter == targetIdx - 1)
                return fi;
        return stack.length;
    }

    void openBlock(int closeAfter)
    {
        stack ~= Frame(false, closeAfter);
        cg.emit(OP_BLOCK);
        cg.emit(WASM_VOID_BLOCK);
    }

    // Branch to the frame at `fi`. A missing frame (fi == stack.length
    // sentinel) means the CFG couldn't be structured — a dropped branch
    // would silently corrupt control flow, so fail loudly instead.
    void branchTo(size_t fi, bool conditional)
    {
        assert(fi < stack.length, "wasm blocks: branch target has no frame");
        cg.emit(conditional ? OP_BR_IF : OP_BR);
        cg.emitULEB(brDepth(fi));
    }

    foreach (const bi; 0 .. N)
    {
        block* b = blocks[bi];

        // Push the condition value of b, or 0 if there is none
        void emitCondValue()
        {
            if (b.Belem)
                cg.genElem(b.Belem);
            else
                cg.emitConst(OP_I32_CONST, 0);
        }

        // Close frames ending before this block
        while (stack.length > 0 && stack[$ - 1].closeAfter < bi)
        {
            cg.emit(OP_END);
            stack = stack[0 .. $ - 1];
        }

        // Open wrapper blocks for BC.jmptab (switch via br_table).
        // Must happen before loop-header frames so depths are computed correctly.
        if (b.bc == BC.jmptab || b.bc == BC.switch_)
        {
            // Unique destination block indices.
            // Bsucc[0] = default; Bsucc[1..n] = cases in Bswitch order.
            int[] dests;
            bool addDest(int idx)
            {
                foreach (d; dests)
                    if (d == idx)
                        return false;
                dests ~= idx;
                return true;
            }
            foreach (int si; 0 .. cast(int) b.Bsucc.length)
                addDest(blockIdx(b.Bsucc[si]));

            // Case bodies also branch forward past the case starts: `break`
            // jumps to the block after the switch, and local if/else merges
            // land between cases. Each such target needs a wrapper closing
            // exactly at it, capped at the enclosing frame's close point so
            // wrappers stay nested (a break out of an enclosing loop is a
            // farther target a wrapper can't legally cover).
            if (dests.length)
            {
                const int maxTarget = stack.length ? stack[$ - 1].closeAfter + 1 : N;
                int maxDest = 0;
                foreach (d; dests)
                    if (d != int.max && d > maxDest)
                        maxDest = d;
                for (int ti = cast(int) bi + 1; ti < maxDest && ti < N; ti++)
                {
                    block* tb = blocks[ti];
                    if (tb.bc != BC.goto_ && tb.bc != BC.iftrue)
                        continue;
                    foreach (int si; 0 .. cast(int) tb.Bsucc.length)
                    {
                        const int midx = blockIdx(tb.Bsucc[si]);
                        if (midx == int.max || midx <= cast(int) bi || midx > maxTarget)
                            continue;
                        if (addDest(midx) && midx > maxDest)
                            maxDest = midx;
                    }
                }
            }
            qsort(dests.ptr, dests.length, int.sizeof, &cmpInt);

            // One wrapper per dest, outermost (highest idx) first
            foreach_reverse (int destIdx; dests)
                openBlock(destIdx - 1);
            info[bi].jmptabDests = dests;
        }

        // Loop header: `block` for the exit target + `loop` for the back edge
        if (info[bi].isLoopHeader)
        {
            const int loopEnd = info[bi].loopEnd;
            openBlock(loopEnd);
            stack ~= Frame(true, loopEnd);
            cg.emit(OP_LOOP);
            cg.emit(WASM_VOID_BLOCK);
        }

        if (b.bc == BC.retexp)
        {
            bool hasRetVal;
            if (b.Belem)
                hasRetVal = cg.genElem(b.Belem);
            if (cg.hasShadowFrame)
            {
                if (hasRetVal)
                {
                    // Save the return value across the epilogue. Use the
                    // function-level retByHiddenPtr flag because TYdarray/
                    // TYdelegate alias TYullong/TYllong on wasm32, so Ety
                    // can't tell a slice return from a plain long.
                    const tym_t bty = tybasic(b.Belem.Ety);
                    WASM_TYPE retTy = cg.retByHiddenPtr ? WASM_I32 : wasmType(bty);
                    uint retTmp = cg.allocTemp(retTy);
                    cg.emit(OP_LOCAL_SET);
                    cg.emitULEB(retTmp);
                    emitShadowEpilogue(cg);
                    cg.emitLocal(OP_LOCAL_GET, retTmp);
                }
                else
                {
                    emitShadowEpilogue(cg);
                }
            }
            cg.emit(OP_RETURN);
            continue;
        }
        else if (b.bc == BC.ret)
        {
            if (b.Belem)
            {
                const bool v = cg.genElem(b.Belem);
                if (v)
                    cg.emit(OP_DROP);
            }
            if (cg.hasShadowFrame)
                emitShadowEpilogue(cg);
            // A value-returning function may still end in BC.ret (e.g. a call
            // to a noreturn function like __switch_error); `unreachable` gives
            // the validator a polymorphic stack.
            if (hasReturn)
                cg.emit(OP_UNREACHABLE);
            cg.emit(OP_RETURN);
            continue;
        }
        else if (b.bc == BC.exit)
        {
            if (b.Belem)
            {
                const bool v = cg.genElem(b.Belem);
                if (v)
                    cg.emit(OP_DROP);
            }
            cg.emit(OP_UNREACHABLE);
            continue;
        }
        else if (b.bc == BC.jmptab || b.bc == BC.switch_)
        {
            // Wrapper blocks already opened above.
            int[] dests = info[bi].jmptabDests;

            cg.genElem(b.Belem);

            long vmin = long.max;
            long vmax = long.min;
            foreach (v; b.Bswitch)
            {
                if (v < vmin)
                    vmin = v;
                if (v > vmax)
                    vmax = v;
            }
            if (b.Bswitch.length == 0)
            {
                cg.emit(OP_DROP);
                continue;
            }

            // dests[i] is the (i)th innermost wrapper
            uint depthOf(int destIdx)
            {
                foreach (size_t di, int d; dests)
                    if (d == destIdx)
                        return cast(uint) di;
                return cast(uint)(dests.length - 1); // fallback: default
            }

            int defaultIdx = blockIdx(b.Bsucc[0]);
            uint defaultDepth = depthOf(defaultIdx);

            enum maxJumpTableSize = 1024;

            const condType = b.Belem.wasmType;
            // Span computed as unsigned: case values may straddle the full
            // long range. br_table needs an i32 index and a dense table.
            const ulong span = cast(ulong) vmax - cast(ulong) vmin;
            const bool useBrTable = condType == WASM_I32
                && span < maxJumpTableSize
                && span < b.Bswitch.length * 4UL + 4;

            if (!useBrTable)
            {
                // If-else chain: store condition in a local, compare each case
                uint condLocal = cg.allocTemp(condType);
                cg.emit(OP_LOCAL_SET);
                cg.emitULEB(condLocal);
                foreach (size_t ci, long cv; b.Bswitch)
                {
                    int caseIdx = blockIdx(b.Bsucc[cast(int)(ci + 1)]);
                    cg.emitLocal(OP_LOCAL_GET, condLocal);
                    if (condType == WASM_I64)
                    {
                        cg.emitConst(OP_I64_CONST, cv);
                        cg.emit(OP_I64_EQ);
                    }
                    else if (condType == WASM_I32)
                    {
                        cg.emitConst(OP_I32_CONST, cast(int) cv);
                        cg.emit(OP_I32_EQ);
                    }
                    cg.emit(OP_BR_IF);
                    cg.emitULEB(depthOf(caseIdx));
                }
                if (defaultDepth > 0)
                {
                    cg.emit(OP_BR);
                    cg.emitULEB(defaultDepth);
                }
                continue;
            }

            // Dense i32 range: br_table with a 0-based index
            if (vmin != 0)
            {
                cg.emitConst(OP_I32_CONST, cast(int)-vmin);
                cg.emit(OP_I32_ADD);
            }

            const size_t tableLen = cast(size_t)(span + 1);
            cg.emit(OP_BR_TABLE);
            cg.emitULEB(cast(uint) tableLen);
            foreach (long v; vmin .. vmax + 1)
            {
                int destIdx = defaultIdx;
                foreach (size_t ci, long cv; b.Bswitch)
                    if (cv == v)
                    {
                        destIdx = blockIdx(b.Bsucc[cast(int)(ci + 1)]);
                        break;
                    }
                cg.emitULEB(depthOf(destIdx));
            }
            cg.emitULEB(defaultDepth); // default label
            continue;
        }
        else if (b.bc == BC.ifthen || b.bc == BC.iftrue)
        {
            block* taken = succ(b, 0);
            block* nottaken = succ(b, 1);
            int takenIdx = blockIdx(taken);
            int nottakenIdx = blockIdx(nottaken);

            size_t outerLoop = stack.length;
            foreach_reverse (size_t fi, ref const Frame f; stack)
                if (f.isLoop)
                {
                    outerLoop = fi;
                    break;
                }
            int exitBlockIdx = (outerLoop < stack.length) ? stack[outerLoop - 1].closeAfter + 1 : -1;

            if (takenIdx <= cast(int) bi)
            {
                // Back edge: condition true => loop continue
                emitCondValue();
                emitCondToI32(cg, b.Belem);
                branchTo(loopFrame(takenIdx), true);
                // false => exit loop
                if (nottakenIdx > info[takenIdx].loopEnd)
                    branchTo(blockFrame(nottakenIdx), false);
            }
            else if (nottakenIdx <= cast(int) bi)
            {
                // Back edge: condition false => loop continue
                emitCondValue();
                emitCondInvert(cg, b.Belem);
                branchTo(loopFrame(nottakenIdx), true);
            }
            else if (outerLoop < stack.length &&
                (nottakenIdx == exitBlockIdx || takenIdx == exitBlockIdx))
            {
                // Loop exit condition
                emitCondValue();
                if (nottakenIdx == exitBlockIdx)
                    emitCondInvert(cg, b.Belem); // false => exit
                else
                    emitCondToI32(cg, b.Belem); // true => exit
                cg.emit(OP_BR_IF);
                cg.emitULEB(brDepth(outerLoop - 1));
            }
            else if (takenIdx == cast(int) bi + 1 || nottakenIdx == cast(int) bi + 1)
            {
                // Pure forward if/else: one arm inline at bi+1, the other at
                // skipIdx. The inline arm's last block may jump past skipIdx
                // to a merge point.
                const bool inlineIsTaken = takenIdx == cast(int) bi + 1;
                const int skipIdx = inlineIsTaken ? nottakenIdx : takenIdx;

                int mergeIdx = -1;
                if (skipIdx - 1 > cast(int) bi && skipIdx - 1 < N)
                {
                    block* last = blocks[skipIdx - 1];
                    if (last.bc == BC.goto_ && last.Bsucc.length > 0)
                    {
                        const int midx = blockIdx(last.Bsucc[0]);
                        if (midx != int.max && midx > skipIdx)
                            mergeIdx = midx;
                    }
                    else if (last.bc == BC.retexp || last.bc == BC.ret
                        || last.bc == BC.exit)
                    {
                        // Arm ends in a return, but blocks inside it (e.g. an
                        // inner if) may still branch forward past skipIdx;
                        // cover the farthest such target.
                        foreach (int ti; cast(int) bi + 1 .. skipIdx)
                            foreach (int si; 0 .. cast(int) blocks[ti].Bsucc.length)
                            {
                                const int midx = blockIdx(blocks[ti].Bsucc[si]);
                                if (midx != int.max && midx > skipIdx && midx > mergeIdx)
                                    mergeIdx = midx;
                            }
                    }
                }
                // The merge frame must nest inside enclosing frames
                if (mergeIdx >= 0 && stack.length &&
                    mergeIdx - 1 > stack[$ - 1].closeAfter)
                    mergeIdx = stack[$ - 1].closeAfter + 1;
                if (mergeIdx >= 0 && exactFrame(mergeIdx) >= stack.length)
                    openBlock(mergeIdx - 1);

                size_t skipFrame = exactFrame(skipIdx);
                if (skipFrame >= stack.length)
                {
                    openBlock(skipIdx - 1);
                    skipFrame = stack.length - 1;
                }
                emitCondValue();
                if (inlineIsTaken)
                    emitCondInvert(cg, b.Belem);
                else
                    emitCondToI32(cg, b.Belem);
                branchTo(skipFrame, true);
            }
            else
            {
                // Both targets non-immediate (e.g. `if (c) break; continue;`
                // in a switch case): branch through frames closing exactly
                // where each target begins.
                emitCondValue();
                emitCondToI32(cg, b.Belem);
                branchTo(exactFrame(takenIdx), true);
                branchTo(exactFrame(nottakenIdx), false);
            }
            continue;
        }
        else if (b.bc == BC.goto_)
        {
            block* target = succ(b, 0);
            if (b.Belem)
            {
                const bool v = cg.genElem(b.Belem);
                if (v)
                    cg.emit(OP_DROP);
            }
            if (!target)
                continue;

            int targetIdx = blockIdx(target);
            if (targetIdx <= bi)
            {
                // Back edge => loop continue
                branchTo(loopFrame(targetIdx), false);
            }
            else if (targetIdx > bi + 1)
            {
                // Forward goto that skips blocks: br out of the covering frame
                const size_t fi = blockFrame(targetIdx);
                if (fi < stack.length)
                {
                    branchTo(fi, false);
                }
                else
                {
                    // A jump into a loop body past its header (multi-entry
                    // loop; blockopt creates these from unreachable code
                    // after an infinite loop) can't be structured without
                    // node splitting. Trap rather than fall through.
                    bool entersLoop = false;
                    foreach (int h; cast(int) bi + 1 .. targetIdx)
                        if (info[h].isLoopHeader && info[h].loopEnd >= targetIdx)
                            entersLoop = true;
                    assert(entersLoop, "wasm blocks: branch target has no frame");
                    cg.emit(OP_UNREACHABLE);
                }
            }
            // targetIdx == bi+1: fall through naturally
            continue;
        }

        // Default: emit expression, discard result
        if (b.Belem)
        {
            const bool hasVal = cg.genElem(b.Belem);
            if (hasVal)
                cg.emit(OP_DROP);
        }
    }

    while (stack.length > 0)
    {
        cg.emit(OP_END);
        stack = stack[0 .. $ - 1];
    }
}
