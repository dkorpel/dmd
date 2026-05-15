# LDC2 WebAssembly ABI for D Features

Investigation of how LDC2 (1.42.0 / LLVM 21) compiles D to WASM32.  
Test programs compiled with `-mtriple=wasm32-unknown-unknown -betterC -O0`.

---

## 1. Struct Member Functions

### Calling convention

```d
struct Vec2 {
    float x, y;
    float dot(Vec2 other) { return x * other.x + y * other.y; }
    Vec2 scale(float f)   { return Vec2(x * f, y * f); }
}
```

**Key rules:**

| Case | Signature |
|------|-----------|
| `void-return method` | `(i32 this, params...) → result` |
| `value-return struct method` | `(i32 hidden_ret, i32 this, params...)` |
| `primitive-return method` | `(i32 this, params...) → primitive` |

- `this` is always the **first explicit i32 parameter** (pointer to struct in linear memory).
- Structs returned by value get a **hidden i32 return-pointer prepended before `this`**. The function writes to that address and returns void.
- Fields accessed via `i32.load/store offset=N` where N is the byte offset in the struct.

**Generated WAT for `dot`:**
```wat
(func $dot (param i32 i32) (result f32)   ;; (this, other) -> f32
  local.get 0  f32.load           ;; this.x
  local.get 1  f32.load           ;; other.x
  f32.mul
  local.get 0  f32.load offset=4  ;; this.y
  local.get 1  f32.load offset=4  ;; other.y
  f32.mul
  f32.add)
```

**Generated WAT for `scale` (struct return):**
```wat
(func $scale (param i32 i32 f32)     ;; (ret_ptr, this, f) -> void
  local.get 0                         ;; ret_ptr
  local.get 1  f32.load               ;; this.x
  local.get 2  f32.mul
  f32.store                           ;; ret_ptr[0] = x*f
  local.get 0
  local.get 1  f32.load offset=4     ;; this.y
  local.get 2  f32.mul
  f32.store offset=4)                 ;; ret_ptr[1] = y*f
```

---

## 2. Class Instance Layout

```d
class Base { int val; }
class Derived : Base { int extra; }
```

**Instance memory layout (WASM32, with monitor):**

```
Offset  Size  Field
0       4     vptr  — i32, linear memory address of __vtblZ
4       4     monitor  — i32, always 0 in betterC/WASM
8       4     first user field (Base.val)
12      4     next field (Derived.extra)
```

- Instance size: `4 (vptr) + 4 (monitor) + user fields`
- `Base` instance = 12 bytes, `Derived` instance = 16 bytes.
- The `__initZ` symbol is the default instance data blob placed in the **data section**:
  - First i32 = address of the class's vtable (`__vtblZ`) in linear memory.
  - Remaining bytes = default field values (zeros unless initialized).

**Example init data for Dog (at linear address 44):**
```
\40\00\00\00   ← vptr = 64 = address of Dog.__vtblZ
\00\00\00\00   ← monitor = 0
\00\00\00\00   ← Animal.x = 0 (default)
```

---

## 3. Vtable Layout (`__vtblZ`)

The vtable is an array of **i32 WASM function table indices** stored in the data section.

**Slot assignment** (for a class inheriting from `Object`):

```
Slot  Offset  Contents
0     0       ClassInfo pointer — always 0 (null) in betterC/WASM
1     4       Object.toString    table index
2     8       Object.toHash      table index
3     12      Object.opCmp       table index
4     16      Object.opEquals    table index
5     20      first virtual method  (e.g. sound())
6     24      second virtual method (e.g. doubled())
...
```

Slot byte offset = `slot_index × 4`.

**Dog vtable data** (binary, little-endian i32s):
```
slot 0: 0x00000000  ← ClassInfo (null)
slot 1: 0x00000001  ← toString at table[1]
slot 2: 0x00000002  ← toHash at table[2]
slot 3: 0x00000003  ← opCmp at table[3]
slot 4: 0x00000004  ← opEquals at table[4]
slot 5: 0x00000005  ← Dog.sound at table[5]
slot 6: 0x00000006  ← Animal.doubled at table[6]
```

