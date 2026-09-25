#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./install.sh
# Native Windows jq otherwise writes CRLF into Bash's line-oriented input.
case $(uname -s) in MINGW*|MSYS*) jq() { command jq -b "$@"; };; esac
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ROOT=$tmp
mkdir -p "$ROOT/config" "$ROOT/state"
cat > "$tmp/releases" <<'EOF'
[
 {"tag_name":"v3","prerelease":false,"draft":false,"published_at":"2026-09-23"},
 {"tag_name":"v2","prerelease":false,"draft":false,"published_at":"2026-09-22"},
 {"tag_name":"v1","prerelease":false,"draft":false,"published_at":"2026-09-21"},
 {"tag_name":"v4-beta.3","prerelease":true,"draft":false,"published_at":"2026-09-25"},
 {"tag_name":"v4-beta.2","prerelease":true,"draft":false,"published_at":"2026-09-24"}
]
EOF
fetch_releases() { cat "$tmp/releases"; }
# Only the external registry is simulated; selection and confirmations stay real.
check_app_image() {
  local status
  printf '%s\n' "$1" >> "$tmp/checked"
  status=$(jq -r --arg tag "$1" '.[$tag][0] // 0' "$tmp/status")
  jq --arg tag "$1" 'if (.[$tag]|length)>1 then .[$tag]=.[$tag][1:] else . end' "$tmp/status" > "$tmp/next"
  mv "$tmp/next" "$tmp/status"
  return "$status"
}
ask() {
  local answer
  printf '%s\n' "$1" >> "$tmp/prompts"
  IFS= read -r answer < "$tmp/answers"
  tail -n +2 "$tmp/answers" > "$tmp/next-answer"
  mv "$tmp/next-answer" "$tmp/answers"
  printf '%s' "$answer"
}
# Invoked indirectly by run_step.
# shellcheck disable=SC2317,SC2329
docker() {
  case "$1" in
    pull) printf '%s\n' "$2" >> "$tmp/pulls";;
    image) printf 'app@sha256:%s\n' "$VERSION";;
    *) return 1;;
  esac
}
reset_case() {
  CHANNEL=stable CHANNEL_EXPLICIT=1 ACTION=install ACCEPT=0 VERSION='' APP_IMAGE=''
  printf '{}' > "$tmp/status"
  : > "$tmp/answers"; : > "$tmp/checked"; : > "$tmp/pulls"; : > "$tmp/prompts"
}

reset_case
printf '{"v3":[10]}' > "$tmp/status"
printf 'y\n' > "$tmp/answers"
choose_version > "$tmp/output"
[[ $VERSION == v2 && $(cat "$tmp/pulls") == ghcr.io/iluobei/miaomiaowux:2 ]] || { echo 'Missing latest image did not offer the previous stable version'; exit 1; }
grep -q 'y/n' "$tmp/prompts"
[[ $(cat "$tmp/checked") == $'v3\nv2' ]]

reset_case
CHANNEL=beta
printf '{"v4-beta.3":[11]}' > "$tmp/status"
printf 'y\n' > "$tmp/answers"
choose_version > "$tmp/output"
[[ $VERSION == v4-beta.2 && $(cat "$tmp/checked") == $'v4-beta.3\nv4-beta.2' ]]

reset_case
printf '{"v3":[10],"v2":[11]}' > "$tmp/status"
printf 'n\n' > "$tmp/answers"
if choose_version > "$tmp/output"; then echo 'Declined fallback was accepted'; exit 1; fi
[[ ! -s $tmp/pulls && $(cat "$tmp/checked") == $'v3\nv2\nv1' ]]

reset_case
printf '{"v3":[20]}' > "$tmp/status"
if (choose_version) > "$tmp/output" 2>&1; then echo 'Registry failure accepted'; exit 1; fi
[[ $(cat "$tmp/checked") == v3 && ! -s $tmp/pulls && ! -s $tmp/prompts ]]
grep -q '网络\|限流\|鉴权' "$tmp/output"

