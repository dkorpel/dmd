#!/bin/sh
set -e
root=$(cd "$(dirname "$0")/../../.." && pwd)
out=${1:-$root/generated/deglobal}
dmd -g -i -I="$root/compiler/src" -J="$root/compiler/src/dmd/res" -J="$root/generated/linux/release/64" \
    -version=NoBackend -version=GC -version=NoMain -version=MARS -version=CallbackAPI \
    -I="$root/compiler/tools/deglobal" -od="$out" -of="$out/deglobal" "$root/compiler/tools/deglobal/deglobal.d"
