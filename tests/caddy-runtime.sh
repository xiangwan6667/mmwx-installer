#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./install.sh

# Run as root on a disposable Linux Docker runner. Cloudflare calls are mocked;
# configuration replacement, Caddy TLS, Compose and PostgreSQL are real.
[[ $EUID == 0 ]] || { echo 'Run the Caddy integration test as root'; exit 1; }
command -v docker >/dev/null
tmp=$(mktemp -d)
ROOT=$tmp
project=mmwx-installer
compose() { docker compose -p "$project" -f "$ROOT/config/compose.yaml" "$@"; }
cleanup() {
  local code=$?
  if [[ $code != 0 && -f $ROOT/config/compose.yaml ]]; then
    compose ps >&2 || true
    for output in "$ROOT/rotation-output" "$ROOT/rollback-output" "$ROOT/reload-output" "$ROOT/domain-success-output" "$ROOT/domain-rollback-output"; do
      if [[ -f $output ]]; then tail -n 30 "$output" | caddy_redact >&2 || true; fi
    done
  fi
  compose down --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$tmp"
  exit "$code"
}
trap cleanup EXIT
trap 'printf "Caddy integration failed at line %s\n" "$LINENO" >&2' ERR
mkdir -p "$ROOT/config" "$ROOT/state" "$ROOT/certs/data" "$ROOT/certs/config" "$ROOT/backups"
DOMAIN=panel.example.com CHANNEL=stable VERSION=v1.0.0
APP_IMAGE=alpine:3.22 PG_IMAGE=postgres:18-alpine CADDY_IMAGE=caddy:2.11.4-alpine
for image_ref in "$APP_IMAGE" "$PG_IMAGE" "$CADDY_IMAGE"; do docker pull "$image_ref"; done
APP_IMAGE=$(docker image inspect "$APP_IMAGE" --format '{{index .RepoDigests 0}}')
PG_IMAGE=$(docker image inspect "$PG_IMAGE" --format '{{index .RepoDigests 0}}')
CADDY_IMAGE=$(docker image inspect "$CADDY_IMAGE" --format '{{index .RepoDigests 0}}')
printf 'POSTGRES_PASSWORD=test-ci-only\n' > "$ROOT/config/postgres.env"
printf 'MMWX_DATABASE_PASSWORD=test-ci-only\n' > "$ROOT/config/app.env"
printf 'old-ci-token-00000000000000000000\n' > "$ROOT/config/cloudflare.token"
printf 'CF_API_TOKEN=old-ci-token-00000000000000000000\nEXTRA_SETTING=preserve-me\n' > "$ROOT/config/caddy.env"
printf 'new-ci-token-11111111111111111111\n' > "$ROOT/input.token"
cat "$ROOT/config/cloudflare.token" "$ROOT/input.token" > "$ROOT/forbidden.tokens"
chmod 600 "$ROOT/config/cloudflare.token" "$ROOT/config/caddy.env" "$ROOT/input.token"
cat > "$ROOT/config/Caddyfile" <<EOF
{
  auto_https disable_redirects
}
$DOMAIN {
  tls internal
  respond "retained-gateway" 200
}
EOF
render_compose > "$ROOT/original.yaml"
# Compose config discards env_file entries even with --no-env-resolution on
# some versions. Restore the known paths so every recreation reads live files.
docker compose -f "$ROOT/original.yaml" config --no-env-resolution --format json | jq --arg root "$ROOT" '
  .services.caddy.ports=[{target:443,published:"443",host_ip:"127.0.0.1",protocol:"tcp"}] |
  .services.caddy.depends_on.mmwx.condition="service_started" |
  del(.services.caddy.environment.CF_API_TOKEN,
      .services.mmwx.environment.MMWX_DATABASE_PASSWORD,
      .services.postgres.environment.POSTGRES_PASSWORD) |
  .services.caddy.env_file=[$root+"/config/caddy.env"] |
  .services.mmwx.env_file=[$root+"/config/app.env"] |
  .services.postgres.env_file=[$root+"/config/postgres.env"] |
  .services.mmwx.command=["sleep","infinity"] | del(.services.mmwx.healthcheck)
