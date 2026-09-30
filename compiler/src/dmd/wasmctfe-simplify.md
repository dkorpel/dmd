# WASM CTFE: simplification findings that were not applied

The commits on the `wasm-ctfe` branch were reviewed newest to oldest for reuse,
simplification, efficiency and altitude (fixing at the right depth). Findings
that were applied are in the `wasmctfe: ...` simplification commits. This file
lists the findings that were *not* applied, and why, so they can be picked up
later.

A finding was skipped when its fix would change intended behaviour, needed
changes well outside the reviewed commits, was a redesign and not a cleanup, or
turned out to be a false positive.

Each section names the commits that were reviewed and the commit that holds the
applied fixes.

## Open questions and possible bugs

These came up during the reviews. None of them was verified or fixed.

- **Module cache stays off after one circular-initialization error.**
  `ipCircularVars` is never emptied, so the module cache is disabled for the
  rest of the compilation. A per-build flag is not obviously safe, because a
  cached module could miss a circular read that begins later. This is the
  largest efficiency item left.
- **Reserved address layout overlaps under `-m32`.** A tagged pointer could
  decode as `null`. There is no single definition of the reserved addresses.
- **String literals are recognised by a trailing zero.** A
  `static immutable int[3] a = [1, 2, 0]` could trigger a false out-of-bounds
  error. Flagging string literals when they are emitted would fix it.
- **SLEB relocations are detected in `selflink.d` by checking the previous
  byte.** Regular `wasm-ld` output could encode addresses of 2^31 and above
  wrongly. Emitting SLEB relocations in `codgen.d` changes non-CTFE output.
- **Retries never delete the old compiled module.** Each lazy-virtual or stub
  retry leaks one `wasmtime` module.
- **The interpreter does not flag `y >>= 70`, the engine does.** No test covers
  shift-range errors.
- **druntime and Phobos do not build with the strict engine.** A
  semantic-only build of the library sources gives
  `core/internal/gc/proxy.d(26): wasm-ctfe cannot evaluate 'cast(GC)new ProtoGC'`
  (the build has an unresolved `stderr`),
  `std/datetime/timezone.d(1122): wasm-ctfe cannot evaluate 'new immutable(LocalTime)'`
  and an `Error: unknown` for
  `_d_aaIn!(const(JSONValue)[string], ...)` in `std/json.d`. The same three
  errors appear with the compiler from before the simplification commits
  (643dff209b). Both libraries build with `DMD_CTFE=verify` (no mismatches)
  and `DMD_CTFE=off`. `tmp/simplify/libcheck.sh` runs this check.
- **An array literal of structs returned from a lambda cannot be evaluated.**
  `enum S[] a = () { return [S(1, "a"), S(2, "b")]; }();` with
  `struct S { int a; string s; }` fails in strict mode; the build skips
  `TypeInfo_Const`, `TypeInfo_Array` and `TypeInfo_Invariant` as "not ready".
- **`is` on two float arrays poisons the build**, so a function that compares
  `double[]` slices with `is` cannot be evaluated by the engine.
- **`typeid(C).name` is computed three ways.** The interpreter uses
  `toPrettyChars()`, the class info uses `toPrettyChars(true, true)` and skips
  `TypeInfo_` classes, and `wasmCtfeFindClass` uses `toPrettyChars(true, true)`
  without that exception. For a template class the interpreter and the engine
  can return different names.
- **`a ~ f(a)` is evaluated in a different order by the engine and by native
  code.** The engine order is patched in glue by rewriting the AST during code
  generation. Fixing the order in the lowering (`lowerToArrayCat`) would make
  both agree but changes native behaviour.
- **Verify mode skips the comparison whenever the AST interpreter errored.**
  `wasmctfe.md` calls this a stop-gap until the legality scan runs in the
  in-process path, which it does since 7b2efa852e. "The interpreter errored
  and the engine returned a value" is the accepts-invalid case verify mode
  should report. Removing the skip needs a triage of the new mismatch lines in
  `fail_compilation`.
- **The wasm signature of `_memsetn` follows the glue, not druntime.** The
  count is `size_t` in the runtime-symbol table since e40df7f3ca, while
  `rt/memset.d` declares `int count`. Changing druntime to `size_t` would make
  all three agree.