**Cat vtable** overrides slot 5 with table[7] (Cat.sound):
```
slot 5: 0x00000007  ← Cat.sound
slot 6: 0x00000006  ← Animal.doubled (inherited)
```

---

## 4. Virtual Dispatch

Virtual call sequence for `b.sound()` where `b : Animal`:

```wat
;; 1. Load the vtable pointer (vptr) from instance offset 0
local.get 0        ;; push this (i32)
i32.load           ;; vptr = *this

;; 2. Load the table index from vtable slot (e.g. slot 5 = offset 20)
i32.load offset=20 ;; table_idx = vptr[5]

;; 3. Indirect call through the function table
local.get 0        ;; push this as first arg to callee
local.get 2        ;; save table_idx (from above)
call_indirect (type N)  ;; calls table[table_idx](this, ...)
```

The `call_indirect` places the table index at the TOP of the stack, with arguments below it.

### What `Animal.doubled()` generates:

```wat
;; this.vptr[slot_of_sound] = vtable base + 20 bytes
this.load              ;; load vptr
i32.load offset=20     ;; load table index for sound()
call_indirect (type 1) ;; (i32) -> i32, passing this
i32.const 1
i32.shl                ;; * 2
```

---

## 5. Function Table (Element Section)

```wat
(import "env" "__indirect_function_table" (table (;0;) 7 funcref))

(elem (;0;) (i32.const 1) func
    env.toString  env.toHash  env.opCmp  env.opEquals
    Dog.sound  Animal.doubled  Cat.sound)
```

- The function table is **imported** from `"env"` as `"__indirect_function_table"`.
- Element section initializes table starting at **index 1** (index 0 is reserved/null).
- Imported functions (Object base methods) get the lowest table indices.
- Defined methods get sequential indices after imports.
- **This means function table indices in vtables are stable compile-time constants** — LDC computes them when building the vtable data.

---

## 6. Nested Functions

```d
int testNested(int x) {
    int helper(int y) { return x + y; }  // captures x
    return helper(10);
}
```

### ABI: nested function receives a **frame pointer** as first i32

```wat
(func $helper (param i32 i32) (result i32)  ;; (frame_ptr, y) -> i32
  local.get 0      ;; frame_ptr
  i32.load         ;; *frame_ptr = captured x
  local.get 1      ;; y
  i32.add)
```

### Outer function places captures in shadow stack frame:

```wat
(func $testNested (param i32) (result i32)   ;; x
  ;; allocate shadow frame
  global.get 0 ; i32.const 16 ; i32.sub → frame
  global.set 0

  ;; store captured x into frame at offset 8
  frame ; x ; i32.store align=1   ;; frame[8] = x

  ;; call helper(frame_ptr_to_x, 10)
  frame+8 ; i32.const 10
  call $helper)
```

**Rules:**
- Nested function's **first parameter** = pointer to the captured-variable region.
- Captured **mutable** variables also live in the frame so mutations propagate back.
- The frame pointer is a plain i32 linear memory address.
- The outer function passes `frame + offset_of_captured_var` (not the full frame base).

### Mutation example (`increment` mutating `counter`):

```wat
(func $increment (param i32)    ;; frame_ptr_to_counter
  local.get 0        ;; frame_ptr
  local.get 0
  i32.load           ;; *frame_ptr (current counter value)
  i32.const 1
  i32.add
  i32.store)         ;; *frame_ptr = counter + 1
```

The outer function reads back `*frame_ptr` after the nested call to get the updated value.

---

## 7. Shadow Stack

Every function needing a frame (locals whose address is taken, struct temporaries, etc.) uses a **linear-memory shadow stack**:

- `__stack_pointer` is an i32 **mutable global** imported from `"env"`.
- **Prologue**: `sp = __stack_pointer - frame_size; __stack_pointer = sp`
- **Epilogue**: `__stack_pointer = sp + frame_size`
- The stack grows **downward** (subtract to allocate).
- Local variables live at positive offsets from `sp` (e.g., `sp+4`, `sp+8`, ...).

---

## 8. Summary: What DMD Must Implement

### Struct methods
- Pass `this` (i32) as first param.
- Struct return: prepend hidden i32 return-pointer before `this`.
- Access fields via `i32.load/store` with compile-time byte offsets.

