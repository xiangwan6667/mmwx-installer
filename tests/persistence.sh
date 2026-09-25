#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./install.sh
tmp=$(mktemp -d); trap 'docker compose -p mmwx-persistence -f "$tmp/config/compose.yaml" down >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT
ROOT=$tmp
mkdir -p "$ROOT/config" "$ROOT/state"
DOMAIN=panel.example.com APP_IMAGE=alpine:3.22 PG_IMAGE=postgres:18-alpine
# Pin the fixture before its first start so an image/tag change cannot mask a
# missing --force-recreate in the reinstall path.
docker pull "$APP_IMAGE"
docker pull "$PG_IMAGE"
APP_IMAGE=$(docker image inspect "$APP_IMAGE" --format '{{index .RepoDigests 0}}')
PG_IMAGE=$(docker image inspect "$PG_IMAGE" --format '{{index .RepoDigests 0}}')
CADDY_IMAGE=$APP_IMAGE
printf 'POSTGRES_PASSWORD=test-ci-only\n' > "$ROOT/config/postgres.env"
printf 'MMWX_DATABASE_PASSWORD=test-ci-only\n' > "$ROOT/config/app.env"
printf 'CF_API_TOKEN=test-ci-only-cloudflare-token\n' > "$ROOT/config/caddy.env"
printf 'test-ci-only-cloudflare-token\n' > "$ROOT/config/cloudflare.token"
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
compose exec -T mmwx sh -c 'echo retained | tee /app/data/probe /app/subscribes/probe /app/rule_templates/probe >/dev/null'
compose exec -T caddy sh -c 'echo retained | tee /data/probe /config/probe >/dev/null'
assert_persisted_data() {
  local dir
  [[ $(compose exec -T postgres psql -U mmwx -d mmwx -Atc 'SELECT value FROM persistence_test') == retained ]]
  for dir in /app/data /app/subscribes /app/rule_templates; do
    [[ $(compose exec -T mmwx cat "$dir/probe") == retained ]]
  done
  for dir in /data /config; do
    [[ $(compose exec -T caddy cat "$dir/probe") == retained ]]
  done
}
# Same operation as retaining data on uninstall, followed by service restoration.
compose down
compose up -d --wait --wait-timeout 120
assert_persisted_data
for service in caddy mmwx postgres; do
  [[ $(compose exec -T "$service" date +%z) == +0800 ]]
done
[[ $(compose exec -T postgres psql -U mmwx -d mmwx -Atc 'SHOW timezone') == Asia/Shanghai ]]

# Exercise the real controller reinstall with running dependencies and unchanged
# image refs. Only host networking/HTTPS checks are replaced; image pulls,
# Compose and the PostgreSQL instance remain real.
jq -n --arg app "$APP_IMAGE" --arg caddy "$CADDY_IMAGE" --arg pg "$PG_IMAGE" \
  '{domain:"panel.example.com",channel:"stable",version:"v1.0.0",app:$app,caddy:$caddy,pg:$pg}' > "$ROOT/state/state.json"
cp "$ROOT/state/state.json" "$ROOT/state/reinstall.json"
sha256sum "$ROOT"/config/* "$ROOT/state/state.json" > "$ROOT/before-reinstall.sha256"
declare -A container_before image_before started_before
for service in caddy mmwx postgres; do
  container_before[$service]=$(compose ps -q "$service")
  [[ -n ${container_before[$service]} ]]
  image_before[$service]=$(docker inspect --format '{{.Image}}' "${container_before[$service]}")
  started_before[$service]=$(docker inspect --format '{{.State.StartedAt}}' "${container_before[$service]}")
done
network_is_ready() { return 0; }
verify_https() { :; }
dc() { compose "$@"; }
finish_reinstall
for service in caddy mmwx postgres; do
  container_after=$(compose ps -q "$service")
  [[ -n $container_after ]]
  if [[ $service == mmwx ]]; then
    [[ $container_after != "${container_before[$service]}" ]]
  else
    [[ $container_after == "${container_before[$service]}" ]]
    [[ $(docker inspect --format '{{.State.StartedAt}}' "$container_after") == "${started_before[$service]}" ]]
  fi
  [[ $(docker inspect --format '{{.Image}}' "$container_after") == "${image_before[$service]}" ]]
done
assert_persisted_data
sha256sum --check --status "$ROOT/before-reinstall.sha256"
[[ ! -e $ROOT/state/reinstall.json ]]
echo 'PASS: database/app/certificate data survives removal and recreation; all three containers use UTC+8'
echo 'PASS: reinstall recreates only the controller, preserving running dependencies, images, data, credentials and configuration'
