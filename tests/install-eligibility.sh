#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./install.sh
case $(uname -s) in MINGW*|MSYS*) jq() { command jq -b "$@"; };; esac
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ROOT=$tmp/root
fresh() { rm -rf "$ROOT"; mkdir -p "$ROOT/state" "$ROOT/config"; }
state() {
  printf '%s\n' '{"domain":"mmwx.example.com","channel":"stable","version":"v1.0.0","app":"app:v1","caddy":"caddy:test","pg":"postgres:test"}' > "$1"
}
status_is() {
  installation_status
  [[ $INSTALL_STATUS == "$1" ]] || { echo "Expected $1, got $INSTALL_STATUS: $INSTALL_STATUS_REASON"; exit 1; }
}
fresh
status_is fresh
install_entry_guard
mkdir -p "$ROOT/state/logs"
printf 'log' > "$ROOT/state/logs/task.log"
status_is fresh
printf '{"stage":1}\n' > "$ROOT/state/progress.json"
status_is incomplete
install_entry_guard
state "$ROOT/state/state.json"
status_is blocked
jq '. + {stage:5}' "$ROOT/state/state.json" > "$ROOT/state/progress.json"
status_is incomplete
jq '.version="v2.0.0"' "$ROOT/state/progress.json" > "$tmp/next"
mv "$tmp/next" "$ROOT/state/progress.json"
status_is blocked
fresh
printf '{"stage":1}\n' > "$ROOT/state/progress.json"
state "$ROOT/state/state.json"
jq '. + {stage:6}' "$ROOT/state/state.json" > "$ROOT/state/progress.json"
status_is incomplete
install_entry_guard
jq '.stage=7' "$ROOT/state/progress.json" > "$tmp/next"
mv "$tmp/next" "$ROOT/state/progress.json"
status_is installed
# A completed installation must stop before migration, preflight or confirmation.
ensure_layout() { echo migration >> "$tmp/side-effects"; }
preflight() { echo preflight >> "$tmp/side-effects"; }
confirm() { echo confirm >> "$tmp/side-effects"; return 1; }
if (install_stack) > "$tmp/output" 2>&1; then echo 'Installed host accepted'; exit 1; fi
[[ ! -f $tmp/side-effects ]]
grep -q '已安装' "$tmp/output"
# Guard is independent of container running state (including keep-data uninstall).
rm "$ROOT/state/progress.json"
status_is installed
if (install_entry_guard) > "$tmp/output" 2>&1; then exit 1; fi
fresh
state "$ROOT/state.json"
status_is installed
if (install_stack) > "$tmp/output" 2>&1; then exit 1; fi
[[ ! -f $tmp/side-effects ]]
jq '. + {stage:6}' "$ROOT/state.json" > "$ROOT/progress.json"
status_is incomplete
mkdir "$ROOT/.layout-migration"
status_is blocked
fresh
printf '{"stage":7}\n' > "$ROOT/state/progress.json"
status_is blocked
for value in '{' '{"stage":-1}' '{"stage":2.5}' '{"stage":8}' '{"stage":"1"}'; do
  printf '%s\n' "$value" > "$ROOT/state/progress.json"
  status_is blocked
done
fresh
printf '{}' > "$ROOT/state/state.json"
status_is blocked
fresh
state "$ROOT/state/state.json"
state "$ROOT/state.json"
status_is blocked
for item in config/compose.yaml data/app/value certs/data/cert postgres.env backups/snapshot state/network-state.json unknown-data/value; do
  fresh
  mkdir -p "$(dirname "$ROOT/$item")"
  printf retained > "$ROOT/$item"
  status_is blocked
  if (install_entry_guard) > "$tmp/output" 2>&1; then exit 1; fi
  [[ $(cat "$ROOT/$item") == retained ]]
done
fresh
printf '{}' > "$ROOT/state/update.json"
if (install_entry_guard) > "$tmp/output" 2>&1; then echo 'Pending update accepted'; exit 1; fi
[[ ! -f $tmp/side-effects ]]
fresh
state "$ROOT/state/state.json"
# Exercise main without touching /run or host commands: root check substituted only
# for Git Bash, and the real lock redirected into this private test directory.
# shellcheck disable=SC2016
eval "$(declare -f main | sed 's|/run/mmwx-installer.lock|"$tmp/installer.lock"|g; s/\$EUID/0/g')"
trace_start() { :; }
ACTION='' ACCEPT=0
if (main install) > "$tmp/output" 2>&1; then echo 'Direct CLI accepted installed host'; exit 1; fi
[[ ! -f $tmp/side-effects ]]
grep -q '已安装' "$tmp/output"
# The actual menu must mark the entry and return to its prompt without dispatch.
check_script_update() { :; }
printf '1\n0\n' > "$tmp/answers"
ask() {
  local answer
  IFS= read -r answer < "$tmp/answers"
  tail -n +2 "$tmp/answers" > "$tmp/remaining"
  mv "$tmp/remaining" "$tmp/answers"
  printf '%s' "$answer"
}
SELF=$tmp/dispatch.sh
printf '#!/usr/bin/env bash\necho unexpected > "%s"\n' "$tmp/dispatched" > "$SELF"
menu > "$tmp/menu"
grep -q '安装 / 继续安装（已安装）' "$tmp/menu"
[[ ! -e $tmp/dispatched ]]
echo 'PASS: install entry classifies fresh/incomplete/completed/legacy/unsafe state and blocks before side effects'
