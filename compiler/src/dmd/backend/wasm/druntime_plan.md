# WASM Druntime Compatibility Plan

Goal: incrementally make DMD's runnable test suite pass on WASM without
modifying druntime's existing cross-platform modules.  The strategy is to
provide a thin WASM-specific runtime library (`druntime/src/rt/wasm/`) that
supplies all the hooks the compiler and object.d call into, at the minimum
fidelity needed to pass tests.

## Constraints

- **No threads, fibers, int128, or C-library extensions** — out of scope for now.
- **GC = bump allocator** — `gc_malloc` bumps a pointer and never frees.
  No scanning, no finalizers, no GC pressure.
- **Exceptions → compile-time error or runtime `unreachable`** — any code path
  that would `throw` calls a stub that traps (`unreachable` in WASM).
  The compiler already rejects `-fno-exceptions` violations; add a similar
  gate for WASM.
- **TypeInfo and ClassInfo must work** — vtable layout, `typeid`, `is`
  expressions, and `cast(T)` dynamic casts all depend on these.
- **`assert` must work** — failures should print a message and trap.
- **Module constructors/destructors must run** — `rt_moduleCtor` / `rt_moduleDtor`.

## Phase 4 — Arrays and strings with runtime support

**Goal:** `arr ~= x`, `arr.length = n`, string concatenation all work.

The compiler lowers these to template instantiations in
`core/internal/array/`.  These are pure-D templates that call `GC.realloc`
— they should work once Phase 1's GC stubs are present.

Key hooks:
- `_d_arrayappendcTX` — `arr ~= singleElement`
- `_d_arrayappendT` — `arr ~= otherSlice`
- `_d_arraysetlengthT` — `arr.length = n`
- `_d_arrayassign_l` / `_d_arrayassign_r` — element-wise copy with dtors
- `_d_arraycopy` — `arr[] = other[]`
- `_d_arrayappendcd` / `_d_arrayappendwd` — `str ~= dchar` (in lifetime.d)

**Action:** compile `core/internal/array/*.d` for WASM; fix any missing
platform guards.

**Completion check:** `auto a = [1,2,3]; a ~= 4; assert(a.length == 4);`
runs in wasmtime.

---

## Phase 5 — Module constructors and static data

**Goal:** module-level `__gshared` variables with initializers, `static this()`,
and `shared static this()` all run before `main`.

This requires `rt_moduleCtor` to correctly traverse the `ModuleInfo` linked
list.  The existing `rt/minfo.d` does this; the only obstacle is TLS
(thread-local storage) constructors.

**Action:** add `version (WebAssembly)` inside `rt/minfo.d` to skip the
`rt_moduleTlsCtor` call (TLS does not exist in single-threaded WASM).

**Completion check:**
```d
__gshared int x;
shared static this() { x = 42; }
void main() { assert(x == 42); }
```

---

## Phase 6 — Interfaces and `Object` methods

**Goal:** `toString`, `toHash`, `opEquals` work on class instances.

`Object.toString` default returns the class name via `TypeInfo_Class.name`.
`Object.toHash` uses the pointer.  Both are pure D in `object.d`.

**Action:** verify `object.d` final methods compile; provide a stub for
`_d_setSameMutex` (no-op for single-threaded WASM).

Also needed for `writeln(obj)`:

- `core.stdc.stdio` printf — already works via WASI
- `std.conv.to!string` — Phobos, out of scope initially; tests use manual
  `printf` or `write`

---

## Phase 7 — Unit tests

**Goal:** `dmd -mwasm32 -os=wasm -unittest test.d` runs unit tests in wasmtime.

The compiler generates a module-level unit test function and a
`__unittestResults` variable.  `rt/dmain2.d` normally calls
`runModuleUnitTests()`.

**Action:** provide a WASM version of `runModuleUnitTests` that:
1. Iterates `ModuleInfo` structs
2. Calls each module's `unitTest` function pointer
3. Prints pass/fail counts to stderr
4. Returns a `UnitTestResult`

Wire this into the WASM `_start` when built with `-unittest`.

---

## Phase 8 — Associative arrays (basic)

**Goal:** `int[string] aa; aa["key"] = 1; assert(aa["key"] == 1);`

The AA runtime is in `rt/aaA.d`.  It uses the GC for all allocation —
with Phase 1's `gc_malloc` stub this should work without changes.

**Action:** verify `rt/aaA.d` compiles for WASM; the TypeInfo pointer
hashing it does is pure D and platform-independent.

---

## Build system

### New directory: `druntime/src/rt/wasm/`

Files:
- `start.d` — `_start`, entry point
- `gc.d` — bump/malloc-based GC stubs
- `sync.d` — no-op monitor/critical stubs
- `errors.d` — `_d_assert*`, `_d_arraybounds*`, `_d_nullpointerp`
- `eh.d` — `_d_throwdwarf` → abort
- `minfo.d` — WASM-specific module info iteration (or thin wrapper)

### Compilation

