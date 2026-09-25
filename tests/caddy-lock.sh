#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./install.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ROOT=$tmp/root
mkdir -p "$ROOT/state" "$ROOT/config" "$tmp/runtime"
for file in compose.yaml Caddyfile cloudflare.token caddy.env; do touch "$ROOT/config/$file"; done
DOMAIN=mmwx.example.com CHANNEL=stable VERSION=v1 APP_IMAGE=app CADDY_IMAGE=caddy PG_IMAGE=pg
save_state; checkpoint 7
printf 'old runtime' > "$tmp/runtime/runtime.sh"
# Only redirect the machine-global lock/runtime paths. Exercise actual dispatch.
# shellcheck disable=SC2016
eval "$(declare -f main | sed 's|/run/mmwx-installer.lock|$tmp/maintenance.lock|g; s|\$EUID|0|g')"
# shellcheck disable=SC2016
eval "$(declare -f caddy_lock_cf | sed 's|/run/mmwx-cf.lock|$tmp/cf.lock|g')"
# shellcheck disable=SC2016
eval "$(declare -f caddy_refresh_runtime | sed 's|/usr/local/lib/mmwx-installer|$tmp/runtime|g')"
# shellcheck disable=SC2016
eval "$(declare -f sync_cf | sed 's|/run/mmwx-cf.lock|$tmp/cf.lock|g')"
flock() { printf '%s\n' "$*" >> "$tmp/locks"; [[ ${BUSY:-} != "${*: -1}" ]]; }
caddy_action() { printf '%s\n' "$1" >> "$tmp/actions"; }
for action in caddy-reload caddy-restart caddy-token caddy-domain; do
  (
    replace_caddy_token() { echo token >> "$tmp/actions"; }
    change_caddy_domain() { echo domain >> "$tmp/actions"; }
    : > "$tmp/locks"; : > "$tmp/actions"
    main "$action"
    [[ $(cat "$tmp/locks") == $'-n 7\n-w 180 8' ]]
    [[ -s $tmp/actions ]]
    cmp "$SELF" "$tmp/runtime/runtime.sh"
  )
  for busy in 7 8; do
    : > "$tmp/actions"
    if (BUSY=$busy main "$action") > "$tmp/output" 2>&1; then echo 'Busy lock accepted'; exit 1; fi
    [[ ! -s $tmp/actions ]]
  done
done
(
  change_caddy_domain() { [[ $CADDY_DOMAIN_TARGET == new.example.com && $DOMAIN == mmwx.example.com ]]; }
  main caddy-domain --domain new.example.com
)
# A staged token operation blocks conflicting work, including the old timer.
mkdir "$ROOT/state/caddy-token-change"
for operation in install_stack update_stack reinstall_stack rollback_stack uninstall_stack; do
  if ("$operation") > "$tmp/output" 2>&1; then echo "Pending token allowed $operation"; exit 1; fi
done
: > "$tmp/actions"
fetch_cf() { echo fetched >> "$tmp/actions"; return 1; }
sync_cf > "$tmp/output"
[[ ! -s $tmp/actions ]]
if (main caddy-reload) > "$tmp/output" 2>&1; then echo 'Pending token allowed reload'; exit 1; fi
rm -r "$ROOT/state/caddy-token-change"
for task in update.json reinstall.json image-rollback.json; do
  printf '{}' > "$ROOT/state/$task"
  if (main caddy-restart) > "$tmp/output" 2>&1; then echo 'Pending task allowed Caddy write'; exit 1; fi
  rm "$ROOT/state/$task"
done
# Legacy Caddy actions must not call the whole-stack migration helper.
printf '{}' > "$ROOT/state.json"
ensure_layout() { echo migration >> "$tmp/actions"; }
if (main caddy-reload) > "$tmp/output" 2>&1; then echo 'Legacy Caddy write accepted'; exit 1; fi
[[ ! -s $tmp/actions ]]
rm "$ROOT/state.json"
# Menu 5 token recovery must return without taking the full-stack resume branch.
mkdir "$ROOT/state/caddy-token-change"
recover_caddy_token() { echo token-recovered >> "$tmp/actions"; }
resume_task > "$tmp/output"
[[ $(cat "$tmp/actions") == token-recovered ]]
rm -r "$ROOT/state/caddy-token-change"
mkdir "$ROOT/state/caddy-domain-change"
for operation in install_stack update_stack reinstall_stack rollback_stack uninstall_stack replace_caddy_token; do
  if ("$operation") > "$tmp/output" 2>&1; then echo "Pending domain allowed $operation"; exit 1; fi
done
: > "$tmp/actions"
sync_cf > "$tmp/output"
[[ ! -s $tmp/actions ]]
if (main caddy-reload) > "$tmp/output" 2>&1; then echo 'Pending domain allowed reload'; exit 1; fi
recover_caddy_domain() { echo domain-recovered >> "$tmp/actions"; }
resume_task > "$tmp/output"
[[ $(cat "$tmp/actions") == domain-recovered ]]
echo 'PASS: ordered maintenance/CF locks, pending-task guards, legacy isolation, runtime refresh and token-only resume'
