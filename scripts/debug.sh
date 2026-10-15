#!/bin/bash
# Drives a DEBUG build of Margin (scripts/build.sh --debug) through its control hook.
#
#   scripts/debug.sh capture-area <x> <y> <w> <h>   capture a rect (AppKit global points), no overlay
#   scripts/debug.sh capture-screen                 capture the display under the pointer
#   scripts/debug.sh toggle-shelf                   tuck / show the shelf
#   scripts/debug.sh clear                          remove every item from the shelf (undoable)
#   scripts/debug.sh dismiss [n]                    remove the n newest cards (undoable), keeping the keys where they are
#   scripts/debug.sh restore-last                   Restore Last Removed (the shelf's ⌘Z)
#   scripts/debug.sh dump-state                     print the app state (shelf, mark, timings…) as JSON
#
# Commands are posted as the distributed notification io.github.jenish-shobhit.margin.debug with the
# command string as its object. Release builds don't listen.
set -euo pipefail

NAME="io.github.jenish-shobhit.margin.debug"
STATE="/tmp/margin-state.json"

if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
  exit $(( $# == 0 ? 2 : 0 ))
fi

post() {
  /usr/bin/osascript -l JavaScript - "$NAME" "$*" <<'JS' >/dev/null
ObjC.import('Foundation');
function run(argv) {
  $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately(
    $.NSString.stringWithString(argv[0]), $.NSString.stringWithString(argv[1]), $(), true);
  delay(0.2); // posting is asynchronous: give it time to leave before osascript exits
}
JS
}

if [[ "$1" == "dump-state" ]]; then
  rm -f "$STATE"
  post "$@"
  for _ in $(seq 1 50); do
    if [[ -s "$STATE" ]]; then
      cat "$STATE"
      echo
      exit 0
    fi
    sleep 0.1
  done
  echo "debug.sh: no reply in 5 s. Is a DEBUG build of Margin running?" >&2
  exit 1
fi

post "$@"
