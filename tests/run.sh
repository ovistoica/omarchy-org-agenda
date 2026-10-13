#!/usr/bin/env bash
# Run the test suites in isolation: Emacs never sees the user's real HOME,
# so Org cannot write ids, persisted caches or anything else outside $tmp.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export XDG_CONFIG_HOME="$tmp/config"
export XDG_CACHE_HOME="$tmp/cache"
export XDG_DATA_HOME="$tmp/data"
export XDG_STATE_HOME="$tmp/state"
export TMPDIR="$tmp"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"

# stdin from /dev/null: any Org prompt fails fast instead of hanging.
emacs --batch -Q \
  -l ert \
  -l "$root/elisp/omarchy-org-agenda.el" \
  -l "$root/tests/agenda-test.el" \
  -f ert-run-tests-batch-and-exit </dev/null

if [[ -f "$root/tests/model.test.js" ]]; then
  node "$root/tests/model.test.js"
fi
