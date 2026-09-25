#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./install.sh
fixture='[{"tag_name":"v9-beta.1","prerelease":true,"draft":false,"published_at":"2026-09-03T00:00:00Z"},{"tag_name":"v8","prerelease":false,"draft":false,"published_at":"2026-09-02T00:00:00Z"},{"tag_name":"v10","prerelease":false,"draft":true,"published_at":"2026-09-04T00:00:00Z"}]'
[[ $(printf '%s' "$fixture" | select_release stable | jq -r .tag_name) == v8 ]]
[[ $(printf '%s' "$fixture" | select_release beta | jq -r .tag_name) == v9-beta.1 ]]
if printf '[]' | select_release beta >/dev/null; then echo 'Empty channel accepted'; exit 1; fi
valid_domain panel.example.com
for bad in 'x;touch /tmp/pwn' '*.example.com' 'https://example.com' '-bad.example.com' 'localhost'; do
  if valid_domain "$bad"; then echo "Unsafe domain accepted: $bad"; exit 1; fi
done
[[ $(printf '{"result":[]}' | dns_record_action 203.0.113.9) == create ]]
[[ $(printf '{"result":[{"type":"A","content":"203.0.113.9","proxied":true}]}' | dns_record_action 203.0.113.9) == keep ]]
if printf '{"result":[{"type":"A","content":"203.0.113.8","proxied":true}]}' | dns_record_action 203.0.113.9 2>/dev/null; then echo 'Conflicting DNS accepted'; exit 1; fi
printf '173.245.48.0/20\n104.16.0.0/13\n' | validate_cidrs
for bad in '0.0.0.0/0' '127.0.0.1/32' '::/0' 'garbage'; do
  if printf '%s\n' "$bad" | validate_cidrs 2>/dev/null; then echo "Unsafe network accepted: $bad"; exit 1; fi
done
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
DOMAIN=panel.example.com APP_IMAGE=example/app@sha256:abc CADDY_IMAGE=example/caddy@sha256:def PG_IMAGE=postgres:18-alpine
render_compose > "$tmp/compose.yaml"
render_caddy > "$tmp/Caddyfile"
if command -v docker >/dev/null; then
  printf 'CF_API_TOKEN=test-only\n' > "$tmp/caddy.env"
  printf 'MMWX_DATABASE_PASSWORD=test-only\n' > "$tmp/app.env"
  printf 'POSTGRES_PASSWORD=test-only\n' > "$tmp/postgres.env"
  docker compose -f "$tmp/compose.yaml" config --format json > "$tmp/config.json"
  jq -e '.services.mmwx.ports == null and .services.postgres.ports == null and (.services.caddy.ports | length == 2) and .networks.database.internal == true' "$tmp/config.json" >/dev/null
fi
echo 'PASS: channel selection, unsafe input rejection, network validation, configuration rendering'
