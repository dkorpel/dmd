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

// Per-block metadata computed during analysis
private struct BlkInfo
{
    bool isLoopHeader; // targeted by a back edge
    int loopEnd; // for loop headers: index of the block that closes the loop
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

// Emit a returning/terminating block (retexp/ret/exit).
// Returns false if b is not one of those.
private bool emitBlockReturn(ref WasmCG cg, block* b, bool hasReturn)
{
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
        cg.reachable = false;
        return true;
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
        cg.reachable = false;
        return true;
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
        cg.reachable = false;
        return true;
    }
    return false;
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
        if (b.bc == BC.goto_ || b.bc == BC.iftrue || b.bc == BC.ifthen
            || b.bc == BC.jmptab || b.bc == BC.switch_)
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

    // A wasm loop frame may extend past its last back edge, so overlapping
    // loop regions (irreducible goto flow) can be made to nest by extending
    // the earlier loop's end over the later one.
    {
        bool changed = true;
        while (changed)
        {
            changed = false;
            foreach (int h1; 0 .. N)
            {
                if (!info[h1].isLoopHeader)
                    continue;
                foreach (int h2; h1 + 1 .. N)
                    if (info[h2].isLoopHeader && h2 <= info[h1].loopEnd
                        && info[h2].loopEnd > info[h1].loopEnd)
                    {
                        info[h1].loopEnd = info[h2].loopEnd;
                        changed = true;
                    }
            }
        }
    }

    // Every forward branch target gets one block frame: OP_BLOCK before block
    // `begin`, OP_END after block `end` (= target-1), so a br to it lands on
    // the target. Collecting them all up front lets frames open in reverse
    // target order, which per-branch lazy opening can't do when several
    // targets are pending at once (e.g. an if-chain).
    struct BFrame
    {
        int begin;
        int end;
    }

    BFrame[] bframes;

    void needFrame(int source, int target)
    {
        foreach (ref f; bframes)
            if (f.end == target - 1)
            {
                if (source < f.begin)
                    f.begin = source;
                return;
            }
        bframes ~= BFrame(source, target - 1);
    }

    foreach (int i; 0 .. N)
    {
        block* b = blocks[i];
        if (b.bc == BC.goto_ || b.bc == BC.iftrue || b.bc == BC.ifthen)
        {
            foreach (int si; 0 .. cast(int) b.Bsucc.length)
            {
                const int t = blockIdx(b.Bsucc[si]);
                if (t != int.max && t > i + 1)
                    needFrame(i, t);
            }
        }
        else if (b.bc == BC.jmptab || b.bc == BC.switch_)
        {
            // br_table can't fall through, so even target i+1 needs a frame
            foreach (int si; 0 .. cast(int) b.Bsucc.length)
            {
                const int t = blockIdx(b.Bsucc[si]);
                if (t != int.max && t > i)
                    needFrame(i, t);
            }
        }
    }
    // Every loop gets an exit wrapper so branches past its end have a frame
    foreach (int h; 0 .. N)
        if (info[h].isLoopHeader)
            needFrame(h, info[h].loopEnd + 1);

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

    // Frames must nest (LIFO), so widen begins until the set is laminar.
    // Loops are fixed [header, loopEnd] frames the block frames must respect.
    bool converged;
    {
        int iterations = 0;
        bool changed = true;
        while (changed && iterations <= cast(int) bframes.length * N + 2)
        {
            changed = false;
            iterations++;
            foreach (ref f; bframes)
            {
                foreach (int h; 0 .. N)
                {
                    if (!info[h].isLoopHeader)
                        continue;
                    const int le = info[h].loopEnd;
                    if (f.begin > h && f.begin <= le && f.end > le)
                    {
                        f.begin = h; // exits the loop: enclose it
                        changed = true;
                    }
                    else if (f.begin < h && f.end >= h && f.end < le)
                    {
                        // Branch into a loop body from outside (multi-entry
                        // loop): unstructurable. Keep the frame for in-loop
                        // sources; the validation below sees the outside
                        // sources are uncovered and picks the dispatch-loop
                        // fallback for the whole function.
                        f.begin = h;
                        changed = true;
                    }
                }
                foreach (ref const g; bframes)
                    if (g.begin < f.begin && f.begin <= g.end && g.end < f.end)
                    {
                        f.begin = g.begin; // crosses g: enclose it
                        changed = true;
                    }
            }
        }
        converged = !changed;
    }

