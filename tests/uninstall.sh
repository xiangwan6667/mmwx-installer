#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./install.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ROOT=$tmp
mkdir -p "$ROOT/config" "$ROOT/state"
printf '{}' > "$ROOT/state/state.json"
printf 'data-to-keep' > "$ROOT/sentinel"
load_state() { :; }
ask() { printf '%s' "$CHOICE"; }
confirm() { printf '%s\n' "$1" >> "$ROOT/prompts"; [[ $ANSWER == y ]]; }
remove_services() { echo removed >> "$ROOT/calls"; }
purge_installation() { echo purged >> "$ROOT/calls"; }
CHOICE='' ANSWER=y
uninstall_stack >/dev/null
[[ $(cat "$ROOT/calls") == removed && $(cat "$ROOT/sentinel") == data-to-keep ]]
: > "$ROOT/calls"
CHOICE=2 ANSWER=n
uninstall_stack >/dev/null
[[ ! -s $ROOT/calls ]]
CHOICE=2 ANSWER=y
uninstall_stack >/dev/null
[[ $(cat "$ROOT/calls") == $'removed\npurged' ]]
grep -q '永久删除' "$ROOT/prompts"
echo 'PASS: uninstall defaults to retention; full deletion requires confirmation'
