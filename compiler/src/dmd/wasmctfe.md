# WASM CTFE engine

`dmd.wasmctfe` evaluates CTFE function calls by compiling them to WebAssembly
and executing them in wasmtime, instead of walking the AST with the
interpreter in `dmd.dinterpret`.

## Activation

Off by default. Controlled by environment variables (kept out of the CLI while
experimental):

| Variable | Effect |
|---|---|
| `DMD_CTFE=wasm` | Use the wasm engine where possible, AST interpreter as fallback |
| `DMD_CTFE=verify` | Run both engines, report result mismatches to stderr, use the AST result |
| `DMD_CTFE_STATS=1` | Print counters at exit |
| `DMD_CTFE_VERBOSE=1` | Log every attempt/success/failure |
| `DMD_CTFE_DIR=path` | Work directory for generated files (default `./__wasmctfe`) |
| `DMD_CTFE_KEEP=1` | Keep generated shim/wasm files |

## How it works

For a CTFE call `f(args...)` (hooked both at `ctfeInterpret` top level and at
`interpretFunction` inside the AST interpreter, so nested calls are also
candidates):

1. **Support check**: `f` must be a non-nested, non-virtual, non-template plain
   function; parameter and return types restricted to integers, floats, bool,
   chars, enums of those, and (nested) dynamic arrays of those; all arguments
   must be literal expressions.
2. **Legality scan**: a conservative transitive walk over the function body and
   its callees rejects anything the AST interpreter would refuse (calls to
   bodyless externs, inline asm, mutable globals, pointers, classes, AAs,
   delegates, `real`, `__ctfe`, ...). This prevents the wasm engine from
   *succeeding* where CTFE must report an error. Modules under
   `core.internal.*`, `core.lifetime`, `core.math`, `core.bitop`,
   `core.checkedint`, `core.int128`, `object` and `rt.*` are trusted without
   scanning (the AST interpreter special-cases the same druntime hooks).
3. **Shim generation**: a small D module is written that declares the function
   `pragma(mangle, ...)`-bound to its mangled name with an ABI-erased
   signature, calls it with the rendered literal arguments, and serializes the
   result to stdout in a small tagged text format.
4. **Compile + run**: the same dmd binary is re-invoked as a subprocess with
   `-mwasm32 -os=wasi -i`, compiling the shim plus the module that defines the
   function; the result is linked by wasm-ld and executed by wasmtime.
5. **Decode**: the tagged output is parsed back into typed literal
   `Expression`s (IntegerExp/RealExp/StringExp/ArrayLiteralExp/NullExp).

Any failure anywhere (unsupported construct, compile error, link error, trap,
nonzero exit) falls back silently to the AST interpreter, so diagnostics for
erroneous CTFE remain byte-identical.

Results and failures are memoized per (mangled name, rendered args); each
function gets a bounded number of subprocess attempts.

## Supported surface

Scalars (integers, bool, chars, float/double), enums of those, dynamic and
static arrays (nested), strings of all widths, and POD structs of the above
(mirrored in the shim as ABI-erased `struct __Sn` declarations, serialized
field-by-field via `.tupleof`). Rejected: templates/instances, nested
functions, methods/`this`, `ref`/`out`/`lazy` params, classes, AAs, pointers,
delegates, `real`, unions, bitfields, non-default alignment.

## Results

`./run.d quick` (compilable + fail_compilation + runnable subset + unit +
dshell) passes identically with `DMD_CTFE=wasm`: exit 0, zero failing
targets. Wall time ~5 min vs ~1 min baseline on a 16-thread machine — the
suite is a worst case (thousands of small one-shot CTFE calls, each paying
subprocess compile+link+run once before memoization/budgeting kicks in).

Benchmarks (function defined in an imported module, evaluated once in an
`enum`; `/usr/bin/time`, warm FS caches):

| workload | AST time | wasm time | AST maxrss | wasm maxrss |
|---|---|---|---|---|
| `fib(30)` recursive | 3.70 s | 0.22 s | 141 MB | 176 MB |
| bubble-sort 2000 ints + checksum | 5.48 s | 0.41 s | 210 MB | 177 MB |
| build 20 000-entry string by `~=` | 3.48 s | 0.43 s | **5.88 GB** | 181 MB |
| 200 distinct tiny calls (same module) | 0.02 s | 2.37 s | 18 MB | 177 MB |

