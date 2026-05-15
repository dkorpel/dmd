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

// Monitor static init / term (called from dmain2 on other platforms)
void _d_monitor_staticctor() @nogc {}
void _d_monitor_staticdtor() @nogc {}

// Critical-section init / term
void _d_critical_init() @nogc {}
void _d_critical_term() @nogc {}

// synchronized(obj) enter / exit
void _d_monitorenter(Object h) {}
void _d_monitorexit(Object h) {}

// Monitor destruction
void _d_monitordelete(Object h, bool det) {}
void _d_monitordelete_nogc(Object h) @nogc {}

// Shared-mutex helpers (used by synchronized classes)
void _d_setSameMutex(shared Object ownee, shared Object owner) @trusted {}

// Thread init / term (stubs so dmain2 can be compiled in if needed)
void thread_init() @nogc {}
void thread_term() @nogc {}
void thread_joinAll() {}
