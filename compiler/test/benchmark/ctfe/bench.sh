#!/usr/bin/env bash
# CTFE benchmark runner.
#
# Compiles each case in cases/ with -o- (semantic + CTFE only, no codegen)
# and reports wall time and peak RSS. With two compilers, prints a
# comparison table with deltas — use this to compare the AST-node and
# linear-memory CTFE representations.
#
# Usage:
#   ./bench.sh <dmd> [<dmd2>]
#
# Environment:
#   RUNS=5        repetitions per case; best time / max RSS is reported
#   DFLAGS=...    extra flags passed to every compile
#   AFLAGS=...    extra flags for compiler A only (e.g. compare one binary
#   BFLAGS=...    extra flags for compiler B only  with/without a -preview)
set -euo pipefail
cd "$(dirname "$0")"

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "usage: $0 <dmd> [<dmd2>]" >&2
    exit 1
fi

RUNS="${RUNS:-5}"
DFLAGS="${DFLAGS:-}"
AFLAGS="${AFLAGS:-}"
BFLAGS="${BFLAGS:-}"
TIME=/usr/bin/time
[[ -x $TIME ]] || { echo "error: $TIME not found (needed for RSS measurement)" >&2; exit 1; }

# bench <compiler> <source> <flags> -> "seconds kilobytes" (best time, max RSS over RUNS)
bench() {
    local compiler=$1 src=$2 flags=${3:-}
    local best_t="" max_rss=0 out t rss
    for ((i = 0; i < RUNS; i++)); do
        out=$($TIME -f "%e %M" "$compiler" -c -o- $DFLAGS $flags "$src" 2>&1 >/dev/null) || {
            echo "error: $compiler failed on $src:" >&2
            echo "$out" >&2
            exit 1
        }
        # Last line of stderr is the time(1) format string.
        read -r t rss <<< "$(tail -n1 <<< "$out")"
        if [[ -z $best_t ]] || awk "BEGIN { exit !($t < $best_t) }"; then
            best_t=$t
        fi
        (( rss > max_rss )) && max_rss=$rss
    done
    echo "$best_t $max_rss"
}

mib() { awk "BEGIN { printf \"%.1f\", $1 / 1024 }"; }
pct() { awk "BEGIN { printf \"%+.1f%%\", ($2 - $1) / $1 * 100 }"; }

cases=(cases/*.d)
echo "runs per case: $RUNS (best time, max RSS)"
echo

if [[ $# -eq 1 ]]; then
    printf '| %-14s | %10s | %10s |\n' "case" "time (s)" "RSS (MiB)"
    printf '|:%s|%s:|%s:|\n' "$(printf -- '-%.0s' {1..14})" "$(printf -- '-%.0s' {1..10})" "$(printf -- '-%.0s' {1..10})"
    for src in "${cases[@]}"; do
        read -r t rss <<< "$(bench "$1" "$src" "$AFLAGS")"
        printf '| %-14s | %10s | %10s |\n' "$(basename "$src" .d)" "$t" "$(mib "$rss")"
    done
else
    printf '| %-14s | %10s | %10s | %10s | %10s | %8s | %8s |\n' \
        "case" "time A (s)" "time B (s)" "RSS A (MiB)" "RSS B (MiB)" "Δ time" "Δ RSS"
    printf '|:%s|%s:|%s:|%s:|%s:|%s:|%s:|\n' \
        "$(printf -- '-%.0s' {1..14})" "$(printf -- '-%.0s' {1..10})" "$(printf -- '-%.0s' {1..10})" \
        "$(printf -- '-%.0s' {1..10})" "$(printf -- '-%.0s' {1..10})" "$(printf -- '-%.0s' {1..8})" "$(printf -- '-%.0s' {1..8})"
    for src in "${cases[@]}"; do
        read -r ta rssa <<< "$(bench "$1" "$src" "$AFLAGS")"
        read -r tb rssb <<< "$(bench "$2" "$src" "$BFLAGS")"
        printf '| %-14s | %10s | %10s | %10s | %10s | %8s | %8s |\n' \
            "$(basename "$src" .d)" "$ta" "$tb" "$(mib "$rssa")" "$(mib "$rssb")" \
            "$(pct "$ta" "$tb")" "$(pct "$rssa" "$rssb")"
    done
    echo
    echo "A = $1${AFLAGS:+ $AFLAGS}"
    echo "B = $2${BFLAGS:+ $BFLAGS}"
fi
