#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./install.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/sbin" "$tmp/bin"
# Exercise real file replacement in a private directory, never the host's commands.
# shellcheck disable=SC2016
eval "$(declare -f self_update | sed 's|/usr/local/sbin|"$tmp/sbin"|g; s|/usr/local/bin|"$tmp/bin"|g')"
# Accept only the pinned release assets; raw/main and floating asset URLs fail.
get() {
  local url=$1 output='' tag="v$SCRIPT_VERSION"
  shift
  while (($#)); do
    case "$1" in -o) output=$2; shift 2;; -w|-H) shift 2;; *) return 1;; esac
  done
  case "$url" in
    https://github.com/xiangwan6667/mmwx-installer/releases/latest\?mmwx_check=*)
      [[ ${failure:-} != resolve ]] || return 1
      printf '%s' "https://github.com/xiangwan6667/mmwx-installer/releases/tag/${redirect:-$tag}";;
    "https://github.com/xiangwan6667/mmwx-installer/releases/download/$tag/install.sh")
      [[ ${failure:-} != asset ]] || return 1
      cp "$tmp/remote.sh" "$output";;
    "https://github.com/xiangwan6667/mmwx-installer/releases/download/$tag/SHA256SUMS")
      [[ ${failure:-} != manifest ]] || return 1
      cp "$tmp/SHA256SUMS" "$output";;
    *) printf 'Unexpected download: %s\n' "$url" >&2; return 1;;
  esac
}
manifest() { printf '%s  install.sh\n' "$(sha256sum "$tmp/remote.sh" | cut -d ' ' -f1)" > "$tmp/SHA256SUMS"; }
# Download cleanup has its own tests; this fixture never inspects /root.
cleanup_downloads() { :; }
cp ./install.sh "$tmp/remote.sh"
manifest
cp ./install.sh "$tmp/sbin/mmwx-installer"
ln "$tmp/sbin/mmwx-installer" "$tmp/original"
ln -s "$tmp/sbin/mmwx-installer" "$tmp/bin/mmwx"

self_update > "$tmp/output"
grep -q '已经是最新版' "$tmp/output" || { echo 'Current script reported an update'; exit 1; }
[[ $tmp/sbin/mmwx-installer -ef $tmp/original ]] || { echo 'Current script was unnecessarily replaced'; exit 1; }

# A changed script must still update, even if its declared version was not bumped.
printf '\n# Remote maintenance change\n' >> "$tmp/remote.sh"
manifest
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
# Failure must preserve the installed file, even in a conditional caller.
expect_rejected() {
  if self_update > "$tmp/output" 2>&1; then echo 'Invalid release accepted'; exit 1; fi
  [[ $tmp/sbin/mmwx-installer -ef $tmp/updated && -L $tmp/bin/mmwx ]]
  cmp -s "$tmp/sbin/mmwx-installer" "$tmp/updated"
  [[ -z $(find "$tmp/sbin" -name '.mmwx-installer.*' -print) ]]
}
for failure in resolve asset manifest; do expect_rejected; done
failure=''
for redirect in v0.2.8-beta.1 v0.2.8/extra '../../main' https://example.com/v0.2.8; do expect_rejected; done
redirect=''
printf '%064d  install.sh\n' 0 > "$tmp/SHA256SUMS"
expect_rejected
manifest
cat "$tmp/SHA256SUMS" > "$tmp/duplicate"
cat "$tmp/duplicate" >> "$tmp/SHA256SUMS"
expect_rejected
printf '%064d  bootstrap.sh\n' 0 > "$tmp/SHA256SUMS"
expect_rejected
printf '#!/usr/bin/env bash\nif\n' > "$tmp/remote.sh"
manifest
expect_rejected
sed 's/^SCRIPT_VERSION=.*/SCRIPT_VERSION=0.0.0/' ./install.sh > "$tmp/remote.sh"
manifest
expect_rejected

echo 'PASS: stable release updates are verified and atomic; invalid releases preserve the manager'
