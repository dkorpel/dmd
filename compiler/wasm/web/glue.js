// Loads dmd.wasm and runs the DMD frontend on a source string, returning the
// -vcg-ast dump. Provides a minimal WASI shim (the in-memory compile flow only
// really needs fd_write for stdout/stderr capture; the rest are stubs).

const WASI_ESUCCESS = 0;
const WASI_EBADF = 8;

let memory = null;
let stdoutText = "";   // fd 1: the -vasm disassembly
let stderrText = "";   // fd 2: diagnostics

const td = new TextDecoder("utf-8");
const te = new TextEncoder();

function readCStr() {} // unused placeholder

function dv() { return new DataView(memory.buffer); }

// Collect bytes written to fd 1/2 (stdout/stderr) from an iovec array.
function writeIovs(fd, iovsPtr, iovsLen, nwrittenPtr) {
    const view = dv();
    let written = 0;
    let chunks = [];
    for (let i = 0; i < iovsLen; i++) {
        const ptr = view.getUint32(iovsPtr + i * 8, true);
        const len = view.getUint32(iovsPtr + i * 8 + 4, true);
        chunks.push(new Uint8Array(memory.buffer, ptr, len));
        written += len;
    }
    const text = chunks.map((c) => td.decode(c)).join("");
    if (fd === 1) stdoutText += text;       // -vasm disassembly
    else stderrText += text;                // diagnostics
    view.setUint32(nwrittenPtr, written, true);
    return WASI_ESUCCESS;
}

const wasi = {
    fd_write: (fd, iovs, iovsLen, nwritten) => writeIovs(fd, iovs, iovsLen, nwritten),
    fd_read: () => WASI_EBADF,
    fd_close: () => WASI_ESUCCESS,
    fd_seek: () => WASI_EBADF,
    fd_fdstat_get: () => WASI_EBADF,
    fd_filestat_get: () => WASI_EBADF,
    fd_filestat_set_size: () => WASI_EBADF,
    fd_prestat_get: () => WASI_EBADF,
    fd_prestat_dir_name: () => WASI_EBADF,
    fd_readdir: () => WASI_EBADF,
    path_open: () => WASI_EBADF,
    path_filestat_get: () => WASI_EBADF,
    path_filestat_set_times: () => WASI_EBADF,
    path_create_directory: () => WASI_EBADF,
    path_remove_directory: () => WASI_EBADF,
    path_unlink_file: () => WASI_EBADF,
    path_rename: () => WASI_EBADF,
    environ_get: () => WASI_ESUCCESS,
    environ_sizes_get: (countPtr, sizePtr) => {
        const view = dv();
        view.setUint32(countPtr, 0, true);
        view.setUint32(sizePtr, 0, true);
        return WASI_ESUCCESS;
    },
    clock_time_get: (id, prec, timePtr) => {
        dv().setBigUint64(timePtr, BigInt(Date.now()) * 1000000n, true);
        return WASI_ESUCCESS;
    },
    proc_exit: (code) => { throw new Error("proc_exit(" + code + ")"); },
};

let exports = null;
let wasmModule = null;     // compiled WebAssembly.Module, instantiated fresh per compile
let lastModified = null;   // dmd.wasm's Last-Modified header, as a Date (or null)

// When dmd.wasm was last built/deployed, per its Last-Modified header.
export function dmdLastModified() { return lastModified; }

export async function loadDmd(url = "dmd.wasm") {
    const resp = await fetch(url);
    const lm = resp.headers.get("last-modified");
    if (lm) { const d = new Date(lm); if (!isNaN(d)) lastModified = d; }
    // Compile once; instantiate per compile (see newInstance). Holding only the
    // Module — not an Instance — means no linear memory is retained between compiles.
    wasmModule = await WebAssembly.compileStreaming(resp);
}

// Spin up a fresh wasm instance with its own zero-initialized linear memory.
//
// The DMD frontend is a one-shot compiler: its global tables (identifier/type
// interning, the module list, ...) aren't designed to be re-initialized in
// place, and its allocator is a bump pointer that never frees. Reusing a single
// instance across compiles therefore (a) leaks ~77 MB per run — re-parsed
// druntime/Phobos that is never reclaimed — so a few dozen runs exhaust the
// wasm32 address space, and (b) corrupts global state (e.g. `import std.stdio`
// compiles on the first run but traps on the second). A fresh instance per
// compile sidesteps both: clean state and clean memory every time, and the
// previous instance's memory is reclaimed by the JS GC once it's unreferenced.
function newInstance() {
    const instance = new WebAssembly.Instance(wasmModule, {
        wasi_snapshot_preview1: wasi,
        env: {},
    });
    exports = instance.exports;
    memory = exports.memory;
    if (exports.__wasm_call_ctors) exports.__wasm_call_ctors();
}

// Compile `source`, returning { ast, asm, errors, diagnostics }.
// `asm` is the -vasm x86 disassembly (the backend prints it to stdout).
export function compile(source) {
    newInstance();   // fresh memory + global state: no leak, no cross-run corruption
    stdoutText = "";
    stderrText = "";
    const bytes = te.encode(source);
    const ptr = exports.dmdwasm_input_buffer(bytes.length + 1);
    new Uint8Array(memory.buffer, ptr, bytes.length).set(bytes);
    new Uint8Array(memory.buffer, ptr + bytes.length, 1)[0] = 0;

    // A user snippet can still trap the instance (e.g. the `real.mant_dig`
    // static assert in float-heavy Phobos hits `unreachable`). Catch it so the
    // page survives — the next compile gets a brand-new instance regardless.
    try {
        exports.dmdwasm_run(ptr, bytes.length);
    } catch (e) {
        return {
            lex: "", parse: "", sema: "", ast: "", ir: "", irOpt: "",
            asm: stdoutText,
            errors: exports.dmdwasm_errors() || 1,
            diagnostics: stderrText + "\ndmd.wasm trapped: " + e.message,
        };
    }

    const astPtr = exports.dmdwasm_ast_ptr();
    const astLen = exports.dmdwasm_ast_len();
    const ast = astLen ? td.decode(new Uint8Array(memory.buffer, astPtr, astLen)) : "";
    const parsePtr = exports.dmdwasm_parse_ptr();
    const parseLen = exports.dmdwasm_parse_len();
    const parse = parseLen ? td.decode(new Uint8Array(memory.buffer, parsePtr, parseLen)) : "";
    const semaPtr = exports.dmdwasm_sema_ptr();
    const semaLen = exports.dmdwasm_sema_len();
    const sema = semaLen ? td.decode(new Uint8Array(memory.buffer, semaPtr, semaLen)) : "";
    const lexPtr = exports.dmdwasm_lex_ptr();
    const lexLen = exports.dmdwasm_lex_len();
    const lex = lexLen ? td.decode(new Uint8Array(memory.buffer, lexPtr, lexLen)) : "";
    const irPtr = exports.dmdwasm_ir_ptr();
    const irLen = exports.dmdwasm_ir_len();
    const ir = irLen ? td.decode(new Uint8Array(memory.buffer, irPtr, irLen)) : "";
    const irOptPtr = exports.dmdwasm_iropt_ptr();
    const irOptLen = exports.dmdwasm_iropt_len();
    const irOpt = irOptLen ? td.decode(new Uint8Array(memory.buffer, irOptPtr, irOptLen)) : "";
    return { lex, parse, sema, ast, ir, irOpt, asm: stdoutText, errors: exports.dmdwasm_errors(), diagnostics: stderrText };
}
