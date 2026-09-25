#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
[[ $EUID == 0 && $(uname -s) == Linux ]] || { printf '请使用 Linux root 用户运行。\n' >&2; exit 1; }
if ! command -v curl >/dev/null || [[ ! -s /etc/ssl/certs/ca-certificates.crt ]]; then
  apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl
fi
temporary=$(mktemp /tmp/mmwx-install.XXXXXX)
trap 'rm -f "$temporary"' EXIT
curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 15 --max-time 120 \
  https://raw.githubusercontent.com/xiangwan6667/mmwx-installer/main/install.sh -o "$temporary"
bash -n "$temporary"
grep -qx '# Independent installer. Never invoke the upstream install script.' "$temporary"
bash "$temporary"
