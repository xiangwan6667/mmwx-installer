#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./install.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ROOT=$tmp/root
mkdir -p "$ROOT/state/caddy-token-change"
DOMAIN=panel.example.com SUBSCRIPTION_DOMAIN=mmw.example.net
reset_probe() {
  printf '{"phase":"probing","domain":"panel.example.com","zone":"","name":"","value":"","comment":""}' > "$ROOT/state/caddy-token-change/journal.json"
  printf '[]' > "$tmp/records"
  : > "$tmp/calls"
}
caddy_token_request() {
  local method=$1 endpoint=$2 payload=$3 output=$4
  printf '%s %s\n' "$method" "$endpoint" >> "$tmp/calls"
  case "$method $endpoint" in
    'GET /zones?'*)
      if [[ ${MODE:-} == missing-zone ]]; then
        printf '{"success":true,"result":[{"id":"zone1","name":"example.com","status":"active"}]}' > "$output"
      else
        printf '{"success":true,"result":[{"id":"zone1","name":"example.com","status":"active"},{"id":"zone2","name":"example.net","status":"active"}]}' > "$output"
      fi;;
    'POST /zones/'*'/dns_records')
      [[ ${MODE:-} != denied || $endpoint != /zones/zone2/* ]] || return 1
      jq '[. + {id:"probe1"}]' "$payload" > "$tmp/records"
      printf '{"success":true,"result":{"id":"probe1"}}' > "$output";;
    'GET /zones/'*'/dns_records?'*) jq '{success:true,result:.,result_info:{total_pages:1}}' "$tmp/records" > "$output";;
    'DELETE /zones/'*'/dns_records/'*) printf '[]' > "$tmp/records"; printf '{"success":true,"result":{}}' > "$output";;
    *) return 1;;
  esac
}
reset_probe
caddy_token_probe
if ! grep -q '^POST /zones/zone2/dns_records$' "$tmp/calls"; then echo 'New Token did not validate subscription zone DNS permissions'; exit 1; fi
[[ $(jq -r .phase "$ROOT/state/caddy-token-change/journal.json") == validated ]]
[[ $(jq length "$tmp/records") == 0 ]]
reset_probe
if MODE=missing-zone caddy_token_probe; then echo 'Token accepted without subscription zone'; exit 1; fi
if grep -q '^POST' "$tmp/calls"; then echo 'Probe mutated DNS before checking all zone grants'; exit 1; fi
reset_probe
if MODE=denied caddy_token_probe; then echo 'Token accepted without subscription DNS edit'; exit 1; fi
[[ $(jq -r .phase "$ROOT/state/caddy-token-change/journal.json") == probing ]]
echo 'PASS: Token replacement requires read and DNS edit for independent subscription zones'
