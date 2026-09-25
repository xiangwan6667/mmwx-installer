#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT_DIR/install.sh"
scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT
ROOT=$scratch/root; mkdir -p "$ROOT/config"
assert_contains() { local out=$1 needle=$2; [[ $out == *"$needle"* ]] || { echo "missing: $needle" >&2; exit 1; }; }
fixture='{"type":"urn:ietf:params:acme:error:rateLimited","detail":"too many certificates already issued; retry-after: 2026-10-02T00:00:00Z"}'
rc=0; out=$(caddy_tls_diagnose "$fixture") || rc=$?
[[ $rc -eq 2 ]]; assert_contains "$out" 'ACME 证书签发速率限制'; assert_contains "$out" 'retry-after'; assert_contains "$out" '2026-10-02'
rc=0; out=$(caddy_tls_diagnose 'HTTP 429 from Cloudflare API while reading zone') || rc=$?
[[ $rc -eq 0 ]]; assert_contains "$out" '未在最近'
rc=0; out=$(caddy_tls_diagnose 'acme: authorization failed: DNS-01 challenge unauthorized invalid token') || rc=$?
[[ $rc -eq 1 ]]; assert_contains "$out" 'DNS-01 验证失败'
rc=0; out=$(caddy_tls_diagnose 'certificate handshake failed') || rc=$?
[[ $rc -eq 0 ]]; assert_contains "$out" '未在最近'
rc=0; out=$(caddy_tls_diagnose 'DNS-01 challenge completed successfully') || rc=$?
[[ $rc == 0 ]]
rc=0; out=$(caddy_tls_diagnose 'HTTP 429 urn:ietf:params:acme:error:rateLimited: too many certificates (5) already issued for this exact set of identifiers; retry after 2026-10-02 08:00:00 UTC') || rc=$?
[[ $rc == 2 ]]; assert_contains "$out" '相同域名集合'; assert_contains "$out" '2026-10-02 08:00:00'
printf 'secret-token-fixture\n' > "$ROOT/config/cloudflare.token"
rc=0; out=$(caddy_tls_diagnose 'DNS-01 failed invalid secret-token-fixture') || rc=$?
[[ $rc == 1 && $out != *secret-token-fixture* ]]
if grep -R secret-token-fixture "$ROOT/state/logs"; then echo 'TLS logs leaked token'; exit 1; fi
printf 'PASS: ACME rate limits and retry evidence distinguished from generic 429 and successful DNS; logs redacted\n'


# Exercise the actual HTTPS failure branches without waiting or network calls.
DOMAIN=panel.example.com
sleep() { :; }
curl() {
  if [[ ${PUBLIC_ONLY:-0} == 1 && $* == *--resolve* ]]; then return 0; fi
  echo fixture-connection-failed >&2; return 60
}
dc() { printf '%s\n' '{"type":"urn:ietf:params:acme:error:rateLimited","detail":"too many certificates for this exact set; retry after 2026-10-02 08:00:00 UTC"}'; }
trace_start install
if (verify_https) > "$scratch/https-failed" 2>&1; then echo 'Failed HTTPS passed'; exit 1; fi
grep -q '2026-10-02 08:00:00' "$scratch/https-failed"
grep -q 'CA 速率限制' "$TRACE_LOG"
if (PUBLIC_ONLY=1 verify_https) > "$scratch/public-failed" 2>&1; then exit 1; fi
grep -q '源站证书有效' "$scratch/public-failed"
if grep -q '证书申请触发' "$scratch/public-failed"; then echo 'Public network failure mislabeled as rate limit'; exit 1; fi
echo 'PASS: HTTPS failure surfaces CA rate limit; valid origin and failed public HTTPS stay distinct'
