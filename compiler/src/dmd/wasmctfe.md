# WASM CTFE engine

`dmd.wasmctfe` evaluates CTFE by compiling the expression and everything it
calls to WebAssembly with dmd's own glue layer and backend, and running the
result in wasmtime through its C API, inside the compiler process. It is
meant to replace the AST interpreter in `dmd.dinterpret`. The problems caused
by running the glue layer and backend during semantic analysis are collected in
`wasmctfe-glue.md`.

## Activation

On by default on Posix hosts, in `strict` mode: the AST interpreter is not
used, not even for expressions that are already literals, which are copied
and scrubbed directly. Other hosts use the AST interpreter. Controlled by
environment variables (kept out of the CLI while experimental):

| Variable | Effect |
|---|---|
| `DMD_CTFE=off` | Use only the AST interpreter |
| `DMD_CTFE=inproc` | Use the engine where possible, AST interpreter as fallback |
| `DMD_CTFE=verify` | Run both engines, report result mismatches to stderr, use the AST result |
| `DMD_CTFE=strict` | Engine only, also under `global.gag`; a non-literal the engine can't evaluate is an error (`wasm-ctfe cannot evaluate ... [reason]`) |
| `DMD_CTFE_STATS=1` | Print counters at exit |
| `DMD_CTFE_VERBOSE=1` | Log every attempt/success/failure |
| `DMD_CTFE_TRACEGEN=1` | Log what the build pulls in and which functions become stubs |
| `DMD_CTFE_SHOWGAG=1` | Don't gag errors raised while building |
| `DMD_CTFE_KEEP=1` | Write each built module to `wasmctfe_ip_N.wasm` |

## How it works

`ctfeInterpret` calls `tryWasmCtfe` before the AST interpreter.

1. **Fold**: expressions that need no code are answered on the host.
   Constant folding (`optimize`) runs first, also when the expression
   contains calls, since a dead `?:` arm or a `const` initializer often
   removes them. A tree of pure operators whose leaves are literals or
   calls with literal arguments (`x | f(1)`, `"a" ~ g(2) ~ "b"`,
   `[f(1), f(2) + 1]`) is evaluated node by node: each call goes through
   the cached direct-call path and the operators are folded on the host.
2. **Wrap**: a call with literal arguments is evaluated directly: the
   arguments are written into guest memory and the function is called by its
   export. Any other expression is wrapped in a generated function;
   enclosing `const` locals are hoisted into it and top-level array
   operations are unrolled.
3. **Check**: `ipExprSupported` and the legality scan reject what the engine
   can't do yet or what CTFE must refuse. In `verify` and `inproc` mode that
   falls back to the AST interpreter; in `strict` mode it is an error.
4. **Analyse**: `wasmCtfePreSemantic3` walks the bodies of the root and its
   callees and runs `semantic3` on every function the build will need, before
   the build starts, so that CTFE nested in that analysis gets its own engine
   run.
5. **Build** (`wasmCtfeGenerate` in `glue/package.d`): the root function goes
   through `toObjFile` for the wasm64 target, and every function, vtable,
   `TypeInfo` and global it references is queued and built the same way.
   `wasmCtfeBuildActive` switches glue lowerings to CTFE semantics (`__ctfe`
   is true, GC lowerings are on, `const` initializers fold). Symbols already
   in the program are not built again: the module imports them. The build
   is retried to replace functions that fail to build with traps, and to run
   `semantic3` on functions the walk missed.
6. **Link**: all evaluations share one wasmtime store. A base module exports
   the memory, the function table, the stack pointer and the exception tag;
   every build is a small module instantiated into that store, with its data
   placed after the data of the modules before it and its functions appended
   to the table. A module that built cleanly is committed: its exports are
   defined in the linker and later modules call them. A module that contains
   trap stubs is used once and rolled back. Imports that are neither in the
   program nor host callbacks bind to host functions: the bump allocator
   behind `gc_malloc` and `malloc`, math builtins, 80-bit `real`, C++ casts,
   `_aApply*`, stub traps and lazily built virtual functions.
7. **Run**: guest memory is reset to the image of the committed data, the
   function is called and a trap becomes a CTFE error.
8. **Decode**: guest memory is read back into literal `Expression`s:
   scalars, arrays, structs, unions, pointers, class references (by vtable
   address), AAs, function pointers and delegates, keeping shared references
   and cycles.

## Results

Measured on 2026-09-30 against the AST interpreter at baseline
`12d7c683ba`. Both compilers are release builds (`ENABLE_RELEASE=1`), all
runs use `-o-`, and each time is the best of three runs. The harness is
`tmp/ctfebench/bench.sh`. The `real/` workloads import Phobos
(`EXTRA=-I<phobos>`).

| Workload | AST (base) | AST (`DMD_CTFE=off`) | wasm engine |
|---|---|---|---|
| `aa` (AA insert/lookup, n=20000) | 7.09 s / 42 MB | 7.07 s / 45 MB | 0.07 s / 56 MB |
| `fib` (recursion) | 0.40 s / 47 MB | 0.37 s / 49 MB | 0.01 s / 31 MB |
| `manysmall` (3000 small CTFE calls) | 2.83 s / 344 MB | 2.82 s / 346 MB | 0.13 s / 65 MB |
| `sieve` | 7.84 s / 1256 MB | 8.10 s / 1258 MB | 0.05 s / 46 MB |
| `sort` | 2.65 s / 371 MB | 2.66 s / 374 MB | 0.05 s / 44 MB |
| `strings` (append/concat) | 2.51 s / 4025 MB | 2.56 s / 4025 MB | 0.15 s / 57 MB |
| `structs` | 1.04 s / 337 MB | 1.08 s / 337 MB | 0.04 s / 42 MB |
| `ctRegex` (two patterns) | 1.30 s / 301 MB | 1.18 s / 304 MB | 0.95 s / 355 MB |
| `format`/`to`/`sort` enums | 0.23 s / 98 MB | 0.24 s / 98 MB | 0.32 s / 150 MB |
| import 12 Phobos modules | 0.19 s / 85 MB | 0.19 s / 87 MB | 0.24 s / 122 MB |
| 2000 different tiny lambdas | 0.11 s / 40 MB | 0.11 s / 43 MB | 0.86 s / 149 MB |

Compute-heavy CTFE is 17–150 times faster and uses up to 70 times less
memory. The AST interpreter is unchanged: `DMD_CTFE=off` matches the
baseline.

Code with many small, different CTFE calls is slower. A call is answered
without a module when the host can fold it (constant expressions, functions
whose body is a constant, cached results). Every other call builds,
compiles and instantiates a module, and the last row of the table is the
worst case: 2000 lambdas that each run a two-iteration loop once. A module
costs about 0.38 ms there: 0.07 ms in glue and backend code generation,
0.29 ms in `wasmtime_module_new`, 0.01 ms to link and 0.003 ms to call.
Wasmtime's share has a floor that the engine cannot lower: a module that
contains only `(func (result i32) i32.const 1)` takes 0.14 ms, spread thinly
over Cranelift's pipeline, the object writer and type registration. Opt
level, the single-pass register allocator, serial compilation and unwind
info change it by less than 10 %. Fuel metering doubled it, which is why it
is off (see "No fuel"). ctRegex builds 39 modules, the `format` workload 20
and importing Phobos 23 (it was 700 before constant globals were folded on
the host).

Profiling tips: `-ftime-trace -ftime-trace-granularity=0` shows each CTFE
call. `perf` sees only on-CPU time, and Cranelift runs on worker threads, so
time the phases with a clock instead.

## Bugs and quirks discovered

The first version generated a D shim and ran `dmd -mwasm32` and `wasmtime`
as subprocesses. It has been removed; sections that mention the subprocess
or the shim describe problems from that version.

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

Later superseded: unions are allowed and only pointer reinterpretation is
checked, at run time (see "Pointers in unions").

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

The same family shows up with other initializer kinds. An ExpInitializer
whose expression is still untyped trips `todt` `visitNull`'s
`assert(e.type)`. A VoidInitializer with no type segfaults in `size()`.
Both now poison the build as well. The legality scan's
const/immutable-global and static-local acceptance also requires
`_init.semanticDone`, so an unanalyzed initializer is rejected before
the worklist ever sees it.

### `?:` arms that don't produce the result type
The backend's `OPcond` can have an arm that produces nothing, a void arm
(`TYvoid`), or a scalar arm under a `v128` result. Coercing such arms
asserted in `emitCoerce`/`wasmType`. Arms are now fitted: drop what
was pushed, then pad with a zero of the result type (`v128.const 0`
for vectors).

### Expr wrappers must not capture their enclosing frame
`static assert`/`enum` expressions inside function or method bodies can
reference nested functions or frame temps (the `$` of `(f())[0 .. $]`
lives in the enclosing method). A synthetic module-level wrapper cannot
access those; compiling one produced "`test1` is a nested function and
cannot be accessed" as a gagged error and poisoned the build. The
expr-support scan now bails when the expression calls a nested function
or references a function-parented variable that is not declared inside
the expression itself.

### CTFE re-entered during an engine build must defer
Semantic3 of a worklist function can instantiate templates whose members
run their own CTFE (druntime's `newCapacity` table, `enum attr` in the
array hooks). `wasmCtfeGenerate` is not reentrant and refused the nested
call — but `ipGetModule` then cached that function as permanently failed
and reported it as "errors" (no message, since nothing was actually
raised). Nested requests now return null before touching the failure
cache; the same evaluation succeeds later at top level, or runs in the
AST interpreter (see "Nested builds fall back to the AST interpreter").

### Array literals allocate through the host bump allocator
The `_d_arrayliteralTX` lowering never runs for ctfe-scope expressions,
so engine builds lower a heap array literal to a
`_d_allocmemory(dim * elemsize)` call (bound to the wasmtime host bump
allocator, same as `gc_malloc`) followed by inline element stores —
the same shape the native lowering produces.

