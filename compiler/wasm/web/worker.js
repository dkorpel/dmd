// Runs the DMD frontend off the main thread. The compile() call is synchronous
// wasm that would otherwise freeze the page (no repaint, no input) for its whole
// duration; hosting it in a worker keeps the UI — spinner, typing, scrolling —
// responsive while a compile is in flight.
//
// Protocol (main thread -> worker):
//   { type: "load", url }      -> loads/compiles dmd.wasm, replies "loaded"/"loadError"
//   { type: "warm" }          -> precompiles the runtime a Run needs, replies "warmed"
//   { type: "compile", src, wat } -> compiles `src`, replies "result"
//                              (`wat` also compiles it for the wasm target)
//   { type: "run", src }       -> compiles (if needed) and runs `src`, posting a
//                              "runPhase" per stage, replies "runResult"
// Replies carry only structured-cloneable data (plain strings/objects).

import { loadDmd, compile, run, warmRuntime, dmdLastModified } from "./glue.js";

self.onmessage = async (e) => {
    const msg = e.data;
    if (msg.type === "load") {
        try {
            await loadDmd(msg.url);
            const lm = dmdLastModified();
            self.postMessage({ type: "loaded", lastModified: lm ? lm.toISOString() : null });
        } catch (err) {
            self.postMessage({ type: "loadError", message: String((err && err.message) || err) });
        }
        return;
    }
    if (msg.type === "warm") {
        try {
            warmRuntime();
        } catch (err) {
            // A failed precompile is not fatal: the next run() falls back to
            // compiling the runtime itself.
        }
        self.postMessage({ type: "warmed" });
        return;
    }
    if (msg.type === "compile") {
        let result;
        try {
            result = compile(msg.src, { wat: !!msg.wat });
        } catch (err) {
            // compile() already catches wasm traps; this guards anything else so a
            // bad run reports an error instead of killing the worker.
            result = {
                lex: "", parse: "", sema: "", ast: "", ir: "", irOpt: "", asm: "", asmUnopt: "", wat: "",
                errors: 1,
                diagnostics: "dmd.wasm worker error: " + String((err && err.message) || err),
            };
        }
        self.postMessage({ type: "result", result });
        return;
    }
    if (msg.type === "run") {
        let result;
        try {
            result = run(msg.src, (phase) => self.postMessage({ type: "runPhase", phase }));
        } catch (err) {
            result = { output: "", errors: 1, diagnostics: "dmd.wasm worker error: " + String((err && err.message) || err) };
        }
        self.postMessage({ type: "runResult", result });
    }
};