' > "$ROOT/config/compose.yaml"
jq -e --arg root "$ROOT" '.services.caddy.env_file==[$root+"/config/caddy.env"] and
  .services.mmwx.env_file==[$root+"/config/app.env"] and
  .services.postgres.env_file==[$root+"/config/postgres.env"] and
  .services.caddy.environment.CF_API_TOKEN==null' "$ROOT/config/compose.yaml" >/dev/null
save_state
checkpoint 7
compose up -d --wait --wait-timeout 120
compose exec -T postgres psql -U mmwx -d mmwx -c "CREATE TABLE caddy_rotation_test(value text); INSERT INTO caddy_rotation_test VALUES ('retained');"
compose exec -T mmwx sh -c 'echo retained | tee /app/data/probe /app/subscribes/probe /app/rule_templates/probe >/dev/null'
compose exec -T caddy sh -c 'echo retained | tee /data/probe /config/probe >/dev/null'

# Trust only the fixture CA. Production readiness still uses the system roots.
export SSL_CERT_FILE="$ROOT/certs/data/caddy/pki/authorities/local/root.crt"
export CURL_CA_BUNDLE="$SSL_CERT_FILE"
origin_get() {
  curl --silent --show-error --fail --noproxy '*' --connect-timeout 2 --max-time 5 \
    --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/"
}
ready=0
for ((attempt=0; attempt<30; attempt++)); do
  if [[ -f $SSL_CERT_FILE ]] && [[ $(origin_get 2>/dev/null) == retained-gateway ]]; then ready=1; break; fi
  sleep 1
done
[[ $ready == 1 ]] || { echo 'Fixture TLS did not become ready'; exit 1; }

# A dependency has a pending Compose change. Omitting --no-deps would apply it
# and recreate the controller/database, which this test must detect.
jq '.services.mmwx.environment.UNAPPLIED_FIXTURE_CHANGE="yes" |
    .services.postgres.environment.UNAPPLIED_FIXTURE_CHANGE="yes"' \
  "$ROOT/config/compose.yaml" > "$ROOT/config/compose.next"
mv "$ROOT/config/compose.next" "$ROOT/config/compose.yaml"
sha256sum "$ROOT/config/compose.yaml" "$ROOT/config/Caddyfile" "$ROOT/config/app.env" \
  "$ROOT/config/postgres.env" "$ROOT/state/state.json" "$ROOT/state/progress.json" > "$ROOT/unchanged.sha256"
find "$ROOT/certs/data" -type f \( -name '*.crt' -o -name '*.key' \) -exec sha256sum {} + | sort > "$ROOT/certificates.sha256"
[[ -s $ROOT/certificates.sha256 ]]
declare -A before_id before_started
for service in caddy mmwx postgres; do
  before_id[$service]=$(compose ps -q "$service")
  before_started[$service]=$(docker inspect --format '{{.State.StartedAt}}' "${before_id[$service]}")
done
assert_retained() {
  local service dir id
  for service in mmwx postgres; do
    id=$(compose ps -q "$service")
    [[ $id == "${before_id[$service]}" ]]
    [[ $(docker inspect --format '{{.State.StartedAt}}' "$id") == "${before_started[$service]}" ]]
  done
  [[ $(compose exec -T postgres psql -U mmwx -d mmwx -Atc 'SELECT value FROM caddy_rotation_test') == retained ]]
  for dir in /app/data /app/subscribes /app/rule_templates; do
    [[ $(compose exec -T mmwx cat "$dir/probe") == retained ]]
  done
  for dir in /data /config; do [[ $(compose exec -T caddy cat "$dir/probe") == retained ]]; done
  sha256sum --check --status "$ROOT/unchanged.sha256"
  sha256sum --check --status "$ROOT/certificates.sha256"
}

dc() { compose "$@"; }
confirm() { return 0; }
# The unit suite exercises zone matching and all TXT create/delete failures.
# These are the only external-account boundaries replaced in this fixture.
caddy_token_probe() { return 0; }
caddy_token_cleanup() { return 0; }
TOKEN_FILE=$ROOT/input.token
replace_caddy_token > "$ROOT/rotation-output" 2>&1
[[ $(compose ps -q caddy) != "${before_id[caddy]}" ]]
[[ $(compose exec -T caddy printenv CF_API_TOKEN) == "$(cat "$TOKEN_FILE")" ]]
cmp "$TOKEN_FILE" "$ROOT/config/cloudflare.token"
grep -qx 'EXTRA_SETTING=preserve-me' "$ROOT/config/caddy.env"
[[ $(origin_get) == retained-gateway ]]
[[ ! -d $ROOT/state/caddy-token-change ]]
assert_retained
if grep -F -f "$ROOT/forbidden.tokens" "$ROOT/rotation-output" >/dev/null ||
   grep -r -F -f "$ROOT/forbidden.tokens" "$ROOT/state/logs" >/dev/null; then
  echo 'Rotation output exposed the Token'; exit 1
