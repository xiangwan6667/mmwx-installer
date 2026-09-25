#!/usr/bin/env bash
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."
source ./install.sh
tmp=$(mktemp -d ./test-update-XXXXXX); trap 'rm -rf "$tmp"' EXIT
ROOT=$tmp
backup=$ROOT/backups/test
mkdir -p "$backup" "$ROOT/data" "$ROOT/subscribes" "$ROOT/rule_templates"
printf old > "$ROOT/data/value"
printf old-compose > "$backup/compose.yaml"
printf '{}' > "$backup/state.json"
printf dump > "$backup/database.dump"
tar -czf "$backup/files.tar.gz" -C "$ROOT" data subscribes rule_templates
printf new > "$ROOT/data/value"
printf extra > "$ROOT/data/extra"
dc() { echo "$*" >> "$ROOT/calls"; }
write_update_progress restoring "$backup"
recover_update
[[ $(cat "$ROOT/data/value") == old && ! -f $ROOT/data/extra ]]
[[ $(cat "$ROOT/compose.yaml") == old-compose && ! -f $ROOT/update.json ]]
grep -qx 'exec -T postgres pg_restore -U mmwx -d mmwx --exit-on-error' "$ROOT/calls"
# A second interruption during recovery must be safe to retry.
write_update_progress restoring "$backup"
recover_update
[[ $(cat "$ROOT/data/value") == old ]]
# Interruption during backup never attempts to use incomplete backup data.
rm "$backup/database.dump" "$backup/files.tar.gz"
write_update_progress backing-up "$backup"
recover_update
[[ ! -f $ROOT/update.json ]]
echo 'PASS: interrupted update recovery is repeatable; incomplete backup is not restored'
