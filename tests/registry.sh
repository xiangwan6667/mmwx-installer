#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./install.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ROOT=$tmp/root
mkdir -p "$tmp/requests" "$tmp/scratch"
export TMPDIR=$tmp/scratch
VERSION=v99 APP_IMAGE=installed@sha256:unchanged
machine=x86_64
uname() { printf '%s\n' "$machine"; }
digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
token_body='{"token":"fixture-anonymous-token"}'
index='{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":123,"platform":{"os":"linux","architecture":"amd64"}},{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","size":123,"platform":{"os":"unknown","architecture":"unknown"}}]}'
single='{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":123},"layers":[]}'
config='{"os":"linux","architecture":"amd64","rootfs":{"type":"layers","diff_ids":[]},"config":{}}'
missing_body='{"errors":[{"code":"MANIFEST_UNKNOWN","message":"manifest unknown"}]}'

# Mock the network boundary: all classification, parsing and cleanup use production code.
curl() {
  local output='' url='' header='' token_header=0
  printf '%s\n' "$@" >> "$tmp/requests/arguments"
  while (($#)); do
    case "$1" in
      -o|--output) output=$2; shift 2;;
      -H|--header)
        header=$2
        if [[ $header == @* ]] && grep -qx 'Authorization: Bearer fixture-anonymous-token' "${header#@}"; then token_header=1; fi
        shift 2;;
      -w|--write-out|--proto|--proto-redir|--tls-max|--connect-timeout|--max-time|--max-redirs|--retry|--max-filesize) shift 2;;
      https://*) url=$1; shift;;
      *) shift;;
    esac
  done
  [[ -n $output ]] || { printf 'mock: response file missing\n' >&2; return 90; }
  case "$url" in
    'https://ghcr.io/token?service=ghcr.io&scope=repository:iluobei/miaomiaowux:pull')
      printf '%s' "$token_body" > "$output"; printf '%s' "$token_status"; return "$token_exit";;
    'https://ghcr.io/v2/iluobei/miaomiaowux/manifests/0.5.4')
      [[ $token_header == 1 ]] || return 91
      printf '%s' "$manifest_body" > "$output"
      if [[ $manifest_exit != 0 ]]; then printf 'curl: (28) fixture timeout\n' >&2; fi
      printf '%s' "$manifest_status"; return "$manifest_exit";;
    "https://ghcr.io/v2/iluobei/miaomiaowux/blobs/$digest")
      [[ $token_header == 1 ]] || return 91
      printf '%s' "$config_body" > "$output"; printf '%s' "$config_status"; return 0;;
    *) printf 'mock: unexpected URL\n' >&2; return 92;;
  esac
}

reset_fixture() {
  token_status=200 token_exit=0 manifest_status=200 manifest_exit=0 config_status=200
  token_body='{"token":"fixture-anonymous-token"}'
  manifest_body=$index config_body=$config machine=x86_64
  : > "$tmp/requests/arguments"
}
expect_status() {
  local expected=$1 label=$2 version=${3-v0.5.4} actual=0
  check_app_image "$version" > "$tmp/stdout" 2> "$tmp/stderr" || actual=$?
  [[ $actual == "$expected" ]] || { printf 'FAIL: %s: expected %s, got %s\n' "$label" "$expected" "$actual"; cat "$tmp/stderr"; exit 1; }
  [[ $VERSION == v99 && $APP_IMAGE == installed@sha256:unchanged ]] || { echo 'FAIL: checker changed selected image'; exit 1; }
  [[ -z $(find "$TMPDIR" -mindepth 1 -print -quit) ]] || { echo 'FAIL: token temporary files remain'; exit 1; }
  if grep -R -q 'fixture-anonymous-token' "$tmp/stdout" "$tmp/stderr" "$tmp/requests" "$ROOT/state/logs" 2>/dev/null; then
    echo 'FAIL: token leaked into output, curl arguments or logs'; exit 1
  fi
}

