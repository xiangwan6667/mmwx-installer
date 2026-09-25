#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./install.sh
# Native Windows jq emits CRLF; normalize its transport in the local fixture.
jq() { command jq "$@" | tr -d '\r'; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ROOT=$tmp/root
mkdir -p "$ROOT/config" "$ROOT/state"
DOMAIN=old.example.com PREFIX='' ZONE_NAME=example.com
printf 'old.example.com {}\n' > "$ROOT/config/Caddyfile"
MODE=''
caddy_domain_local_ipv4() { printf '8.8.8.8\n'; }
ask() { case "$1" in *前缀*) printf '';; *) printf 1;; esac; }
reset_dns() {
  [[ ! -d $ROOT/state/caddy-domain-change ]] || caddy_domain_discard
  caddy_domain_stage
  : > "$tmp/calls"
  printf '[]' > "$tmp/new"
  cat > "$tmp/old" <<'JSON'
[
 {"id":"old1","name":"old.example.com","type":"A","content":"8.8.8.8","proxied":true,"comment":"mmwx-installer","ttl":1},
 {"id":"unowned","name":"old.example.com","type":"A","content":"8.8.8.8","proxied":true,"comment":null,"ttl":1},
 {"id":"unproxied","name":"old.example.com","type":"A","content":"8.8.8.8","proxied":false,"comment":"mmwx-installer","ttl":1},
 {"id":"otherip","name":"old.example.com","type":"A","content":"1.1.1.1","proxied":true,"comment":"mmwx-installer","ttl":1}
]
JSON
}
caddy_domain_request() {
  local method=$1 endpoint=$2 payload=$3 output=$4 file id pages=1
  printf '%s %s\n' "$method" "$endpoint" >> "$tmp/calls"
  case "$method $endpoint" in
    'GET /zones?'*)
      if [[ $endpoint == *page=2 ]]; then
        printf '{"success":true,"result":[{"id":"zone2","name":"example.net","status":"active"}],"result_info":{"total_pages":2}}' > "$output"
      else printf '{"success":true,"result":[{"id":"zone1","name":"example.com","status":"active"}],"result_info":{"total_pages":2}}' > "$output"; fi;;
    'GET /zones/'*'/dns_records?'*)
      file=$tmp/new
      [[ $endpoint != *'name=old.example.com&'* ]] || file=$tmp/old
      [[ $MODE != read-fail ]] || return 7
      [[ $MODE != paginated ]] || pages=2
      if [[ $MODE == malformed ]]; then printf '{"success":true,"result":null}' > "$output"; return 0; fi
      jq --argjson pages "$pages" '{success:true,result:.,result_info:{total_pages:$pages}}' "$file" > "$output";;
    'POST /zones/'*'/dns_records')
      [[ $MODE != post-fail ]] || return 22
      jq '[. + {id:"new1"}]' "$payload" > "$tmp/new"
      printf '{"success":true,"result":{"id":"new1"}}' > "$output"
      [[ $MODE != post-timeout ]];;
    'DELETE /zones/'*'/dns_records/'*)
      id=${endpoint##*/}
      [[ $MODE != delete-fail ]] || return 22
      for file in "$tmp/old" "$tmp/new"; do
        jq --arg id "$id" '[.[]|select(.id!=$id)]' "$file" > "$tmp/next" && mv "$tmp/next" "$file" || return 1
      done
      printf '{"success":true,"result":{}}' > "$output"
      [[ $MODE != delete-timeout ]];;
    *) echo "Unexpected API $method $endpoint" >&2; return 1;;
  esac
}
reset_dns
caddy_domain_plan ''
jq -e '.new_domain=="mmwx.example.com" and .old_zone=="zone1" and .ipv4=="8.8.8.8"' "$ROOT/state/caddy-domain-change/journal.json" >/dev/null
jq -e 'length==1 and .[0].id=="old1"' "$ROOT/state/caddy-domain-change/old_records.json" >/dev/null
grep -q 'page=2' "$tmp/calls"
# Reuse matching A without creating, claiming, or cleaning it on rollback.
printf '[{"id":"existing","name":"mmwx.example.com","type":"A","content":"8.8.8.8","proxied":true,"comment":null,"ttl":1}]' > "$tmp/new"
caddy_domain_ensure_dns
caddy_domain_cleanup_dns new
[[ $(jq length "$tmp/new") == 1 ]]
if grep -Eq 'POST|DELETE' "$tmp/calls"; then echo 'Modified a reused record'; exit 1; fi

# Ambiguous POST is reconciled and never repeated; rollback cleans this marker only.
printf '[]' > "$tmp/new"
MODE=post-timeout caddy_domain_ensure_dns
caddy_domain_ensure_dns
[[ $(grep -c '^POST' "$tmp/calls") == 1 ]]
MODE=delete-timeout caddy_domain_cleanup_dns new
[[ $(jq length "$tmp/new") == 0 ]]
# A lost create result followed by an empty query cannot cause a second POST.
if caddy_domain_ensure_dns; then echo 'Repeated an unresolved creation'; exit 1; fi
[[ $(grep -c '^POST' "$tmp/calls") == 1 ]]

