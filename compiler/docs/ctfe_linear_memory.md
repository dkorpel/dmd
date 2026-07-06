# CTFE Linear Memory

Design document for replacing AST-node intermediate values in CTFE with a
linear (flat byte) memory representation, similar to WebAssembly linear memory.

Status: **Phases 1–4 and 6 done**, gated behind `-preview=ctfeLinearMemory`.
Phase 5 (reference tier) is not started — values involving classes, AAs,
delegates, or pointers simply stay on the AST path. See [Phases](#phases)
and [Implementation notes](#implementation-notes-as-built).

Code:
- `compiler/src/dmd/ctfememory.d` — arenas, allocation table, checked
  access, encode/decode (in-module unittests cover the memory layer)
- `compiler/src/dmd/dinterpret.d` — interpreter integration (scalar tier,
  slice tier, fast paths, flip-to-AST materialization)
- `compiler/test/unit/semantic/ctfememory.d` — typed round-trip tests
  (`./run.d -u unit/semantic/ctfememory.d`)
- `compiler/test/benchmark/ctfe/` — benchmark corpus and runner

## Motivation

Every intermediate value during CTFE is currently a region-allocated AST class
instance (`ctfeEmplaceExp` in `dinterpret.d`). The interpreter stack is an
array of `Expression` references (`CtfeStack.values`), and the exit path
deep-copies region-owned expressions back to GC memory (`copyRegionExp`).

A single `int` intermediate costs a full `IntegerExp` instance — vtable
pointer, `Loc`, `Type` pointer, `EXP` tag — roughly 40–56 bytes plus allocator
overhead, versus 4 bytes of payload. Aggregates are worse: a
`StructLiteralExp` holds an `Expressions` array of pointers to further
heap-allocated nodes. This inflates peak memory for CTFE-heavy builds
(`ctRegex`, `std.format`, string mixin generators) and causes heavy allocation
traffic.

## Design

### Arenas

Two growable `ubyte[]` arenas hold all intermediate values:

- **Stack arena** — one frame per CTFE function call. Locals are laid out at
  their natural `Type.size()` / `Type.alignsize()` offsets. The layout is the
  same one dmd already computes for codegen, which guarantees that struct and
  union layout during CTFE matches target semantics. Frames are popped on
  function return.
- **Heap arena** — allocations that outlive a frame: `new` expressions, array
  literals, closures, exception objects thrown during interpretation. Bump
  allocated, released wholesale when the outermost CTFE invocation ends
  (mirroring the current `ctfeGlobals.region` savePos/release discipline).

Little endian is assumed: scalars are stored raw and host loads/stores operate
directly on the bytes.

### Safety model

No memory corruption may be possible, regardless of what the interpreted code
does:

- **No raw host pointers escape.** A CTFE pointer is a fat handle
  `{allocId, offset}`. An allocation table maps `allocId` to
  `{arena, base, size, live, type}`.
- **Every load and store is checked**: the `allocId` must be live and
  `offset + accessSize <= size`. A failed check produces a clean CTFE error,
  never undefined behavior in the compiler.
- **Popping a frame marks its allocations dead**, so dereferencing a dangling
  pointer to a former stack local is caught deterministically (better
  diagnostics than the current representation offers).
- **References are not bytes.** Pointers, class references, delegates, and
  associative array handles are stored as 32-bit indices into a
  per-allocation reference-slot table, with a shadow bitmap marking which
  offsets are reference slots. Reading a reference slot as an integer through
  a union remains an error. Reinterpreting plain-old-data bytes
  (int ↔ float, int ↔ ubyte[4]) becomes allowed — it is just a byte read, and
  is safe by construction.
- **Pointer arithmetic keeps provenance**: only the offset changes; the
  `allocId` is fixed. Comparing or subtracting pointers into different
  allocations remains an error, as today.

### Boundary conversion

The entry point and result of CTFE remain AST nodes, so conversion goes both
ways:

- **Entry**: `encode(Expression, Type, ref Arena) → Handle` recursively
  serializes argument literals (`IntegerExp`, `RealExp`, `StringExp`,
  `ArrayLiteralExp`, `StructLiteralExp`, `AddrExp`, …) and referenced global
  constants into the arena.
- **Exit**: `decode(Handle, Type, Loc) → Expression` rebuilds a literal AST
  expression from the bytes. This replaces the `scrubReturnValue` /
  `copyRegionExp` deep-copy machinery.

Source location data is dropped for intermediate values. Diagnostics use the
interpreter's current statement location (already tracked in `InterState`);
the decoded result expression receives the CTFE call-site `Loc`.

### Migration representation

During migration, the interpreter's value type is a tagged union
`CtfeValue = { Handle | Expression }`. Each language construct migrates to the
linear representation independently; unsupported constructs fall back to the
Expression path. The new path is gated behind a flag so the old path remains
available as a reference oracle — differential testing runs both and compares
decoded results.

## Phases

1. ✅ **Benchmark harness** (`compiler/test/benchmark/ctfe/`). Corpus: synthetic
   CTFE stress programs (loops, struct arrays, string building). Measures wall
   time and peak RSS; `bench.sh` emits a baseline-vs-new comparison table
   (`AFLAGS`/`BFLAGS` compare one binary with/without the preview flag).
   Baseline recorded in the benchmark README before any interpreter change.
2. ✅ **Core module** (`compiler/src/dmd/ctfememory.d`): arenas, allocation
   table, fat handles, checked load/store, encode/decode for scalars, structs,
   and static arrays. Standalone unit tests including out-of-bounds and
   dangling-pointer cases.
3. ✅ **Interpreter integration, scalar tier**: scalar locals live in linear
   frames; assignment, compound assignment, and ++/-- operate on raw bytes.
4. ✅ **Aggregates**: dynamic arrays as `{allocId, offset, length}` handles
   with heap-arena payloads; element reads/writes, `.length`, `.length = n`,
   `~=`, slicing, slice arguments, `new T[](n)`, handle assignment with
   sharing semantics matching AST literal aliasing.
5. ⬜ **Reference tier**: classes, associative arrays, delegates, closures via
   reference-slot tables. Not started; such values stay AST nodes (the
   fallback is automatic, see the flip rule below), so this is purely a
   further optimization, not a correctness gap.
6. ✅ **Unions**: plain-old-data reinterpretation is allowed for values in
   linear memory (dynamic array elements): the bytes are the value, reading
   any member reinterprets them, little endian. Locals and AST-resident
   values keep the standard "reinterpretation through overlapped field"
   error. Reference slots never enter linear memory (phase 5 not done), so
   the overlap-with-references error is preserved trivially.
7. 🔶 **Full validation**: full compiler test suite (compilable,
   fail_compilation, runnable) passes in default mode; a CTFE-heavy battery
   (interpret3/4/5, ctfe_math, reinterpretctfe, ctfesimd, __ctfeWrite plus
   targeted linear-memory tests) passes with the preview flag; druntime and
   all of Phobos build with the patched compiler (including `-unittest`
   under `-preview=dip1000`), and every Phobos module front-end-compiles
   cleanly with the preview flag. `std.regex` unittests, the heaviest
   ctRegex CTFE load available, measured with a PGO-optimized compiler:
   peak RSS 1611 → 804 MiB (−50%), wall time at parity with master
   (2.94 → 2.92 s; −1% to −3% across runs, within noise).
   Dub-package validation and a decision on retiring the Expression path
   are still open. The Expression path remains both the fallback and the
   differential-testing oracle.

## Implementation notes (as built)

- Preview flag: `-preview=ctfeLinearMemory` (off by default; default-mode
  behavior is unchanged).
- Per stack entry, the representation invariant is: if
  `CtfeStack.values[adr]` is non-null the AST node wins; otherwise a valid
  linear slot holds the value. `VarDeclaration.ctfeLinearKind` caches which
  tier a variable can use (scalar, slice, slice-through-reference, none).
- **Flip to AST**: any load the linear fast paths don't support materializes
  the value into an AST literal once (`materializeLinearSlice`), after which
  the AST node is canonical. A materialized payload is marked *escaped* and
  all other handles to it lazily redirect to the same canonical node, so
  aliasing semantics are identical to sharing one literal node. This makes
  every unsupported construct safe by construction: worst case is the old
  representation.
- **Sharing**: handle assignment (`b = a`) marks the payload shared. Element
  writes through shared payloads mutate shared state (same as a shared
  literal node); `~=` detaches with a copy (same as `ctfeCat`); `.length = n`
  on a shared payload falls back to AST (matching
  `changeArrayLiteralLength`'s element-node aliasing).
- Function arguments are staged into caller-frame linear slots where
  possible, so scalar and slice parameters bind without AST allocation.
- **Linear slice returns**: when a call's result is about to be stored
  straight into a slice-eligible variable (`v = f(...)`, including through
  `ref` parameters), the caller offers a hand-over channel
  (`CtfeGlobals.linearReturnDest`, taken and cleared at `visit(CallExp)`
  entry so nested calls cannot consume it). A `return <slice-var>;` in the
  callee then transfers the 16-byte handle instead of materializing the
  whole array; `return f(...);` chains the offer to the inner call. This
  matches AST semantics exactly: a return does not copy CTFE-owned literals,
  so both representations return a live reference to the same array object.
  Payloads live in the heap arena, so the handle outlives the callee frame;
  sharing needs no extra marking because any aliasing event before the
  hand-over already set the sticky `payloadShared` flag.
- `v.length = n` on a shared payload detaches with a byte copy when the
  element type is scalar (fresh storage, matching `changeArrayLiteralLength`,
  where element-node sharing is unobservable for scalars); struct/sarray
  elements keep observable node aliasing and stay on the AST path. A
  resize of a non-empty AST-resident array also stays AST: adopting it
  into linear memory would force a whole-array decode wherever the value
  escapes back to an AST consumer (typically a struct field), turning
  every resize-and-return call into an encode + decode round trip.
- Heap-arena payloads are freed wholesale when the outermost CTFE invocation
  ends; stack frames are popped LIFO but payload alloc-ids are not reused
  before the wholesale reset, so dangling handles stay detectable.

- **Byte-native scalar expressions** (`tryEvalScalarRaw`): originally every
  scalar read decoded bytes into a fresh `IntegerExp` for the AST-based
  evaluator, which under an -O3+PGO compiler made the linear path *slower*
  than the AST path (whose reads return a cached node pointer and whose
  region bump-allocator is nearly free). Now whole side-effect-free integral
  expression trees — variable/element/field reads, arithmetic, shifts,
  comparisons, `&&`/`||`/`?:`, casts, `.length` — evaluate directly on raw
  64-bit values with no intermediate nodes; `x op= expr` and ++/-- also
  read-modify-write the slot bytes directly, and integral call arguments
  stage as raw bytes. The discipline is total bail-out: at any unsupported
  node the evaluator returns false *before anything observable happens*
  (supported nodes are all side-effect-free, and error cases like division
  by zero bail too), so the generic path re-evaluates and reports. This was
  deliberately scoped as an incremental experiment — a few hundred lines —
  to gauge the headroom before deciding on a full bytecode/WASM-style
  interpreter rewrite.

Performance (ldc2 -O3 -flto=full + PGO compiler, hyperfine, x86_64 Linux;
full table in `compiler/test/benchmark/ctfe/README.md`): peak memory drops
48–81% on aggregate-heavy cases (string_build 132 → 25 MiB, whole-Phobos
ctRegex unittest compile 1611 → 804 MiB). Time wins on loop, aggregate,
and array-returning code: int_loop −35%, string_build −57%, sort_array
−20%, struct_array −10%, std.regex unittests at parity with master (−1%
to −3% across runs, within noise). The slice-return channel
was decisive for real-world code: before it, ctRegex's resize-and-return
helpers (std.uni `GcPolicy.realloc`, `_dupCtfe`) decoded 13.2 million array
elements back to AST nodes per std.regex build; with the hand-over plus the
adopt-only-empty-arrays rule for `.length =`, that dropped 96%, flipping
std.regex from +18% to parity. What still loses is scalar call-dominated code
(deep_calls +30%): the remaining overhead is per-call machinery (argument
staging, slot binding, scalar return-value decode), which a raw-value
calling convention — i.e. the full bytecode interpreter — would be needed
to eliminate. Benchmark conclusions drawn from an unoptimized host-dmd
build are misleading — the AST path benefits disproportionately from an
optimized compiler binary.

## Risks

- `dinterpret.d` is ~7600 lines; the touch surface is large. Mitigation:
  per-construct migration with the old path as a differential-testing oracle.
- Associative array keys and template value parameters need equality and
  hashing over linear values (currently Expression comparison in
  `ctfeexpr.d`).
- Exception objects thrown during CTFE cross stack frames and must live in the
  heap arena.
- `void`-initialized data and unions whose fields overlap reference slots must
  keep producing errors per the spec.
