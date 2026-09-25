#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./install.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ROOT=$tmp
if (
  install_command() { :; }
  install_stack() { echo unsafe-install > "$ROOT/unexpected"; }
  resume_task
) >/dev/null 2>&1; then echo 'Resume on fresh host accepted'; exit 1; fi
[[ ! -f $ROOT/unexpected ]]
DOMAIN=panel.example.com CHANNEL=stable VERSION=v1 APP_IMAGE=app:v1 CADDY_IMAGE=caddy:test
printf 'test-token' > "$ROOT/cloudflare.token"
prepare_secrets
first=$(cat "$ROOT/postgres.env")
rm "$ROOT/app.env"
prepare_secrets
[[ $(cat "$ROOT/postgres.env") == "$first" ]]
[[ $(cut -d= -f2 "$ROOT/app.env") == "${first#*=}" ]]
checkpoint 3
DOMAIN='' CHANNEL='' VERSION=''
load_progress
[[ $STAGE == 3 && $DOMAIN == panel.example.com && $CHANNEL == stable && $VERSION == v1 ]]
# Real install orchestration with mocked host operations: interrupt after selected image,
# then resume without querying DNS/releases again or rotating credentials.
cat > "$tmp/harness.sh" <<'EOF'
set -euo pipefail
source ./install.sh
ROOT=$TEST_ROOT
preflight() { :; }
install_command() { :; }
configure_timezone() { :; }
# Git Bash cannot apply Linux directory modes; Linux CI uses real install.
case $(uname -s) in MINGW*|MSYS*) install() { mkdir -p "${@: -1}"; };; esac
install_docker() { :; }
dns_check() { echo unexpected-dns >> "$ROOT/calls"; exit 90; }
choose_version() { echo unexpected-version >> "$ROOT/calls"; exit 91; }
build_caddy() { [[ $PHASE != interrupted ]] || exit 42; CADDY_IMAGE=caddy:test; }
docker() { [[ $1 != image ]] || printf 'postgres@sha256:test\n'; }
dc() { :; }
network_setup() { echo network-checked >> "$ROOT/calls"; }
verify_https() { :; }
install_stack
EOF
if TEST_ROOT=$tmp PHASE=interrupted bash "$tmp/harness.sh" >/dev/null; then echo 'Interruption not propagated'; exit 1; else [[ $? == 42 ]]; fi
[[ $(jq -r .stage "$ROOT/progress.json") == 3 ]]
TEST_ROOT=$tmp PHASE=resume bash "$tmp/harness.sh" >/dev/null
[[ $(jq -r .stage "$ROOT/progress.json") == 7 ]]
[[ $(cat "$ROOT/postgres.env") == "$first" ]]
[[ $(cat "$ROOT/calls") == network-checked ]]
echo 'PASS: interrupted install resumes, preserves credentials and rechecks networking'
