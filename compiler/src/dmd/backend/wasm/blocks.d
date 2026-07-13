/**
 * WebAssembly control-flow structuring.
 *
 * WebAssembly has no arbitrary `goto`: control flow is expressed with nested
 * structured regions — `block`/`loop`/`if` bracketed by `end`, left by a `br N`
 * that targets the N-th enclosing region. This module turns DMD's unstructured
 * block CFG (arbitrary `Bsucc` edges) into that nested form and drives codgen.d
 * to emit the region opcodes and branches.
 *
 * Algorithm:
 *   1. Assign each block a reverse-post-order index. A successor edge B => A
 *      with A.index <= B.index is a back edge, making A a loop header (its region
 *      becomes a `loop`); overlapping loop regions from irreducible flow are
 *      widened so they nest.
 *   2. Every forward branch target gets a `block` frame: OP_BLOCK opens before
 *      the span reaching it and OP_END closes just before the target, so a `br`
 *      to that frame lands on the target. All frames are collected up front and
 *      widened until laminar (frames must nest LIFO), because several targets can
 *      be pending at once (an if-chain) in an order lazy per-branch opening can't
 *      produce.
 *   3. Emit: at each block, close frames ending before it and open frames
 *      beginning at it, then translate the terminator into fall-through, `br`,
 *      `br_if`, or `br_table` (switch: dense range => indexed table, sparse =>
 *      compare chain).
 *
 * Exceptions (EH_WASM) add `try_table` frames: `structureTryRegions` reorders
 * blocks so each `BC._try` header is immediately followed by the blocks it
 * guards and then its landing-pad group (blockopt (-O) and the inliner scatter
 * them); the catch clause lands on the block just past the try body.
 *
 * Fallback: a CFG that can't be made laminar (goto into a loop body, `goto case`
 * to an earlier case, some optimizer layouts) fails validation and is emitted
 * with a dispatch loop — a selector local drives a `br_table` inside one big
 * `loop`, one wrapper `block` per basic block, so every branch becomes "set
 * selector, br to the loop". Correct for any CFG, but slower code.
 *
 * Set WASM_BLOCKS=1 in the environment to dump the block graph and the repaired
 * frames when debugging structuring bugs.
 *
 * Copyright:   Copyright (C) 1999-2026 by The D Language Foundation, All Rights Reserved
 * License:     $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/compiler/src/dmd/backend/wasm/blocks.d, _blocks.d)
 */
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

import core.stdc.stdio : printf;
import core.stdc.stdlib : getenv;

nothrow:

private struct BlkInfo
{
    bool isLoopHeader; // targeted by a back edge
    int loopEnd; // for loop headers: index of the block that closes the loop
}

private int blockIdx(block* b)
{
    return b ? b.Bdfoidx : int.max;
}

private block* succ(block* b, int n)
{
    if (n < b.Bsucc.length)
        return b.Bsucc[n];
    return null;
}

