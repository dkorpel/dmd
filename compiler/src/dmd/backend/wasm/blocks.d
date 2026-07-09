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
        if (cg.framePublished)
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
            cg.genElemDiscard(b.Belem);
        if (cg.framePublished)
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
    else if (b.bc == BC.exit || b.bc == BC._ret)
    {
        // BC._ret survives only in EH_WASM functions: after
        // insertFinallyBlockCalls it is reached exclusively through the
        // rethrow/flag-dispatch chain, so falling off its end is impossible.
        if (b.Belem)
            cg.genElemDiscard(b.Belem);
        cg.emit(OP_UNREACHABLE);
        cg.reachable = false;
        return true;
    }
    return false;
}

// Reorder `blocks` so the try_table frame model can structure them: each
// BC._try header is directly followed by the blocks it guards (those whose
// Btry chain reaches it) and then by its landing-pad group (BC.jcatch, or
// BC._finally + BC._lpad). Within each nesting level, blocks are emitted in
// reverse post order from the level's entry, so acyclic forward flow (catch
// dispatch, handlers, join points) never becomes an index-space back edge
// that the loop detection would mistake for a loop — blockopt (-O) and the
// inliner produce layouts where that would otherwise happen. Blocks the pass
// cannot attribute are appended at the end, where the validation below
// downgrades the function to dispatch emission.
private block*[] layoutTryRegions(block*[] blocks)
{
    foreach (size_t i, b; blocks)
        b.Bdfoidx = cast(uint) i;
    LayoutState st;
    st.blocks = blocks;
    st.placed = new bool[blocks.length];
    st.visited = new bool[blocks.length];
    st.result.reserve(blocks.length);
    st.layoutLevel(null, blocks[0]);
    foreach (b; blocks)
        if (!st.placed[b.Bdfoidx])
            st.result ~= b;
    return st.result;
}

private struct LayoutState
{
    block*[] blocks;
    bool[] placed;
    bool[] visited;
    block*[] result;

nothrow:

    static bool isPad(const block* b)
    {
        return b.bc == BC.jcatch || b.bc == BC._finally || b.bc == BC._lpad;
    }

    // Map `b` to its representative at `owner`'s nesting level: itself if
    // directly owned, the ancestor BC._try header whose region contains it
    // if nested deeper, or null if outside `owner` entirely.
    static block* levelNode(block* b, block* owner)
    {
        block* prev = b;
        for (block* t = b.Btry; ; prev = t, t = t.Btry)
        {
            if (t is owner)
                return prev;
            if (t is null)
                return null;
        }
    }

    // Emit the blocks of `owner`'s nesting level reachable from `entry` in
    // reverse post order. Nested try regions collapse into their header
    // node; landing pads ride along with their header in placeOne.
    void layoutLevel(block* owner, block* entry)
    {
        block*[] post;

        void dfs(block* node) nothrow
        {
            if (visited[node.Bdfoidx])
                return;
            visited[node.Bdfoidx] = true;

            void visitSucc(block* s)
            {
                if (!s)
                    return;
                block* ln = levelNode(s, owner);
                if (!ln || isPad(ln) || placed[ln.Bdfoidx] || visited[ln.Bdfoidx])
                    return;
                dfs(ln);
            }

            if (node.bc == BC._try && node.Bsucc.length > 1)
            {
                // Collapsed region node: its level successors are the
                // region's exits plus the landing pad's continuations.
                foreach (m; blocks)
                    if (m !is node && levelNode(m, node) !is null)
                        foreach (s; m.Bsucc)
                            visitSucc(s);
                block* h = node.Bsucc[1];
                if (h && h.bc == BC.jcatch)
                {
                    foreach (s; h.Bsucc)
                        visitSucc(s);
                }
                else if (h && h.bc == BC._finally)
                {
                    foreach (s; h.Bsucc)
                        visitSucc(s);
                    if (h.Bsucc.length && h.Bsucc[0].bc == BC._lpad)
                        foreach (s; h.Bsucc[0].Bsucc)
                            visitSucc(s);
                }
            }
            else
            {
                foreach (s; node.Bsucc)
                    visitSucc(s);
            }
            post ~= node;
        }

        block* e = entry ? levelNode(entry, owner) : null;
        if (!e || isPad(e) || placed[e.Bdfoidx] || visited[e.Bdfoidx])
            return;
        dfs(e);
        foreach_reverse (n; post)
            placeOne(n);
    }

