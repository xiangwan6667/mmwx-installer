#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./install.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/sbin" "$tmp/bin"
# Exercise real file replacement in a private directory, never the host's commands.
# shellcheck disable=SC2016
eval "$(declare -f self_update | sed 's|/usr/local/sbin|"$tmp/sbin"|g; s|/usr/local/bin|"$tmp/bin"|g')"
get() { cp "$tmp/remote.sh" "${@: -1}"; }
# Download cleanup has its own tests; this fixture never inspects /root.
cleanup_downloads() { :; }
cp ./install.sh "$tmp/remote.sh"
cp ./install.sh "$tmp/sbin/mmwx-installer"
ln "$tmp/sbin/mmwx-installer" "$tmp/original"
ln -s "$tmp/sbin/mmwx-installer" "$tmp/bin/mmwx"

self_update > "$tmp/output"
grep -q '已经是最新版' "$tmp/output" || { echo 'Current script reported an update'; exit 1; }
[[ $tmp/sbin/mmwx-installer -ef $tmp/original ]] || { echo 'Current script was unnecessarily replaced'; exit 1; }

# A changed script must still update, even if its declared version was not bumped.
printf '\n# Remote maintenance change\n' >> "$tmp/remote.sh"
self_update > "$tmp/output"
grep -q '管理脚本已更新' "$tmp/output"
cmp -s "$tmp/remote.sh" "$tmp/sbin/mmwx-installer"
[[ ! $tmp/sbin/mmwx-installer -ef $tmp/original ]]

# Repeating the update is a no-op, and repairs a missing management symlink.
ln "$tmp/sbin/mmwx-installer" "$tmp/updated"
rm "$tmp/bin/mmwx"
self_update > "$tmp/output"
grep -q '已经是最新版' "$tmp/output"
[[ $tmp/sbin/mmwx-installer -ef $tmp/updated && -L $tmp/bin/mmwx ]]
[[ $(readlink "$tmp/bin/mmwx") == "$tmp/sbin/mmwx-installer" ]]
echo 'PASS: current script is not replaced; changed script updates; missing command is repaired'
