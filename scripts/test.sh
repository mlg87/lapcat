#!/usr/bin/env bash
# Runs the Swift Testing suites. Use this instead of bare `swift test`.
#
# The Command Line Tools keep Testing.framework outside the default search path, so a bare
# `swift test` compiles SwiftPM's generated runner with `canImport(Testing) == false` and
# silently runs zero tests. These flags apply to every target, the runner included. The CLT
# Testing×Foundation cross-import overlay ships without a swiftmodule, hence the overlay flag.
# With Xcode installed the flags are unnecessary and skipped.
set -euo pipefail
cd "$(dirname "$0")/.."

clt="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
flags=()
if [[ "$(xcode-select -p)" == /Library/Developer/CommandLineTools* && -d "$clt/Testing.framework" ]]; then
  flags=(
    -Xswiftc -F -Xswiftc "$clt"
    -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays
    -Xlinker -rpath -Xlinker "$clt"
  )
fi

exec swift test "${flags[@]}" "$@"