    void placeOne(block* b)
    {
        if (placed[b.Bdfoidx])
            return;
        placed[b.Bdfoidx] = true;
        result ~= b;
        if (b.bc != BC._try || b.Bsucc.length < 2)
            return;
        layoutLevel(b, b.Bsucc[0]);
        block* h = b.Bsucc[1];
        if (h && !placed[h.Bdfoidx] && h.bc == BC.jcatch)
        {
            placed[h.Bdfoidx] = true;
            result ~= h;
        }
        else if (h && !placed[h.Bdfoidx] && h.bc == BC._finally)
        {
            placed[h.Bdfoidx] = true;
            result ~= h;
            block* lp = h.Bsucc.length ? h.Bsucc[0] : null;
            if (lp && lp.bc == BC._lpad && !placed[lp.Bdfoidx])
            {
                placed[lp.Bdfoidx] = true;
                result ~= lp;
            }
        }
    }
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

    // Blockopt (-O) merges and reorders blocks, so a try body is not
    // necessarily laid out contiguously between its BC._try header and its
    // landing pad. The try_table frame model requires exactly that layout;
    // rebuild it from Btry ownership, which blockopt preserves.
    foreach (b; blocks)
        if (b.bc == BC._try)
        {
            blocks = layoutTryRegions(blocks);
            break;
        }

    // Assign sequential indices
    foreach (size_t i, b; blocks)
        b.Bdfoidx = cast(int) i;