- **Float fills go through a host hook with a guessed stride.**
  `ipHostMemsetT` takes the element size from the wasm value kind. A soft
  `real` is 12 bytes under `-m32` but is passed as a 16-byte value, so a
  `real[]` fill there may use the wrong stride. `_memsetSIMD` has no hook, and
  the hook names `_memset16ii` to `_memset128ii` cannot be reached.
- **Temporary symbol numbers in host object files depend on engine builds.**
  The `_TMP` counter is shared, so a change in how many temporaries an engine
  build creates renumbers the host's symbols. The object files are otherwise
  identical.
- **Verify mode hands an error expression to the engine.** When the AST
  interpreter fails an enum initializer and the enum is used later
  (`enum v = f(); pragma(msg, v);`), the engine build hits the `assert` in the
  default `visit(Expression)` of `e2ir.d`. Seen with `core.math.rint` on a
  `real`, which the engine evaluates and the AST interpreter rejects.
- **The engine is compiled in, linked and enabled by three different
  conditions.** `build.d` links libwasmtime on `linux`, the engine code is
  compiled unless `NoBackend` is set, and the mode defaults to strict on
  `Posix`. macOS and the BSDs get the engine enabled without the library, and
  the dub build has no link flag. One version identifier set by the build
  script would cover all three.
- **A TypeInfo may be emitted twice in an engine build**, once by
  `TypeInfo_toObjFile` and once when the work list pops the declaration that
  `toSymbol` queued. The two are deduplicated by different flags.
- **`sqrt(double) + fabs(sin(double))` in a loop fails** with "wasm-ctfe cannot
  evaluate". It fails the same way before the simplification commits.
- **A ctfe-only lambda that loops over an outer const array fails.**
  `enum e = (() { int t; foreach (x; array) t += x; return t; })();` inside a
  function with `immutable int[4] array = 3;` gives "wasm-ctfe cannot
  evaluate". Indexing the array from such a lambda works.
- **A nested static array outer const may be filled only in its outer
  dimension.** `visitSymbol` in `e2ir.d` passes the outer `dim` with the
  scalar's type to `setArray` for `const int[2][3] a = 0`.
- **Engine builds are refused for everything a host function defers.**
  `hostFuncDepth` is non-zero for the whole of `FuncDeclaration_toObjFile`,
  including the loop that emits function-local classes and structs after
  `writefunc`. A local class whose `finishVtbl` needs CTFE is therefore refused
  and the root function stays failed.
- **Runtime-library symbols created by an engine build are reused by the
  host.** Only builds during host codegen get their own `rtlsym` table. A
  symbol first created by an earlier engine build keeps the wasm type, name
  and saved-register mask. ELF on x86-64 does not notice; Mach-O and AArch64
  hosts might.
- **A vector literal counts as a literal without looking at its elements.**
  `cast(int4) [f(), 1, 2, 3]` is returned as-is in strict mode, with `f()`
  not evaluated. Recursing into the operand in `ipIsLiteral` would fix it.
- **A scalar operand with a call is evaluated once per element in an unrolled
  array operation.** `a[] * f()` runs `f()` n times. Avoiding it needs a
  temporary.
- **The bucket-walk fallback of `ipDecodeAA` finds no entries under `-m32`.**
  It tests the filled mark with `cast(long) hash < 0`, but the hash is read
  zero-extended from 4 bytes. It only matters when the order table has no
  entry for the AA.
- **The verify-mode comparison treats results nested deeper than 200 levels as
  equal.** `ipResultEqual` stops cycles through pointers into arrays with a
  depth cap, while struct literals use the pair stack. Using the stack for
  array literals too would compare deep results for real.
- **The `hdrgen.d` null guard fixes a bug that also exists on master.**
  `-ftime-trace` prints an enum while its members are still being analysed. It
  could go upstream as its own fix.
- **Self-linking never gathers the ModuleInfo array.** `gatherMinfo` looks for
  segments named `minfo` and `linkerSymbolAddr` resolves `__start_minfo` and
  `__stop_minfo`. The object writer names the segment `__minfo` and
  `rt/sections_wasm.d` references `__start___minfo` and `__stop___minfo`
  (renamed in f1063afe46, before the self-link port). A `-mwasm-selflink`
  build with druntime would report the two symbols as undefined; the only test
  is `-betterC`. `gatherMinfo` also aligns the array for 4-byte pointers under
  wasm64 and allocates a buffer for every module before it knows there is
  anything to gather. One shared name constant would fix the mismatch, but
  that changes self-link output.
