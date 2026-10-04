#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./install.sh
jq() { command jq "$@" | tr -d '\r'; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ROOT=$tmp/root
mkdir -p "$ROOT/config" "$ROOT/state" "$ROOT/certs"
DOMAIN=old.example.com SUBSCRIPTION_DOMAIN=mmw.example.com CHANNEL=stable VERSION=v1 APP_IMAGE=app CADDY_IMAGE=caddy PG_IMAGE=pg
save_state; checkpoint 7
for file in compose.yaml caddy.env cloudflare.token; do printf 'unchanged\n' > "$ROOT/config/$file"; done
render_caddy > "$ROOT/config/Caddyfile"
printf 'retained-certificate\n' > "$ROOT/certs/test"
cp "$ROOT/config/Caddyfile" "$tmp/old.caddy"
cp "$ROOT/state/state.json" "$tmp/old.state"
cp "$ROOT/state/progress.json" "$tmp/old.progress"
sha256sum "$ROOT/config/compose.yaml" "$ROOT/config/caddy.env" "$ROOT/config/cloudflare.token" "$ROOT/certs/test" > "$tmp/retained"
confirm() {
  if [[ $1 == *迁移* ]]; then
    # Both domains must remain usable until the panel migration is confirmed.
    grep -q 'old.example.com, new.example.com {' "$ROOT/config/Caddyfile" || return 1
    [[ $(jq -r .domain "$ROOT/state/state.json") == old.example.com ]] || return 1
    [[ ${MODE:-} != wait-migration ]]
  else [[ ${MODE:-} != cancel ]]; fi
}
caddy_domain_plan() {
  [[ ${MODE:-} != plan-fail ]] || return 1
  jq --arg domain "${1:-new.example.com}" '.new_domain=$domain' "$ROOT/state/caddy-domain-change/journal.json" > "$tmp/journal"
  mv "$tmp/journal" "$ROOT/state/caddy-domain-change/journal.json"
}
caddy_domain_ensure_dns() { echo create >> "$tmp/events"; [[ ${MODE:-} != dns-fail ]]; }
caddy_domain_cleanup_dns() {
  echo "cleanup $1" >> "$tmp/events"
  [[ ${MODE:-} != cleanup-fail || $1 != old ]]
}
caddy_validate_config() { [[ ${MODE:-} != validate-fail || $(cat "$ROOT/config/Caddyfile") == "$(cat "$tmp/old.caddy")" ]]; }
caddy_ready() { [[ ${MODE:-} != rollback-fail ]]; }
caddy_domain_verify() { [[ ${MODE:-} != tls-fail && ${MODE:-} != rollback-fail ]]; }
caddy_tls_diagnose() { :; }
# Invoked via caddy_step.
# shellcheck disable=SC2317,SC2329
dc() {
  printf '%s\n' "$*" >> "$tmp/events"
  [[ $* == 'exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile' ]] || return 1
  [[ ${MODE:-} != reload-fail || $(cat "$ROOT/config/Caddyfile") == "$(cat "$tmp/old.caddy")" ]] &&
  [[ ${MODE:-} != finalize-fail || $(cat "$ROOT/config/Caddyfile") != *$'\nnew.example.com {'* ]]
}
reset_fixture() {
  cp "$tmp/old.state" "$ROOT/state/state.json"
  cp "$tmp/old.progress" "$ROOT/state/progress.json"
  cat "$tmp/old.caddy" > "$ROOT/config/Caddyfile"
  : > "$tmp/events"
}
assert_old() {
  cmp "$tmp/old.state" "$ROOT/state/state.json"
  cmp "$tmp/old.progress" "$ROOT/state/progress.json"
  cmp "$tmp/old.caddy" "$ROOT/config/Caddyfile"
  sha256sum -c "$tmp/retained" >/dev/null
}
MODE=cancel change_caddy_domain >/dev/null
[[ ! -e $ROOT/state/caddy-domain-change && ! -s $tmp/events ]]
MODE='' change_caddy_domain old.example.com >/dev/null
[[ ! -e $ROOT/state/caddy-domain-change && ! -s $tmp/events ]]
for mode in plan-fail dns-fail validate-fail reload-fail tls-fail; do
  reset_fixture
  if (MODE=$mode change_caddy_domain) > "$tmp/output" 2>&1; then echo "Accepted $mode"; exit 1; fi
  assert_old
  [[ ! -e $ROOT/state/caddy-domain-change ]]
  if grep -qx 'cleanup old' "$tmp/events"; then echo 'Removed old DNS before success'; exit 1; fi
done
reset_fixture
MODE='' change_caddy_domain > "$tmp/output"
[[ $(jq -r .domain "$ROOT/state/state.json") == new.example.com ]]
[[ $(jq -r .domain "$ROOT/state/progress.json") == new.example.com ]]
[[ $(jq -r .subscription_domain "$ROOT/state/state.json") == mmw.example.com ]]
grep -q '^mmw.example.com {' "$ROOT/config/Caddyfile"
grep -q '^new.example.com {' "$ROOT/config/Caddyfile"
[[ ! -e $ROOT/state/caddy-domain-change ]]
grep -qx 'cleanup old' "$tmp/events"
if grep -qx 'cleanup new' "$tmp/events"; then echo 'Deleted new DNS after success'; exit 1; fi
sha256sum -c "$tmp/retained" >/dev/null

# Declining panel confirmation preserves both hosts, old state and DNS.
reset_fixture
MODE=wait-migration change_caddy_domain > "$tmp/output"
[[ $(jq -r .phase "$ROOT/state/caddy-domain-change/journal.json") == awaiting-migration ]]
[[ $(jq -r .domain "$ROOT/state/state.json") == old.example.com ]]
grep -q 'old.example.com, new.example.com {' "$ROOT/config/Caddyfile"
grep -q '系统设置.*系统' "$tmp/output"
if grep -qx 'cleanup old' "$tmp/events"; then echo 'Cleaned old domain before panel migration'; exit 1; fi
MODE=wait-migration recover_caddy_domain >/dev/null
[[ -d $ROOT/state/caddy-domain-change ]]
MODE='' recover_caddy_domain >/dev/null
[[ $(jq -r .domain "$ROOT/state/state.json") == new.example.com ]]
[[ ! -e $ROOT/state/caddy-domain-change ]]

# Once panel migration is confirmed, finalization failures cannot roll back it.
reset_fixture
if (MODE=finalize-fail change_caddy_domain) > "$tmp/output" 2>&1; then echo 'Final reload failure accepted'; exit 1; fi
[[ $(jq -r .phase "$ROOT/state/caddy-domain-change/journal.json") == finalizing ]]
if grep -qx 'cleanup new' "$tmp/events"; then echo 'Deleted migrated destination after panel confirmation'; exit 1; fi
MODE='' recover_caddy_domain >/dev/null
[[ $(jq -r .domain "$ROOT/state/state.json") == new.example.com ]]
[[ ! -e $ROOT/state/caddy-domain-change ]]

# Cleanup failure keeps the working new domain and resume retries only DNS cleanup.
reset_fixture
if (MODE=cleanup-fail change_caddy_domain) > "$tmp/output" 2>&1; then echo 'Cleanup failure accepted'; exit 1; fi
[[ $(jq -r .phase "$ROOT/state/caddy-domain-change/journal.json") == committed ]]
[[ $(jq -r .domain "$ROOT/state/state.json") == new.example.com ]]
: > "$tmp/events"
MODE='' recover_caddy_domain >/dev/null
[[ $(cat "$tmp/events") == 'cleanup old' && ! -e $ROOT/state/caddy-domain-change ]]

# A failed rollback keeps the journal until recovery can restore the old gateway.
reset_fixture
if (MODE=rollback-fail change_caddy_domain) > "$tmp/output" 2>&1; then echo 'Failed rollback accepted'; exit 1; fi
[[ -f $ROOT/state/caddy-domain-change/journal.json ]]
MODE='' recover_caddy_domain >/dev/null
assert_old
[[ ! -e $ROOT/state/caddy-domain-change ]]

# Simulate interruption after only state.json was changed; recover both records.
reset_fixture
caddy_domain_stage
MODE='' caddy_domain_plan ''
caddy_domain_phase applying
jq '.domain="new.example.com"' "$tmp/old.state" > "$ROOT/state/state.json"
printf 'partial-write' > "$ROOT/config/Caddyfile"
MODE='' recover_caddy_domain >/dev/null
assert_old
echo 'PASS: domain switch reloads only Caddy, retains data, rolls back failures and resumes DNS cleanup'
