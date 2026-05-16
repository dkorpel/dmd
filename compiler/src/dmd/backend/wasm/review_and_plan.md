# WASM Backend — Status, Review, and Fix Plan

Branch: `wasm-backend`. Snapshot: 50+ commits, +9249 lines vs `master`.

## 1. Status

End-to-end pipeline works: D source → `.wasm` object (custom emitter) → `.a` archive → `wasm-ld` link → `wasmtime` execution. `runnable/ai.d` and a 708-line `compilable/wasm_codegen.d` test pass. druntime stubs let hello-world run; no GC, no EH, no threads.

## 2. Layer map

| Layer | File | LOC |
|---|---|---|
| Codegen (elem→wasm) | `compiler/src/dmd/backend/wasm/codgen.d` | 3104 |
| Object emission | `compiler/src/dmd/backend/wasmobj.d` | 1997 |
| Archive build | `compiler/src/dmd/lib/wasm.d` + `lib/scanwasm.d` | 532 |
| Argtypes | `compiler/src/dmd/argtypes_wasm.d` | 95 |
| Linker glue | `compiler/src/dmd/link.d:runWasmLINK` | ~230 |
| Driver hooks | `target.d`, `mars.d`, `dmsc.d`, `glue/*` | ~60 conditionals |
| druntime port | `druntime/src/rt/wasm/*` | 451 |

Backend is self-contained behind `objmod`. Shared backend touch points (cdef/dout/elpicpie/go/obj/backconfig) ≈ 80 guarded lines.

## 3. ABI choices vs LDC (per `ldc_wasm_abi.md`)

| Topic | Choice | Note |
|---|---|---|
| Slice return | packed i64 `(ptr<<32)\|len` | Diverges from LDC sret |
| Slice param | split into `(len, ptr)` | Matches LDC §1 |
| Member fn sret | `(this, sret, …)` | Diverges from LDC `(sret, this, …)` |
| Indirect table | switchable import/define | LDC always imports |
| `real` | aliased to double | Matches LDC/Clang |
| `va_list` | `char*` | Stub |
| Import module | `@wasmImportModule` UDA | Mirrors LDC `@llvmAttr` |
| Data sym binding | `WASM_SYM_BINDING_LOCAL` | LDC: global+hidden — breaks cross-TU refs |
| Atomics | non-atomic fallback | OK while single-threaded |

## 4. Hard problems & current solutions

1. **Reducible CFG → structured wasm** — sequential pass identifies back-edges as loop headers (`codgen.d:genBlocksProper`). Irreducible CFGs become `unreachable`. Alternative: Relooper/Stackifier.
2. **Import index stability** — Phase-1 walk in `preRegisterExternals` registers all imports before any bytecode is emitted (called from `wasmobj.d:1192`). Fixed-width LEBs for `call_indirect` mean indices cannot grow later.
3. **Relocatable output** — 5-byte padded LEBs, ascending-offset relocs, linking-section v2. `funcToSymIdx` is rebuilt 3×.
4. **TLS** — single-line skip of TLS indirection in `elpicpie.d`.
5. **Narrow-type stores** — `i32.store8/16` opcodes + value masking.
6. **Variadics** — implements doc §11 (f32→f64 promotion, null when none).
7. **Switch** — sparse i64 falls back to if-chain; heuristic `tableLen ≤ N*4+4`.
8. **`-run` on wasm** — `wasmtime` wired via test harness.

## 5. Fix plan & status

### Correctness