- **Data relocations are applied before the layout exists.** `selfLink` runs
  `applyDataRelocs` before `computeLayout`, so a static initializer such as
  `__gshared void* p = &__heap_base;` gets address 0 without a diagnostic.
  Code relocations see the final layout.
- **wasm64 code relocations keep the 32-bit relocation types.**
  `MEMORY_ADDR_LEB` and `TABLE_INDEX_SLEB` are written to `reloc.CODE` for
  10-byte fields, and `wat.d` advances 5 bytes per relocation. The width is
  derived from `I64()` in `RelocOp.emit` and `patchSelfLinkCodeRelocs`.
  Picking `MEMORY_ADDR_LEB64` / `TABLE_INDEX_SLEB64` when the relocation is
  created, as the data relocations do, would carry the width in the type.
- **`-mwasm64` is only half a switch.** It has no entry in `cli.d` and is
  missing from `parse_arch_arg` in `mars.d`. `-os=wasi` after `-mwasm64` sets
  the architecture back to wasm32 without a message. `runnable/hello.d` hits
  `assert(0)` in the conversion table of `codgen.d` with `-mwasm64`, and the
  CTFE engine cannot evaluate calls for that target
  (`runnable/testaa.d`: "wasm-ctfe cannot evaluate `test6178a()`").
- **The flush at exit sits in the shared `_start`.** `rt/wasm/start.d` calls
  `fflush(null)` after `__wasm_call_dtors` for every link mode. Only the empty
  self-link stub of `__wasm_call_dtors` in `rt/wasm/selflink.d` needs it; with
  wasi-libc the real function already flushes. The stubs
  `_d_eh_swapContext` and `_d_eh_swapContextDwarf` in the same file cover a
  gap of the whole wasm target (`rt.dwarfeh` is not in the archive) for one
  link mode only.
- **Unresolved self-link symbols are reported by the link step.** With `-c`
  the module is written with address 0 for them and no error. Reporting in
  `obj_end` would cover both, but makes `-c` fail where it succeeds today.

## b59c4b7545, 6cfaa2bd1f (fixes in 9807fbec93)

- **Copy-on-change helper in `ipSubstConstVars`.** Copying lazily came out no
  shorter. Copying every node up front would permanently allocate a copy of
  each large literal root.
- **Reusing optimize's `expandVar` or `wasmCtfeOuterConstInit` for the variable
  lookup.** The first changes shared `optimize.d`. The second changes which
  variables get folded (construct/blit unwrapping, `inuse`).
- **Dropping the `wasmCtfeBuildActive` qualifier on the `setEthis` guard in
  `toir.d`.** It would change shared glue code on native builds.
- **Always putting arguments on the bump heap.** Memory would grow on every
  call. The `65536` threshold is still an unnamed constant.
- **Reusing the name→address map from `applyDataRelocs`.** It is built before
  layout, so its offsets are not final.
- **Not deep-copying `StringExp` results; skipping optimize when the root is a
  bare `VarExp`.** Small gains, and the first could expose shared string
  buffers.
- **Moving the data extents onto `WasmModule`; replacing the four per-call
  copies of module state with one pointer.** This pattern predates the reviewed
  commits.

## ee6c843d9b, 1596df9f78, 0193c20703 (fixes in 77bdc3ef95)

- **Undoing the operand reversal for all binary intrinsics in one place.** This
  is the deeper fix for the bit-op and `OPyl2x`/`OPscale` swaps, but it changes
  the operand order the x86 backend sees.
- **Sharing the hidden-context-pointer fill with the interpreter's
  `visit(StructLiteralExp)`.** The interpreter allocates from the CTFE region
  and copies arrays only on modification; sharing means changing its hot path.
- **Copy-on-write in `ctfeLiteral`.** `scrubReturnValue` modifies literals in
  place.
- **Growing the last heap block in place and recording its 16-byte-rounded
  size.** Changes how the heap allocates.
- **One reusable spine buffer in `WasmCG`.** A buffer is only allocated when a
  comma chain is nested on the left, so there is little to save.

## 4f03986ce9 (fixes in 678a7e2830)

- **Replaying the whole call on an uncaught exception.** Recording the last
  throw instead changes which memory state the error message decodes from.
  Re-running the AST interpreter on errors changes the strict-mode design.
