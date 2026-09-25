#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./install.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ROOT=$tmp
run_step '下载测试' bash -c 'printf "layer-details\n"' > "$tmp/screen"
if grep -q layer-details "$tmp/screen"; then echo 'Verbose output leaked'; exit 1; fi
grep -q layer-details "$ROOT"/state/logs/*.log
if run_step '失败测试' bash -c 'echo meaningful-error >&2; exit 23' > "$tmp/error" 2>&1; then exit 1; else [[ $? == 23 ]]; fi
grep -q meaningful-error "$tmp/error"
grep -q '完整日志' "$tmp/error"
# Interrupting a step must also stop the Docker-like grandchild behind a function.
if [[ $(uname -s) == Linux ]]; then
  (
    # Record the actual step shell after its signal trap is installed; $! alone
    # identifies the outer function wrapper, which cannot exercise that trap.
    # shellcheck disable=SC2016
    eval "$(declare -f run_step | sed '/trap .* INT TERM;/a\    printf "%s\\n" "$BASHPID" > "$tmp/runner-pid";')"
    # Invoked indirectly through run_step. The release file avoids racing a timer.
    # shellcheck disable=SC2317,SC2329
    step_child() {
      bash -c 'echo ready > "$1"; for ((i=0;i<250;i++)); do [[ ! -e $2 ]] || { echo continued > "$3"; exit; }; sleep 0.02; done' _ "$tmp/ready" "$tmp/release" "$tmp/continued"
    }
    run_step '中断测试' step_child > "$tmp/interrupted" 2>&1 &
    runner=$!
    for ((i=0;i<100;i++)); do [[ ! -s $tmp/runner-pid || ! -f $tmp/ready ]] || break; sleep 0.02; done
    [[ -s $tmp/runner-pid && -f $tmp/ready ]]
    kill -TERM "$(cat "$tmp/runner-pid")"
    code=0
    wait "$runner" || code=$?
    touch "$tmp/release"
    sleep 1
    [[ $code == 130 ]] || { echo "Unexpected interruption status: $code"; exit 1; }
    [[ ! -f $tmp/continued ]] || { echo 'Grandchild continued after interruption'; exit 1; }
  )
fi
# Capture dependency selection without touching host package state.
run_step() { printf '%s\n' "$*" >> "$tmp/packages"; }
dpkg-query() { printf 'install ok installed'; }
dependencies >/dev/null
[[ ! -f $tmp/packages ]]
dpkg-query() { case "${@: -1}" in jq|ufw) return 1;; *) printf 'install ok installed';; esac; }
dependencies >/dev/null
[[ $(wc -l < "$tmp/packages") == 2 ]]
grep -qx '安装缺失依赖 env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq jq ufw' "$tmp/packages"
echo 'PASS: compact output preserves errors/logs, dependency check installs only missing packages'
