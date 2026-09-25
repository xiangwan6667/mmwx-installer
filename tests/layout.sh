#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./install.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ROOT=$tmp
mkdir "$ROOT/data" "$ROOT/postgres-data" "$ROOT/caddy-data"
printf application > "$ROOT/data/probe"
printf database > "$ROOT/postgres-data/probe"
printf certificate > "$ROOT/caddy-data/probe"
printf password > "$ROOT/postgres.env"
printf '{"stage":1}' > "$ROOT/progress.json"
install_command() { :; }
systemctl() { :; }
ensure_layout
[[ $(cat "$ROOT/data/app/probe") == application ]]
[[ $(cat "$ROOT/data/postgres/probe") == database ]]
[[ $(cat "$ROOT/certs/data/probe") == certificate ]]
[[ $(cat "$ROOT/config/postgres.env") == password ]]
[[ -f $ROOT/state/progress.json && ! -f $ROOT/progress.json ]]
ensure_layout
[[ $(cat "$ROOT/data/app/probe") == application ]]
echo 'PASS: legacy data/config/certificates migrate without replacement; repeated migration is harmless'
