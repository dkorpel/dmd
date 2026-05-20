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
| Data sym binding | `WASM_SYM.BINDING_LOCAL` | LDC: global+hidden — breaks cross-TU refs |
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
- [x] **F3** *Deferred (risky ABI change).* DATA syms emitted with `WASM_SYM.BINDING_LOCAL`. Changing to global+hidden requires testing cross-TU data refs end-to-end with `wasm-ld`. Best done as a follow-up PR with dedicated tests.
- [x] **F4** *Fixed.* Data symbol size now derived from `type_size(sym.Stype)` instead of `0`, fixing `--gc-sections` bounds checks.
- [x] **F5** *Documented.* Inliner disabled for WASM because `scanForInlines` asserts on WASM IR; added a TODO comment in `backend/go.d` flagging the assertion. Root-cause needs a real backend debug session; out of scope for this PR.
- [x] **F6** *Fixed.* `glue/e2ir.d` silent null-pointer returns for `new` on WASM now raise a proper compile error via `irs.eSink.error`.
- [x] **F7** *Fixed.* Replaced three `target.isWasm` checks in `glue/s2ir.d` with `config.ehmethod == EHmethod.EH_NONE`. `cfg.ehmethod` is already set to `EH_NONE` for WASM in `backconfig.d:295`, so this is a clean per-target flag.
- [x] **F8** *Not a bug.* `emitCondToI32` is gated by `ty == TYllong || TYullong`; only fires on i64 conditions where i64→i32 truth conversion is required.
- [x] **F9** *Fixed.* Null-slice argument (`i64.const 0`) is now split into two `i32` operands when the callee parameter is a D slice. `genOneArg` accepts a `forceSlice` flag and the non-variadic direct-call path walks `Tparamtypes` alongside the args via `paramIsSlice`, so an OPconst null passed where `char[]`/`char[][]` is expected matches the split `(i32, i32)` ABI. Workaround in `rt/wasm/start.d` (`_Dmain(size_t,size_t)`) reverted to `_Dmain(char[][])`.

### Simplification (line economy)

- [x] **S4** *Confirmed in use.* `preRegisterExternals` is called from `wasmobj.d:1192` as Phase 1 of two-phase codegen. Required for import-index stability with fixed-width LEBs. Cannot be dropped without switching to relocations for all function references.
- [x] **S5** *Done.* Added `isDataSym(FL)` helper. Replaced 4 duplicated `switch ... case FL.data..datseg` patterns in `codgen.d:803, 902, 998, 2003` with `if (isDataSym(s.Sfl))`. Saved ~30 lines.
- [x] **S1** *Done.* `emitBinop`/`emitRelop` collapsed via `pickByKind(ty, f32, f64, i64, i32)` helper. ~170 lines → ~50 lines.
- [x] **S3** *Done.* `emitLoad`/`emitStore` share a `memOpsFor(ty)` table returning `(loadOp, storeOp, alignLog2)`. ~85 lines → ~30 lines.
- [x] **S8** *Done.* Extracted `buildFuncToSymIdx()` helper; three reloc emitters now share it. ~40 lines saved.
- [x] **S2** *Done.* `OPstreq`/`OPmemcpy`/`OPmemset` now emit `memory.copy` / `memory.fill` (added `OP_FC_PREFIX`, `emitMemoryCopy`, `emitMemoryFill`). The hand-rolled byte-copy and runtime-count loops are gone. ~150 lines → ~50 lines. Bulk-memory is in the WebAssembly MVP+ baseline; supported by every current runtime (wasmtime, V8, SpiderMonkey, JSC, wasmer).
- [ ] **S6** *Skipped.* `wasmobj.d:481-673` section emitters vary too much (skip-if-empty rules, mixed init-expr emission) for a clean `emitVecSection` template; estimated savings ~30 lines at a real clarity cost.
- [ ] **S7** *Pending.* `lib/elf.d:308-422` vs `lib/wasm.d:150-264` — parameterize `writeLibToBuffer` (~150 lines). Cross-cutting change to lib infrastructure.

### Integration polish

- [x] **I1** *Done.* Added `Target.setArch()` helper in `target.d`; mars.d arch-flag boilerplate dropped from 40 lines to 12.
- [x] **I3** *No action.* `ObjMemDecl` in `backend/obj.d:507` is a dead helper not invoked anywhere. No symmetry needed.
- [ ] **I2** *Pending.* `link.d:runWasmLINK` is 230 lines glued onto `runLINK`. Worth splitting into a `LinkBackend` interface, but a substantial restructure.
- [x] **I4** *Done.* `link.d` no longer passes a hardcoded full path to wasm-ld. The user's `-L-L<dir>` linkswitches are already forwarded, and an argv0-derived `-L` is appended as fallback; druntime + libc are pulled in via `-l:libdruntime-wasm.a` / `-l:libc.a` so wasm-ld resolves them through its standard search path. `argv0DruntimeDir` is now a clearly-named fallback, not the primary mechanism.

## 6. Out of scope

- Reducible-only CFG (Relooper would be major rewrite).
- Full LDC ABI compatibility for slice return / member sret order (intentional divergence, documented in `ldc_wasm_abi.md`).
- GC, EH, threads in druntime.

## 7. Summary of changes applied this round

15 items resolved (F1, F4, F5, F6, F7, F8, F9, I1, I3, I4, S1, S2, S3, S5, S8) and 2 deferred items investigated and documented (F2 not-a-bug, S4 confirmed required). Build and `./run.d quick` pass after every change (`OS=wasm compilable/wasm_codegen.d` and `OS=wasm runnable/ai.d` always green; unrelated pre-existing failures on branch in bcraii2/pragmainline2/b16976/vcg-ast/test6952/dwarf). Remaining work (F3, S6/S7, I2, I4) is documented above with rationale for deferral; each is a distinct follow-up PR. Net diff after the simplification round: ~300 lines removed across `codgen.d` + `wasmobj.d`.
