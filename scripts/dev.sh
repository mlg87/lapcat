#!/usr/bin/env bash
# Builds the debug app bundle and runs it in the foreground (logs on stdout).
# The app only ever runs bundled: TCC keys privacy grants to the bundle's signature.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/bundle-app.sh debug
exec build/LapCat.app/Contents/MacOS/LapCat "$@"