- **Classifying errors once in the legality scan; a parent-expression stack on
  `IRState` instead of the glue globals; deriving call sites from source
  positions instead of the `elem` field.** Structural rewrites.
- **`ipBadPointerCast` copies dinterpret's pointer-cast rules.** Sharing them
  means refactoring `dinterpret.d`.
- **`getTypePointerBitmap` for the pointer-offset code.** It has different
  rules for `void` and delegates.
- **`generateUncaughtError` for the uncaught message.** It would change the
  call-trace output.
- **Merging `ipCheckNewClass` with `wasmCtfeNewCircular`.** They check fields
  in a different order, and the second records circular variables as a side
  effect.
- **Union tag table is a linear scan over up to 1024 tags.** Needs a new data
  structure.
- **Merging the error and trap branches after the wasm call.** Their verbose
  output and replay logic differ.
- **Folding the three root pre-scans into one walk.** They depend on running in
  order.
- **Parallel site arrays as one struct; passing the call site to `callfunc` as
  a parameter; the debug-only formatted trap messages.** Low value.

## ae633291b3 (fixes in 47bb89fd76)

- **One `if (!__ctfe)` check inside `accumulatePure` instead of the 11 guards
  in `profile_gc.d`.** The guards let the engine drop the `scope(exit)` blocks
  entirely.
- **No null checks in trusted druntime code or on `&local.method()` calls.**
  Bad pointers inside druntime would read memory silently.
- **Codegen using `ipCtfeCond`.** Changes what gets pruned.
- **`constfold.Equal`/`Identity` instead of `ipLiteralCompare`.** They compare
  struct fields differently.
- **Chaining exceptions in druntime instead of on the host.** Affects all wasm
  builds.
- **Counting `-cov=ctfe` in linear memory instead of one host call per
  statement.** Redesign.
- **Symbol flags in the data extents instead of the name-keyed tables.**
  Redesign.
- **A private copy of `global.params` for the engine instead of temporarily
  overriding the global settings.** Redesign.
- **Merging the three append implementations.** Redesign.
- **Compiling `_d_invariant` into the module.** Redesign.
- **Compact save/restore of the four `global.params` fields; the `-cov=ctfe`
  module list scan; the optimize call that runs twice on a rare path; reusing
  scratch locals for `-m32` `real` stores; `ipLdP` without `memcpy`.** Low
  value.
- **Merging `ipNestedCallable` and `ipNestedFrameFree`.** They look alike but
  check different things.

## 3ea9f1efae (fixes in a77d6abf43)

- **`tinst = null` instead of the `ctfeOnly` field.** Loses the "instantiated
  from" trace in errors.
- **The explicit hook list instead of the `"_d_"` prefix, without the betterC
  gate.** Changes `@nogc` checking and inference in normal builds.
- **Decoding class `vthis` as null in `ipDecodeClassRef`.** A real outer-object
  reference could be lost.
- **Merging `ipCircularVar` with the other four pre-scan walks or with the
  legality scanner.** Much refactoring, and the two circularity checks do not
  treat the same variables as circular.
- **A shared helper for the index-to-field walk; one classifier for global
  access.** Touch code outside the commit.
- **A visited-pair set that lasts for the whole comparison.** Changes the
  comparison semantics.
- **A symbol flag instead of the entry-point names in `buildFuncType`.**
  Redesign.
- **Building the call-path cache key once instead of on every retry.** Predates
  the commit.

## 8d2a4257fd, 87e47fd1dc, 21d4cf1d33 (fixes in 3b2d439298)

- **Caching modules that contain stubs.** A cached stub could outlive a rebuild
  that would have resolved it.
- **Handling a failed function locally instead of rerunning the whole build;
  merging the stub, error and no-body maps.** Redesigns.
- **`expandVar` instead of `getConstInitializer` in `e2ir.d`.** `expandVar`
  folds fewer kinds of initializer.
- **`utf_encode` in the `appendC` encoder.** It asserts on an invalid `dchar`.
- **Replacing the `classRefSeen` hash map; growing `realloc` in place; parsing
  the `_aApply` name once.** Small gains for extra code.

## 26bf547ba6, 4227f8d219, 0d9f36abed (fixes in e404b6f5c3)

- **Keeping the wasmtime linker per module; caching builtin arguments; caching
  the memory export.** Redesigns of code mostly outside the batch.
