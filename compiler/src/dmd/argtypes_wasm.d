/**
 * Break down a D type into basic types for the WebAssembly ABI.
 *
 * Copyright:   Copyright (C) 1999-2026 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 https://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/compiler/src/dmd/argtypes_wasm.d, _argtypes_wasm.d)
 * Documentation:  https://dlang.org/phobos/dmd_argtypes_wasm.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/compiler/src/dmd/argtypes_wasm.d
 */

module dmd.argtypes_wasm;

import dmd.mtype;

/****************************************************
 * Break down a D type into basic types for WebAssembly ABI.
 * WebAssembly has 4 basic value types: i32, i64, f32, f64
 * All parameters and returns are passed in locals (numbered sequentially).
 *
 * Params:
 *      t = type to break down
 * Returns:
 *      For non-aggregate types or small aggregates: returns the type itself
 *      For large aggregates: returns empty (pass by reference)
 */
TypeTuple toArgTypes_wasm(Type t)
{
    //printf("toArgTypes_wasm() %s\n", t.toChars());
    if (t == Type.terror)
        return new TypeTuple(t);

    const size = cast(size_t) t.size();
    if (size == 0)
        return null;

    // WASM MVP: keep it simple - pass small types directly, pass large types by reference
    // In practice, aggregates larger than 8 bytes (one i64) should be passed by reference
    Type tb = t.toBasetype();

    // Pass primitives directly
    if (tb.isintegral() || tb.isfloating() || tb.isPointer())
        return new TypeTuple(t);

    // Small aggregates (1-8 bytes): pass in registers
    if (size <= 8)
        return new TypeTuple(t);

    // Large aggregates: pass by reference (empty indicates indirect passing)
    return TypeTuple.empty;
}