Compute-heavy CTFE is 10–17× faster and, for allocation-heavy code, up to
30× lighter (the AST interpreter's region allocator never frees during an
evaluation). The last row is the adversarial case: pipeline overhead
(~100–150 ms per unique call: dmd -mwasm32 + wasm-ld + wasmtime) dwarfs tiny
evaluations, and same-module calls additionally re-run the enum in the
subprocess (see quirks); the per-function attempt budget caps the damage.

## Bugs and quirks discovered

(collected during development; see git history of this file)

### `size_t` struct fields silently corrupt results
The nastiest bug found: `core.demangle.Buffer.bslice_empty()` returns a
`BufSlice` whose `size_t from, to` fields are 8 bytes in the frontend's view
(native compile) but 4 bytes in the wasm-compiled real struct. Function
mangled names embed parameter/return *type names*, not struct layouts, so
unlike a bare `size_t` parameter this mismatch does not fail to link — the
shim's mirror struct just reads garbage (`to` came back as `1048260`, a wasm
shadow-stack address), which then failed `assert(to == 0)` in demangle's
invariant during later AST interpretation of the corrupted literal
(runnable/template9.d, runnable/test10386.sh). Since the frontend cannot
distinguish a stable `ulong` field from a target-dependent `size_t` alias
(both are `Tuns64` post-semantic), the engine now rejects any struct
containing 8-byte integer fields, recursively.

### Probing the AST has side effects
The legality scanner originally called `functionSemantic3()` on callees and
`isDataseg()` on visited variables. Both can *advance semantic analysis* of
symbols that were not ready, surfacing errors that a normal compile never
produces: runnable/opover2.d failed with `variable Typedef_payload forward
referenced`, and a `__traits(compiles, ...)` in template9.d flipped to false
because speculative semantic3 poisoned `fd.errors`. The scanner now never
runs semantic itself: functions not yet `semantic3done` are rejected (they
get another chance once the interpreter reaches them naturally), declarations
not yet `semanticdone` are rejected, and the whole scan runs gagged.

### CTFE reference semantics don't survive serialization
`compilable/interpret3.d`'s `funcRetArr(x)[2] = 4` pattern: a function that
returns (a slice of) its array argument must return the *same* array, so the
caller can write through it. The wasm engine serializes values, so identity is
lost and the write lands on a detached copy. The engine now refuses calls
whose result contains a mutable-element dynamic array while any parameter
(recursively, through structs and static arrays) contains a dynamic array.
Immutable-element returns (e.g. `string`) are still allowed even though
`f(s) is s` identity could in principle diverge — writes are impossible
through them.

Relatedly, returned literals must be marked `OwnedBy.ctfe`, or the
interpreter refuses to mutate them in place when the surrounding evaluation
continues (`f()[i] = x` on a fresh result); the top-level entry then scrubs
them back to code ownership like any other CTFE result.

### Empty arrays and `null` are indistinguishable at runtime
Found by `verify` mode on compilable/test21432.d: a function returning
`enum int[] a = []; return a;` yields the empty array literal `[]` from the
AST interpreter, but at runtime `[]` is `(null, 0)`, so the wasm-side
serializer sees a null pointer and reports `null`. The distinction (visible
via `is null` in later CTFE) cannot be recovered after execution, in either
direction. The engine now treats a serialized null array as a decode failure
and falls back to the AST interpreter — null/empty results are cheap to
interpret anyway. Length-0 arrays with a non-null pointer (empty slices of
allocated arrays) still decode as `[]`, matching the AST result.

