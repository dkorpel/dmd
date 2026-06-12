#!/bin/sh
# Build the DMD frontend to WebAssembly (milestone 1: -vcg-ast AST dump).
# Run from the dmd repo root: ./compiler/wasm/build.sh
set -e

DMD_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$DMD_ROOT"

WASI_LIBC="${WASI_LIBC:-/home/dennis/repos1/wasi-libc/sysroot/lib/wasm32-wasi/libc.a}"
RTLIB="$DMD_ROOT/compiler/wasm/lib/libcompiler-rt-wasm.a"
DRT="$DMD_ROOT/druntime/src"

ldmd2 -mtriple=wasm32-unknown-unknown-wasi -defaultlib= \
  -L-allow-undefined -L"$WASI_LIBC" -L"$RTLIB" -L--no-entry \
  -L--export=dmdwasm_run -L--export=dmdwasm_ast_ptr -L--export=dmdwasm_ast_len \
  -L--export=dmdwasm_parse_ptr -L--export=dmdwasm_parse_len \
  -L--export=dmdwasm_sema_ptr -L--export=dmdwasm_sema_len \
  -L--export=dmdwasm_lex_ptr -L--export=dmdwasm_lex_len \
  -L--export=dmdwasm_ir_ptr -L--export=dmdwasm_ir_len \
  -L--export=dmdwasm_iropt_ptr -L--export=dmdwasm_iropt_len \
  -L--export=dmdwasm_errors -L--export=dmdwasm_input_buffer -L--export=dmdwasm_selftest -L--export=dmdwasm_run_stdin -L--export=__wasm_call_ctors \
  -Oz \
  -J. -Jcompiler/src/dmd/res -Jcompiler/wasm \
  -i -Icompiler/wasm/shim -Icompiler/src -I"$DRT" -i=core -i=rt -i=dmd \
  compiler/wasm/dmdwasm.d compiler/wasm/dmdwasm_lexdump.d compiler/wasm/dmdwasm_irdump.d compiler/wasm/rthooks.d \
  -of=compiler/wasm/dmd.wasm "$@"

# Publish the built module to the web harness so `web/` is self-contained.
cp compiler/wasm/dmd.wasm compiler/wasm/web/dmd.wasm
