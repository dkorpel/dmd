/**
 * No-op monitor and critical-section stubs for WebAssembly.
 * WASM is single-threaded; all synchronisation primitives are elided.
 *
 * Copyright: Copyright (C) 1999-2026 by The D Language Foundation, All Rights Reserved
 * License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 */
module rt.wasm.sync;

nothrow:
extern (C):

void _d_monitor_staticctor() @nogc {}
void _d_monitor_staticdtor() @nogc {}

void _d_critical_init() @nogc {}
void _d_critical_term() @nogc {}

private extern (C) void* gc_calloc(size_t sz, uint ba = 0, const scope TypeInfo ti = null) @nogc nothrow;

void _d_monitorenter(Object h)
{
    auto pmon = cast(void**) cast(void*) h + 1;
    if (*pmon is null)
        *pmon = gc_calloc(3 * (void*).sizeof);
}
void _d_monitorexit(Object h) {}

void _d_criticalenter2(void** pcs) @nogc {}
void _d_criticalexit(void* cs) @nogc {}

void _d_monitordelete(Object h, bool det) {}
void _d_monitordelete_nogc(Object h) @nogc {}

void _d_setSameMutex(shared Object ownee, shared Object owner) @trusted {}

alias DEvent = void delegate(Object);
void rt_attachDisposeEvent(Object h, DEvent e) {}
void rt_detachDisposeEvent(Object h, DEvent e) {}

void thread_init() @nogc {}
void thread_term() @nogc {}
void thread_joinAll() {}
