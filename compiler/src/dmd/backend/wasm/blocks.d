module dmd.backend.wasm.blocks;

import dmd.backend.cc;
import dmd.backend.cdef;
import dmd.backend.el;
import dmd.backend.oper;
import dmd.backend.ty;
import dmd.backend.type;
import dmd.backend.var : globsym;
import dmd.backend.wasm.enums;
import dmd.backend.wasm.codgen;

nothrow:

// Per-block metadata computed during analysis
private struct BlkInfo
{
    int idx; // sequential index (0-based)
    bool isLoopHeader; // targeted by a back edge
    int loopEnd; // for loop headers: index of the block that closes the loop
    int nOpen; // how many block/loop pairs open AT this block
    int nClose; // how many end's to emit AFTER this block
    int[] jmptabDests; // for BC.jmptab: unique sorted destination block indices
}

private block*[] collectBlocks(block* start)
{
    block*[] v;
    for (block* b = start; b; b = b.Bnext)
        v ~= b;
    return v;
}

private int blockIdx(block* b)
{
    return b ? b.Bdfoidx : int.max;
}

// Successor index in Bsucc list
private block* succ(block* b, int n)
{
    if (n < b.numSucc())
        return b.nthSucc(n);
    return null;
}

/// Structured control flow synthesis (block CFG => WASM)
void genBlocksProper(ref WasmCG cg, block* startblock, bool hasReturn)
{
    block*[] blocks = collectBlocks(startblock);
    const int N = cast(int) blocks.length;
    if (N == 0)
        return;

    // Assign sequential indices
    foreach (size_t i, b; blocks)
        b.Bdfoidx = cast(int) i;

    // Find back edges: edge B => A where A.idx <= B.idx
    // A back edge target is a loop header.
    BlkInfo[] info = new BlkInfo[N];
    foreach (size_t i, b; blocks)
    {
        info[i].idx = cast(int) i;
        if (b.bc == BC.goto_ || b.bc == BC.iftrue)
        {
            foreach (int si; 0 .. b.numSucc())
            {
                block* s = b.nthSucc(si);
                if (s && s.Bdfoidx <= cast(int) i) // back edge
                {
                    info[s.Bdfoidx].isLoopHeader = true;
                    if (info[s.Bdfoidx].loopEnd < cast(int) i)
                        info[s.Bdfoidx].loopEnd = cast(int) i;
                }
            }
        }
    }

    // Nesting stack: each entry is (isLoop: bool, openedAtIdx: int, closeAtIdx: int)
    struct Frame
    {
        bool isLoop;
        int closeAfter;
    }

    Frame[] stack;
    int depth()
    {
        return cast(int) stack.length;
    }

    // br depth to reach a given stack frame (0 = innermost)
    uint brDepth(size_t frameIdx)
    {
        return cast(uint)(stack.length - 1 - frameIdx);
    }

    // Find the stack frame for a loop whose header is at idx
    // Returns stack.length if not found (sentinel)
    size_t loopFrame(int headerIdx)
    {
        foreach_reverse (size_t fi, ref const Frame f; stack)
            if (f.isLoop && f.closeAfter >= headerIdx)
                return fi;
        return stack.length; // sentinel: not found
    }

    // Find the enclosing block (non-loop) frame index for a forward exit target
    size_t blockFrame(int exitTarget)
    {
        foreach_reverse (size_t fi, ref const Frame f; stack)
            if (!f.isLoop && f.closeAfter >= exitTarget - 1)
                return fi;
        return stack.length; // sentinel: not found
    }

    foreach (const bi; 0 .. N)
    {
        block* b = blocks[bi];

        // Close frames whose closeAfter == bi - 1
        while (stack.length > 0 && stack[$ - 1].closeAfter < bi)
        {
            cg.emit(OP_END);
            stack = stack[0 .. $ - 1];
        }

        // Open wrapper blocks for BC.jmptab (switch via br_table).
        // Must happen before loop-header frames so depths are computed correctly.
        if (b.bc == BC.jmptab || b.bc == BC.switch_)
        {
            // Collect unique destination block indices, sorted ascending.
            // Bsucc[0] = default; Bsucc[1..n] = cases in Bswitch order.
            int[] dests;
            foreach (int si; 0 .. b.numSucc())
            {
                int idx = blockIdx(b.nthSucc(si));
                bool found = false;
                foreach (d; dests)
                    if (d == idx)
                    {
                        found = true;
                        break;
                    }
                if (!found)
                    dests ~= idx;
            }

            import std.algorithm : sort; // TODO: don't import Phobos

            sort(dests);

            // Open one wrapper block per unique dest, outermost (highest idx) first.
            // Frame closeAfter = destIdx - 1 so the block ends just before that block.
            foreach_reverse (int destIdx; dests)
            {
                stack ~= Frame(false, destIdx - 1);
                cg.emit(OP_BLOCK);
                cg.emit(WASM_VOID_BLOCK);
            }
            // stash dest list for use when emitting the br_table
            info[bi].jmptabDests = dests;
        }

        // Open a loop for loop headers: emit `block` (exit) + `loop` (continue)
        if (info[bi].isLoopHeader)
        {
            int loopEnd = info[bi].loopEnd;
            // block $exit (depth +1): close after loopEnd
            stack ~= Frame(false, loopEnd);
            cg.emit(OP_BLOCK);
            cg.emit(WASM_VOID_BLOCK);
            // loop $continue (depth +1): also close after loopEnd
            stack ~= Frame(true, loopEnd);
            cg.emit(OP_LOOP);
            cg.emit(WASM_VOID_BLOCK);
        }

        // Emit block expression (statement-level: discard result)
        if (b.bc == BC.retexp)
        {
            // Return value: leave on stack, then return
            if (b.Belem)
                cg.genElem(b.Belem);
            if (cg.hasShadowFrame)
            {
                if (b.Belem) // return value is on the stack
                {
                    // Save, epilogue, reload. Aggregates returned via
                    // hidden pointer leave an i32 on the stack.
                    // Use the function-level retByHiddenPtr flag because
                    // TYdarray/TYdelegate alias TYullong/TYllong on wasm32,
                    // so b.Belem.Ety can't distinguish a slice/delegate
                    // return from a plain ulong/long.
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
            // If the function has a return value but this path provides none
            // (e.g. void call to a noreturn function like __switch_error),
            // emit unreachable so the WASM validator sees a polymorphic stack.
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
            // dests[i] has depth = (dests.length - 1 - i) from the current stack top.
            int[] dests = info[bi].jmptabDests;
            size_t nw = dests.length;

            // Emit switch expression
            cg.genElem(b.Belem);

            // Compute vmin/vmax from case values
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

            // Helper: depth for a given block index
            uint depthOf(int destIdx)
            {
                foreach (size_t di, int d; dests)
                    if (d == destIdx)
                        return cast(uint)(di);
                return cast(uint)(nw - 1); // fallback: default
            }

            // Default block: Bsucc[0]
            int defaultIdx = blockIdx(b.nthSucc(0));
            uint defaultDepth = depthOf(defaultIdx);

            // br_table is only valid for i32 indices and dense ranges.
            // Use if-else chain when: values are i64, or the range is too
            // sparse (table would exceed 1024 entries).
            enum maxJumpTableSize = 1024;

            const ulong tableLen64 = cast(ulong)(vmax - vmin) + 1;
            const bool useBrTable = tableLen64 <= maxJumpTableSize && tableLen64 <= b.Bswitch.length * 4UL + 4;

            if (!useBrTable)
            {
                // If-else chain: store condition in a local, compare each case.
                const condType = b.Belem.wasmType;
                uint condLocal = cg.allocTemp(condType);
                cg.emit(OP_LOCAL_SET);
                cg.emitULEB(condLocal);
                foreach (size_t ci, long cv; b.Bswitch)
                {
                    int caseIdx = blockIdx(b.nthSucc(cast(int)(ci + 1)));
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
                // Fall through to default
                if (defaultDepth > 0)
                {
                    cg.emit(OP_BR);
                    cg.emitULEB(defaultDepth);
                }
                continue;
            }

            // Dense i32 range: use br_table.
            // Adjust switch value to 0-based
            if (vmin != 0)
            {
                cg.emitConst(OP_I32_CONST, cast(int)-vmin);
                cg.emit(OP_I32_ADD);
            }

            // Table entries: for each integer value vmin..vmax, find its dest
            const size_t tableLen = cast(size_t) tableLen64;
            cg.emit(OP_BR_TABLE);
            cg.emitULEB(cast(uint) tableLen);
            foreach (long v; vmin .. vmax + 1)
            {
                // Find which Bswitch entry matches this value
                int destIdx = defaultIdx;
                foreach (size_t ci, long cv; b.Bswitch)
                    if (cv == v)
                    {
                        destIdx = blockIdx(b.nthSucc(cast(int)(ci + 1)));
                        break;
                    }
                cg.emitULEB(depthOf(destIdx));
            }
            cg.emitULEB(defaultDepth); // default label
            continue;
        }
        else if (b.bc == BC.ifthen || b.bc == BC.iftrue)
        {
            // switch converted to if-then chain is same as iftrue
            block* taken = succ(b, 0);
            block* nottaken = succ(b, 1);
            int takenIdx = blockIdx(taken);
            int nottakenIdx = blockIdx(nottaken);

            // Find enclosing loop (if any)
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
                if (b.Belem)
                    cg.genElem(b.Belem);
                else
                {
                    cg.emitConst(OP_I32_CONST, 0);
                }
                emitCondToI32(cg, b.Belem);
                size_t lf = loopFrame(takenIdx);
                if (lf < stack.length)
                {
                    cg.emit(OP_BR_IF);
                    cg.emitULEB(brDepth(lf));
                    // false => exit loop
                    if (nottakenIdx > info[takenIdx].loopEnd)
                    {
                        size_t ef = blockFrame(nottakenIdx);
                        if (ef < stack.length)
                        {
                            cg.emit(OP_BR);
                            cg.emitULEB(brDepth(ef));
                        }
                    }
                }
                else
                    cg.emit(OP_DROP);
            }
            else if (nottakenIdx <= cast(int) bi)
            {
                // Back edge: condition false => loop continue
                if (b.Belem)
                    cg.genElem(b.Belem);
                else
                {
                    cg.emitConst(OP_I32_CONST, 0);
                }
                emitCondInvert(cg, b.Belem);
                size_t lf = loopFrame(nottakenIdx);
                if (lf < stack.length)
                {
                    cg.emit(OP_BR_IF);
                    cg.emitULEB(brDepth(lf));
                }
                else
                    cg.emit(OP_DROP);
            }
            else if (outerLoop < stack.length &&
                (nottakenIdx == exitBlockIdx || takenIdx == exitBlockIdx))
            {
                // Loop exit condition (condition block is loop header or part of loop)
                if (b.Belem)
                    cg.genElem(b.Belem);
                else
                {
                    cg.emitConst(OP_I32_CONST, 0);
                }
                if (nottakenIdx == exitBlockIdx)
                {
                    // condition true => stay in loop, false => exit
                    emitCondInvert(cg, b.Belem);
                    cg.emit(OP_BR_IF);
                    cg.emitULEB(brDepth(outerLoop - 1));
                }
                else
                {
                    // condition true => exit, false => stay
                    emitCondToI32(cg, b.Belem);
                    cg.emit(OP_BR_IF);
                    cg.emitULEB(brDepth(outerLoop - 1));
                }
            }
            else
            {
                // Pure forward if/else (no loop involved).
                // Open a block BEFORE emitting the condition so we can br_if out.
                if (takenIdx == cast(int) bi + 1)
                {
                    // True path is inline; false path at nottakenIdx.
                    // If the true path jumps past the false path (if-else), we need an
                    // outer block so the true path can 'br 1' to skip the false path.
                    // Detect by peeking at the taken block's successor.
                    int mergeIdx = -1;
                    if (bi + 1 < N)
                    {
                        block* takenBlock = blocks[bi + 1];
                        if (takenBlock.bc == BC.goto_ && takenBlock.numSucc() > 0)
                        {
                            block* mergeBlock = takenBlock.nthSucc(0);
                            if (mergeBlock)
                            {
                                int midx = blockIdx(mergeBlock);
                                if (midx > nottakenIdx)
                                    mergeIdx = midx;
                            }
                        }
                    }
                    if (mergeIdx >= 0)
                    {
                        // if-else structure: open outer block covering both paths.
                        stack ~= Frame(false, mergeIdx - 1);
                        cg.emit(OP_BLOCK);
                        cg.emit(WASM_VOID_BLOCK);
                    }
                    stack ~= Frame(false, nottakenIdx - 1);
                    cg.emit(OP_BLOCK);
                    cg.emit(WASM_VOID_BLOCK);
                    if (b.Belem)
                        cg.genElem(b.Belem);
                    else
                    {
                        cg.emitConst(OP_I32_CONST, 0);
                    }
                    emitCondInvert(cg, b.Belem);
                    cg.emit(OP_BR_IF);
                    cg.emitULEB(0);
                }
                else if (nottakenIdx == cast(int) bi + 1)
                {
                    // False path is inline; true path at takenIdx.
                    // block $skip ... cond; br_if 0 ... [false path] ... end $skip
                    stack ~= Frame(false, takenIdx - 1);
                    cg.emit(OP_BLOCK);
                    cg.emit(WASM_VOID_BLOCK);
                    if (b.Belem)
                        cg.genElem(b.Belem);
                    else
                    {
                        cg.emitConst(OP_I32_CONST, 0);
                    }
                    emitCondToI32(cg, b.Belem);
                    cg.emit(OP_BR_IF);
                    cg.emitULEB(0);
                }
                else
                {
                    // Both branches non-immediate — complex; just evaluate.
                    if (b.Belem)
                    {
                        bool v = cg.genElem(b.Belem);
                        if (v)
                            cg.emit(OP_DROP);
                    }
                }
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
                size_t lf = loopFrame(targetIdx);
                if (lf < stack.length)
                {
                    cg.emit(OP_BR);
                    cg.emitULEB(brDepth(lf));
                }
            }
            else if (targetIdx > bi + 1)
            {
                // Forward goto that skips blocks — need to br out of if-block.
                // Find the shallowest non-loop block frame that encompasses targetIdx.
                foreach_reverse (size_t fi, ref const Frame f; stack)
                {
                    if (!f.isLoop && f.closeAfter >= targetIdx - 1)
                    {
                        cg.emit(OP_BR);
                        cg.emitULEB(brDepth(fi));
                        break;
                    }
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

    // Close any remaining open frames
    while (stack.length > 0)
    {
        cg.emit(OP_END);
        stack = stack[0 .. $ - 1];
    }
}
