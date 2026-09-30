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
- **`sqrt(double) + fabs(sin(double))` in a loop fails** with "wasm-ctfe cannot
  evaluate". It fails the same way before the simplification commits.
- **A ctfe-only lambda that loops over an outer const array fails.**
  `enum e = (() { int t; foreach (x; array) t += x; return t; })();` inside a
  function with `immutable int[4] array = 3;` gives "wasm-ctfe cannot
  evaluate". Indexing the array from such a lambda works.
- **A nested static array outer const may be filled only in its outer
  dimension.** `visitSymbol` in `e2ir.d` passes the outer `dim` with the
  scalar's type to `setArray` for `const int[2][3] a = 0`.
- **The `hdrgen.d` null guard fixes a bug that also exists on master.**
  `-ftime-trace` prints an enum while its members are still being analysed. It
  could go upstream as its own fix.

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

## b183f6379f, b770e0e760, bbfee4f85a (fixes in the "soft-real" simplification commit)

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