### Classes
- **`__initZ`**: static data blob with `vptr = address(class.__vtblZ)` at offset 0, then field defaults. Emitted in the data section.
- **`__vtblZ`**: static data blob of i32 table indices. Slot 0 = 0 (ClassInfo null). Slots 1-4 = Object base methods. User methods start at slot 5+.
- **Virtual dispatch**: `this.load` (vptr) → `vptr.load(offset=slot*4)` (table_idx) → `call_indirect(table_idx, this, args)`.
- **Constructor**: returns `this` (i32). Calls parent ctor explicitly.

### Nested functions
- Prepend frame_ptr (i32) as first parameter.
- Outer function allocates shadow frame, copies captures there.
- Pass `frame_ptr + field_offset` to nested function.

### Function table
- Import `__indirect_function_table` from `"env"`.
- Element section initializes from index 1 (index 0 = null).
- Vtable values = function table indices, set at compile time.
- DMD's two-phase codegen must assign stable table indices before emitting vtable data.

---

## 9. Concrete Example: Full Class Hierarchy

```d
class Base { int val; int get() { return val; } int compute() { return get() * 2; } }
class Derived : Base { int extra; override int get() { return val + extra; } }
```

**Linear memory layout:**

| Address | Symbol | Content |
|---------|--------|---------|
| 0 | `Base.__initZ` | `\10\00\00\00 \00\00\00\00 \00\00\00\00` — vptr=16, monitor=0, val=0 |
| 16 | `Base.__vtblZ` | `[0,1,2,3,4,5,6]` — ClassInfo(0), 4×Object, get(5), compute(6) |
| 44 | `Derived.__initZ` | `\40\00\00\00 \00\00\00\00 \00\00\00\00 \00\00\00\00` — vptr=64 |
| 64 | `Derived.__vtblZ` | `[0,1,2,3,4,7,6]` — Derived.get overrides to table[7] |

**Function table:**

| Table index | Function |
|-------------|----------|
| 0 | (null/reserved) |
| 1 | `Object.toString` |
| 2 | `Object.toHash` |
| 3 | `Object.opCmp` |
| 4 | `Object.opEquals` |
| 5 | `Base.get` |
| 6 | `Base.compute` |
| 7 | `Derived.get` |

**`Base.compute()` calls `get()` virtually (slot 5 = offset 20):**

```wat
local.get 0          ;; this
i32.load             ;; vptr = *this
i32.load offset=20   ;; vtbl[5] = table index for get()
local.get 0          ;; this (argument to callee)
[swap top two]       ;; table_idx must be on top
call_indirect (type (func (param i32) (result i32)))
```

**`testClassInit` calls `b.compute()` (slot 6 = offset 24):**

```wat
local.get b          ;; b (Base reference = Derived* instance)
i32.load             ;; vptr
i32.load offset=24   ;; vtbl[6] = table index for compute()
local.get b
call_indirect
```

---

## 10. D Slice ABI (`T[]`)

Tested with:
```d
int sliceLen(const(char)[] s);          // slice parameter
const(char)[] makeSlice(const(char)* p, int len); // slice return
int totalLen(const(char)[] a, const(char)[] b);   // two slice params
```

### Slice as parameter

A D slice `T[]` (`{size_t length; T* ptr}`) is **split into two i32 WASM parameters**:
- First i32 = **length** (field at offset 0)
- Second i32 = **ptr** (field at offset 4)

```
(func $sliceLen (param i32 i32) (result i32))
;;                    len  ptr
```

Two slices become four i32 params:
```
(func $totalLen (param i32 i32 i32 i32) (result i32))
;;                   a.len a.ptr b.len b.ptr
```

### Slice as return value

A function returning a slice uses a **hidden sret pointer** as its **first parameter**.
The function writes `{length, ptr}` into memory at that address and returns **nil** (void):

```
(func $makeSlice (param i32 i32 i32))
;;                    sret  p   len
```

The sret address layout:
```
sret[+0] = length (i32, D slice offset 0)
sret[+4] = ptr    (i32, D slice offset 4)
```

### Member function returning slice

For member functions (D or extern(C) with D name mangling), the parameter order is:
```
(func $Str__asSlice (param i32 i32))
;;                       sret this
```

