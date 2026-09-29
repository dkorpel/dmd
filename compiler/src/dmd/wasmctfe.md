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
cache; the same evaluation succeeds later at top level.

### Array literals allocate through the host bump allocator
The `_d_arrayliteralTX` lowering never runs for ctfe-scope expressions,
so engine builds lower a heap array literal to a
`_d_allocmemory(dim * elemsize)` call (bound to the wasmtime host bump
allocator, same as `gc_malloc`) followed by inline element stores —
the same shape the native lowering produces.

### `~= dchar` runs host-side
`_d_arrayappendcd`/`_d_arrayappendcw` are implemented as host functions:
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

### Frame-free nested functions run with a null context

A `static assert` inside a function body can call that function's nested
functions. The expression wrapper lives at module scope and has no frame.
It is allowed when every enclosing function up to the first non-nested
one has no nested frame refs (`hasNestedFrameRefs()` is false, and there
is no dual context), because nothing can read through the context. In
that case `getEthis` returns a null context during engine builds instead
of erroring. A read of an *enclosing-frame variable* from a frame-less
function still poisons the build (`visitSymbol`). Nested codegen
normally compiles the enclosing function first, to get frame offsets.
That step is skipped while the parent is still in semantic3; the
`static assert` sits inside it.

Variables declared inside the wrapped expression are re-parented to the
wrapper for the duration of the build, then restored. One example is the
stack temp for an array literal passed to a `scope` parameter.
Otherwise they look like enclosing-frame variables, and `&(null ctx)`
asserted in `cgcs`.

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
