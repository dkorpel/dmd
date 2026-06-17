// Runs the DMD frontend off the main thread. The compile() call is synchronous
// wasm that would otherwise freeze the page (no repaint, no input) for its whole
// duration; hosting it in a worker keeps the UI — spinner, typing, scrolling —
// responsive while a compile is in flight.
//
// Protocol (main thread -> worker):
//   { type: "load", url }      -> loads/compiles dmd.wasm, replies "loaded"/"loadError"
//   { type: "compile", src }   -> compiles `src`, replies "result"
// Replies carry only structured-cloneable data (plain strings/objects).

import { loadDmd, compile, dmdLastModified } from "./glue.js";

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
    if (msg.type === "compile") {
        let result;
        try {
            result = compile(msg.src);
        } catch (err) {
            // compile() already catches wasm traps; this guards anything else so a
            // bad run reports an error instead of killing the worker.
            result = {
                lex: "", parse: "", sema: "", ast: "", ir: "", irOpt: "", asm: "", asmUnopt: "",
                errors: 1,
                diagnostics: "dmd.wasm worker error: " + String((err && err.message) || err),
            };
        }
        self.postMessage({ type: "result", result });
    }
};
