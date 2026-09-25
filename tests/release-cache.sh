#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./install.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ROOT=$tmp
base=https://github.com/xiangwan6667/mmwx-installer
curl() {
  local url='' output='' write='' arg
  while (($#)); do
    arg=$1; shift
    case "$arg" in
      -o) output=$1; shift;; -w) write=$1; shift;;
      "$base"/*) url=$arg;;
    esac
  done
  case "$url" in
    "$base/releases/latest"*)
      if [[ $url =~ /releases/latest\?mmwx_check=[0-9]+-[0-9]+-[0-9]+$ ]]; then
        printf '%s\n' "$url" >> "$tmp/queries"
        printf '%s/releases/tag/v9.9.9' "$base"
      else printf '%s/releases/tag/v0.0.1' "$base"; fi;;
    "$base/releases/download/v9.9.9/install.sh") cp "$tmp/remote.sh" "$output";;
    "$base/releases/download/v9.9.9/SHA256SUMS") cp "$tmp/SHA256SUMS" "$output";;
    *) printf 'Unexpected fetch %s (%s)\n' "$url" "$write" >&2; return 1;;
  esac
}
sed 's/^SCRIPT_VERSION=.*/SCRIPT_VERSION=9.9.9/' install.sh > "$tmp/remote.sh"
printf '%s  install.sh\n' "$(sha256sum "$tmp/remote.sh" | cut -d ' ' -f1)" > "$tmp/SHA256SUMS"
check_script_update
[[ $SCRIPT_UPDATE_VERSION == v9.9.9 ]] || { echo 'Menu lookup reused the stale latest URL'; exit 1; }
mkdir "$tmp/download"
[[ $(download_installer_release "$tmp/download") == v9.9.9 ]] || { echo 'Self-update lookup reused the stale latest URL'; exit 1; }
cmp "$tmp/remote.sh" "$tmp/download/install.sh"
(
  source ./bootstrap.sh
  [[ $(download_installer_release "$tmp/download") == v9.9.9 ]] || { echo 'Bootstrap lookup reused the stale latest URL'; exit 1; }
)
[[ $(sort -u "$tmp/queries" | wc -l) == 3 ]] || { echo 'Release queries reused a cache key'; exit 1; }
echo 'PASS: menu, self-update and bootstrap bypass cached latest redirects and pin verified assets'
