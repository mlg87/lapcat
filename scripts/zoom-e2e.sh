#!/usr/bin/env bash
# Runs `lapcat-dev zoom-e2e` (live Zoom end-to-end check) with the secrets from .env.zoom-e2e.
# See README § Zoom end-to-end run for the one-time setup.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -f .env.zoom-e2e ]; then
  set -a
  . ./.env.zoom-e2e
  set +a
fi
exec swift run lapcat-dev zoom-e2e "$@"
