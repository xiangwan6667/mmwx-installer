#!/usr/bin/env bash
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."
source ./install.sh
tmp=$(mktemp -d ./test-update-XXXXXX); trap 'rm -rf "$tmp"' EXIT
ROOT=$tmp
mkdir -p "$ROOT/config" "$ROOT/state"
backup=$ROOT/backups/test
mkdir -p "$backup" "$ROOT/data/app" "$ROOT/data/subscribes" "$ROOT/data/rule_templates"
printf old > "$ROOT/data/app/value"
printf old-compose > "$backup/compose.yaml"
printf '{"domain":"panel.example.com","channel":"stable","version":"v1","app":"app:v1","caddy":"caddy:test","pg":"postgres:18-alpine"}' > "$backup/state.json"
printf dump > "$backup/database.dump"
tar -czf "$backup/files.tar.gz" -C "$ROOT/data" app subscribes rule_templates
printf new > "$ROOT/data/app/value"
printf extra > "$ROOT/data/app/extra"
dc() { echo "$*" >> "$ROOT/calls"; }
write_update_progress restoring "$backup"
recover_update
[[ $(cat "$ROOT/data/app/value") == old && ! -f $ROOT/data/app/extra ]]
grep -q 'image: app:v1' "$ROOT/config/compose.yaml"
[[ ! -f $ROOT/state/update.json ]]
grep -qx 'stop mmwx' "$ROOT/calls"
grep -qx 'up -d --no-deps --wait --wait-timeout 300 mmwx' "$ROOT/calls"
if grep -q caddy "$ROOT/calls"; then echo 'Update recovery disturbed the gateway'; exit 1; fi
grep -qx 'exec -T postgres pg_restore -U mmwx -d mmwx --exit-on-error' "$ROOT/calls"
# A second interruption during recovery must be safe to retry.
write_update_progress restoring "$backup"
recover_update
[[ $(cat "$ROOT/data/app/value") == old ]]
# Interruption during backup never attempts to use incomplete backup data.
rm "$backup/database.dump" "$backup/files.tar.gz"
write_update_progress backing-up "$backup"
recover_update
[[ ! -f $ROOT/state/update.json ]]
# Old journals stopped Caddy; recover that existing container without recreate.
write_update_progress backing-up "$backup"
jq 'del(.service_scope)' "$ROOT/state/update.json" > "$ROOT/state/legacy.json"
mv "$ROOT/state/legacy.json" "$ROOT/state/update.json"
: > "$ROOT/calls"
recover_update
grep -qx 'up -d --no-deps --no-recreate --wait --wait-timeout 120 postgres' "$ROOT/calls"
grep -qx 'up -d --no-deps --no-recreate --wait --wait-timeout 300 caddy' "$ROOT/calls"
if grep -Eq 'stop .*caddy|restart .*caddy|force-recreate' "$ROOT/calls"; then echo 'Legacy recovery restarted the gateway'; exit 1; fi
[[ ! -f $ROOT/state/update.json ]]
echo 'PASS: interrupted update recovery is repeatable; incomplete backup is not restored'
