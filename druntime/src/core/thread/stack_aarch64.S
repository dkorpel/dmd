/**
 * AArch64 stack primitives for the DigitalMars compiler, which has no
 * inline assembler for AArch64 yet.
 *
 * Copyright: Copyright D Language Foundation 2026.
 * License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 */

#if (__linux__ || __FreeBSD__ || __NetBSD__ || __OpenBSD__ || __DragonFly__ | __GNU__) && __ELF__
.section .note.GNU-stack,"",%progbits
#endif

#if defined(__aarch64__)

#if defined(__APPLE__)
#define CSYM(name) _##name
#define FUNC(name) .globl CSYM(name); .p2align 2; CSYM(name):
#else
#define CSYM(name) name
#define FUNC(name) .globl name; .p2align 2; .type name, %function; name:
#endif

        .text

/* void* _d_getStackTop() */
FUNC(_d_getStackTop)
        mov     x0, sp
        ret

/* void _d_saveCalleeRegisters(void** buf), buf must hold 11 pointers.
 * Stores x19-x28 (callee saved per AAPCS64 5.1.1) plus x29, which optionally
 * can be a callee saved register.
 */
FUNC(_d_saveCalleeRegisters)
        stp     x19, x20, [x0]
        stp     x21, x22, [x0, #16]
        stp     x23, x24, [x0, #32]
        stp     x25, x26, [x0, #48]
        stp     x27, x28, [x0, #64]
        str     x29, [x0, #80]
        ret

#endif