- **Batching lazy virtuals before one rebuild.** Redesign.
- **`useGC = true` during the build instead of the five `e2ir.d` checks.**
  Semantic analysis that runs during a build would skip betterC diagnostics
  permanently.
- **`eval_builtin` instead of the soft-real math imports; a host
  `_d_callfinalizer` instead of `scopeNewClass`.** Larger reworks.
- **`wasmCtfeAggReady` walking base-class fields.** Larger rework.
- **`emitStore` in `genVarArgs`.** 12-byte soft reals would get different
  stores.
- **Keying vtbls by `toVtblSymbol`'s name in `wasmCtfeRecordClass`.** A cached
  vtbl symbol can be created outside the build and skip the recording.
- **Dropping the `oldVtblCtx` save/restore in `toobj.d`.** Not clearly safe.
- **Dropping the `ipLazyHit` resets.** They keep nested CTFE calls from seeing
  a stale value.
- **Removing the ClassInfo-name fallback; restoring the plain asserts.** Not
  verified to be dead.
- **One registry for the four name→function maps; a has-subclass set.**
  Redesigns.
- **Moving the builtin shortcut out of `tryWasmCtfeInprocOnce`.** Changes the
  order of checks.

## b183f6379f, b770e0e760, bbfee4f85a (fixes in ca077f4d65)

- **Materializing an outer const once per function instead of once per
  reference (`visitSymbol` in `e2ir.d`).** Every reference builds a fresh
  temporary and re-evaluates the initializer, so a loop over an outer const
  array is quadratic. Hoisting the initializer to function entry changes when
  it runs, and an initializer that traps would then fail calls that never read
  the variable.
- **`wasmCtfeOuterConstInit` returning a complete value (array literal for a
  scalar-initialized static array) so the glue only calls `toElem` and
  `addressElem`.** A plain read would yield an rvalue instead of
  `(tmp = init, tmp)`, and a large `const T[N] a = x` would allocate an
  N-element literal.
- **A synthetic `VarDeclaration` plus `visitAssign` for the same code.**
  `visitAssign` constructs struct literals in place and may call constructors
  where the current code copies a value.
- **`v._init.semanticDone` in `wasmCtfeAggReady` instead of re-folding the
  initializer and checking for five literal kinds.** Looks like the right test,
  but it makes more aggregates ready on a repeat visit (array initializers, AA
  literals, `&global`, function pointers).
- **Inline `v128.xor`/`v128.and` for soft-real negation, `fabs` and the truth
  test.** They only touch the sign bit, so the host call is avoidable, but it
  changes codegen and the padding bytes of the result.
- **Only the interface part of the early return in `ipDecodeClassRef`.** The
  exact vtbl lookup could then decode classes with subclasses in builds without
  `TypeInfo_Class`, which is a behaviour change. The `wasmCtfeHasSubclass` scan
  can also run twice there.
- **The soft-real imports as 24 `RTLSYM` entries instead of the cache in
  `softreal.d`.** One mechanism instead of two, but no fewer lines, and the
  host still needs the name table.
- **`ipEncodeArg` calling `ipEncodeVal` per element.** Not needed after both
  got the shared `ipPutFloat`.

## a1e6f6a051 (fixes in e9db998e39)

- **Tracking the live per-function backend state instead of the call depth, and
  reusing the function's own `deferToObj` list for deferred TypeInfos.** The
  right depth for the refusal (see the open question above), but it makes
  engine builds accepted in places where they are refused today, and it changes
  the order of TypeInfo data in the host object.
- **Stashing the host backend tables for every engine build, not only during
  host codegen.** Removes the second code path, but moves all builds during
  semantic to separate tables and changes which `rtlsym` symbols the host gets.
- **Recording host symbols only where they are created.** Changes which symbols
  are stashed in multi-object builds.
- **Keeping the capacity of the stash scratch arrays and swapping `SegData`
  instead of starting from `.init`.** The allocation only leaks on the rare
  host-codegen path.
- **One `takeGlueCaches` helper shared with `wasmCtfeWipeCaches`.** The stash
  and unstash pair became one exchange function instead.
- **`verifyHookExist` calling the new quiet hook lookup.** Touches an upstream
  function. The lookup also still runs up to three times for one `~=`.
- **Returning "already a literal" from the engine instead of walking the
  expression again on the `null` path.** The strict-mode decision now sits at
  the single exit of `tryWasmCtfe`, but the walk is still a second one.
