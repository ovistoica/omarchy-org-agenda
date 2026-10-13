#!/usr/bin/env bash
# Static checks on the plugin folder, for CI and before publishing: the
# manifest is one the shell will accept, its widget settings are
# consistent, and the code keeps the safety rules the README promises
# (plain-text rendering only, a Model.js that QML can import as is).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="$root/manifest.json"
failures=0

ok() { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1" >&2; failures=$((failures + 1)); }

# check DESCRIPTION COMMAND...: report whether COMMAND succeeds.
check() {
  local description="$1"
  shift
  if "$@"; then ok "$description"; else bad "$description"; fi
}

# jq-true FILTER: the manifest satisfies the jq FILTER.
jq-true() { jq -e "$1" "$manifest" >/dev/null 2>&1; }

if ! jq -e . "$manifest" >/dev/null 2>&1; then
  bad "manifest.json parses"
  exit 1
fi
ok "manifest.json parses"

check "schemaVersion is 1" jq-true '.schemaVersion == 1'
check "id matches ^[a-z0-9-]+\\.[a-z0-9.-]+\$" \
  jq-true '.id | type == "string" and test("^[a-z0-9-]+\\.[a-z0-9.-]+$")'
check "kinds include service and bar-widget" \
  jq-true '.kinds | type == "array" and index("service") != null and index("bar-widget") != null'

entry-points-exist() {
  local missing
  missing="$(jq -r '.entryPoints | to_entries[] | .value' "$manifest" |
    while IFS= read -r rel; do [[ -f "$root/$rel" ]] || printf '%s\n' "$rel"; done)" || return 1
  [[ -z $missing ]] || { printf '      missing: %s\n' $missing >&2; return 1; }
}
check "entry-point files exist" entry-points-exist

# Each schema key has a default, and the two agree.
schema-matches-defaults() {
  local mismatches
  mismatches="$(jq -r '
    .barWidget.defaults as $defaults
    | .barWidget.schema[]
    | .key as $k
    | select(($defaults | has($k) | not) or ($defaults[$k] != .defaultValue))
    | $k' "$manifest")" || return 1
  [[ -z $mismatches ]] || { printf '      key: %s\n' $mismatches >&2; return 1; }
}
check "every schema key has an equal default" schema-matches-defaults

schema-types-known() {
  local unknown
  unknown="$(jq -r '
    ["boolean", "enum", "integer", "multiselect", "path", "string"] as $known
    | .barWidget.schema[]
    | select(.type as $t | $known | index($t) | not)
    | "\(.key) (\(.type))"' "$manifest")" || return 1
  [[ -z $unknown ]] || { printf '      %s\n' "$unknown" >&2; return 1; }
}
check "schema types are known" schema-types-known

# The shell refuses plugin folders that contain symlinks.
no-symlinks() {
  local links
  links="$(find "$root" -name .git -prune -o -type l -print)"
  [[ -z $links ]] || { printf '      %s\n' "$links" >&2; return 1; }
}
check "no symlinks in the plugin folder" no-symlinks

# QML imports Model.js as a plain script: no modules, no Node APIs.
check "Model.js passes node --check" node --check "$root/Model.js"
model-is-plain-script() {
  ! grep -nE '^[[:space:]]*(export|import)[[:space:]{*]|require\(' "$root/Model.js" >&2
}
check "Model.js has no export/import/require(" model-is-plain-script

# Org text is shown as plain text only, through PlainText.qml.
no-rich-text() {
  ! grep -nE 'Text\.(StyledText|RichText)' "$root"/*.qml >&2
}
check "no QML uses Text.StyledText or Text.RichText" no-rich-text

no-bare-text() {
  local files=()
  mapfile -t files < <(find "$root" -name .git -prune -o -name '*.qml' ! -name PlainText.qml -print)
  ! grep -nE '(^|[^A-Za-z0-9_.])Text[[:space:]]*\{' "${files[@]}" >&2
}
check "no bare Text { outside PlainText.qml" no-bare-text

if ((failures > 0)); then
  printf '%d check(s) failed\n' "$failures" >&2
  exit 1
fi
echo "all manifest checks passed"
