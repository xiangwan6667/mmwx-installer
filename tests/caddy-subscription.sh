#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./install.sh
jq() { command jq "$@" | tr -d '\r'; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ROOT=$tmp/root
mkdir -p "$ROOT/config" "$ROOT/state"
DOMAIN=panel.example.com SUBSCRIPTION_DOMAIN='' CHANNEL=stable VERSION=v1 APP_IMAGE=app CADDY_IMAGE=caddy PG_IMAGE=pg
save_state; checkpoint 7
for file in compose.yaml caddy.env cloudflare.token; do printf 'retained\n' > "$ROOT/config/$file"; done
render_caddy > "$ROOT/config/Caddyfile"
confirm() { [[ $1 != *更新* || ${MODE:-} != wait ]]; }
caddy_domain_plan() {
  local target=${1:-mmw.example.com}
  # shellcheck disable=SC2016
  caddy_domain_journal --arg target "$target" '.new_domain=$target'
}
caddy_domain_ensure_dns() { :; }
caddy_domain_cleanup_dns() { printf '%s\n' "$1" >> "$tmp/cleanup"; }
caddy_domain_reload() { :; }
caddy_ready() { :; }
caddy_domain_verify() { [[ ${MODE:-} != fail ]]; }
caddy_tls_diagnose() { :; }
declare -F add_caddy_subscription >/dev/null || { echo 'Subscription domain management missing'; exit 1; }
add_caddy_subscription > "$tmp/output"
[[ $(jq -r .domain "$ROOT/state/state.json") == panel.example.com ]]
[[ $(jq -r .subscription_domain "$ROOT/state/state.json") == mmw.example.com ]]
[[ $(jq -r .subscription_domain "$ROOT/state/progress.json") == mmw.example.com ]]
grep -q '^panel.example.com {' "$ROOT/config/Caddyfile"
grep -q '^mmw.example.com {' "$ROOT/config/Caddyfile"
grep -q 'path /x/\* /api/fw/\* /api/clash/subscribe /api/user/package-subscribe /api/subscribe' "$ROOT/config/Caddyfile"
grep -q 'respond 404' "$ROOT/config/Caddyfile"
grep -q '系统设置.*系统.*订阅域名' "$tmp/output"
[[ ! -e $ROOT/state/caddy-domain-change ]]
if (add_caddy_subscription other.example.com) >/dev/null 2>&1; then echo 'Add silently replaced existing subscription'; exit 1; fi
# Loading, saving and rendering preserve the independent subscription hostname.
SUBSCRIPTION_DOMAIN=''
load_state
[[ $SUBSCRIPTION_DOMAIN == mmw.example.com ]]
save_state; checkpoint 7
render_caddy > "$tmp/rendered"
grep -q '^mmw.example.com {' "$tmp/rendered"
cp "$ROOT/config/Caddyfile" "$tmp/old.caddy"
# Switch stages both subscription hosts and waits for the panel setting.
MODE='wait' change_caddy_subscription next.example.com > "$tmp/output"
[[ $(jq -r .subscription_domain "$ROOT/state/state.json") == mmw.example.com ]]
grep -q '^mmw.example.com, next.example.com {' "$ROOT/config/Caddyfile"
grep -q '^panel.example.com {' "$ROOT/config/Caddyfile"
[[ $(jq -r .phase "$ROOT/state/caddy-domain-change/journal.json") == awaiting-migration ]]
MODE='' recover_caddy_domain >/dev/null
[[ $(jq -r .domain "$ROOT/state/state.json") == panel.example.com ]]
[[ $(jq -r .subscription_domain "$ROOT/state/state.json") == next.example.com ]]
grep -q '^next.example.com {' "$ROOT/config/Caddyfile"
if grep -q 'mmw.example.com' "$ROOT/config/Caddyfile"; then echo 'Old subscription still served after confirmation'; exit 1; fi
# A certificate failure restores only the subscription operation's snapshot.
cp "$ROOT/config/Caddyfile" "$tmp/committed.caddy"
if (MODE=fail change_caddy_subscription failed.example.com) > "$tmp/output" 2>&1; then echo 'Failed subscription certificate accepted'; exit 1; fi
cmp "$tmp/committed.caddy" "$ROOT/config/Caddyfile"
[[ $(jq -r .subscription_domain "$ROOT/state/state.json") == next.example.com ]]
[[ $(jq -r .domain "$ROOT/state/state.json") == panel.example.com ]]
[[ ! -e $ROOT/state/caddy-domain-change ]]
# Subscription HTTPS checks must verify both the 404 guard and working proxy.
(
  source ./install.sh
  ROOT=$tmp/probe
  mkdir -p "$ROOT/state/caddy-domain-change"
  printf '{"kind":"subscription"}' > "$ROOT/state/caddy-domain-change/journal.json"
  DOMAIN=mmw.example.com
  caddy_ready() { :; }
  sleep() { :; }
  curl() {
    printf '%s\n' "$*" >> "$tmp/probe-calls"
    case "$*" in
      *'/api/subscribe'*) printf '%s' "${PROXY_STATUS:-401}";;
      *) printf 404;;
    esac
  }
  : > "$tmp/probe-calls"
  caddy_domain_verify >/dev/null
  if ! grep -q '/api/subscribe' "$tmp/probe-calls"; then echo 'Subscription proxy was not checked'; exit 1; fi
  if PROXY_STATUS=502 caddy_domain_verify >/dev/null 2>&1; then echo 'Broken subscription upstream accepted'; exit 1; fi
)
echo 'PASS: subscription add/switch, restricted paths, durable independent state, panel confirmation and rollback'