- **Finding all functions that need semantic3 in one build attempt.** Each
  attempt finds only the next layer, so a call chain of depth k needs k+1
  builds (limit 64). Redesign.

## 04d80e220c, 9055d76cdd (fixes in 208cacba49)

One fix changed behaviour on purpose: the address of the AA order table now
comes from the data extents. The probe it replaces was switched off by a nested
build, so an AA result could come back in bucket order (a mismatch in verify
mode).

- **Dropping `wasmCtfeBuiltFuncs` in favour of the list of functions that got
  code (`wasmCtfeObjMarked`).** The first list also holds functions that return
  before code generation, so a pointer to such a function would stop decoding.
- **`isOverlappedWith` in `ipOverlapDominated`.** It compares bit ranges, so
  bit-fields that share a storage unit in a union would both be decoded.
- **`isUnaArrayOp`/`isBinArrayOp` from `arrayop.d` in `ipIsArrayOpNode`, and
  dropping the shift operators.** The shifts look unreachable for array
  operands, but that was not verified.
- **One `wasmCtfeNewItem` helper for all engine-build allocations in
  `e2ir.d`.** The pointer branch now reuses the existing store code and the
  struct branch uses the class branch's form; the five
  `_d_allocmemory` call expressions are still written out.
- **Recording function names in `selfLink` only on request, and building the
  table-slot map on the first function pointer decode.** Needs a new switch;
  small gain.
- **One pass over tuple elements in `tryWasmCtfeExpr`.** The remaining double
  walk is only over all-literal prefixes.
- **The defensive null checks at the top of `ipDecodePtr` and `ipDecodeAA`.**
  They cannot fail with the single caller they have now; kept for future
  callers.

## d3f170a527, 0da34a1ed1, 54527b69ff, f530c3c97a, b8b37777c2, 80e704019e, 3ccbb61acb, b0fd813fbf, 64eecd12f9, b43ad693e1, b45f7f59b6, 50d81ec66f, 296cc8cca7, 5c152935ae (fixes in c1ba8dbc1a)

One fix repairs a regression from e404b6f5c3. That commit marked every
function of a retry round as "semantic3 tried" before forcing any of them. A
nested build started by the first forced function then skipped the others and
failed with an unimplemented runtime call (seen when building druntime:
`core.lifetime.emplace!(OutOfMemoryError, ...)` hit a static assert). Functions
are marked one at a time again.

- **Array `is` through `visitEqual`.** The hand-built length and `memcmp`
  compare in `visitIdentity` could call the equality code, but that changes the
  element type and adds a short-circuit on equal pointers.
- **`elAssign` in `visitCat`.** The temporary copy builds `OPstreq` by hand.
  `elAssign` types a static array copy as `TYstruct` and takes the C type from
  the D type, so the generated element differs.
- **`wasmCtfeAggReady` through `getConstInitializer`.** The helper reports
  errors of non-speculative members for real, lowers static AAs and clears the
  scope on error; the hand-written block does none of these. Field
  initializers still get semantic by three routes (`wasmCtfeAggReady`,
  `membersToDt`, `ipInitConstInitializer`).
- **`arrayop.d` predicates in the legality scan.** The operator list in
  `Scan.visit(BinExp)` is no shorter when written with them.
- **Typeid identity fold through `ctfeIdentity`.** It asserts that both
  operands are types, so the `isType` guards stay and nothing gets shorter.
- **Linear search in the AA order table, and a "last entry" shortcut.**
  `ctfeOrderSlot` scans all tables on every AA operation. A shortcut needs a
  second global in `newaa.d`.
- **A pointer-compare pass in `unparkWasmCtfe` before the associative-array
  fixpoint.** The cost of the current loop was not measured, and the pass adds
  a second walk of the same list.
- **A name cache for `wasmCtfeFindClass`.** It is only used when a class
  result is decoded.
- **A scope-based "guest instance" test in place of `buildActiveSuspended`.**
  Six sites keep the suspension counter balanced and two of them use different
  tests for "host rooted". Deriving it from the scope is a redesign of how
  template instances are assigned to modules.
- **Lowering `new` and array literals in ctfe scopes in the frontend.** The
  glue allocates by hand when no lowering exists, and the legality scan lists
  the supported shapes. Using the frontend lowering there would remove both,
  but it changes which hooks engine builds call.
