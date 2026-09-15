#!/bin/sh
set -eu

usage() {
  cat <<'USAGE'
usage: compiler/wasm/trypr.sh [--in-place] [--no-apply] [--out DIR] [--repo OWNER/NAME] <pr-number>
       compiler/wasm/trypr.sh --index DIR

Builds dmd.wasm from a dlang/dmd pull request applied on top of this checkout
(the wasm-web-app branch) so the explorer can run that PR's compiler.

  ./compiler/wasm/trypr.sh 23803
      Creates worktrees under tmp/prbuild/ from this checkout's HEAD and from
      PHOBOS_ROOT's HEAD, applies the PR's diff (merge-base..head) to the dmd
      one, builds the native dmd, the wasm druntime + Phobos archives and
      dmd.wasm there, and writes compiler/wasm/web/pr/23803/ with dmd.wasm,
      meta.json, and the PR's test cases as examples/ + examples.json, plus
      pr/index.json. Then serve compiler/wasm/web and open index.html?pr=23803.
      Worktrees persist, so later builds are incremental.

  --in-place  apply the PR to this checkout and PHOBOS_ROOT directly (CI)
  --no-apply  the tree already contains the PR (resolved by hand after a
              conflict, or a prepared branch): skip the reset and the apply
  --out DIR   write the build there instead of web/pr/<N>
  --repo R    repository the PR belongs to (default dlang/dmd)
  --index DIR regenerate DIR/index.json from DIR/*/meta.json and exit

Environment: PHOBOS_ROOT (default: the phobos checkout next to the main dmd
repository), HOST_DMD (build.d), GH_TOKEN (gh in CI), TRYPR_SOURCE (recorded
in meta.json as "source": manual (default) or label, for automation).
Requires gh (https://cli.github.com) with access to the PR's repository.
Exit status 2 means the PR did not apply cleanly; resolve the conflicts in the
tree it names and rerun with --no-apply.
USAGE
}

gen_index() {
  d="$1"
  first=1
  {
    printf '['
    for n in $(ls "$d" 2>/dev/null | grep -E '^[0-9]+$' | sort -rn); do
      [ -f "$d/$n/meta.json" ] || continue
      [ "$first" = 1 ] || printf ','
      first=0
      cat "$d/$n/meta.json"
    done
    printf ']\n'
  } > "$d/index.json"
  echo "wrote $d/index.json"
}

fresh_worktree() {
  if [ -L "$2" ] || { [ -e "$2" ] && [ ! -f "$2/.git" ]; }; then
    echo "$2 exists but is not a linked worktree; remove it first" >&2
    exit 1
  fi
  if [ -f "$2/.git" ]; then
    git -C "$2" reset -q --hard
    git -C "$2" clean -qfd
    git -C "$2" checkout -q --detach "$3"
  else
    git -C "$1" worktree add -q --detach "$2" "$3"
  fi
}

DMD_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REPO=dlang/dmd
INPLACE=
NOAPPLY=
OUT=
PR=

while [ $# -gt 0 ]; do
  case "$1" in
    --in-place) INPLACE=1 ;;
    --no-apply) NOAPPLY=1 ;;
    --out) OUT="$2"; shift ;;
    --repo) REPO="$2"; shift ;;
    --index) gen_index "$2"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option $1" >&2; usage >&2; exit 1 ;;
    *) PR="$1" ;;
  esac
  shift
done

case "${PR:-}" in
  ''|*[!0-9]*) usage >&2; exit 1 ;;
esac

command -v gh >/dev/null || { echo "gh not found: install https://cli.github.com" >&2; exit 1; }

if [ -z "${PHOBOS_ROOT:-}" ]; then
  PHOBOS_ROOT="$(cd "$(git -C "$DMD_ROOT" rev-parse --git-common-dir)/../../phobos" 2>/dev/null && pwd)" || true
fi
[ -n "${PHOBOS_ROOT:-}" ] || { echo "set PHOBOS_ROOT to a Phobos checkout (no ../phobos next to the main dmd repository)" >&2; exit 1; }
[ -f "$PHOBOS_ROOT/Makefile" ] || { echo "PHOBOS_ROOT=$PHOBOS_ROOT is not a Phobos checkout" >&2; exit 1; }

echo "== PR $REPO#$PR"
read -r HEAD BASEREF <<EOT
$(gh pr view "$PR" -R "$REPO" --json headRefOid,baseRefName --jq '"\(.headRefOid) \(.baseRefName)"')
EOT
BASE="$(gh api "repos/$REPO/compare/$BASEREF...$HEAD" --jq .merge_base_commit.sha)"
echo "   head $HEAD"
echo "   base $BASE ($BASEREF)"

BASEHEAD="$(git -C "$DMD_ROOT" rev-parse HEAD)"
if [ -n "$INPLACE" ]; then
  TREE="$DMD_ROOT"
  PHOBOS_TREE="$PHOBOS_ROOT"
else
  WORK="$DMD_ROOT/tmp/prbuild"
  TREE="$WORK/dmd"
  PHOBOS_TREE="$WORK/phobos"
  mkdir -p "$WORK"
  if [ -n "$NOAPPLY" ]; then
    [ -f "$TREE/.git" ] || { echo "--no-apply needs an existing tree at $TREE" >&2; exit 1; }
  else
    fresh_worktree "$DMD_ROOT" "$TREE" "$BASEHEAD"
  fi
  [ -f "$PHOBOS_TREE/.git" ] && [ -n "$NOAPPLY" ] || fresh_worktree "$PHOBOS_ROOT" "$PHOBOS_TREE" "$(git -C "$PHOBOS_ROOT" rev-parse HEAD)"
  mkdir -p "$TREE/generated/wasm"
  for t in "$DMD_ROOT"/generated/wasm/wasi-sysroot-*.tar.gz; do
    [ -f "$t" ] && [ ! -f "$TREE/generated/wasm/$(basename "$t")" ] && cp "$t" "$TREE/generated/wasm/"
  done
fi
echo "== dmd tree $TREE (explorer base $BASEHEAD)"
echo "== phobos tree $PHOBOS_TREE ($(git -C "$PHOBOS_TREE" rev-parse --short HEAD))"

if [ "$(git -C "$TREE" rev-parse --is-shallow-repository)" = true ]; then DEPTH=--depth=1; else DEPTH=; fi
git -C "$TREE" fetch -q $DEPTH "https://github.com/$REPO" "$BASE" "$HEAD"

if [ -n "$NOAPPLY" ]; then
  APPLIED=manual
  echo "== not applying the PR: using the tree as is"
else
  APPLIED=clean
  PATCH="$(mktemp)"
  git -C "$TREE" diff --binary "$BASE" "$HEAD" > "$PATCH"
  [ -s "$PATCH" ] || { echo "PR has no changes against $BASEREF" >&2; exit 1; }
  git -C "$TREE" diff --stat "$BASE" "$HEAD" | tail -1
  if ! git -C "$TREE" apply --3way "$PATCH"; then
    echo "== PR does not apply cleanly on top of $BASEHEAD; conflicts in:" >&2
    git -C "$TREE" diff --name-only --diff-filter=U >&2
    echo "   (resolve them in $TREE and rerun with --no-apply, or merge a newer $BASEREF into this branch)" >&2
    rm -f "$PATCH"
    exit 2
  fi
  rm -f "$PATCH"
fi

echo "== building native dmd"
(cd "$TREE" && ./compiler/src/build.d)
DMDBIN="$TREE/generated/linux/release/64/dmd"

echo "== building wasm druntime + Phobos"
make -C "$TREE/druntime" wasm -j"$(nproc)"
make -C "$PHOBOS_TREE" wasm -j"$(nproc)"

echo "== building dmd.wasm"
(cd "$TREE" && DMD="$DMDBIN" PHOBOS_ROOT="$PHOBOS_TREE" ./compiler/wasm/build.sh)

if [ -n "$OUT" ]; then GEN_INDEX=; else OUT="$DMD_ROOT/compiler/wasm/web/pr/$PR"; GEN_INDEX=1; fi
mkdir -p "$OUT"
cp "$TREE/compiler/wasm/dmd.wasm" "$OUT/dmd.wasm"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
gh pr view "$PR" -R "$REPO" --json number,title,author,url,headRefOid,baseRefName,state \
  --jq "{pr:.number,repo:\"$REPO\",title:.title,author:.author.login,url:.url,head:.headRefOid,baseRef:.baseRefName,base:\"$BASE\",state:.state,builtAt:\"$NOW\",explorerRef:\"$BASEHEAD\",applied:\"$APPLIED\",source:\"${TRYPR_SOURCE:-manual}\"}" \
  > "$OUT/meta.json"

rm -rf "$OUT/examples"
mkdir -p "$OUT/examples"
first=1
{
  printf '['
  for f in $(git -C "$TREE" diff --name-only --diff-filter=AM "$BASE" "$HEAD" -- compiler/test | grep -E '^compiler/test/(compilable|runnable|fail_compilation)/[A-Za-z0-9_.-]+\.d$'); do
    [ -f "$TREE/$f" ] || continue
    rel="${f#compiler/test/}"
    name="$(echo "$rel" | tr / _)"
    case "${rel%%/*}" in
      compilable) panes=sema,diag ;;
      fail_compilation) panes=diag ;;
      *) panes=run,diag ;;
    esac
    cp "$TREE/$f" "$OUT/examples/$name"
    [ "$first" = 1 ] || printf ','
    first=0
    printf '{"label":"%s","file":"examples/%s","panes":"%s"}' "$rel" "$name" "$panes"
  done
  printf ']\n'
} > "$OUT/examples.json"
echo "   $(ls "$OUT/examples" | wc -l) test cases exported as examples"

[ -z "$GEN_INDEX" ] || gen_index "$(dirname "$OUT")"
echo "== done: $OUT"
[ -z "$GEN_INDEX" ] || echo "   serve $DMD_ROOT/compiler/wasm/web and open index.html?pr=$PR"