private bool emitBlockReturn(ref WasmCG cg, block* b, bool hasReturn)
{
    if (b.bc == BC.retexp)
    {
        if (!hasReturn)
        {
            if (b.Belem)
                cg.genElemDiscard(b.Belem);
            if (cg.framePublished)
                emitShadowEpilogue(cg);
            cg.emit(OP_RETURN);
            cg.reachable = false;
            return true;
        }
        bool hasRetVal;
        if (b.Belem)
            hasRetVal = cg.genElem(b.Belem);
        if (cg.framePublished)
        {
            if (hasRetVal)
            {
                const tym_t bty = tybasic(b.Belem.Ety);
                WASM_TYPE retTy = wasmType(bty);
                uint retTmp = cg.allocTemp(retTy);
                cg.emit(OP_LOCAL_SET, uleb(retTmp));
                emitShadowEpilogue(cg);
                cg.emit(OP_LOCAL_GET, uleb(retTmp));
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
        if (hasReturn)
            cg.emit(OP_UNREACHABLE);
        cg.emit(OP_RETURN);
        cg.reachable = false;
        return true;
    }
    else if (b.bc == BC.exit || b.bc == BC._ret)
    {
        if (b.Belem)
            cg.genElemDiscard(b.Belem);
        cg.emit(OP_UNREACHABLE);
        cg.reachable = false;
        return true;
    }
    return false;
}

private void emitCaseEq(ref WasmCG cg, WASM_TYPE condType, uint condLocal, long cv)
{
    cg.emit(OP_LOCAL_GET, uleb(condLocal));
    if (condType == WASM_I64)
        cg.emit(OP_I64_CONST, sleb(cv), OP_I64_EQ);
    else
        cg.emit(OP_I32_CONST, sleb(cast(int) cv), OP_I32_EQ);
}

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
                foreach (m; blocks)
                    if (m !is node && levelNode(m, node) !is null)
                        foreach (s; m.Bsucc)
                            visitSucc(s);
                block* h = node.Bsucc[1];
                if (h && (h.bc == BC.jcatch || h.bc == BC._finally))
                {
                    foreach (s; h.Bsucc)
                        visitSucc(s);
                    if (h.bc == BC._finally && h.Bsucc.length
                        && h.Bsucc[0].bc == BC._lpad)
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
        if (h && !placed[h.Bdfoidx]
            && (h.bc == BC.jcatch || h.bc == BC._finally))
        {
            placed[h.Bdfoidx] = true;
            result ~= h;
            block* lp = h.bc == BC._finally && h.Bsucc.length ? h.Bsucc[0] : null;
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
    block*[] blocks;
    for (block* b = startblock; b; b = b.Bnext)
        blocks ~= b;
    const int N = cast(int) blocks.length;
    if (N == 0)
        return;

    foreach (b; blocks)
        if (b.bc == BC._try)
        {
            blocks = layoutTryRegions(blocks);
            break;
        }

    foreach (size_t i, b; blocks)
        b.Bdfoidx = cast(int) i;

    BlkInfo[] info = new BlkInfo[N];
    foreach (size_t i, b; blocks)
    {
        if (b.bc == BC.goto_ || b.bc == BC.iftrue || b.bc == BC.ifthen
            || b.bc == BC.jmptab || b.bc == BC.switch_
            || b.bc == BC._finally || b.bc == BC._lpad || b.bc == BC.jcatch)
        {
            foreach (s; b.Bsucc)
            {
                if (s && s.Bdfoidx <= cast(int) i)
                {
                    info[s.Bdfoidx].isLoopHeader = true;
                    if (info[s.Bdfoidx].loopEnd < cast(int) i)
                        info[s.Bdfoidx].loopEnd = cast(int) i;
                }
            }
        }
    }

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

    struct TryReg
    {
        int start;
        int end;
        bool isCatch;
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
        const bool table = b.bc == BC.jmptab || b.bc == BC.switch_;
        if (table || b.bc == BC.goto_ || b.bc == BC.iftrue || b.bc == BC.ifthen)
        {
            foreach (s; b.Bsucc)
            {
                const int t = blockIdx(s);
                if (t != int.max && t > (table ? i : i + 1))
                    needFrame(i, t);
            }
        }
        else if (b.bc == BC._finally || b.bc == BC._lpad || b.bc == BC.jcatch)
        {
            const int t = blockIdx(succ(b, b.bc == BC._finally ? 1 : 0));
            if (t != int.max && t > i + 1)
                needFrame(i, t);
        }
    }
    foreach (int h; 0 .. N)
        if (info[h].isLoopHeader)
            needFrame(h, info[h].loopEnd + 1);

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
                        f.begin = h;
                        changed = true;
                    }
                    else if (f.begin < h && f.end >= h && f.end < le)
                    {
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
                        f.begin = g.begin;
                        changed = true;
                    }
            }
        }
        converged = !changed;
    }

    bool structurable = converged && !tryBroken;
    if (structurable)
    {
        bool branchOK(int i, int t)
        {
            if (t == int.max)
                return true;
            if (t <= i)
                return info[t].isLoopHeader && info[t].loopEnd >= i;
            foreach (ref const f; bframes)
                if (f.end == t - 1)
                    return f.begin <= i;
            return true;
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
            foreach (s; b.Bsucc)
            {
                const int t = blockIdx(s);
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

    if (getenv("WASM_BLOCKS"))
    {
        foreach (ref const f; bframes)
            printf("  frame [%d..%d] -> %d\n", f.begin, f.end, f.end + 1);
        foreach (ref const t; tryRegs)
            printf("  try [%d..%d] land %d %s\n", t.start, t.end,
                t.end + 1, t.isCatch ? "catch".ptr : "finally".ptr);
    }

    enum FrameKind
    {
        block,
        loop,
        tryTable,
        catchLand,
    }

    struct Frame
    {
        FrameKind kind;
        int closeAfter;
        int loopStart = -1;
        bool parentReachable;
        int tryIdx = -1;
    }

    Frame[] stack;

    uint brDepth(size_t frameIdx)
    {
        return cast(uint)(stack.length - 1 - frameIdx);
    }

    size_t loopFrame(int headerIdx)
    {
        foreach_reverse (size_t fi, ref const Frame f; stack)
            if (f.kind == FrameKind.loop && f.loopStart == headerIdx)
                return fi;
        return stack.length;
    }

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
        cg.emit(OP_BLOCK, WASM_VOID_BLOCK);
    }

    void openTryFrames(int ti)
    {
        const int end = tryRegs[ti].end;
        const bool isCatch = tryRegs[ti].isCatch;
        stack ~= Frame(FrameKind.catchLand, end, -1, cg.reachable, ti);
        cg.emit(OP_BLOCK, isCatch ? WASM_I32 : WASM_TYPE.EXNREF);
        stack ~= Frame(FrameKind.tryTable, end, -1, cg.reachable, ti);
        cg.emit(OP_TRY_TABLE, WASM_VOID_BLOCK, uleb(1));
        if (isCatch)
        {
            cg.emit(WASM_CATCH.CATCH);
            cg.emitTagOperand();
        }
        else
            cg.emit(WASM_CATCH.CATCH_ALL_REF);
        cg.emit(uleb(0));
    }

    void closeTop()
    {
        const Frame f = stack[$ - 1];
        cg.emit(OP_END);
        stack = stack[0 .. $ - 1];
        if (f.kind == FrameKind.tryTable)
        {
            cg.emit(OP_UNREACHABLE);
            cg.reachable = false;
            return;
        }
        if (f.kind == FrameKind.catchLand)
        {
            if (tryRegs[f.tryIdx].isCatch)
                emitCaughtStore(cg, tryRegs[f.tryIdx].tryBlock.jcatchvar);
            else
                cg.emit(OP_LOCAL_SET,
                    uleb(cg.exnLocalFor(tryRegs[f.tryIdx].tryBlock.Bsucc[1].flag)));
            cg.reachable = true;
        }
        else
            cg.reachable = f.parentReachable;
    }

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

    int currentIdx;

    uint destDepth(int t)
    {
        const size_t fi = t <= currentIdx ? loopFrame(t) : exactFrame(t);
        assert(fi < stack.length, "wasm blocks: branch target has no frame");
        return brDepth(fi);
    }

    void branchToBlock(int t, bool conditional)
    {
        cg.emit(conditional ? OP_BR_IF : OP_BR, uleb(destDepth(t)));
        if (!conditional)
            cg.reachable = false;
    }

    foreach (const bi; 0 .. N)
    {
        block* b = blocks[bi];
        currentIdx = bi;

        while (stack.length > 0 && stack[$ - 1].closeAfter < bi)
            closeTop();

        void openLoop(int loopEnd)
        {
            stack ~= Frame(FrameKind.loop, loopEnd, bi, cg.reachable);
            cg.emit(OP_LOOP, WASM_VOID_BLOCK);
        }

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
            const int defaultIdx = blockIdx(b.Bsucc[0]);

            cg.genElem(b.Belem);

            if (b.Bswitch.length == 0)
            {
                cg.emit(OP_DROP);
                if (defaultIdx != bi + 1)
                    branchToBlock(defaultIdx, false);
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
            const ulong span = cast(ulong) vmax - cast(ulong) vmin;
            const bool useBrTable = condType == WASM_I32
                && span < maxJumpTableSize
                && span < b.Bswitch.length * 4UL + 4;

            if (!useBrTable)
            {
                const uint condLocal = cg.allocTemp(condType);
                cg.emit(OP_LOCAL_SET, uleb(condLocal));
                foreach (size_t ci, long cv; b.Bswitch)
                {
                    emitCaseEq(cg, condType, condLocal, cv);
                    branchToBlock(blockIdx(b.Bsucc[cast(int)(ci + 1)]), true);
                }
                if (defaultIdx != bi + 1)
                    branchToBlock(defaultIdx, false);
                continue;
            }

            if (vmin != 0)
                cg.emit(OP_I32_CONST, sleb(cast(int)-vmin), OP_I32_ADD);

            const size_t tableLen = cast(size_t)(span + 1);
            cg.emit(OP_BR_TABLE, uleb(cast(uint) tableLen));
            foreach (long v; vmin .. vmax + 1)
            {
                int destIdx = defaultIdx;
                foreach (size_t ci, long cv; b.Bswitch)
                    if (cv == v)
                    {
                        destIdx = blockIdx(b.Bsucc[cast(int)(ci + 1)]);
                        break;
                    }
                cg.emit(uleb(destDepth(destIdx)));
            }
            cg.emit(uleb(destDepth(defaultIdx)));
            cg.reachable = false;
            continue;
        }
        else if (b.bc == BC.ifthen || b.bc == BC.iftrue)
        {
            const int takenIdx = blockIdx(succ(b, 0));
            const int nottakenIdx = blockIdx(succ(b, 1));

            if (b.Belem)
                cg.genElem(b.Belem);
            else
                cg.emitConst(OP_I32_CONST, 0);

            if (takenIdx == nottakenIdx)
            {
                emitCondToI32(cg, b.Belem);
                cg.emit(OP_DROP);
                if (takenIdx != bi + 1)
                    branchToBlock(takenIdx, false);
            }
            else if (takenIdx == bi + 1)
            {
                emitCondInvert(cg, b.Belem);
                branchToBlock(nottakenIdx, true);
            }
            else if (nottakenIdx == bi + 1)
            {
                emitCondToI32(cg, b.Belem);
                branchToBlock(takenIdx, true);
            }
            else
            {
                emitCondToI32(cg, b.Belem);
                branchToBlock(takenIdx, true);
                branchToBlock(nottakenIdx, false);
            }
            continue;
        }
        else if (b.bc == BC.goto_ || b.bc == BC._finally
            || b.bc == BC._lpad || b.bc == BC.jcatch)
        {
            if (b.Belem)
                cg.genElemDiscard(b.Belem);
            const int t = blockIdx(succ(b, b.bc == BC._finally ? 1 : 0));
            if (t != int.max && t != bi + 1)
                branchToBlock(t, false);
            continue;
        }

        if (b.Belem)
            cg.genElemDiscard(b.Belem);
    }

    while (stack.length > 0)
        closeTop();
}

private void genBlocksDispatch(ref WasmCG cg, block*[] blocks, bool hasReturn)
{
    if (getenv("WASM_BLOCKS"))
        printf("  (dispatch fallback)\n");

    const uint sel = cg.allocTemp(WASM_I32);
    cg.emit(OP_I32_CONST, sleb(0), OP_LOCAL_SET, uleb(sel));

    cg.emit(OP_LOOP, WASM_VOID_BLOCK);
    foreach (i; 0 .. blocks.length)
        cg.emit(OP_BLOCK, WASM_VOID_BLOCK);
    cg.emit(OP_LOCAL_GET, uleb(sel), OP_BR_TABLE, uleb(cast(uint) blocks.length));
    foreach (i; 0 .. blocks.length)
        cg.emit(uleb(cast(uint) i));
    cg.emit(uleb(0));

    const int N = cast(int) blocks.length;
    foreach (i; 0 .. blocks.length)
    {
        cg.emit(OP_END);
        block* b = blocks[i];

        const uint loopDepth = cast(uint)(N - 1 - i);

        void gotoBlock(size_t t, uint extraDepth)
        {
            cg.emit(OP_I32_CONST, sleb(t), OP_LOCAL_SET, uleb(sel),
                OP_BR, uleb(loopDepth + extraDepth));
        }

        if (emitBlockReturn(cg, b, hasReturn))
            continue;

        if (b.bc == BC.iftrue || b.bc == BC.ifthen)
        {
            cg.emit(OP_I32_CONST, sleb(blockIdx(succ(b, 0))),
                OP_I32_CONST, sleb(blockIdx(succ(b, 1))));
            if (b.Belem)
                cg.genElem(b.Belem);
            else
                cg.emitConst(OP_I32_CONST, 0);
            emitCondToI32(cg, b.Belem);
            cg.emit(OP_SELECT, OP_LOCAL_SET, uleb(sel), OP_BR, uleb(loopDepth));
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
            const condType = b.Belem.wasmType;
            const uint condLocal = cg.allocTemp(condType);
            cg.emit(OP_LOCAL_SET, uleb(condLocal));
            foreach (size_t ci, long cv; b.Bswitch)
            {
                emitCaseEq(cg, condType, condLocal, cv);
                cg.emit(OP_IF, WASM_VOID_BLOCK);
                gotoBlock(blockIdx(b.Bsucc[cast(int)(ci + 1)]), 1);
                cg.emit(OP_END);
            }
            gotoBlock(defaultIdx, 0);
        }
        else if (b.bc == BC.goto_ || b.bc == BC._finally)
        {
            if (b.Belem)
                cg.genElemDiscard(b.Belem);
            if (block* target = succ(b, b.bc == BC._finally ? 1 : 0))
                gotoBlock(blockIdx(target), 0);
        }
        else
        {
            if (b.Belem)
                cg.genElemDiscard(b.Belem);
            if (i + 1 < N)
                gotoBlock(i + 1, 0);
        }
    }

    cg.emit(OP_END);
    cg.emit(OP_UNREACHABLE);
    cg.reachable = false;
}
