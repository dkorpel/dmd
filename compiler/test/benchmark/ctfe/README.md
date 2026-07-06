# CTFE benchmarks

Measures wall time and peak RSS of CTFE-heavy compiles, to track the
linear-memory CTFE project (see `compiler/docs/ctfe_linear_memory.md`).

Each file in `cases/` is a self-contained module (no imports) whose top-level
`enum` forces a heavy CTFE evaluation. Cases are compiled with `-c -o-` so
only lexing/parsing/semantic/CTFE run — no code generation.

## Usage

```sh
# Single compiler: absolute numbers
./bench.sh path/to/dmd

# Two compilers: comparison table
./bench.sh path/to/dmd-baseline path/to/dmd-linear

# One binary, with/without the linear-memory preview
BFLAGS=-preview=ctfeLinearMemory ./bench.sh path/to/dmd path/to/dmd
```

`RUNS` (default 5) sets repetitions per case; best time and max RSS are
reported. `DFLAGS` adds flags to every compile; `AFLAGS`/`BFLAGS` add flags
to only the first/second compiler.

## Baseline

Recorded 2026-07-05, master @ 6922fef759, Linux x86_64, host dmd 2.112.0:

| case           |   time (s) |  RSS (MiB) |
|:--------------|----------:|----------:|
| deep_calls     |       0.29 |       24.8 |
| int_loop       |       0.79 |       52.3 |
| sort_array     |       0.95 |       70.3 |
| string_build   |       0.18 |      136.7 |
| struct_array   |       0.33 |       52.5 |

Note `string_build`: 0.18 s of work but 136.7 MiB peak RSS — intermediate
string values as AST nodes dominate memory, which is exactly what the
linear-memory representation targets.

## Results with `-preview=ctfeLinearMemory`

Recorded 2026-07-06, same machine, phases 3–4+6 implemented. The compiler
binary matters: an optimized build (ldc2 1.42.0, `-O3 -flto=full` + PGO
trained on Phobos in both modes) makes the AST path's region bump-allocation
nearly free, which shifts the time comparison against the linear path.
Numbers below are from the PGO binary with the byte-native scalar tier
(`tryEvalScalarRaw`: whole integral expression trees, RMW assignments and
argument staging evaluate on raw values, no intermediate nodes) and the
linear slice-return channel (a call's slice result stored straight into a
slice variable hands over the 16-byte handle instead of materializing an
AST array) — times are hyperfine means (`--warmup 2`), RSS is max over 5
runs via bench.sh.

| case           | time AST (ms) | time linear (ms) | RSS AST (MiB) | RSS linear (MiB) |  Δ time |   Δ RSS |
|:--------------|-------------:|----------------:|-------------:|----------------:|--------:|--------:|
| deep_calls     |          64.1 |             83.5 |          20.1 |             23.1 |    +30% |    +15% |
| int_loop       |         155.0 |            101.0 |          47.7 |             19.2 |    -35% |    -60% |
| sort_array     |         203.8 |            163.4 |          64.1 |             22.5 |    -20% |    -65% |
| string_build   |          95.9 |             41.5 |         131.9 |             24.5 |    -57% |    -81% |
| struct_array   |          79.2 |             71.1 |          47.5 |             24.7 |    -10% |    -48% |

Real-world check: `std.regex` unittests (heaviest ctRegex CTFE load) go
from 2.94 s / 1611 MiB to 2.92 s / 804 MiB — peak RSS halved, wall time at
parity with master (−1% to −3% across runs, within noise).

Reading: memory drops massively on all aggregate-heavy cases, and time wins
wherever loops, allocation volume, or array-returning functions dominate
(`string_build`'s AST run spends ~55 of 96 ms in system time faulting in
freshly allocated pages; `sort_array` flipped from +10% to −20% when
returned arrays stopped materializing). The remaining loss is scalar
call-dominated code (`deep_calls` is ~25 ns/call of extra frame/staging/
return-decode work over the AST path) — closing that needs a raw-value
calling convention for scalars, i.e. the full bytecode-interpreter step.
(With an unoptimized host-dmd build the AST path's allocator is slower and
the linear path looks uniformly better — always benchmark the optimized
binary.)
