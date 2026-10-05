#!/bin/bash
set -u
global=$1
max=${2:-10}
steps=${3:-1}
root=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$root"
tool=generated/deglobal/deglobal
base=tmp/deglobal/dmd-base
skipfile=tmp/deglobal/skip-$global.txt
log=tmp/deglobal/loop-$global.log
touch "$skipfile"

build() {
    ./compiler/src/build.d >"$log.build" 2>&1 &&
    ./compiler/src/build.d BUILD=debug >>"$log.build" 2>&1 &&
    ./compiler/src/build.d unittest >>"$log.build" 2>&1
}

keepfile=compiler/tools/deglobal/keep-$global.txt
skips() { local s; s=$(cat "$skipfile" "$keepfile" 2>/dev/null | grep . | paste -sd,); [ -n "$s" ] && echo "--skip=$s"; }

for ((i = 0; i < steps; i++)); do
    git diff --quiet compiler/src || { echo "dirty tree"; exit 1; }
    chosen=$($tool step --global="$global" --max="$max" $(skips)) || { echo "tool failed"; exit 1; }
    [ -z "$chosen" ] && { echo "no more candidates"; exit 0; }
    if ! build; then
        git checkout -q compiler/src
        good=()
        for f in $(echo "$chosen" | awk '{print $1}'); do
            $tool step --global="$global" --max=1 --only="$f" $(skips) >/dev/null
            if build; then
                good+=("$f")
            else
                echo "$f" >> "$skipfile"
                echo "skip $f (build failed)" | tee -a "$log"
            fi
            git checkout -q compiler/src
        done
        [ ${#good[@]} = 0 ] && continue
        chosen=$($tool step --global="$global" --max="$max" --only="$(IFS=,; echo "${good[*]}")" $(skips))
        build || { echo "combined build failed"; git checkout -q compiler/src; exit 1; }
    fi
    if ! ./compiler/tools/deglobal/oracle.sh "$base" > "$log.oracle"; then
        echo "codegen changed with: $chosen" | tee -a "$log"
        cat "$log.oracle"
        exit 1
    fi
    names=$(echo "$chosen" | awk '{print $1 "()"}' | paste -sd, | sed 's/,/, /g')
    n=$(echo "$chosen" | wc -l)
    if [ "$n" = 1 ]; then subject="backend: pass $global as parameter to $names"; else subject="backend: pass $global as parameter to $n functions"; fi
    git commit -q -am "$subject" -m "$names" -m "Generated with compiler/tools/deglobal" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
    echo "committed: $names" | tee -a "$log"
done
