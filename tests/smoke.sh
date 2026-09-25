#!/usr/bin/env bash
# Dedicated disposable test host only. Publishes Caddy solely on loopback.
set -euo pipefail
cd "$(dirname "$0")/.."
source ./install.sh
ROOT=/root/mmwx-installer-smoke
[[ ! -e $ROOT ]] || die 'Smoke directory already exists; inspect it before retrying.'
mkdir -m 700 "$ROOT"
cleanup() { docker compose -p mmwx-smoke -f "$ROOT/compose.json" down 2>/dev/null || true; }
trap cleanup EXIT
DOMAIN=localhost
CHANNEL=stable
choose_version
CADDY_IMAGE=mmwx-installer-caddy:2.11.4-cf0.2.4
PG_IMAGE=postgres:18-alpine
password=$(openssl rand -hex 24)
printf 'MMWX_DATABASE_PASSWORD=%s\n' "$password" > "$ROOT/app.env"
printf 'POSTGRES_PASSWORD=%s\n' "$password" > "$ROOT/postgres.env"
touch "$ROOT/caddy.env"
render_compose > "$ROOT/compose.yaml"
printf ':80 {\n reverse_proxy mmwx:12889\n}\n' > "$ROOT/Caddyfile"
docker compose -p mmwx-smoke -f "$ROOT/compose.yaml" config --format json | jq '.services.caddy.ports=[{target:80,published:"18080",host_ip:"127.0.0.1",protocol:"tcp"}] | (.services[].restart)="no"' > "$ROOT/compose.json"
docker compose -p mmwx-smoke -f "$ROOT/compose.json" up -d --wait --wait-timeout 300
curl -fsS http://127.0.0.1:18080/ -o /dev/null
echo 'PASS: official stable image, PostgreSQL and Caddy bridge proxy'
CHANNEL=beta
choose_version
jq --arg image "$APP_IMAGE" '.services.mmwx.image=$image' "$ROOT/compose.json" > "$ROOT/next.json"
mv "$ROOT/next.json" "$ROOT/compose.json"
docker compose -p mmwx-smoke -f "$ROOT/compose.json" up -d --wait --wait-timeout 300
curl -fsS http://127.0.0.1:18080/ -o /dev/null
echo 'PASS: official Beta image with existing PostgreSQL data and Caddy bridge proxy'
docker compose -p mmwx-smoke -f "$ROOT/compose.json" ps
