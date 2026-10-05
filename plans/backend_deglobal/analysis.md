# DMD backend refactoring: analysis and plan

Source: the 361 closed PRs labelled `Compiler:Backend` + `Severity:Refactoring`
(April 2021 to September 2026), plus counts measured at 3f86a3b3a2 (80 files,
about 127k lines in `compiler/src/dmd/backend`).

## Direction of past work

| Theme | Example PRs | Status |
|---|---|---|
| Remove other products' leftovers (SCPP, HTOD, MARS, SPP, OMF, PARSER, hydration, C++ declarations) | #15232, #16898, #16993, #23153, #23387 | Mostly done. Deleted over 15k lines. |
| Replace prototypes with imports; untangle modules (delete `var.d`/`global.d`; merge `dtype` into `type`, `elem` into `el`, `goh` into `go`; `x86/` and `arm/` packages) | #15111..#15262, #23172, #23252..#23266, #16527 | Mostly done |
| Globals into state structs, then the struct as a parameter: `CGstate`, `ElfObj`/`MachObj`/`MscoffObj`, `BlockOpt bo`, `GlobalOptimizer go` (being replaced by a `changes` parameter), `CgElem`, `CGCS` | #16456..#16511, #22954..#23033, #23005..#23011, #23877..#23893 | Active, largest remaining job |
| Pointers to `ref`/`out`; pointer + length to slices | #16698..#16750, #23311..#23331, #20650 | Partly done |
| Linked lists to arrays (Bpred, Bsucc, Tparamtypes, Sfldlst, SEenumlist; `dlist.d` deleted) | #23173..#23244 | Done |
| Manifest constants to D enums, clearer names (SC, GOAL, FL, BC, DT, BFL, Mangle) | #20718, #20724, #23534, #23338 | Partly done |
| Explicit `public`/`private`, private functions "below the fold" | #23103..#23110, #23167, #23272 | Started |
| Local cleanups: `foreach`, localized declarations, `char` to `bool`, `goto` to loops, D pointer syntax, fewer `= void`, `@safe` | #16307, #16581, #23880, #20726, #21107 | Ongoing |

Observations:

- Nearly every PR is a small mechanical edit repeated dozens of times.
- Failures came from size (#15125 rippled and ran CI out of memory) or from
  behaviour changes (Bsucc took three attempts, #23195 to #23209, because
  iteration order changed the generated code; debugged by bisecting the
  hour-long test suite).
- Identical codegen is the correctness criterion for a pure refactor.

## Remaining debt (grep counts)

| Pattern | Count |
|---|---|
| `__gshared` | 175 |
| uses of global `cgstate` | 155 |
| `go.` / `bo.` | 347 / 221 |
| pointer out-parameters / `T**` parameters | ~235 / 33 |
| (pointer, length) parameter pairs | 23 |
| `enum X = ...` manifest constants / anonymous `enum {}` blocks | 314 / 116 |
| `return 0/1` | 99 |
| `version(none)` / `static if(0)` | 143 |
| `@trusted` vs `@safe` | 1077 vs 106 |
| `goto` (489 in disasm86) | 1566 |

## Priority: remove globals

Goal: a re-entrant backend that can run on several threads. The established
pattern is:

1. Gather related globals into a state struct (`CGstate`, `GlobalOptimizer`,
   `BlockOpt`, `ElfObj`, ...), still held in one `__gshared` instance.
2. Pass that instance as a `ref` parameter, starting from leaf functions and
   moving up the call graph, until only the entry point touches the global.
3. Make the entry point own the state (local variable or a context object).

Step 2 is mechanical and is what `compiler/tools/deglobal` automates.

### Tool design

- Analysis uses dmd as a library: every module under `compiler/src/dmd` is a
  root module, run through full semantic with `-debug` enabled so `debug`
  blocks are seen. Output: for each function, which backend globals it uses
  directly, and its resolved callees and call sites (with byte offsets).
- A function is a candidate for one global G when it references G, is not
  address-taken, has no UFCS or unresolved call sites, and all its callers
  are visible. Candidates are processed leaves first: a function whose
  callees no longer use G.
- The rewrite for function F and global G:
  - if F has no parameter of G's type, add `ref T name` as the first parameter;
  - replace every `G` token inside F's body with the parameter name;
  - at each call site insert the caller's parameter if it has one, else `G`.
  This moves the global use up one level per step, so every step compiles.
- Verification: build dmd, compile a fixed corpus with the old and new
  compiler under several flag sets and target OSes, require byte-identical
  object files.

### Not automated

- Gathering loose globals into a struct (naming and grouping are a judgment call).
- Function pointer tables and callbacks (signature change is shared).
- Turning the final global at the entry point into owned state.

## Using the tool

```sh
compiler/tools/deglobal/build.sh                          # builds generated/deglobal/deglobal
generated/deglobal/deglobal report                        # all backend globals by number of users
generated/deglobal/deglobal report --global=cgstate       # per function: leaf?, blocker or "ok"
generated/deglobal/deglobal step --global=cgstate --max=10 [--skip=f,g] [--only=f,g] [--param=cg]
cp generated/linux/release/64/dmd tmp/deglobal/dmd-base   # baseline compiler, before any step
compiler/tools/deglobal/oracle.sh tmp/deglobal/dmd-base   # byte-compare objects: base vs current dmd
compiler/tools/deglobal/loop.sh cgstate 10 5              # 5 rounds of step + build + oracle + commit
```

The parameter name defaults to `cg` for `cgstate` and to the global's own
name otherwise (the existing `ref GlobalOptimizer go` / `ref BlockOpt bo`
convention, where the parameter shadows the global).

Blockers the tool reports instead of editing: address-taken functions,
overloads, templates, virtual functions, non-D linkage, unexplained uses of the
name (anything the semantic pass did not see), and callers that are `@safe` or
`pure` (they may not touch a `__gshared`; those callers must get the parameter
in the same step).

Oracle notes: `SOURCE_DATE_EPOCH` is pinned because of `__TIME__`;
`runnable/test17338.d` is excluded because its MS-COFF output differs from run
to run with the same compiler.

## Status of `cgstate` (2026-10-05)

This branch gave 135 more functions a `ref CGstate cg` parameter (361 in total). Every generated commit builds in release, debug and unittest
mode, and the oracle reports byte-identical objects.

Functions on `compiler/tools/deglobal/keep-cgstate.txt` keep using the global on purpose:

| Function | Reason |
|---|---|
| `getRtlsym`, `getRtlsymPersonality`, `symbol_func` | Read only `fregsaved`, a per-target ABI constant, and fill a global per-target cache. Threading them pulled codegen state into all of glue. `fregsaved` belongs in a target config, not in `CGstate`. |
| `regm_str`, `disassemble` | Debug printing; `regm_str` has its own `__gshared` ring buffer |
| `simplify_code` | Called by `CodeBuilder.gen`; a parameter would change about 400 `cdb.gen(...)` calls. Better: `CodeBuilder` holds a `CGstate*`. |

Still blocked, to do by hand:

- `cgelem.d` `el*` handlers (`elind`, `elstruct`, `elva_start`) sit in a function table and only read
  `cgstate.AArch64` (a target flag) and call `prolog_genva_start`.
- `cv8_outsym` is a callback; `ElfObj/MachObj/MsCoffObj_func_term` are called from the string mixin in `obj.d`.
- `tryMain` in `main.d` calls `backend_init(cgstate, ...)`: the final owner.

Open design question: the call graph reaches codegen from glue IR building. `toElem` emits static locals
through `toObjFile`, and data building (`todt.d`) emits vtables, which generate thunk code through
`toThunkSymbol` and `cod3_thunk`. Two options:

1. Keep threading `cg` through glue (mechanical; touches every `toElem`/`Statement_toIR`/`todt` function).
2. Carry it in `IRState` (already passed everywhere in glue), and defer thunk generation out of data building.