### Appends use GC-style block capacity
The host bump allocator keeps a "used" length per allocation, and
`gc_expandArrayUsed`, `gc_shrinkArrayUsed` and `gc_reserveArrayCapacity`
implement the druntime GC contract on it: a slice whose end is the block's
used end grows in place while capacity remains. Without it every `~=`
reallocated, and since the bump allocator never frees, building a large
string or AA at compile time ran out of guest memory. The host-side append
paths (`__wasmctfe_append`, `~= dchar`) share the same logic and over-allocate
by 1.5x. Aliasing behaves as at run time: appending to a slice that doesn't
end at the used end copies.

### Bit-test intrinsics had swapped, 32-bit-only operands
On wasm the argument list of `core.bitop.bts`/`btr`/`btc` arrives as
`(bitnum, ptr)`, while the optimizer's `OPbt` (from `cgelem`'s
`p[b >> 6] & (1 << (b & 63))` pattern and `gother`'s dead-store rewrite of
`bts`) uses the x86 order `(ptr, bitnum)`. The wasm lowering followed the
first order and kept the bit number in an i32 local, which is invalid wasm
under `-m64` (found by `ctRegex`: "type mismatch: expected i32, found i64"),
and `OPbt` was not lowered at all. e2ir now swaps the intrinsic operands on
wasm so both use `(ptr, bitnum)`, and the lowering handles i64 bit numbers
and `OPbt`. This also affects native wasm codegen.

### Aliases in function bodies are not scanned
`alias t = someFunction;` inside a body made the legality scanner (a
`SemanticTimeTransitiveVisitor`) walk `someFunction`'s body. That body may
not have had semantic3, so its locals showed up as "unresolved
declaration" and the whole call chain was rejected (`std.uni.simpleCaseFoldings`,
hence every `ctRegex`). Calls through the alias are still found as
`CallExp`s.

### Const outer locals: frame first, initializer second
Reading an enclosing function's `const`/`immutable` local re-evaluates its
initializer when the reader has no real frame (ctfe-scope lambdas,
`static foreach` aggregates). This must not happen when the reference is
a normal nested reference: `immutable oldLen = array.length;
array.length += n; (){ ... oldLen ... }()` in `std.array.insertInPlace`
re-read the grown length. The initializer is now only used when the
current function is not in the variable's `nestedrefs`.

### Frameless context pointers are constants
Without a frame, `getEthis` returns the constant `wasmCtfeNoFrame`.
`setEthis` took its address when the target function has nested frame
references, giving `&0xFF000000`, which trips the common-subexpression
pass (`cgcs.d` assert) in debug builds. Release builds emitted it silently.
Seen in `std.format` through `enum check = { ... use(S.init) ... }()`
inside a function with a nested struct. The constant is now passed as is.

### Data extents are per module
Pointer-to-data lookups (`ipFindData`) used the self-link's global
extent list, which describes the most recently linked module. When a
cached module ran after a different one was built, lookups used the wrong
table; `std.uni` read Unicode block names from the wrong offsets. Each
cached `IpModule` now keeps its own extents, like its table and vtables.

### Constant globals are folded on the host
`std.internal.unicode_tables` initializes an array of about 650
`UnicodeProperty("Name", Name)` literals, where `Name` is a
`static immutable ubyte[]`. Each element is its own CTFE call, and each
built a module. Expressions without calls now have `const`/`immutable`
data-segment variables with literal initializers substituted, including
inside struct and array literals, slices and index expressions. The
result is then optimized. If that gives a literal, it is deep-copied with
`copyLiteral` and returned without a module. `optimize` leaves slices of
string constants as a bounds-free `"..."[]`, which is unwrapped. The result
is the same as the AST interpreter's, which also reads the initializer.

### Copy-on-write memory images are disabled
With `memory_init_cow` enabled (the default), wasmtime creates a memory
image (a memfd) for every module's data segments. That made instantiation
cost about 85 µs. With it disabled, the data is copied in on each
instantiation, which costs about 15 µs for CTFE-sized data.

### Selflink rebuilt the data map per function
`patchSelfLinkCodeRelocs` built a name-to-address map of all data segments
for every function body. That is O(functions × segments), and it took 11% of
a ctRegex compile. The map is now built once per code section.

### Time traces crash on enum values printed mid-evaluation
`-ftime-trace` prints each CTFE expression. For `access = front | back |
opIndex`, `optimize` had folded `front | back` in place into an `IntegerExp`
of the enum type. `hdrgen` looked the value up among the enum members and
dereferenced `access.value`, which was still unevaluated. Unmatched members
are now skipped.

### Large argument lists live above the stack
Arguments are copied into linear memory below the shadow stack top. A
call whose arguments exceed the stack (large struct or array literals)
now grows memory and places them in fresh pages, and the bump heap starts
after them.

### `~= dchar` runs host-side
`_d_arrayappendcd`/`_d_arrayappendwd` are implemented as host functions:
decode the slice at the ref address, UTF-8/UTF-16-encode the code point,
reallocate via the bump allocator and write the new slice back through
both the ref and the sret pointer. Signature on wasm64 is
`(i64 sret, i64 ref, i32 dchar) -> ()`.

### Array identity is structural in CTFE — and engine builds emulate it
The AST interpreter's `is` on arrays goes through `ctfeRawCmp`, i.e. it
is a structural comparison: `static assert({ return [1] is [1]; }())`
passes natively even though two literals are involved. The engine has
real pointer semantics, so a pointer-pair compare would say false;
engine builds instead lower non-null array identity to
`len1 == len2 && memcmp(p1, p2, len1 * elemsize) == 0`. Exception:
arrays of floating-point elements — the interpreter compares those
elements with `==` (so `[double.nan] is [double.nan]` is *false*
natively), which bitwise memcmp would get wrong; those stay poisoned.

