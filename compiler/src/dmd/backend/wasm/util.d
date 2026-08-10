/**
 * WASM utility functions
 */

module dmd.backend.wasm.util;

import dmd.common.outbuffer;

// Note: outbuffer already contains members writesLEB128 and writeuLEB128

/// Emit a 5-byte padded ULEB128 (fixed-width, allowing linker relocation patching)
void writeuLEB128_5(ref OutBuffer buf, uint v) nothrow @safe
{
    buf.writeByte((v & 0x7F) | 0x80);
    buf.writeByte(((v >> 7) & 0x7F) | 0x80);
    buf.writeByte(((v >> 14) & 0x7F) | 0x80);
    buf.writeByte(((v >> 21) & 0x7F) | 0x80);
    buf.writeByte((v >> 28) & 0x0F);
}

/// Returns: number of bytes needed for ULEB128 encoding of v
uint ulebSize(uint v) nothrow
{
    uint n = 0;
    do
    {
        n++;
        v >>= 7;
    }
    while (v);
    return n;
}

/// Returns: number of bytes needed for signed LEB128 encoding of v.
uint slebSize(long v) nothrow
{
    uint n = 0;
    bool more = true;
    while (more)
    {
        const byte b = cast(byte)(v & 0x7F);
        v >>= 7;
        if ((v == 0 && (b & 0x40) == 0) || (v == -1 && (b & 0x40) != 0))
            more = false;
        n++;
    }
    return n;
}

/// Overwrite a little-endian 32-bit value in place.
void patchLE32(ubyte[] buf, uint off, uint v) nothrow @safe
{
    if (off + 4 > buf.length)
        return;
    buf[off + 0] = cast(ubyte)(v);
    buf[off + 1] = cast(ubyte)(v >> 8);
    buf[off + 2] = cast(ubyte)(v >> 16);
    buf[off + 3] = cast(ubyte)(v >> 24);
}

/// Overwrite a 5-byte padded LEB128 operand in place. Values below 2^28 encode
/// identically as signed and unsigned here, which covers every index and
/// address a self-linked module produces.
void patchLEB5(ubyte[] buf, uint off, uint v) nothrow @safe
{
    if (off + 5 > buf.length)
        return;
    foreach (b; 0 .. 5)
    {
        buf[off + b] = cast(ubyte)((v & 0x7f) | (b < 4 ? 0x80 : 0));
        v >>= 7;
    }
}
