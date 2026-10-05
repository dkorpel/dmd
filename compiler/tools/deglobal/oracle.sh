#!/bin/bash
set -u
root=$(cd "$(dirname "$0")/../../.." && pwd)
base=$(realpath "$1")
new=$(realpath "${2:-$root/generated/linux/release/64/dmd}")
out=$root/tmp/deglobal/oracle
rm -rf "$out"
mkdir -p "$out"
cd "$root"

configs=(
    "o64|-m64 -O -inline -release"
    "g64|-m64 -g"
    "o32|-m32 -O -fPIC"
    "win|-os=windows -m64 -O -g"
    "osx|-os=osx -m64 -O -g"
)

{
    ls compiler/test/runnable/*.d | grep -v test17338
    ls compiler/src/dmd/backend/*.d compiler/src/dmd/backend/x86/*.d compiler/src/dmd/backend/arm/*.d
} > "$out/files"

run() {
    cfg=$1; flags=$2; file=$3
    name=$(echo "$file" | tr / _)
    common="-c -conf= -I=druntime/src -I=compiler/src -J=compiler/src/dmd/res -J=generated/linux/release/64 -w -verrors=0"
    obj="$out/$cfg/work/$name.o"
    timeout 60 "$base" $common $flags -of="$obj" "$file" >/dev/null 2>&1
    bs=$?
    [ -f "$obj" ] && mv "$obj" "$out/$cfg/base/$name.o"
    timeout 60 "$new" $common $flags -of="$obj" "$file" >/dev/null 2>&1
    ns=$?
    [ -f "$obj" ] && mv "$obj" "$out/$cfg/new/$name.o"
    if [ $bs != $ns ]; then
        echo "STATUS $cfg $file $bs $ns"
    elif [ $bs = 0 ]; then
        if cmp -s "$out/$cfg/base/$name.o" "$out/$cfg/new/$name.o"; then
            echo "SAME $cfg $file"
            rm -f "$out/$cfg/base/$name.o" "$out/$cfg/new/$name.o"
        else
            echo "DIFF $cfg $file"
        fi
    else
        echo "FAIL $cfg $file"
    fi
}
export -f run
export SOURCE_DATE_EPOCH=0
export base new out

for c in "${configs[@]}"; do
    cfg=${c%%|*}
    mkdir -p "$out/$cfg/base" "$out/$cfg/new" "$out/$cfg/work"
    sed "s/^/$cfg|${c#*|}|/" "$out/files"
done | xargs -P "${JOBS:-12}" -d '\n' -I{} bash -c 'IFS="|" read -r cfg flags file <<< "{}"; run "$cfg" "$flags" "$file"' > "$out/results"

for k in SAME DIFF STATUS FAIL; do
    printf "%-7s %6d\n" $k "$(grep -c "^$k " "$out/results")"
done
grep -E "^(DIFF|STATUS) " "$out/results" | head -20
! grep -qE "^(DIFF|STATUS) " "$out/results"
