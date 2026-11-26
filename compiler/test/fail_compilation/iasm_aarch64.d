/*
REQUIRED_ARGS: -marm64
TEST_OUTPUT:
---
fail_compilation/iasm_aarch64.d(22): Error: offset 32768 out of range for `ldr`
fail_compilation/iasm_aarch64.d(23): Error: offset 4 for `ldp` must be a multiple of 8 in range -512..504
fail_compilation/iasm_aarch64.d(24): Error: `x0`..`x30` or `sp` expected as base in memory operand
fail_compilation/iasm_aarch64.d(25): Error: shift amount for `ldr` must be 0 or 3
fail_compilation/iasm_aarch64.d(26): Error: 32-bit index register expected for `uxtw`/`sxtw`
fail_compilation/iasm_aarch64.d(27): Error: invalid shift type for `add`, expected lsl/lsr/asr
fail_compilation/iasm_aarch64.d(28): Error: `xzr`/`wzr` cannot be used here
fail_compilation/iasm_aarch64.d(29): Error: `sp` cannot be used here
fail_compilation/iasm_aarch64.d(30): Error: condition code expected after `b.`
fail_compilation/iasm_aarch64.d(31): Error: function expected for `bl`, not `L1`
---
*/

void f()
{
    asm
    {
        ldr x0, [x1, #32768];
        ldp x0, x1, [x2, #4];
        ldr x0, [xzr];
        ldr x0, [x1, x2, lsl #2];
        ldr x0, [x1, x2, uxtw];
        add x0, x1, x2, ror #2;
        add xzr, sp, #1;
        orr x0, sp, x1;
        b.xx L1;
        bl L1;
    L1:
        ret;
    }
}
