#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./install.sh
tmp=$(mktemp -d ./test-update-isolation-XXXXXX); trap 'rm -rf "$tmp"' EXIT
ROOT=$tmp
trap 'printf "Isolation test failed at line %s\n" "$LINENO"; cat "$ROOT/output" "$ROOT/calls" 2>/dev/null' ERR
mkdir -p "$ROOT/config" "$ROOT/state" "$ROOT/data/app" "$ROOT/data/subscribes" "$ROOT/data/rule_templates"
DOMAIN=panel.example.com CHANNEL=stable VERSION=v1 APP_IMAGE=app:v1 CADDY_IMAGE=caddy:test PG_IMAGE=postgres:test
save_state; checkpoint 7
render_compose > "$ROOT/config/compose.yaml"
printf 'retained' > "$ROOT/data/app/value"
preflight() { :; }
install_command() { :; }
configure_timezone() { :; }
choose_version() { VERSION=v2; APP_IMAGE=app:v2; }
sync_cf() { echo 'unexpected-sync' >> "$ROOT/calls"; return 1; }
dc() {
  printf '%s\n' "$*" >> "$ROOT/calls"
  if [[ $1 == up && ${*: -1} == mmwx && $APP_IMAGE == app:v2 && ${FAIL:-} == deploy ]]; then return 1; fi
  if [[ $1 == exec && $4 == pg_dump ]]; then
    [[ ${FAIL:-} != backup ]] || return 1
    printf database-dump
  fi
}
for FAIL in '' backup deploy; do
  VERSION=v1 APP_IMAGE=app:v1; save_state
  : > "$ROOT/calls"
  if [[ -z $FAIL ]]; then
    update_stack > "$ROOT/output"
    [[ $(jq -r .version "$ROOT/state/state.json") == v2 ]]
  else
    if (update_stack) > "$ROOT/output" 2>&1; then echo "Accepted failed $FAIL"; exit 1; fi
    [[ $(jq -r .version "$ROOT/state/state.json") == v1 ]]
  fi
  if grep -Eq 'caddy|unexpected-sync|^up -d --wait' "$ROOT/calls"; then echo 'App update touched gateway/full stack'; exit 1; fi
  grep -qx 'stop mmwx' "$ROOT/calls"
  [[ ! -f $ROOT/state/update.json && $(cat "$ROOT/data/app/value") == retained ]]
done
# Legacy layout migration is explicit; a main-container action cannot trigger it.
printf '{}' > "$ROOT/state.json"
: > "$ROOT/calls"
ensure_layout() { echo migration >> "$ROOT/calls"; }
for operation in update_stack rollback_stack; do
  if ("$operation") > "$ROOT/output" 2>&1; then echo 'Legacy layout was changed implicitly'; exit 1; fi
done
[[ ! -s $ROOT/calls ]]
echo 'PASS: update success, failed backup and failed deployment operate only on the controller'
