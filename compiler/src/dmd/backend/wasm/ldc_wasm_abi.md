# LDC2 WebAssembly ABI for D Features

LDC2 (1.42.0 / LLVM 21) D→WASM32 compilation investigation.
Test programs: `-mtriple=wasm32-unknown-unknown -betterC -O0`.

# Slice ABI: stop packing slices/delegates into i64

**Current direction (2026-05-22):** slices and delegates are **never** packed
into a single i64 anywhere. They are always represented as two i32 values —
`(length, ptr)` for slices, `(context, funcptr)` for delegates — both on the
WASM value stack and in shadow-frame memory (two adjacent i32 slots).
Any IR producing an i64 representation is a bug to be fixed at the producer.

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

- `this` always **first explicit i32 param** (pointer to struct in linear memory).
- Struct return by value → **hidden i32 return-pointer prepended before `this`**. Function writes there, returns void.
- Fields accessed via `i32.load/store offset=N` (N = byte offset in struct).

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
- `Base` = 12 bytes, `Derived` = 16 bytes.
- `__initZ` symbol = default instance data blob in **data section**:
  - First i32 = vtable address (`__vtblZ`) in linear memory.
  - Remaining bytes = default field values (zeros unless initialized).

**Example init data for Dog (at linear address 44):**
```
\40\00\00\00   ← vptr = 64 = address of Dog.__vtblZ
\00\00\00\00   ← monitor = 0
\00\00\00\00   ← Animal.x = 0 (default)
```

---

## 3. Vtable Layout (`__vtblZ`)

Vtable = array of **i32 WASM function table indices** in data section.

**Slot assignment** (class inheriting from `Object`):

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

`call_indirect` places table index at TOP of stack, arguments below.

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

- Function table **imported** from `"env"` as `"__indirect_function_table"`.
- Element section starts at **index 1** (index 0 = reserved/null).
- Imported functions (Object base methods) get lowest table indices.
- Defined methods get sequential indices after imports.
- **Function table indices in vtables = stable compile-time constants** — LDC computes them when building vtable data.

---

## 6. Nested Functions

```d
int testNested(int x) {
    int helper(int y) { return x + y; }  // captures x
    return helper(10);
}
```

### ABI: nested function receives **frame pointer** as first i32

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
- Nested function **first param** = pointer to captured-variable region.
- Captured **mutable** variables live in frame so mutations propagate back.
- Frame pointer = plain i32 linear memory address.
- Outer passes `frame + offset_of_captured_var` (not full frame base).

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

Outer reads back `*frame_ptr` after nested call to get updated value.

---

## 7. Shadow Stack

Functions needing a frame (address-taken locals, struct temporaries) use **linear-memory shadow stack**:

- `__stack_pointer` = i32 **mutable global** imported from `"env"`.
- **Prologue**: `sp = __stack_pointer - frame_size; __stack_pointer = sp`
- **Epilogue**: `__stack_pointer = sp + frame_size`
- Stack grows **downward** (subtract to allocate).
- Locals at positive offsets from `sp` (`sp+4`, `sp+8`, ...).

---

## 8. Summary: What DMD Must Implement

### Struct methods
- Pass `this` (i32) as first param.
- Struct return: prepend hidden i32 return-pointer before `this`.
- Access fields via `i32.load/store` with compile-time byte offsets.

### Classes
- **`__initZ`**: static data blob, `vptr = address(class.__vtblZ)` at offset 0, then field defaults. Data section.
- **`__vtblZ`**: static data blob of i32 table indices. Slot 0 = 0 (ClassInfo null). Slots 1-4 = Object base. User methods slot 5+.
- **Virtual dispatch**: `this.load` (vptr) → `vptr.load(offset=slot*4)` (table_idx) → `call_indirect(table_idx, this, args)`.
- **Constructor**: returns `this` (i32). Calls parent ctor explicitly.

### Nested functions
- Prepend frame_ptr (i32) as first parameter.
- Outer allocates shadow frame, copies captures there.
- Pass `frame_ptr + field_offset` to nested function.

