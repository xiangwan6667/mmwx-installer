#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./install.sh
scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT
ROOT=$scratch/root
# Module-first plus enough trailing output reproduces grep -q closing the pipe.
docker() {
  case ${MODE:-large} in
    missing) printf 'other.module\n';;
    failed) printf 'dns.providers.cloudflare\n'; echo 'daemon failure' >&2; return 125;;
    *) printf 'dns.providers.cloudflare\n'; for ((i=0;i<12000;i++)); do printf 'extra.module.%s padding-padding-padding\n' "$i"; done;;
  esac
}
if (docker run --rm --network none fixture caddy list-modules | grep -qx dns.providers.cloudflare) > "$scratch/old" 2>&1; then
  echo 'Fixture failed to reproduce early pipe closure'; exit 1
fi
run_step '验证模块' verify_caddy_module fixture > "$scratch/output"
grep -q 'extra.module.11999' "$ROOT"/state/logs/*.log
if MODE=missing run_step '缺少模块' verify_caddy_module fixture > "$scratch/missing" 2>&1; then exit 1; else [[ $? == 1 ]]; fi
if MODE=failed run_step '执行失败' verify_caddy_module fixture > "$scratch/failed" 2>&1; then exit 1; else [[ $? == 2 ]]; fi
grep -q 'daemon failure' "$scratch/failed"
echo 'PASS: old probe reproduces SIGPIPE; full module output is consumed and Docker failures remain failures'
