/**
 * Minimal C stdio shim for WebAssembly.
 *
 * Provides printf/puts/putchar using WASI fd_write so programs that import
 * these functions from "env" (DMD's default) don't hit a signature_mismatch
 * stub from wasm-ld.
 *
 * The signature matches DMD's calling convention for extern(C) variadic calls:
 * only the format string (first argument) is actually passed on the WASM stack;
 * additional arguments are NOT passed (they accumulate below the format string
 * on the WASM operand stack and are later dropped by the caller).  The format
 * string is therefore printed literally with "(?)" substituted for any %spec.
 *
 * This is intentionally a stub — it allows D programs that use printf for
 * simple output to compile and run on WASM.  A proper varargs-aware printf
 * requires implementing the WASM C varargs ABI, which is future work.
 *
 * Copyright: Copyright (C) 1999-2026 by The D Language Foundation, All Rights Reserved
 * License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 */
module rt.wasm.io;

import core.attribute : wasmImportModule;

nothrow @nogc:

// ── WASI fd_write ─────────────────────────────────────────────────────────────

private struct Iov { uint ptr; uint len; }

@wasmImportModule("wasi_snapshot_preview1")
private extern(C) int fd_write(int fd, Iov* iovs, int n, uint* nwritten);

// Single-iov write to a file descriptor (stdout=1, stderr=2).
private void wasi_write(int fd, const(char)* p, size_t len)
{
    if (!len) return;
    uint nw;
    Iov iov = { cast(uint) cast(size_t) p, cast(uint) len };
    fd_write(fd, &iov, 1, &nw);
}

// ── printf (minimal, format-string-only calling convention) ───────────────────
// DMD's WASM variadic ABI (matches LDC2/wasi-libc): caller spills `...` args to
// a shadow-stack frame and passes a pointer to that frame as the trailing i32
// parameter after all fixed args.  The signature here is therefore
// (fmt: i32, vargs: i32) -> i32.  We ignore vargs and substitute "(?)" for any
// %spec; this lets D programs that use printf for simple output compile and run.
// A proper varargs-aware printf would decode `vargs` per the format string.

extern (C) int printf(const(char)* fmt, void* vargs)
{
    if (!fmt) return 0;
    const(char)* p   = fmt;
    const(char)* seg = p;
    int written = 0;

    while (*p)
    {
        if (*p != '%')          { p++; continue; }

        // Flush literal segment before '%'
        if (p > seg)
        {
            wasi_write(1, seg, p - seg);
            written += cast(int)(p - seg);
        }
        p++; // skip '%'

        // Skip flags / width / precision / length modifier
        while (*p == '-' || *p == '+' || *p == ' ' || *p == '#' || *p == '0' ||
               (*p >= '0' && *p <= '9') || *p == '.' || *p == '*' ||
               *p == 'h' || *p == 'l' || *p == 'L' || *p == 'z' || *p == 'j' || *p == 't')
            p++;

        if (*p == '%')          { wasi_write(1, p, 1); written++; p++; }
        else if (*p)
        {
            // Unknown specifier (argument not available): print placeholder
            enum holder = "?";
            wasi_write(1, holder.ptr, holder.length);
            written += cast(int) holder.length;
            p++; // consume specifier character
        }
        seg = p;
    }

    // Flush trailing segment
    if (p > seg)
    {
        wasi_write(1, seg, p - seg);
        written += cast(int)(p - seg);
    }
    return written;
}

// ── puts / putchar ────────────────────────────────────────────────────────────

extern (C) int puts(const(char)* s)
{
    if (!s) return 0;
    size_t n = 0;
    while (s[n]) n++;
    wasi_write(1, s, n);
    wasi_write(1, "\n".ptr, 1);
    return cast(int) n + 1;
}

extern (C) int putchar(int c)
{
    char ch = cast(char) c;
    wasi_write(1, &ch, 1);
    return c;
}
