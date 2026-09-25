#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./install.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ROOT=$tmp
mkdir -p "$ROOT/config" "$ROOT/state" "$ROOT/data/postgres" "$ROOT/data/app" "$ROOT/certs/data" "$ROOT/backups"
DOMAIN=panel.example.com CHANNEL=stable VERSION=v1
APP_IMAGE=app@sha256:current PG_IMAGE=postgres@sha256:current CADDY_IMAGE=mmwx-installer-caddy:2.11.4-cf0.2.4
save_state; checkpoint 7
# Original installation checkpoints may be stale after subsequent updates.
jq '.version="v0" | .app="app@sha256:old"' "$ROOT/state/progress.json" > "$ROOT/state/older.json"
mv "$ROOT/state/older.json" "$ROOT/state/progress.json"
cp "$ROOT/state/state.json" "$tmp/original-state"
cp "$ROOT/state/progress.json" "$tmp/original-progress"
for name in compose.yaml Caddyfile postgres.env app.env caddy.env cloudflare.token; do printf 'original-%s\n' "$name" > "$ROOT/config/$name"; done
printf database > "$ROOT/data/postgres/value"
printf application > "$ROOT/data/app/value"
printf certificate > "$ROOT/certs/data/value"
printf backup > "$ROOT/backups/value"
find "$ROOT/config" "$ROOT/data" "$ROOT/certs" "$ROOT/backups" -type f -exec sha256sum {} + | sort > "$tmp/before"
preflight() { :; }
install_command() { :; }
network_is_ready() { return 0; }
install_units() { echo units >> "$tmp/calls"; }
apply_firewall() { echo firewall >> "$tmp/calls"; }
verify_https() { [[ $FAIL != https ]]; }
confirm() { printf '%s\n' "$1" >> "$tmp/prompts"; [[ $ANSWER == y ]]; }
# Invoked indirectly through run_step.
# shellcheck disable=SC2317,SC2329
docker() {
  [[ $1 == pull && $2 == app@sha256:current ]] || return 90
  printf 'pull %s\n' "$2" >> "$tmp/calls"
  [[ $FAIL != pull ]]
}
build_caddy() { echo build-caddy >> "$tmp/calls"; [[ $FAIL != caddy ]]; }
dc() {
  printf 'compose %s\n' "$*" >> "$tmp/calls"
  case "$1" in
    config)
      jq -n --arg app "$APP_IMAGE" --arg caddy "$CADDY_IMAGE" --arg pg "$PG_IMAGE" \
        '{services:{mmwx:{image:$app},caddy:{image:$caddy},postgres:{image:$pg}}}' ;;
    up) [[ $FAIL != recreate ]];;
    *) return 90;;
  esac
}
ANSWER=n FAIL=''
: > "$tmp/calls"
reinstall_stack > "$tmp/output"
[[ ! -s $tmp/calls && ! -f $ROOT/state/reinstall.json ]]

ANSWER=y
reinstall_stack > "$tmp/output"
[[ ! -f $ROOT/state/reinstall.json ]]
grep -qx 'pull app@sha256:current' "$tmp/calls"
grep -qx 'compose up -d --no-deps --force-recreate --wait --wait-timeout 300 mmwx' "$tmp/calls"
if grep -Eq 'build-caddy|pull postgres|^units$|^firewall$' "$tmp/calls"; then echo 'Reinstall touched another service'; exit 1; fi
grep -q '数据\|保留' "$tmp/prompts"
find "$ROOT/config" "$ROOT/data" "$ROOT/certs" "$ROOT/backups" -type f -exec sha256sum {} + | sort > "$tmp/after"
cmp "$tmp/before" "$tmp/after"

# Failed download must not recreate containers; task remains resumable.
: > "$tmp/calls"
FAIL=pull
if (reinstall_stack) > "$tmp/output" 2>&1; then echo 'Download failure accepted'; exit 1; fi
[[ -f $ROOT/state/reinstall.json ]]
if grep -q 'compose up' "$tmp/calls"; then echo 'Recreated before images ready'; exit 1; fi

# Continue through the actual menu 5 dispatcher without repeating consent.
: > "$tmp/calls"; : > "$tmp/prompts"
FAIL=''
resume_task > "$tmp/output"
[[ ! -f $ROOT/state/reinstall.json && ! -s $tmp/prompts ]]
grep -qx 'compose up -d --no-deps --force-recreate --wait --wait-timeout 300 mmwx' "$tmp/calls"

for FAIL in recreate https; do
  if (reinstall_stack) > "$tmp/output" 2>&1; then echo "Failure $FAIL accepted"; exit 1; fi
  [[ -f $ROOT/state/reinstall.json ]]
  FAIL='' resume_task > "$tmp/output"
  [[ ! -f $ROOT/state/reinstall.json ]]
done

# Pending updates/rollbacks must be recovered before a reinstall can begin.
for conflict in update.json image-rollback.json; do
  printf '{}' > "$ROOT/state/$conflict"
  : > "$tmp/calls"
  if (reinstall_stack) > "$tmp/output" 2>&1; then echo 'Conflicting task accepted'; exit 1; fi
  [[ ! -s $tmp/calls && ! -f $ROOT/state/reinstall.json ]]
  rm "$ROOT/state/$conflict"
done

# Pending reinstall blocks conflicting lifecycle actions, including older tasks.
cp "$ROOT/state/state.json" "$ROOT/state/reinstall.json"
for operation in install_stack update_stack rollback_stack uninstall_stack; do
  : > "$tmp/calls"
  if ("$operation") > "$tmp/output" 2>&1; then echo "Pending reinstall allowed $operation"; exit 1; fi
  [[ ! -s $tmp/calls ]]
done
rm "$ROOT/state/reinstall.json"

cmp "$tmp/original-state" "$ROOT/state/state.json"
cmp "$tmp/original-progress" "$ROOT/state/progress.json"
# A legacy migration would restart every service; reinstall must not trigger it.
printf '{}' > "$ROOT/state.json"
: > "$tmp/migration"
if (
  ensure_layout() { echo migration >> "$tmp/migration"; }
  reinstall_stack
) > "$tmp/output" 2>&1; then echo 'Legacy layout reinstalled without migration'; exit 1; fi
[[ ! -s $tmp/migration ]] || { echo 'Reinstall triggered full-stack migration'; exit 1; }
rm "$ROOT/state.json"
find "$ROOT/config" "$ROOT/data" "$ROOT/certs" "$ROOT/backups" -type f -exec sha256sum {} + | sort > "$tmp/after"
cmp "$tmp/before" "$tmp/after"
echo 'PASS: reinstall touches only the app, preserves data/config, requires consent and resumes failures'