reset_fixture; expect_status 0 'OCI index supports amd64 and ignores attestation'
reset_fixture; machine=aarch64; expect_status 11 'index missing arm64'
reset_fixture; machine=aarch64; manifest_body=${index/amd64/arm64}; expect_status 0 'OCI index supports arm64'
reset_fixture; manifest_body=${index/vnd.oci.image.index.v1+json/vnd.docker.distribution.manifest.list.v2+json}; expect_status 0 'Docker manifest list'
reset_fixture; manifest_body=$(jq '.manifests |= map(select(.platform.architecture=="unknown"))' <<<"$index"); expect_status 11 'attestations alone are not host images'
reset_fixture; manifest_status=404; manifest_body=$missing_body; expect_status 10 'missing tag'
reset_fixture; manifest_status=404; manifest_body=${missing_body/MANIFEST_UNKNOWN/NAME_UNKNOWN}; expect_status 10 'missing repository'
reset_fixture; manifest_status=404; manifest_body='<html>proxy missing</html>'; expect_status 20 'non-registry 404'
reset_fixture; manifest_status=404; manifest_body='{"errors":[{"code":"UNAUTHORIZED"}]}'; expect_status 20 '404 does not hide authorization error'
reset_fixture; manifest_status=404; manifest_body="$missing_body $missing_body"; expect_status 20 'multiple JSON errors are malformed'
reset_fixture; manifest_status=401; manifest_body=$missing_body; expect_status 20 'authentication failure'
reset_fixture; manifest_status=403; expect_status 20 'access denied'
reset_fixture; manifest_status=429; expect_status 20 'rate limit'
reset_fixture; manifest_status=503; expect_status 20 'registry outage'
reset_fixture; manifest_status=000; manifest_exit=28; expect_status 20 'transport failure'
grep -q 'fixture timeout' "$ROOT/state/logs/image-check.log"
reset_fixture; token_status=401; expect_status 20 'token authorization failure'
reset_fixture; token_exit=28; expect_status 20 'token transport failure'
reset_fixture; token_body='{}'; expect_status 20 'missing token'
reset_fixture; token_body='{"token":"header\ninjection"}'; expect_status 20 'invalid token header'
reset_fixture; manifest_body='<html>proxy</html>'; expect_status 20 'malformed manifest'
reset_fixture; manifest_body='{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":null}'; expect_status 20 'malformed index'
reset_fixture; manifest_body=$(jq 'del(.manifests[0].platform)' <<<"$index"); expect_status 20 'unresolved platform metadata'
reset_fixture; manifest_body=$single; expect_status 0 'single OCI manifest config matches amd64'
reset_fixture; manifest_body=${single/vnd.oci.image.manifest.v1+json/vnd.docker.distribution.manifest.v2+json}; expect_status 0 'single Docker manifest'
reset_fixture; manifest_body=$single; machine=aarch64; expect_status 11 'single config mismatches host'
reset_fixture; manifest_body=$single; machine=aarch64; config_body=${config/amd64/arm64}; expect_status 0 'single config matches arm64'
reset_fixture; manifest_body=$single; config_body=${config/linux/windows}; expect_status 11 'single config has wrong OS'
reset_fixture; manifest_body=$single; config_body='{}'; expect_status 20 'malformed config'
reset_fixture; manifest_body=$single; config_body="$config $config"; expect_status 20 'multiple JSON configs are malformed'
reset_fixture; manifest_body=$single; config_status=404; expect_status 20 'missing blob is an invalid publication'
reset_fixture; manifest_body=$(jq '.config.digest="../invalid"' <<<"$single"); expect_status 20 'invalid config digest'
reset_fixture; machine=riscv64; expect_status 20 'unsupported host'; [[ ! -s $tmp/requests/arguments ]]
reset_fixture; expect_status 20 'invalid version' '../0.5.4'; [[ ! -s $tmp/requests/arguments ]]
reset_fixture; expect_status 20 'empty version' ''; [[ ! -s $tmp/requests/arguments ]]
echo 'PASS: registry availability, host platforms, error separation, token privacy and cleanup'
