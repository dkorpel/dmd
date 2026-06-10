/**
 * core.internal.atomic for wasm32-wasi. Upstream's atomic.d only implements
 * DigitalMars/GNU backends (no LDC), so it fails to compile with ldc2. The wasm
 * build is single-threaded, so atomics degrade to plain loads/stores.
 * Shadows druntime via the wasm build's -Icompiler/wasm/shim.
 */
module core.internal.atomic;

import core.atomic : MemoryOrder;

nothrow @nogc pure @trusted:

inout(T) atomicLoad(MemoryOrder order = MemoryOrder.seq, T)(inout(T)* src)
    => *src;

void atomicStore(MemoryOrder order = MemoryOrder.seq, T)(T* dest, T value)
{
    *dest = value;
}

T atomicFetchAdd(MemoryOrder order = MemoryOrder.seq, bool result = true, T)(T* dest, T value)
{
    T old = *dest;
    *dest = cast(T)(old + value);
    return old;
}

T atomicFetchSub(MemoryOrder order = MemoryOrder.seq, bool result = true, T)(T* dest, T value)
{
    T old = *dest;
    *dest = cast(T)(old - value);
    return old;
}

T atomicExchange(MemoryOrder order = MemoryOrder.seq, bool result = true, T)(T* dest, T value)
{
    T old = *dest;
    *dest = value;
    return old;
}

bool atomicCompareExchangeStrong(MemoryOrder succ = MemoryOrder.seq, MemoryOrder fail = MemoryOrder.seq, T)(T* dest, T* compare, T value)
{
    if (*dest == *compare)
    {
        *dest = value;
        return true;
    }
    *compare = *dest;
    return false;
}

alias atomicCompareExchangeWeak = atomicCompareExchangeStrong;

bool atomicCompareExchangeStrongNoResult(MemoryOrder succ = MemoryOrder.seq, MemoryOrder fail = MemoryOrder.seq, T)(T* dest, const T compare, T value)
{
    if (*dest == compare)
    {
        *dest = value;
        return true;
    }
    return false;
}

alias atomicCompareExchangeWeakNoResult = atomicCompareExchangeStrongNoResult;

void atomicFence(MemoryOrder order = MemoryOrder.seq)() {}
void atomicSignalFence(MemoryOrder order = MemoryOrder.seq)() {}
void pause() {}
