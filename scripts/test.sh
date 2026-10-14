#!/bin/bash
# Runs the Swift Testing suite with Command Line Tools only (no Xcode).
# CLT ships Testing.framework outside the default search paths, and Swift 6.4's default
# build system needs Xcode, so we use the native build system and add the paths by hand.
set -euo pipefail
cd "$(dirname "$0")/.."
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
swift test --build-system native \
  -Xswiftc -F -Xswiftc "$F" -Xlinker -F -Xlinker "$F" \
  -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L" "$@" 2>&1 | grep -v "has been deprecated"
