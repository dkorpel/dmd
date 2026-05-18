# Slice ABI refactor: rip out i64 packing, treat slices like structs

## Status
**Commit 2 landed** (Simplify sliceparams? — 323630d2a6): `isSliceElem` heuristic
gone, replaced by callee-param-driven splitting + a small RTL prototype table.
Commits 1 and 3 still **deferred** after a failed attempt — see "Failed attempt"
below.

## Failed attempt (2026-05-18): frontend RET.stack route
Tried the smallest-seeming path to commit 1 — make the frontend route slice
returns through its existing sret machinery by:

1. `argtypes_wasm.d`: return `TypeTuple.empty` for `Tarray` (and `Tdelegate`),
   so `retStyle()` reports `RET.stack`.
2. `wasmobj.d::isAggregateType`: include `TYullong+Tnext` so `buildFuncType`
   prepends an i32 sret param and drops the i64 result.

`./run.d wasm` regressed 5 runnable tests (`test21429`, `traits_child`,
`test22659`, `ice15030`, `test15862`). Minimal repro:

```d
int[] makeSlice() { static int[3] x = [1,2,3]; return x[]; }
extern(C) int _start() { auto s = makeSlice(); /* read s.length */ }
```

Symptom: `s` is read but never written. `wasm-objdump -d` shows
`call makeSlice; drop;` followed by `local.get 0 ; i32.wrap_i64` from an
uninitialised i64 local. The call wrote to a fresh `_TMP0` shadow slot, not to
`s`.

