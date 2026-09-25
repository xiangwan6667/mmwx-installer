#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./install.sh
case $(uname -s) in MINGW*|MSYS*) jq() { command jq -b "$@"; };; esac
scratch=$(mktemp -d)
trap 'if [[ $? != 0 && -f $scratch/output ]]; then cat "$scratch/output" >&2; fi; rm -rf "$scratch"' EXIT
host=$(cd "$scratch" && pwd -P)/host
ROOT=$host/opt/mmwx-installer
mkdir -p "$ROOT/state" "$host/var/lib/docker" "$host/var/lib/containerd" "$host/etc/docker"
for operation in docker_purge_paths_check docker_purge_phase docker_purge_preflight purge_docker; do
  eval "$(declare -f "$operation" | sed "s|/var/lib/docker|$host/var/lib/docker|g; s|/var/lib/containerd|$host/var/lib/containerd|g; s|/etc/docker|$host/etc/docker|g; s|/etc/containerd|$host/etc/containerd|g; s|/etc/apt/|$host/etc/apt/|g")"
done
# Avoid falling through to the CI runner's real Docker binary after mock purge.
# shellcheck disable=SC2016
eval "$(declare -f purge_docker | sed 's/command -v docker/test "${DOCKER_REMOVED:-0}" = 0/g')"
# External services are mocked; paths, JSON journal and deletion are real.
# shellcheck disable=SC2317,SC2329
docker_fixture() {
  case "$*" in
    'context inspect --format {{.Endpoints.docker.Host}}') echo unix:///var/run/docker.sock;;
    'info --format {{json .}}') printf '{"DockerRootDir":"%s","Swarm":{"LocalNodeState":"inactive"},"SecurityOptions":[]}' "${DATA_ROOT:-$host/var/lib/docker}";;
    'ps -aq') printf '%s' "${CONTAINERS:-}";;
    'inspect foreign --format '*) echo other;;
    'volume ls -q') printf '%s' "${VOLUMES:-}";;
    'volume inspect foreign --format '*) echo other;;
    'volume inspect anonymous --format '*) echo '<no value>';;
    'ps -aq --filter volume=anonymous') echo project;;
    'inspect project --format '*) echo mmwx-installer;;
    'network ls -q') printf '%s' "${NETWORKS:-bridge}";;
    'network inspect foreign') echo '[{"Name":"foreign","Labels":{}}]';;
    'network inspect bridge') echo '[{"Name":"bridge","Id":"123456789abc1234","Driver":"bridge","Options":{"com.docker.network.bridge.name":"docker0"},"Labels":{}}]';;
    'ps -aq --filter label=com.docker.compose.project=mmwx-installer'|'network ls -q --filter label=com.docker.compose.project=mmwx-installer') :;;
    *) echo "Unexpected Docker command: $*" >&2; return 1;;
  esac
}
docker() { docker_fixture "$@"; }
systemctl() {
  case "$1" in
    show) echo loaded;;
    is-active) [[ ${SERVICE_ACTIVE:-0} == 1 ]];;
    *) printf '%s\n' "$*" >> "$scratch/systemctl";;
  esac
}
findmnt() { printf '%s' "${MOUNT:-}"; }
# shellcheck disable=SC2317,SC2329
ctr() { case "$*" in *'namespaces list -q') echo other;; *'containers list -q') echo foreign;; *) return 1;; esac; }
dpkg-query() { [[ $* == *'docker-ce' ]] || return 1; printf 'install ok installed'; }
apt-get() {
  printf '%s\n' "$*" >> "$scratch/apt"
  if [[ $1 == -s ]]; then echo 'Purg docker-ce [1.0]'; return; fi
  [[ ${APT_FAIL:-0} != 1 ]] || return 1
  export DOCKER_REMOVED=1
}
env() { shift; "$@"; }
ip() { printf '%s\n' "$*" >> "$scratch/ip"; }
docker_purge_firewall() { echo cleaned > "$scratch/firewall"; }
expect_refusal() {
  if (docker_purge_preflight) > "$scratch/output" 2>&1; then echo "Unsafe purge accepted: $1"; exit 1; fi
  [[ -d $host/var/lib/docker && ! -e $ROOT/state/docker-purge.json ]]
  grep -q "$2" "$scratch/output"
}
CONTAINERS=foreign expect_refusal container '其他项目容器'
VOLUMES=foreign expect_refusal volume '其他项目存储卷'
NETWORKS=foreign expect_refusal network '其他项目网络'
DATA_ROOT=/srv/docker expect_refusal root '自定义目录'
SERVICE_ACTIVE=1 expect_refusal containerd 'containerd 中存在其他项目'
printf stored > "$host/var/lib/containerd/foreign"
expect_refusal stopped-containerd 'containerd 已停止'
rm "$host/var/lib/containerd/foreign"
# Success also accepts anonymous volumes attached only to project containers.
VOLUMES=anonymous docker_purge_preflight
jq -e '.phase=="prepared" and .bridges==["docker0"]' "$ROOT/state/docker-purge.json" >/dev/null
printf image-layer > "$host/var/lib/docker/image"
printf cached-data > "$host/var/lib/containerd/cache"
if (APT_FAIL=1 purge_docker) > "$scratch/output" 2>&1; then echo 'Failed apt purge reported success'; exit 1; fi
[[ -f $host/var/lib/docker/image && $(jq -r .phase "$ROOT/state/docker-purge.json") == stopping ]]
# Retry must refuse new workloads if Docker was restarted.
if (SERVICE_ACTIVE=1 CONTAINERS=foreign docker_purge_preflight) > "$scratch/output" 2>&1; then echo 'Restarted foreign workload accepted'; exit 1; fi
grep -q '其他项目容器' "$scratch/output"
# A mounted data directory is never recursively removed.
if (MOUNT="$host/var/lib/docker" docker_purge_preflight) > "$scratch/output" 2>&1; then echo 'Mounted data accepted'; exit 1; fi
[[ -f $host/var/lib/docker/image ]]
docker_purge_preflight
purge_docker
[[ ! -e $host/var/lib/docker && ! -e $host/var/lib/containerd && ! -e $host/etc/docker ]]
[[ $(jq -r .phase "$ROOT/state/docker-purge.json") == removed ]]
grep -qx 'disable --now docker.socket' "$scratch/systemctl"
grep -qx 'purge -y docker-ce' "$scratch/apt"
grep -qx 'link delete dev docker0 type bridge' "$scratch/ip"
[[ -s $scratch/firewall ]]
docker_purge_preflight
purge_docker
echo 'PASS: Docker purge guards other workloads, removes engine data/bridges and retries package failures'
