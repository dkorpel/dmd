# AArch64 trivial fixes

Small, self-contained corrections to the AArch64 backend: a wrong argument, a
wrong constant, a missing mask. They are collected on this branch separately from
the larger AArch64 changes so they can be reviewed at a glance.

Listed oldest first, in the order they are committed.

## backend/arm: read float constants as Vfloat in cdeq

Assigning a `float` constant to memory read the constant from the `Vdouble` union
field instead of `Vfloat`, so the stored bit pattern was garbage.

```d
void f(ref float x) { x = 1.5f; }
```

## backend/arm: clamp CSE spill store to REGSIZE

A common subexpression whose type is wider than a register (a slice, a `cdouble`)
was spilled with the full type size as the store width, which is not an encodable
`STR` size.

```d
size_t f(int[] a) { return a.length ? a.length : 0; }
```

## AArch64: mark locals as read when their address is materialized

Taking the address of a local or parameter did not set `SFLread` on the symbol, so
the variable could still be treated as unreferenced.

```d
void g(int*);
void f() { int x = 3; g(&x); }
```

## AArch64: fix lazy parameter ABI and cdstreq register clobber

Two fixes:

* `ISX64REF` was missing parentheses, so `&&` bound tighter than intended and the
  `lazy` exclusion did not apply to the `passTypeByRef` half of the condition — a
  lazy parameter of a by-reference type was passed by reference instead of as a
  delegate.
* In `cdstreq`, the register holding the destination pointer was allocated without
  excluding the source registers, so a struct assignment could overwrite the
  source pointer before reading through it.

```d
struct S { int[16] a; }
void f(lazy S s) { S t = s; }

void copy(S* p, S* q) { *p = *q; }
```

## AArch64: fix float array ABI, GP-to-FP fmov encoding, struct copy loops

Four one-line corrections in the same area:

* `fmov_float_gen` was always given `sf = 1`, so moving a 4-byte value from a
  general purpose register to a float register used the 64-bit form.
* `movParams` stored the two halves of a register pair at offsets derived from the
  whole size instead of the half size.
* The byte copy loop in `cdstreq` advances its index register, but the register was
  still recorded in `regcon.immed` as holding its original constant.
* `argtypes` applied the x86 rule for returning a small struct in registers on
  AArch64 as well.

```d
struct S { float[2] a; }
S f(S s) { return s; }
```

## AArch64: fix MSW store offset in register pair assignment

Storing the high half of a register pair set `Voffset` to `sz / 2` rather than
adding it, so the store went to offset 8 of the frame instead of 8 past the
destination.

```d
struct S { int x; int[] arr; }
void f(ref S s, int[] b) { s.arr = b; }
```

## AArch64: use the AArch64 getlvalue when spilling a register variable

`arm/cod3.d` imported `getlvalue` from the x86 backend, so spilling a register
variable built an x86 effective address.

```d
long f(long a, long b, long c, long d, long e, long g, long h, long i)
{
    return a + b + c + d + e + g + h + i;
}
```

## AArch64: mark the lvalue register as modified in cdpost

`getregs` takes a register mask, but `cdpost` passed a bare register number, so the
wrong set of registers was marked as modified.

```d
int f(ref int i) { return i++; }
```

## AArch64: increment the pointer at 64 bits in the postinc assignment

The `ADD` after a post-increment was given the size flag as the 64-bit selector and
the `postinc` byte count where the immediate belongs, so a pointer was incremented
as a 32-bit value by the wrong amount.

```d
char f(ref char* p) { return *p++; }
```

## AArch64: gennop() must emit an AArch64 nop

`gennop` emitted the x86 `0x90` opcode into the AArch64 instruction stream.

```d
void f(int a, int b) { if (a) { } else if (b) { } }
```

## AArch64: keep mPSW when widening pretregs for a common subexpression

When a common subexpression was asked for in no particular register, `pretregs` was
overwritten with the full register set instead of being OR'd, dropping the `mPSW`
request, so the flags the caller wanted were never set.

```d
bool f(int a, int b) { return (a + b) && (a + b) != 3; }
```

## AArch64: emit a conditional branch, not an x86 opcode, in the register pair compare

Comparing two register pairs emitted `genjmp(JNE)`, an x86 opcode, into the AArch64
instruction stream.

```d
bool f(int[] a, int[] b) { return a is b; }
```

## AArch64: adjust x1 in a thunk when the callee takes a hidden return pointer

A thunk always adjusted `x0`, but when the function returns a struct through a
hidden pointer, `x0` holds that pointer and `this` is in `x1`.

```d
struct Big { long a, b, c; }
interface I { Big get(); }
class C : I { Big get() { return Big(1, 2, 3); } }
```

## AArch64: encode MOV to/from SP as ADD Rd,Rn,#0

`MOV` is an alias of `ORR` with the zero register, where register 31 means `ZR`, not
`SP`, so `genmovreg` turned `mov sp, x29` into `mov xzr, x29` and left the stack
pointer unrestored.

```d
import core.stdc.stdlib : alloca;
void f(size_t n) { void* p = alloca(n); }
```