- **No parameter registers for wasm.** `visitSymbol` tests `SC.fastpar` for
  every target to cover a wasm-only state. The test for `SC.regpar`, which is
  never assigned, was dropped; the rest needs a backend change.
- **A `genElemAs` helper in `codgen.d`.** Would touch code from before these
  commits.
- **Typeid fold in glue.** Moving the fold out of `tryWasmCtfeExpr` changes
  which expressions reach the engine.

## c185ce6596, 7b2efa852e, abacf08325, 53c6f80de0, dbc78f622f, 3d4fa81d8d, e40df7f3ca, ddae26a150 (fixes in 4f8985713b)

The virtual call path in `e2ir.d` has its upstream assert back
(`tysize(TYnptr) == 4` on 32-bit x86). It holds during engine builds because a
32-bit target gets a wasm32 module.

- **A "caller memory or trap" helper for the host hooks.** Every hook fetches
  the memory and returns a trap when there is none. A helper saves no lines,
  because each hook still needs its own early return.
- **One fill routine behind `ipHostMemsetn` and `ipHostMemsetT`.** The two
  check bounds in a different order, treat a zero element size differently
  and print different trap texts.
- **Filling by doubling the copied prefix.** Both hooks copy one element at a
  time. Doubling is wrong when the value of `_memsetn` lies inside the
  destination, and the cost was not measured.
- **Removing `ipHostMemsetT`.** `setArray` could send float and `real` fills
  to the inline `OPmemset` loop of the wasm backend. That changes the
  generated code of engine builds and of real wasm builds.
- **One error path in the epilogue of `wasmCtfeGenerateOnce`.** The gagged and
  the `DMD_CTFE_SHOWGAG` branch both end in "poison when errors were raised",
  but `endGagging` counts gagged errors and the other branch counts reported
  ones. They are not equal when a nested build reports an error ungagged.
- **No result cache for expression wrappers.** Each wrapped expression stores
  a cache entry that is rarely hit. Opting out needs a parameter through two
  functions, and the cost was not measured.
- **Raw locations and length-prefixed strings in cache keys.** Both would make
  keys shorter to build, but they change which calls share an entry.
- **A `wide` flag in `HostImport`.** `ipHostArrayAppendC` compares the import
  name on every call to tell `_d_arrayappendwd` from `_d_arrayappendcd`. A
  flag saves one string compare per append.
- **`elAssign` in `Dsymbol_toElem`.** The initializer copy builds `OPstreq` by
  hand; `elAssign` produces a different element for static arrays.
- **The re-append condition in `templateInstanceSemantic`.** Two tests cover
  what one invariant ("the primary instance sits in a non-root module") could
  express. The rewrite touches upstream logic.

## cce6e02dfd, d392e7b071, 7436614c60, e72e48a342, e87ea5c69f, 1705c07d23 (fixes in 4b9560ea0b)

Two fixes change behaviour. Host imports are linked with the function type
the module declares, so a call to a function with more than 16 parameters no
longer fails with "cannot evaluate". The per-call import records are freed
after the call and no longer pile up in the cached module.

- **Resolving host imports once per module.** Which host function an import
  binds to is worked out again on every call. Doing it when the module is
  created moves the lookup in the glue tables (stubs, error functions, lazy
  functions) from call time to build time.
- **A width-neutral `DataReloc`.** The record could store "function or data"
  and leave the 32 or 64-bit wire type to the one writer. The emitter and the
  two predicates that were added cover the duplication; changing the record
  touches the object writer from before these commits.
- **`needsCodegen` outside the `pure` block of `Scope`.**
  `wasmCtfeLoweringActive` casts `wasmCtfeMode` to `pure` so that
  `Scope.needsCodegen` can stay under the attribute label. Moving the function
  above the label removes the cast but moves upstream code.
- **Recording rejected symbols in `wasmCtfeQueueDefinition`.** A symbol that
  is not queued is classified again on every reference. Remembering the
  rejection is only valid for the reasons that cannot change during a build,
  and the lazy-virtual branch must stay out.
- **A return-style predicate that does not allocate.** `toArgTypes_wasm`
  allocates a `TypeTuple` per query. A predicate would have to repeat its
  type tests. The rule is now in one place (`isReturnOnStack_wasm`), which
  still allocates.
