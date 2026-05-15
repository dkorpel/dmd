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

---

## Phase 1 — Minimal startup: `main()` reaches user code

**Goal:** a trivial `void main() {}` compiles and runs under wasmtime.

### 1.1 Entry point (`rt/wasm/start.d`)

Provide a `_start` export (WASI entry point) that:

```d
module rt.wasm.start;
extern (C) void rt_moduleCtor();
extern (C) void rt_moduleDtor();
extern (C) int main(int argc, char** argv);
extern (C) void _start() {
    rt_moduleCtor();
    main(0, null);
    rt_moduleDtor();
}
```

The existing `rt/dmain2.d` is too heavy (pulls in threads, GC init, etc.).
For WASM we bypass it entirely and wire `_start` directly.

### 1.2 Module info (`rt/wasm/minfo.d`)

`rt_moduleCtor` / `rt_moduleDtor` must iterate `ModuleInfo` structs and call
each module's static constructor in dependency order.  The existing
`rt/minfo.d` is almost usable but pulls in `core.thread` for TLS ctors.

Provide a WASM-specific wrapper that:
- Calls `rt_moduleCtor` from `rt/minfo.d` with TLS stubs disabled, **or**
- Re-implements the iteration using the linker-provided `__start___minfo` /
  `__stop___minfo` symbols (same as the ELF approach).

Use `version (WebAssembly)` guards inside `rt/minfo.d` to skip TLS ctor
iteration, which requires threads.

### 1.3 GC stubs (`rt/wasm/gc.d`)

Implement the full `gc_*` extern(C) surface as a bump allocator:

```d
module rt.wasm.gc;
private __gshared ubyte* heap_ptr;
private __gshared size_t heap_left;

extern (C) void gc_init() nothrow @nogc {
    import core.stdc.stdlib : malloc;
    // Request a large slab; wasmtime grows memory as needed.
    heap_ptr = cast(ubyte*) malloc(4 * 1024 * 1024); // 4 MiB initial
    heap_left = 4 * 1024 * 1024;
}
extern (C) void gc_term() nothrow @nogc {}
extern (C) void* gc_malloc(size_t sz, uint ba = 0, const scope TypeInfo ti = null) nothrow {
    import core.stdc.stdlib : malloc;
    return malloc(sz); // delegate to wasi libc malloc (no GC)
}
extern (C) void* gc_calloc(size_t sz, uint ba = 0, const scope TypeInfo ti = null) nothrow {
    import core.stdc.stdlib : calloc;
    return calloc(1, sz);
}
extern (C) void* gc_realloc(void* p, size_t sz, uint ba = 0, const scope TypeInfo ti = null) nothrow {
    import core.stdc.stdlib : realloc;
    return realloc(p, sz);
}
extern (C) void gc_free(void* p) nothrow @nogc {}   // leak
extern (C) void gc_enable()  nothrow @nogc {}
extern (C) void gc_disable() nothrow @nogc {}
extern (C) void gc_collect() nothrow @nogc {}
extern (C) void gc_minimize() nothrow @nogc {}
extern (C) void gc_addRoot(void* p) nothrow @nogc {}
extern (C) void gc_addRange(void* p, size_t sz, const TypeInfo ti = null) nothrow @nogc {}
extern (C) void gc_removeRoot(void* p) nothrow {}
extern (C) void gc_removeRange(void* p) nothrow {}
extern (C) void* gc_addrOf(void* p) nothrow @nogc { return null; }
extern (C) void gc_runFinalizers(const scope void[] segment) nothrow {}
// BlkInfo query — unused with bump alloc
extern (C) GC.BlkInfo_ gc_query(void* p) pure nothrow { return GC.BlkInfo_.init; }
```

Using `malloc`/`calloc` from wasi-libc is the simplest approach: WASM linear
memory grows automatically and wasi-libc's malloc is already linked in.

### 1.4 Monitor / critical stubs (`rt/wasm/sync.d`)

Provide no-op stubs for all `_d_monitor_*` and `_d_critical_*` hooks.
WASM is single-threaded; these are safe to elide.

```d
extern (C) void _d_monitor_staticctor() @nogc nothrow {}
extern (C) void _d_monitor_staticdtor() @nogc nothrow {}
extern (C) void _d_critical_init() @nogc nothrow {}
extern (C) void _d_critical_term() @nogc nothrow {}
// synchronized blocks use _d_monitorenter / _d_monitorexit
extern (C) void _d_monitorenter(Object h) nothrow {}
extern (C) void _d_monitorexit(Object h) nothrow {}
```

**Completion check:** `dmd -mwasm32 -os=wasm test.d && wasmtime test.wasm`
succeeds for a trivial `void main() {}`.

---

## Phase 2 — Assert, errors, and safe aborts

**Goal:** `assert(cond)` works; failures print a message and trap.

