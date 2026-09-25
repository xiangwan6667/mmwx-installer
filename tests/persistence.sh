#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./install.sh
tmp=$(mktemp -d)
failed_image="mmwx-persistence-failed:$$"
cleanup() {
  docker compose -p mmwx-persistence -f "$tmp/config/compose.yaml" down >/dev/null 2>&1 || true
  docker image rm "$failed_image" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT
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
# The production renderer is sourced above; a fixture override is defined later.
# shellcheck disable=SC2218
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

# Exercise successful updates and failed-candidate recovery with real Compose,
# pg_dump/pg_restore and bind mounts. The fixture replaces the application and
# host/network setup; all service lifecycle operations remain real.
docker pull alpine:3.21
updated_image=$(docker image inspect alpine:3.21 --format '{{index .RepoDigests 0}}')
mkdir -p "$ROOT/failed-image"
printf 'FROM %s\nCOPY fail.sh /fail.sh\nENTRYPOINT ["sh", "/fail.sh"]\n' "$PG_IMAGE" > "$ROOT/failed-image/Dockerfile"
cat > "$ROOT/failed-image/fail.sh" <<'EOF'
#!/bin/sh
set -eu
for directory in /app/data /app/subscribes /app/rule_templates; do
  printf 'failed\n' > "$directory/probe"
done
PGPASSWORD=test-ci-only psql -h postgres -U mmwx -d mmwx -v ON_ERROR_STOP=1 -Atc \
  "UPDATE persistence_test SET value = 'failed' RETURNING value" > /app/data/failed-database-value
touch /app/data/failed-update-ran
exit 1
EOF
docker build --pull=false -t "$failed_image" "$ROOT/failed-image"

# Pending dependency configuration changes make a missing --no-deps or
# --no-recreate observable as container replacement, even with pinned images.
jq '
  .services.caddy.environment.PERSISTENCE_UPDATE_SENTINEL="pending" |
  .services.postgres.environment.PERSISTENCE_UPDATE_SENTINEL="pending" |
  .services.mmwx.depends_on={postgres:{condition:"service_healthy"}} |
  .services.mmwx.restart="no" |
  .services.mmwx.command=["sh","-c","touch /tmp/fixture-ready; exec sleep infinity"] |
  .services.mmwx.healthcheck={test:["CMD","test","-f","/tmp/fixture-ready"],interval:"1s",timeout:"1s",retries:3}
' "$ROOT/config/compose.yaml" > "$ROOT/update-fixture.json"
cp "$ROOT/update-fixture.json" "$ROOT/config/compose.yaml"
render_compose() { jq --arg app "$APP_IMAGE" '.services.mmwx.image=$app' "$ROOT/update-fixture.json"; }
preflight() { :; }
install_command() { :; }
configure_timezone() { :; }
choose_version() { VERSION=$next_version; APP_IMAGE=$next_image; }
sync_cf() { die 'Controller update must not synchronize or reload the gateway.'; }

for service in caddy postgres; do
  container_before[$service]=$(compose ps -q "$service")
  started_before[$service]=$(docker inspect --format '{{.State.StartedAt}}' "${container_before[$service]}")
done
assert_dependencies_unchanged() {
  local service container_after
  for service in caddy postgres; do
    container_after=$(compose ps -q "$service")
    [[ $container_after == "${container_before[$service]}" ]]
    [[ $(docker inspect --format '{{.State.StartedAt}}' "$container_after") == "${started_before[$service]}" ]]
    [[ $(docker inspect --format '{{.State.Running}}' "$container_after") == true ]]
  done
}
backup_for_version() {
  local directory
  for directory in "$ROOT/backups/"*; do
    if [[ $(jq -r .version "$directory/state.json") == "$1" ]]; then
      printf '%s\n' "$directory"
      return 0
    fi
  done
  return 1
}

controller_before=$(compose ps -q mmwx)
next_version=v1.0.1 next_image=$updated_image
update_stack
[[ $(compose ps -q mmwx) != "$controller_before" ]]
[[ $(docker inspect --format '{{.Image}}' "$(compose ps -q mmwx)") == "$(docker image inspect --format '{{.Id}}' "$updated_image")" ]]
[[ $(jq -r .version "$ROOT/state/state.json") == v1.0.1 ]]
[[ $(jq -r .app "$ROOT/state/state.json") == "$updated_image" ]]
[[ ! -e $ROOT/state/update.json ]]
assert_dependencies_unchanged
assert_persisted_data
success_backup=$(backup_for_version v1.0.0)
[[ -s $success_backup/database.dump ]]
[[ $(tar -xOzf "$success_backup/files.tar.gz" app/probe) == retained ]]
echo 'PASS: successful controller update preserves running gateway/database containers and backs up data'

next_version=v1.0.2 next_image=$failed_image
set +e
(set -e; update_stack) > "$ROOT/failed-update.log" 2>&1
update_status=$?
set -e
cat "$ROOT/failed-update.log"
[[ $update_status -ne 0 ]]
[[ $(jq -r .version "$ROOT/state/state.json") == v1.0.1 ]]
[[ $(jq -r .app "$ROOT/state/state.json") == "$updated_image" ]]
[[ $(docker inspect --format '{{.Image}}' "$(compose ps -q mmwx)") == "$(docker image inspect --format '{{.Id}}' "$updated_image")" ]]
[[ ! -e $ROOT/state/update.json ]]
assert_dependencies_unchanged
assert_persisted_data
failed_backup=$(backup_for_version v1.0.1)
[[ -f $failed_backup/failed-app/failed-update-ran ]]
[[ $(head -n 1 "$failed_backup/failed-app/failed-database-value") == failed ]]
[[ $(cat "$failed_backup/failed-app/probe") == failed ]]
[[ ! -e $ROOT/data/app/failed-update-ran ]]
echo 'PASS: failed controller update restores its previous image, application files and database without restarting dependencies'
