#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./install.sh
case $(uname -s) in MINGW*|MSYS*) jq() { command jq -b "$@"; };; esac
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
rows='[{"tag_name":"v1.0.0","draft":false,"prerelease":false,"published_at":"2026-09-27"},{"tag_name":"v2.0.0","draft":false,"prerelease":false,"published_at":"2026-09-26"},{"tag_name":"v3.0.0","draft":false,"prerelease":false,"published_at":"2026-09-25"}]'
[[ $(recent_releases stable update v2 <<< "$rows" | jq -r '.[].tag_name') == v3.0.0 ]] || { echo 'Direction filtering admitted an equal or older release'; exit 1; }
[[ $(recent_releases stable rollback v2 <<< "$rows" | jq -r '.[].tag_name') == v1.0.0 ]]
for pair in 'v1.0.0-beta.2 v1.0.0-beta.10' 'v1.0.0-beta.10 v1.0.0' 'v1.0.0 v1.0.1-beta.1' 'v9 v10'; do
  read -r older newer <<< "$pair"
  version_allowed update "$older" "$newer"
  version_allowed rollback "$newer" "$older"
  if version_allowed update "$newer" "$older"; then exit 1; fi
done
if version_allowed update v1 v1.0.0+new; then echo 'Build metadata changed equality'; exit 1; fi
if version_allowed rollback v1.0 v1; then exit 1; fi
if recent_releases stable update bad <<< "$rows" >/dev/null 2>&1; then echo 'Invalid baseline accepted'; exit 1; fi
many=$(jq -nc '[range(20;30)|{tag_name:("v"+tostring),draft:false,prerelease:false,published_at:("2026-09-"+tostring)}] + [range(1;8)|{tag_name:("v"+tostring),draft:false,prerelease:false,published_at:("2026-08-0"+tostring)}]')
[[ $(recent_releases stable rollback v10 <<< "$many" | jq -r 'map(.tag_name)|join(",")') == v7,v6,v5,v4,v3 ]]
invalid=$(jq -c '. + [{tag_name:"nightly",draft:false,prerelease:false,published_at:"2026-10-01"}]' <<< "$rows")
[[ $(select_release stable update v2 <<< "$invalid" 2>"$tmp/warning" | jq -r .tag_name) == v3.0.0 ]]
grep -q nightly "$tmp/warning"
# The first full page has no rollback candidates. The next page must be read.
get() {
  printf '%s\n' "$1" >> "$tmp/requests"
  case "$1" in
    *'page=1') jq -nc '[range(100;200)|{tag_name:("v"+tostring),draft:false,prerelease:false,published_at:"2026-09-27"}]';;
    *'page=2') printf '%s' "$many";;
    *) return 1;;
  esac
}
fetched=$(fetch_releases 5 rollback v10)
[[ $(wc -l < "$tmp/requests") == 2 ]]
[[ $(recent_releases stable rollback v10 <<< "$fetched" | jq length) == 5 ]]
# Real HTML parsing and web pagination must continue beyond ineligible releases.
release_html() { printf '<section id="release-%s"><relative-time datetime="2026-09-27"></relative-time>%s</section>' "$1" "${2:-}"; }
get() {
  printf '%s\n' "$1" >> "$tmp/web-requests"
  case "$1" in
    */latest) release_html v50;;
    *'page=1') release_html v40; printf '<a rel="next">Next</a>';;
    *'page=2') release_html v1; release_html v2-beta.1 '<span class="Label">Pre-release</span>';;
    *) return 1;;
  esac
}
fetched=$(fetch_releases_web 1 rollback v10)
[[ $(wc -l < "$tmp/web-requests") == 3 ]]
[[ $(select_release beta rollback v10 <<< "$fetched" | jq -r .tag_name) == v2-beta.1 ]]
get() { release_html v50; printf '<a rel="next">Next</a>'; }
fetch_releases_web 5 rollback v10 > "$tmp/web-capped" 2> "$tmp/web-warning"
grep -q '查询上限' "$tmp/web-warning"
get() { jq -nc '[range(100;200)|{tag_name:("v"+tostring),draft:false,prerelease:false,published_at:"2026-09-27"}]'; }
# Use the sourced implementation here; the fixture override below is intentional.
# shellcheck disable=SC2218
fetch_releases 5 rollback v10 > "$tmp/api-capped" 2> "$tmp/api-warning"
grep -q '查询上限' "$tmp/api-warning"
# Cross-channel ordering uses semantic versions, including final and prerelease transitions.
cross='[{"tag_name":"v2.0.0","draft":false,"prerelease":false,"published_at":"2026-09-27"},{"tag_name":"v2.1.0-beta.1","draft":false,"prerelease":true,"published_at":"2026-09-26"},{"tag_name":"v2.0.0-beta.10","draft":false,"prerelease":true,"published_at":"2026-09-25"}]'
fetch_releases() { printf '%s' "$cross"; }
check_app_image() { return 0; }
CHANNEL=stable CHANNEL_EXPLICIT=1 ACCEPT=0
# This is the sourced chooser; the later override isolates the final guard tests.
# shellcheck disable=SC2218
choose_version update v2.0.0-beta.2 >/dev/null
[[ $VERSION == v2.0.0 ]]
CHANNEL=beta
# shellcheck disable=SC2218
choose_version update v2.0.0 >/dev/null
[[ $VERSION == v2.1.0-beta.1 ]]
# shellcheck disable=SC2218
choose_version rollback v2.0.0 >/dev/null
[[ $VERSION == v2.0.0-beta.10 ]]
# Reselecting an empty channel cancels without checking or pulling an invalid candidate.
CHANNEL=stable VERSION=v3
check_app_image() { printf '%s\n' "$1" >> "$tmp/checked"; return 10; }
printf '2\n2\n' > "$tmp/answers"
ask() { local answer; IFS= read -r answer < "$tmp/answers"; tail -n +2 "$tmp/answers" > "$tmp/next"; mv "$tmp/next" "$tmp/answers"; printf '%s' "$answer"; }
if select_available_image "$rows" specified update v2 > "$tmp/output"; then echo 'Empty reselected channel accepted'; exit 1; fi
[[ $(cat "$tmp/checked") == v3 ]]
grep -q '没有符合方向' "$tmp/output"
# A final update guard protects the system even if a chooser returns a bad target.
ROOT=$tmp/root; mkdir -p "$ROOT/state" "$ROOT/config"
preflight() { :; }
load_state() { VERSION=v2; APP_IMAGE=old; }
choose_version() { VERSION=$selected_target; APP_IMAGE=changed-digest; }
pull_app_version() { echo pull >> "$tmp/mutations"; }
install_command() { echo command >> "$tmp/mutations"; }
configure_timezone() { echo timezone >> "$tmp/mutations"; }
dc() { echo service >> "$tmp/mutations"; }
for selected_target in v1 v2.0.0 v2+changed; do update_stack >/dev/null; done
[[ ! -e $tmp/mutations && ! -e $ROOT/state/update.json ]]
load_state() { VERSION=invalid; APP_IMAGE=old; }
if (update_stack) >/dev/null 2>&1; then echo 'Invalid installed baseline accepted'; exit 1; fi
[[ ! -e $tmp/mutations ]]
# Rollback validates the selected version again immediately before pulling.
load_state() { VERSION=v2; APP_IMAGE=old; }
fetch_releases() { printf '%s' "$rows"; }
select_version_menu() { VERSION=$selected_target; }
select_available_image() { return 0; }
confirm() { return 0; }
for selected_target in v3 v2.0.0 v2+changed; do rollback_stack >/dev/null; done
[[ ! -e $tmp/mutations && ! -e $ROOT/state/image-rollback.json ]]
printf '{"stage":6}' > "$ROOT/state/progress.json"
selected_target=v1
if (rollback_stack) >/dev/null 2>&1; then echo 'Rollback accepted incomplete installation'; exit 1; fi
[[ ! -e $tmp/mutations ]]
rm "$ROOT/state/progress.json"
echo 'PASS: semantic ordering, strict directions and filtering before recent five'
