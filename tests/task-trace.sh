#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./install.sh
scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT
ROOT=$scratch/root
mkdir -p "$ROOT/config"
printf 'CF_API_TOKEN=fixture-token-very-private\n' > "$ROOT/config/caddy.env"
printf 'POSTGRES_PASSWORD=fixture-password-private\n' > "$ROOT/config/postgres.env"
declare -F trace_start >/dev/null || { echo 'Task tracing missing'; exit 1; }
trace_start install
[[ -f $TRACE_LOG ]]
run_step '成功步骤' bash -c 'echo finished' > "$scratch/screen"
if run_step '失败步骤' bash -c 'echo fixture-token-very-private; echo fixture-password-private >&2; exit 23' > "$scratch/error" 2>&1; then exit 1; else [[ $? == 23 ]]; fi
trace_finish 23
if grep -R -E 'fixture-token-very-private|fixture-password-private' "$ROOT/state/logs" "$scratch/error"; then echo 'Secret persisted in log'; exit 1; fi
grep -q 'STEP_FAILED.*exit=23' "$TRACE_LOG"
grep -q 'version=' "$TRACE_LOG"
grep -q '失败步骤' "$TRACE_LOG"
grep -q 'FINISH.*exit=23' "$TRACE_LOG"
trace_show > "$scratch/view"
grep -q '失败步骤' "$scratch/view"
# Direct die failures, outside run_step, must be traceable with source location.
if (die 'explicit-error') > "$scratch/die" 2>&1; then exit 1; fi
grep -q 'ERROR.*explicit-error' "$TRACE_LOG"
# No credentials in the command's arguments are recorded as metadata.
if grep -q 'bash -c' "$TRACE_LOG"; then echo 'Raw command args were recorded'; exit 1; fi
# Finishing a full purge must not recreate the deleted project directory.
rm -f "$TRACE_LOG"
trace_finish 0
[[ ! -e $TRACE_LOG ]]
echo 'PASS: task and step failures retain cause/exit/source, redact secrets and remain viewable'
