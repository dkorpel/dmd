/*
DISABLED: win osx
REQUIRED_ARGS: -marm64 -vasm -betterC
TEST_OUTPUT:
---
_D12iasm_aarch643fooFZv:
0000:   D6 5F 03 C0  $r:[^\n]*$
_D12iasm_aarch643barFZv:
0000:   91 00 04 20  $r:[^\n]*$
0004:   8B 02 0C 20  $r:[^\n]*$
0008:   F8 5F 80 20  $r:[^\n]*$
000c:   79 40 0C 20  $r:[^\n]*$
0010:   38 40 1C 20  $r:[^\n]*$
0014:   38 40 14 20  $r:[^\n]*$
0018:   38 E2 68 20  $r:[^\n]*$
001c:   F8 62 78 20  $r:[^\n]*$
0020:   B8 62 58 20  $r:[^\n]*$
0024:   91 00 03 FD  $r:[^\n]*$
0028:   91 00 43 FF  $r:[^\n]*$
002c:   8B 21 63 E0  $r:[^\n]*$
0030:   54 00 00 A1  $r:[^\n]*$
0034:   B4 FF FE 60  $r:[^\n]*$
0038:   36 18 00 60  $r:[^\n]*$
003c:   17 FF FF F1  $r:[^\n]*$
0040:   94 00 00 00  $r:[^\n]*$
0044:   D6 5F 03 C0  $r:[^\n]*$
0048:   D6 5F 03 C0  $r:[^\n]*$
---
*/

void foo() {}

void bar()
{
    asm
    {
    L0:
        add x0, x1, #1;
        add x0, x1, x2, LSL #3;
        ldr x0, [x1, #-8];
        ldrh w0, [x1, #6];
        ldrb w0, [x1, #1]!;
        ldrb w0, [x1], #1;
        ldrsb w0, [x1, x2];
        ldr x0, [x1, x2, lsl #3];
        ldr w0, [x1, w2, uxtw #2];
        mov x29, sp;
        add sp, sp, #16;
        add x0, sp, x1;
        b.ne L1;
        cbz x0, L0;
        tbz x0, #3, L1;
        b L0;
        bl foo;
    L1:
        ret;
    }
}
