#!/usr/bin/env bash
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."
source ./install.sh
source_path=$PWD/install.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
tmp=$(cd "$tmp" && pwd -P)
host=$tmp/host
ROOT=$host/opt/mmwx-installer

# Exercise the actual deletion paths, with every host path confined to this fixture.
for operation in remove_services purge_installation uninstall_script; do
  # shellcheck disable=SC2016
  eval "$(declare -f "$operation" | sed 's|/opt/mmwx-installer|$host/opt/mmwx-installer|g; s|/usr/local/|$host/usr/local/|g; s|/etc/systemd/|$host/etc/systemd/|g; s|/var/lib/systemd/|$host/var/lib/systemd/|g; s|/run/mmwx-cf.lock|$host/cf.lock|g')"
done
# Preserve the downloaded-script signature check while redirecting its fixed path.
# shellcheck disable=SC2016
eval "$(declare -f cleanup_downloads | sed 's|/root/mmwx-install.sh|$host/root/mmwx-install.sh|g')"
cd "$tmp"
ask() { printf '%s' "$CHOICE"; }
confirm() { printf '%s\n' "$1" >> "$tmp/prompts"; [[ $ANSWER == y ]]; }
dc() { [[ $* == 'down --remove-orphans' ]] || return 1; printf 'removed\n' >> "$tmp/calls"; }
systemctl() { case "$1" in show) echo not-found;; is-active) return 3;; disable) return 42;; *) :;; esac; }
flock() { :; }
iptables() { return 1; }
ipset() { return 1; }
remove_legacy_cf_rules() { :; }
network_restore_preflight() { echo checked >> "$tmp/network-calls"; [[ ${RESTORE_FAIL:-} != preflight ]]; }
restore_install_network() { echo restored >> "$tmp/network-calls"; [[ ${RESTORE_FAIL:-} != restore ]]; }
docker() { [[ $* == 'image rm mmwx-installer-caddy:2.11.4-cf0.2.4' ]]; }
# Match the supported root execution while keeping all filesystem operations real.
stat() { printf '0\n'; }

prepare_installation() {
  mkdir -p "$ROOT/config" "$ROOT/state" "$host/usr/local/bin" "$host/usr/local/sbin" \
    "$host/usr/local/lib/mmwx-installer" "$host/etc/systemd/system/docker.service.d" "$host/root"
  printf '{}' > "$ROOT/state/state.json"
  printf 'compose' > "$ROOT/config/compose.yaml"
  printf 'data-to-keep' > "$ROOT/sentinel"
  cp "$source_path" "$host/usr/local/sbin/mmwx-installer"
  chmod +x "$host/usr/local/sbin/mmwx-installer"
  ln -sf "$host/usr/local/sbin/mmwx-installer" "$host/usr/local/bin/mmwx"
  cp "$source_path" "$host/usr/local/lib/mmwx-installer/runtime.sh"
  cp "$source_path" "$host/root/mmwx-install.sh"
  touch "$host/etc/systemd/system/docker.service.d/mmwx-firewall.conf" \
    "$host/etc/systemd/system/mmwx-firewall.service" \
    "$host/etc/systemd/system/mmwx-cf-sync.service" "$host/etc/systemd/system/mmwx-cf-sync.timer" \
    "$host/etc/systemd/system/mmwx-network-rollback.service" "$host/etc/systemd/system/mmwx-network-rollback.timer"
  SELF=$host/usr/local/sbin/mmwx-installer
  : > "$tmp/calls"
  : > "$tmp/network-calls"
}
assert_manager_retained() {
  [[ -f $SELF && -x $SELF && -L $host/usr/local/bin/mmwx ]] || {
    echo 'Service uninstall removed the management command or active menu script'; exit 1;
  }
  [[ $(readlink "$host/usr/local/bin/mmwx") == "$SELF" ]]
  bash "$host/usr/local/bin/mmwx" --version | grep -q '^mmwx-installer '
}

prepare_installation
CHOICE='' ANSWER=y
uninstall_stack > "$tmp/output"
[[ $(cat "$tmp/calls") == removed && $(cat "$ROOT/sentinel") == data-to-keep ]]
[[ ! -e $host/etc/systemd/system/mmwx-cf-sync.timer ]]
assert_manager_retained
[[ ! -s $tmp/network-calls ]]

: > "$tmp/calls"
CHOICE=2 ANSWER=n
uninstall_stack > "$tmp/output"
[[ ! -s $tmp/calls && -f $ROOT/sentinel ]]
assert_manager_retained

CHOICE=2 ANSWER=y
if (RESTORE_FAIL=preflight uninstall_stack) > "$tmp/output" 2>&1; then echo 'Missing network backup accepted'; exit 1; fi
[[ ! -s $tmp/calls && -f $ROOT/sentinel ]]
if (RESTORE_FAIL=restore uninstall_stack) > "$tmp/output" 2>&1; then echo 'Failed restoration accepted'; exit 1; fi
[[ -f $ROOT/sentinel ]]
assert_manager_retained
: > "$tmp/calls"; : > "$tmp/network-calls"
uninstall_stack > "$tmp/output"
[[ $(cat "$tmp/calls") == removed && ! -e $ROOT ]]
[[ $(cat "$tmp/network-calls") == $'checked\nrestored' ]]
[[ ! -e $host/etc/systemd/system/mmwx-network-rollback.service && ! -e $host/etc/systemd/system/mmwx-network-rollback.timer ]]
[[ ! -e $host/usr/local/lib/mmwx-installer/runtime.sh && ! -e $host/root/mmwx-install.sh ]]
grep -q '永久删除' "$tmp/prompts"
assert_manager_retained

# The explicit script-only action remains the only way to remove the manager.
prepare_installation
# Cancelling a legacy-layout uninstall must not migrate or start anything.
mv "$ROOT/config/compose.yaml" "$ROOT/compose.yaml"
mv "$ROOT/state/state.json" "$ROOT/state.json"
ensure_layout() { echo unexpected-migration >> "$tmp/calls"; return 1; }
CHOICE=2 ANSWER=n
uninstall_stack > "$tmp/output"
[[ ! -s $tmp/calls && -f $ROOT/state.json && -f $ROOT/compose.yaml ]]
rm -f "$host/etc/systemd/system/mmwx-cf-sync.timer" "$host/etc/systemd/system/docker.service.d/mmwx-firewall.conf"
ANSWER=y
uninstall_script > "$tmp/output"
[[ ! -e $host/usr/local/bin/mmwx && ! -e $SELF && ! -e $host/root/mmwx-install.sh ]]
[[ $(cat "$ROOT/sentinel") == data-to-keep && -f $host/usr/local/lib/mmwx-installer/runtime.sh ]]
echo 'PASS: service retention and purge keep a working manager; only script uninstall removes it'