### Exceptions run in-engine without druntime's EH runtime
The wasm target lowers `throw` to `_d_throwc` (rt.wasm.eh pins the
object, chains collateral exceptions, then executes the wasm `throw`
instruction) and catch dispatch to `_d_eh_wasm_match`. Neither body is
available to engine builds (rt.wasm.eh is `version (WebAssembly)`, and
the frontend runs with host versions), so:
- engine builds lower `throw` directly to the backend's `OPthrow`
  (native wasm `throw` on the module's `__d_exception` tag). Pinning is
  unnecessary (the bump allocator never frees) and collateral-exception
  chaining is not reconstructed;
- `_d_eh_wasm_match(o, ci)` is a host hook: it reads `vtbl = *o`,
  `classinfo = *vtbl`, then walks the `TypeInfo_Class.base` chain in
  guest memory comparing pointers (in-module classinfo pointers are
  unique). The offset of `base` is taken from `Type.typeinfoclass`'s
  field layout at bind time.
An uncaught exception surfaces as a wasmtime execution error; the
engine result is discarded and the AST interpreter's "uncaught CTFE
exception" diagnostic stands.

### Classes work inside engine builds
`new C(...)`, constructors, virtual calls and class field access all
compile and run in-engine (vtables and classinfo are emitted by the
regular wasm pipeline; `gc_malloc` binds to the host bump allocator).
The remaining class gaps are at the boundary: class-typed CTFE
*arguments* (including `this` for methods) have no marshalling, and
expression wrappers bail on implicit `this`.

### Class-typed results marshal back by classinfo name
A direct call returning a class decodes the returned i64 object address
into a `ClassReferenceExp` (the same shape dinterpret builds: a
`StructLiteralExp` over all hierarchy fields, root base first, with the
`__monitor` field skipped exactly like dinterpret's `hasMonitor()`
logic). The *dynamic* type is recovered by reading
`TypeInfo_Class.name` from guest memory (`obj → vtbl[0] → classinfo →
name`, offsets from `Type.typeinfoclass`'s layout) and looking the
fully-qualified name up in a registry of `ClassDeclaration`s recorded
as `toObjFile` emits them during engine builds — so downcasts like
`cast(Derived) make()` see the right runtime type. Interface-typed
results stay unsupported. Null pointer fields decode to `null`;
non-null raw pointers in a result still fail the decode.

Two prerequisites surfaced here: a class only referenced through the
`_d_newclassT` lowering reaches the worklist via
`__traits(initSymbol)`'s `SymbolDeclaration → toInitializer` path, and
the aggregate-readiness gate must not require `semantic2done` on fields
*without* initializers (a `pragma(msg)` in the middle of semantic2
evaluates before the class's own semantic2 has run).

### Method calls on class constants go through the expression wrapper
A CTFE entry like `sc.get()` on a `static immutable C sc` compiles as
an expression wrapper: e2ir emits the receiver's `ClassReferenceExp` as
a static data symbol whose vtbl/classinfo pointers are ordinary data
relocations, so virtual dispatch works in-engine. Direct-call
marshalling of class `this` stays unimplemented (the wrapper covers
these entries). Two blockers had to fall first:

- **TypeInfo_Class sizing**: `genClassInfoForClass` compares
  `Type.typeinfoclass.structsize` against the compiler's layout and
  calls `fatal()` on mismatch. Early in semantic2, TypeInfo_Class may
  not be sized yet (structsize 0), and native `-o-` compiles never
  reach this check — so an engine build hitting it would kill
  compilation that should succeed. The worklist forces `determineSize`
  on `Type.typeinfoclass` before emitting any class and poisons the
  build (instead of proceeding into `fatal()`) if it still has no size.
- **Silent-zero vtbl**: a class reached *only* through a
  `ClassReferenceExp` (no `new`, no TypeInfo reference) queued just its
  `__vtbl` VarDeclaration — a synthetic var with no initializer, which
  `toObjFile` emits as zeros. Every virtual call then trapped
  "uninitialized element" (table index 0). The worklist now redirects a
  class's `vtblsym` to the `ClassDeclaration` itself, whose `toObjFile`
  emits the real vtbl (with function-table relocations), the classinfo
  and the init symbol.

### Associative arrays run in-guest via core.internal.newaa
The frontend already lowers AA operations (`aa[k]`, `aa[k] = v`, `k in
aa`, `aa == bb`, `new V[K]`) to template hooks in
`core.internal.newaa` — plain D code in the import path. Engine builds
compile those instances to wasm like any other function, with
`gc_malloc` bound to the host bump allocator, so AAs work with no
host-side AA implementation at all. Four blockers fell:

- the old `getTypeInfo` poison for `Taarray` (a pre-classes-era guard)
  and the worklist's skip of `TypeInfoAssociativeArrayDeclaration`
  vars;
- `TypeInfo_AssociativeArray` instances created at codegen time have
  null `entry`/`xopEqual`/`xtoHash` (those are filled by a
  scope-carrying semantic3 the lowering defers). `newaa`'s templated
  code never reads them at runtime, so engine builds emit those three
  slots as null instead of crashing;
- `_d_aaEqual!(K,V)` never reaches semantic3 through
  `functionSemantic3` because the lowering registers it via
  `addDeferredSemantic3` (the `deferred3` flag makes
  `functionSemantic3` a no-op), and native CTFE interprets AA equality
  itself so nothing else forces it. `ipForceSemantic3` now runs
  `semantic3(fd, fd._scope)` directly for deferred-3 functions. The
  queue also keeps bodyless functions whose semantic3 hasn't run yet
  (a template instance grows its body in semantic3);
- a class field initializer not yet `semantic2done` (bug 10782's
  scenario) resolves on demand: the readiness gate runs
  `initializerSemantic` from the field's saved `_scope` under the
  engine build's gag (using `getConstInitializer` here would ungag and
  double-report errors, seen as a duplicated circular-reference error
  in ice10259). On error the class is just "not ready" and the native
  path reports once. `membersToDt`'s `semantic2done` assert admits
  engine builds since the initializer is resolved by then.

With this, interpret3 under `DMD_CTFE=verify` reports **zero compile
failures, zero runtime failures and zero mismatches** for every
attempted engine evaluation.

### Engine-build template instances went permanently speculative

Instances created while the engine build is active get `minst = null`
(so guest-only instantiations don't leak into native codegen). But
`ipForceSemantic3` runs the deferred semantic3 of real runtime hooks
like `_d_aaEqual` during the build, and *inner* instantiations made by
those bodies (`impl_aaEqual!(K,V)` behind the `pure_aaEqual` cast)
would natively run later, ungagged, with a real `minst`. Nulling their
`minst` made the primary instance permanently speculative — nothing
re-instantiates it, so `needsCodegen` elided it and the link failed
with an undefined `impl_aaEqual`. Fix: a suspend counter turns off the
`wasmCtfeBuildActiveNow()` minst-nulling for the duration of
`ipForceSemantic3`, since anything instantiated inside a forced
semantic3 would have been instantiated natively anyway. The forced
deferred-3 semantic3 also runs with gag lifted, matching native
`runDeferredSemantic3`.

### AA insertion order at CTFE

The AST interpreter's AAs preserve insertion order (they are literal
lists), and tests observe it via `aa.keys`, `foreach`, `aa.values`.
The `newaa` hash implementation iterates buckets. Under `if (__ctfe)`
a side table in `newaa` (keyed by `Impl*`, holding `Entry*` in
insertion order — entry pointers are stable across bucket resize)
records append/replace/remove, and `_aaKeys`/`_aaValues`/`_d_aaApply`/
`_aaRange` walk it at CTFE. The `__ctfe` branches must cast entries to
`typeof(aa.buckets[0].entry)` (keeping `inout`), not a
`substInout`-stripped type: for class keys the result array element
type stays `inout(Object)` and `copyEmplace` requires source and
target types to match. A void-returning `@trusted` lambda holds the
inout-typed local (a lambda *returning* inout fails to compile).

### `new seg_data()` in a raw-realloc array vs `-lowmem`

`SegData` is an `Rarray!(seg_data*)` whose buffer grows with plain C
`realloc` — the GC never scans it. The wasm object writer allocated
its entries with `new seg_data()` (and `new OutBuffer()`), so under
`-lowmem` (GC collections enabled in dmd) a collection could free
live `seg_data` structs mid-build; the memory was then reused (e.g.
by `symbol_calloc`) and later `Offset(seg) = offset` writes through
the stale pointer corrupted whatever landed there — observed as a
`Symbol.Sseg` turning into pointer-half garbage and a `SegData[seg]`
bounds assert, ~50% reproducible on xtest46_gc, vanishing under gdb
and valgrind (GC-heap reuse is invisible to both). Every other object
writer allocates `seg_data` with `mem_calloc` and `SDbuf` with C
`calloc`; the wasm writer now does the same.

### `__ctfeGuest()` and `isIfCtfeBlock` dead-branch elision

The AST interpreter must not see the CTFE order-table code in `newaa`
(it chokes on the `__gshared` side table), so those branches are
guarded by a guest discriminator `__ctfeGuest()`: a normal function
returning `false` that the wasm-CTFE glue folds to `1` while an engine
build is active. The guard must be written as nested statements,
`if (__ctfe) if (__ctfeGuest()) ...`, never `if (__ctfe && __ctfeGuest())`:
native codegen only skips `if (__ctfe)` bodies via
`Statement.isIfCtfeBlock()`, which matches a bare `__ctfe` condition.
With a compound condition e2ir still walks the (dead) branch, pushes
any lambdas in it onto `deferToObj`, and the emitted lambdas reference
`ctfeOrder*Impl` symbols that no runtime druntime defines — an
undefined-reference link failure that only shows up in tests using
those AA operations.

### Forced `semantic3` and instance rooting

The engine build forces `semantic3` on `deferred3` instances it needs
(`ipForceSemantic3`). Nested instantiations made during that pass
follow the engine-build `minst`-nulling by default, which is correct
for engine-only helpers but wrong when the forced function is an
instance the *host* also codegens: its nested instances (e.g.
`impl_aaEqual` inside `_d_aaEqual`) must be host-real or the host link
fails. Conversely, unconditionally suspending the nulling leaks
engine-only instances (whole `newaa` TypeInfo families) into the host
object — `compilable/ti_emission.sh` checks exactly that. The rule:
suspend the nulling only when the forced function's enclosing
`TemplateInstance` has a non-null `minst`, or, for a non-template
function, when it lives in a root module.

That rule is not enough on its own; compiling dmd's own unit-test
runner under `DMD_CTFE=verify` found four more leak paths:

- **Attribute inference through host code.** An engine-only function
  calls a host-rooted template function whose attributes are still
  being inferred, so `functionParameters` runs its `semantic3` during
  the build, and its instantiations (`peekSlice!`) got nulled.
  `Semantic3Visitor.visit(FuncDeclaration)` now suspends the nulling
  whenever its scope's `minst` is a root module. The host would have
  analyzed that body anyway.
- **Suspension inherited across CTFE.** Host `semantic3` of a root
  function can itself trigger CTFE, so the engine build would start
  with the nulling already suspended. Every build entry saves the
  suspend counter, zeroes it, and restores it afterwards.
- **TypeInfo generation.** Engine `e2ir` `typeid` goes through
  `TypeInfo_toObjFile` → struct `TypeInfo` `toDt` → `semantic` of
  `__xopEquals` and friends, which instantiates `__equals!`,
  `_d_aaEqual!`, and `RTInfoImpl!` for *host* structs.
  `TypeInfo_toObjFile` suspends the nulling. Conversely,
  `semanticTypeInfo` is a no-op during a build. Otherwise an engine-only
  `in` expression queues a `TypeInfoAssociativeArrayDeclaration` into
  host `deferred3`, and that declaration's `semantic3` forces its
  `Entry!` instance into the root module
  (`tmpl.minst = importedFrom`).
- **Parked instances.** `appendToModuleMember` keeps build-created
  speculative instances in their non-root module ("parked"), so
  engine-only instances never reach root codegen or `-vcg-ast` output.
  In stock dmd a speculative instance lands in root members, and
  `needsCodegen` later resolves it through `tinst`/`tnext`. When the
  host reuses a parked instance speculatively, or promotes it to root,
  the instance is re-appended to root members. Parked instances whose
  `tinst` chain reaches it are re-appended transitively; without that,
  `dstrcmp!` inside an engine-analyzed `__cmp!char` stays undefined.
  Host reuse from a *non-root* scope does not unpark, because stock
  dmd would keep that instance non-root too.

### `NoBackend` builds

The unit-test runner builds the frontend with `-version=NoBackend`.
`dmd.wasmctfe` is imported from frontend modules (`dinterpret`,
`dscope`, `templatesem`) but itself imports the glue and backend, so
it provides a `version (NoBackend)` stub section (mode always `off`,
all entry points no-ops) and keeps the real implementation in the
`else` branch.

### Nested functions without a frame get a trapping context

A `static assert` inside a function body can call that function's nested
functions. The expression wrapper lives at module scope and has no frame.
During engine builds `getEthis` returns `wasmCtfeNoFrame` (0xFF00_0000)
instead of erroring, and a direct call of a nested function passes the
same value. That address lies above the most the guest memory can grow
to (see "Mutable globals are poisoned"), so the call runs until it
actually reads or writes the enclosing frame, and then traps. Taking the
address of an enclosing variable (`ref` argument) does not trap. The AST
interpreter rejects that as well; `compilable/interpret3.d` was made
mode-neutral for it (`test8608`). Functions with a dual context or a
`this` are still rejected up front. A read of an *enclosing-frame
variable* from a frame-less function still poisons the build
(`visitSymbol`). Nested codegen normally compiles the enclosing function
first, to get frame offsets. That step is skipped while the parent is
still in semantic3; the `static assert` sits inside it.

Variables declared inside the wrapped expression are re-parented to the
wrapper for the duration of the build, then restored. One example is the
stack temp for an array literal passed to a `scope` parameter.
Otherwise they look like enclosing-frame variables, and `&(null ctx)`
asserted in `cgcs`.

`hasNestedFrameRefs()` is not enough on its own. References made from a
ctfe-scope (`static foreach` aggregate lambdas, `enum` initializers)
skip `checkNestedReference`, so the outer variable never lands in
`closureVars`. `ipReadsOuterLocals` scans the nested body, including
`DeclarationExp` initializers, for locals owned by another function.
Without it, `static foreach (a, b; array)` over an enclosing
`immutable int[32] array = 1` read garbage through the null context.
When the poison fires on a struct or static-array variable, `visitSymbol`
returns a dummy local of the right type, not an integer 0; the
surrounding e2ir code asserts on a struct-typed non-lvalue before the
poison takes effect.

### `a ~ f(a)` evaluation order

`_d_arraycatnTX` takes `auto ref` operands, so an lvalue operand is
passed by reference and read after later operands have run. Natively,
`val ~ cat11ret3(val)` (the callee appends to `val`) yields the
post-call `val`. `runnable/evalorder.d` carries a FIXME for that. CTFE
is left-to-right. During engine builds, `visitCat` spills earlier lvalue
operands into temporaries when a later operand has side effects.

### `typeid(C).name` at CTFE is now fully qualified

The AST interpreter used to return the bare identifier (`"Tiger"`), while
runtime `TypeInfo_Class.name` is qualified (`"typeid_name.Tiger"`). The
engine runs the real TypeInfo, so it returns the qualified name. The AST
interpreter was aligned (`toPrettyChars`) and `compilable/typeid_name.d`
updated.

### Pointer results are rebuilt from the allocation log

The host bump allocator records every allocation (base, requested size).
A pointer result is looked up in that log and rebuilt in the AST
interpreter's shapes. A pointer to the start of a one-struct allocation
becomes `&S(...)`. Anything else becomes `&[...][i]` over the whole
allocation, read as an array of the pointee type. Structs and arrays are
memoized by address, so cycles and sharing survive (`&S(1, <recursion>)`).
Pointers into static data or the stack are not decodable, so they fall back.

The allocation's type is unknown. `0 in [0:0]` points at the value
inside an AA `Entry`, which the engine decodes as `&[0, 0][1]`. The AST
interpreter gives `&[0][0]`. Dereferencing gives the same result, so
verify compares the pointees, not the shapes.

`new T` at module scope has no `_d_newitemT` lowering, because
`needsCodegen()` is false there. Engine builds allocate through
`_d_allocmemory` and blit `T.init`, as they already did for classes.

### AA results are read through the CTFE order table

An AA result is an `Impl*`. The data extents that `selfLink` records
give the address of `core.internal.newaa.ctfeOrders`, and the decoder
walks that table's entries for the impl. The result is an
`AssocArrayLiteralExp` in insertion order, which is exactly the AST
interpreter's order. A null impl decodes as `null`.

### Unions decode to the active member

Memory doesn't say which union member was written last, so engine builds
record it (see "Active union members"). The decoder keeps the recorded
member and leaves the others `null`. When no member of a group was
recorded, it keeps the explicitly initialized member, else the first
declared one, as the AST interpreter's default initialization does. Verify
compares union structs, and classes containing unions, by their encoded
bytes instead of by shape.

### Enclosing `const` locals are hoisted into the wrapper

`static assert(bowie == 4001)` inside a function reads a `const` local
whose initializer is itself CTFE (`space()`). The wrapper function gets
a `DeclarationExp` for each such local, transitively through their
initializers, and the locals are re-parented for the build. Mutable
locals and parameters still fail, like in the AST interpreter.
The `$` length variables of `a[0 .. $]` count as declared by their
`SliceExp`/`IndexExp`.

### Top-level array operations are unrolled

`enum int[2] D = A[1 .. 3] * 6;` never reaches `_arrayOp`, because array
operations outside a function body are not lowered by semantic. The
engine unrolls them into an `ArrayLiteralExp` of per-element
expressions (`A[1] * 6, A[2] * 6`), recursing for nested arrays. An
operand whose array depth is lower than the result's is broadcast, so
`[[1, 2], [3, 4]] + [10, 20]` adds `[10, 20]` to each row. The length
comes from a static array type, an array literal or a slice with
constant bounds. Operands containing calls would be evaluated once per
element, so those still fail. Unary array operations (`-A[]`) at top
level trip an assert in the AST interpreter too.

### Function pointer and delegate results

Table indices are mapped back to function symbols through the selflink
table names and the list of functions built for the engine. A function
literal becomes a `FuncExp`, a plain function a `SymOffExp`. Delegates
with a non-null context pointer are not decoded yet.

### Strict mode

`DMD_CTFE=strict` is the no-fallback switch. The engine also runs under
`global.gag` (inside `__traits(compiles)`, speculative instances), and
whenever it returns nothing for a non-literal expression the compile
fails with `wasm-ctfe cannot evaluate` and the last `ipFallback`
reason. `tmp/ctfe2/strictsweep.sh` compiles every test file this way
with `-o-`. Literal detection is now deep: an array, struct or AA
literal counts only when its elements are literals. Constant folding
results are accepted on the same condition, which avoids an engine
build for most `enum` and `static if` conditions.

### Engine builds run semantic3 between attempts

A worklist function that has not had semantic3 used to be analysed in
the middle of the engine build, and any CTFE it triggered was deferred
to the AST interpreter. Now the build records such functions, returns,
runs `ipForceSemantic3` on each (gagged, with a pre-semantic flag that
still keeps new template instances off the host object), and retries.
Nested CTFE during that pre-semantic phase gets its own engine build,
because no build is in flight. After 64 attempts the build gives up.
Errors that occurred before the build started no longer stop it:
`glueHasErrors()` compares against the error count at build start.

### Codegen-only functions are built too

`static foreach` aggregate lambdas and `@__ctfe` functions are marked
`skipCodegen`, and semantic skips the druntime hook lowerings in
`sc.ctfe` scopes. With a CTFE mode active, array appends (`~=`) in ctfe
scopes are lowered to `_d_arrayappendT`/`_d_arrayappendcTX` anyway,
including the `__res ~= x` that builds the `static foreach` index array.
The lowering only happens when `object` declares the hook, so custom
runtimes without it are unaffected; an append left unlowered poisons the
engine build instead of asserting. Other hooks stay unlowered in ctfe
scopes: lowering them all breaks the AST interpreter (`__ArrayCast`
reinterpret errors) and runtimes without the hooks. Engine builds
ignore `skipCodegen`, `-profile` prologs and `-profile=gc` tracing.

### CTFE during host codegen

Host codegen runs semantic lazily: `finishVtbl` analyses virtual
functions, and `TypeInfo_toDt` instantiates `RTInfo!T`. Both can call
CTFE, which means an engine build while the host object file is half
written. The backend is global state, so an engine build used to
clobber it. The host's text segment index ended up in the wasm
`SegData`, and host `csym`s were reused by the engine and then wiped
(`barray.d` assert at `obj_end`, `test23166`). An engine build during
host codegen now stashes and restores:

- `objmod`, `SegData`, `cseg`, `funcsym_p` and `bzeroSymbol`
- runtime-library symbols, `el` string table, readonly cache and the
  string-literal table
- every `csym`/`sinit`/`deferToObj` the host created, `PASS.obj`
  markers (else the engine skips functions the host already emitted)
  and `TypeInfoDeclaration.hadCodegen`
- struct-literal symbols

The fixup list needs no stash, since only the ELF, Mach-O and COFF
writers use it. The DWARF section handles survive because restoring the
host backend does not set them up a second time.

Per-function backend state (`globsym`, blocks) is not stashed. Instead,
TypeInfo data requested while a host function is being generated is
emitted after that function. An engine build that is still requested
mid-function is refused. `-cov` counters are not emitted in engine
builds, since they would reference the host's coverage symbol.

### Array operations on integer arrays with a floating operand

`enum r = A[] * 0.5;` with `int[] A` gives `[0, 0, ...]` in the AST
interpreter, which multiplies as integers. The engine computes the
element type from the expression (`double`), like compiled code does,
and gives `[0.5, ...]`.

### `real` is 80-bit, computed on the host

Wasm has no 80-bit float, and the wasm backend normally treats `real`
as `double`. That would change CTFE results. Engine builds instead keep
the host layout: `real` takes 16 bytes in memory, holding the x87
80-bit value followed by zero padding. In registers it is a `v128`.
Every `real` operation becomes a call to a host import
(`__wasmctfe_real_add`, `_cmp`, `_toI64`, ...). The host evaluates it
with its own `real` and `CTFloat`, like the AST interpreter does, so
results are bit-identical. The pieces:

- `backend/wasm/softreal.d` holds the helper symbols.
- `codgen.d` routes `real` binops, relops, conditions, unary math and
  conversions to the helpers. Loads, stores and constants use `v128`.
- `backend_init_wasm_ctfe` sets `_tysize[TYreal]` to the host size.
- `el_bin` no longer shrinks `real` constants to `double` for wasm.
  That x87-only optimization produced `real op double` trees.
- `long`/`ulong` to `real` conversions skip the lossy `double` step
  that e2ir emits (`OPd_ld(OPs64_d(x))` becomes `fromI64(x)`). Casts
  from `real` to integers use `cast(int)`/`cast(uint)`/`cast(long)`,
  the same as `constfold`.

`core.math.rint` and `rndtol` have no body, so the AST interpreter
rejects them. The engine evaluates them. This applies only when the
host `real` is x87 and the target `realsize` is 16. On other hosts,
`real` still blocks the engine. Complex and imaginary types are still
blocked.

### Forward-referenced field initializers are folded

A class used before its declaration is analysed (`test19941`) can have
fields whose initializer has not been through semantic2. For such a
field, `wasmCtfeAggReady` folds the `ExpInitializer` itself. If the
initializer does not fold to a literal, the aggregate stays blocked.

### Static members of aggregates still in semantic

Members that need `this`, and virtual members, of an aggregate that has
not finished semantic are skipped. Static members are built. Sizing an
aggregate whose `semanticRun` is still `PASS.semantic` would re-enter
its semantic (`test23589`: circular `cols_two`, so `tstr` is marked as
failed for good). `Type_toCtype` poisons the build instead of calling
`determineSize` in that case. The debug-only `Fclass` ctype is not
computed in engine builds.

### Struct copies duplicated side effects

`elstruct` rewrote `*alloc() = init` as a block copy that evaluated
`alloc()` twice. This was an upstream backend bug that the x86 backend
masks. `new Object` got a zero vptr from the second allocation. The copy
now requires a side-effect-free lvalue.

### Other decoding details

- An integer cast to a pointer (`cast(int*) 8`) decodes back to an
  integer-valued pointer, not a dereference.
- A class result from a build without ClassInfo decodes by static type,
  if the class has no subclasses in the build.
- `noreturn` fields decode to their default initializer.
- A nested function without a frame gets an explicit null context
  argument when called directly.

### Unions and reinterpretation are allowed

Function bodies may use unions and anonymous unions. Reading a member
other than the last one written reinterprets the bytes, as it does at
run time. The AST interpreter rejects this ("reinterpretation through
overlapped field"). Wasm memory is little-endian on every host, so the
result is the same everywhere. A pointer read back as an integer is an
engine address. It is deterministic but means nothing outside the
engine.

### `extern(C++)` classes

A C++ vtable has no `ClassInfo` slot, so the dynamic class of a result
can't be read from memory. `selfLink` records the address of every
`__vtblZ` symbol, and the engine maps each C++ class in the build to its
vtable address. A downcast between C++ classes is a paint at run time,
but CTFE checks the dynamic type. Engine builds lower it to the host
import `__wasmctfe_cppcast(obj, targetVtbl)`, which returns `null` when
the object isn't a `targetVtbl` class or a subclass of it.

### `scope` class destruction

`delete` of a `scope` class variable calls `_d_callfinalizer`, which is
in `rt` and not in the build. Engine builds call the destructors of the
allocated class directly, most derived first, as the AST interpreter
does. They stop after the first destructor of a non-D class. The vptr is
not cleared and the memory is not reset.

### Virtual functions are built lazily

Emitting a vtable used to pull in every virtual function and force
semantic3 on it. For dmd's own `Type` hierarchy that reached unrelated
code whose semantic failed at that point. A vtable entry for a function
without semantic3 is now an import. If the program calls it, the host
records the function and traps. The host then runs semantic3 on it and
rebuilds and reruns the evaluation, up to 32 times. The AST interpreter
also runs semantic3 only on functions it calls.

### Legality scan follows the build

The static scan skips the dead branch of `if (__ctfe)` and
`if (!__ctfe)`, like codegen does. It doesn't enter nested aggregates or
templates, whose members are scanned when they are called. Manifest
constants are skipped. Functions nested in a `unittest` are built with
the evaluation, not deferred to the unittest.

### Field initializers without semantic

A class built during CTFE can have field initializers that haven't been
through semantic. `membersToDt` runs `getConstInitializer` on them, like
the AST interpreter does when it builds a class literal.

### `-betterC`

Engine builds ignore `-betterC` for the lowerings they need.
`checkaction=C` and `checkaction=halt` become `checkaction=D` during a
build, because `__assert_fail` and `hlt` have no CTFE meaning. The GC
lowerings for `new`, `~` and `~=` are generated even when `useGC` is
off, and `_d_arrayappendcTX` in druntime no longer has a `-betterC`
body of `assert(0)`: it uses `typeid(T)` only when `D_TypeInfo` is
available. The AST interpreter never cared about `-betterC` either.

### Functions that fail to build become traps

A function called from the evaluated expression can fail to build even
though the AST interpreter never reaches the failing part, or never
calls it at all. Examples are functions containing inline assembly,
`__traits` that only work at runtime, or code whose semantic errors are
gagged. When a function other than the root poisons the build or
produces gagged errors, the build is retried with that function as an
import. Calling the import traps with `cannot build X: reason`, which in
strict mode becomes the error. A module with such stubs is not cached,
because the next evaluation may not need the stub at all.

### C allocation and `errno`

`malloc`, `calloc`, `realloc` and `free` bind to the host bump
allocator, and `free` does nothing. `gc_addRange` and `gc_removeRange`
do nothing. `__errno_location` returns a cell in guest memory, which is
reset with the heap. This lets code that manages its own memory through
`core.stdc.stdlib` run at CTFE, which the AST interpreter rejects.

### `foreach` over strings with a different character type

`foreach (dchar c; string)` and the other transcoding loops lower to
`_aApplycd1` and friends in `rt`, which are not in the build. The host
implements all 18 variants (`_aApply[R]XY{1,2}`): it decodes the
array, re-encodes each character to the loop type, and calls the loop
body through the function table with a temporary in guest memory.
Invalid UTF traps, like the AST interpreter's error.

### Class results are identified by vtable address

Class references in a result used to be decoded by the `ClassInfo`
name, which is ambiguous for nested classes and classes in templates
with the same pretty name. Every class the build emits now records its
vtable address, and decoding looks up the vptr first. Cyclic object
graphs are tracked by address, so a class that refers to itself no
longer hits the depth limit.

### Associative array iteration order matches run time

The guest uses the real druntime AA implementation, so `.keys`,
`.values` and `foreach` visit entries in hash order, the same order as
the compiled program. The AST interpreter visits them in insertion
order. `runnable/interpret.d` asserted the insertion order of `.keys`
and `.values`; those checks now compare the elements without regard to
order, and the `[4:true, 5:true].keys` initializer was rewritten so both
engines produce the same array.

### Nested classes get their outer pointer

`new Inner(...)` inside a member function of `Outer` stores `this` in
the hidden outer pointer of the new object. The AST interpreter ignores
the `thisexp` of a `NewExp` and leaves the field `null`
(`compilable/test22292.d`). The guest runs the real constructor
lowering and stores the pointer. Verify mode accepts a `null` outer
pointer from the AST interpreter.

### Comparing cyclic results in verify mode

`wasmCtfeCompare` recursed through class references up to a fixed depth.
Two objects that point at each other twice (`TestA` with two fields
referring to one `TestB`, which points back) made the comparison
exponential, and `test22292` grew to 18 GB before the kernel killed it.
The comparison now tracks the pairs of struct literals in progress.

### Result cache keys include literal values and symbol identity

Results are cached by the location and text of the expression plus the
symbols it references. `static foreach` bodies produce many expressions
with the same location and text that differ only in the value of the
loop symbol, which is not always visible in the text: in
`tests[tok].description` the index `tok` has already been folded into
the AA lookup lowering. The unittest runner's
`__traits(getAttributes)` on 179 generated unittests all got the first
attribute. Keys now include the address of each referenced symbol and
the text of every literal in the expression, including lowerings.

### Temporaries declared in module-level expressions

An expression at module scope can declare a temporary, for example the
copy made for an rvalue passed to a `ref` parameter under
`-preview=rvaluerefparam` (`compilable/fix21647.d`). Its parent is the
module, so `isDataseg` caches `true` and the legality scan rejected it
as a mutable global. The wrapper function now takes over the variable
and its `isDataseg` cache for the duration of the build.

### Address of an immutable global

`&globalS` where `globalS` is `immutable` with an initializer is
allowed, like reading it (`compilable/issue24316.d`). Mutable globals are
covered by the next section.

### Mutable globals are poisoned

The AST interpreter lets CTFE take the address of a mutable global or
static local, do arithmetic on it and compare it, but not read or write
through it. The legality scan used to reject any mention of a mutable
global. It now records its mangled name in `wasmSelfLinkPoisonNames`,
and the wasm object writer places such symbols at 0xF000_0000 and above
instead of in the data section. No bytes are emitted for them, and CTFE
builds declare the memory with a maximum of 0xF000 pages, so any load or
store traps while the address stays valid. A pointer into the poisoned
area is decoded back to `&global + offset` by symbol name
(`interpret3.bug9745`). Druntime's own globals (the trusted modules) are
never poisoned; a mutable druntime global in scanned code is still
rejected. Compiler temporaries (`STC.temp`) such as the `__critsec` of a
`synchronized` block are plain guest data, and the critical section and
monitor hooks are host no-ops.

Slicing a mutable global without reading it now succeeds, so
`test9745(7)` in `interpret3.d` was made mode-neutral.

### Circular initialization

`immutable int i = i;` made the build of the initializer request the
value of `i` again, which printed the error once from the nested
evaluation and once from the outer one (`fail_compilation/ice12827.d`).
The engine now checks up front for a reference to a constant whose
initializer is being evaluated and reports "circular initialization"
like the AST interpreter. The check only looks at the expression
itself; a cycle through a called function is still reported as a
failed evaluation in strict mode.

### `D main` keeps its declared signature

The wasm backend gives `_Dmain` the fixed signature
`(i32, i32) -> i32` so the start code can call any form of `main`. In a
CTFE build `main()` is an ordinary function called with its declared
arguments (`enum forceCtfe = main();` in
`runnable/class_destructors.d`), so the normalisation is skipped.

### Template instances used only in `if (__ctfe)` blocks

With the engine active, druntime hooks are lowered inside `if (__ctfe)`
blocks so the guest can run them. Their template instances, for example
`__arrayAlloc!char` from `new char[5]`, were then emitted into the host
object file, where they reference the GC. Under `-betterC` that failed
to link (`runnable/test18472.d`). Instances created in such a block are
now marked `ctfeOnly` and are never emitted by the host. If the same
instance is later needed outside a `__ctfe` block, the flag is cleared.

### `-betterC` attribute inference with engine lowerings

Under `-betterC` a template function that uses the GC is inferred as
not `@nogc` and marked `skipCodegen`, so that it can still run at
compile time. The engine lowers `~` to `_d_arraycatnTX` even under
`-betterC`, and the call to that non-`@nogc` hook ended `@nogc`
inference before the `CatExp` itself was checked. The function was then
emitted and failed with "requires the GC" (`compilable/test23606.d`).
Hook calls that exist only because of the engine no longer take part in
`@nogc` inference. For the same reason `new T[n]` inside an `if (__ctfe)`
block no longer marks the function `skipCodegen`.

### `_d_arrayappendcTX` under `-betterC`

Without `D_TypeInfo` the druntime hook asserts. It now has an
`if (__ctfe)` path that allocates with `GC.malloc` and copies, which
the guest can run. The host removes the branch, so compiled `-betterC`
code does not reference the GC. An earlier version rewrote the whole
hook to work without `TypeInfo`, which made every `-betterC` program
with an append in a `@__ctfe` function fail to link once the
`druntime/import` copy was refreshed.

### Integer-to-pointer casts are tagged

`cast(int*) 123` is a pointer that must not be dereferenced at compile
time. In the guest, address 123 is ordinary memory, and the value read
would depend on the layout of the build. In CTFE builds a non-null
integer converted to a pointer is XORed with `wasmCtfeIntPtrTag`
(1 << 48), both for `CastExp` and for pointer-typed `IntegerExp` constants
that the frontend folded. Converting a pointer back to an integer XORs
again, so round trips give the original value, and comparisons and
arithmetic between such pointers still work. A dereference traps because
the address is far outside memory. Result decoding strips the tag before
building the `cast(T*) n` expression.

### Null pointers

Address 0 is writable wasm memory, so a null dereference does not trap
by itself. Null checks are forced on in CTFE builds (see below), which
covers `*p` and member access. Two other paths needed their own checks:
slicing a pointer (`p[0 .. n]` with `p is null` and a non-zero length),
and the host `memcpy`, `memset`, `memcmp` and `_memset*` imports, which
trap on any range that touches the first four bytes. Nothing is placed
there because `dataHeap` starts at 4. `null[0 .. 0]` with a length only
known at run time stays valid (`std.array.Appender.put`).

### Checks are always on in CTFE builds

Bounds checks, asserts and null checks are switched on for the duration
of a build, whatever `-release`, `-check` or `-boundscheck` say, and
`checkaction=C` or `halt` become `D`. CTFE reports these errors under all
switches. Out-of-range shift counts on 32 and 64-bit operands call
`__wasmctfe_shift_error`, which the AST interpreter also reports.

### Exception chaining

An exception thrown from a `finally` block that runs because of another
exception must be chained to it (`Throwable.next`), or replace it with
`bypassedException` set when the new one is an `Error` and the old one is
not. In CTFE builds the lowering of `try`/`finally` extracts the D object
of the in-flight `exnref` at the landing pad (a `try_table` with a
`catch` of the D tag around `throw_ref`) into a shadow slot, and wraps
the finally body in a catch whose handler throws
`__wasmctfe_chain(e1, e2)`. The host import implements
`Throwable.chainTogether` and the `Error` bypass on guest memory. Code
compiled for a real wasm target does not chain yet.

### Class invariants

`assert(obj)` calls `rt.invariant_._d_invariant`, which is not in the
importable druntime. The host implements it: it walks the `ClassInfo`
chain of the object and calls each `classInvariant` through the function
table.

### What the engine allows that the AST interpreter rejects

The following run in the engine and are deterministic and sandboxed, so
they are allowed. Tests that asserted they fail at compile time were
changed to record the result in an `enum` instead.

- D-style variadic functions (`runnable/test42.d`).
- Reading a `= void` local or field: CTFE builds zero-initialize them
  (`interpret3.bug6438`).
- Writing through a string literal.
- `<` and `>` between pointers into different allocations.
- Pointer arithmetic and dereference outside the bounds of an allocation,
  as long as it stays inside guest memory (`interpret3.test14028b`,
  `ptrDeref`). The result depends on the build's memory layout.
- Reinterpreting casts between pointer types, arrays and pointers, and
  `void*` arithmetic (`interpret3.badpointer`, `bug6386`, `bug6420`), and
  reading an `int[]` as `byte[]` (`bug7780`). Wasm is little-endian, like
  every dmd target.
- Reading an inactive union member (`bug6681`), unless it reads a pointer
  as non-pointer data or the other way around (see "Pointers in unions").
  `fail_compilation/fail19123.d`, `test16284.d`, `diag11756.d` and
  `dbitfields.d` moved to `compilable/` and assert the reinterpreted
  values.
- `= void` locals and fields returned from CTFE or read through a
  default-initialized struct (`ice14055.d`, `ctfe10995.d`, now in
  `compilable/`).
- Slice assignment to a `__vector` (`ice20042.d`, now in `compilable/`).
- Casting away `immutable` from an array and writing through it
  (`fail14304.d` keeps only its first, pointer-cast error). The write only
  changes the engine's copy of the data.
- Slicing a pointer to a local (`bug7785`), and returning the address of a
  local without dereferencing it (`test7876`).
- `typeid(int).toString()` (`bug10579`).
- Floating point is computed at the precision of the type, not in
  `real`. `interpret3.classtest1` compared a `float` to a `double`
  literal and relied on the extra precision; it now compares to `2.6f`.
  `compilable/paranoia_ctfe.d -version=Single` reports 0 defects in the
  engine and 1 with the AST interpreter, so verify mode reports a
  mismatch there.

`interpret3.ctfeSort6250` indexed a slice of length 1 at index 1, which
throws `RangeError` at run time and in the engine. The AST interpreter
checked against the underlying array. The test now uses `.ptr[1]`.

### Error sites

Errors that the AST interpreter reports from its own checks are reported by
the engine with the same text, so that diagnostics do not depend on which
engine ran. The glue layer finds the construct at compile time and emits a
call to `__wasmctfe_error(kind, site)` (or `__wasmctfe_error2` with two
extra values) in its place, guarded by a run-time condition where the AST
interpreter only fails for some values. `site` indexes the expression.
Nothing is reported unless the code runs: a function that contains a bad
cast in a branch that is never taken still evaluates. When the call traps,
`ipReportSiteError` builds the message from the site expression and adds
the call chain.

| Kind | Construct | Message |
|---|---|---|
| 1, 2 | read of an unreadable or circularly initialized static | `variable ... cannot be read at compile time`, `circular initialization of ...` |
| 3 | `switch` without a matching case | `no case label for ...` |
| 4 | overlapping or mismatched slice copy | same as the AST interpreter |
| 5, 6 | `SymOffExp` that reinterprets its variable | `reinterpreting cast ...`, `cannot convert ...` |
| 7 | pointer cast that reinterprets the pointee | `reinterpreting cast from ... is not supported in CTFE` |
| 8 | address of an imported symbol | `cannot take address of imported symbol ...` |
| 9 | `throw null` | `to be thrown ... must be non-null` |
| 10, 13 | array cast between element types of different layout, hex string length | `array cast from ... is not supported at compile time` |
| 11 | cast of a `noreturn` value | `cannot cast ... at compile time` |
| 12 | address of the `.init` symbol of a dynamic array | `cannot determine the address of the initializer symbol` |
| 14 | `.init` of a struct whose default initializer has errors | the initializer's errors |
| 15 | `new` of a class with a field that is being initialized | `circular reference to ...` |
| 16 | real pointer cast to an integer | `cannot cast ... to ... at compile time` |
| 17 | placement `new` | ``new ( ... )` PlacementExpression cannot be evaluated at compile time`` |
| 18 | field of `typeid(T)` other than `name` | `... is not yet implemented at compile time` |
| 19 | C function that ends without `return` | `no return value from function` |
| 20 | slice of a pointer past its allocation | `pointer slice [..] exceeds allocated memory block [..]` |
| 21 | slice of a `null` array | `slice [..] is out of bounds` |
| 22 | union member read that reinterprets pointers | `reinterpretation through overlapped field ...` |

Casts in trusted (druntime) modules, compiler-generated functions and C
files are exempt from kinds 5 to 16, since they are lowerings rather than
user code.

A few checks are not tied to a site. A call to a function without a body
reaches the stub import for its mangled name, which reports `cannot be
interpreted at compile time, because it has no available source code`.
A root expression that calls a type (`int(int)(3)`) or applies an array
operation to a string literal is rejected by the legality scan with the
AST interpreter's message.

Some kinds need facts known only at run time. Kind 16 compares the
pointer against the tag used for integer-to-pointer casts, so a round
trip `cast(size_t) cast(int*) 123` still works. Kind 20 looks the pointer
up in the allocation log and the data segment map and measures the slice
in elements of the pointer's type; a string literal's terminating zero is
not part of its block. Pointers into the stack are not checked. Kind 21
is emitted only on the path where the bounds check already failed and the
array's pointer is `null`, and reports at the declaration of the variable
the slice was taken from, as the AST interpreter reports at the location
of the `null` literal.

### Pointers in unions

Reading a union member reinterprets its bytes (see "Unions and
reinterpretation are allowed"), except where a pointer would be read as
something else or be forged from non-pointer data. For a member whose
pointer offsets differ from an overlapping member's, the glue layer
calls `__wasmctfe_union(info, op, address)` on each access. A write (an
assignment to the member, or taking its address) records the member as
active at that address; a read checks the active members recorded over
its bytes. Declaring a local of a type that contains such a union clears
the records for its storage. Members with the same pointer layout, such
as `size_t*` and `struct { size_t* p; }`, are not checked. The records are
the same ones that "Active union members" describes.

### Discarded roots

A root expression whose type the engine cannot return, and a `noreturn`
root, are run in a `void` wrapper only to surface their errors. Side
effects of that run (`__ctfeWrite`, coverage counts) are suppressed. If
the run succeeds, the expression falls back as before.

### Recursion limit

The AST interpreter stops at 1000 nested calls with "CTFE recursion
limit exceeded". The engine has no call counter: deep recursion runs
until the guest stack is exhausted and wasmtime traps. If the call chain
of the trap repeats the same call at least 16 times, the engine prints
the AST interpreter's message, including the fixed text "1000 recursive
calls", although the real depth depends on the frame sizes.

### `__ctfeWrite`

`__ctfeWrite` is a host import that prints, except in verify mode where
the AST interpreter already printed. An evaluation that printed is not
put in the result cache, because a cache hit would skip the output.

### Appends and `-profile=gc`

`~=` of an element without postblit or destructor has no druntime
lowering in some contexts. CTFE builds call the host import
`__wasmctfe_append` for it. `core.internal.profile_gc` wraps its hooks in
`scope(exit)` accounting that calls into `rt`; those statements are now
`scope(exit) if (!__ctfe)`, so the lowered hooks run in the guest under
`-profile=gc`.

### Other lowering details

- Nested associative array literals inside a lowered AA literal get their
  own semantic when the engine lowering is active, so the inner literal
  is lowered too.
- A `$` variable of a slice at module scope is a static with an
  initializer. CTFE builds use the initializer instead of the variable.
- `if (__ctfe || x)` and `?:` / `&&` / `||` with `__ctfe` are folded the
  same way by the legality scan and by codegen.
- `!is(T)`-style `NotExp` of a `TypeExp` evaluates to `false` directly.
- An `immutable` or `const` global with a string literal initializer is
  answered with a copy of the literal, without a build.


### 32-bit targets

With `-m32` the frontend has `size_t == uint` and 4-byte pointers, so the
CTFE build is a wasm32 module (memory32, `i32` stack pointer) rather than
the wasm64 used for 64-bit targets. `backend_init_wasm_ctfe` picks the
model from `target.isLP64`. On the host side every pointer-sized value
goes through `ipPS` (the target pointer size): `ipValP`/`ipSetP` read and
write host-call arguments and results, `ipLdP`/`ipStP` read and write
pointer-sized words in guest memory, and struct layouts known to the host
(`BlkInfo`, `Interface`, slices, AA buckets) use multiples of `ipPS`.

- The integer-to-pointer tag is `0xF800_0000` instead of `1 << 48`. Small
  integers cast to pointers land in the poisoned range and trap on access.
  Integers at or above `0xF800_0000` cast to pointers alias ordinary
  memory; accessing them does not trap.
- x87 `real` is 12 bytes on 32-bit x86 (10 bytes plus 2 padding). Soft
  real still carries the value in a `v128`, but stores write only 12
  bytes (`v128.store64_lane` plus `v128.store32_lane`) so they do not
  clobber the next field. Loads still read 16 bytes.
- Poisoned globals sit at `0xF000_0000` and above. In wasm32 that is a
  negative `i32.const`, so the self-linker patches data addresses in
  `i32.const` with a signed LEB128.

### Nested struct context pointers in results

A nested struct returned from CTFE carries its context pointer. For a
function called without a frame, that pointer is the `wasmCtfeNoFrame`
marker. The AST interpreter always produces `null` for the hidden `this`
field of a struct literal, and the glue layer asserts that it is `null`.
The decoder writes `null` for that field, and turns the marker into
`null` wherever else it shows up.

### Null checks on pointer indexing and `typeid`

`p[i]` on a null pointer reads address `i * T.sizeof`, which is valid
memory, and `typeid(obj)` on a null class reference reads the vtable
from address 0. In 64-bit builds the second read happened to trap on the
data at address 4; in 32-bit builds it silently returned `null`. CTFE
builds now add a null check on the base pointer of a pointer `IndexExp`
and on the object of a class `typeid`.

### Identity of literals with complex fields

`T.init is T.init` where `T` has a `cfloat` field cannot be built (complex
types block the engine). If both sides of `is`/`==`/`!=` fold to
literals, the engine compares them directly: struct literals field by
field, `ComplexExp`/`RealExp` with bitwise identity for `is` and IEEE
equality for `==`.

### `-cov=ctfe`

The AST interpreter counts each statement it runs into
`Module.ctfe_cov`. CTFE builds with `-cov=ctfe` call the host import
`__wasmctfe_cov(module, line)` in place of the usual `__coverage` counter
increment. `module` is an index into `wasmCtfeCovModules`. The engine's
result cache skips repeated evaluations, so counts can be lower than the
AST interpreter's. Only whether a line was hit is reliable.

### `-ftime-trace`

The `Ctfe:` event now wraps the engine as well as the AST interpreter.
When the expression is a call, the engine also emits a `Ctfe: call` event
with the callee and arguments. The AST interpreter emits one of those for
every function it interprets; the engine only emits one for the outermost
call. Code generation for CTFE builds does not emit `Codegen: function`
events.

### One program for the whole compilation

Every root used to get its own self-contained module, so a callee such as
`std.format`'s internals was generated and compiled again in each module
that reached it, and each module had its own memory, table and store.
Builds now share one store. `wasmSelfLinkShared` makes the object writer
emit a module that imports memory, table, stack pointer and exception tag
from `env`, exports every function it defines, and places data at
`wasmSelfLinkDataBase` and table entries at `wasmSelfLinkTableBase`, both
taken from the end of the program so far. `wasmCtfeQueueDefinition` skips
symbols in the library (`wasmCtfeCommitEmitted`), which turns references to
them into imports resolved by the linker.

The program is thrown away and rebuilt from nothing ("flush") when
something already committed turns out to be wrong: a module defines a name
the program bound to a host stub or to a different function, a global that
was committed as data has to be poisoned, or a lazy virtual function was
already called directly.
`DMD_CTFE_STATS` prints the module, temporary-module and flush counts.

### Functions are analysed before the build

The build used to discover functions without `semantic3` one attempt at a
time: emit everything, find the functions that were missing, analyse them,
emit everything again. `format` needed 77 attempts' worth of emission for
65 modules and emitted 1518 function bodies to keep 579. The walk in
`wasmCtfePreSemantic3` follows what code generation will reference: calls
(virtual ones included, since `callfunc` takes the symbol of the statically
bound function), lowerings, `new`, `typeid`, `catch` types, casts, function
and delegate literals, and the initializers of static variables. For a
struct type it adds the functions its `TypeInfo` points at. Functions
referenced only from data (vtables, class and interface `TypeInfo`) are not
analysed: those are built when they already have `semantic3` and become
lazy imports otherwise (`wasmCtfeDataCtx`). The retry loop is still there
for what the walk misses.

### Glue expressions are folded on the host

Most expression roots are not computations. Importing Phobos evaluated
hundreds of roots like `[cast(ubyte) 1, 2]`, `"abc"[]`, `cond ? a : b` with
a constant condition, or `flags | toFlag(x)`, and each one cost a module:
about 0.4 ms even when the module only contains the wrapper. Two of these
cases hid behind `optimize` itself. It folds the elements of an array
literal in place and returns the same node, and it leaves `lit[]` as a
`SliceExp`; both are now recognised as folded. 2000 roots of the form
`[f(N), f(N + 1) + 1]` went from 0.85 s to 0.08 s, with one module instead
of 2001.

A sub-expression that was folded in place has no separate result; the
unrolled array operation and tuple elements copy the literal themselves
(`ipSubExpr`).

### Struct arguments with slice fields

The direct-call path writes literal arguments into guest memory. A struct
argument whose fields are slices (`asTrie(TrieEntry(x"...", x"...",
x"..."))` in `std.uni`) was refused and went through a wrapper module. The
slice payloads are now written behind the struct and the fields point at
them.

### Overloads can share a mangled name

`string f(T)(T x)` and `string f(T)(T y)` have the same mangled name and
are selected by named arguments. The direct-call result cache was keyed by
mangled name and arguments, which the host fold tier exposed: `f(y: 0)`
returned the cached result of `f(x: 0)`. The key now includes the function's
identity. The shared program links by name too: a later module that called
the first `f` was bound to the second. A module that defines a name the
program already has, for a function declared somewhere else, now flushes
the program. Both overloads in one module still collapse into one function,
as they do in a native object file.

### `-lib` builds

`TypeInfo_toObjFile` passes `global.params.multiobj`, which with `-lib`
appends the `TypeInfo` to the host's list of objects to write later. During
an engine build that left the `TypeInfo` undefined in the module, and the
build failed with an unresolved symbol. This broke building druntime's
static library. Engine builds never use multiobj.

### Extern globals

An `extern` variable has no definition to emit. A function that mentions
one and is reached only through a vtable is not covered by the legality
scan, so the module had an unresolved data symbol and the whole evaluation
failed (`std.datetime.timezone`'s `LocalTime` reads `tzname`). Engine
builds now define extern variables in the poisoned address range and turn
reads into the "static variable cannot be read at compile time" error site,
so only an evaluation that actually reads one fails.

### Functions with a constant body

`std.meta.staticIndexOf` and `core.lifetime` call hundreds of lambdas and
template functions whose body is `return 3;` after `static if` has picked a
branch. Each one cost a module. When the statements of a body are
declarations without run-time effect (`enum`, `alias`, imports, nested
functions and types), `if` with a constant condition, and a `return` whose
expression folds to a literal, the direct-call path returns that literal
(`ipFoldConstBody`). The arguments are validated first, so a call with an
argument that is not known at compile time still reports it. Struct
literals of nested structs are left to the engine, because their hidden
context field is part of the result, and nothing is folded under
`-cov=ctfe`. Compiling sumtype's unittests went from 960 modules to 575.

### No fuel

The store used to run with `consume_fuel` and a budget of two billion
instructions per call, as a guard against CTFE that does not terminate.
Fuel is compiled into every function as a counter update per block, and
for a module of a few hundred bytes that doubled the time spent in
Cranelift (519 to 281 microseconds for a 190 byte lambda). It is off now.
A non-terminating loop in CTFE hangs the compiler, as it does with the AST
interpreter. Infinite recursion still traps on the stack limit.

### Hidden return pointer symbols

`FuncDeclaration.shidden` caches the backend symbol of the hidden pointer a
function returns a struct through. An engine build of a function set it
for the wasm calling convention, and the host build of the same function
found it already set and reused it. When the inliner turned the result
into a named return value (`vthis.nrvo`), the host wrote the result through
a symbol that did not belong to its function. `core.time.Duration.zero` and
`dur!"hours"` in a druntime built by the engine-mode compiler returned
garbage, and every program using vibe-core or dub crashed at startup.
`shidden` is now part of the per-declaration state that is exchanged
between host and engine (`hostSymExchange`) and wiped after a build
(`wasmCtfeWipeCaches`). Test: `runnable/ctfe_nrvo_host.d`.

### Integer arrays that came from a string literal

Phobos stores its Unicode tables as hex strings cast to
`immutable(size_t)[]`. The AST interpreter passes such a `StringExp`
through CTFE by reference, so `static immutable res = asTrie(entries)`
ends up with the same `StringExp`, and the glue layer writes a
`StringExp` to read-only data. The engine decoded the slice from memory as
an `ArrayLiteralExp`, which the glue layer writes to `.data`: 250 KB of
tables in `libphobos2.a` moved from `.rodata` to `.data`.
Every `StringExp` with a non-character element type that goes into engine
memory, as an argument (`ipEncodeArg`) or through the glue layer
(`wasmCtfeNoteString`), is now remembered by content. A decoded slice with
the same bytes and element type becomes a copy of that `StringExp`.
Test: `compilable/ctfe_hexstring_result.d`.

### Host code compared between modes

The engine shares the glue layer and the per-declaration backend state
with host code generation, so a leak shows up as different host code. To
look for leaks, druntime and Phobos are built as `-lib` archives with the
engine and with `DMD_CTFE=off`, and every defined symbol is compared by
content and relocations. druntime is identical apart from one numbered
`ModuleInfo`. Phobos differs in 74 of 17795 symbols, all understood:

- 67 `std.conv.enumRep` strings are in `.rodata` with the engine and in
  `.data` with the AST interpreter, which returns a character array built
  by appending as an `ArrayLiteralExp`, where the engine returns a
  `StringExp`.
- 5 `core.internal.newaa` instances for `std.json` are emitted in a
  different order. The backend inlines a `pragma(inline, true)` callee
  only when its code was generated before the caller's, so the order
  decides whether `_d_aaLen` contains two calls or none.
- 2 `ModuleInfo` symbols (`fiber`, `uuid`) carry a counter in their name
  that differs between the two builds.

35 template instances that only CTFE uses are emitted by the AST
interpreter build and not by the engine build.

### C math functions

The backend lowers `%` on `float` and `double`, and the `core.math`
intrinsics `sin`, `cos`, `ldexp`, `rint` and `rndtol` on those types, to
calls of `fmod`, `sin`, `cos`, `ldexp`, `rint`, `llrint`, `log2` and
`log1p` (with an `f` suffix for `float`). The engine did not provide them,
so any CTFE with a floating point remainder failed (the `color` package
used by ggplotd computes hue angles with `h % 1`). They are now host
imports (`ipHostLibm`) that compute in `real`, as the AST interpreter's
builtins do, and round to the argument type. `rint` and `rndtol` have no
source for the AST interpreter, so the engine now evaluates calls that
`DMD_CTFE=off` rejects. Test: `compilable/ctfe_libm.d`.

### Negative floating point values cast to `uint`

`cast(uint)` of a `double` used `i32.trunc_sat_f64_u`, which turns every
negative value into 0. The host compiles the conversion with a 64-bit
signed truncation and keeps the low 32 bits, so `cast(uint) -128.0` is
`0xFFFFFF80`, and the AST interpreter agrees. The `color` package used by
ggplotd packs signed normalized integers that way
(`floatToNormBits!(9, true)(-0.5) == 0x180`). `OPd_u32` is now
`i64.trunc_sat_f64_s` followed by `i32.wrap_i64`.
Test: `compilable/ctfe_neg_to_uint.d`.

### `void[]` results

A `void[]` result, such as `cast(immutable(void)[]) import("file")` passed
through a function, was rejected as a result type. The AST interpreter
represents it as a `StringExp` of bytes, and the engine now decodes it
the same way. dwt stores its resource files like this.
Test: `compilable/ctfe_void_array_result.d`.

### Slice assignment order in the wasm backend

For `a = [len(a)]` the wasm backend stored the length half of the new
slice into `a` before evaluating the pointer half, which contains the
call, so `len` saw the new length. Both halves of an `OPpair` are now
evaluated into locals before either is stored. This affected the wasm
target as well as the engine. diet-ng generated a filter chain without its
interpolation because of it. Test: `compilable/ctfe_slice_assign_order.d`.

### Members of a struct that is still in semantic

A member function that needs `this` was not built while its aggregate was
still in semantic, because the layout could change. For a struct whose
size is already determined the layout is final, so its members are now
built. mir's `Date` computes `enum _startDict = Date(1900, 1, 1)._dayNumber`
inside `Date`. Test: `compilable/ctfe_unfinished_struct_ctor.d`.

### `typeof(null)` results

A function returning `typeof(null)`, as the lambda in
`std.format.checkFormatException` does for arguments that cannot throw,
was rejected as a result type. It is now decoded as `null`, and only from
a zero pointer, so it never claims the bytes of another union member.
Test: `compilable/ctfe_null_result.d`.

### Generated `opCmp` and `opEquals` of TypeInfo

The legality scan queues `xeq` and `xcmp` of every struct type it meets.
`functionSemantic3` lifts the gag for functions outside speculative
instances, so the scan reported the error of a generated `__xopCmp` whose
`opCmp` template does not match, such as `Tuple` with a member without
`opCmp` (dxml). The host runs these through `semanticTypeInfoMembers`,
which keeps the gag and falls back to `xerrcmp`, and the scan now does the
same. Test: `compilable/ctfe_typeinfo_opcmp.d`.

### Template instance cycles

When a `ctfeOnly` instance is used again outside CTFE, the frontend moves
the new instance's `tinst` to it. With the engine forcing semantic3 of the
instance's functions, that reuse can happen inside the instance itself, and
`tinst` pointed to the instance, which the nesting check reports as
recursive expansion (Pegged). The move now skips a `tinst` chain that
already contains the instance. Test: `compilable/ctfe_tinst_cycle.d`.

### Active union members

The AST interpreter knows which member of a union was written last. The
engine used to decode a union from its bytes and pick the widest member,
so a tagged union holding a smaller member failed to decode (mir
`Algebraic`, `std.json.JSONValue`, `std.sumtype.SumType` in argparse and
serialized). Engine builds now keep a record per written member, keyed by
its address, in a sorted array on the host. It is reset for every call.

- An assignment to a member, a slice assignment to it, taking its address
  and passing it to a mutable `ref` parameter call
  `__wasmctfe_union(info, 1, address)`. The call replaces the records
  inside the member's bytes and those of the overlapping siblings.
- Struct literals record each explicitly initialized overlapped field.
- Declaring a local whose type contains a union clears its storage
  (`op 2`).
- Copies of a type that contains a union (`OPstreq`, `memcpy`, by-value
  parameters) call `__wasmctfe_unioncopy(dst, src, n)`, which moves the
  records with the bytes. The host-side copies (appends, `realloc`,
  `memset`, array growth) do the same. `toctype` marks these types with
  `STRoverlap`, and `elstruct` leaves them in memory, since a copy through
  a register cannot carry the records.

Test: `compilable/ctfe_union_active.d`.

### Nested builds fall back to the AST interpreter

Generating the `TypeInfo` of a struct during an engine build runs
`semanticTypeInfoMembers`, which can run semantic3 of `toString` and a
string mixin in it (dub-registry). That CTFE is requested while a build
is in progress, and the engine can't start another. In strict mode the
request used to fail. It is now marked as deferred (`wasmCtfeDeferred`),
and `ctfeInterpret` evaluates it with the AST interpreter. Test:
`compilable/ctfe_typeinfo_nested_build.d`.

### `static immutable` without an initializer

A `static immutable` field set in a `shared static this` has no
initializer at compile time (ae's and sdc's `pageSize`). The legality scan
rejected functions that mention it as reading a mutable global. It is now
poisoned like a mutable global, so only an actual read traps. Test:
`compilable/ctfe_uninit_immutable_global.d`.

### Host builtins need literal arguments

The host evaluates calls to builtins such as `sqrt` directly when the
wrapper's arguments are literals. `sqrt(sqrt(16.0))` passed a call
expression, which `eval_sqrt` asserted on (mir-random). The host path now
requires every argument to be a literal. Test:
`compilable/ctfe_nested_builtin.d`.

### Callees whose `semantic3` is in progress

`std.format.checkFormatException` for sdc's `Value.dump` formats
`Args.init` of a `MapResult` whose `front` calls `Value.dump` again,
which is still in `semantic3`. The legality scan rejected the whole
evaluation because a callee was pending. The AST interpreter never calls
`front` on the empty range. A pending callee now leaves the caller
pending instead of rejected, and the root is accepted when its own
`semantic3` is done. The build skips the pending function, so calling it
traps as an unresolved import. Test: `compilable/ctfe_pending_callee.d`.

### Appends lowered only for the engine

The AST interpreter evaluates `~=` directly, so the frontend lowers it to
`_d_arrayappendcTX` only in code that is generated, and never for the
index array of a `static foreach` over a range. Engine builds lower it in
both places. The hook instances took the root module as `minst` and were
emitted into the host object, together with the `TypeInfo` of the
`static foreach` tuple, whose `__xopEquals` and `__xtoHash` were never
generated (serialized failed to link). Such lowerings now run with
`ctfeBlock` set, so their instances are `ctfeOnly`. Test:
`compilable/ctfe_static_foreach_link.d`.

### `float` and `double` round in the engine

The AST interpreter computes `float` and `double` expressions in `real`
without rounding intermediate results, so `f(1) == 1.0 / 3` can hold for
a `float` function `f`. The engine computes in IEEE `float` and `double`,
like the program would at run time. This makes ggplotd's test fail in
engine mode. The difference is intentional and won't be fixed.