These files are compiled **only** when targeting WASM.  The DMD driver
(`link.d` / `dmsc.d`) should automatically include them, analogous to how
`deh.d` / `dwarfeh.d` are selected per-platform.

---

## Build system

### Step 1 — `mak/SRCS` (short-term, no Makefile changes)

The `druntime/mak/SRCS` file lists all sources compiled into the normal
druntime static library.  Do **not** add WASM sources there; the existing
build is for the host platform and must not be broken.

Instead, during this incremental phase, compile the WASM runtime sources
explicitly in the test runner (see Testing section below).

### Step 2 — `druntime/Makefile` WASM target (medium-term)

Add a new `wasm` make target that cross-compiles a `libdruntime-wasm.a`:

```makefile
WASM_DMD    ?= dmd
WASM_FLAGS   = -mwasm32 -os=wasm -betterC -conf= -Isrc -Iimport -w -de
WASM_RT_DIR  = src/rt/wasm
WASM_SRCS    = $(WASM_RT_DIR)/start.d \
               $(WASM_RT_DIR)/gc.d \
               $(WASM_RT_DIR)/sync.d \
               $(WASM_RT_DIR)/errors.d \
               $(WASM_RT_DIR)/eh.d \
               $(WASM_RT_DIR)/minfo.d \
               src/object.d \
               src/rt/minfo.d \
               src/rt/lifetime.d \
               src/rt/arraycat.d \
               src/rt/aApply.d \
               src/rt/aApplyR.d \
               src/rt/aaA.d \
               src/core/internal/array/appending.d \
               src/core/internal/array/capacity.d \
               src/core/internal/array/construction.d \
               src/core/internal/array/concatenation.d \
               src/core/internal/array/arrayassign.d

WASM_LIB = generated/wasm/libdruntime-wasm.a

.PHONY: wasm
wasm: $(WASM_LIB)

$(WASM_LIB): $(WASM_SRCS)
	$(WASM_DMD) -lib $(WASM_FLAGS) -of$@ $(WASM_SRCS)
```

The `-betterC` flag is **not** used; the WASM stubs themselves use full D
(they import `object.d`).  What `-betterC` would exclude is exactly what
we're implementing.

---

## Testing strategy

### During development (no pre-built druntime)

The compiler test runner (`compiler/test/d_do_test.d`) already detects WASM
tests via `-os=wasm`.  Extend it to compile the WASM runtime sources
alongside the test file:

```d
// In d_do_test.d, WASM branch:
if (isWasm && !betterC)
{
    extraSources ~= druntimeWasmSrcs; // glob druntime/src/rt/wasm/*.d + shared srcs
    dflags ~= "-Idruntime/src";
}
```

This means each test compiles with the runtime sources included directly —
slow but no pre-build step required.

### Once `libdruntime-wasm.a` is built

Switch the test runner to link against the pre-built archive:

```makefile
# compiler/test/Makefile (wasm tests)
WASM_DRUNTIME = $(ROOT)/../druntime/generated/wasm/libdruntime-wasm.a

runnable/%.wasm: runnable/%.d $(WASM_DRUNTIME)
	$(DMD) -mwasm32 -os=wasm $< $(WASM_DRUNTIME) -of$@
	wasmtime $@ $(EXECUTE_ARGS)
```

### Incremental test gating

Each test file that exercises a feature not yet working gets:

```d
// DISABLED: wasm
```

Remove the disable annotation as each phase lands, verifying with:

```sh
cd compiler/test
./run.d runnable/classtest.d -mwasm32 -os=wasm
```

A CI job running `./run.d runnable -mwasm32 -os=wasm` (skipping `DISABLED`)
tracks overall progress.

---

## Test progression (runnable tests, incremental)

| Phase | Tests unlocked |
|-------|---------------|
| 1 (startup) | trivial `void main() {}` |
| 2 (assert/abort) | any test using `assert` without GC |
| 3 (classes/TypeInfo) | OOP tests, `typeid`, `cast` |
| 4 (arrays) | `arrayop.d`, `arraycat.d`, slice tests |
| 5 (module ctors) | tests with static initializers |
| 6 (Object methods) | tests using `.toString`, `==` on objects |
| 7 (unittests) | `bettercUnittest.d`, unit test blocks |
| 8 (AAs) | `aApply.d`, AA-heavy tests |

The test runner (`d_do_test.d`) already supports WASM via wasmtime.
For each phase, add `DISABLED: wasm` overrides on tests that require
out-of-scope features, and remove `DISABLED` as features land.

---

## What stays out of scope

- `core.thread`, `core.sync.*` — no threading in WASM MVP
- Fibers / coroutines — require stack-switching not available in WASM
- `real` (80-bit float) — no equivalent in WASM; already stubbed
- Dynamic loading (`rt_loadLibrary`) — no dlopen in WASM
- Stack traces / backtraces — `_d_traceContext` returns null
- Signal handling — no signals in WASI
- `core.sys.*` OS bindings beyond WASI — excluded by `version(WebAssembly)`
