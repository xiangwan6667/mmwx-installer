#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./install.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ufw() {
  if [[ $* == 'status numbered' ]]; then
    cat <<'EOF'
Status: active
[ 1] 22/tcp                     ALLOW IN    Anywhere                   # mmwx-ssh
[ 2] 80,443/tcp                 ALLOW IN    173.245.48.0/20            # mmwx-cf
[ 3] 80/tcp                     ALLOW IN    192.0.2.1                 # other-project
[12] 80,443/tcp                 ALLOW IN    104.16.0.0/13             # mmwx-cf
[13] 22/tcp                     ALLOW IN    192.0.2.2                 # mmwx-cf
[14] 80,443/tcp                 ALLOW IN    192.0.2.3                 # mmwx-cf-other
EOF
  else printf '%s\n' "$*" >> "$tmp/deletions"; fi
}
remove_legacy_cf_rules
[[ $(cat "$tmp/deletions") == $'--force delete 12\n--force delete 2' ]]
echo 'PASS: migration deletes only owned web rules, highest index first'