### Function table
- Import `__indirect_function_table` from `"env"`.
- Element section starts from index 1 (index 0 = null).
- Vtable values = function table indices, set at compile time.
- DMD two-phase codegen must assign stable table indices before emitting vtable data.

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

D slice `T[]` (`{size_t length; T* ptr}`) **split into two i32 WASM params**:
- First i32 = **length** (offset 0)
- Second i32 = **ptr** (offset 4)

```
(func $sliceLen (param i32 i32) (result i32))
;;                    len  ptr
```

Two slices = four i32 params:
```
(func $totalLen (param i32 i32 i32 i32) (result i32))
;;                   a.len a.ptr b.len b.ptr
```

### Slice as return value

Slice return → **hidden sret pointer** as **first param**.
Function writes `{length, ptr}` at that address, returns void:

```
(func $makeSlice (param i32 i32 i32))
;;                    sret  p   len
```

sret layout:
```
sret[+0] = length (i32, D slice offset 0)
sret[+4] = ptr    (i32, D slice offset 4)
```

### Member function returning slice

Member functions with hidden return pointer:
```
(func $Str__asSlice (param i32 i32))
;;                       sret this
```

**sret before `this`** when function has hidden return pointer.

---

### DMD vs LDC comparison

| Aspect | LDC | DMD (current) |
|--------|-----|---------------|
| Slice parameter | two i32: `(len, ptr)` | two i32: `(len, ptr)` ✓ |
| Slice return | sret first param, `-> nil` | sret first param, `-> nil` (target) |
| Member with sret | `(sret, this, ...)` | `(sret, this, ...)` (target) |

**Slices and delegates never packed into single i64.** Both params and returns = two separate i32 values: `(length, ptr)` for slices, `(context, funcptr)` for delegates. Returning slice/delegate uses sret — caller passes pointer to two-i32 destination as first param, WASM signature has no result value for that field.

---

## 11. C Variadic Functions (`printf`, `...`)

Tested: LDC 1.42.0 / LLVM 21, `-O0`.

```d
extern(C):
int printf(const(char)* fmt, ...);
int myVariadic(int count, ...);

void testPrintf()      { printf("hello %d %f\n", 42, 3.14); }
void testNoVarargs()   { printf("no args\n"); }
void testUserVariadic(){ myVariadic(3, 1, 2, 3); }
```

### Function type

C variadics have WASM type `(fixed_params..., i32 varargs_ptr) → result`.
`...` replaced by single trailing `i32` pointer regardless of vararg count.

```wat
(import "env" "printf"     (func (param i32 i32) (result i32)))
(import "env" "myVariadic" (func (param i32 i32) (result i32)))
```

### Caller convention

1. **Fixed args** pushed to WASM value stack left-to-right.
2. **Variadic args** spilled to shadow stack frame left-to-right with natural C alignment (4-byte for i32/f32→f64, 8-byte for i64/f64). C default promotions apply: `float → double`, `char/short → int`.
3. Pointer to varargs frame pushed as last `i32` param.
4. **No** variadic args → `i32.const 0` (null).
5. `__stack_pointer` restored after call.

### Generated WAT for `testPrintf` (LDC)

```wat
global.get __stack_pointer      ; sp_old
i32.const 16
i32.sub
local.set 0                     ; sp = sp_old - 16
local.get 0
global.set __stack_pointer      ; __stack_pointer = sp

local.get 0
i64.const 4614253070214989087   ; 3.14 as f64 bit pattern
i64.store offset=8              ; sp[8..15] = 3.14 (double)
local.get 0
i32.const 42
i32.store                       ; sp[0..3] = 42 (int)

i32.const 0                     ; fmt_ptr
local.get 0                     ; varargs_ptr = sp
call printf                     ; printf(fmt, sp)

drop
local.get 0
i32.const 16
i32.add
global.set __stack_pointer      ; restore
```

### Varargs memory layout

| Offset | Size | C type   | Value |
|--------|------|----------|-------|
| 0      | 4    | int      | 42    |
| 4      | 4    | (pad)    | —     |
| 8      | 8    | double   | 3.14  |