    // Validate that every branch has a frame or loop to br to. Irreducible
    // control flow (goto into a loop body, `goto case` to an earlier case,
    // optimizer-produced layouts) fails this and uses the dispatch fallback.
    bool structurable = converged;
    if (structurable)
    {
        bool branchOK(int i, int t)
        {
            if (t == int.max)
                return true;
            if (t <= i) // back edge: must continue a loop from inside it
                return info[t].isLoopHeader && info[t].loopEnd >= i;
            foreach (ref const f; bframes)
                if (f.end == t - 1)
                    return f.begin <= i;
            return true; // fallthrough needs no frame
        }

        outer: foreach (int i; 0 .. N)
        {
            block* b = blocks[i];
            const bool branches = b.bc == BC.goto_ || b.bc == BC.iftrue
                || b.bc == BC.ifthen || b.bc == BC.jmptab || b.bc == BC.switch_;
            if (!branches)
                continue;
            foreach (int si; 0 .. cast(int) b.Bsucc.length)
            {
                const int t = blockIdx(b.Bsucc[si]);
                if (t == i + 1 && b.bc != BC.jmptab && b.bc != BC.switch_)
                    continue;
                if (!branchOK(i, t))
                {
                    structurable = false;
                    break outer;
                }
            }
        }
    }

    if (!structurable)
    {
        genBlocksDispatch(cg, blocks, hasReturn);
        return;
    }

    // WASM_BLOCKS=1: dump the repaired frames
    {
        import core.stdc.stdlib : getenv;
        import core.stdc.stdio : printf;
        if (getenv("WASM_BLOCKS"))
            foreach (ref const f; bframes)
                printf("  frame [%d..%d] -> %d\n", f.begin, f.end, f.end + 1);
    }

    // Nesting stack of open block/loop frames; frames must close in LIFO order.
    struct Frame
    {
        bool isLoop;
        int closeAfter; // OP_END is emitted after this block index
        int loopStart = -1; // for loops: the header block index
        bool parentReachable; // reachability at the point this frame was opened
    }

    Frame[] stack;

    // br depth to reach a given stack frame (0 = innermost)
    uint brDepth(size_t frameIdx)
    {
        return cast(uint)(stack.length - 1 - frameIdx);
    }

    // Find the stack frame for the loop whose header is at idx.
    // These lookups return stack.length as a not-found sentinel.
    size_t loopFrame(int headerIdx)
    {
        foreach_reverse (size_t fi, ref const Frame f; stack)
            if (f.isLoop && f.loopStart == headerIdx)
                return fi;
        return stack.length;
    }

    // Block frame closing exactly where targetIdx begins, so a br to it
    // lands on targetIdx. The pre-pass opened one per forward branch target.
    size_t exactFrame(int targetIdx)
    {
        foreach_reverse (size_t fi, ref const Frame f; stack)
            if (!f.isLoop && f.closeAfter == targetIdx - 1)
                return fi;
        return stack.length;
    }

    void openBlock(int closeAfter)
    {
        stack ~= Frame(false, closeAfter, -1, cg.reachable);
        cg.emit(OP_BLOCK);
        cg.emit(WASM_VOID_BLOCK);
    }

    // Open the pre-computed frames beginning at `pos` whose end lies in
    // (loEnd, hiEnd], outermost (largest end) first
    void openFramesAt(int pos, int loEnd, int hiEnd)
    {
        while (true)
        {
            int best = loEnd;
            foreach (ref const f; bframes)
                if (f.begin == pos && f.end > best && f.end <= hiEnd)
                    best = f.end;
            if (best == loEnd)
                return;
            openBlock(best);
            hiEnd = best - 1;
        }
    }

    // Branch to the frame at `fi`. A missing frame (fi == stack.length
    // sentinel) means the CFG couldn't be structured — a dropped branch
    // would silently corrupt control flow, so fail loudly instead.
    void branchTo(size_t fi, bool conditional)
    {
        assert(fi < stack.length, "wasm blocks: branch target has no frame");
        cg.emit(conditional ? OP_BR_IF : OP_BR);
        cg.emitULEB(brDepth(fi));
        if (!conditional)
            cg.reachable = false;
    }

    int currentIdx;

    // Branch to block `t`: continue its loop if backward, exit a block
    // frame if forward
    void branchToBlock(int t, bool conditional)
    {
        branchTo(t <= currentIdx ? loopFrame(t) : exactFrame(t), conditional);
    }

