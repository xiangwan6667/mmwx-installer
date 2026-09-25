#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./install.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ROOT=$tmp
mkdir -p "$ROOT/network-backup"
printf 'rolled-back\n' > "$ROOT/network-backup/state"
if (confirm_network) 2>/dev/null; then echo 'Expired network confirmation accepted'; exit 1; fi
# A tar failure after the DB backup must restart the old application.
printf '{}' > "$ROOT/state.json"
printf 'old-compose' > "$ROOT/compose.yaml"
preflight() { :; }
install_command() { :; }
configure_timezone() { :; }
load_state() { :; }
choose_version() { VERSION=v1; }
dc() { printf '%s\n' "$*" >> "$ROOT/operations"; }
tar() { return 1; }
if (update_stack) >/dev/null 2>&1; then echo 'Failed backup reported success'; exit 1; fi
grep -qx 'start mmwx caddy' "$ROOT/operations"
[[ $(cat "$ROOT/compose.yaml") == old-compose ]]
echo 'PASS: expired confirmation rejected; failed backup restarts old application'
