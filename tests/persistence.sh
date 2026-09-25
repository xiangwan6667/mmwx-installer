#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./install.sh
tmp=$(mktemp -d); trap 'docker compose -p mmwx-persistence -f "$tmp/config/compose.yaml" down >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT
ROOT=$tmp
mkdir -p "$ROOT/config" "$ROOT/state"
DOMAIN=localhost APP_IMAGE=alpine:3.22 CADDY_IMAGE=alpine:3.22 PG_IMAGE=postgres:18-alpine
printf 'POSTGRES_PASSWORD=test-ci-only\n' > "$ROOT/config/postgres.env"
printf 'MMWX_DATABASE_PASSWORD=test-ci-only\n' > "$ROOT/config/app.env"
touch "$ROOT/config/caddy.env"
printf ':80 {}\n' > "$ROOT/config/Caddyfile"
render_compose > "$ROOT/original.yaml"
# Use lightweight stand-ins to verify the exact rendered volumes and time settings.
docker compose -f "$ROOT/original.yaml" config --format json | jq '
  .services.caddy.ports=[] |
  .services.caddy.command=["sleep","infinity"] | del(.services.caddy.depends_on) |
  .services.mmwx.command=["sleep","infinity"] | del(.services.mmwx.healthcheck,.services.mmwx.depends_on)
' > "$ROOT/config/compose.yaml"
compose() { docker compose -p mmwx-persistence -f "$ROOT/config/compose.yaml" "$@"; }
compose up -d --wait --wait-timeout 120
compose exec -T postgres psql -U mmwx -d mmwx -c 'CREATE TABLE persistence_test(value text); INSERT INTO persistence_test VALUES ('"'retained'"');'
compose exec -T mmwx sh -c 'echo retained > /app/data/probe'
compose exec -T caddy sh -c 'echo retained > /data/probe'
# Same operation as retaining data on uninstall, followed by service restoration.
compose down
compose up -d --wait --wait-timeout 120
[[ $(compose exec -T postgres psql -U mmwx -d mmwx -Atc 'SELECT value FROM persistence_test') == retained ]]
[[ $(compose exec -T mmwx cat /app/data/probe) == retained ]]
[[ $(compose exec -T caddy cat /data/probe) == retained ]]
for service in caddy mmwx postgres; do
  [[ $(compose exec -T "$service" date +%z) == +0800 ]]
done
[[ $(compose exec -T postgres psql -U mmwx -d mmwx -Atc 'SHOW timezone') == Asia/Shanghai ]]
echo 'PASS: database/app/certificate data survives removal and recreation; all three containers use UTC+8'
