#!/usr/bin/env bash
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."
source ./install.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
host=$tmp/host
ROOT=$host/opt/mmwx-installer
for operation in network_backup_path network_backup_validate network_backup_capture network_restore_preflight restore_install_network; do
  declare -F "$operation" >/dev/null || { echo "Missing network recovery helper: $operation"; exit 1; }
  # Redirect actual filesystem boundaries; keep copying, validation and recovery real.
  # shellcheck disable=SC2016
  eval "$(declare -f "$operation" | sed 's|/etc/ufw|$host/etc/ufw|g; s|/etc/default/ufw|$host/etc/default/ufw|g; s|/etc/sysctl.d/90-mmwx-ipv4-only.conf|$host/etc/sysctl.d/90-mmwx-ipv4-only.conf|g; s|/proc/sys/net/ipv6/conf|$host/proc/sys/net/ipv6/conf|g; s|/run/mmwx-network.lock|$host/network.lock|g')"
done
flock() { :; }
ufw() {
  case "$*" in
    status) printf 'Status: %s\n' "$(cat "$host/ufw-running")";;
    disable|'--force disable') echo inactive > "$host/ufw-running";;
    '--force enable') [[ ! -e $host/fail-ufw ]] || return 42; echo active > "$host/ufw-running";;
    *) echo "Unexpected ufw command: $*" >&2; return 1;;
  esac
}
sysctl() {
  local key=${2%%=*} value=${2#*=} interface
  [[ $key == */* ]] || key=${key//./\/}
  interface=${key#net/ipv6/conf/}; interface=${interface%/disable_ipv6}
  [[ ! -e $host/fail-sysctl ]] || return 42
  case "$1" in
    -n) cat "$host/proc/sys/net/ipv6/conf/$interface/disable_ipv6";;
    -w)
      if [[ $interface == all ]]; then
        for file in "$host"/proc/sys/net/ipv6/conf/*/disable_ipv6; do printf '%s\n' "$value" > "$file"; done
      fi
      printf '%s\n' "$value" > "$host/proc/sys/net/ipv6/conf/$interface/disable_ipv6";;
    *) return 1;;
  esac
}
fixture() {
  rm -rf "$host"
  mkdir -p "$ROOT/state" "$host/etc/ufw/applications.d" "$host/etc/default" "$host/etc/sysctl.d"
  local file interface
  for file in ufw.conf user.rules user6.rules before.rules before6.rules after.rules after6.rules; do
    printf 'original %s\n' "$file" > "$host/etc/ufw/$file"
  done
  printf 'IPV6=yes\nDEFAULT_INPUT_POLICY="ACCEPT"\n' > "$host/etc/default/ufw"
  printf 'original-sysctl\n' > "$host/etc/sysctl.d/90-mmwx-ipv4-only.conf"
  for interface in all default lo eth0 eth1 vlan.100; do
    mkdir -p "$host/proc/sys/net/ipv6/conf/$interface"
    printf '0\n' > "$host/proc/sys/net/ipv6/conf/$interface/disable_ipv6"
  done
  printf '1\n' > "$host/proc/sys/net/ipv6/conf/eth1/disable_ipv6"
  printf '1\n' > "$host/proc/sys/net/ipv6/conf/vlan.100/disable_ipv6"
  printf '%s\n' "${1:-active}" > "$host/ufw-running"
}
mutate_network() {
  printf 'confirmed\n' > "$ROOT/state/network-backup/state"
  printf 'installer-rules\n' > "$host/etc/ufw/user.rules"
  printf 'new-file\n' > "$host/etc/ufw/extra-rules"
  printf 'IPV6=no\n' > "$host/etc/default/ufw"
  printf 'installer-sysctl\n' > "$host/etc/sysctl.d/90-mmwx-ipv4-only.conf"
  sysctl -w net.ipv6.conf.all.disable_ipv6=1
  printf 'active\n' > "$host/ufw-running"
}
assert_restored() {
  [[ $(cat "$host/etc/ufw/user.rules") == 'original user.rules' && ! -e $host/etc/ufw/extra-rules ]]
  [[ $(cat "$host/etc/default/ufw") == $'IPV6=yes\nDEFAULT_INPUT_POLICY="ACCEPT"' ]]
  [[ $(cat "$host/proc/sys/net/ipv6/conf/all/disable_ipv6") == 0 ]]
  [[ $(cat "$host/proc/sys/net/ipv6/conf/default/disable_ipv6") == 0 ]]
  [[ $(cat "$host/proc/sys/net/ipv6/conf/lo/disable_ipv6") == 0 ]]
  [[ $(cat "$host/proc/sys/net/ipv6/conf/eth0/disable_ipv6") == 0 ]]
  [[ $(cat "$host/proc/sys/net/ipv6/conf/eth1/disable_ipv6") == 1 ]]
  [[ $(cat "$host/proc/sys/net/ipv6/conf/vlan.100/disable_ipv6") == 1 ]]
  [[ $(cat "$ROOT/state/network-backup/state") == restored ]]
}

# Full restore preserves mixed interface values, all original files, and initial active state.
fixture
network_backup_capture
mutate_network
network_backup_capture
network_restore_preflight
restore_install_network
assert_restored
[[ $(cat "$host/ufw-running") == active ]]
[[ $(cat "$host/etc/sysctl.d/90-mmwx-ipv4-only.conf") == original-sysctl ]]

# Initially inactive UFW stays inactive and an installer-created sysctl file is removed.
fixture inactive
rm "$host/etc/sysctl.d/90-mmwx-ipv4-only.conf"
network_backup_capture
mutate_network
restore_install_network
assert_restored
[[ $(cat "$host/ufw-running") == inactive && ! -e $host/etc/sysctl.d/90-mmwx-ipv4-only.conf ]]

# Legacy snapshots can restore only their recorded global/default/loopback values.
fixture
network_backup_capture
rm "$ROOT/state/network-backup/ipv6-interfaces.tsv" "$ROOT/state/network-backup/sysctl-present" \
  "$ROOT/state/network-backup/sysctl-original" "$ROOT/state/network-backup/format"
mutate_network
restore_install_network > "$tmp/legacy-output"
[[ $(cat "$host/proc/sys/net/ipv6/conf/lo/disable_ipv6") == 0 ]]
[[ ! -e $host/etc/sysctl.d/90-mmwx-ipv4-only.conf ]]
grep -q '旧版' "$tmp/legacy-output"
mkdir -p "$ROOT/network-backup"
cp -a "$ROOT/state/network-backup/." "$ROOT/network-backup/"
rm -rf "$ROOT/state/network-backup"
printf '{}' > "$ROOT/state.json"
printf 'confirmed\n' > "$ROOT/network-backup/state"
restore_install_network > "$tmp/legacy-output"
[[ $(cat "$ROOT/network-backup/state") == restored ]]

# Missing/corrupt snapshots block before any UFW or sysctl writes.
fixture
rm "$host/etc/sysctl.d/90-mmwx-ipv4-only.conf"
network_restore_preflight
printf '{}' > "$ROOT/state/state.json"
if (network_restore_preflight) > "$tmp/error" 2>&1; then echo 'Missing backup accepted'; exit 1; fi
[[ $(cat "$host/ufw-running") == active ]]
network_backup_capture
printf '2\n' > "$ROOT/state/network-backup/ipv6-lo"
if (restore_install_network) > "$tmp/error" 2>&1; then echo 'Corrupt snapshot accepted'; exit 1; fi
[[ $(cat "$host/ufw-running") == active && $(cat "$host/proc/sys/net/ipv6/conf/eth1/disable_ipv6") == 1 ]]

# Partial recovery does not claim success; the complete original snapshot remains retryable.
fixture
network_backup_capture
mutate_network
touch "$host/fail-sysctl"
if (restore_install_network) > "$tmp/error" 2>&1; then echo 'Failed recovery accepted'; exit 1; fi
[[ $(cat "$ROOT/state/network-backup/state") != restored && -f $ROOT/state/network-backup/ufw-default ]]
rm "$host/fail-sysctl"
restore_install_network
assert_restored
mutate_network
touch "$host/fail-ufw"
if (restore_install_network) > "$tmp/error" 2>&1; then echo 'Failed UFW activation accepted'; exit 1; fi
[[ $(cat "$ROOT/state/network-backup/state") != restored ]]
rm "$host/fail-ufw"
restore_install_network
assert_restored

# Installation progress after networking also proves mutation even if state.json is absent.
fixture
rm "$host/etc/sysctl.d/90-mmwx-ipv4-only.conf"
printf '{"stage":6}\n' > "$ROOT/state/progress.json"
if (network_restore_preflight) > "$tmp/error" 2>&1; then echo 'Missing network backup accepted after stage 6'; exit 1; fi
rm "$ROOT/state/progress.json"

# Failure before publication cannot leave a snapshot that a later run mistakes for complete.
printf '2\n' > "$host/proc/sys/net/ipv6/conf/eth0/disable_ipv6"
if (network_backup_capture) > "$tmp/error" 2>&1; then echo 'Invalid interface value captured'; exit 1; fi
[[ ! -e $ROOT/state/network-backup ]]
[[ -z $(find "$ROOT/state" -name '.network-backup.*' -print -quit) ]]

# A partial modern snapshot never falls back to the less strict legacy format.
fixture
network_backup_capture
rm "$ROOT/state/network-backup/sysctl-present"
if (network_restore_preflight) > "$tmp/error" 2>&1; then echo 'Partial modern snapshot accepted as legacy'; exit 1; fi

echo 'PASS: network snapshots restore UFW, IPv6 and original sysctl files; corrupt snapshots and retryable failures fail closed'
