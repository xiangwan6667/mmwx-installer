#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./install.sh

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ROOT=$tmp
printf '0' > "$tmp/calls"
: > "$tmp/argv"
SCRIPT_VERSION=0.2.10
curl_mode=latest
curl() {
  local calls; calls=$(cat "$tmp/calls"); printf '%s' "$((calls + 1))" > "$tmp/calls"
  printf '<%s>\n' "$@" >> "$tmp/argv"
  local url="${!#}"
  [[ $url == https://github.com/xiangwan6667/mmwx-installer/releases/latest ]] || return 1
  case $curl_mode in
    latest) printf '%s' 'https://github.com/xiangwan6667/mmwx-installer/releases/tag/v0.2.11' ;;
    equal) printf '%s' 'https://github.com/xiangwan6667/mmwx-installer/releases/tag/v0.2.10' ;;
    older) printf '%s' 'https://github.com/xiangwan6667/mmwx-installer/releases/tag/v0.2.9' ;;
    multi) printf '%s' 'https://github.com/xiangwan6667/mmwx-installer/releases/tag/v0.2.100' ;;
    beta) printf '%s' 'https://github.com/xiangwan6667/mmwx-installer/releases/tag/v0.2.11-beta.1' ;;
    malformed) printf '%s' 'https://github.com/other/project/releases/tag/v9.9.9' ;;
    empty) return 0 ;;
    http) printf '%s' 'http://github.com/xiangwan6667/mmwx-installer/releases/tag/v9.9.9' ;;
    leading) printf '%s' 'https://github.com/xiangwan6667/mmwx-installer/releases/tag/v01.02.011' ;;
    boundary_major) printf '%s' 'https://github.com/xiangwan6667/mmwx-installer/releases/tag/v10.0.0' ;;
    boundary_minor) printf '%s' 'https://github.com/xiangwan6667/mmwx-installer/releases/tag/v1.10.0' ;;
    boundary_minor2) printf '%s' 'https://github.com/xiangwan6667/mmwx-installer/releases/tag/v2.0.0' ;;
    failure) return 22 ;;
  esac
}

SCRIPT_UPDATE_CHECKED=0 SCRIPT_UPDATE_VERSION=''
curl_mode=latest
check_script_update
[[ $SCRIPT_UPDATE_CHECKED == 1 && $SCRIPT_UPDATE_VERSION == v0.2.11 ]]
[[ $(cat "$tmp/calls") == 1 ]]
expect_arg() { grep -A1 -xF -- "<$1>" "$tmp/argv" | grep -qxF -- "<$2>"; }
expect_arg --proto '=https'
expect_arg --proto-redir '=https'
expect_arg --connect-timeout 2
expect_arg --max-time 3
expect_arg --retry 0
expect_arg -o /dev/null
expect_arg -w '%{url_effective}'

for curl_mode in equal older beta malformed empty http leading; do
  SCRIPT_UPDATE_CHECKED=0 SCRIPT_UPDATE_VERSION=''
  check_script_update
  [[ $SCRIPT_UPDATE_CHECKED == 1 && -z $SCRIPT_UPDATE_VERSION ]] || { echo "invalid release accepted: $curl_mode"; exit 1; }
done

SCRIPT_UPDATE_CHECKED=0 SCRIPT_UPDATE_VERSION=''; curl_mode=multi
check_script_update
[[ $SCRIPT_UPDATE_VERSION == v0.2.100 ]] || { echo 'multi-digit version compared incorrectly'; exit 1; }

for spec in '9.9.9 boundary_major v10.0.0' '1.9.99 boundary_minor v1.10.0' '1.99.9 boundary_minor2 v2.0.0'; do
  read -r SCRIPT_VERSION curl_mode expected <<<"$spec"
  SCRIPT_UPDATE_CHECKED=0 SCRIPT_UPDATE_VERSION=''; check_script_update
  [[ $SCRIPT_UPDATE_VERSION == "$expected" ]] || { echo "numeric boundary failed: $spec"; exit 1; }
done

SCRIPT_UPDATE_CHECKED=0 SCRIPT_UPDATE_VERSION=''; curl_mode=failure
check_script_update
[[ $SCRIPT_UPDATE_CHECKED == 1 && -z $SCRIPT_UPDATE_VERSION ]] || { echo 'network failure was not ignored'; exit 1; }
calls_after_failure=$(cat "$tmp/calls")
check_script_update
[[ $(cat "$tmp/calls") == "$calls_after_failure" ]] || { echo 'failed lookup was retried'; exit 1; }

SCRIPT_UPDATE_CHECKED=0 SCRIPT_UPDATE_VERSION=''; curl_mode=latest
check_script_update; first=$(cat "$tmp/calls"); check_script_update
[[ $(cat "$tmp/calls") == "$first" ]] || { echo 'lookup was repeated'; exit 1; }

# Opening the menu performs one lookup and presents a newer version as menu 9.
SCRIPT_UPDATE_CHECKED=0 SCRIPT_UPDATE_VERSION=''; curl_mode=latest
printf '0' > "$tmp/calls"
SCRIPT_VERSION=0.2.10
printf 'x\n0\n' > "$tmp/answers"
ask() { local answer; IFS= read -r answer < "$tmp/answers"; tail -n +2 "$tmp/answers" > "$tmp/next"; mv "$tmp/next" "$tmp/answers"; printf '%s' "$answer"; }
menu > "$tmp/menu"
grep -q 'v0.2.11.*菜单 9' "$tmp/menu"
[[ $(cat "$tmp/calls") == 1 ]] || { echo 'menu queried more than once'; exit 1; }

SCRIPT_UPDATE_CHECKED=0 SCRIPT_UPDATE_VERSION=''; curl_mode=failure
printf '0' > "$tmp/calls"; printf 'x\n0\n' > "$tmp/answers"
menu > "$tmp/menu"
[[ $(cat "$tmp/calls") == 1 ]] || { echo 'failed menu lookup queried more than once'; exit 1; }
[[ -z $SCRIPT_UPDATE_VERSION ]]
(
  SCRIPT_UPDATE_CHECKED=0
  # Invoked indirectly by menu -> check_script_update.
  # shellcheck disable=SC2317,SC2329
  curl() { return 127; }
  printf '0\n' > "$tmp/answers"
  menu > "$tmp/missing-curl-menu"
  [[ $SCRIPT_UPDATE_CHECKED == 1 && -z $SCRIPT_UPDATE_VERSION ]]
)

# Informational flags return without making a network request.
SCRIPT_UPDATE_CHECKED=0 SCRIPT_UPDATE_VERSION=''; curl_mode=latest; before=$(cat "$tmp/calls")
main --version >/dev/null
[[ $(cat "$tmp/calls") == "$before" && $SCRIPT_UPDATE_CHECKED == 0 ]]
main --help >/dev/null
[[ $(cat "$tmp/calls") == "$before" && $SCRIPT_UPDATE_CHECKED == 0 ]]

echo 'PASS: management script release checks'
