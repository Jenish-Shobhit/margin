#!/bin/bash
# Drives a DEBUG build of Margin (scripts/build.sh --debug) through its control hook.
#
#   scripts/debug.sh capture-area <x> <y> <w> <h>   capture a rect (AppKit global points), no overlay
#   scripts/debug.sh capture-screen                 capture the display under the pointer
#   scripts/debug.sh toggle-shelf                   tuck / show the shelf
#   scripts/debug.sh clear                          Close Shelf: every card off the shelf, files kept (undoable)
#   scripts/debug.sh dismiss [n]                    remove the n newest cards (undoable), keeping the keys where they are
#   scripts/debug.sh restore-last                   Restore Last Removed (the shelf's ⌘Z)
#   scripts/debug.sh hover-shelf [off]              as if the pointer were on the newest card (its chrome, Close Shelf)
#   scripts/debug.sh show settings [pane]|menu [s]  open Settings (general, shortcuts, recording), or the menu bar menu for s seconds
#   scripts/debug.sh dump-state                     print the app state (shelf, mark, recording, timings…) as JSON
#   scripts/debug.sh record-area <x> <y> <w> <h>    record a rect (AppKit global points), no overlay
#   scripts/debug.sh record-screen                  record the display under the pointer
#   scripts/debug.sh record-window [<id>]           record a window (by window number; the frontmost without one)
#   scripts/debug.sh stop-recording                 stop and save the recording, as ⇧⌘5 does
#   scripts/debug.sh recording-fault fail           the recording's writer fails now, as on a full disk (debug builds)
#   scripts/debug.sh recording-fault crash          Margin exits at once mid-recording, as in a crash (debug builds)
#   scripts/debug.sh recording-fault hang-stream    the next stop's stopCapture never answers (debug builds)
#   scripts/debug.sh recording-fault hang-finish    the next stop's finishWriting never answers (debug builds)
#   scripts/debug.sh recording-fault limit <bytes>  later recordings stop near that file size, as at FAT32's 4 GB ("off" resets)
#
# Commands are posted as the distributed notification io.github.jenish-shobhit.margin.debug with the
# command string as its object. Release builds don't listen.
#
# The updater's commands (spec §14.3; all of them are in Sources/Margin/Debug/UpdateDebugCommands.swift):
#   scripts/debug.sh update-check [<feed-url>]      Check for Updates…, against a local feed when given (file://, http://127.0.0.1)
#   scripts/debug.sh update-install                 Install and Relaunch (also update-later, update-skip, update-cancel)
#   scripts/debug.sh update-state                   write the updater's state to /tmp/margin-update-state.json
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
