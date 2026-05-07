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

import dmd.astenums;
import dmd.mtype;
import dmd.typesem;
import dmd.target : target;

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
    if (t == Type.terror)
        return new TypeTuple(t);

    Type tb = t.toBasetype();

    // void has no size and is not passed — return null
    if (tb.ty == Tvoid)
        return null;

    const sz = cast(size_t) t.size();
    if (sz == 0)
        return null;

    switch (tb.ty)
    {
        // integer primitives
    case Tint8:
    case Tuns8:
    case Tint16:
    case Tuns16:
    case Tint32:
    case Tuns32:
    case Tint64:
    case Tuns64:
    case Tint128:
    case Tuns128:
    case Tbool:
    case Tchar:
    case Twchar:
    case Tdchar:
        // floating point
    case Tfloat32:
    case Tfloat64:
    case Tfloat80:
    case Timaginary32:
    case Timaginary64:
    case Timaginary80:
    case Tcomplex32:
    case Tcomplex64:
    case Tcomplex80:
        // pointer-like
    case Tpointer:
    case Tnull:
    case Tfunction:
        return new TypeTuple(t);

    default:
        break;
    }

    // D dynamic arrays (slices T[]): decompose into (length, ptr) as two separate params.
    // This matches the x86 convention (toArgTypes_x86 does the same) and is binary
    // compatible with LDC2's WebAssembly output. On WASM32:
    //   T[]  → (size_t length, T* ptr) = (i32, i32)
    if (tb.ty == Tarray)
        return new TypeTuple(Type.tsize_t, Type.tvoidptr);

    // Delegates: decompose into (funcptr, contextptr).
    if (tb.ty == Tdelegate)
        return new TypeTuple(Type.tvoidptr, Type.tvoidptr);

    // Other aggregates (structs, static arrays, etc.): always pass by reference.
    // Returning TypeTuple(t) for aggregates would recurse into visitStruct
    // during backend type conversion; empty signals indirect passing.
    return TypeTuple.empty;
}