# Explicit selection retries the same version, with no fallback prompt or image change.
reset_case
CHANNEL=''
printf '{"v3":[10,0]}' > "$tmp/status"
printf '3\n1\n1\n1\n' > "$tmp/answers"
choose_version > "$tmp/output"
[[ $VERSION == v3 && $(cat "$tmp/checked") == $'v3\nv3' ]]
[[ $(cat "$tmp/pulls") == ghcr.io/iluobei/miaomiaowux:3 ]]

reset_case
CHANNEL=''
printf '{"v3":[10]}' > "$tmp/status"
printf '3\n1\n1\n2\n1\n2\n' > "$tmp/answers"
choose_version > "$tmp/output"
[[ $VERSION == v2 && $(cat "$tmp/checked") == $'v3\nv2' ]]

reset_case
CHANNEL=''
printf '{"v3":[10]}' > "$tmp/status"
printf '3\n1\n1\n0\n' > "$tmp/answers"
if choose_version > "$tmp/output"; then echo 'Explicit cancellation was accepted'; exit 1; fi
[[ ! -s $tmp/pulls && $(cat "$tmp/checked") == v3 ]]

# A registry error in an older candidate must stop, not skip to another image.
reset_case
printf '{"v3":[10],"v2":[20]}' > "$tmp/status"
if (choose_version) > "$tmp/output" 2>&1; then echo 'Candidate registry error accepted'; exit 1; fi
[[ $(cat "$tmp/checked") == $'v3\nv2' && ! -s $tmp/pulls ]]

# Only the five recent releases are eligible, even if the sixth has an image.
reset_case
cp "$tmp/releases" "$tmp/original-releases"
jq '. + [
  {tag_name:"v0.9",prerelease:false,draft:false,published_at:"2026-09-20"},
  {tag_name:"v0.8",prerelease:false,draft:false,published_at:"2026-09-19"},
  {tag_name:"v0.7",prerelease:false,draft:false,published_at:"2026-09-18"}
]' "$tmp/releases" > "$tmp/more-releases"
mv "$tmp/more-releases" "$tmp/releases"
printf '{"v3":[10],"v2":[10],"v1":[11],"v0.9":[10],"v0.8":[10]}' > "$tmp/status"
if (choose_version) > "$tmp/output" 2>&1; then echo 'No recent image was accepted'; exit 1; fi
[[ $(cat "$tmp/checked") == $'v3\nv2\nv1\nv0.9\nv0.8' && ! -s $tmp/pulls ]]
mv "$tmp/original-releases" "$tmp/releases"

# A missing terminal is an error, never an implicit Enter selecting a release.
reset_case
if (
  ACTION=update CHANNEL_EXPLICIT=0
  ask() { return 1; }
  choose_version
) > "$tmp/output" 2>&1; then echo 'Failed prompt silently chose a version'; exit 1; fi
[[ ! -s $tmp/pulls ]]

# A fallback to the already running digest must not back up or stop the service.
reset_case
printf '{"v3":[10]}' > "$tmp/status"
printf 'y\n' > "$tmp/answers"
preflight() { :; }
install_command() { :; }
configure_timezone() { :; }
load_state() { VERSION=v2; APP_IMAGE=app@sha256:v2; CHANNEL=stable; }
dc() { echo 'Service was touched unexpectedly' >&2; exit 90; }
update_stack > "$tmp/output"
[[ -z $(find "$ROOT/backups" -mindepth 1 -print -quit) && ! -f $ROOT/state/update.json ]]
grep -q '当前.*版本\|无需更新' "$tmp/output"

# Cancellation is success at the menu level; a failed digest read must remain an error.
reset_case
if (
  docker() { [[ $1 != image ]]; }
  update_stack
) > "$tmp/output" 2>&1; then echo 'Failed image inspection was mistaken for cancellation'; exit 1; fi
[[ ! -f $ROOT/state/update.json ]]
echo 'PASS: same-channel fallback needs consent, explicit selection retries/reselects, registry errors stop, current version stays running'
