# Running the glue layer and backend from the frontend

The wasm CTFE engine (`dmd.wasmctfe`, see `wasmctfe.md`) evaluates CTFE by
running `toObjFile` and the backend for a wasm64 target while semantic
analysis is still in progress. The glue layer and backend were written for a
single pass after semantic analysis is complete, and calling them from the
middle of the frontend has caused the problems below.

## 1. Semantic analysis is not finished

The glue layer assumes every symbol it sees has been fully analysed. CTFE runs
long before that.

- Module-level `enum` initializers are evaluated during semantic2, before any
  function has had semantic3. The engine forces `semantic3` on the functions
  it builds (`ipForceSemantic3`). When that fails, the error surfaces earlier
  and in a different form than with the AST interpreter, for example "CTFE
  failed because of previous errors".
- Globals and fields can reach the build with initializers that have not been
  through semantic. `Initializer_toDt` crashed on an array initializer
  without a type (`fail19447`). `membersToDt` and the glue now run
  `getConstInitializer` on such initializers first.
- Sizing an aggregate whose `semanticRun` is still `PASS.semantic` re-enters
  its semantic (`test23589`). Only static members of such aggregates are
  built.
- Merely inspecting the AST has side effects. Calling `functionSemantic3` or
  `isDataseg` from the legality scan advanced analysis of symbols that were
  not ready, producing forward reference errors (`opover2`) and flipping
  `__traits(compiles)` results (`template9`).

## 2. Re-entrancy

The backend is global state. CTFE can now happen inside a build, and a build
can happen inside host codegen.

- Running semantic3 on a function during a build can instantiate templates
  that run their own CTFE. Nested evaluations are deferred: the build records
  the functions that need semantic3, returns, runs it, and retries.
- Host codegen runs semantic lazily (`finishVtbl`, `RTInfo!T` in
  `TypeInfo_toDt`), which can call CTFE while the host object file is half
  written. The backend state is stashed and restored around the engine build.
- Global maps shared between builds, such as the stub list, have to be saved
  and restored by the outer build so nested evaluations cannot clobber them.

## 3. Template instance ownership

Instances created during a build get `minst = null`, so guest-only
instantiations do not end up in the host object file. When the build forces
semantic3 on real druntime hooks such as `_d_aaEqual`, the inner
instantiations they make became permanently speculative and later failed to
link. `wasmCtfeSuspendMinstNull` and a separate pre-semantic state
(`wasmCtfePreSemEnter`) restore normal rooting for those cases.

The opposite problem appears when the frontend lowers druntime hooks only
for the engine, as it does inside `if (__ctfe)` blocks. The resulting
instances have a host ancestor, and `needsCodegen` emits every child of
an emitted instance, so guest-only instances such as `__arrayAlloc!char`
ended up in the host object file. They are now flagged `ctfeOnly`, which
`needsCodegen` honours until an instantiation outside a `__ctfe` block
clears it.

## 4. The host target leaks into the build

The engine builds for wasm64, but `target.*` still describes the host.

- `-m32` hits an assert in the virtual call path of e2ir
  (`tysize(TYnptr) == 4` when `target.isX86`). It is skipped during builds,
  but the frontend's `size_t` is still 32-bit while the guest is 64-bit, so
  `-m32` is not supported yet (`test9565`, `diag7420`).
- Any OS or target predicate consulted during a build, such as `retStyle`,
  answers for the host.

## 5. Global flags change the lowerings

Several compiler switches change what the glue layer emits in ways that make
no sense at CTFE.

- `-betterC` turns off `useGC`, which skips the GC lowerings for `new`, `~`
  and `~=`. The checks are bypassed while a build is active, and
  `_d_arrayappendcTX` in druntime needed a body that works without TypeInfo.
- `checkaction=C` and `checkaction=halt` emit `__assert_fail` and `hlt`.
  They are switched to `checkaction=D` for the duration of a build.
- `__ctfe` must be true in the guest, and the dead branch of
  `if (__ctfe)` / `if (!__ctfe)` must be removed the same way by codegen and
  by the legality scan.
- Semantic skips the druntime hook lowerings in `sc.ctfe` scopes and marks
  some functions `skipCodegen`. With the engine active, appends in those
  scopes are lowered anyway and such functions are built.

## 6. Builds reach more code than the AST interpreter

The AST interpreter only analyses what it actually calls. The build follows
every reference.

