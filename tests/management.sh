#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./install.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ROOT=$tmp
mkdir -p "$ROOT/config" "$ROOT/state"
jq -n '[range(10;24) | {tag_name:("v"+tostring),draft:false,prerelease:(.%2==0),published_at:("2026-09-"+tostring+"T00:00:00Z")}]' > "$tmp/releases"
recent=$(recent_releases stable < "$tmp/releases")
[[ $(jq length <<<"$recent") == 5 && $(jq -r '.[0].tag_name' <<<"$recent") == v23 && $(jq -r '.[4].tag_name' <<<"$recent") == v15 ]]
[[ $(recent_releases beta < "$tmp/releases" | jq -r '.[0].tag_name') == v22 ]]
fetch_releases() { cat "$tmp/releases"; }
ask() { case "$1" in *'编号'*) echo 2;; *'通道'*) echo 1;; *) echo 3;; esac; }
docker() { if [[ $1 == image ]]; then echo image@sha256:fixture; fi; }
check_app_image() { return 0; }
CHANNEL='' ACTION=install
choose_version >/dev/null
[[ $VERSION == v21 && $CHANNEL == stable ]]
# A failed or invalid download must never replace the installed manager.
get() { return 1; }
if (self_update) >/dev/null 2>&1; then echo 'Invalid script accepted'; exit 1; fi
# Rollback chooses an official release even without any installation history.
preflight() { :; }
load_state() { VERSION=v99; }
confirm() { return 0; }
(
  finish_image_rollback() { jq -e '.version=="v21" and .channel=="stable"' "$ROOT/state/image-rollback.json" >/dev/null; }
  rollback_stack >/dev/null
)
rm "$ROOT/state/image-rollback.json"
# Manual rollback must touch only the controller service and retain current data.
mkdir -p "$ROOT/data/app"
printf current-data > "$ROOT/data/app/value"
printf '{"version":"v6","app":"app@sha256:old","channel":"beta"}' > "$ROOT/state/image-rollback.json"
DOMAIN=panel.example.com CADDY_IMAGE=caddy:test PG_IMAGE=postgres:18-alpine
# Invoked indirectly through run_step.
# shellcheck disable=SC2317,SC2329
dc() { printf '%s\n' "$*" >> "$ROOT/calls"; }
finish_image_rollback >/dev/null
[[ $(cat "$ROOT/calls") == 'up -d --no-deps --wait --wait-timeout 300 mmwx' ]]
[[ $(cat "$ROOT/data/app/value") == current-data && ! -f $ROOT/state/image-rollback.json ]]
[[ $(jq -r .version "$ROOT/state/state.json") == v6 ]]
# Failed old image must recover the original image without restoring data.
printf '{"version":"v5","app":"app@sha256:bad","channel":"stable"}' > "$ROOT/state/image-rollback.json"
load_state() { DOMAIN=panel.example.com; VERSION=v6; APP_IMAGE=app@sha256:old; CHANNEL=beta; }
dc() { [[ $APP_IMAGE != app@sha256:bad ]]; }
if (finish_image_rollback) >/dev/null 2>&1; then echo 'Failed rollback reported success'; exit 1; fi
[[ ! -f $ROOT/state/image-rollback.json && $(cat "$ROOT/data/app/value") == current-data ]]
echo 'PASS: five releases per channel; rollback chooses official versions without history and preserves data'
