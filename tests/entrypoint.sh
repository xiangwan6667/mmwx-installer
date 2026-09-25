#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./install.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ROOT=$tmp
# Test cleanup only inside this test root; do not inspect the operator's /root.
eval "$(declare -f cleanup_downloads | sed 's|/root/mmwx-install.sh|/nonexistent/mmwx-install.sh|g')"
stat() { echo 0; }
SELF=$tmp/mmwx-install.sh
cp ./install.sh "$SELF"
cleanup_downloads
[[ ! -f $SELF ]]
printf 'unrelated-user-file\n' > "$SELF"
cleanup_downloads
[[ -f $SELF ]]
SELF=$tmp/install.sh
cp ./install.sh "$SELF"
cleanup_downloads
[[ -f $SELF ]]
# The one-line bootstrap must install/register the menu before a user selects install.
grep -q '^open_installed_menu()' install.sh
menu_header > "$tmp/header"
grep -q "v$SCRIPT_VERSION" "$tmp/header"
# Upgrading from an old menu execs the new canonical entrypoint directly.
# Redirect its lock into this fixture; all other cleanup behavior is real.
# shellcheck disable=SC2016
eval "$(declare -f open_installed_menu | sed 's|/run/mmwx-installer.lock|"$ROOT/menu.lock"|g')"
cp ./install.sh "$tmp/mmwx-install.sh"
(
  cd "$tmp"
  SELF=/usr/local/sbin/mmwx-installer
  menu() { :; }
  # Lock behavior is covered by Linux integration; Windows Git Bash lacks flock.
  flock() { :; }
  open_installed_menu
)
[[ ! -f $tmp/mmwx-install.sh ]] || { echo 'Old downloaded copy survived canonical menu startup'; exit 1; }
(
  SELF=/usr/local/lib/mmwx-installer/runtime.sh
  if (main firewall-apply --version) >/dev/null 2>&1; then
    echo 'Backend accepted extra management arguments'; exit 1
  fi
)
# The dedicated-host notice precedes consent and any installation work.
(
  # Only bypass root identity/host lock in this private fixture.
  # shellcheck disable=SC2016
  eval "$(declare -f main | sed 's|\$EUID|0|g; s|/run/mmwx-installer.lock|$ROOT/install.lock|g')"
  SELF=$tmp/install.sh ACTION='' ACCEPT=0
  flock() { :; }
  confirm() { printf 'consent-boundary\n'; return 1; }
  install_stack() { echo unexpected-install; }
  main install > "$tmp/install-notice"
)
grep -q '专用服务器' "$tmp/install-notice"
grep -q '无其他业务' "$tmp/install-notice"
if grep -q unexpected-install "$tmp/install-notice"; then echo 'Install proceeded without consent'; exit 1; fi
echo 'PASS: known downloaded copies removed; unrelated files retained; version header present'
