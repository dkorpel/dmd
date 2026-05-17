# Slice ABI refactor: rip out i64 packing, treat slices like structs

## Status
**Deferred.** Patching the heuristic detection is shorter today; this refactor is
the right move once wasm64 is on the table or the heuristic keeps regressing.

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
