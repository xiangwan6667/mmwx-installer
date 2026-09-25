#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./install.sh
case $(uname -s) in MINGW*|MSYS*) jq() { command jq -b "$@"; };; esac
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ROOT=$tmp/root
mkdir -p "$ROOT/config" "$ROOT/state" "$ROOT/certs/data" "$ROOT/certs/config"
DOMAIN=mmwx.example.com CHANNEL=stable VERSION=v1 APP_IMAGE=app CADDY_IMAGE=caddy PG_IMAGE=pg
save_state; checkpoint 7
old='old-token-01234567890123456789'
new='new-token-01234567890123456789'
printf '%s\n' "$old" > "$ROOT/config/cloudflare.token"
printf 'TZ=Asia/Shanghai\nCF_API_TOKEN=%s\n' "$old" > "$ROOT/config/caddy.env"
printf '%s\n' "$new" > "$tmp/new-token"
TOKEN_FILE=$tmp/new-token
chmod 600 "$TOKEN_FILE" "$ROOT"/config/*
cp "$ROOT/config/cloudflare.token" "$tmp/original.token"
cp "$ROOT/config/caddy.env" "$tmp/original.env"
# These boundaries require a Linux root installation; transaction/file logic is real.
caddy_require_install() { load_state; }
caddy_token_file_check() { [[ -f $1 && ! -L $1 && $(stat -c %a "$1") == 600 ]]; }
confirm() { return 0; }
caddy_step() { shift; "$@"; }
caddy_ready() { [[ ${FAIL:-} != ready ]]; }
caddy_validate_config() { return 0; }
dc() {
  printf '%s\n' "$*" >> "$tmp/docker.calls"
  [[ $* == 'up -d --no-deps --force-recreate --wait --wait-timeout 300 caddy' ]]
}
caddy_token_request() {
  local method=$1 endpoint=$2 data=$3 output=$4
  printf '%s %s\n' "$method" "$endpoint" >> "$tmp/api.calls"
  case "$method $endpoint" in
    'GET /zones?'*)
      [[ ${FAIL:-} != auth ]] || return 1
      if [[ ${FAIL:-} == zone ]]; then printf '{"success":true,"result":[],"result_info":{"total_pages":1}}' > "$output";
      else printf '{"success":true,"result":[{"id":"zone123","name":"example.com","status":"active"}],"result_info":{"total_pages":1}}' > "$output"; fi;;
    'POST '*)
      if [[ ${FAIL:-} != create ]]; then jq '. + {id:"record123"}' "$data" > "$tmp/record"; fi
      [[ ${FAIL:-} != timeout && ${FAIL:-} != create ]] || return 1
      printf '{"success":true,"result":{"id":"record123"}}' > "$output";;
    'GET '*'/dns_records?'*)
      [[ ${FAIL:-} != network ]] || return 1
      if [[ -f $tmp/record && ${FAIL:-} != invisible ]]; then jq -s '{success:true,result:.,result_info:{total_pages:1}}' "$tmp/record" > "$output";
      else printf '{"success":true,"result":[],"result_info":{"total_pages":1}}' > "$output"; fi;;
    'DELETE '*)
      [[ ${FAIL:-} != delete ]] || return 1
      rm -f "$tmp/record"
      printf '{"success":true,"result":{"id":"record123"}}' > "$output";;
    *) return 90;;
  esac
}
assert_old() { cmp "$ROOT/config/cloudflare.token" "$tmp/original.token"; cmp "$ROOT/config/caddy.env" "$tmp/original.env"; }
for FAIL in auth zone create timeout delete invisible; do
  : > "$tmp/docker.calls"; : > "$tmp/api.calls"
  if (replace_caddy_token) > "$tmp/output" 2>&1; then echo "Accepted $FAIL"; exit 1; fi
  assert_old
  [[ ! -s $tmp/docker.calls ]]
  [[ $(grep -c '^POST ' "$tmp/api.calls" || true) -le 1 ]]
  if [[ $FAIL == delete || $FAIL == invisible ]]; then
    [[ -f $ROOT/state/caddy-token-change/journal.json ]]
    FAIL='' recover_caddy_token > "$tmp/output"
    [[ ! -e $tmp/record ]]
  fi
  [[ ! -d $ROOT/state/caddy-token-change ]]
  rm -f "$tmp/record"
done
FAIL=''
replace_caddy_token > "$tmp/output" 2>&1
cmp "$ROOT/config/cloudflare.token" "$tmp/new-token"
grep -qx 'TZ=Asia/Shanghai' "$ROOT/config/caddy.env"
[[ ! -d $ROOT/state/caddy-token-change && ! -f $tmp/record ]]
grep -qx 'up -d --no-deps --force-recreate --wait --wait-timeout 300 caddy' "$tmp/docker.calls"
if grep -F -e "$old" -e "$new" "$tmp/output" "$tmp/api.calls" "$tmp/docker.calls"; then echo 'Leaked Token'; exit 1; fi
# Simulate interruption between the two atomic credential replacements.
cp "$tmp/original.token" "$ROOT/config/cloudflare.token"; cp "$tmp/original.env" "$ROOT/config/caddy.env"
caddy_token_stage
caddy_token_phase applying
cp "$tmp/new-token" "$ROOT/config/cloudflare.token"
recover_caddy_token > "$tmp/output"
assert_old
[[ ! -d $ROOT/state/caddy-token-change ]]
# Rollback failure retains credentials and journal for retry.
caddy_token_stage; caddy_token_phase applying
FAIL=ready
if (recover_caddy_token) > "$tmp/output" 2>&1; then echo 'Accepted failed rollback'; exit 1; fi
[[ -f $ROOT/state/caddy-token-change/journal.json ]]
assert_old
FAIL='' recover_caddy_token > "$tmp/output"
# An unavailable API cannot block restoring the old local gateway credentials.
caddy_token_stage; caddy_token_phase applying
jq '.zone="zone123" | .name="_mmwx-token-unresolved.mmwx.example.com"' "$ROOT/state/caddy-token-change/journal.json" > "$tmp/journal"
mv "$tmp/journal" "$ROOT/state/caddy-token-change/journal.json"
cp "$tmp/new-token" "$ROOT/config/cloudflare.token"
: > "$tmp/docker.calls"
if (FAIL=network recover_caddy_token) > "$tmp/output" 2>&1; then echo 'Unresolved cleanup accepted'; exit 1; fi
assert_old
[[ -s $tmp/docker.calls && -f $ROOT/state/caddy-token-change/journal.json ]]
FAIL='' recover_caddy_token > "$tmp/output"
# Committed transactions clean up without reverting or recreating.
caddy_token_stage; caddy_token_phase committed
cp "$tmp/new-token" "$ROOT/config/cloudflare.token"
: > "$tmp/docker.calls"
recover_caddy_token > "$tmp/output"
cmp "$tmp/new-token" "$ROOT/config/cloudflare.token"
[[ ! -s $tmp/docker.calls ]]
echo 'PASS: Token permission probes, ambiguous create cleanup, two-file recovery and Caddy-only rollback'
trap 'printf "Token boundary test failed at line %s\n" "$LINENO" >&2' ERR

# Exercise the real HTTP wrapper with a captured curl boundary. Credentials
# belong in a private header file, never in argv, stdout or stderr.
(
  # Already analyzed at file scope; reload real functions inside this fixture.
  # shellcheck source=/dev/null
  source ./install.sh
  ROOT=$tmp/http-root
  mkdir -p "$ROOT/state/caddy-token-change"
  chmod 700 "$ROOT/state/caddy-token-change"
  printf '%s\n' "$new" > "$ROOT/state/caddy-token-change/candidate.token"
  printf '{"type":"TXT","name":"_probe.example.com","content":"test"}\n' > "$ROOT/payload.json"
  : > "$tmp/curl.calls"
  # shellcheck disable=SC2317,SC2329
  curl() {
    local arg header='' output='' payload=''
    printf 'request\n' >> "$tmp/curl.calls"
    printf '%s\n' "$@" > "$tmp/curl.argv"
    for arg in "$@"; do
      [[ $arg != *"$old"* && $arg != *"$new"* && $arg != --retry* ]] || return 90
    done
    while (($#)); do
      case "$1" in
        --header) header=${2#@}; [[ $2 == @* ]] || return 91; shift 2;;
        --output) output=$2; shift 2;;
        --data-binary) payload=${2#@}; [[ $2 == @* ]] || return 92; shift 2;;
        *) shift;;
      esac
    done
    [[ -f $header && ! -L $header && $(stat -c %a "$header") == 600 ]] || return 93
    grep -Fxq "Authorization: Bearer $new" "$header" || return 94
    [[ -f $payload && -n $output ]] || return 95
    if [[ ${HTTP_FAIL:-} == timeout ]]; then return 28; fi
    printf '{"success":true,"result":{"id":"record123"}}' > "$output"
    printf 200
  }
  caddy_token_request POST /zones/zone123/dns_records "$ROOT/payload.json" "$ROOT/response.json" > "$tmp/http-output" 2>&1
  [[ $(wc -l < "$tmp/curl.calls") == 1 && ! -s $tmp/http-output ]]
  if grep -Fq -e "$old" -e "$new" "$tmp/curl.argv" "$tmp/http-output"; then echo 'HTTP boundary exposed a Token'; exit 1; fi
  : > "$tmp/curl.calls"
  if HTTP_FAIL=timeout caddy_token_request POST /zones/zone123/dns_records "$ROOT/payload.json" "$ROOT/response.json" > "$tmp/http-output" 2>&1; then
    echo 'HTTP timeout accepted'; exit 1
  fi
  [[ $(wc -l < "$tmp/curl.calls") == 1 ]]
  # A missing credential must stop before curl, including inside if/! contexts.
  rm "$ROOT/state/caddy-token-change/candidate.token"
  : > "$tmp/curl.calls"
  if caddy_token_request POST /zones/zone123/dns_records "$ROOT/payload.json" "$ROOT/response.json" > "$tmp/http-output" 2>&1; then
    echo 'Missing HTTP credential accepted'; exit 1
  fi
  [[ ! -s $tmp/curl.calls ]]
)

# Invalid input and staging failures must leave both installed files untouched
# and must not reach either the API or Docker. Keep the platform permission
# shim above, because a Git Bash user cannot own files as Linux uid 0.
ROOT=$tmp/root TOKEN_FILE=$tmp/new-token
cp "$tmp/original.token" "$ROOT/config/cloudflare.token"
cp "$tmp/original.env" "$ROOT/config/caddy.env"
for bad_input in format mode; do
  printf '%s\n' "$new" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  case "$bad_input" in format) printf 'bad token\n' > "$TOKEN_FILE";; mode) chmod 644 "$TOKEN_FILE";; esac
  : > "$tmp/api.calls"; : > "$tmp/docker.calls"
  if (
    # Git Bash reports synthetic permissions and chmod cannot change them.
    # Linux CI uses the real 0644 file; only emulate stat on Windows here.
    case $(uname -s) in MINGW*|MSYS*)
      if [[ $bad_input == mode ]]; then
        stat() {
          if [[ $* == "-c %a $TOKEN_FILE" ]]; then printf '644\n'; else command stat "$@"; fi
        }
      fi;;
    esac
    replace_caddy_token
  ) > "$tmp/output" 2>&1; then echo "Accepted invalid $bad_input"; exit 1; fi
  assert_old
  [[ ! -s $tmp/api.calls ]] || { echo "Invalid $bad_input reached API"; exit 1; }
  [[ ! -s $tmp/docker.calls ]] || { echo "Invalid $bad_input reached Docker"; exit 1; }
  [[ ! -d $ROOT/state/caddy-token-change ]] || { echo "Invalid $bad_input retained transaction"; exit 1; }
  [[ -z $(find "$ROOT/state" -maxdepth 1 -name '.caddy-token-*' -print -quit) ]]
done
printf '%s\n' "$new" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"
: > "$tmp/stage-writes"; : > "$tmp/api.calls"; : > "$tmp/docker.calls"
if (
  # Both commands are called indirectly by caddy_token_stage.
  # shellcheck disable=SC2317,SC2329
  mktemp() { return 1; }
  # shellcheck disable=SC2317,SC2329
  cp() { printf 'copy attempted\n' >> "$tmp/stage-writes"; return 96; }
  replace_caddy_token
) > "$tmp/output" 2>&1; then echo 'Failed private staging accepted'; exit 1; fi
assert_old
[[ ! -s $tmp/stage-writes && ! -s $tmp/api.calls && ! -s $tmp/docker.calls && ! -d $ROOT/state/caddy-token-change ]]

# Restore the real layout guard while keeping harmless network/container mocks.
# The fixture contains current-format config files, then each conflicting state
# is introduced separately; none may trigger migration or a container command.
(
  # shellcheck source=/dev/null
  source ./install.sh
  ROOT=$tmp/root TOKEN_FILE=$tmp/new-token
  confirm() { return 0; }
  caddy_token_probe() { printf 'API attempted\n' >> "$tmp/guard.calls"; return 1; }
  # Unexpected indirect calls are recorded, rather than changing the host.
  # shellcheck disable=SC2317,SC2329
  dc() { printf 'container attempted\n' >> "$tmp/guard.calls"; return 1; }
  # shellcheck disable=SC2317,SC2329
  ensure_layout() { printf 'migration attempted\n' >> "$tmp/guard.calls"; return 1; }
  printf '{}\n' > "$ROOT/config/compose.yaml"
  printf ':80 {}\n' > "$ROOT/config/Caddyfile"
  for conflict in legacy progress update.json reinstall.json image-rollback.json token; do
    : > "$tmp/guard.calls"
    case "$conflict" in
      legacy) printf '{}\n' > "$ROOT/state.json";;
      progress) jq '.stage=6' "$ROOT/state/progress.json" > "$tmp/progress"; mv "$tmp/progress" "$ROOT/state/progress.json";;
      token) mkdir "$ROOT/state/caddy-token-change";;
      *) printf '{}\n' > "$ROOT/state/$conflict";;
    esac
    if (replace_caddy_token) > "$tmp/output" 2>&1; then echo "Accepted conflicting $conflict"; exit 1; fi
    [[ ! -s $tmp/guard.calls ]]
    assert_old
    case "$conflict" in
      legacy) grep -q '旧目录' "$tmp/output";;
      progress) grep -q '完成安装' "$tmp/output";;
      token) grep -q 'Token 替换待恢复' "$tmp/output";;
      *) grep -q '未完成的维护任务' "$tmp/output";;
    esac
    case "$conflict" in
      legacy) rm "$ROOT/state.json";;
      progress) checkpoint 7;;
      token) rmdir "$ROOT/state/caddy-token-change";;
      *) rm "$ROOT/state/$conflict";;
    esac
  done
)
echo 'PASS: private HTTP headers, no credential arguments/retries, rejected invalid inputs and conflicting tasks'
