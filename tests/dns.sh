#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./install.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
TOKEN_FILE=$tmp/token
printf 'fixture-token-not-a-real-secret' > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"
# Ownership and interface discovery are host boundaries in this API test.
stat() { case "$2" in %u) echo 0;; %a) echo 600;; *) return 1;; esac; }
ip() { printf '[{"addr_info":[{"local":"8.8.8.8"}]}]'; }
get() {
  case "${@: -1}" in
    *'/zones?status=active&per_page=50&page=1')
      printf '{"success":true,"result":[{"id":"zone1","name":"example.com"}],"result_info":{"total_pages":2}}';;
    *'/zones?status=active&per_page=50&page=2')
      printf '{"success":true,"result":[{"id":"zone2","name":"example.org"}],"result_info":{"total_pages":2}}';;
    *'/zones/zone2/dns_records?name=cs.example.org')
      printf '{"success":true,"result":[]}';;
    *'/zones/zone2/dns_records')
      local previous='' argument payload=''
      for argument in "$@"; do [[ $previous != --data ]] || payload=$argument; previous=$argument; done
      jq -e '.name=="cs.example.org" and .type=="A" and .content=="8.8.8.8" and .proxied==true' <<<"$payload" >/dev/null
      printf '{"success":true}';;
    *) echo 'Unexpected API call' >&2; return 1;;
  esac
}
ask() { echo 'Unexpected prompt' >&2; exit 80; }
PREFIX=cs ZONE_NAME=example.org DOMAIN=''
dns_check
[[ $DOMAIN == cs.example.org && $CF_TOKEN == fixture-token-not-a-real-secret ]]
# With multiple authorized zones the numbered selection builds the same domain.
ZONE_NAME='' DOMAIN=''
ask() { echo 2; }
dns_check
[[ $DOMAIN == cs.example.org ]]
echo 'PASS: paginated zone selection and prefix create the intended proxied DNS record'
