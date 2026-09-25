#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./install.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ROOT=$tmp
mkdir -p "$ROOT/config" "$ROOT/state"
jq -n '[range(1;9) | {tag_name:("v"+tostring),draft:false,prerelease:(.%2==0),published_at:("2026-09-0"+tostring+"T00:00:00Z")}]' > "$tmp/releases"
recent=$(recent_releases < "$tmp/releases")
[[ $(jq length <<<"$recent") == 5 && $(jq -r '.[0].tag_name' <<<"$recent") == v8 && $(jq -r '.[4].tag_name' <<<"$recent") == v4 ]]
fetch_releases() { cat "$tmp/releases"; }
ask() { if [[ $1 == *'编号'* ]]; then echo 2; else echo 3; fi; }
docker() { if [[ $1 == image ]]; then echo image@sha256:fixture; fi; }
CHANNEL='' ACTION=install
choose_version >/dev/null
[[ $VERSION == v7 && $CHANNEL == stable ]]
# A failed or invalid download must never replace the installed manager.
get() { printf 'not a shell script\n' > "${@: -1}"; }
if (self_update) >/dev/null 2>&1; then echo 'Invalid script accepted'; exit 1; fi
# No snapshot means rollback must not stop services.
preflight() { :; }
load_state() { :; }
dc() { echo unexpected > "$ROOT/calls"; }
if (rollback_stack) >/dev/null 2>&1; then echo 'Rollback without backup accepted'; exit 1; fi
[[ ! -f $ROOT/calls ]]
# Manual rollback must touch only the controller service and retain current data.
mkdir -p "$ROOT/data/app"
printf current-data > "$ROOT/data/app/value"
printf '{"version":"v6","app":"app@sha256:old","channel":"beta"}' > "$ROOT/state/image-rollback.json"
DOMAIN=panel.example.com CADDY_IMAGE=caddy:test PG_IMAGE=postgres:18-alpine
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
echo 'PASS: recent list limited to five, exact selection, invalid manager rejected, rollback needs a snapshot'