**sret comes before `this`** when the function has a hidden return pointer.

---

### DMD vs LDC comparison

| Aspect | LDC | DMD (current) |
|--------|-----|---------------|
| Slice parameter | two i32: `(len, ptr)` | two i32: `(len, ptr)` ✓ |
| Slice return | sret first param, `-> nil` | `-> i64` packed as `(ptr<<32)\|len` |
| Member with sret | `(sret, this, ...)` | `(this, sret, ...)` (wrong order) |

**DMD's `SplitParam` approach for slice parameters is correct** — it creates two i32 params
in `(len, ptr)` order and reconstructs them as i64 internally for use in the function body.

**DMD's slice return differs**: DMD declares slice-returning functions as `-> i64`
and packs the slice as `(ptr<<32) | len` in a single i64. LDC uses sret.
This means DMD-compiled and LDC-compiled slice-returning functions are **not ABI-compatible**
for cross-module calls. Within a single DMD compilation, the convention is consistent.

**Consequence**: `Circle.kind() -> const(char)[]` in DMD has type `(i32 this) -> i64`.
The OPpair operator (used to construct slice return values) must pack into i64, not push
two i32s. Fixed in `codgen.d`: OPpair/OPrpair with `TYullong` result packs into i64.

---

## 11. Differences from x86 ABI (DMD implications)

| Aspect | x86 DMD | WASM (LDC) |
|--------|---------|------------|
| Vtable entries | **function addresses** (code pointers) | **table indices** (i32 integers) |
| Vtable storage | `.rodata`/COMDAT section with relocs | data section, no relocations needed |
| Virtual dispatch | `call [vptr + slot*8]` (indirect through memory) | `i32.load(vptr + slot*4)` then `call_indirect` |
| `this` parameter | implicit (rcx/rdi depending on OS ABI) | explicit first i32 parameter |
| Struct return | depends on calling convention | hidden i32 pointer as first param (before `this`) |
| Nested function closure | usually via GC or stack pointer | explicit frame pointer i32 as first param |
| Stack | hardware stack (rsp) | shadow stack via mutable global `__stack_pointer` |

**Critical implementation note**: Because vtable entries are table indices (not addresses), DMD's WASM backend must know all function table indices **before** emitting `__vtblZ` data. This requires either:
1. A two-pass approach: register all functions first, then emit vtable data, or
2. A relocation mechanism that patches vtable entries after function registration.

LDC handles this by building the full module (including element section) in a single LLVM codegen pass where all indices are known.

---

## 12. DMD Relocatable Object Format (wasm-ld compatibility)

DMD emits one of two WASM binary formats depending on compilation mode:

### Final module (no `-c` flag)
- Self-contained WASM module, runnable directly with wasmtime.
- No "linking" or "reloc.*" custom sections.
- Function table indices in vtable data patched at compile time.
- Element section populated with compact ULEB function indices.

### Relocatable object (`-c` flag)
Follows the [WebAssembly tool conventions linking format](https://github.com/WebAssembly/tool-conventions/blob/main/Linking.md):
- **"linking"** custom section (version 2) with `WASM_SYMBOL_TABLE` subsection.
  - FUNCTION symbols: undefined (imports) have no name; defined have explicit name + global binding.
  - TABLE symbol: for the defined function table (`__indirect_function_table`, BINDING_LOCAL).
- **"reloc.CODE"**: `R_WASM_FUNCTION_INDEX_LEB` for each direct function call (5-byte padded ULEB).
- **"reloc.ELEM"**: `R_WASM_FUNCTION_INDEX_LEB` for each element in the element section (5-byte padded ULEB).
- **"reloc.DATA"**: `R_WASM_TABLE_INDEX_I32` for each 4-byte function table index in the data section (vtable entries).
- Import type ordering: import function types are placed first in the type section so `call_indirect` type indices remain stable after wasm-ld merges the type table.

### Known limitation
`R_WASM_TYPE_INDEX_LEB` relocations for `call_indirect` type indices are not emitted (wasm-ld 22 rejects local function symbols as relocation targets for this type). For multi-file linking involving `call_indirect`, the type indices may be incorrect if wasm-ld reorders the type table differently from our ordering heuristic.