- Emitting a vtable pulled in every virtual function and forced semantic3 on
  it, which reached unrelated code in dmd's own `Type` hierarchy that failed
  at that point. Vtable entries for functions without semantic3 are now
  imports; the host builds the function and reruns only if it is called.
- `core.simd` intrinsics reached the wasm backend, whose `assert(0)` on an
  unsupported operator killed the compiler. During builds unsupported
  operators lower to `unreachable`.
- Functions with inline assembly, runtime-only `__traits`, or gagged semantic
  errors used to fail the whole evaluation. A function other than the root
  that fails to build is now replaced by an import that traps with
  `cannot build X: reason` when called.

## 7. Backend bugs hidden by x86

- `elstruct` rewrote `*alloc() = init` as a block copy that evaluated
  `alloc()` twice. `new Object` got a zero vptr from the second allocation.
  The x86 backend masks this; the copy now requires a side-effect-free
  lvalue.
- The wasm object writer allocated `seg_data` entries with `new`, but stored
  them in an `Rarray` grown with C `realloc`, which the GC does not scan.
  Under `-lowmem` a collection could free them in the middle of a build.

## 8. Module dependencies

- Frontend modules (`dinterpret`, `dscope`, `templatesem`) import
  `dmd.wasmctfe`, which imports the glue layer and backend. The unit-test
  runner builds the frontend with `-version=NoBackend`, so `wasmctfe.d` has a
  stub section for that version.
- Frontend code that must be `pure nothrow @nogc` reads the engine mode
  through a function pointer cast.

## 9. Errors from speculative builds

Building a function the evaluation turns out not to need must not print
anything. Builds therefore run gagged, track poisoning, stub failing
functions, and retry. Gagging also hides real engine bugs, so
`DMD_CTFE_SHOWGAG=1` disables it for debugging.

## 10. CTFE semantics leak into the glue layer and backend

Some CTFE rules cannot be expressed in the frontend, so the glue layer and
the wasm backend check `wasmCtfeBuildActive` / `wasmCGCtfeBuild` and
emit different code:

- `e2ir` tags integer-to-pointer casts and pointer-typed integer
  constants, adds a null check to pointer slicing, zero-initializes
  `= void` locals, and guards shift counts.
- `s2ir` wraps `finally` bodies in a catch that chains exceptions, and
  the block structurer extracts the D object of an in-flight `exnref` for
  it.
- The wasm object writer places poisoned globals outside the memory and
  gives the memory a maximum size. These names are collected by the
  frontend's legality scan, so the writer must only honour them while an
  engine build is active; otherwise a real wasm compilation in the same
  process would move its globals too.

Each of these is a second code path in code shared with normal
compilation, and the object writer depends on frontend state it cannot
see.

## 11. The backend model is global

`backend_init_wasm_ctfe` calls `out_config_init` with the model derived
from `target`, and resizes `TYreal` for soft real. Both are global
backend state that `backend_reinit_host` has to restore. A 32-bit target
gets a wasm32 CTFE module. The host engine then has to read and write
every pointer-sized value at the target width. `backend/wasm` itself was
wasm32 first, so no backend changes were needed apart from the 12-byte
soft-real store and signed data-address relocations.

## 12. Error locations need to survive the backend

Many CTFE errors must name an expression and print the chain of calls
that led to it ("called from here"). The glue layer records the
expression as a site (`wasmCtfeAddSite`) and passes the index to a host
import. Calls record their site in a new `elem.Esite` field, which the
wasm code generator emits into the site table when it lowers the call.

An earlier version kept a map from `elem*` to site. Elems are freed and
reused by the optimizer, so the map returned sites for unrelated calls.
The field travels with the elem, but every optimizer transformation that
replaces a call elem has to carry it: `cgelem.cgel_lvalue` rewrites
`(a, f())` so that the comma node ends up where the call was, and lost the
site until it was copied over. Other rewrites may still drop it; the
result is a missing "called from here" line, not a wrong one.

The `switch` statement's CTFE check shared its condition elem between the
check and the jump, which is invalid in the backend's tree model and
crashed `elem_debug` after the optimizer freed one of them. It is now
copied with `el_copytree`.

## 13. Link results are global too

`wasmSelfLinkDataExtents`, like the table and vtable lists before it, is a
global filled by each self-link. The engine caches modules and runs them
long after the next link, so anything it reads from a link result has to
be copied into the cached module. Resetting the global with
`.length = 0` also reused the array the cached module still referenced;
it is now reset with `= null`.
