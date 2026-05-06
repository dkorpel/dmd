// Tests that the WebAssembly target is recognized and sets the correct version identifiers.
// REQUIRED_ARGS: -mwasm32 -os=wasm -o-

version (WebAssembly) {} else static assert(0, "WebAssembly version not defined");
version (WASM32)      {} else static assert(0, "WASM32 version not defined");
version (CRuntime_WASI) {} else static assert(0, "CRuntime_WASI version not defined");
version (LittleEndian) {} else static assert(0, "LittleEndian version not defined");

// Should NOT define platform-specific versions
version (linux)   static assert(0, "linux should not be defined for WASM target");
version (Windows) static assert(0, "Windows should not be defined for WASM target");
version (OSX)     static assert(0, "OSX should not be defined for WASM target");
version (X86_64)  static assert(0, "X86_64 should not be defined for WASM target");
version (AArch64) static assert(0, "AArch64 should not be defined for WASM target");
