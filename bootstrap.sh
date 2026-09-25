#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
get() { curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 15 --max-time 90 --retry 2 "$@"; }
download_installer_release() {
  local directory=$1 base=https://github.com/xiangwan6667/mmwx-installer url tag expected actual
  # Resolve latest once, then pin BOTH assets to that stable release. This uses
  # the website redirect and does not consume the anonymous GitHub API quota.
  url=$(get "$base/releases/latest" -o /dev/null -w '%{url_effective}') || { printf '无法查询正式 Release。\n' >&2; return 1; }
  [[ $url =~ ^https://github.com/xiangwan6667/mmwx-installer/releases/tag/(v[0-9]+\.[0-9]+\.[0-9]+)$ ]] || { printf '正式 Release 地址无效。\n' >&2; return 1; }
  tag=${BASH_REMATCH[1]}
  if ! get "$base/releases/download/$tag/install.sh" -o "$directory/install.sh" ||
     ! get "$base/releases/download/$tag/SHA256SUMS" -o "$directory/SHA256SUMS"; then
    printf 'Release %s 下载失败，请稍后重试。\n' "$tag" >&2; return 1
  fi
  expected=$(awk '
    $2 == "install.sh" || $2 == "*install.sh" { if (NF != 2) exit 1; count++; hash=$1 }
    END { if (count != 1 || length(hash) != 64 || hash ~ /[^0-9a-fA-F]/) exit 1; print tolower(hash) }
  ' "$directory/SHA256SUMS") || { printf 'Release 校验文件无效。\n' >&2; return 1; }
  actual=$(sha256sum "$directory/install.sh") || return 1
  [[ ${actual%% *} == "$expected" ]] || { printf 'Release SHA-256 校验失败。\n' >&2; return 1; }
  if ! head -1 "$directory/install.sh" | grep -qx '#!/usr/bin/env bash' ||
     ! bash -n "$directory/install.sh" ||
     ! grep -qx '# Independent installer. Never invoke the upstream install script.' "$directory/install.sh" ||
     ! grep -Eq '^self_update\(\) [({]$' "$directory/install.sh" ||
     [[ $(grep -c '^SCRIPT_VERSION=' "$directory/install.sh") != 1 ]] ||
     ! grep -qxF "SCRIPT_VERSION=${tag#v}" "$directory/install.sh"; then
    printf 'Release 脚本格式或版本不匹配。\n' >&2; return 1
  fi
  printf '%s\n' "$tag"
}
bootstrap_main() (
  [[ $EUID == 0 && $(uname -s) == Linux ]] || { printf '请使用 Linux root 用户运行。\n' >&2; return 1; }
  if ! command -v curl >/dev/null || [[ ! -s /etc/ssl/certs/ca-certificates.crt ]]; then
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl || return 1
  fi
  local temporary
  temporary=$(mktemp -d /tmp/mmwx-install.XXXXXX) || return 1
  trap 'rm -rf -- "$temporary"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  download_installer_release "$temporary" >/dev/null || return 1
  bash "$temporary/install.sh" "$@"
)
if [[ ${BASH_SOURCE[0]:-} == "$0" || -z ${BASH_SOURCE[0]:-} ]]; then bootstrap_main "$@"; fi
