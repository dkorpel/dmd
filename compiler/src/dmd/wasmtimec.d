/**
 * D bindings for the subset of the wasmtime C API used by the wasm CTFE engine.
 *
 * Copyright:   Copyright (C) 2026 by The D Language Foundation, All Rights Reserved
 * License:     $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/compiler/src/dmd/wasmtimec.d, _wasmtimec.d)
 */
module dmd.wasmtimec;

extern (C) nothrow @nogc:

struct wasm_engine_t;
struct wasm_config_t;
struct wasmtime_store_t;
struct wasmtime_context_t;
struct wasmtime_module_t;
struct wasmtime_linker_t;
struct wasmtime_error_t;
struct wasm_trap_t;
struct wasmtime_caller_t;
struct wasm_functype_t;
struct wasm_frame_t;

struct wasm_frame_vec_t
{
    size_t size;
    wasm_frame_t** data;
}

struct wasm_byte_vec_t
{
    size_t size;
    char* data;
}

alias wasm_name_t = wasm_byte_vec_t;
alias wasm_message_t = wasm_byte_vec_t;

enum : ubyte
{
    WASMTIME_I32 = 0,
    WASMTIME_I64 = 1,
    WASMTIME_F32 = 2,
    WASMTIME_F64 = 3,
    WASMTIME_V128 = 4,
    WASMTIME_FUNCREF = 5,
    WASMTIME_EXTERNREF = 6,
    WASMTIME_ANYREF = 7,
}

enum : ubyte
{
    WASMTIME_EXTERN_FUNC = 0,
    WASMTIME_EXTERN_GLOBAL = 1,
    WASMTIME_EXTERN_TABLE = 2,
    WASMTIME_EXTERN_MEMORY = 3,
    WASMTIME_EXTERN_SHAREDMEMORY = 4,
    WASMTIME_EXTERN_TAG = 5,
}

struct wasmtime_func_t
{
    ulong store_id;
    void* __private;
}

struct wasmtime_table_t
{
    ulong store_id;
    uint __private1;
    uint __pad;
    uint __private2;
}

struct wasmtime_memory_t
{
    ulong store_id;
    uint __private1;
    uint __pad;
    uint __private2;
}

struct wasmtime_global_t
{
    ulong store_id;
    uint __private1;
    uint __private2;
    uint __private3;
}

struct wasmtime_instance_t
{
    ulong store_id;
    size_t __private;
}

union wasmtime_valunion_t
{
    int i32;
    long i64;
    float f32;
    double f64;
    ubyte[16] v128;
    wasmtime_func_t funcref;
    ubyte[24] _pad;
}

struct wasmtime_val_t
{
    ubyte kind;
    wasmtime_valunion_t of;
}

union wasmtime_extern_union_t
{
    wasmtime_func_t func;
    wasmtime_global_t global;
    wasmtime_table_t table;
    wasmtime_memory_t memory;
    void* sharedmemory;
    ubyte[24] _pad;
}

struct wasmtime_extern_t
{
    ubyte kind;
    wasmtime_extern_union_t of;
}

struct wasm_valtype_t;

struct wasm_valtype_vec_t
{
    size_t size;
    wasm_valtype_t** data;
}

wasm_valtype_t* wasm_valtype_new(ubyte kind);
void wasm_valtype_vec_new_uninitialized(wasm_valtype_vec_t*, size_t);
wasm_functype_t* wasm_functype_new(wasm_valtype_vec_t* params, wasm_valtype_vec_t* results);
void wasm_functype_delete(wasm_functype_t*);

wasm_config_t* wasm_config_new();
void wasmtime_config_wasm_memory64_set(wasm_config_t*, bool);
void wasmtime_config_wasm_exceptions_set(wasm_config_t*, bool);
void wasmtime_config_memory_init_cow_set(wasm_config_t*, bool);
wasm_engine_t* wasm_engine_new_with_config(wasm_config_t*);

wasmtime_store_t* wasmtime_store_new(wasm_engine_t*, void* data, void function(void*) finalizer);
wasmtime_context_t* wasmtime_store_context(wasmtime_store_t*);
void wasmtime_store_delete(wasmtime_store_t*);
void wasmtime_store_limiter(wasmtime_store_t*, long memory_size, long table_elements, long instances,
    long tables, long memories);

