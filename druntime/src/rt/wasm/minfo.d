/**
 * Module constructor/destructor execution for WebAssembly.
 *
 * The backend (backend/wasm/obj.d WasmObj_moduleinfo) emits one
 * `immutable(ModuleInfo)*` per linked module into a data segment named
 * "minfo".  wasm-ld concatenates those segments and synthesises the bracket
 * symbols `__start_minfo` / `__stop_minfo`, giving us the full module list at
 * runtime without any platform section machinery.
 *
 * `rt_moduleCtor` / `rt_moduleDtor` (called by `rt.wasm.start._d_run_main`
 * around `main`) order the modules so that a module's imports are constructed
 * first (depth-first over `ModuleInfo.importedModules`), run the shared then
 * TLS constructors, and run the destructors in reverse.  A genuine cyclic
 * constructor dependency traps (matching `--DRT-oncycle=abort`).  This is a
 * self-contained reimplementation of `rt.minfo.ModuleGroup`'s core ordering,
 * which can't be reused directly because `rt.minfo` imports the platform
 * `rt.sections` (unavailable for the WASM target).
 *
 * Copyright: Copyright (C) 1999-2026 by The D Language Foundation, All Rights Reserved
 * License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 */
module rt.wasm.minfo;

// Bracket symbols defined by wasm-ld for the "minfo" data segment.  Their
// addresses delimit the `immutable(ModuleInfo)*[]` array.
private extern(C) extern __gshared void* __start_minfo;
private extern(C) extern __gshared void* __stop_minfo;

private extern(C) noreturn _wasm_trap(int) @nogc nothrow;
private extern(C) void* calloc(size_t, size_t) @nogc nothrow;

nothrow:

// Module ctor/dtor bodies are `void function()` (potentially throwing), but
// WASM has no exception-handling runtime, so a throwing ctor traps regardless;
// treat them as nothrow to call them from this nothrow driver.
private alias CtorFn = void function() nothrow;

// Scratch is heap-allocated (calloc), not kept as large static arrays: a big
// druntime-archive `__gshared` array can land at a linear-memory address that
// overlaps a user module's globals (the wasm backend does not fully separate
// cross-object static data), and the walker writing into it would corrupt user
// state.  Heap storage never overlaps the static data region.
private __gshared immutable(ModuleInfo)*[] _modules;
private __gshared ubyte* _state;                  // 0 unseen, 1 on-stack, 2 done
private __gshared immutable(ModuleInfo)** _order; // ctor run order
private __gshared size_t _orderLen;

private immutable(ModuleInfo)*[] gatherModules() @nogc
{
    auto b = cast(immutable(ModuleInfo)**) &__start_minfo;
    auto e = cast(immutable(ModuleInfo)**) &__stop_minfo;
    return b[0 .. e - b];
}

private size_t indexOf(immutable(ModuleInfo)* m) @nogc
{
    foreach (i, x; _modules)
        if (x is m)
            return i;
    return size_t.max;
}

// Depth-first: append a module to `_order` only after all of its imports, so
// constructors later run imports-first.
private void visit(size_t i) @nogc
{
    if (_state[i] == 2)
        return;
    if (_state[i] == 1)
        return; // back-edge: a plain import cycle (not a ctor dependency cycle);
                // skip rather than trap.  The module is already mid-visit and
                // will be appended to _order when that visit completes.
    _state[i] = 1;
    foreach (imp; _modules[i].importedModules)
    {
        if (imp is _modules[i])
            continue; // self-import
        const j = indexOf(imp);
        if (j != size_t.max)
            visit(j);
    }
    _order[_orderLen++] = _modules[i];
    _state[i] = 2;
}

extern(C) void rt_moduleCtor()
{
    _modules = gatherModules();
    const n = _modules.length;
    if (!n)
        return;

    _state = cast(ubyte*) calloc(n, 1);                       // zeroed
    _order = cast(immutable(ModuleInfo)**) calloc(n, (void*).sizeof);
    if (!_state || !_order)
        _wasm_trap(1); // out of memory before module construction
    _orderLen = 0;

    // Independent constructors (`pragma(crt_constructor)`-like ictor) run first,
    // in any order, then the dependency-sorted shared and TLS constructors.
    foreach (m; _modules)
        if (auto f = m.ictor)
            (cast(CtorFn) f)();
    foreach (k; 0 .. n)
        visit(k);
    foreach (m; _order[0 .. _orderLen])
        if (auto f = m.ctor)
            (cast(CtorFn) f)();
    foreach (m; _order[0 .. _orderLen])
        if (auto f = m.tlsctor)
            (cast(CtorFn) f)();
}

extern(C) void rt_moduleDtor()
{
    if (!_orderLen)
        return;
    foreach_reverse (m; _order[0 .. _orderLen])
        if (auto f = m.tlsdtor)
            (cast(CtorFn) f)();
    foreach_reverse (m; _order[0 .. _orderLen])
        if (auto f = m.dtor)
            (cast(CtorFn) f)();
    _orderLen = 0;
}