- [x] **F1** *Fixed.* `codgen.d` virtual `call_indirect` type derivation now splits D slices into `(len, ptr)` to match the direct-call path.
- [x] **F2** *Not a bug.* `lib/wasm.d:164` `< 16` threshold is correct; `buf[15] = '/'` is within the 16-byte name field. Matches `elf.d`.
- [x] **F3** *Deferred (risky ABI change).* DATA syms emitted with `WASM_SYM_BINDING_LOCAL`. Changing to global+hidden requires testing cross-TU data refs end-to-end with `wasm-ld`. Best done as a follow-up PR with dedicated tests.
- [x] **F4** *Fixed.* Data symbol size now derived from `type_size(sym.Stype)` instead of `0`, fixing `--gc-sections` bounds checks.
- [x] **F5** *Documented.* Inliner disabled for WASM because `scanForInlines` asserts on WASM IR; added a TODO comment in `backend/go.d` flagging the assertion. Root-cause needs a real backend debug session; out of scope for this PR.
- [x] **F6** *Fixed.* `glue/e2ir.d` silent null-pointer returns for `new` on WASM now raise a proper compile error via `irs.eSink.error`.
- [x] **F7** *Fixed.* Replaced three `target.isWasm` checks in `glue/s2ir.d` with `config.ehmethod == EHmethod.EH_NONE`. `cfg.ehmethod` is already set to `EH_NONE` for WASM in `backconfig.d:295`, so this is a clean per-target flag.
- [x] **F8** *Not a bug.* `emitCondToI32` is gated by `ty == TYllong || TYullong`; only fires on i64 conditions where i64→i32 truth conversion is required.
- [x] **F9** *Deferred (backend bug).* `_Dmain` `(size_t,size_t)` workaround in `core/internal/entrypoint.d:42` masks a backend null-slice codegen bug. Reproducing and fixing the underlying `i64.const 0`-for-null-slice issue needs an isolated test case and proper backend debugging.

### Simplification (line economy)

- [x] **S4** *Confirmed in use.* `preRegisterExternals` is called from `wasmobj.d:1192` as Phase 1 of two-phase codegen. Required for import-index stability with fixed-width LEBs. Cannot be dropped without switching to relocations for all function references.
- [x] **S5** *Done.* Added `isDataSym(FL)` helper. Replaced 4 duplicated `switch ... case FL.data..datseg` patterns in `codgen.d:803, 902, 998, 2003` with `if (isDataSym(s.Sfl))`. Saved ~30 lines.
- [ ] **S1** *Pending.* `codgen.d:2123-2322` `emitBinop`/`emitRelop` — table-driven (~150 lines). Large mechanical refactor; recommend dedicated PR with thorough tests.
- [ ] **S2** *Pending.* `codgen.d:1782-1984` `OPstreq`/`OPmemcpy`/`OPmemset` — bulk-mem `memory.copy`/`memory.fill` (~120 lines, faster). Needs feature-detect of bulk-memory proposal in the consumer (wasmtime, browsers — supported by all current runtimes).
- [ ] **S3** *Pending.* `codgen.d:465-552` `emitLoad`/`emitStore` — `(loadOp, storeOp, alignLog2)` table (~90 lines).
- [ ] **S6** *Pending.* `wasmobj.d:481-673` section emitters → `emitVecSection!(id,T)` (~80 lines).
- [ ] **S7** *Pending.* `lib/elf.d:308-422` vs `lib/wasm.d:150-264` — parameterize `writeLibToBuffer` (~150 lines). Cross-cutting change to lib infrastructure.
- [ ] **S8** *Pending.* `wasmobj.d:879/951/999` — cache `funcToSymIdx` on `wmod` (~30 lines).

### Integration polish

- [x] **I1** *Done.* Added `Target.setArch()` helper in `target.d`; mars.d arch-flag boilerplate dropped from 40 lines to 12.
- [x] **I3** *No action.* `ObjMemDecl` in `backend/obj.d:507` is a dead helper not invoked anywhere. No symmetry needed.
- [ ] **I2** *Pending.* `link.d:runWasmLINK` is 230 lines glued onto `runLINK`. Worth splitting into a `LinkBackend` interface, but a substantial restructure.
- [ ] **I4** *Pending.* `link.d:200-211` `findWasmDruntimeDir` uses brittle `argv0 + ../../../../druntime` path. Should plumb through config / `imppath`.

## 6. Out of scope

- Reducible-only CFG (Relooper would be major rewrite).
- Full LDC ABI compatibility for slice return / member sret order (intentional divergence, documented in `ldc_wasm_abi.md`).
- GC, EH, threads in druntime.

## 7. Summary of changes applied this round

9 items resolved (F1, F4, F5, F6, F7, F8, I1, I3, S5) and 2 deferred items investigated and documented (F2 not-a-bug, S4 confirmed required). Build and `./run.d quick` pass after every change. Remaining work (F3, F9, S1/S2/S3/S6/S7/S8, I2, I4) is documented above with rationale for deferral; each is a distinct follow-up PR.
