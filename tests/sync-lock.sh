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
# shellcheck disable=SC2317,SC2329
dc() { :; }
sync_cf
[[ -f $ROOT/cloudflare-v4.txt && -f $ROOT/Caddyfile ]]
grep -q 'legacy.example.com' "$ROOT/Caddyfile"
# Successful reloads write JSON on stderr; keep this out of the terminal.
dc() {
  case "$*" in
    'ps --status running -q caddy') echo caddy-container;;
    'exec -T caddy caddy reload --config /etc/caddy/Caddyfile') printf '{"level":"info","msg":"reload-details"}\n' >&2;;
  esac
}
sync_cf > "$ROOT/screen" 2>&1
if grep -q reload-details "$ROOT/screen"; then echo 'Caddy JSON leaked to screen'; exit 1; fi
grep -q reload-details "$ROOT"/state/logs/*.log
# The daily renderer reads subscription state instead of an empty shell global.
rm "$ROOT/state.json"
mkdir -p "$ROOT/config"
printf '{"domain":"panel.example.com","subscription_domain":"mmw.example.com"}' > "$ROOT/state/state.json"
SUBSCRIPTION_DOMAIN=''
sync_cf > "$ROOT/screen" 2>&1
grep -q '^panel.example.com {' "$ROOT/config/Caddyfile"
grep -q '^mmw.example.com {' "$ROOT/config/Caddyfile"
grep -q 'respond 404' "$ROOT/config/Caddyfile"
echo 'PASS: CF synchronization reports lock failure, preserves caller flow and supports legacy layout'
