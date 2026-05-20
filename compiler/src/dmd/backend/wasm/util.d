/**
 * WASM utility functions
 */

module dmd.backend.wasm.util;

import dmd.common.outbuffer;

/// Emit a 5-byte padded ULEB128 (fixed-width, allowing linker relocation patching)
void writeuLEB128_5(ref OutBuffer buf, uint v) nothrow @safe
{
    buf.writeByte((v & 0x7F) | 0x80);
    buf.writeByte(((v >> 7) & 0x7F) | 0x80);
    buf.writeByte(((v >> 14) & 0x7F) | 0x80);
    buf.writeByte(((v >> 21) & 0x7F) | 0x80);
    buf.writeByte((v >> 28) & 0x0F); // MSB=0 to terminate
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