### The engine must not touch the process environment
`dshell/sameenv.d` compares the environment of `dmd -run` against a directly
executed binary. The engine originally did `unsetenv("DMD_CTFE")` in the
parent (so its dmd subprocess wouldn't recurse into wasm CTFE), which the test
duly detected. The unsetenv now happens after `fork()` in the child only.

### size_t mangling saves the day
The frontend semantically analyzes for the *native* target, so `size_t` is
64-bit in the AST, but the wasm subprocess re-compiles the source where
`size_t` is 32-bit. For functions with `size_t` in their signature this is
self-correcting: the mangled name embeds `m` (ulong) natively but `k` (uint) on
wasm32, the `pragma(mangle)` shim import doesn't resolve, and wasm-ld's
`--import-undefined` turns it into an `env::` import that fails wasmtime
instantiation — an automatic (if slow) rejection. Functions that merely use
`size_t` *internally* keep 32-bit semantics silently; a function computing
`size_t.max` at compile time would produce a different answer. Only `verify`
mode catches those.

### Undefined symbols surface at instantiation, not link
Because the wasm driver links with `--import-undefined`, a missing definition
does not fail `wasm-ld`; it becomes an `env::` import and fails only when
wasmtime instantiates the module. The engine detects `unknown import` in the
runner output and blacklists the function.

### `__ctfe` is false in the wasm engine
The subprocess builds *runtime* code, so `if (__ctfe)` takes the runtime
branch. For the usual idiom (same result, different algorithm) this is
harmless, but code relying on CTFE-only behavior would diverge, so the
legality scan rejects any function whose scanned body references `__ctfe`
(trusted druntime modules excepted).

### Same-module CTFE is a chicken-and-egg problem
The subprocess compiles the module that *defines* the called function. If the
expensive CTFE call sits in that same module (`enum r = checksum(2000);` next
to `checksum`), the subprocess must evaluate that very enum with its own
(AST) interpreter just to finish semantic analysis of the module — so the
wasm engine pays the full AST cost *plus* pipeline overhead, and can never
win. The engine wins when the function lives in an imported module, which is
the usual library topology. A future improvement would be extracting the
function subgraph into a synthetic module instead of recompiling the defining
module.

### Nothing has run semantic3 when module-level enums evaluate
Module-level `enum` initializers are evaluated during semantic2, before *any*
function in the module has had semantic3 run. The legality scanner initially
treated "callee not semantic3done" as a rejection, which killed essentially
every top-level attempt with helper functions. The interpreter itself runs
`functionSemantic3()` on demand for functions it actually calls, and every
non-template function must pass semantic3 anyway in a valid program (PASS3
runs it unconditionally), so the scanner now eagerly runs semantic3 for
callees that are not inside template instances; instance members stay
hands-off (see the forward-reference quirk above) and yield a non-cached
"retry" verdict instead.

### Accepts-invalid: unions
`fail_compilation/test16284.d`: comparing structs containing anonymous unions
must *error* in CTFE ("reinterpretation through overlapped field"), but the
wasm build just compares the bytes and succeeds, making the expected error
disappear. The legality scanner now rejects any body whose expressions
involve struct types with overlapped fields (recursively). This is the
general hazard class of this design: the engine must never *succeed* where
the AST interpreter errors, and CTFE legality rules (union access, pointer
arithmetic limits, `@safe` reinterpretation rules...) have to be
over-approximated statically. Interestingly this hole was masked until the
eager-semantic3 change widened coverage — every scanner liberalization can
expose new accepts-invalid cases.

### Version blocks are re-resolved for wasi
The subprocess re-runs semantic analysis under `-os=wasi`, so
`version (linux)` etc. resolve differently than they did in the host compile.
A function whose CTFE result depends on such blocks silently gets the
wasm-flavored answer. Conservative fallback does not catch this; `verify` mode
does.


### AST interpreter broadcasts pointer stores into static-array fields
Found by `verify` mode on `interpret3.d` bug 13630: a constructor doing
`auto p = arr.ptr; *p = 0;` on a `float[3]` field. Runtime semantics (and the
wasm engine) give `[0, nan, nan]`. The AST interpreter instead records the
struct field as the scalar `0.0F`, which later indexing treats as a broadcast:
`s.arr[1] == 0` under AST CTFE but is `nan` at runtime. The wasm engine's
byte-accurate memory model is *more* correct than the AST interpreter here.
The verify comparator accepts an AST scalar against a wasm array literal when
the first wasm element matches, to keep this known divergence from drowning
out real mismatches.

### static foreach evaluates before aggregate sizes are finalized
`compilable/issue23391.d`: the same function body evaluated via
`static foreach (t; MyZip().myarray)` returned length 0 while the identical
`enum n = arr(R(false)).length` returned 1. Cause: static foreach expansion
runs its CTFE call while other module members (here the element struct) still
have `sizeok == Sizeok.fwd`. `Type_toCtype` then baked a backend struct type
with `Sstructsize == 0`, so `registerShadow` computed alignment 0 and size 0:
the loop variable and its spill temp collapsed onto shadow-frame offset 0,
aliasing the saved sret pointer, and the element copy vanished. The
`.length` result silently became 0 — and the by-mangled-name cache then
poisoned every later evaluation of the same call in the module. Fix:
`Type_toCtype` forces `determineSize` on structs during wasm-ctfe builds
(`Sizeok.fwd` means "ready to compute", so this is safe). The AST
interpreter never notices because it computes sizes lazily on demand.

### ctfe-scope semantic skips the ExpInitializer-to-construct rewrite
`interpret3.d` bug 11535 (`md5_digest11535`): passing an array literal to a
`scope` slice parameter makes expressionsem wrap it as
`(auto __arrayliteral_on_stack = [...] , cast(slice)tmp)`. In a normal
function scope, declaration semantic rewrites the temp's ExpInitializer into
a ConstructExp; in the CTFE evaluation scope (no `sc.func`) that rewrite is
skipped. `Dsymbol_toElem` then compiled the initializer as a discarded value:
the literal was materialized into one temp while the slice pointed at the
never-written `__arrayliteral_on_stack` symbol — `__equals` compared
garbage. e2ir now detects an ExpInitializer that never references its
variable during wasm-ctfe builds and emits the missing store. Same hazard
class as the skipped druntime lowerings: ctfe-scope semantic produces AST
shapes native codegen never sees.

### Unsupported operators degrade to traps during engine builds
Druntime pulled `core.simd` x86 `__simd()` intrinsics (OPvector) into a
worklist; the wasm backend used to `assert(0)` on any unsupported operator,
killing the whole compiler process. During wasm-ctfe builds the backend now
lowers unsupported operators to `unreachable` traps instead: if the
evaluated path never executes them the result is unaffected (coverage on
`interpret3.d` jumped from 185 to 349 verified evaluations), and if it does,
the trap surfaces as a runtime failure rather than an ICE.

### Verify mode must ignore engine results when the AST interpreter errored
In `DMD_CTFE=verify`, several fail_compilation tests (ctfe10995, dbitfields,
fail19123, ...) printed MISMATCH lines: the AST interpreter produced an
ErrorExp (the test's expected diagnostic) while the engine produced a value
or a different failure. Comparing against an error result is meaningless —
the compare is now skipped when the native result `isErrorExp()`. Note this
also masks accepts-invalid holes in the in-process path (it runs no legality
scan yet); that gets addressed when the scanner moves into
`tryWasmCtfeInproc`.

### Eager semantic3 changes diagnostic flavor on erroneous functions
The engine forces `functionSemantic3` on worklist functions before the AST
interpreter would have. When that semantic3 itself fails, dinterpret's
call-site check `semanticRun >= semantic3done && hasSemantic3Errors` fires
and prints "CTFE failed because of previous errors in `f`" — but natively
the first call reaches `interpretFunction`, fails inside `functionSemantic3`
there, and produces only a silent `cantexp` plus the "called from here"
backtrace note. Tests encode the native wording (fail208, fail216, fail4448,
ice10599, ...). Fix: every eager-semantic3 site records a consume-once
marker (`forcedSem3Errors`) when it detects errors; dinterpret's check
consumes the marker on the first call and reproduces the native flavor
(cantexp + backtrace), while later calls print the "previous errors"
message exactly as native does. There are three eager sites — the legality
scanner, the inproc entry, and the glue worklist — and all three must set
the marker.

### -m32 codegen asserts 64-bit-unsafe invariants during engine builds
`diag7420.d -m32`: e2ir's virtual-call path asserts `tysize(TYnptr) == 4`
on x86 targets, but engine builds run with wasm64 pointer sizes while
`target.isX86` still reflects the host target. The assert is skipped when
`wasmCtfeBuildActive`. Same hazard class as the OS-dependent `retStyle`
checks: any `target.*` predicate consulted during an engine build sees the
*host* target, not wasm.

### Mutable statics with unanalyzed initializers crash the worklist
`fail19447.d` segfaulted: `immutable int i = g19447(mh);` runs CTFE during
phase-1 semantic, but `int[2] mh = [1, 2];` is a *mutable* static whose
initializer semantic is deferred to semantic2. The engine worklist pulled
`mh` in as a referenced data symbol and `toObjFile` hit
`Initializer_toDt.visitArray` with `ai.type == null` — a raw, unsemantic'd
ArrayInitializer. The worklist now poisons the build when it meets a
variable whose ArrayInitializer has no type yet (or a StructInitializer).
Natively the test errors out ("static variable `mh` cannot be read at
compile time") before ever touching the initializer.