Root cause: the frontend's slice-init lowering does **not** reach the
`visitAssign` construct-RVO branch at [e2ir.d:2772](../../glue/e2ir.d#L2772).
Debug printf inside that visitor showed, for `auto s = makeSlice()`:
- `ae.op = 79` (construct) ✓
- `e1.op = 14` (variable) ✓
- `t1b.ty = 30` (Tarray) ✓
- `e2.op = 96` (**int64**) ✗ — not a CallExp

So `lastComma(ae.e2).isCallExp()` returned null; the call-RVO path was skipped.
The IR for `_start` ended up containing `call makeSlice _TMP0` as a free-standing
statement with no binding back to `s`. The frontend's lowering for Tarray
initialization with a function call apparently splits init from the call —
fine when Tarray returned i64 in regs (s = i64 result), broken when we route
through sret without also teaching the lowering to use `&s` as ehidden.

Two real paths forward:

### Path A — fix the frontend lowering
Make `ConstructExp(s, callReturningSlice)` reach the RVO path. Risk: changes
to e2ir/dsymbolsem affect every target, not just WASM.

### Path B — keep TYdarray=TYullong in middle-end, transform only at WASM emit (recommended; matches the original "option 1" above)
Confine the sret transform to the WASM backend; the frontend keeps thinking
slices return i64 in regs.

Sketch:
- `wasmobj.d::buildFuncType`: when `ret` is a slice (TYullong+Tnext, not
  delegate), prepend i32 sret param, drop the i64 result. **Do NOT** change
  `isAggregateType` (frontend stays unaware).
- `codgen.d` function prologue: detect slice-returning function; reserve the
  first WASM param (i32) as the sret pointer local; track its index on the
  WasmCG.
- `codgen.d` BC.retexp emission for slice returns: instead of leaving i64 on
  stack to return, store it (as `(ptr<<32)|len` matching the existing pack
  layout — `i64.store` writes len at +0, ptr at +4 LE) to `*sretPtr`, then
  emit empty return.
- `codgen.d` OPcall handling for slice-returning callees: allocate an 8-byte
  scratch slot from the shadow stack; push slot addr as the leading arg;
  after the call, emit `i64.load` from the slot so the i64 value continues
  to flow through downstream IR unchanged.
- Same treatment for delegates if going for LDC parity.

Estimated size: 200–400 lines, all in codgen.d/wasmobj.d. The
[runnable] wasm regression target (`./run.d wasm`, wasmtime-backed) is the
validation loop — exercise it after every step.

### What about commit 3 (slice locals as stack slots)
Stays optional/secondary. Worth ~100 lines once commit 1 is in. The two
register i64 locals plus split-on-load pattern works fine post-commit-1; no
new bugs forced by it.

## Motivation
Today on wasm32 the backend represents a D slice `T[]` as a single i64 register
value with the bit layout `(ptr << 32) | len`. Every call boundary has to
*pack* (OPpair → i64) and *split* (i64 → i32, i32) the slice. Detection of
"this i64 is really a slice" is heuristic — `isSliceElem` looks at `Ety`,
`ET.Tnext`, symbol `Stype.Tnext`, OPpair shape, OPind-of-pointer-to-slice —
and misses real cases (e.g. an OPvar of a temp materialised from an OPcall
returning a slice). Each miss is a silent wasm-ld type-mismatch or a wasmtime
validation error at the use site.

Two structural problems:

1. **Doesn't scale to wasm64.** A wasm64 slice would need i128, which WASM
   doesn't have. Any port would have to do this refactor anyway.
2. **LDC divergence.** LDC uses sret for slice returns and `(i32, i32)` for
   slice params — no packing. Our slice-returning functions are
   ABI-incompatible with LDC-compiled code (documented in `ldc_wasm_abi.md`).

## Target ABI (matches LDC)
- **Slice param** `T[]` → two i32 params `(len, ptr)`.
- **Slice return** `T[]` → sret: hidden first param `i32 sretPtr`, callee
  stores `len` at `+0` and `ptr` at `+4`. Function WASM result type is empty.
- **Delegate** `{ ctx*, funcptr* }` → same treatment (two i32 / sret).
- **Slice local** → either two i32 locals OR an 8-byte stack slot. Pick stack
  slot for simplicity (matches struct lowering already in place).

## Scope of deletions
~100 lines disappear:
- `isSliceElem` (~35 lines) — [codgen.d:1628](codgen.d#L1628)
- `paramIsSlice` (~7 lines) — [codgen.d:1664](codgen.d#L1664)
- `forceSlice` plumbing in `genOneArg` (~10 lines)
- `asSlice` detection + split-on-stack block in direct-call path (~20 lines)
- Prologue split→rejoin loop for split slice params (~25 lines) at
  [codgen.d:2470-2540](codgen.d#L2470-L2540)
- OPpair-pack-to-i64 lowering for slice construction
- Voffset shift/mask for slice field access on i64 locals (~10 lines) around
  [codgen.d:610](codgen.d#L610)
- `collectArgTypes` slice branch in call-indirect (~5 lines)
- `TYdarray == TYullong` mapping in [wasmobj.d:482](../wasmobj.d#L482) — slices
  become a distinct WASM-level concept (struct-by-value, not i64).

## Scope of additions
~80–120 lines:
- **Slice locals as stack slots.** Allocate 8 bytes of shadow stack at function
  entry per slice local. OPvar of slice → address of slot. Field access (`.length`,
  `.ptr`) → ordinary `i32.load offset=0/4`.
- **OPpair lowering for slices.** Currently constructs an i64; change to: allocate
  scratch slot, store len/ptr to it, push slot address. (Or: push len/ptr separately
  if the immediate parent is a call arg — peephole.)
- **Slice arg materialisation.** Before each call, if the source elem is an OPvar
  of a slice slot, emit two `i32.load`s from the slot. If it's an OPpair, just
  emit the two operands. If it's an OPcall returning a slice, the call wrote to a
  caller-supplied sret slot — load len/ptr from that slot.
- **Slice return via sret.** At every slice-returning call site, allocate scratch
  slot, prepend its address as the first arg. After call, the slot holds the slice.
- **Function signature.** When a function returns a slice, prepend `i32` to params
  and drop the result type. Update prologue to remember the sret pointer local.
- **Return statement.** `return slice;` → store len/ptr to the sret pointer; emit
  empty return.

## Middle-end friction (the real cost)
DMD's `elem.Ety` is a single `tym_t`. There's no first-class "2 × i32 aggregate"
concept — slices being i64 is precisely what made them fit. Two options:

1. **Keep TYdarray as TYullong at the elem level, change only at WASM boundary.**
   Backend code that constructs/inspects slices still sees an i64-shaped value;
   the *WASM emit* layer is the one that materialises split params and sret.
   This is closer to the current code; fewer middle-end ripples. Net LOC: probably
   wash.
2. **Introduce a backend-internal "slice ref" tym_t or a stack-slot pseudo-elem.**
   Cleaner, but invasive — affects every cgelem op that handles TYdarray.

Recommend **option 1**: confine the ABI change to wasmobj.d + the call-site /
prologue / return-statement emit paths in codgen.d. Leave middle-end OPpair /
OPvar / OPind semantics alone.

## Suggested commit split
1. **Slice return → sret.** Biggest correctness win (kills OPpair-pack-to-i64
   for returns). Makes us LDC-compatible for returns. Roughly self-contained:
   prologue, return stmt, and call-site sret-slot allocation.
2. **Slice param materialisation cleanup.** Replace `isSliceElem` /
   `paramIsSlice` / `forceSlice` heuristics with a single rule: "if the callee
   param type (or, for varargs, the declared param type at this position) is a
   slice, emit two i32s." For RTL symbols with empty Tparamtypes, prepopulate a
   small prototype table (see `rtlsym.d`) so the rule applies uniformly. Removes
   the largest pile of detection code.
3. **Slice locals → stack slots.** Optional cleanup; the previous two commits
   already deliver the correctness and LDC-parity wins.

## When to actually do this
- Before any wasm64 port (mandatory).
- If two more `_d_arrayboundsp`-class detection bugs show up (the heuristic is
  proving brittle in practice).
- When stabilising the WASM ABI for external consumption (LDC parity matters).

## Open questions
- Delegates: same shape as slices, same treatment. Do them in the same pass?
- `extern(C)` slice params: C doesn't have slices, so no extra ABI work — but
  ensure mangling/sig still matches what wasi-libc et al. import.
- Sret slot lifetime: the caller's scratch slot must outlive the call. If the
  slice result feeds directly into another call, can we reuse the slot or do we
  need two? (Answer: one slot per pending slice value in the expression.)