# Only the snapshotted, unchanged old record is removed; DELETE timeout is reconciled.
MODE=delete-timeout caddy_domain_cleanup_dns old
[[ $(jq length "$tmp/old") == 3 ]]
jq -e 'all(.[]; .id!="old1")' "$tmp/old" >/dev/null
caddy_domain_cleanup_dns old

# Post-plan edits keep the record even if its ID/ownership marker are unchanged.
reset_dns; caddy_domain_plan mmwx.example.com
jq 'map(if .id=="old1" then .content="9.9.9.9" else . end)' "$tmp/old" > "$tmp/next"; mv "$tmp/next" "$tmp/old"
caddy_domain_cleanup_dns old
[[ $(jq length "$tmp/old") == 4 ]]
if grep -q '^DELETE' "$tmp/calls"; then echo 'Deleted an edited record'; exit 1; fi
reset_dns; caddy_domain_plan mmwx.example.com
if MODE=delete-fail caddy_domain_cleanup_dns old; then echo 'Accepted failed DNS deletion'; exit 1; fi
[[ $(jq length "$tmp/old") == 4 ]]
caddy_domain_cleanup_dns old
[[ $(jq length "$tmp/old") == 3 ]]

for mode in malformed paginated read-fail; do
  reset_dns
  if MODE=$mode caddy_domain_plan mmwx.example.com; then echo "Accepted $mode DNS response"; exit 1; fi
  if grep -Eq 'POST|DELETE' "$tmp/calls"; then echo 'Wrote before validation'; exit 1; fi
done
reset_dns
printf '[{"id":"conflict","name":"mmwx.example.com","type":"AAAA","content":"::1","proxied":true}]' > "$tmp/new"
if caddy_domain_plan mmwx.example.com; then echo 'Accepted AAAA conflict'; exit 1; fi
reset_dns; caddy_domain_plan mmwx.example.com
if MODE=post-fail caddy_domain_ensure_dns; then echo 'Accepted failed DNS creation'; exit 1; fi
caddy_domain_cleanup_dns new
[[ $(jq length "$tmp/new") == 0 ]]
reset_dns; caddy_domain_plan mmwx.example.net
jq -e '.new_zone=="zone2" and .old_zone=="zone1"' "$ROOT/state/caddy-domain-change/journal.json" >/dev/null
reset_dns; caddy_domain_plan old.example.com
[[ ! -s $tmp/calls ]]
# Exercise the real HTTP boundary, including private headers and no write retries.
(
  source ./install.sh
  ROOT=$tmp/http
  mkdir -p "$ROOT/config" "$ROOT/state/caddy-domain-change"
  token='domain-fixture-token-00000000000000'
  printf '%s\n' "$token" > "$ROOT/config/cloudflare.token"
  chmod 600 "$ROOT/config/cloudflare.token"
  caddy_token_file_check() { [[ -f $1 && ! -L $1 && $(stat -c %a "$1") == 600 ]]; }
  curl() {
    local output='' header='' arg
    printf '%s\n' "$@" > "$tmp/http-args"
    while (($#)); do
      arg=$1; shift
      case "$arg" in --output) output=$1; shift;; --header) header=${1#@}; shift;; esac
    done
    [[ $(stat -c %a "$header") == 600 ]]
    grep -qx "Authorization: Bearer $token" "$header"
    printf '{"success":true,"result":[]}' > "$output"
    [[ ${HTTP_MODE:-} != failure ]] || return 28
    printf 200
  }
  printf '{}' > "$ROOT/payload"
  if ! caddy_domain_request POST /zones/zone1/dns_records "$ROOT/payload" "$ROOT/response" > "$tmp/http-output" 2>&1; then
    cat "$tmp/http-output" "$ROOT/state/caddy-domain-change/request.error" >&2
    echo 'HTTP fixture failed'; exit 1
  fi
  grep -q '^--data-binary$' "$tmp/http-args"
  grep -A1 '^--retry$' "$tmp/http-args" | grep -qx 0
  if grep -F "$token" "$tmp/http-args" "$tmp/http-output"; then echo 'Token leaked'; exit 1; fi
  if HTTP_MODE=failure caddy_domain_request POST /zones/zone1/dns_records "$ROOT/payload" "$ROOT/response"; then echo 'HTTP timeout accepted'; exit 1; fi
  rm "$ROOT/config/cloudflare.token"
  if caddy_domain_request GET /zones '' "$ROOT/response"; then echo 'Missing Token accepted'; exit 1; fi
)
echo 'PASS: zone selection, DNS conflict/reuse, ownership checks, ambiguous POST/DELETE reconciliation and safe cleanup'
