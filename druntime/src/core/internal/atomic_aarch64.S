/**
 * AArch64 atomic primitives for the DigitalMars compiler, which has no
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

/* T _d_atomic_load_N(const T* src) */
FUNC(_d_atomic_load_1)
        ldarb   w0, [x0]
        ret
FUNC(_d_atomic_load_2)
        ldarh   w0, [x0]
        ret
FUNC(_d_atomic_load_4)
        ldar    w0, [x0]
        ret
FUNC(_d_atomic_load_8)
        ldar    x0, [x0]
        ret

/* void _d_atomic_store_N(T* dest, T value) */
FUNC(_d_atomic_store_1)
        stlrb   w1, [x0]
        ret
FUNC(_d_atomic_store_2)
        stlrh   w1, [x0]
        ret
FUNC(_d_atomic_store_4)
        stlr    w1, [x0]
        ret
FUNC(_d_atomic_store_8)
        stlr    x1, [x0]
        ret

/* T _d_atomic_fetch_add_N(T* dest, T value), returns the previous value */
FUNC(_d_atomic_fetch_add_1)
1:      ldaxrb  w2, [x0]
        add     w3, w2, w1
        stlxrb  w4, w3, [x0]
        cbnz    w4, 1b
        mov     w0, w2
        ret
FUNC(_d_atomic_fetch_add_2)
1:      ldaxrh  w2, [x0]
        add     w3, w2, w1
        stlxrh  w4, w3, [x0]
        cbnz    w4, 1b
        mov     w0, w2
        ret
FUNC(_d_atomic_fetch_add_4)
1:      ldaxr   w2, [x0]
        add     w3, w2, w1
        stlxr   w4, w3, [x0]
        cbnz    w4, 1b
        mov     w0, w2
        ret
FUNC(_d_atomic_fetch_add_8)
1:      ldaxr   x2, [x0]
        add     x3, x2, x1
        stlxr   w4, x3, [x0]
        cbnz    w4, 1b
        mov     x0, x2
        ret

/* T _d_atomic_exchange_N(T* dest, T value), returns the previous value */
FUNC(_d_atomic_exchange_1)
1:      ldaxrb  w2, [x0]
        stlxrb  w3, w1, [x0]
        cbnz    w3, 1b
        mov     w0, w2
        ret
FUNC(_d_atomic_exchange_2)
1:      ldaxrh  w2, [x0]
        stlxrh  w3, w1, [x0]
        cbnz    w3, 1b
        mov     w0, w2
        ret
FUNC(_d_atomic_exchange_4)
1:      ldaxr   w2, [x0]
        stlxr   w3, w1, [x0]
        cbnz    w3, 1b
        mov     w0, w2
        ret
FUNC(_d_atomic_exchange_8)
1:      ldaxr   x2, [x0]
        stlxr   w3, x1, [x0]
        cbnz    w3, 1b
        mov     x0, x2
        ret

/* bool _d_atomic_cas_N(T* dest, T* compare, T value)
 * On failure *compare is set to the value read from dest.
 */
FUNC(_d_atomic_cas_1)
        ldrb    w4, [x1]
1:      ldaxrb  w3, [x0]
        cmp     w3, w4
        b.ne    2f
        stlxrb  w5, w2, [x0]
        cbnz    w5, 1b
        mov     w0, #1
        ret
2:      clrex
        strb    w3, [x1]
        mov     w0, #0
        ret
FUNC(_d_atomic_cas_2)
        ldrh    w4, [x1]
1:      ldaxrh  w3, [x0]
        cmp     w3, w4
        b.ne    2f
        stlxrh  w5, w2, [x0]
        cbnz    w5, 1b
        mov     w0, #1
        ret
2:      clrex
        strh    w3, [x1]
        mov     w0, #0
        ret
FUNC(_d_atomic_cas_4)
        ldr     w4, [x1]
1:      ldaxr   w3, [x0]
        cmp     w3, w4
        b.ne    2f
        stlxr   w5, w2, [x0]
        cbnz    w5, 1b
        mov     w0, #1
        ret
2:      clrex
        str     w3, [x1]
        mov     w0, #0
        ret
FUNC(_d_atomic_cas_8)
        ldr     x4, [x1]
1:      ldaxr   x3, [x0]
        cmp     x3, x4
        b.ne    2f
        stlxr   w5, x2, [x0]
        cbnz    w5, 1b
        mov     w0, #1
        ret
2:      clrex
        str     x3, [x1]
        mov     w0, #0
        ret

/* void _d_atomic_fence() */
FUNC(_d_atomic_fence)
        dmb     ish
        ret

/* void _d_atomic_pause() */
FUNC(_d_atomic_pause)
        yield
        ret

#endif