wasmtime_error_t* wasmtime_module_new(wasm_engine_t*, const(ubyte)* wasm, size_t len, wasmtime_module_t**);
void wasmtime_module_delete(wasmtime_module_t*);

wasmtime_linker_t* wasmtime_linker_new(wasm_engine_t*);
void wasmtime_linker_delete(wasmtime_linker_t*);
void wasmtime_linker_allow_shadowing(wasmtime_linker_t*, bool);
wasmtime_error_t* wasmtime_linker_define(wasmtime_linker_t*, wasmtime_context_t*,
    const(char)* module_, size_t module_len, const(char)* name, size_t name_len, const(wasmtime_extern_t)*);
wasmtime_error_t* wasmtime_linker_define_instance(wasmtime_linker_t*, wasmtime_context_t*,
    const(char)* name, size_t name_len, const(wasmtime_instance_t)*);
bool wasmtime_linker_get(const(wasmtime_linker_t)*, wasmtime_context_t*,
    const(char)* module_, size_t module_len, const(char)* name, size_t name_len, wasmtime_extern_t*);
wasmtime_error_t* wasmtime_linker_define_func(
    wasmtime_linker_t*, const(char)* module_, size_t module_len,
    const(char)* name, size_t name_len, const(wasm_functype_t)*,
    wasmtime_func_callback_t cb, void* data, void function(void*) finalizer);
wasmtime_error_t* wasmtime_linker_instantiate(
    const(wasmtime_linker_t)*, wasmtime_context_t*,
    const(wasmtime_module_t)*, wasmtime_instance_t*, wasm_trap_t**);

bool wasmtime_instance_export_get(wasmtime_context_t*, const(wasmtime_instance_t)*,
    const(char)* name, size_t name_len, wasmtime_extern_t*);

alias wasmtime_func_callback_t = wasm_trap_t* function(void* env, wasmtime_caller_t*,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults);

wasmtime_error_t* wasmtime_func_call(wasmtime_context_t*, const(wasmtime_func_t)*,
    const(wasmtime_val_t)* args, size_t nargs, wasmtime_val_t* results, size_t nresults, wasm_trap_t**);

wasmtime_context_t* wasmtime_caller_context(wasmtime_caller_t*);
bool wasmtime_caller_export_get(wasmtime_caller_t*, const(char)* name, size_t name_len, wasmtime_extern_t*);
bool wasmtime_table_get(wasmtime_context_t*, const(wasmtime_table_t)*, ulong index, wasmtime_val_t* val);
wasmtime_error_t* wasmtime_table_set(wasmtime_context_t*, const(wasmtime_table_t)*, ulong index, const(wasmtime_val_t)*);
wasmtime_error_t* wasmtime_table_grow(wasmtime_context_t*, const(wasmtime_table_t)*, ulong delta,
    const(wasmtime_val_t)* init, ulong* prev_size);

ubyte* wasmtime_memory_data(const(wasmtime_context_t)*, const(wasmtime_memory_t)*);
size_t wasmtime_memory_data_size(const(wasmtime_context_t)*, const(wasmtime_memory_t)*);

wasmtime_error_t* wasmtime_memory_grow(wasmtime_context_t*, const(wasmtime_memory_t)*, ulong delta, ulong* prev_size);

void wasmtime_global_get(wasmtime_context_t*, const(wasmtime_global_t)*, wasmtime_val_t*);
wasmtime_error_t* wasmtime_global_set(wasmtime_context_t*, const(wasmtime_global_t)*, const(wasmtime_val_t)*);

wasm_trap_t* wasmtime_trap_new(const(char)* msg, size_t msg_len);
void wasmtime_error_message(const(wasmtime_error_t)*, wasm_name_t*);
void wasmtime_error_delete(wasmtime_error_t*);
void wasm_trap_message(const(wasm_trap_t)*, wasm_message_t*);
void wasm_trap_delete(wasm_trap_t*);
void wasmtime_error_wasm_trace(const(wasmtime_error_t)*, wasm_frame_vec_t*);
void wasm_trap_trace(const(wasm_trap_t)*, wasm_frame_vec_t*);
void wasm_frame_vec_delete(wasm_frame_vec_t*);
size_t wasm_frame_module_offset(const(wasm_frame_t)*);
const(wasm_name_t)* wasmtime_frame_module_name(const(wasm_frame_t)*);
void wasm_byte_vec_delete(wasm_byte_vec_t*);