    foreach (const bi; 0 .. N)
    {
        block* b = blocks[bi];
        currentIdx = bi;

        // Push the condition value of b, or 0 if there is none
        void emitCondValue()
        {
            if (b.Belem)
                cg.genElem(b.Belem);
            else
                cg.emitConst(OP_I32_CONST, 0);
        }

        // Close frames ending before this block. Per WASM validation, control
        // past an OP_END resumes at the reachability the enclosing frame had
        // when it was opened — regardless of whether the body fell through.
        while (stack.length > 0 && stack[$ - 1].closeAfter < bi)
        {
            const Frame f = stack[$ - 1];
            cg.emit(OP_END);
            stack = stack[0 .. $ - 1];
            cg.reachable = f.parentReachable;
        }

        // Open frames beginning here. At a loop header, frames ending at or
        // after the loop end enclose the loop, the rest open inside it.
        if (info[bi].isLoopHeader)
        {
            const int loopEnd = info[bi].loopEnd;
            openFramesAt(bi, loopEnd - 1, int.max);
            stack ~= Frame(true, loopEnd, bi, cg.reachable);
            cg.emit(OP_LOOP);
            cg.emit(WASM_VOID_BLOCK);
            openFramesAt(bi, -1, loopEnd - 1);
        }
        else
            openFramesAt(bi, -1, int.max);

        if (emitBlockReturn(cg, b, hasReturn))
            continue;

        if (b.bc == BC.jmptab || b.bc == BC.switch_)
        {
            uint destDepth(int destIdx)
            {
                const size_t fi = destIdx <= cast(int) bi
                    ? loopFrame(destIdx) : exactFrame(destIdx);
                assert(fi < stack.length, "wasm blocks: branch target has no frame");
                return brDepth(fi);
            }

            const int defaultIdx = blockIdx(b.Bsucc[0]);

            cg.genElem(b.Belem);

            if (b.Bswitch.length == 0)
            {
                cg.emit(OP_DROP);
                if (defaultIdx != cast(int) bi + 1)
                    branchTo(exactFrame(defaultIdx), false);
                continue;
            }

            long vmin = long.max;
            long vmax = long.min;
            foreach (v; b.Bswitch)
            {
                if (v < vmin)
                    vmin = v;
                if (v > vmax)
                    vmax = v;
            }

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
                    cg.emitULEB(destDepth(caseIdx));
                }
                if (defaultIdx != cast(int) bi + 1)
                {
                    cg.emit(OP_BR);
                    cg.emitULEB(destDepth(defaultIdx));
                    cg.reachable = false;
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
                cg.emitULEB(destDepth(destIdx));
            }
            cg.emitULEB(destDepth(defaultIdx)); // default label
            cg.reachable = false; // br_table is unconditional
            continue;
        }
        else if (b.bc == BC.ifthen || b.bc == BC.iftrue)
        {
            const int takenIdx = blockIdx(succ(b, 0));
            const int nottakenIdx = blockIdx(succ(b, 1));

            emitCondValue();
            if (takenIdx == nottakenIdx)
            {
                // Degenerate: both arms go to the same block
                emitCondToI32(cg, b.Belem);
                cg.emit(OP_DROP);
                if (takenIdx != cast(int) bi + 1)
                    branchToBlock(takenIdx, false);
            }
            else if (takenIdx == cast(int) bi + 1)
            {
                emitCondInvert(cg, b.Belem);
                branchToBlock(nottakenIdx, true);
            }
            else if (nottakenIdx == cast(int) bi + 1)
            {
                emitCondToI32(cg, b.Belem);
                branchToBlock(takenIdx, true);
            }
            else
            {
                // Neither target is the next block (e.g. `if (c) break;
                // continue;` in a switch case, or a loop back edge whose
                // exit skips blocks)
                emitCondToI32(cg, b.Belem);
                branchToBlock(takenIdx, true);
                branchToBlock(nottakenIdx, false);
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

            const int targetIdx = blockIdx(target);
            if (targetIdx != bi + 1) // == bi+1 falls through naturally
                branchToBlock(targetIdx, false);
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
        const Frame f = stack[$ - 1];
        cg.emit(OP_END);
        stack = stack[0 .. $ - 1];
        cg.reachable = f.parentReachable;
    }
}

// Fallback for irreducible control flow the structurer can't nest: a selector
// local drives a br_table inside a loop, with one wrapper block per basic
// block. Every branch becomes "set selector, br to the loop". Slower code,
// but handles any CFG.
private void genBlocksDispatch(ref WasmCG cg, block*[] blocks, bool hasReturn)
{
    import core.stdc.stdlib : getenv;
    import core.stdc.stdio : printf;
    if (getenv("WASM_BLOCKS"))
        printf("  (dispatch fallback)\n");

    const int N = cast(int) blocks.length;
    const uint sel = cg.allocTemp(WASM_I32);
    cg.emitConst(OP_I32_CONST, 0);
    cg.emitLocal(OP_LOCAL_SET, sel);

    cg.emit(OP_LOOP);
    cg.emit(WASM_VOID_BLOCK);
    foreach (int i; 0 .. N)
    {
        cg.emit(OP_BLOCK);
        cg.emit(WASM_VOID_BLOCK);
    }
    // The innermost wrapper is block 0's: br depth i lands on block i's body
    cg.emitLocal(OP_LOCAL_GET, sel);
    cg.emit(OP_BR_TABLE);
    cg.emitULEB(cast(uint) N);
    foreach (int i; 0 .. N)
        cg.emitULEB(cast(uint) i);
    cg.emitULEB(0); // default; sel is always a valid block index

    foreach (int i; 0 .. N)
    {
        cg.emit(OP_END); // close wrapper i; block i's body follows
        block* b = blocks[i];

        // Inside body i the open frames are wrappers i+1 .. N-1, then the loop
        const uint loopDepth = cast(uint)(N - 1 - i);

        void gotoBlock(int t, uint extraDepth)
        {
            cg.emitConst(OP_I32_CONST, t);
            cg.emitLocal(OP_LOCAL_SET, sel);
            cg.emit(OP_BR);
            cg.emitULEB(loopDepth + extraDepth);
        }

        if (emitBlockReturn(cg, b, hasReturn))
            continue;

        if (b.bc == BC.iftrue || b.bc == BC.ifthen)
        {
            // sel = cond ? taken : nottaken
            cg.emitConst(OP_I32_CONST, blockIdx(succ(b, 0)));
            cg.emitConst(OP_I32_CONST, blockIdx(succ(b, 1)));
            if (b.Belem)
                cg.genElem(b.Belem);
            else
                cg.emitConst(OP_I32_CONST, 0);
            emitCondToI32(cg, b.Belem);
            cg.emit(OP_SELECT);
            cg.emitLocal(OP_LOCAL_SET, sel);
            cg.emit(OP_BR);
            cg.emitULEB(loopDepth);
        }
        else if (b.bc == BC.jmptab || b.bc == BC.switch_)
        {
            const int defaultIdx = blockIdx(b.Bsucc[0]);
            cg.genElem(b.Belem);
            if (b.Bswitch.length == 0)
            {
                cg.emit(OP_DROP);
                gotoBlock(defaultIdx, 0);
                continue;
            }
            // Compare chain against each case value
            const condType = b.Belem.wasmType;
            const uint condLocal = cg.allocTemp(condType);
            cg.emit(OP_LOCAL_SET);
            cg.emitULEB(condLocal);
            foreach (size_t ci, long cv; b.Bswitch)
            {
                cg.emitLocal(OP_LOCAL_GET, condLocal);
                if (condType == WASM_I64)
                {
                    cg.emitConst(OP_I64_CONST, cv);
                    cg.emit(OP_I64_EQ);
                }
                else
                {
                    cg.emitConst(OP_I32_CONST, cast(int) cv);
                    cg.emit(OP_I32_EQ);
                }
                cg.emit(OP_IF);
                cg.emit(WASM_VOID_BLOCK);
                gotoBlock(blockIdx(b.Bsucc[cast(int)(ci + 1)]), 1);
                cg.emit(OP_END);
            }
            gotoBlock(defaultIdx, 0);
        }
        else if (b.bc == BC.goto_)
        {
            if (b.Belem)
            {
                const bool v = cg.genElem(b.Belem);
                if (v)
                    cg.emit(OP_DROP);
            }
            if (block* target = succ(b, 0))
                gotoBlock(blockIdx(target), 0);
        }
        else
        {
            if (b.Belem)
            {
                const bool hasVal = cg.genElem(b.Belem);
                if (hasVal)
                    cg.emit(OP_DROP);
            }
            if (i + 1 < N)
                gotoBlock(i + 1, 0);
        }
    }

    cg.emit(OP_END); // close the dispatch loop
    // Control never falls out of the loop, but the validator doesn't know
    cg.emit(OP_UNREACHABLE);
    cg.reachable = false;
}
