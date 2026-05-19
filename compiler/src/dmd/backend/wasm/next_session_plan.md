# DMD WASM backend — next session plan

Two remaining failure clusters in the deepen unittests (after the struct
`__initZ` template fix in commit `b7ae06b0df`). Both reproduce on
`build/bops/array-unittest-wasm-dmd.wasm` (the Arena one) and any of the
larger module unittests like `bops/atomic` (testrunner summary path).

## Repro

```sh
cd /home/dennis/repos/deepen
touch makefile && make build/bops/array-unittest-wasm-dmd.wasm
wasmtime build/bops/array-unittest-wasm-dmd.wasm
```

Build with `-g` (add to makefile rule) for better backtraces.

---

## Bug 1: `Arena.newPage` assert fires

### Symptom
```
abort
_d_assert_msg
_d_assert
_d_assertp
_D4bops9allocator5Arena7newPageMFNaNekZv      <-- assert in here
_D4bops9allocator5Arena8allocateMFNaNlNekkZAh
... Allocator.newArray ... Array.ensureCapacity ... Array.addLength ... Array.put
```

### Suspects
[source/bops/allocator.d:295-326](../../deepen/source/bops/allocator.d#L295) has two asserts:

```d
auto newSize = size_t(1) << (1 + bsr(ArenaPage.sizeof - 1 + size));
if (newSize < size)
    assert(0);                       // line 307: overflow path
...
auto p = malloc(newSize);
...
assert(p);                           // line 321: malloc returned null
```

Most likely candidates:

1. **`bsr` is wrong on size_t (i32 on wasm32).** Recent commit
   `e6f47f1868 "Convert bsf and bsr to I32"` changed bsr's return type.
   If `bsr(small_value)` returns a bogus large number, the `1 <<` shift
   overflows to 0, making `newSize < size`, hitting `assert(0)`.
   Verify by dumping at runtime, or write a minimal D wasm test:
   ```d
   import bops.bitop : bsr;
   pragma(msg, bsr(63));   // should be 5
   pragma(msg, bsr(64));   // should be 6
   ```
   And a runtime check via printf.

2. **`malloc(0)` or huge `malloc` returns null.** Less likely — `lib/libc.a`
   should be standard wasi-libc. Confirm second by adding a printf
   immediately before the assert.

### Investigation steps

- Add a `printf` in `Arena.newPage` printing `size`, `newSize`, and
  `bsr(...)` separately before each assert. Rebuild deepen, rerun.
- If `newSize` is wrong → look at WAT for `_D4bops5bitop3bsr*` and verify
  the `i64.clz` → `i32` wrap path is correct for the actual input type
  (size_t = i32 on wasm32, so the `WASM_I64` branch shouldn't fire).
- Check [compiler/src/dmd/backend/wasm/codgen.d:1947-1967](../compiler/src/dmd/backend/wasm/codgen.d#L1947)
  for `OPbsr`. The `tybasic(e.E1.Ety).wasmType` check — does it agree
  with the result type the frontend expects?

### Likely fix locations
- `compiler/src/dmd/backend/wasm/codgen.d` OPbsr/OPbsf code, OR
- IR generation for `bsr` intrinsic at the call site (size promotion).

---

## Bug 2: `OutBuffer` / `Array.put` crash in testrunner summary

### Symptom
Many simple module unittests succeed individually but `testrunner.runTests`'s
end-of-suite `stdout.writeln(...)` summary crashes inside `memcpy` called from
`Array!char.put` called from `OutBuffer.opOpAssign!"~"` called from
`bops.stdio.write` / `writeln`.

### Suspects

The testrunner builds a multi-arg formatted summary. `bops.stdio.write` for
N>=2 args allocates a temporary `OutBuffer outbuf;` on the stack and appends
each argument to it. With the `__initZ` fix in `b7ae06b0df`, simple
`SomeStruct s;` declarations now initialize correctly. But the OutBuffer
struct contains an `Array!char` which contains an `Allocator` whose default
tag is `AllocatorTag.gc = 1`.

The questions:
1. Is `OutBuffer.init` actually being emitted with the right bytes
   (alloc tag = 1 at the right offset)?  Check
   `wasm-objdump -x build/bops/atomic-unittest-wasm-dmd.wasm | less` for
   `_D4bops9outbuffer9OutBuffer6__initZ` — segment offset + 16 bytes of
   the segment at that offset.
2. Is the `Allocator.gc` global arena (`globalArena` in
   [allocator.d:80](../../deepen/source/bops/allocator.d#L80)) properly
   zeroed at startup? It's `private static Arena globalArena;` — a TLS
   variable in the frontend but mapped to plain data on wasm.
3. Or is the call ABI broken for the OutBuffer being passed by ref to
   `opOpAssign`? Check the WAT around the `OutBuffer.opOpAssign` call
   — is it passing `&outbuf` correctly?

### Investigation steps

- Dump WAT for one failing test (e.g. atomic):
  `wasm2wat build/bops/atomic-unittest-wasm-dmd.wasm > /tmp/atomic.wat`
- Find the `testrunner.runTests` function and its multi-arg writeln call.
- Find the OutBuffer local: confirm what bytes get copied in.
- Step through manually: where is `globalArena` accessed? Confirm its
  Soffset and that the bytes there are zero.
- If structure looks fine, instrument `Array.put` (deepen side) with a
  printf of `&this`, `_capacity`, `slice.ptr`, `slice.length` to confirm
  what `this` looks like at the failing call.

### Likely fix locations
- Could overlap with Bug 1 if root cause is the same `bsr` issue
  (`newCapacity` in array.d calls `bsr`).
- Could be wasm-backend ABI for ref-struct param to a member function
  (`this` pointer passing) — check [codgen.d](../compiler/src/dmd/backend/wasm/codgen.d)
  call-site emission for member-of-struct methods.
- Could be globalArena initialization — verify TLS-to-data lowering for
  `private static Arena globalArena;`.

### Quick triage
Fix Bug 1 first. If `bsr` is wrong, `Array.newCapacity` (which calls bsr)
will produce garbage capacity values; that alone could cause the
testrunner crash through a corrupted slice.length wraparound. So Bug 1
and Bug 2 may collapse into one fix.

---

## Verification

After each fix:
1. `./compiler/src/build.d` (rebuild dmd)
2. From `compiler/test`: `./run.d wasm` — must still show 0 failures
3. From `/home/dennis/repos/deepen`:
   - `touch makefile && make build/bops/array-unittest-wasm-dmd.wasm`
   - `wasmtime build/bops/array-unittest-wasm-dmd.wasm` — should print test results
4. Smoke test more modules: `for t in atomic bitmanip allocator hash memory; do touch makefile && make build/bops/$t-unittest-wasm-dmd.wasm && wasmtime build/bops/$t-unittest-wasm-dmd.wasm; done`

## Relevant prior commits

- `b7ae06b0df` WASM: emit struct static init template
- `3d29d0030b` WASM: spill address-taken parameters into shadow frame
- `e6f47f1868` Convert bsf and bsr to I32                **← suspect for Bug 1**
- `1aa3496886` struct by ref param
