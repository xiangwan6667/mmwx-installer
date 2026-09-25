#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=bootstrap.sh
source ./bootstrap.sh
command -v bootstrap_main >/dev/null || { echo 'bootstrap_main is required'; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
tag=v1.2.3
release="https://github.com/xiangwan6667/mmwx-installer/releases/tag/$tag"
asset_base="https://github.com/xiangwan6667/mmwx-installer/releases/download/$tag"
marker="$tmp/executed"; payload="$tmp/install.sh"
cat >"$payload" <<EOF
#!/usr/bin/env bash
# Independent installer. Never invoke the upstream install script.
SCRIPT_VERSION=1.2.3
self_update() {
  :
}
printf '%s\\n' executed > '$marker'
EOF
hash=$(sha256sum "$payload" | awk '{print $1}')
printf '%s  install.sh\n' "$hash" > "$tmp/SHA256SUMS"
# shellcheck disable=SC2317,SC2329
get() {
  local url=$1; shift
  case "$url" in
    https://github.com/xiangwan6667/mmwx-installer/releases/latest) printf '%s\n' "$release" ;;
    "$asset_base/install.sh") cp "$payload" "${!#}" ;;
    "$asset_base/SHA256SUMS") cp "$tmp/SHA256SUMS" "${!#}" ;;
    *) echo "unexpected fetch URL: $url" >&2; return 1 ;;
  esac
}
uname() { echo Linux; }; curl() { return 0; }; apt-get() { echo unexpected-apt >&2; return 1; }
touch "$tmp/ca.crt"
# shellcheck disable=SC2016
eval "$(declare -f bootstrap_main | sed 's/\$EUID/0/g; s/if ! command -v curl.*/if false; then/' )"
( bootstrap_main )
[[ -f $marker ]] || { echo 'validated release was not executed'; exit 1; }
for bad in \
  'https://github.com/xiangwan6667/mmwx-installer/raw/main/install.sh' \
  'https://github.com/xiangwan6667/mmwx-installer/releases/tag/v1.2.3-beta' \
  'https://github.com/other/repo/releases/tag/v1.2.3'; do
  # shellcheck disable=SC2317,SC2329
  get() { local url=$1; [[ $url == https://github.com/xiangwan6667/mmwx-installer/releases/latest ]] || return 1; printf '%s\n' "$bad"; }
  rm -f "$marker"
  if ( bootstrap_main ) 2>"$tmp/error"; then echo "accepted invalid redirect: $bad"; exit 1; fi
  [[ ! -e $marker ]] || { echo 'executed installer after invalid redirect'; exit 1; }
done
# shellcheck disable=SC2317,SC2329
get() {
  local url=$1; shift
  case "$url" in
    https://github.com/xiangwan6667/mmwx-installer/releases/latest) printf '%s\n' "$release" ;;
    "$asset_base/install.sh") cp "$payload" "${!#}" ;;
    "$asset_base/SHA256SUMS") printf 'deadbeef  install.sh\n' > "${!#}" ;;
    *) return 1 ;;
  esac
}
rm -f "$marker"
if ( bootstrap_main ) 2>"$tmp/error"; then echo 'accepted invalid SHA256SUMS'; exit 1; fi
[[ ! -e $marker ]] || { echo 'executed installer after hash failure'; exit 1; }

# A valid checksum for the wrong version still cannot execute.
sed -i 's/SCRIPT_VERSION=1.2.3/SCRIPT_VERSION=1.2.4/' "$payload"
hash=$(sha256sum "$payload" | awk '{print $1}')
printf '%s  install.sh\n' "$hash" > "$tmp/SHA256SUMS"
# shellcheck disable=SC2317,SC2329
get() {
  local url=$1; shift
  case "$url" in
    https://github.com/xiangwan6667/mmwx-installer/releases/latest) printf '%s\n' "$release" ;;
    "$asset_base/install.sh") cp "$payload" "${!#}" ;;
    "$asset_base/SHA256SUMS") cp "$tmp/SHA256SUMS" "${!#}" ;;
    *) return 1 ;;
  esac
}
if ( bootstrap_main ) 2>"$tmp/error"; then echo 'accepted wrong script version'; exit 1; fi
[[ ! -e $marker ]] || { echo 'executed wrong version'; exit 1; }
sed -i 's/SCRIPT_VERSION=1.2.4/SCRIPT_VERSION=1.2.3/' "$payload"

# A missing asset or duplicate checksum entry must fail closed.
# shellcheck disable=SC2317,SC2329
get() {
  local url=$1; shift
  case "$url" in
    https://github.com/xiangwan6667/mmwx-installer/releases/latest) printf '%s\n' "$release" ;;
    "$asset_base/install.sh") cp "$payload" "${!#}" ;;
    "$asset_base/SHA256SUMS") return 1 ;;
    *) return 1 ;;
  esac
}
if ( bootstrap_main ) 2>"$tmp/error"; then echo 'accepted missing manifest'; exit 1; fi
[[ ! -e $marker ]] || { echo 'executed without manifest'; exit 1; }
get() {
  local url=$1; shift
  case "$url" in
    https://github.com/xiangwan6667/mmwx-installer/releases/latest) printf '%s\n' "$release" ;;
    "$asset_base/install.sh") cp "$payload" "${!#}" ;;
    "$asset_base/SHA256SUMS") printf '%s  install.sh\n%s  install.sh\n' "$hash" "$hash" > "${!#}" ;;
    *) return 1 ;;
  esac
}
if ( bootstrap_main ) 2>"$tmp/error"; then echo 'accepted duplicate checksum'; exit 1; fi
[[ ! -e $marker ]] || { echo 'executed with duplicate checksum'; exit 1; }
echo 'PASS: release redirect, validation and failure cases'