Natural alignment: `int` at offset 0, `double` at offset 8 (next 8-byte boundary). Frame size rounded to 16 bytes.

### DMD vs LDC comparison

| Aspect | LDC | DMD (after fix) |
|--------|-----|-----------------|
| Function type for `printf` | `(i32 fmt, i32 va_ptr) → i32` | `(i32 fmt, i32 va_ptr) → i32` ✓ |
| No varargs | pass `i32.const 0` | pass `i32.const 0` ✓ |
| `int` vararg | `i32.store` at natural offset | `i32.store` ✓ |
| `double` vararg | `i64.store` (bit pattern) | `f64.store` ✓ (same bytes) |
| `float` vararg | `f64.promote_f32` + `f64.store` | `f64.promote_f32` + `f64.store` ✓ |
| Stack restore | after call | after call ✓ |

`i64.store` vs `f64.store` for double varargs = cosmetic — both write same 8 bytes. Calling convention fully compatible.

### Implementation in DMD

- `wasmobj.d: buildFuncType()`: appends `i32` to params when `variadic(t)`.
- `codgen.d: case OPcall`: detects `variadic(calleeSym.Stype)`, collects args into flat array, emits fixed args to WASM stack, spills variadic args to dynamically-allocated shadow frame, passes frame pointer as last `i32`.

---

## 12. Differences from x86 ABI (DMD implications)

| Aspect | x86 DMD | WASM (LDC) |
|--------|---------|------------|
| Vtable entries | **function addresses** (code pointers) | **table indices** (i32 integers) |
| Vtable storage | `.rodata`/COMDAT section with relocs | data section, no relocations needed |
| Virtual dispatch | `call [vptr + slot*8]` (indirect through memory) | `i32.load(vptr + slot*4)` then `call_indirect` |
| `this` parameter | implicit (rcx/rdi depending on OS ABI) | explicit first i32 parameter |
| Struct return | depends on calling convention | hidden i32 pointer as first param (before `this`) |
| Nested function closure | usually via GC or stack pointer | explicit frame pointer i32 as first param |
| Stack | hardware stack (rsp) | shadow stack via mutable global `__stack_pointer` |

**Critical**: vtable entries = table indices (not addresses), so DMD WASM backend must know all function table indices **before** emitting `__vtblZ` data. Requires either:
1. Two-pass: register all functions first, then emit vtable data, or
2. Relocation mechanism patching vtable entries after function registration.

LDC handles this via single LLVM codegen pass where all indices known.

---

## 12. DMD Relocatable Object Format (wasm-ld compatibility)

DMD emits two WASM binary formats depending on compilation mode:

### Final module (no `-c` flag)
- Self-contained WASM module, runnable with wasmtime.
- No "linking" or "reloc.*" custom sections.
- Function table indices in vtable data patched at compile time.
- Element section with compact ULEB function indices.

### Relocatable object (`-c` flag)
Follows [WebAssembly tool conventions linking format](https://github.com/WebAssembly/tool-conventions/blob/main/Linking.md):
- **"linking"** custom section (version 2) with `WASM_SYMBOL_TABLE` subsection.
  - FUNCTION symbols: undefined (imports) have no name; defined have explicit name + global binding.
  - TABLE symbol: defined function table (`__indirect_function_table`, BINDING_LOCAL).
- **"reloc.CODE"**: `R_WASM.FUNCTION_INDEX_LEB` for each direct function call (5-byte padded ULEB).
- **"reloc.ELEM"**: `R_WASM.FUNCTION_INDEX_LEB` for each element section entry (5-byte padded ULEB).
- **"reloc.DATA"**: `R_WASM.TABLE_INDEX_I32` for each 4-byte function table index in data section (vtable entries).
- Import type ordering: import function types first in type section so `call_indirect` type indices stay stable after wasm-ld merges type table.

### Known limitation
`R_WASM.TYPE_INDEX_LEB` relocations for `call_indirect` type indices not emitted (wasm-ld 22 rejects local function symbols as relocation targets for this type). Multi-file linking with `call_indirect` may have incorrect type indices if wasm-ld reorders type table differently from our ordering heuristic.