#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./install.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ROOT=$tmp
mkdir -p "$ROOT/state"
# Redirect only the lock boundary; exercise the real sync function.
# shellcheck disable=SC2016
eval "$(declare -f sync_cf | sed 's|/run/mmwx-cf.lock|$ROOT/cf.lock|g')"
flock() { return 1; }
if (sync_cf) >/dev/null; then echo 'Busy firewall lock incorrectly reported success'; exit 1; fi
flock() { :; }
fetch_cf() { printf '173.245.48.0/20\n' > "$1"; }
apply_firewall_rules() { echo applied >> "$ROOT/events"; }
remove_legacy_cf_rules() { :; }
sync_cf
echo continued >> "$ROOT/events"
[[ $(cat "$ROOT/events") == $'applied\ncontinued' ]]
# Legacy layout continues refreshing even after the management command is removed.
printf '{"domain":"legacy.example.com"}' > "$ROOT/state.json"
rm "$ROOT/state/cloudflare-v4.txt"
dc() { :; }
sync_cf
[[ -f $ROOT/cloudflare-v4.txt && -f $ROOT/Caddyfile ]]
grep -q 'legacy.example.com' "$ROOT/Caddyfile"
echo 'PASS: CF synchronization reports lock failure, preserves caller flow and supports legacy layout'