    // A back edge B => A (A.idx <= B.idx) makes A a loop header.
    BlkInfo[] info = new BlkInfo[N];
    foreach (size_t i, b; blocks)
    {
        if (b.bc == BC.goto_ || b.bc == BC.iftrue || b.bc == BC.ifthen
            || b.bc == BC.jmptab || b.bc == BC.switch_
            || b.bc == BC._finally || b.bc == BC._lpad || b.bc == BC.jcatch)
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

    // EH_WASM try regions: each BC._try opens a try_table frame over
    // [start, end] whose catch clause lands on the block at end+1 (the
    // BC.jcatch pad of a try/catch, or the BC._lpad of a try/finally).
    // Fixed regions like loops — block frames must nest around them.
    struct TryReg
    {
        int start; // BC._try block index
        int end; // last block inside the try_table (= land - 1)
        bool isCatch; // catch (i32 payload) vs catch_all_ref (exnref)
        block* tryBlock;
    }

    TryReg[] tryRegs;
    bool tryBroken = false;
    foreach (int i; 0 .. N)
    {
        block* b = blocks[i];
        if (b.bc != BC._try)
            continue;
        int land = int.max;
        bool isCatch;
        block* h = b.Bsucc.length > 1 ? b.Bsucc[1] : null;
        if (h && h.bc == BC.jcatch)
        {
            land = blockIdx(h);
            isCatch = true;
        }
        else if (h && h.bc == BC._finally && h.Bsucc.length
            && h.Bsucc[0].bc == BC._lpad)
        {
            land = blockIdx(h.Bsucc[0]);
        }
        if (land == int.max || land <= i)
        {
            tryBroken = true;
            break;
        }
        tryRegs ~= TryReg(i, land - 1, isCatch, b);
    }

    // Try regions must be laminar with each other and with loops.
    if (!tryBroken)
    {
        static bool overlapPartially(int a1, int a2, int b1, int b2)
        {
            return a1 <= b2 && b1 <= a2
                && !(a1 <= b1 && b2 <= a2) && !(b1 <= a1 && a2 <= b2);
        }

        outerTry: foreach (size_t ti, ref const TryReg t; tryRegs)
        {
            foreach (ref const TryReg u; tryRegs[ti + 1 .. $])
                if (overlapPartially(t.start, t.end, u.start, u.end))
                {
                    tryBroken = true;
                    break outerTry;
                }
            foreach (int h; 0 .. N)
                if (info[h].isLoopHeader
                    && overlapPartially(t.start, t.end, h, info[h].loopEnd))
                {
                    tryBroken = true;
                    break outerTry;
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
        else if (b.bc == BC._finally)
        {
            // Normal entry branches to the finally body (Bsucc[1]), skipping
            // the exceptional BC._lpad block that follows this one.
            const int t = blockIdx(succ(b, 1));
            if (t != int.max && t > i + 1)
                needFrame(i, t);
        }
        else if (b.bc == BC._lpad || b.bc == BC.jcatch)
        {
            // Landing pads continue at Bsucc[0]; after blockopt (-O) that
            // block is not necessarily laid out right after the pad.
            const int t = blockIdx(succ(b, 0));
            if (t != int.max && t > i + 1)
                needFrame(i, t);
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
                printf("  b%d bc=%d try=%d succ=[", cast(int) i, cast(int) b.bc,
                    b.Btry ? blockIdx(b.Btry) : -1);
                foreach (int si; 0 .. cast(int) b.Bsucc.length)
                    printf("%s%d", si ? ",".ptr : "".ptr, blockIdx(b.Bsucc[si]));
                printf("]\n");
            }
        }
    }

    // Frames must nest (LIFO), so widen begins until the set is laminar.
    // Loops and try regions are fixed [start, end] frames the block frames
    // must respect.
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
                void respectRegion(int h, int le)
                {
                    if (f.begin > h && f.begin <= le && f.end > le)
                    {
                        f.begin = h; // exits the region: enclose it
                        changed = true;
                    }
                    else if (f.begin < h && f.end >= h && f.end < le)
                    {
                        // Branch into the region from outside (multi-entry
                        // loop, goto into a try body): unstructurable. Keep
                        // the frame for in-region sources; the validation
                        // below sees the outside sources are uncovered and
                        // picks the dispatch-loop fallback for the whole
                        // function.
                        f.begin = h;
                        changed = true;
                    }
                }

                foreach (int h; 0 .. N)
                    if (info[h].isLoopHeader)
                        respectRegion(h, info[h].loopEnd);
                foreach (ref const TryReg t; tryRegs)
                    respectRegion(t.start, t.end);
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
    bool structurable = converged && !tryBroken;
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
            if (b.bc == BC._finally)
            {
                const int t = blockIdx(succ(b, 1));
                if (t != i + 1 && !branchOK(i, t))
                {
                    structurable = false;
                    break outer;
                }
                continue;
            }
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
        {
            foreach (ref const f; bframes)
                printf("  frame [%d..%d] -> %d\n", f.begin, f.end, f.end + 1);
            foreach (ref const t; tryRegs)
                printf("  try [%d..%d] land %d %s\n", t.start, t.end,
                    t.end + 1, t.isCatch ? "catch".ptr : "finally".ptr);
        }
    }

    enum FrameKind
    {
        block,
        loop,
        tryTable, // the try_table instruction's own frame
        catchLand, // typed block the catch clause lands on (result i32/exnref)
    }

    // Nesting stack of open frames; frames must close in LIFO order.
    struct Frame
    {
        FrameKind kind;
        int closeAfter; // OP_END is emitted after this block index
        int loopStart = -1; // for loops: the header block index
        bool parentReachable; // reachability at the point this frame was opened
        int tryIdx = -1; // for tryTable/catchLand: index into tryRegs
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
            if (f.kind == FrameKind.loop && f.loopStart == headerIdx)
                return fi;
        return stack.length;
    }

    // Block frame closing exactly where targetIdx begins, so a br to it
    // lands on targetIdx. The pre-pass opened one per forward branch target.
    size_t exactFrame(int targetIdx)
    {
        foreach_reverse (size_t fi, ref const Frame f; stack)
            if (f.kind == FrameKind.block && f.closeAfter == targetIdx - 1)
                return fi;
        return stack.length;
    }

    void openBlock(int closeAfter)
    {
        stack ~= Frame(FrameKind.block, closeAfter, -1, cg.reachable);
        cg.emit(OP_BLOCK);
        cg.emit(WASM_VOID_BLOCK);
    }

    // Open the two frames of a try region: the typed landing block the catch
    // clause targets, then the try_table itself (innermost, so the clause's
    // label immediate is always 0 — labels resolve outside the try_table).
    void openTryFrames(int ti)
    {
        const int end = tryRegs[ti].end;
        const bool isCatch = tryRegs[ti].isCatch;
        stack ~= Frame(FrameKind.catchLand, end, -1, cg.reachable, ti);
        cg.emit(OP_BLOCK);
        cg.emit(isCatch ? WASM_I32 : WASM_TYPE.EXNREF);
        stack ~= Frame(FrameKind.tryTable, end, -1, cg.reachable, ti);
        cg.emit(OP_TRY_TABLE);
        cg.emit(WASM_VOID_BLOCK);
        cg.emitULEB(1);
        if (isCatch)
        {
            cg.emit(WASM_CATCH.CATCH);
            cg.emitTagOperand();
        }
        else
            cg.emit(WASM_CATCH.CATCH_ALL_REF);
        cg.emitULEB(0);
    }

    // Close the innermost open frame. A catchLand frame's END is the landing
    // pad: the caught value is on the stack there, so park it (jcatchvar for
    // a catch's i32 payload, a per-try exnref local for a finally), and the
    // pad is reachable via the exceptional edge regardless of fall-through.
    void closeTop()
    {
        const Frame f = stack[$ - 1];
        cg.emit(OP_END);
        stack = stack[0 .. $ - 1];
        if (f.kind == FrameKind.tryTable)
        {
            // The try body always branches out, so normal completion of the
            // try_table is impossible; the validator still types the
            // fall-through path to the catchLand END, which expects the
            // caught value. Make that path polymorphic.
            cg.emit(OP_UNREACHABLE);
            cg.reachable = false;
            return;
        }
        if (f.kind == FrameKind.catchLand)
        {
            if (tryRegs[f.tryIdx].isCatch)
                emitCaughtStore(cg, tryRegs[f.tryIdx].tryBlock.jcatchvar);
            else
                cg.emitLocal(OP_LOCAL_SET,
                    cg.exnLocalFor(tryRegs[f.tryIdx].tryBlock.Bsucc[1].flag));
            cg.reachable = true;
        }
        else
            cg.reachable = f.parentReachable;
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
            closeTop();

        void openLoop(int loopEnd)
        {
            stack ~= Frame(FrameKind.loop, loopEnd, bi, cg.reachable);
            cg.emit(OP_LOOP);
            cg.emit(WASM_VOID_BLOCK);
        }

        // Open frames beginning here. At a loop header, frames ending at or
        // after the loop end enclose the loop, the rest open inside it; a
        // try region nests inside or outside the loop by relative extent.
        int tryIdx = -1;
        foreach (size_t ti, ref const TryReg t; tryRegs)
            if (t.start == bi)
                tryIdx = cast(int) ti;

        if (info[bi].isLoopHeader && tryIdx >= 0)
        {
            const int le = info[bi].loopEnd;
            const int te = tryRegs[tryIdx].end;
            if (le >= te)
            {
                openFramesAt(bi, le - 1, int.max);
                openLoop(le);
                openFramesAt(bi, te, le - 1);
                openTryFrames(tryIdx);
                openFramesAt(bi, -1, te < le ? te : le - 1);
            }
            else
            {
                openFramesAt(bi, te, int.max);
                openTryFrames(tryIdx);
                openFramesAt(bi, le - 1, te);
                openLoop(le);
                openFramesAt(bi, -1, le - 1);
            }
        }
        else if (info[bi].isLoopHeader)
        {
            const int loopEnd = info[bi].loopEnd;
            openFramesAt(bi, loopEnd - 1, int.max);
            openLoop(loopEnd);
            openFramesAt(bi, -1, loopEnd - 1);
        }
        else if (tryIdx >= 0)
        {
            const int te = tryRegs[tryIdx].end;
            openFramesAt(bi, te, int.max);
            openTryFrames(tryIdx);
            openFramesAt(bi, -1, te);
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
                cg.genElemDiscard(b.Belem);
            if (!target)
                continue;

            const int targetIdx = blockIdx(target);
            if (targetIdx != bi + 1) // == bi+1 falls through naturally
                branchToBlock(targetIdx, false);
            continue;
        }
        else if (b.bc == BC._finally)
        {
            // Normal entry: branch to the finally body (Bsucc[1]), skipping
            // the exceptional BC._lpad block right after this one.
            if (b.Belem)
                cg.genElemDiscard(b.Belem);
            const int t = blockIdx(succ(b, 1));
            if (t != bi + 1)
                branchToBlock(t, false);
            continue;
        }
        else if (b.bc == BC._lpad || b.bc == BC.jcatch)
        {
            // Landing pad: continue at Bsucc[0], which blockopt (-O) may
            // have laid out elsewhere.
            if (b.Belem)
                cg.genElemDiscard(b.Belem);
            const int t = blockIdx(succ(b, 0));
            if (t != bi + 1)
                branchToBlock(t, false);
            continue;
        }

        // Default: emit expression, discard result.
        // (BC._try opens its frames above.)
        if (b.Belem)
            cg.genElemDiscard(b.Belem);
    }

    while (stack.length > 0)
        closeTop();
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
                cg.genElemDiscard(b.Belem);
            if (block* target = succ(b, 0))
                gotoBlock(blockIdx(target), 0);
        }
        else if (b.bc == BC._finally)
        {
            // Normal-path finally entry (no try_table in dispatch mode, so
            // the exceptional path is lost: exceptions escape this function).
            if (b.Belem)
                cg.genElemDiscard(b.Belem);
            gotoBlock(blockIdx(succ(b, 1)), 0);
        }
        else
        {
            if (b.Belem)
                cg.genElemDiscard(b.Belem);
            if (i + 1 < N)
                gotoBlock(i + 1, 0);
        }
    }

    cg.emit(OP_END); // close the dispatch loop
    // Control never falls out of the loop, but the validator doesn't know
    cg.emit(OP_UNREACHABLE);
    cg.reachable = false;
}