fi

# Fail the candidate readiness check once, then verify the real recovery path
# restores both files and the running Caddy environment. TLS is checked again
# by the original readiness function when the old container is restored.
cp "$ROOT/config/cloudflare.token" "$ROOT/retained.token"
cp "$ROOT/config/caddy.env" "$ROOT/retained.env"
printf 'failed-ci-token-22222222222222222\n' > "$TOKEN_FILE"
cat "$TOKEN_FILE" >> "$ROOT/forbidden.tokens"
eval "$(declare -f caddy_ready | sed '1s/caddy_ready/caddy_ready_runtime/')"
caddy_ready() {
  if [[ -f $ROOT/fail-ready-once ]]; then
    rm "$ROOT/fail-ready-once"
    return 1
  fi
  caddy_ready_runtime
}
touch "$ROOT/fail-ready-once"
if (replace_caddy_token) > "$ROOT/rollback-output" 2>&1; then
  echo 'Failed candidate was accepted'; exit 1
fi
cmp "$ROOT/retained.token" "$ROOT/config/cloudflare.token"
cmp "$ROOT/retained.env" "$ROOT/config/caddy.env"
[[ $(compose exec -T caddy printenv CF_API_TOKEN) == "$(cat "$ROOT/retained.token")" ]]
[[ $(origin_get) == retained-gateway ]]
[[ ! -d $ROOT/state/caddy-token-change ]]
assert_retained
if grep -F -f "$ROOT/forbidden.tokens" "$ROOT/rollback-output" >/dev/null ||
   grep -r -F -f "$ROOT/forbidden.tokens" "$ROOT/state/logs" >/dev/null; then
  echo 'Recovery output exposed a Token'; exit 1
fi

# The real running gateway must keep serving its previous config when reload
# validation fails. Rewrite in place to respect the production file bind mount.
caddy_id=$(compose ps -q caddy)
caddy_started=$(docker inspect --format '{{.State.StartedAt}}' "$caddy_id")
cp "$ROOT/config/Caddyfile" "$ROOT/valid-Caddyfile"
printf 'invalid_directive {\n' > "$ROOT/config/Caddyfile"
if (caddy_action reload) > "$ROOT/reload-output" 2>&1; then
  echo 'Invalid Caddy configuration reloaded'; exit 1
fi
[[ $(origin_get) == retained-gateway ]]
[[ $(compose ps -q caddy) == "$caddy_id" ]]
[[ $(docker inspect --format '{{.State.StartedAt}}' "$caddy_id") == "$caddy_started" ]]
cat "$ROOT/valid-Caddyfile" > "$ROOT/config/Caddyfile"
assert_retained

echo 'PASS: Token reaches the real Caddy environment; only the gateway is recreated and certificates/data persist'
echo 'PASS: failed candidate restores both credentials and the Caddy environment without changing business containers'
echo 'PASS: invalid reload retains the running gateway and verified origin TLS'

