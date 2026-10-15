#!/bin/bash
# Measures Margin as a user feels it, in an optimised build with the control hook (scripts/build.sh --bench).
#
#   scripts/bench.sh build [<git-ref>]          a bench app of this tree (or of <ref>, in a temporary worktree);
#                                               prints its path under .build/bench-apps/
#   scripts/bench.sh run [--app <app>] [opts]   N captures of each kind; median / p90 / min / max per metric
#   scripts/bench.sh ab <A.app> <B.app> [opts]  two builds, interleaved in blocks, side by side
#   scripts/bench.sh launch [--shelf <file>]    launch → ready and memory, N times
#   scripts/bench.sh report <results.jsonl>…    the table again
#   scripts/bench.sh encode <png>…              PNG encode options on real captures (offline)
#   scripts/bench.sh micro                      offline timings of small main-thread steps
#   scripts/bench.sh make-shelf <dir> <n>       a shelf.json of n cards, for launch --shelf
#
# `scripts/bench.sh help` lists every option. The driver (scripts/bench/) is compiled once with MarginKit.
set -euo pipefail
cd "$(dirname "$0")/.." >/dev/null
ROOT=$(pwd)
TOOL_DIR="$ROOT/.build/bench-tool"
TOOL="$TOOL_DIR/bench"

build_tool() {
  local sources=("$ROOT"/scripts/bench/*.swift "$ROOT"/Sources/MarginKit/*.swift)
  local stale=0
  if [[ ! -x "$TOOL" ]]; then stale=1; else
    for f in "${sources[@]}"; do [[ "$f" -nt "$TOOL" ]] && stale=1 && break; done
  fi
  if [[ "$stale" == 1 ]]; then
    mkdir -p "$TOOL_DIR"
    echo "==> Compiling the bench driver" >&2
    swiftc -O -swift-version 5 -module-name MarginBench "${sources[@]}" -o "$TOOL" 2>&1 \
      | grep -v -e "warning:" -e "^ *|" -e "^ *[0-9]* |" -e "^\[#" -e "^$" >&2 || true
    [[ -x "$TOOL" ]] || { echo "bench.sh: the driver didn't compile" >&2; exit 1; }
  fi
}

case "${1:-help}" in
  build)
    REF="${2:-}"
    if [[ -z "$REF" ]]; then
      scripts/build.sh --bench >&2
      SRC="$ROOT/.build/app/bench/Margin.app"
      NAME="$(git rev-parse --short HEAD)$([[ -n "$(git status --porcelain -- Sources Package.swift Resources)" ]] && echo -dirty || true)"
    else
      SHA=$(git rev-parse --short "$REF")
      TMP="$ROOT/.build/bench-src/$SHA"
      rm -rf "$TMP"
      git worktree add --detach "$TMP" "$REF" >&2
      (cd "$TMP" && scripts/build.sh --bench >&2)
      SRC="$TMP/.build/app/bench/Margin.app"
      NAME="$SHA"
    fi
    OUT="$ROOT/.build/bench-apps/$NAME/Margin.app"
    rm -rf "$OUT"
    mkdir -p "$(dirname "$OUT")"
    ditto "$SRC" "$OUT"
    if [[ -n "$REF" ]]; then git worktree remove --force "$TMP" >&2; fi
    echo "$OUT"
    ;;
  *)
    build_tool
    exec "$TOOL" "$@"
    ;;
esac