- **The `sret` test in `tryWasmCtfeInprocOnce`.** It lists the type kinds by
  hand where it could ask `isReturnOnStack_wasm`. The list also decides how
  the result is decoded.
- **`relOp` for the 128-bit compare in `emitRelop`.** The four-line opcode
  table could be two calls to the nested `relOp` after moving it up. That is
  not shorter.
- **Unused members of partly used enums in `wasmtimec.d`**
  (`WASMTIME_EXTERNREF`, `WASMTIME_EXTERN_TAG`, ...) and
  `R_WASM.MEMORY_ADDR_LEB64`. They keep the numbering complete.
- **"Memory or trap" prologue of the host hooks.** See the batch above; the
  hooks that only format a message now share `ipCallerMem` and `ipTrapf`.

## ef17b5f61f, a68516fa69, 4cb4ea763d, 12d7c683ba, 7d8d2e855d (fixes in ecdc3fc9a5)

Three fixes repair leftovers of the self-link port (4cb4ea763d). The
merge-conflict marker in a doc comment of `link.d` is gone, together with the
`wasm-opt` sentence and the unused `verbose` parameter of
`finishWasmSelfLink`. `rt/wasm/start.d` declares `fflush` again; the port
dropped the declaration, so the wasm druntime did not compile. The wasm
druntime archive was not rebuilt. `addWasmSelfLinkRuntimeRoots` searches
`global.importPaths` through the array overload of `FileName.searchPath`, so
an import directory with a `:` in its name is no longer split.

Output was compared with the compiler from the commit before: wasm32 and
wasm64 objects, self-linked modules and the modules of the CTFE engine
(`DMD_CTFE_KEEP`) are byte-identical (`tmp/simplify/wobjcmp.sh`,
`wobjcmp64.sh`, `modcmp.sh`).

- **Self-link switches that nothing in this tree sets.**
  `wasmSelfLinkDataBase`, `wasmSelfLinkImportMemory`,
  `wasmSelfLinkDataSymbols` and `wasmSelfLinkStackSize` are only read here.
  Folding their branches removes eight conditions in `obj.d` and
  `selflink.d`. The browser explorer on the `wasm-web-app` branch sets them,
  and removing them makes every merge between the branches conflict.
- **`emitLoad` / `emitStore` for pointer loads and stores.** Ten sites in
  `codgen.d` write `OP_PTR_LOAD, Uleb(PTR_ALIGN), Uleb(off)` inside a longer
  `cg.emit(...)` call. `cg.emitLoad(TYnptr, off)` emits the same bytes but
  splits each call in two, so the code gets longer.
- **Renaming `inproc`.** The mode name, `tryWasmCtfeInproc` and the
  `wasm-ctfe inproc:` prefix distinguish the engine from a subprocess engine
  that no longer exists. `DMD_CTFE=inproc` is a user-visible value.
- **`enum Legality` for the 0/1/2 result of `scanLegalityImpl`.** The function
  now has two nested helpers (`settle`, `pending`) that name the three
  outcomes; the `int` result is compared with `1` in two places.
- **Renaming the object file in `finishWasmSelfLink`.** The module is read,
  compared, written and the object deleted. A `rename` is cheaper, but
  `File.update` keeps the timestamp of an unchanged output and a rename does
  not.
- **One lookup function in `emitCodeSection`.** It resolves calls by symbol
  for objects and by symbol or name for self-linked modules. Always using the
  second lookup removes `funcIdxBySym` as a separate entry point but changes
  the placeholder bytes of relocatable objects.
- **Building the data address index once per module.** `applyDataRelocs` and
  `emitCodeSection` each build it. An earlier section rejects sharing it
  because "offsets are not final"; the offsets are set in `pushDataSeg` and
  the only segment added in between has no symbol, so the reason looks wrong,
  but the index would have to live in `WasmModule`.
- **A `uint[] minfoSegs` list in `WasmModule`.** It would replace the name
  scan in `gatherMinfo`. The scan cannot match today (see the open
  questions), so this is part of that fix.
- **`PTRSIZE` as `tysize(TYnptr)`.** `I64()` is defined as
  `_tysize[TYnptr] == 8`, so `I64() ? 8 : 4` is a round trip. The helpers next
  to it all use `I64()`.
- **A `bool[string]` next to `wasmSelfLinkUnresolved`.** The list is scanned
  for duplicates on every unresolved reference. It only has entries in a
  failing build.