# Real domain-change integration coverage: provider/public DNS boundaries only.
new_domain=new.example.com
third_domain=rollback.example.com
domain_dns_log=$ROOT/domain-dns.log
: > "$domain_dns_log"
render_caddy() {
  local hosts=${1:-$DOMAIN}
  cat <<EOF
{
  auto_https disable_redirects
}
$hosts {
  tls internal
  respond "retained-gateway" 200
}
EOF
}
caddy_domain_plan() {
  local target=${1:-$new_domain} dir=$ROOT/state/caddy-domain-change
  [[ $target =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 1
  jq --arg new "$target" '.new_domain=$new' "$dir/journal.json" > "$dir/journal.tmp" && mv "$dir/journal.tmp" "$dir/journal.json"
}
caddy_domain_ensure_dns() {
  local dir=$ROOT/state/caddy-domain-change
  printf 'ensure:%s\n' "$(jq -r .new_domain "$dir/journal.json")" >> "$domain_dns_log"
  jq '.create_started=true' "$dir/journal.json" > "$dir/journal.tmp" && mv "$dir/journal.tmp" "$dir/journal.json"
}
caddy_domain_cleanup_dns() { printf 'cleanup:%s\n' "$1" >> "$domain_dns_log"; }
caddy_domain_verify() {
  caddy_ready 30 || return 1
  curl --silent --show-error --fail --noproxy '*' --connect-timeout 2 --max-time 5 --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/" | grep -qx retained-gateway
}
declare -A domain_before_id domain_before_started
for service in caddy mmwx postgres; do
  domain_before_id[$service]=$(compose ps -q "$service")
  domain_before_started[$service]=$(docker inspect --format '{{.State.StartedAt}}' "${domain_before_id[$service]}")
done
cp "$ROOT/config/cloudflare.token" "$ROOT/domain-token"
cp "$ROOT/config/caddy.env" "$ROOT/domain-caddy.env"
sha256sum "$ROOT/config/compose.yaml" "$ROOT/config/app.env" "$ROOT/config/postgres.env" > "$ROOT/domain-files.sha256"
find "$ROOT/certs/data" -type f \( -name '*.crt' -o -name '*.key' \) -exec sha256sum {} + | sort > "$ROOT/domain-certs.sha256"
change_caddy_domain "$new_domain" > "$ROOT/domain-success-output" 2>&1
DOMAIN=$new_domain
[[ $(jq -r .domain "$ROOT/state/state.json") == "$new_domain" ]]
[[ $(jq -r .domain "$ROOT/state/progress.json") == "$new_domain" ]]
[[ ! -d $ROOT/state/caddy-domain-change ]]
[[ $(cat "$domain_dns_log") == $'ensure:new.example.com\ncleanup:old' ]]
for service in caddy mmwx postgres; do
  id=$(compose ps -q "$service")
  [[ $id == "${domain_before_id[$service]}" ]]
  [[ $(docker inspect --format '{{.State.StartedAt}}' "$id") == "${domain_before_started[$service]}" ]]
done
[[ $(compose exec -T postgres psql -U mmwx -d mmwx -Atc 'SELECT value FROM caddy_rotation_test') == retained ]]
for dir in /app/data /app/subscribes /app/rule_templates; do [[ $(compose exec -T mmwx cat "$dir/probe") == retained ]]; done
for dir in /data /config; do [[ $(compose exec -T caddy cat "$dir/probe") == retained ]]; done
[[ $(curl --silent --show-error --fail --noproxy '*' --resolve "$new_domain:443:127.0.0.1" "https://$new_domain/") == retained-gateway ]]
cmp "$ROOT/domain-token" "$ROOT/config/cloudflare.token"
cmp "$ROOT/domain-caddy.env" "$ROOT/config/caddy.env"
sha256sum --check --status "$ROOT/domain-files.sha256"
sha256sum --check --status "$ROOT/domain-certs.sha256"
touch "$ROOT/fail-domain-ready"
eval "$(declare -f caddy_ready | sed '1s/caddy_ready/caddy_ready_domain_runtime/')"
caddy_ready() {
  if [[ -f $ROOT/fail-domain-ready ]]; then rm -f "$ROOT/fail-domain-ready"; return 1; fi
  caddy_ready_domain_runtime
}
if (change_caddy_domain "$third_domain") > "$ROOT/domain-rollback-output" 2>&1; then
  echo 'Failed domain candidate was accepted'; exit 1
fi
[[ $(jq -r .domain "$ROOT/state/state.json") == "$new_domain" ]]
[[ $(jq -r .domain "$ROOT/state/progress.json") == "$new_domain" ]]
[[ ! -d $ROOT/state/caddy-domain-change ]]
[[ $(compose ps -q caddy) == "${domain_before_id[caddy]}" ]]
[[ $(curl --silent --show-error --fail --noproxy '*' --resolve "$new_domain:443:127.0.0.1" "https://$new_domain/") == retained-gateway ]]
grep -q '^ensure:rollback.example.com$' "$domain_dns_log"
grep -q '^cleanup:new$' "$domain_dns_log"
echo 'PASS: domain switch keeps real Caddy, app, database, credentials, data and certificates while serving the new SNI'
echo 'PASS: failed domain candidate restores the committed domain and cleans only the staged DNS record'
