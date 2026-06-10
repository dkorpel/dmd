/**
 * WASI shim for core.stdc.fenv: druntime's fenv.d static-asserts "Unsupported
 * platform" for wasm. The backend (dmd.backend.fp) only needs the
 * floating-point-exception query/clear entry points and FE_ALL_EXCEPT; wasm has
 * no FP status register to inspect, so these are inert.
 */
module core.stdc.fenv;

extern (C) nothrow @nogc:

enum FE_ALL_EXCEPT = 0;

struct fenv_t { int __unused; }
alias fexcept_t = int;

int fetestexcept(int excepts) { return 0; }
int feclearexcept(int excepts) { return 0; }
int feraiseexcept(int excepts) { return 0; }
int fegetround() { return 0; }
int fesetround(int round) { return 0; }
int fegetenv(fenv_t* envp) { return 0; }
int fesetenv(const(fenv_t)* envp) { return 0; }