### 2.1 Assert hooks (`rt/wasm/errors.d`)

The compiler lowers `assert(expr)` to a call to one of:

| Symbol | When used |
|--------|-----------|
| `_d_assert(file, line)` | `assert(false)` / simple assert |
| `_d_assertp(file*, line)` | same, pointer form |
| `_d_assert_msg(msg, file, line)` | `assert(expr, msg)` |
| `_d_arrayboundsp(file*, line)` | array index out of bounds |
| `_d_arraybounds_slicep(file*, line, lower, upper, length)` | slice OOB |
| `_d_arraybounds_indexp(file*, line, index, length)` | index OOB |
| `_d_nullpointerp(file*, line)` | null dereference |
| `_d_unittest(file, line)` | unittest failure |
| `_d_unittest_msg(msg, file, line)` | unittest failure with message |

All implementations: `fprintf(stderr, "...", ...)` then `abort()`.
`abort()` in WASI translates to a WASM `unreachable` trap.

Also provide `_d_arraybounds(string file, uint line)` declared in `object.d`
line 2977.

### 2.2 Exceptions → abort (`rt/wasm/eh.d`)

Any `throw` that the compiler emits calls `_d_throwdwarf` (POSIX) or
`_d_throwc` (Windows).  For WASM, provide:

```d
extern (C) noreturn _d_throwdwarf(Throwable o) {
    // Print the message if possible, then trap.
    fprintf(stderr, "Exception thrown (unhandled): %.*s\n",
        cast(int) o.msg.length, o.msg.ptr);
    abort();
}
```

**Compiler gate:** Add a WASM-specific semantic check that `throw` inside a
non-`nothrow` function emits a deprecation or error when targeting WASM,
guiding users to mark their functions `nothrow` or use `assert(false)`.
This is in `compiler/src/dmd/func.d` or `statementsem.d`.

**Completion check:** `assert(2 + 2 == 5)` in a WASM program prints an
error message to stderr and exits with non-zero status (WASM trap).

---

## Phase 3 — Object, TypeInfo, ClassInfo, dynamic cast

**Goal:** `new Foo()`, `typeid(T)`, and `cast(Base) derived` all work.

### 3.1 `_d_newclass` and `_d_newitemU` (`rt/wasm/lifetime.d`)

These are already in `rt/lifetime.d` and call `GC.malloc`.  Since Phase 1
provides `gc_malloc`, `_d_newclass` in the existing `rt/lifetime.d` should
work **as-is** once the GC stubs are in place.

**Action:** test that `rt/lifetime.d` compiles for WASM.  Add
`version (WebAssembly)` guards only where platform-specific imports fail
(e.g., COM object support calls `CoTaskMemAlloc` — exclude with a version
guard).

### 3.2 Array allocation (`_d_newarrayT` / `_d_arraysetlengthT`)

These are template functions in `core/internal/array/`.  They call
`GC.malloc` / `GC.realloc` which both go through the stub.  Should work
as-is once GC stubs compile.

**Action:** verify `core/internal/array/capacity.d` and `appending.d`
compile for WASM (no platform-specific imports expected).

### 3.3 Dynamic cast (`_d_isbaseof`, `_d_toObject`)

Defined in `object.d`.  Pure D code operating on `ClassInfo` chains —
should work without modification.

### 3.4 TypeInfo

`TypeInfo_*` classes are emitted by the compiler into each object file as
`__gshared` variables.  `object.d` defines the base class hierarchy.
No runtime action needed beyond getting `object.d` to compile.

**Action:** ensure `object.d` compiles for WASM.  Known issues:
- `core.atomic` is used for `synchronized (obj)` — the WASM stub in Phase 1
  covers the runtime side; `core.internal.atomic` already has
  `version (WebAssembly)` stubs (use `__atomic_compare_exchange` intrinsic
  or a single-threaded no-op).
- `core.time` / `core.memory` imports — these have `version (WebAssembly)`
  guards already.

**Completion check:**
```d
class Animal { string name() { return "animal"; } }
class Dog : Animal { override string name() { return "dog"; } }
void main() {
    Animal a = new Dog();
    assert(cast(Dog) a !is null);
    assert(typeid(a) == typeid(Dog));
}
```
Runs in wasmtime.

---

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

### Step 3 — auto-link in DMD driver (long-term)

In `compiler/src/dmd/link.d`, inside `runWasmLINK`, add the druntime
archive to the wasm-ld command line when it exists and no `-betterC` flag
is set:

```d
// In runWasmLINK, before building the argv array:
if (!driverParams.betterC)
{
    string druntimeLib = findWasmDruntime(); // looks in well-known paths
    if (druntimeLib.length)
        params.libfiles ~= druntimeLib;
}
```

Until that auto-link is in place, users pass `-L libdruntime-wasm.a`
explicitly, or the test runner does it.

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
