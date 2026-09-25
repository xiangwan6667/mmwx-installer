#!/usr/bin/env bash
# Independent installer. Never invoke the upstream install script.
set -Eeuo pipefail
umask 077
ROOT=/opt/mmwx-installer
UPSTREAM=iluobei/miaomiaowuX
SCRIPT_VERSION=0.2.12
SCRIPT_UPDATE_CHECKED=0 SCRIPT_UPDATE_VERSION=''
CHANNEL='' DOMAIN='' PREFIX='' ZONE_NAME='' TOKEN_FILE='' ACTION='' ACCEPT=0 TEMP_TOKEN='' CHANNEL_EXPLICIT=0 STAGE=0 VERSION=''
APP_IMAGE='' CADDY_IMAGE='' PG_IMAGE=postgres:18-alpine
SELF=$(readlink -f "${BASH_SOURCE[0]}")
TRACE_LOG='' TRACE_ACTION=''

paint() { if [[ -t 1 && -z ${NO_COLOR:-} ]]; then printf '\033[%sm%s\033[0m\n' "$1" "$2"; else printf '%s\n' "$2"; fi; }
info() { paint 36 "  $*"; }
die() { trace_event ERROR "exit=1 source=${BASH_SOURCE[1]##*/}:${BASH_LINENO[0]} function=${FUNCNAME[1]:-main} $*"; paint 31 "  错误：$*" | trace_redact >&2; exit 1; }
section() { printf '\n'; paint '1;36' "  $*"; printf '  ────────────────────────────────────────\n'; }
trace_redact() (
  set +x
  local path item line value
  local -a secrets=()
  for path in "$ROOT/config/cloudflare.token" "$ROOT/cloudflare.token" "${TOKEN_FILE:-}" "${TEMP_TOKEN:-}" \
    "$ROOT/config/caddy.env" "$ROOT/config/postgres.env" "$ROOT/config/app.env" \
    "$ROOT/state/caddy-token-change/old.token" "$ROOT/state/caddy-token-change/candidate.token"; do
    [[ -n $path && -f $path ]] || continue
    [[ -r $path ]] || { printf '凭据不可读，已隐藏日志输出。\n'; cat >/dev/null; return 1; }
    while IFS= read -r item || [[ -n $item ]]; do
      if [[ $path == *.env ]]; then
        case "${item%%=*}" in *TOKEN*|*PASSWORD*|*SECRET*) value=${item#*=};; *) continue;; esac
      else value=$item; fi
      value=${value%$'\r'}; value=${value#\"}; value=${value%\"}; value=${value#\'}; value=${value%\'}
      [[ -z $value ]] || secrets+=("$value")
    done < "$path"
  done
  while IFS= read -r line || [[ -n $line ]]; do
    for value in "${secrets[@]}"; do line=${line//"$value"/[REDACTED]}; done
    printf '%s\n' "$line"
  done
)
trace_event() {
  local level=$1
  shift
  [[ -n ${TRACE_LOG:-} && -f $TRACE_LOG ]] || return 0
  printf '%s %-12s %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$level" "$*" | trace_redact >> "$TRACE_LOG" || return 0
}
trace_start() {
  local directory=$ROOT/state/logs
  [[ ! -L $ROOT && ! -L $ROOT/state && ! -L $directory ]] || die '日志目录不能是符号链接。'
  mkdir -p "$directory" || return 1
  chmod 700 "$directory" || return 1
  TRACE_ACTION=$1
  TRACE_LOG=$(mktemp "$directory/task-$(date +%Y%m%d-%H%M%S)-XXXXXX.log") || return 1
  chmod 600 "$TRACE_LOG" || return 1
  trace_event START "action=$TRACE_ACTION version=$SCRIPT_VERSION arch=$(uname -m) pid=$$"
}
trace_finish() {
  trace_event FINISH "action=${TRACE_ACTION:-unknown} exit=$1"
  if [[ $1 != 0 && -n ${TRACE_LOG:-} && -f $TRACE_LOG ]]; then printf '  任务日志：%s（mmwx trace）\n' "$TRACE_LOG" >&2; fi
}
trace_error() {
  trace_event ERROR "exit=$1 source=install.sh:$2 function=$3"
  printf '操作未完成，可运行 mmwx 继续（第 %s 行，退出码 %s）。\n' "$2" "$1" >&2
}
trace_latest() {
  [[ -d $ROOT/state/logs ]] || return 0
  find "$ROOT/state/logs" -maxdepth 1 -type f -name 'task-*.log' -printf '%T@ %f\n' | LC_ALL=C sort -nr | sed -n '1s/^[^ ]* //p'
}
trace_show() {
  local file
  file=$(trace_latest)
  [[ -n $file ]] || { info '暂无任务日志。'; return 0; }
  info "任务日志：$ROOT/state/logs/$file"
  tail -n 120 "$ROOT/state/logs/$file" | trace_redact
}
trace_follow() {
  local file
  file=$(trace_latest)
  [[ -n $file ]] || { info '暂无任务日志。'; return 0; }
  info '实时追踪任务；Ctrl+C 退出。'
  tail -n 80 -F "$ROOT/state/logs/$file"
}
logs_menu() {
  local choice index file
  local -a files=()
  while true; do
    section '日志与诊断'
    printf '  1  服务日志\n  2  最近任务\n  3  历史任务\n  4  实时追踪最近任务\n  5  证书申请诊断\n  0  返回\n'
    choice=$(ask '选择：')
    case "$choice" in
      1) load_state; caddy_redacted_command dc logs --tail 80 caddy mmwx;;
      2) trace_show;;
      3)
        files=()
        if [[ -d $ROOT/state/logs ]]; then mapfile -t files < <(find "$ROOT/state/logs" -maxdepth 1 -type f -name 'task-*.log' -printf '%T@ %f\n' | LC_ALL=C sort -nr | sed -n '1,20s/^[^ ]* //p'); fi
        if ((${#files[@]} == 0)); then info '暂无任务日志。'; continue; fi
        for index in "${!files[@]}"; do printf '  %s  %s\n' "$((index+1))" "${files[$index]}"; done
        choice=$(ask '任务编号（回车返回）：')
        [[ $choice =~ ^[1-9][0-9]?$ && $choice -le ${#files[@]} ]] || continue
        file=$ROOT/state/logs/${files[$((choice-1))]}
        tail -n 200 "$file" | trace_redact;;
      4) (trap 'exit 0' INT TERM; trace_follow) || true;;
      5) caddy_tls_diagnose '' || true;;
      0|'') return 0;; *) info '无效选择。';;
    esac
  done
}
trace_step_command() (
  set +x
  set -o pipefail
  "$@" 2>&1 | trace_redact
)
run_step() (
  local label=$1 logfile pid code=0 elapsed=0 source=${BASH_SOURCE[1]##*/}:${BASH_LINENO[0]} command_name=${2##*/}
  shift
  mkdir -p "$ROOT/state/logs" || return 1
  logfile=$(mktemp "$ROOT/state/logs/step-$(date +%Y%m%d-%H%M%S)-XXXXXX.log") || return 1
  printf 'step=%s command=%s source=%s version=%s\n' "$label" "$command_name" "$source" "$SCRIPT_VERSION" | trace_redact > "$logfile"
  trace_event STEP_START "step=$label command=$command_name source=$source log=$logfile"
  printf '  · %s\n' "$label"
  # Separate process group covers wrappers (dc) and their external children.
  set -m
  trace_step_command "$@" >> "$logfile" 2>&1 &
  pid=$!
  trap 'kill -TERM -- "-$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; trace_event INTERRUPTED "step=$label exit=130 log=$logfile"; printf "\n  已中断；日志：%s\n" "$logfile"; exit 130' INT TERM
  if [[ -t 1 ]]; then
    while kill -0 "$pid" 2>/dev/null; do
      printf '\r  · %s … %ss' "$label" "$elapsed"
      sleep 1
      elapsed=$((elapsed+1))
    done
    printf '\r\033[K'
  fi
  wait "$pid" 2>/dev/null || code=$?
  printf 'exit=%s\n' "$code" >> "$logfile"
  if [[ $code == 0 ]]; then trace_event STEP_OK "step=$label exit=0"; printf '  ✓ %s\n' "$label"; else
    trace_event STEP_FAILED "step=$label exit=$code source=$source log=$logfile"
    if [[ -n ${TRACE_LOG:-} && -f $TRACE_LOG ]]; then tail -n 20 "$logfile" | trace_redact >> "$TRACE_LOG"; fi
    printf '  ✗ %s\n' "$label" >&2
    tail -n 12 "$logfile" >&2
    printf '  完整日志：%s\n' "$logfile" >&2
  fi
  return "$code"
)
ask() { local value; read -r -p "$1" value </dev/tty || die '无法读取终端，请下载脚本后运行。'; printf '%s' "$value"; }
is_yes() { [[ $1 == y || $1 == Y ]]; }
confirm() {
  local answer
  while true; do
    answer=$(ask "$1 [y/n]：") || return 1
    case "$answer" in y|Y) return 0;; n|N|'') return 1;; *) printf '请输入 y 或 n。\n' >&2;; esac
  done
}
join_domain() {
  [[ $1 =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || return 1
  valid_domain "$2" || return 1
  valid_domain "$1.$2" || return 1
  printf '%s.%s\n' "$1" "$2"
}
get() { curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 15 --max-time 90 --retry 2 "$@"; }
dc() {
  local config=$ROOT/config
  if [[ ! -f $config/compose.yaml && -f $ROOT/compose.yaml ]]; then config=$ROOT; fi
  docker compose --project-name mmwx-installer --project-directory "$config" -f "$config/compose.yaml" "$@"
}
ensure_layout() {
  local name pair source target
  if [[ -f $ROOT/state.json || -f $ROOT/progress.json || -d $ROOT/.layout-migration ]]; then
    [[ ! -L $ROOT ]] || die '安装目录不能是符号链接。'
    info '整理项目目录，迁移原数据……'
    mkdir -p "$ROOT/.layout-migration"
    install_command
    systemctl stop mmwx-cf-sync.timer mmwx-cf-sync.service 2>/dev/null || true
    if [[ -f $ROOT/network-backup/state && $(cat "$ROOT/network-backup/state") == pending ]]; then
      systemctl stop mmwx-network-rollback.timer mmwx-network-rollback.service 2>/dev/null || true
      run_step '恢复原网络设置' /bin/bash "$ROOT/network-backup/rollback.sh"
    fi
    if [[ -f $ROOT/compose.yaml ]]; then
      if [[ -n $(docker compose -p mmwx-installer --project-directory "$ROOT" -f "$ROOT/compose.yaml" ps --status running -q) ]]; then
        touch "$ROOT/.layout-migration/was-running"
      fi
      run_step '停止旧目录容器' docker compose -p mmwx-installer --project-directory "$ROOT" -f "$ROOT/compose.yaml" down
    fi
    # The old app directory was named data; stage it before creating the new data parent.
    if [[ ! -f $ROOT/.layout-migration/app-staged ]]; then
      if [[ -d $ROOT/data ]]; then
        [[ ! -e $ROOT/.legacy-app ]] || die '发现重复应用目录，停止迁移。'
        mv "$ROOT/data" "$ROOT/.legacy-app"
      fi
      touch "$ROOT/.layout-migration/app-staged"
    fi
    mkdir -p "$ROOT/config" "$ROOT/data" "$ROOT/certs" "$ROOT/state" "$ROOT/backups"
    for pair in '.legacy-app:data/app' 'postgres-data:data/postgres' 'subscribes:data/subscribes' 'rule_templates:data/rule_templates' 'caddy-data:certs/data' 'caddy-config:certs/config'; do
      source=$ROOT/${pair%%:*}; target=$ROOT/${pair#*:}
      if [[ -e $source ]]; then
        [[ ! -e $target ]] || die "新旧目录同时存在：$target，停止迁移。"
        mv "$source" "$target"
      fi
    done
    for name in compose.yaml Caddyfile postgres.env app.env caddy.env cloudflare.token; do
      if [[ -f $ROOT/$name ]]; then
        [[ ! -e $ROOT/config/$name ]] || die "配置冲突：$name"
        mv "$ROOT/$name" "$ROOT/config/$name"
      fi
    done
    for name in state.json progress.json update.json image-rollback.json cloudflare-v4.txt network-backup; do
      if [[ -e $ROOT/$name ]]; then
        [[ ! -e $ROOT/state/$name ]] || die "状态冲突：$name"
        mv "$ROOT/$name" "$ROOT/state/$name"
      fi
    done
    if [[ -f $ROOT/state/network-backup/rollback.sh ]]; then
      # shellcheck disable=SC2016
      sed -i 's|\$root/network-backup|$root/state/network-backup|g' "$ROOT/state/network-backup/rollback.sh"
    fi
    if [[ -f $ROOT/config/compose.yaml ]]; then
      if [[ -f $ROOT/state/state.json ]]; then load_state; else load_progress; fi
      render_compose > "$ROOT/config/compose.yaml.tmp"
      mv "$ROOT/config/compose.yaml.tmp" "$ROOT/config/compose.yaml"
    fi
    if [[ -f $ROOT/.layout-migration/was-running && -f $ROOT/state/state.json && ! -f $ROOT/state/update.json && ! -f $ROOT/state/image-rollback.json ]]; then
      configure_timezone
      install_units
      apply_firewall
      run_step '启动服务' dc up -d --wait --wait-timeout 300
    fi
    if [[ -f /etc/systemd/system/mmwx-cf-sync.timer ]]; then systemctl start mmwx-cf-sync.timer; fi
    mv "$ROOT/.layout-migration" "$ROOT/state/layout-v2"
    info '目录迁移完成。'
  fi
  mkdir -p "$ROOT/config" "$ROOT/data" "$ROOT/certs" "$ROOT/state" "$ROOT/backups"
}
valid_domain() {
  [[ $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ && ${#1} -le 253 ]]
}
select_release() {
  jq -ce --arg channel "$1" '[.[] | select(.draft == false and (.prerelease == ($channel == "beta"))) | select(.published_at != null)] | sort_by(.published_at) | last | select(. != null)'
}
recent_releases() {
  jq -ce --arg channel "$1" '[.[] | select(.draft == false and .published_at != null and (.prerelease == ($channel == "beta")))] | unique_by(.tag_name) | sort_by(.published_at) | reverse | .[:5]'
}
parse_release_html() {
  python3 -c 'import sys,re,json,html
s=sys.stdin.read()
blocks=re.findall(r"<section\b[^>]*\bid=\"release-([^\"]+)\"[^>]*>(.*?)</section>",s,re.S)
if not blocks:
    # /releases/latest redirects to a single release page.
    m=re.search(r"<a\b(?=[^>]*aria-current=\"page\")(?=[^>]*href=\"/iluobei/miaomiaowuX/releases/tag/([^\"]+)\")[^>]*>",s)
    if m: blocks=[(m.group(1),s)]
rows=[]
for tag,block in blocks:
    date=re.search(r"<relative-time\b[^>]*datetime=\"([^\"]+)\"",block)
    if not date: continue
    pre=bool(re.search(r"<span\b[^>]*class=\"[^\"]*\bLabel\b[^\"]*\"[^>]*>\s*Pre-release\s*</span>",block))
    rows.append(dict(tag_name=html.unescape(tag),published_at=date.group(1),prerelease=pre,draft=False))
if not rows: sys.exit("Unrecognized GitHub release page")
print(json.dumps(rows))'
}
fetch_releases_web() {
  local rows='[]' page html parsed count=${1:-1}
  html=$(get "https://github.com/$UPSTREAM/releases/latest") || return 1
  parsed=$(parse_release_html <<<"$html") || return 1
  rows=$parsed
  for page in $(seq 1 10); do
    html=$(get "https://github.com/$UPSTREAM/releases?page=$page") || return 1
    parsed=$(parse_release_html <<<"$html") || return 1
    rows=$(printf '%s\n%s\n' "$rows" "$parsed" | jq -cs 'add | unique_by(.tag_name)')
    if jq -e --argjson count "$count" '([.[]|select(.prerelease==true)]|length)>=$count and ([.[]|select(.prerelease==false)]|length)>=$count' <<<"$rows" >/dev/null; then break; fi
    [[ $html == *'rel="next"'* || $html == *'>Next<'* ]] || break
  done
  printf '%s\n' "$rows"
}
fetch_releases() {
  local rows='[]' page result
  for page in $(seq 1 20); do
    if ! result=$(get "https://api.github.com/repos/$UPSTREAM/releases?per_page=100&page=$page" 2>/dev/null) || ! jq -e 'type == "array"' <<<"$result" >/dev/null 2>&1; then
      printf '版本 API 暂不可用，改用官方发布页面。\n' >&2
      fetch_releases_web "${1:-1}"
      return
    fi
    rows=$(printf '%s\n%s\n' "$rows" "$result" | jq -cs 'add')
    [[ $(jq length <<<"$result") -eq 100 ]] || break
  done
  printf '%s\n' "$rows"
}
dns_record_action() {
  jq -er --arg ip "$1" 'if (.result|length)==0 then "create" elif (.result|length)==1 and .result[0].type=="A" and .result[0].content==$ip and .result[0].proxied==true then "keep" else error("Conflicting DNS record; no overwrite") end'
}
validate_cidrs() {
  python3 -c 'import sys,ipaddress
rows=sys.stdin.read().splitlines()
assert rows and len(rows)<=100, "empty or excessive Cloudflare list"
for row in rows:
 n=ipaddress.ip_network(row, strict=True)
 assert n.version==4 and n.prefixlen>=8 and n.network_address.is_global and n.broadcast_address.is_global, "unsafe Cloudflare CIDR"
'
}
render_compose() {
  cat <<EOF
services:
  caddy:
    image: $CADDY_IMAGE
    restart: unless-stopped
    ports: ["0.0.0.0:80:80/tcp", "0.0.0.0:443:443/tcp"]
    env_file: ["$ROOT/config/caddy.env"]
    environment: {TZ: Asia/Shanghai}
    volumes:
      - $ROOT/config/Caddyfile:/etc/caddy/Caddyfile:ro
      - $ROOT/certs/data:/data
      - $ROOT/certs/config:/config
      - /usr/share/zoneinfo/Asia/Shanghai:/etc/localtime:ro
      - /usr/share/zoneinfo/Asia/Shanghai:/usr/share/zoneinfo/Asia/Shanghai:ro
    networks: [frontend]
    depends_on:
      mmwx: {condition: service_healthy}
  mmwx:
    image: $APP_IMAGE
    restart: unless-stopped
    env_file: ["$ROOT/config/app.env"]
    environment:
      TZ: Asia/Shanghai
      PORT: "12889"
      MMWX_DATABASE_DRIVER: postgres
      MMWX_DATABASE_HOST: postgres
      MMWX_DATABASE_PORT: "5432"
      MMWX_DATABASE_NAME: mmwx
      MMWX_DATABASE_USER: mmwx
      MMWX_DATABASE_SSLMODE: disable
    volumes:
      - $ROOT/data/app:/app/data
      - $ROOT/data/subscribes:/app/subscribes
      - $ROOT/data/rule_templates:/app/rule_templates
      - /usr/share/zoneinfo/Asia/Shanghai:/etc/localtime:ro
      - /usr/share/zoneinfo/Asia/Shanghai:/usr/share/zoneinfo/Asia/Shanghai:ro
    networks: [frontend, database]
    depends_on:
      postgres: {condition: service_healthy}
    healthcheck:
      test: [CMD-SHELL, "wget -q --spider http://127.0.0.1:12889/"]
      interval: 10s
      timeout: 5s
      retries: 18
      start_period: 20s
  postgres:
    image: $PG_IMAGE
    restart: unless-stopped
    env_file: ["$ROOT/config/postgres.env"]
    environment: {POSTGRES_DB: mmwx, POSTGRES_USER: mmwx, TZ: Asia/Shanghai, PGTZ: Asia/Shanghai}
    command: [postgres, -c, timezone=Asia/Shanghai, -c, log_timezone=Asia/Shanghai]
    volumes:
      - $ROOT/data/postgres:/var/lib/postgresql
      - /usr/share/zoneinfo/Asia/Shanghai:/etc/localtime:ro
      - /usr/share/zoneinfo/Asia/Shanghai:/usr/share/zoneinfo/Asia/Shanghai:ro
    networks: [database]
    healthcheck:
      test: [CMD-SHELL, "pg_isready -U mmwx -d mmwx"]
      interval: 5s
      timeout: 5s
      retries: 20
networks:
  frontend:
    driver: bridge
    enable_ipv6: false
    driver_opts:
      com.docker.network.bridge.name: br-mmwx-front
  database:
    driver: bridge
    internal: true
    enable_ipv6: false
EOF
}
render_caddy() {
  local proxies='' domain=${1:-$DOMAIN} ranges=$ROOT/state/cloudflare-v4.txt
  [[ -f $ranges ]] || ranges=$ROOT/cloudflare-v4.txt
  if [[ -f $ranges ]]; then
    validate_cidrs < "$ranges"
    proxies="trusted_proxies static $(tr '\n' ' ' < "$ranges")"
  fi
  cat <<EOF
{
  servers {
    protocols h1 h2
    $proxies
    client_ip_headers CF-Connecting-IP
  }
}
$domain {
  tls {
    dns cloudflare {env.CF_API_TOKEN}
    resolvers 1.1.1.1 1.0.0.1
  }
  reverse_proxy mmwx:12889
}
EOF
}

preflight() {
  [[ $(uname -s) == Linux && $EUID == 0 ]] || die '请在 Linux 服务器上使用 root 运行。'
  # shellcheck disable=SC1091
  source /etc/os-release
  case "$ID:$VERSION_ID" in debian:12|debian:13|ubuntu:22.04|ubuntu:24.04|ubuntu:26.04) ;; *) die '支持 Debian 12/13、Ubuntu 22.04/24.04/26.04。';; esac
  case $(uname -m) in x86_64|aarch64) ;; *) die '仅支持 AMD64 / ARM64。';; esac
  [[ -d /run/systemd/system ]] || die '需要 systemd，容器内或普通 chroot 不受支持。'
  [[ ${SSH_CONNECTION:-} != *:* ]] || die '当前 SSH 使用 IPv6；请通过 IPv4 重新连接后运行。'
  ip -4 route show default | grep -q . || die '未发现 IPv4 默认路由。'
  if command -v docker >/dev/null; then
    docker info >/dev/null 2>&1 || die 'Docker 已安装但无法连接，请先检查，不会覆盖现有环境。'
    local foreign
    foreign=$(docker ps -a --format '{{.Names}} {{.Label "com.docker.compose.project"}}' | awk '$2 != "mmwx-installer" {print $1}')
    [[ -z $foreign ]] || die "发现其他容器：$foreign。仅支持全新环境。"
    if [[ ! -f $ROOT/state/state.json && ! -f $ROOT/state/progress.json ]] && [[ -n $(docker ps -aq) ]]; then die '发现已有容器，停止安装。'; fi
  fi
  if [[ ! -f $ROOT/state/state.json ]]; then
    for service in nginx caddy apache2 httpd mmwx postgresql; do
      if systemctl list-unit-files --no-legend "$service.service" 2>/dev/null | grep -q "^$service.service"; then
        die "发现已有服务 $service，请使用全新环境。"
      fi
    done
    [[ -z $(ss -H -lnt '( sport = :80 or sport = :443 )') ]] || die '80 或 443 已被占用。'
    for path in /etc/mmwx /opt/miaomiaowux; do [[ ! -e $path ]] || die "发现已有安装：$path"; done
    if [[ -e /usr/local/bin/mmwx || -L /usr/local/bin/mmwx ]]; then
      [[ $(readlink -f /usr/local/bin/mmwx) == /usr/local/sbin/mmwx-installer ]] || die '发现已有 mmwx 命令。'
    fi
    [[ ! -e $ROOT/config/compose.yaml || -f $ROOT/state/progress.json ]] || die "发现未知安装文件：$ROOT。"
  fi
}
dependencies() {
  local package
  local -a missing=()
  for package in ca-certificates curl jq python3 ufw ipset openssl tzdata; do
    if [[ $(dpkg-query -W -f='${Status}' "$package" 2>/dev/null) != 'install ok installed' ]]; then missing+=("$package"); fi
  done
  if ((${#missing[@]}==0)); then info '依赖检查完成，全部已安装。'; return; fi
  info "补充依赖：${missing[*]}"
  run_step '刷新软件包索引' apt-get update -qq
  run_step '安装缺失依赖' env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
}
configure_timezone() {
  if [[ ! -f /usr/share/zoneinfo/Asia/Shanghai ]]; then
    run_step '安装时区数据' env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tzdata
  fi
  timedatectl set-timezone Asia/Shanghai
}
install_docker() {
  if ! command -v docker >/dev/null; then
    # shellcheck disable=SC1091
    source /etc/os-release
    install -d -m 0755 /etc/apt/keyrings
    get "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
    chmod 0644 /etc/apt/keyrings/docker.asc
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' "$(dpkg --print-architecture)" "$ID" "$VERSION_CODENAME" > /etc/apt/sources.list.d/mmwx-docker.list
    run_step '刷新 Docker 软件源' apt-get update -qq
    run_step '安装 Docker 和 Compose' env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    run_step '启用 Docker 服务' systemctl enable --now docker
  fi
  docker compose version >/dev/null || die '缺少 Docker Compose 插件。'
  if [[ -f /etc/docker/daemon.json ]]; then
    jq -e '(."firewall-backend" // "iptables") == "iptables" and (.ipv6 // false) == false and (.iptables // true) == true' /etc/docker/daemon.json >/dev/null || die 'Docker 网络配置不兼容；请使用全新环境。'
  fi
  iptables -nL DOCKER-USER >/dev/null || die '需要 Docker iptables 后端的 DOCKER-USER 链。'
}
verify_caddy_module() {
  local image=$1 modules
  # Keep the producer alive until it has finished writing.  Piping directly
  # to grep can make docker receive SIGPIPE when the match appears early.
  if ! modules=$(docker run --rm --network none "$image" caddy list-modules); then
    printf '%s\n' "$modules"
    return 2
  fi
  printf '%s\n' "$modules"
  grep -Fxq 'dns.providers.cloudflare' <<<"$modules" || return 1
}
build_caddy() {
  local builddir architecture asset
  case $(uname -m) in x86_64) architecture=amd64;; aarch64) architecture=arm64;; *) die '不支持的架构。';; esac
  asset="caddy-linux-$architecture.gz"
  builddir=$(mktemp -d)
  info '下载预编译的 Caddy + Cloudflare 模块（服务器无需编译）……'
  run_step '下载 Caddy DNS 模块' get "https://github.com/xiangwan6667/mmwx-installer/releases/download/v0.1.0-rc.1/$asset" -o "$builddir/$asset" || { rm -rf "$builddir"; die 'Caddy 下载失败，详情见任务日志。'; }
  run_step '下载 Caddy 校验文件' get 'https://github.com/xiangwan6667/mmwx-installer/releases/download/v0.1.0-rc.1/SHA256SUMS' -o "$builddir/SHA256SUMS" || { rm -rf "$builddir"; die 'Caddy 校验文件下载失败。'; }
  (cd "$builddir"; grep -E "^[a-f0-9]{64}  $asset$" SHA256SUMS | sha256sum --status -c -) || { rm -rf "$builddir"; die 'Caddy 下载校验失败。'; }
  run_step '解压 Caddy DNS 模块' gzip -dk "$builddir/$asset" || { rm -rf "$builddir"; die 'Caddy 解压失败，详情见任务日志。'; }
  mv "$builddir/${asset%.gz}" "$builddir/caddy"
  chmod 0755 "$builddir/caddy"
  cat > "$builddir/Dockerfile" <<'EOF'
FROM caddy:2.11.4
COPY caddy /usr/bin/caddy
EOF
  info '组装 Caddy 容器镜像……'
  run_step '组装 Caddy 镜像' docker build --pull -t mmwx-installer-caddy:2.11.4-cf0.2.4 "$builddir" || { rm -rf "$builddir"; die 'Caddy 构建失败，请检查网络、内存和磁盘。'; }
  rm -rf "$builddir"
  CADDY_IMAGE=mmwx-installer-caddy:2.11.4-cf0.2.4
  local module_status=0
  run_step '验证 Caddy Cloudflare 模块' verify_caddy_module "$CADDY_IMAGE" || module_status=$?
  case $module_status in
    1) die 'Caddy 缺少 Cloudflare 模块。';;
    2) die '无法执行 Caddy 模块检查，请检查 Docker。';;
    0) :;;
    *) die 'Caddy 模块检查失败，请检查 Docker。';;
  esac
}
channel_name() { if [[ $1 == beta ]]; then printf '测试版'; else printf '正式版'; fi; }
select_version_menu() {
  local pages=$1 recent number count selected
  section '指定版本'
  printf '  1  正式版
  2  测试版（Beta）
'
  number=$(ask '选择通道 [1]：') || die '无法读取通道选择。'
  case "$number" in ''|1) CHANNEL=stable;; 2) CHANNEL=beta;; *) die '无效通道。';; esac
  recent=$(recent_releases "$CHANNEL" <<<"$pages")
  count=$(jq length <<<"$recent")
  [[ $count -gt 0 ]] || die "没有可用的$(channel_name "$CHANNEL")。"
  printf '
  最近 %s 个%s
' "$count" "$(channel_name "$CHANNEL")"
  jq -r 'to_entries[] | "  \(.key+1)  \(.value.tag_name)    \(.value.published_at[:10])"' <<<"$recent"
  number=$(ask '版本编号：') || die '无法读取版本选择。'
  [[ $number =~ ^[1-5]$ && $number -le $count ]] || die '无效编号。'
  selected=$(jq -c --argjson index "$((number-1))" '.[$index]' <<<"$recent")
  VERSION=$(jq -r .tag_name <<<"$selected")
}
# 0: published for this host; 10: missing tag/repository; 11: missing platform;
# 20: check failed (transport, access, rate limit or invalid registry response).
check_app_image() (
  set +x
  local version=${1:-} arch dir logfile status token kind digest
  local base=https://ghcr.io/v2/iluobei/miaomiaowux
  local accept='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'
  [[ $version =~ ^v?[0-9][A-Za-z0-9._-]*$ && ${#version} -le 128 ]] || return 20
  case "$(uname -m)" in x86_64) arch=amd64;; aarch64|arm64) arch=arm64;; *) return 20;; esac
  mkdir -p "$ROOT/state/logs" || return 20
  logfile=$ROOT/state/logs/image-check.log
  dir=$(mktemp -d) || return 20
  trap 'rm -rf "$dir"' EXIT
  printf 'Version %s; platform linux/%s\n' "$version" "$arch" >> "$logfile" || return 20
  # Keep registry credentials out of process arguments, output and persistent logs.
  image_check_request() {
    local phase=$1 url=$2 code
    shift 2
    if status=$(curl -q --proto '=https' --proto-redir '=https' --tlsv1.2 -sSL \
      --connect-timeout 10 --max-time 30 --max-redirs 3 \
      -o "$dir/body" -w '%{http_code}' "$@" "$url" 2>> "$logfile"); then
      printf '%s HTTP %s\n' "$phase" "$status" >> "$logfile"
    else
      code=$?
      printf '%s transport error %s (HTTP %s)\n' "$phase" "$code" "$status" >> "$logfile"
      return 20
    fi
  }
  image_check_error() {
    printf '%s\n' "$1" >> "$logfile"
    printf '  镜像检查未完成：%s；日志：%s\n' "$1" "$logfile" >&2
    return 20
  }
  image_check_request token 'https://ghcr.io/token?service=ghcr.io&scope=repository:iluobei/miaomiaowux:pull' || return 20
  [[ $status == 200 ]] || { image_check_error 'GHCR 授权请求失败'; return 20; }
  token=$(jq -ers 'select(length==1) | .[0] | (.token // .access_token) | select(type=="string" and test("^[A-Za-z0-9._~+/-]+=*$"))' "$dir/body" 2>/dev/null) || { image_check_error 'GHCR 授权响应异常'; return 20; }
  printf 'Authorization: Bearer %s\n' "$token" > "$dir/headers" || return 20
  unset token
  image_check_request manifest "$base/manifests/${version#v}" -H "@$dir/headers" -H "Accept: $accept" || return 20
  if [[ $status == 404 ]] && jq -es 'length==1 and (.[0] | (.errors|type=="array" and length>0) and all(.errors[]; .code=="MANIFEST_UNKNOWN" or .code=="NAME_UNKNOWN"))' "$dir/body" >/dev/null 2>&1; then return 10; fi
  [[ $status == 200 ]] || { image_check_error 'GHCR 镜像查询失败'; return 20; }
  kind=$(jq -ers 'select(length==1) | .[0] | select(.schemaVersion==2) | .mediaType | select(type=="string")' "$dir/body" 2>/dev/null) || { image_check_error '镜像清单格式异常'; return 20; }
  case "$kind" in
    application/vnd.oci.image.index.v1+json|application/vnd.docker.distribution.manifest.list.v2+json)
      jq -e '(.manifests|type=="array") and all(.manifests[];
        (.mediaType=="application/vnd.oci.image.manifest.v1+json" or .mediaType=="application/vnd.docker.distribution.manifest.v2+json") and
        (.digest|type=="string" and test("^sha256:[a-f0-9]{64}$")) and (.size|type=="number" and .>=0) and
        (.platform.os|type=="string" and length>0) and (.platform.architecture|type=="string" and length>0))' "$dir/body" >/dev/null 2>&1 || { image_check_error '镜像架构清单异常'; return 20; }
      if jq -e --arg arch "$arch" 'any(.manifests[]; .platform.os=="linux" and .platform.architecture==$arch)' "$dir/body" >/dev/null; then return 0; fi
      printf 'No linux/%s image in manifest index\n' "$arch" >> "$logfile"
      return 11;;
    application/vnd.oci.image.manifest.v1+json|application/vnd.docker.distribution.manifest.v2+json)
      digest=$(jq -er 'select((.layers|type=="array") and
        (.config.mediaType=="application/vnd.oci.image.config.v1+json" or .config.mediaType=="application/vnd.docker.container.image.v1+json") and
        (.config.size|type=="number" and .>=0)) | .config.digest | select(type=="string" and test("^sha256:[a-f0-9]{64}$"))' "$dir/body" 2>/dev/null) || { image_check_error '镜像配置描述异常'; return 20; }
      image_check_request config "$base/blobs/$digest" -H "@$dir/headers" || return 20
      [[ $status == 200 ]] || { image_check_error '镜像配置查询失败'; return 20; }
      jq -es 'length==1 and (.[0] | (.os|type=="string" and length>0) and (.architecture|type=="string" and length>0))' "$dir/body" >/dev/null 2>&1 || { image_check_error '镜像架构配置异常'; return 20; }
      if jq -e --arg arch "$arch" '.os=="linux" and .architecture==$arch' "$dir/body" >/dev/null; then return 0; fi
      printf 'Config does not support linux/%s\n' "$arch" >> "$logfile"
      return 11;;
    *) image_check_error '镜像清单类型不受支持'; return 20;;
  esac
)
pull_app_version() {
  [[ $VERSION =~ ^v?[0-9][A-Za-z0-9._-]*$ ]] || die '上游版本号格式异常。'
  APP_IMAGE="ghcr.io/iluobei/miaomiaowux:${VERSION#v}"
  run_step "下载主控 $VERSION" docker pull "$APP_IMAGE" || die "镜像下载失败：$VERSION，请检查网络或稍后重试。"
  APP_IMAGE=$(docker image inspect "$APP_IMAGE" --format '{{index .RepoDigests 0}}') || die '读取主控镜像摘要失败，未切换版本。'
}
choose_version() {
  local pages selected mode choice=''
  pages=$(fetch_releases 5) || die '无法读取官方版本，请检查 GitHub 网络连接后用 mmwx 继续。'
  section '主控版本'
  for mode in stable beta; do
    selected=$(select_release "$mode" <<<"$pages") || selected=null
    printf '  %s  %s
' "$(channel_name "$mode")" "$(jq -r 'if .==null then "暂无" else .tag_name end' <<<"$selected")"
  done
  if [[ -z $CHANNEL || ( $ACTION == update && $CHANNEL_EXPLICIT == 0 && $ACCEPT == 0 ) ]]; then
    printf '
  1  最新正式版
  2  最新测试版
  3  指定版本
'
    choice=$(ask "选择 [回车沿用$(channel_name "${CHANNEL:-stable}")]：") || die '无法读取版本选择。'
    case "$choice" in
      '') CHANNEL=${CHANNEL:-stable};; 1) CHANNEL=stable;; 2) CHANNEL=beta;;
      3) select_version_menu "$pages";; *) die '无效选择。';;
    esac
  fi
  [[ $CHANNEL == stable || $CHANNEL == beta ]] || die 'channel 只能是 stable 或 beta。'
  if [[ $choice != 3 ]]; then
    selected=$(select_release "$CHANNEL" <<<"$pages") || die '所选通道没有可用版本。'
    VERSION=$(jq -r .tag_name <<<"$selected")
  fi
  if [[ $choice == 3 ]]; then
    select_available_image "$pages" specified || return 1
  else
    select_available_image "$pages" latest || return 1
  fi
  pull_app_version
}

image_unavailable_notice() {
  case "$2" in
    10) info "$1 镜像尚未发布。";;
    11) info "$1 暂无适合本机架构的镜像。";;
    *) die "镜像仓库检查失败，可能是网络、限流或鉴权错误。请稍后重试；日志：$ROOT/state/logs/image-check.log";;
  esac
}
select_available_image() {
  local pages=$1 mode=$2 status candidate choice
  while true; do
    info "检查主控 $VERSION 镜像……"
    if check_app_image "$VERSION"; then return 0; else status=$?; fi
    image_unavailable_notice "$VERSION" "$status"
    if [[ $mode == specified ]]; then
      printf '\n  1  重试\n  2  重新选择版本\n  0  返回\n\n'
      choice=$(ask '选择 [0]：') || die '无法读取版本选择。'
      case "$choice" in
        1) continue;;
        2) select_version_menu "$pages"; continue;;
        ''|0) info '已取消版本选择。'; return 1;;
        *) die '无效选择。';;
      esac
    fi
    # Latest mode considers only earlier releases in the selected channel.
    while IFS= read -r candidate; do
      info "检查主控 $candidate 镜像……"
      if check_app_image "$candidate"; then
        if confirm "使用上一可用$(channel_name "$CHANNEL") $candidate？"; then
          VERSION=$candidate
          return 0
        fi
        info '已取消版本选择。'
        return 1
      else status=$?; fi
      image_unavailable_notice "$candidate" "$status"
    done < <(recent_releases "$CHANNEL" <<<"$pages" | jq -r '.[1:][].tag_name')
    die '该通道最近版本均无适合本机的镜像，请稍后重试或指定其他通道。'
  done
}

dns_check() {
  [[ -f $TOKEN_FILE && ! -L $TOKEN_FILE ]] || die 'Token 文件不存在或为符号链接。'
  [[ $(stat -c %u "$TOKEN_FILE") == 0 && $(stat -c %a "$TOKEN_FILE") == 600 ]] || die 'Token 文件必须属于 root，权限为 600。'
  local token headers zone records ipv4 operation payload response zones chosen count page total=1 allzones='[]'
  token=$(cat "$TOKEN_FILE")
  [[ $token =~ ^[A-Za-z0-9_.-]+$ && ${#token} -ge 20 && ${#token} -le 256 ]] || die 'Token 格式异常，请检查是否误复制了空格或引号。'
  headers=$(mktemp); printf 'Authorization: Bearer %s\n' "$token" > "$headers"
  for ((page=1; page<=total; page++)); do
    response=$(get -H "@$headers" "https://api.cloudflare.com/client/v4/zones?status=active&per_page=50&page=$page") || { rm -f "$headers"; die '无法读取域名，请检查 Token。'; }
    jq -e '.success == true and (.result|type)=="array"' <<<"$response" >/dev/null || { rm -f "$headers"; die 'Token 需要 Zone Read 权限。'; }
    zones=$(jq -c .result <<<"$response")
    allzones=$(printf '%s\n%s\n' "$allzones" "$zones" | jq -cs 'add')
    total=$(jq -r '.result_info.total_pages // 1' <<<"$response")
    [[ $total =~ ^[0-9]+$ && $total -le 100 ]] || { rm -f "$headers"; die '域名列表异常。'; }
  done
  zones=$allzones
  if [[ -n $DOMAIN ]]; then
    chosen=$(jq -ce --arg domain "$DOMAIN" '[.[] | .name as $z | select($domain == $z or ($domain | endswith("."+$z)))] | sort_by(.name|length) | last | select(.!=null)' <<<"$zones") || { rm -f "$headers"; die 'Token 未授权这个主域名，或 Cloudflare 尚未 Active。'; }
  else
    if [[ -n $ZONE_NAME ]]; then zones=$(jq -c --arg zone "$ZONE_NAME" '[.[]|select(.name==$zone)]' <<<"$zones"); fi
    count=$(jq length <<<"$zones")
    [[ $count -gt 0 ]] || { rm -f "$headers"; die '没有可用主域名，请完成 Cloudflare 托管并授权 Token。'; }
    if [[ $count -eq 1 ]]; then chosen=$(jq -c '.[0]' <<<"$zones"); else
      jq -r 'to_entries[] | "\(.key+1). \(.value.name)"' <<<"$zones"
      page=$(ask '选择主域名编号：')
      [[ $page =~ ^[1-9][0-9]*$ && ${#page} -lt 5 && $page -le $count ]] || { rm -f "$headers"; die '无效编号。'; }
      chosen=$(jq -c --argjson index "$((page-1))" '.[$index]' <<<"$zones")
    fi
    ZONE_NAME=$(jq -r .name <<<"$chosen")
    info "主域名：$ZONE_NAME"
    [[ -n $PREFIX ]] || PREFIX=$(ask '子域名前缀 [mmwx]：')
    PREFIX=${PREFIX:-mmwx}
    DOMAIN=$(join_domain "$PREFIX" "$ZONE_NAME") || { rm -f "$headers"; die '前缀只用小写字母、数字或连字符，如 cs。'; }
  fi
  valid_domain "$DOMAIN" || { rm -f "$headers"; die '域名格式不正确。'; }
  zone=$(jq -r .id <<<"$chosen")
  records=$(get -H "@$headers" "https://api.cloudflare.com/client/v4/zones/$zone/dns_records?name=$DOMAIN") || { rm -f "$headers"; die 'DNS 查询失败。'; }
  ipv4=$(ip -j -4 address show scope global | python3 -c 'import sys,json,ipaddress
addresses=[a["local"] for i in json.load(sys.stdin) for a in i.get("addr_info",[]) if ipaddress.ip_address(a["local"]).is_global]
if len(addresses)!=1: sys.exit("需要唯一的网卡公网 IPv4；多地址或 NAT 主机请先确认网络配置。")
print(addresses[0])') || { rm -f "$headers"; die '无法安全确定源站 IPv4。'; }
  python3 -c 'import ipaddress,sys; a=ipaddress.ip_address(sys.argv[1]); assert a.version==4 and a.is_global' "$ipv4"
  jq -e '.success==true and (.result|type)=="array"' <<<"$records" >/dev/null || { rm -f "$headers"; die 'Cloudflare DNS 查询未成功。'; }
  operation=$(dns_record_action "$ipv4" <<<"$records") || { rm -f "$headers"; die "域名 $DOMAIN 已有冲突记录，未覆盖。请在 https://dash.cloudflare.com/ 检查同名 A/AAAA/CNAME 记录。"; }
  if [[ $operation == create ]]; then
    payload=$(jq -nc --arg domain "$DOMAIN" --arg ip "$ipv4" '{type:"A",name:$domain,content:$ip,proxied:true,ttl:1,comment:"mmwx-installer"}')
    response=$(get -H "@$headers" -H 'Content-Type: application/json' --data "$payload" "https://api.cloudflare.com/client/v4/zones/$zone/dns_records") || { rm -f "$headers"; die '创建 DNS 记录失败。'; }
    jq -e '.success==true' <<<"$response" >/dev/null || { rm -f "$headers"; die 'Cloudflare 拒绝创建记录，请检查 DNS Edit 权限。'; }
    info "已创建 $DOMAIN → $ipv4，已开启小黄云。"
  else info '已有 DNS 记录完全匹配，直接使用。'; fi
  rm -f "$headers"
  CF_TOKEN=$token
}
token_guide() {
  cat <<'EOF'
先将主域名托管到 Cloudflare（注册商修改 NS，等待 Active），SSL 选「完全（严格）」。
托管：https://dash.cloudflare.com/
Token：https://dash.cloudflare.com/profile/api-tokens
选择「编辑区域 DNS」模板，补充「区域 → 区域 → 读取」权限。
区域资源：选择你的主域名。
脚本自动创建子域名、开启小黄云并申请证书。
EOF
}
fetch_cf() {
  local target=$1 tmp
  tmp=$(mktemp)
  get https://www.cloudflare.com/ips-v4 -o "$tmp" || { rm -f "$tmp"; return 1; }
  validate_cidrs < "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$target"
}
apply_firewall() (
  exec 8>/run/mmwx-cf.lock
  flock -w 180 8 || die '防火墙正在更新，请稍后重试。'
  apply_firewall_rules
)
apply_firewall_rules() {
  local ranges=$ROOT/state/cloudflare-v4.txt cidr
  # An updated manager must still allow Docker to start before legacy layout migration.
  [[ -f $ranges ]] || ranges=$ROOT/cloudflare-v4.txt
  validate_cidrs < "$ranges"
  iptables -N DOCKER-USER 2>/dev/null || true
  ipset create mmwx_cf_next hash:net family inet -exist
  ipset flush mmwx_cf_next
  while IFS= read -r cidr; do ipset add mmwx_cf_next "$cidr"; done < "$ranges"
  ipset create mmwx_cf hash:net family inet -exist
  ipset swap mmwx_cf_next mmwx_cf
  ipset destroy mmwx_cf_next
  iptables-restore --noflush <<'EOF'
*filter
:MMWX-CF - [0:0]
-F MMWX-CF
-A MMWX-CF -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
-A MMWX-CF -i br-mmwx-front -j RETURN
-A MMWX-CF -m set --match-set mmwx_cf src -p tcp -m multiport --dports 80,443 -j RETURN
-A MMWX-CF -j DROP
COMMIT
EOF
  iptables -C DOCKER-USER -o br-mmwx-front -j MMWX-CF 2>/dev/null || iptables -I DOCKER-USER 1 -o br-mmwx-front -j MMWX-CF
}
remove_legacy_cf_rules() {
  # Delete only this installer's old UFW web permits. Descending numbers avoid renumbering errors.
  local numbers number
  command -v ufw >/dev/null || return 0
  numbers=$(LC_ALL=C ufw status numbered | sed -nE 's/^\[[[:space:]]*([0-9]+)\][[:space:]]+80,443\/tcp[[:space:]]+ALLOW IN[[:space:]]+.*[[:space:]]#[[:space:]]mmwx-cf[[:space:]]*$/\1/p' | sort -rn)
  while IFS= read -r number; do
    [[ -n $number ]] || continue
    ufw --force delete "$number" >/dev/null
  done <<<"$numbers"
}
sync_cf() (
  exec 8>/run/mmwx-cf.lock; flock -w 180 8 || { info 'CF 规则正在更新，请稍后重试。'; return 1; }
  if [[ -e $ROOT/state/caddy-token-change ]]; then info 'Token 替换待恢复，本次 CF 同步跳过。'; return 0; fi
  local state=$ROOT/state config=$ROOT/config
  if [[ ! -f $state/state.json && -f $ROOT/state.json ]]; then state=$ROOT; config=$ROOT; fi
  local old=$state/cloudflare-v4.txt new=$state/cloudflare-v4.new
  fetch_cf "$new" || { printf 'Cloudflare IP 更新失败，保留现有规则。\n' >&2; return 1; }
  mv "$new" "$old"
  apply_firewall_rules
  remove_legacy_cf_rules
  if [[ -f $state/state.json ]]; then
    render_caddy "$(jq -er .domain "$state/state.json")" > "$config/Caddyfile.next"
    # Keep the inode: Caddy mounts this individual file.
    cat "$config/Caddyfile.next" > "$config/Caddyfile"
    rm -f "$config/Caddyfile.next"
    if [[ -n $(dc ps --status running -q caddy) ]]; then caddy_step '重载 Caddy 配置' dc exec -T caddy caddy reload --config /etc/caddy/Caddyfile; fi
  fi
)
network_backup_path() {
  if [[ -e $ROOT/state/network-backup || -L $ROOT/state/network-backup ]]; then
    [[ ! -e $ROOT/network-backup && ! -L $ROOT/network-backup ]] || die '发现两份网络备份，请先检查目录。'
    printf '%s\n' "$ROOT/state/network-backup"
  elif [[ -e $ROOT/network-backup || -L $ROOT/network-backup ]]; then
    printf '%s\n' "$ROOT/network-backup"
  else
    printf '%s\n' "$ROOT/state/network-backup"
  fi
}
network_backup_validate() {
  local backup=$1 file value line interface special
  local -A seen=()
  [[ -d $backup && ! -L $backup && ! -L $ROOT && ! -L $ROOT/state ]] || die '网络备份目录异常，停止恢复。'
  [[ -d $backup/ufw && ! -L $backup/ufw ]] || die '网络备份缺少 UFW 规则，停止恢复。'
  special=$(find "$backup/ufw" ! -type f ! -type d -print -quit) || return 1
  [[ -z $special ]] || die '网络备份包含异常规则文件，停止恢复。'
  for file in ufw-default ufw-status ipv6-all ipv6-default ipv6-lo \
    ufw/ufw.conf ufw/user.rules ufw/user6.rules ufw/before.rules ufw/before6.rules ufw/after.rules ufw/after6.rules; do
    [[ -f $backup/$file && ! -L $backup/$file ]] || die "网络备份缺少 $file，停止恢复。"
  done
  value=$(cat "$backup/ufw-status") || return 1
  [[ $value == 'Status: active' || $value == 'Status: inactive' ]] || die 'UFW 初始状态记录无效。'
  for interface in all default lo; do
    value=$(cat "$backup/ipv6-$interface") || return 1
    [[ $value == 0 || $value == 1 ]] || die 'IPv6 初始状态记录无效。'
  done
  if [[ -e $backup/state || -L $backup/state ]]; then
    [[ -f $backup/state && ! -L $backup/state ]] || die '网络恢复状态文件异常。'
    value=$(cat "$backup/state") || return 1
    case "$value" in pending|confirmed|rolled-back|restored) :;; *) die '网络恢复状态无效。';; esac
  fi
  if [[ -e $backup/format || -e $backup/ipv6-interfaces.tsv || -e $backup/sysctl-present || -L $backup/format || -L $backup/ipv6-interfaces.tsv || -L $backup/sysctl-present ]]; then
    for file in format ipv6-interfaces.tsv sysctl-present; do
      [[ -f $backup/$file && ! -L $backup/$file ]] || die '扩展网络备份不完整，停止恢复。'
    done
    [[ $(cat "$backup/format") == 2 ]] || die '网络备份版本不支持。'
    while IFS= read -r line || [[ -n $line ]]; do
      [[ $line =~ ^([a-zA-Z0-9_.:-]{1,15})$'\t'([01])$ ]] || die 'IPv6 网卡备份格式无效。'
      interface=${BASH_REMATCH[1]}; value=${BASH_REMATCH[2]}
      [[ ! -v seen[$interface] ]] || die 'IPv6 网卡备份存在重复记录。'
      seen[$interface]=$value
    done < "$backup/ipv6-interfaces.tsv"
    for interface in all default lo; do
      [[ ${seen[$interface]:-missing} == "$(cat "$backup/ipv6-$interface")" ]] || die 'IPv6 网卡备份不完整或不一致。'
    done
    value=$(cat "$backup/sysctl-present") || return 1
    case "$value" in
      1) [[ -f $backup/sysctl-original && ! -L $backup/sysctl-original ]] || die '缺少原 IPv6 持久配置。';;
      0) [[ ! -e $backup/sysctl-original && ! -L $backup/sysctl-original ]] || die 'IPv6 持久配置备份不一致。';;
      *) die 'IPv6 持久配置记录无效。';;
    esac
  fi
}
network_backup_capture() (
  local backup staged='' interface file value status
  backup=$(network_backup_path) || return 1
  if [[ -e $backup || -L $backup ]]; then network_backup_validate "$backup"; return $?; fi
  [[ ! -L $ROOT && ! -L $ROOT/state ]] || die '安装状态目录不能是符号链接。'
  mkdir -p "$ROOT/state" && chmod 700 "$ROOT/state" || return 1
  staged=$(mktemp -d "$ROOT/state/.network-backup.XXXXXX") || return 1
  trap '[[ -z ${staged:-} ]] || rm -rf -- "$staged"' EXIT
  [[ -d /etc/ufw && ! -L /etc/ufw && -f /etc/default/ufw && ! -L /etc/default/ufw ]] || die 'UFW 配置文件异常，停止网络修改。'
  cp -a /etc/ufw "$staged/ufw" || return 1
  cp -a /etc/default/ufw "$staged/ufw-default" || return 1
  status=$(LC_ALL=C ufw status) || return 1
  printf '%s\n' "${status%%$'\n'*}" > "$staged/ufw-status" || return 1
  : > "$staged/ipv6-interfaces.tsv" || return 1
  for file in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
    [[ -f $file && ! -L $file ]] || die '无法读取 IPv6 网卡状态。'
    interface=${file%/disable_ipv6}; interface=${interface##*/}
    value=$(cat "$file") || return 1
    printf '%s\t%s\n' "$interface" "$value" >> "$staged/ipv6-interfaces.tsv" || return 1
    case "$interface" in all|default|lo) printf '%s\n' "$value" > "$staged/ipv6-$interface" || return 1;; esac
  done
  if [[ -e /etc/sysctl.d/90-mmwx-ipv4-only.conf || -L /etc/sysctl.d/90-mmwx-ipv4-only.conf ]]; then
    [[ -f /etc/sysctl.d/90-mmwx-ipv4-only.conf && ! -L /etc/sysctl.d/90-mmwx-ipv4-only.conf ]] || die 'IPv6 持久配置文件异常，停止网络修改。'
    cp -a /etc/sysctl.d/90-mmwx-ipv4-only.conf "$staged/sysctl-original" || return 1
    printf '1\n' > "$staged/sysctl-present" || return 1
  else
    printf '0\n' > "$staged/sysctl-present" || return 1
  fi
  printf '2\n' > "$staged/format" || return 1
  network_backup_validate "$staged" || return 1
  mv -T "$staged" "$backup" || return 1
  staged=''
)
network_restore_preflight() {
  local backup progress stage
  backup=$(network_backup_path) || return 1
  if [[ -e $backup || -L $backup ]]; then network_backup_validate "$backup"; return $?; fi
  if [[ -e $ROOT/state/state.json || -e $ROOT/state.json || -e $ROOT/state/cloudflare-v4.txt || -e $ROOT/cloudflare-v4.txt || \
    -e /etc/sysctl.d/90-mmwx-ipv4-only.conf || -L /etc/sysctl.d/90-mmwx-ipv4-only.conf ]]; then
    die '原网络备份缺失，无法安全恢复 UFW 和 IPv6；完整卸载已停止。'
  fi
  for progress in "$ROOT/state/progress.json" "$ROOT/progress.json"; do
    [[ -f $progress ]] || continue
    stage=$(jq -er '.stage | select(type=="number" and .>=0 and .<=7 and floor==.)' "$progress") || die '安装进度异常，无法确认原网络配置。'
    [[ $stage -lt 6 ]] || die '安装已修改网络，但原网络备份缺失，停止完全卸载。'
  done
  return 0
}
restore_install_network() (
  local backup interface value status expected file state_tmp=''
  trap '[[ -z $state_tmp ]] || rm -f -- "$state_tmp"' EXIT
  exec 9>/run/mmwx-network.lock || return 1
  flock -w 180 9 || { info '网络设置正在变更，请稍后重试。'; return 1; }
  network_restore_preflight || return 1
  backup=$(network_backup_path) || return 1
  [[ -d $backup ]] || return 0
  [[ -d /etc/ufw && ! -L /etc/ufw && ! -L /etc/default/ufw && ! -L /etc/sysctl.d/90-mmwx-ipv4-only.conf ]] || die '系统网络配置路径异常，停止恢复。'
  # Always repeat an interrupted restore from the untouched original snapshot.
  ufw --force disable || return 1
  find /etc/ufw -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + || return 1
  cp -a "$backup/ufw/." /etc/ufw/ || return 1
  cp -a "$backup/ufw-default" /etc/default/ufw || return 1
  if [[ -f $backup/sysctl-present && $(cat "$backup/sysctl-present") == 1 ]]; then
    cp -a "$backup/sysctl-original" /etc/sysctl.d/90-mmwx-ipv4-only.conf || return 1
  else
    rm -f /etc/sysctl.d/90-mmwx-ipv4-only.conf || return 1
  fi
  expected=$(cat "$backup/ufw-status") || return 1
  if [[ $expected == 'Status: active' ]]; then ufw --force enable || return 1; fi
  # UFW may apply its own sysctls while enabling; restore runtime values last.
  # Writing "all" changes existing interfaces: restore it before individual values.
  for interface in all default lo; do
    value=$(cat "$backup/ipv6-$interface") || return 1
    sysctl -w "net/ipv6/conf/$interface/disable_ipv6=$value" || return 1
  done
  if [[ -f $backup/ipv6-interfaces.tsv ]]; then
    while IFS=$'\t' read -r interface value; do
      case "$interface" in all|default|lo) continue;; esac
      file=/proc/sys/net/ipv6/conf/$interface/disable_ipv6
      [[ -f $file ]] || continue
      sysctl -w "net/ipv6/conf/$interface/disable_ipv6=$value" || return 1
    done < "$backup/ipv6-interfaces.tsv"
  else
    info '旧版备份仅记录全局、默认和 lo 的 IPv6 状态；其他网卡恢复为原全局值。'
  fi
  status=$(LC_ALL=C ufw status) || return 1
  [[ ${status%%$'\n'*} == "$expected" ]] || { info 'UFW 状态未恢复，已保留备份，请重试。'; return 1; }
  for interface in all default lo; do
    [[ $(cat "/proc/sys/net/ipv6/conf/$interface/disable_ipv6") == "$(cat "$backup/ipv6-$interface")" ]] || return 1
  done
  if [[ -f $backup/ipv6-interfaces.tsv ]]; then
    while IFS=$'\t' read -r interface value; do
      file=/proc/sys/net/ipv6/conf/$interface/disable_ipv6
      [[ ! -f $file ]] || [[ $(cat "$file") == "$value" ]] || return 1
    done < "$backup/ipv6-interfaces.tsv"
  fi
  state_tmp=$(mktemp "$backup/.state.XXXXXX") || return 1
  printf 'restored\n' > "$state_tmp" || return 1
  mv "$state_tmp" "$backup/state" || return 1
  state_tmp=''
)
network_setup() {
  local port
  if [[ -f $ROOT/state/network-backup/state ]]; then
    if [[ $(cat "$ROOT/state/network-backup/state") == confirmed ]]; then
      network_is_ready || die '已确认的网络设置发生变化，请检查 UFW/IPv6 后继续。'
      apply_firewall
      remove_legacy_cf_rules
      return
    fi
    if [[ $(cat "$ROOT/state/network-backup/state") == pending ]]; then
      systemctl stop mmwx-network-rollback.timer 2>/dev/null || true
      run_step '恢复原网络设置' /bin/bash "$ROOT/state/network-backup/rollback.sh"
    fi
    systemctl stop mmwx-network-rollback.timer mmwx-network-rollback.service 2>/dev/null || true
    systemctl reset-failed mmwx-network-rollback.service 2>/dev/null || true
  fi
  SSH_PORTS=$(ss -H -lntp | awk '/sshd/ {n=split($4,a,":"); print a[n]}' | sort -nu)
  [[ -n $SSH_PORTS ]] || die '无法识别 sshd 监听端口，停止网络修改。'
  network_backup_capture || die '无法保存安装前的网络配置，未修改网络。'
  fetch_cf "$ROOT/state/cloudflare-v4.txt" || die 'Cloudflare IP 列表获取失败。'
  install_units
  for port in $SSH_PORTS; do run_step "保留 SSH 端口 $port" ufw allow "$port/tcp" comment mmwx-ssh; done
  # Schedule recovery before changing networking; cancelled only after operator acknowledgement.
  cat > "$ROOT/state/network-backup/rollback.sh" <<'EOF'
#!/bin/bash
set -eu
root=/opt/mmwx-installer
exec 9>/run/mmwx-network.lock
flock 9
test "$(cat "$root/state/network-backup/state")" != confirmed || exit 0
printf 'rolled-back\n' > "$root/state/network-backup/state"
ufw disable
cp -a "$root/state/network-backup/ufw/." /etc/ufw/
cp -a "$root/state/network-backup/ufw-default" /etc/default/ufw
rm -f /etc/sysctl.d/90-mmwx-ipv4-only.conf
for interface in all default lo; do sysctl -w "net.ipv6.conf.$interface.disable_ipv6=$(cat "$root/state/network-backup/ipv6-$interface")"; done
if grep -qx 'Status: active' "$root/state/network-backup/ufw-status"; then ufw --force enable; fi
EOF
  chmod 700 "$ROOT/state/network-backup/rollback.sh"
  printf 'pending\n' > "$ROOT/state/network-backup/state"
  run_step '设置网络回退计时器' systemd-run --collect --unit=mmwx-network-rollback --on-active=5m /bin/bash "$ROOT/state/network-backup/rollback.sh"
  cat > /etc/sysctl.d/90-mmwx-ipv4-only.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF
  run_step '关闭 IPv6' sysctl -p /etc/sysctl.d/90-mmwx-ipv4-only.conf
  sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw
  run_step '设置入站策略' ufw default deny incoming
  run_step '设置出站策略' ufw default allow outgoing
  run_step '启用 UFW' ufw --force enable
  apply_firewall
  remove_legacy_cf_rules
  info '请另开终端，通过 IPv4 重新 SSH 登录；5 分钟未确认将恢复网络。'
  if [[ $ACCEPT == 0 ]]; then
    confirm '新 SSH 已登录成功？' || die '未确认，等待网络回退；稍后用 mmwx 继续。'
    confirm_network
  else
    info '新 SSH 终端运行：mmwx confirm-network'
    local attempt
    for ((attempt=0; attempt<56; attempt++)); do
      [[ $(cat "$ROOT/state/network-backup/state") == confirmed ]] && break
      [[ $(cat "$ROOT/state/network-backup/state") != rolled-back ]] || die '网络已自动恢复，安装停止。'
      sleep 5
    done
    [[ $(cat "$ROOT/state/network-backup/state") == confirmed ]] || die '未在期限内确认新 SSH，安装停止并等待网络回退。'
  fi
}
network_is_ready() {
  [[ $(sysctl -n net.ipv6.conf.all.disable_ipv6) == 1 ]] &&
    grep -qx 'IPV6=no' /etc/default/ufw && ufw status | grep -qx 'Status: active'
}
confirm_network() {
  exec 9>/run/mmwx-network.lock; flock 9
  [[ -f $ROOT/state/network-backup/state && $(cat "$ROOT/state/network-backup/state") == pending ]] || die '没有待确认的网络变更，或网络已回退。'
  systemctl is-active --quiet mmwx-network-rollback.timer || die '网络确认期限已过。'
  [[ ${SSH_CONNECTION:-} != *:* ]] || die '请通过 IPv4 SSH 确认。'
  network_is_ready || die '网络状态不符合预期，请等待回退。'
  printf 'confirmed\n' > "$ROOT/state/network-backup/state"
  systemctl stop mmwx-network-rollback.timer
  systemctl reset-failed mmwx-network-rollback.service 2>/dev/null || true
  flock -u 9
  info '已确认 SSH，取消网络自动回退。'
}
install_command() {
  install -d -m 0755 /usr/local/bin /usr/local/sbin
  if [[ $SELF != /usr/local/sbin/mmwx-installer ]]; then
    local staged
    staged=$(mktemp /usr/local/sbin/.mmwx-installer.XXXXXX)
    install -m 0700 "$SELF" "$staged"
    mv -f "$staged" /usr/local/sbin/mmwx-installer
  fi
  if [[ -e /usr/local/bin/mmwx || -L /usr/local/bin/mmwx ]]; then
    [[ $(readlink -f /usr/local/bin/mmwx) == /usr/local/sbin/mmwx-installer ]] || die '已有 mmwx 命令，未覆盖。'
  else ln -s /usr/local/sbin/mmwx-installer /usr/local/bin/mmwx; fi
}
cleanup_downloads() {
  local candidate owner
  # Only known installer filenames and identifying headers; never recurse through user files.
  for candidate in "$SELF" /root/mmwx-install.sh "$PWD/mmwx-install.sh"; do
    [[ $candidate == */mmwx-install.sh && -f $candidate && ! -L $candidate ]] || continue
    owner=$(stat -c %u "$candidate")
    [[ $owner == 0 ]] || continue
    if grep -qx '# Independent installer. Never invoke the upstream install script.' "$candidate" && grep -qx 'ROOT=/opt/mmwx-installer' "$candidate"; then
      rm -f -- "$candidate"
    fi
  done
}
open_installed_menu() {
  exec 7>/run/mmwx-installer.lock
  flock -n 7 || die '另一个维护进程正在运行，请等待。'
  if [[ $SELF != /usr/local/sbin/mmwx-installer ]]; then
    install_command
  fi
  cleanup_downloads
  exec 7>&-
  if [[ $SELF != /usr/local/sbin/mmwx-installer ]]; then
    # Keep only the canonical entrypoint; a stale downloaded file cannot remain the menu parent.
    exec /bin/bash /usr/local/sbin/mmwx-installer "${MENU_ARGUMENTS[@]}"
  fi
  menu
}
install_units() {
  install_command
  install -d -m 0700 /usr/local/lib/mmwx-installer
  local runtime
  runtime=$(mktemp /usr/local/lib/mmwx-installer/.runtime.XXXXXX)
  install -m 0700 "$SELF" "$runtime"
  mv -f "$runtime" /usr/local/lib/mmwx-installer/runtime.sh
  install -d /etc/systemd/system/docker.service.d
  cat > /etc/systemd/system/docker.service.d/mmwx-firewall.conf <<'EOF'
[Service]
ExecStartPre=/usr/local/lib/mmwx-installer/runtime.sh firewall-apply
EOF
  cat > /etc/systemd/system/mmwx-firewall.service <<'EOF'
[Unit]
Description=MMWX Cloudflare container firewall
After=docker.service ufw.service
PartOf=docker.service ufw.service
Before=mmwx-stack.service
[Service]
Type=oneshot
ExecStart=/usr/local/lib/mmwx-installer/runtime.sh firewall-apply
RemainAfterExit=yes
[Install]
WantedBy=docker.service ufw.service multi-user.target
EOF
  cat > /etc/systemd/system/mmwx-cf-sync.service <<'EOF'
[Unit]
Description=Refresh MMWX Cloudflare IPv4 allowlist
After=network-online.target docker.service
[Service]
Type=oneshot
ExecStart=/usr/local/lib/mmwx-installer/runtime.sh firewall-sync
EOF
  cat > /etc/systemd/system/mmwx-cf-sync.timer <<'EOF'
[Unit]
Description=Daily Cloudflare IPv4 list refresh
[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  run_step '注册容器防火墙服务' systemctl enable mmwx-firewall.service
  run_step '启用 CF 网段定时刷新' systemctl enable --now mmwx-cf-sync.timer
}
save_state() {
  jq -n --arg domain "$DOMAIN" --arg channel "$CHANNEL" --arg version "$VERSION" --arg app "$APP_IMAGE" --arg caddy "$CADDY_IMAGE" --arg pg "$PG_IMAGE" '{domain:$domain,channel:$channel,version:$version,app:$app,caddy:$caddy,pg:$pg}' > "$ROOT/state/state.json.tmp"
  mv "$ROOT/state/state.json.tmp" "$ROOT/state/state.json"
}
verify_https() {
  local attempt origin_ready=0 diagnosis=0
  mkdir -p "$ROOT/state/logs"
  info '等待 Caddy 完成 DNS-01 签发并验证 HTTPS（最多五分钟）……'
  for ((attempt=0; attempt<60; attempt++)); do
    origin_ready=0
    if curl -fsS --noproxy '*' --max-time 5 --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/" -o /dev/null 2> "$ROOT/state/logs/origin-check.log"; then
      origin_ready=1
      if curl -fsSL --max-redirs 3 --max-time 15 "https://$DOMAIN/" -o /dev/null 2>> "$ROOT/state/logs/https-check.log"; then return 0; fi
    fi
    sleep 5
  done
  if [[ $origin_ready == 1 ]]; then
    trace_event HTTPS_FAILED '源站 TLS 已通过，公网 HTTPS 未通过。请检查 Cloudflare Full (strict)、DNS 和安全组。'
    if [[ -n ${TRACE_LOG:-} && -f $TRACE_LOG ]]; then tail -n 12 "$ROOT/state/logs/https-check.log" | trace_redact >> "$TRACE_LOG"; fi
    die '源站证书有效，但公网 HTTPS 验证失败。请检查 Cloudflare Full (strict)、DNS 和安全组；详见 mmwx trace。'
  fi
  if [[ -n ${TRACE_LOG:-} && -f $TRACE_LOG ]]; then tail -n 12 "$ROOT/state/logs/origin-check.log" | trace_redact >> "$TRACE_LOG"; fi
  run_step '诊断证书申请' caddy_tls_diagnose '' || diagnosis=$?
  [[ $diagnosis != 2 ]] || die '证书申请触发 CA 速率限制，请按日志中的重试时间等待；保留现有证书，用菜单 5 继续。'
  die '源站 HTTPS 尚未就绪。请从菜单 4 查看任务日志及证书申请诊断，再用菜单 5 继续。'
}
# Diagnose explicit CA/DNS errors; generic HTTP 429 is not an ACME limit.
caddy_tls_diagnose_text() {
  python3 -c '
import json, re, sys
lines = sys.stdin.read().splitlines()
def readable(line):
    try:
        obj = json.loads(line[line.index("{"):])
        def strings(value):
            if isinstance(value, dict):
                return [part for key, item in value.items() for part in ([key] + strings(item))]
            if isinstance(value, list):
                return [part for item in value for part in strings(item)]
            return [str(value)]
        return " | ".join(strings(obj))
    except (ValueError, TypeError):
        return line
rows = [readable(line) for line in lines]
for row in reversed(rows):
    if re.search(r"urn:ietf:params:acme:error:rateLimited|too many certificates|too many failed authorizations", row, re.I):
        print("检测到 ACME 证书签发速率限制。")
        if re.search(r"too many failed authorizations|authorization failures", row, re.I):
            print("类型：域名验证失败次数过多。先检查 DNS 和权限，再按 CA 指定时间重试。")
        elif re.search(r"exact (?:same )?set|duplicate", row, re.I):
            print("类型：相同域名集合重复签发过多。")
        else:
            print("类型：CA 签发配额限制，具体范围以原始原因说明为准。")
        print("原始原因：" + row[:3000])
        retry = re.search(r"retry[-_ ]after(?:[\s:=|]+)([^|;]+)", row, re.I)
        if retry:
            print("CA 返回的重试信息：" + retry[0][:300])
        else:
            print("日志未包含明确重试时间，请按 CA 错误详情等待后再试。")
        print("保留现有证书目录，不要反复删除证书或重建以强制申请。")
        print("限制说明：https://letsencrypt.org/docs/rate-limits/")
        sys.exit(2)
for row in reversed(rows):
    error = re.search(r"error|failed|unauthorized|invalid", row, re.I)
    dns = re.search(r"dns[-_ ]?01|dns challenge|cloudflare|authoritative nameservers", row, re.I)
    if error and dns:
        print("检测到 DNS-01 验证失败，请检查 Token 权限、区域和 DNS 传播。")
        print("原始原因：" + row[:3000])
        sys.exit(1)
print("未在最近的 Caddy 日志中检测到明确的 ACME 证书速率限制。")
'
}
caddy_tls_diagnose() (
  local text=${1-} temporary result=0 logfile
  temporary=$(mktemp) || return 1
  trap 'rm -f -- "$temporary"' EXIT
  if [[ -z $text ]]; then
    if ! caddy_redacted_command dc logs --no-color --since 15m --tail 100 caddy > "$temporary"; then
      info '无法读取 Caddy 日志，请检查 Docker 和 Caddy 状态。'
      return 1
    fi
    text=$(cat "$temporary")
  fi
  printf '%s\n' "$text" | trace_redact > "$temporary"
  if [[ -d $ROOT ]]; then
    mkdir -p "$ROOT/state/logs" || return 1
    logfile=$(mktemp "$ROOT/state/logs/tls-$(date +%Y%m%d-%H%M%S)-XXXXXX.log") || return 1
    cp "$temporary" "$logfile" || return 1
    trace_event TLS_DIAGNOSIS "log=$logfile"
  fi
  caddy_tls_diagnose_text < "$temporary" || result=$?
  return "$result"
)
load_state() {
  [[ -f $ROOT/state/state.json ]] || die '未发现本安装器的安装记录。'
  DOMAIN=$(jq -er .domain "$ROOT/state/state.json")
  CHANNEL=${CHANNEL:-$(jq -er .channel "$ROOT/state/state.json")}
  VERSION=$(jq -er .version "$ROOT/state/state.json")
  APP_IMAGE=$(jq -er .app "$ROOT/state/state.json")
  CADDY_IMAGE=$(jq -er .caddy "$ROOT/state/state.json")
  PG_IMAGE=$(jq -er .pg "$ROOT/state/state.json")
}
checkpoint() {
  STAGE=$1
  jq -n --argjson stage "$STAGE" --arg domain "$DOMAIN" --arg channel "$CHANNEL" --arg version "$VERSION" --arg app "$APP_IMAGE" --arg caddy "$CADDY_IMAGE" --arg pg "$PG_IMAGE" '{stage:$stage,domain:$domain,channel:$channel,version:$version,app:$app,caddy:$caddy,pg:$pg}' > "$ROOT/state/progress.json.tmp"
  mv "$ROOT/state/progress.json.tmp" "$ROOT/state/progress.json"
}
load_progress() {
  jq -e '.stage|type=="number" and .>=0 and .<=7' "$ROOT/state/progress.json" >/dev/null || die '安装进度异常。'
  STAGE=$(jq -r .stage "$ROOT/state/progress.json")
  DOMAIN=$(jq -r '.domain // ""' "$ROOT/state/progress.json")
  CHANNEL=$(jq -r '.channel // ""' "$ROOT/state/progress.json")
  VERSION=$(jq -r '.version // ""' "$ROOT/state/progress.json")
  APP_IMAGE=$(jq -r '.app // ""' "$ROOT/state/progress.json")
  CADDY_IMAGE=$(jq -r '.caddy // ""' "$ROOT/state/progress.json")
  PG_IMAGE=$(jq -r '.pg // "postgres:18-alpine"' "$ROOT/state/progress.json")
}
prepare_secrets() {
  local password
  if [[ -f $ROOT/config/postgres.env ]]; then
    password=$(sed -n 's/^POSTGRES_PASSWORD=//p' "$ROOT/config/postgres.env")
    [[ $password =~ ^[a-f0-9]{64}$ ]] || die '数据库密码文件格式异常，未覆盖。'
  else
    [[ ! -d $ROOT/data/postgres ]] || die '存在数据库数据但密码文件丢失，停止操作。'
    password=$(openssl rand -hex 32)
    printf 'POSTGRES_PASSWORD=%s\n' "$password" > "$ROOT/config/postgres.env.tmp"
    mv "$ROOT/config/postgres.env.tmp" "$ROOT/config/postgres.env"
  fi
  printf 'MMWX_DATABASE_PASSWORD=%s\n' "$password" > "$ROOT/config/app.env.tmp"
  mv "$ROOT/config/app.env.tmp" "$ROOT/config/app.env"
  if [[ ! -f $ROOT/config/caddy.env ]]; then
    [[ -f $ROOT/config/cloudflare.token ]] || die '缺少 Token，请重新提供。'
    printf 'CF_API_TOKEN=%s\n' "$(cat "$ROOT/config/cloudflare.token")" > "$ROOT/config/caddy.env.tmp"
    mv "$ROOT/config/caddy.env.tmp" "$ROOT/config/caddy.env"
  fi
}
install_stack() {
  caddy_token_pending_guard
  ensure_layout
  [[ ! -f $ROOT/state/reinstall.json ]] || die '请先通过菜单 5 继续镜像重装。'
  preflight
  [[ ! -f $ROOT/state/update.json ]] || die '有未完成的更新，请选择「继续任务 / 恢复服务」。'
  if [[ -f $ROOT/state/progress.json ]]; then
    load_progress
    [[ $STAGE -lt 7 ]] || die '已安装，请在菜单选择更新或恢复服务。'
    info "继续安装（阶段 $STAGE/7）"
  elif [[ -f $ROOT/state/state.json ]]; then
    die '已有安装，请选择恢复服务。'
  fi
  install -d -m 0700 "$ROOT"
  install_command
  if ((STAGE<1)); then
    dependencies
    checkpoint 1
  fi
  configure_timezone
  if ((STAGE<2)); then
    if [[ -z $TOKEN_FILE && -f $ROOT/config/cloudflare.token ]]; then TOKEN_FILE=$ROOT/config/cloudflare.token; fi
    if [[ -z $TOKEN_FILE ]]; then
      token_guide
      TOKEN_FILE=$(mktemp); TEMP_TOKEN=$TOKEN_FILE
      local token
      read -r -s -p 'Cloudflare Token：' token </dev/tty; printf '\n'
      printf '%s' "$token" > "$TOKEN_FILE"
    fi
    dns_check
    printf '%s' "$CF_TOKEN" > "$ROOT/config/cloudflare.token.tmp"
    mv "$ROOT/config/cloudflare.token.tmp" "$ROOT/config/cloudflare.token"
    unset CF_TOKEN
    checkpoint 2
  fi
  install_docker
  if ((STAGE<3)); then choose_version || return 0; checkpoint 3; fi
  if ((STAGE<4)); then
    build_caddy
    run_step '下载 PostgreSQL 镜像' docker pull "$PG_IMAGE"
    PG_IMAGE=$(docker image inspect "$PG_IMAGE" --format '{{index .RepoDigests 0}}')
    checkpoint 4
  fi
  if ((STAGE<5)); then
    prepare_secrets
    render_compose > "$ROOT/config/compose.yaml.tmp"
    mv "$ROOT/config/compose.yaml.tmp" "$ROOT/config/compose.yaml"
    render_caddy > "$ROOT/config/Caddyfile"
    dc config --quiet
    checkpoint 5
  fi
  render_compose > "$ROOT/config/compose.yaml.tmp"
  mv "$ROOT/config/compose.yaml.tmp" "$ROOT/config/compose.yaml"
  network_setup
  render_caddy > "$ROOT/config/Caddyfile"
  save_state
  checkpoint 6
  run_step '启动服务' dc up -d --wait --wait-timeout 300
  verify_https
  checkpoint 7
  printf '\n安装完成：https://%s\n管理菜单：mmwx\n数据库由环境变量管理，无需勾选「使用 PG 数据库」。\n' "$DOMAIN"
}
write_update_progress() {
  jq -n --arg phase "$1" --arg backup "$2" --arg scope "${3:-mmwx}" '{phase:$phase,backup:$backup,service_scope:$scope}' > "$ROOT/state/update.json.tmp"
  mv "$ROOT/state/update.json.tmp" "$ROOT/state/update.json"
}
backup_database() { dc exec -T postgres pg_dump -U mmwx -d mmwx -Fc > "$1"; }
restore_database() {
  dc exec -T postgres dropdb -U mmwx --if-exists --force mmwx
  dc exec -T postgres createdb -U mmwx -O mmwx mmwx
  dc exec -T postgres pg_restore -U mmwx -d mmwx --exit-on-error < "$1"
}
recover_update() {
  local backup phase directory scope
  backup=$(jq -er .backup "$ROOT/state/update.json")
  phase=$(jq -er .phase "$ROOT/state/update.json")
  scope=$(jq -r '.service_scope // "legacy"' "$ROOT/state/update.json")
  [[ $scope == mmwx || $scope == legacy ]] || die '未知更新服务范围。'
  [[ $backup == "$ROOT/backups/"* && ${backup#"$ROOT/backups/"} != */* && -d $backup ]] || die '更新备份路径异常。'
  [[ -f $backup/compose.yaml && -f $backup/state.json ]] || die '更新恢复文件缺失。'
  case "$phase" in
    backing-up)
      # Existing data is authoritative; legacy migration may have removed PG.
      if [[ $scope == legacy ]]; then run_step '确认数据库可用' dc up -d --no-deps --no-recreate --wait --wait-timeout 120 postgres; fi;;
    deploying|restoring)
      [[ -s $backup/database.dump && -s $backup/files.tar.gz ]] || die '更新备份不完整，停止恢复。'
      write_update_progress restoring "$backup" "$scope"
      run_step '停止主控' dc stop mmwx
      run_step '确认数据库可用' dc up -d --no-deps --no-recreate --wait --wait-timeout 120 postgres
      run_step '恢复数据库备份' restore_database "$backup/database.dump"
      mkdir -p "$backup/restored"
      run_step '解压应用文件备份' tar -xzf "$backup/files.tar.gz" -C "$backup/restored"
      if [[ -d $backup/restored/data && ! -e $backup/restored/app ]]; then mv "$backup/restored/data" "$backup/restored/app"; fi
      for directory in app subscribes rule_templates; do
        if [[ -d $ROOT/data/$directory && ! -e $backup/failed-$directory ]]; then
          mv "$ROOT/data/$directory" "$backup/failed-$directory"
        fi
        # Fixed project-owned directories only; retry starts from the same snapshot.
        rm -rf "${ROOT:?}/data/$directory"
        cp -a "$backup/restored/$directory" "$ROOT/data/$directory"
      done
      ;;
    *) die '未知更新阶段。';;
  esac
  cp "$backup/state.json" "$ROOT/state/state.json"
  CHANNEL=''
  load_state
  render_compose > "$ROOT/config/compose.yaml.tmp"
  mv "$ROOT/config/compose.yaml.tmp" "$ROOT/config/compose.yaml"
  run_step '启动主控' dc up -d --no-deps --wait --wait-timeout 300 mmwx
  # Older updates stopped Caddy too; a legacy layout migration may have removed
  # it. Restore it if needed, without recreating an existing gateway.
  if [[ $scope == legacy ]]; then run_step '恢复旧任务停止的网关' dc up -d --no-deps --no-recreate --wait --wait-timeout 300 caddy; fi
  rm -f "$ROOT/state/update.json"
  info "已恢复更新前的版本。备份：$backup"
}
update_stack() {
  caddy_token_pending_guard
  [[ ! -f $ROOT/state.json && ! -f $ROOT/progress.json && ! -d $ROOT/.layout-migration ]] || die '旧版目录需先通过菜单 5 完成迁移，再更新主控。'
  ensure_layout
  [[ ! -f $ROOT/state/reinstall.json ]] || die '请先通过菜单 5 继续镜像重装。'
  preflight
  install_command
  if [[ -f $ROOT/state/update.json ]]; then recover_update; return; fi
  [[ ! -f $ROOT/state/image-rollback.json ]] || die '请先继续未完成的版本回退。'
  [[ ! -f $ROOT/state/progress.json ]] || [[ $(jq -r .stage "$ROOT/state/progress.json") == 7 ]] || die '请先继续完成安装。'
  load_state
  configure_timezone
  local backup current_version=$VERSION current_image=$APP_IMAGE
  choose_version || return 0
  if [[ $VERSION == "$current_version" && $APP_IMAGE == "$current_image" ]]; then
    info "当前已运行 $VERSION，无需更新。"
    return 0
  fi
  mkdir -p "$ROOT/backups"
  backup=$(mktemp -d "$ROOT/backups/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
  cp "$ROOT/config/compose.yaml" "$ROOT/state/state.json" "$backup/"
  write_update_progress backing-up "$backup"
  run_step '停止主控' dc stop mmwx
  if ! run_step '备份数据库' backup_database "$backup/database.dump"; then
    run_step '重新启动旧版本' dc start mmwx; rm -f "$ROOT/state/update.json"; die '数据库备份失败，已重新启动旧版本。'
  fi
  if ! run_step '备份应用文件' tar -czf "$backup/files.tar.gz" -C "$ROOT/data" app subscribes rule_templates; then
    run_step '重新启动旧版本' dc start mmwx; rm -f "$ROOT/state/update.json"; die '文件备份失败，已重新启动旧版本。'
  fi
  write_update_progress deploying "$backup"
  render_compose > "$ROOT/config/compose.yaml.tmp"
  mv "$ROOT/config/compose.yaml.tmp" "$ROOT/config/compose.yaml"
  if run_step '启动主控' dc up -d --no-deps --wait --wait-timeout 300 mmwx; then
    save_state
    rm -f "$ROOT/state/update.json"
    info "更新完成：$VERSION。备份：$backup"
  else
    recover_update
    die '新版本健康检查失败，已恢复旧版本和数据库。'
  fi
}
reinstall_stack() {
  caddy_token_pending_guard
  [[ ! -f $ROOT/state.json && ! -f $ROOT/progress.json && ! -d $ROOT/.layout-migration ]] || die '旧版目录需先通过菜单 5 完成迁移，再重装主控。'
  ensure_layout
  preflight
  [[ ! -f $ROOT/state/update.json && ! -f $ROOT/state/image-rollback.json ]] || die '请先通过菜单 5 完成更新或版本回退。'
  [[ ! -f $ROOT/state/progress.json ]] || [[ $(jq -r .stage "$ROOT/state/progress.json") == 7 ]] || die '请先完成安装，再重装镜像。'
  CHANNEL=''
  load_state
  if [[ ! -f $ROOT/state/reinstall.json ]]; then
    confirm "重新拉取并重建妙妙屋 $VERSION？全部数据保留，主控会短暂中断，数据库和网关保持运行。" || return 0
    cp "$ROOT/state/state.json" "$ROOT/state/reinstall.json.tmp"
    mv "$ROOT/state/reinstall.json.tmp" "$ROOT/state/reinstall.json"
  fi
  finish_reinstall
}
finish_reinstall() {
  local name
  [[ ! -f $ROOT/state/update.json && ! -f $ROOT/state/image-rollback.json ]] || die '存在冲突任务，请先检查任务状态。'
  cmp -s "$ROOT/state/state.json" "$ROOT/state/reinstall.json" || die '安装记录已变化，停止镜像重装。'
  CHANNEL=''
  load_state
  for name in compose.yaml Caddyfile postgres.env app.env caddy.env cloudflare.token; do
    [[ -f $ROOT/config/$name ]] || die "缺少配置 $name，停止重装以保留现有数据。"
  done
  network_is_ready || die '请检查 UFW/IPv6 配置后继续重装。'
  dc config --format json | jq -e --arg app "$APP_IMAGE" --arg caddy "$CADDY_IMAGE" --arg pg "$PG_IMAGE" \
    '.services.mmwx.image==$app and .services.caddy.image==$caddy and .services.postgres.image==$pg' >/dev/null || die '容器配置与安装记录不一致，停止重装。'
  run_step "重新拉取主控 $VERSION" docker pull "$APP_IMAGE" || die '主控镜像下载失败，可通过菜单 5 继续。'
  run_step '重新创建妙妙屋容器' dc up -d --no-deps --force-recreate --wait --wait-timeout 300 mmwx || die '主控重建未完成，可通过菜单 5 继续。'
  verify_https || die 'HTTPS 验证未通过，可通过菜单 5 继续。'
  rm -f "$ROOT/state/reinstall.json"
  info "妙妙屋重装完成：$VERSION。数据、配置、证书和凭据均保留。"
}
check_script_update() {
  [[ $SCRIPT_UPDATE_CHECKED == 0 ]] || return 0
  SCRIPT_UPDATE_CHECKED=1
  SCRIPT_UPDATE_VERSION=''
  local url version newest
  # Menu startup is best effort: no API quota, retries, cache files or script downloads.
  url=$(curl -q --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL \
    --connect-timeout 2 --max-time 3 --retry 0 --max-redirs 3 \
    -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
    -o /dev/null -w '%{url_effective}' \
    "https://github.com/xiangwan6667/mmwx-installer/releases/latest?mmwx_check=$(date +%s%N)-$$-$RANDOM" 2>/dev/null) || return 0
  [[ $url =~ ^https://github.com/xiangwan6667/mmwx-installer/releases/tag/v((0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*))$ ]] || return 0
  version=${BASH_REMATCH[1]}
  [[ $SCRIPT_VERSION =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || return 0
  [[ $version != "$SCRIPT_VERSION" ]] || return 0
  newest=$(printf '%s\n%s\n' "$SCRIPT_VERSION" "$version" | LC_ALL=C sort -V | tail -n 1) || return 0
  if [[ $newest == "$version" ]]; then SCRIPT_UPDATE_VERSION=v$version; fi
  return 0
}
download_installer_release() {
  local directory=$1 base=https://github.com/xiangwan6667/mmwx-installer url tag expected actual
  # Resolve latest once, then pin BOTH assets to that stable release. This uses
  # the website redirect and does not consume the anonymous GitHub API quota.
  # A fresh query key avoids an old latest redirect cached after a new release.
  url=$(get "$base/releases/latest?mmwx_check=$(date +%s%N)-$$-$RANDOM" \
    -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
    -o /dev/null -w '%{url_effective}') || { printf '无法查询正式 Release。\n' >&2; return 1; }
  [[ $url =~ ^https://github.com/xiangwan6667/mmwx-installer/releases/tag/(v[0-9]+\.[0-9]+\.[0-9]+)$ ]] || { printf '正式 Release 地址无效。\n' >&2; return 1; }
  tag=${BASH_REMATCH[1]}
  if ! get "$base/releases/download/$tag/install.sh" -o "$directory/install.sh" ||
     ! get "$base/releases/download/$tag/SHA256SUMS" -o "$directory/SHA256SUMS"; then
    printf 'Release %s 下载失败，请稍后重试。\n' "$tag" >&2; return 1
  fi
  expected=$(awk '
    $2 == "install.sh" || $2 == "*install.sh" { if (NF != 2) exit 1; count++; hash=$1 }
    END { if (count != 1 || length(hash) != 64 || hash ~ /[^0-9a-fA-F]/) exit 1; print tolower(hash) }
  ' "$directory/SHA256SUMS") || { printf 'Release 校验文件无效。\n' >&2; return 1; }
  actual=$(sha256sum "$directory/install.sh") || return 1
  [[ ${actual%% *} == "$expected" ]] || { printf 'Release SHA-256 校验失败。\n' >&2; return 1; }
  if ! head -1 "$directory/install.sh" | grep -qx '#!/usr/bin/env bash' ||
     ! bash -n "$directory/install.sh" ||
     ! grep -qx '# Independent installer. Never invoke the upstream install script.' "$directory/install.sh" ||
     ! grep -Eq '^self_update\(\) [({]$' "$directory/install.sh" ||
     [[ $(grep -c '^SCRIPT_VERSION=' "$directory/install.sh") != 1 ]] ||
     ! grep -qxF "SCRIPT_VERSION=${tag#v}" "$directory/install.sh"; then
    printf 'Release 脚本格式或版本不匹配。\n' >&2; return 1
  fi
  printf '%s\n' "$tag"
}
# Keep the brace signature accepted by older managers during this upgrade.
self_update() {
  (
    local temporary downloaded staged='' tag
    temporary=$(mktemp -d) || die '无法创建更新临时目录。'
    trap 'rm -rf -- "$temporary"; [[ -z $staged ]] || rm -f -- "$staged"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    tag=$(download_installer_release "$temporary") || die '更新失败，保留当前管理脚本。'
    downloaded=$temporary/install.sh
    if [[ -e /usr/local/bin/mmwx || -L /usr/local/bin/mmwx ]]; then
      [[ $(readlink -f /usr/local/bin/mmwx) == /usr/local/sbin/mmwx-installer ]] || die '已有其他 mmwx 命令。'
    fi
    if cmp -s "$downloaded" /usr/local/sbin/mmwx-installer; then
      [[ -L /usr/local/bin/mmwx ]] || ln -s /usr/local/sbin/mmwx-installer /usr/local/bin/mmwx || return 1
      cleanup_downloads
      info '已经是最新版。'
      return 0
    fi
    staged=$(mktemp /usr/local/sbin/.mmwx-installer.XXXXXX) || die '无法暂存更新，保留当前版本。'
    install -m 0700 "$downloaded" "$staged" || die '无法暂存更新，保留当前版本。'
    mv -f "$staged" /usr/local/sbin/mmwx-installer || die '无法替换管理脚本，保留当前版本。'
    [[ -L /usr/local/bin/mmwx ]] || ln -s /usr/local/sbin/mmwx-installer /usr/local/bin/mmwx || return 1
    cleanup_downloads
    info "管理脚本已更新：$tag。"
  )
}
finish_image_rollback() {
  load_state
  VERSION=$(jq -er .version "$ROOT/state/image-rollback.json")
  APP_IMAGE=$(jq -er .app "$ROOT/state/image-rollback.json")
  CHANNEL=$(jq -er .channel "$ROOT/state/image-rollback.json")
  run_step "检查目标主控 $VERSION" docker pull "$APP_IMAGE"
  render_compose > "$ROOT/config/compose.yaml.tmp"
  mv "$ROOT/config/compose.yaml.tmp" "$ROOT/config/compose.yaml"
  # Only recreate the controller. PostgreSQL, Caddy and all persisted data stay in place.
  if ! run_step '切换主控容器' dc up -d --no-deps --wait --wait-timeout 300 mmwx; then
    # state.json still points to the pre-rollback controller; leave data untouched.
    CHANNEL=''
    load_state
    render_compose > "$ROOT/config/compose.yaml.tmp"
    mv "$ROOT/config/compose.yaml.tmp" "$ROOT/config/compose.yaml"
    run_step '切换主控容器' dc up -d --no-deps --wait --wait-timeout 300 mmwx || die '原主控也未能启动，请检查日志后重试恢复。'
    rm -f "$ROOT/state/image-rollback.json"
    die '回退版本未通过健康检查，已切回原主控，未还原数据。'
  fi
  save_state
  rm -f "$ROOT/state/image-rollback.json"
  info "主控已切换至 $VERSION，数据库和文件未还原。"
}
rollback_stack() {
  caddy_token_pending_guard
  [[ ! -f $ROOT/state.json && ! -f $ROOT/progress.json && ! -d $ROOT/.layout-migration ]] || die '旧版目录需先通过菜单 5 完成迁移，再回退主控。'
  ensure_layout
  [[ ! -f $ROOT/state/reinstall.json ]] || die '请先通过菜单 5 继续镜像重装。'
  preflight; load_state
  [[ ! -f $ROOT/state/update.json ]] || die '请先恢复未完成的更新。'
  if [[ -f $ROOT/state/image-rollback.json ]]; then finish_image_rollback; return; fi
  local pages current=$VERSION
  pages=$(fetch_releases 5) || die '无法读取官方版本，请检查 GitHub 网络后重试。'
  select_version_menu "$pages"
  select_available_image "$pages" specified || return 0
  [[ $VERSION != "$current" ]] || { info '选择的是当前版本，无需切换。'; return; }
  confirm "主控 $current → $VERSION，保留当前数据。继续？" || return 0
  pull_app_version
  jq -n --arg version "$VERSION" --arg app "$APP_IMAGE" --arg channel "$CHANNEL" '{version:$version,app:$app,channel:$channel}' > "$ROOT/state/image-rollback.json.tmp"
  mv "$ROOT/state/image-rollback.json.tmp" "$ROOT/state/image-rollback.json"
  finish_image_rollback
}
docker_purge_paths_check() {
  local path mounted mountpoint
  for path in /var/lib/docker /var/lib/containerd /etc/docker; do
    [[ ! -L $path && $(readlink -m "$path") == "$path" ]] || die "Docker 目录异常：$path，停止卸载。"
    mounted=$(findmnt -rn -o TARGET) || return 1
    while IFS= read -r mountpoint; do
      [[ $mountpoint != "$path" && $mountpoint != "$path/"* ]] || die "Docker 目录存在挂载：$mountpoint，请先处理后重试。"
    done <<< "$mounted"
  done
}
docker_purge_firewall() {
  # Docker may leave its chains after dockerd stops. Remove only Docker chains,
  # jumps to those chains and rules naming a recorded bridge; never flush tables.
  python3 - "$ROOT/state/docker-purge.json" <<'PY'
import json, shlex, shutil, subprocess, sys
bridges = set(json.load(open(sys.argv[1], encoding='utf-8'))['bridges'])
for binary in ('iptables', 'ip6tables'):
    if not shutil.which(binary + '-save'):
        continue
    saved = subprocess.check_output([binary + '-save'], text=True)
    table = None
    chains = set()
    rules = []
    def clean():
        if not table:
            return
        for rule in rules:
            targets = [rule[i + 1] for i, value in enumerate(rule[:-1]) if value in ('-j', '-g')]
            interfaces = [rule[i + 1] for i, value in enumerate(rule[:-1]) if value in ('-i', '-o')]
            if rule[1] not in chains and (chains.intersection(targets) or bridges.intersection(interfaces)):
                subprocess.run([binary, '-w', '10', '-t', table, '-D', *rule[1:]], check=True)
        for chain in sorted(chains):
            subprocess.run([binary, '-w', '10', '-t', table, '-F', chain], check=True)
        for chain in sorted(chains):
            subprocess.run([binary, '-w', '10', '-t', table, '-X', chain], check=True)
    for line in saved.splitlines():
        if line.startswith('*'):
            table, chains, rules = line[1:], set(), []
        elif line.startswith(':DOCKER'):
            name = line[1:].split()[0]
            if name == 'DOCKER' or name.startswith('DOCKER-'):
                chains.add(name)
        elif line.startswith('-A '):
            rules.append(shlex.split(line))
        elif line == 'COMMIT':
            clean()
PY
}
docker_purge_preflight() {
  local journal=$ROOT/state/docker-purge.json details id label network name bridge phase users owner
  local -a bridges=() volumes=()
  [[ ! -L $ROOT && ! -L $ROOT/state && ! -L $journal ]] || die 'Docker 卸载记录路径异常。'
  if [[ -f $journal ]]; then
    jq -e '(.phase == "prepared" or .phase == "stopping" or .phase == "removed") and (.bridges | type == "array") and all(.bridges[]; type == "string" and test("^[a-zA-Z0-9_.-]{1,15}$") and . != "lo")' "$journal" >/dev/null || die 'Docker 卸载记录无效。'
    phase=$(jq -r .phase "$journal")
    mapfile -t bridges < <(jq -r '.bridges[]' "$journal")
    if [[ $phase == stopping || $phase == removed ]]; then
      if systemctl is-active --quiet docker.service || systemctl is-active --quiet containerd.service; then
        # Recheck workloads if services were started again after interruption.
        :
      else
        docker_purge_paths_check; return
      fi
    fi
  fi
  [[ -z ${DOCKER_HOST:-} && -z ${DOCKER_CONTEXT:-} ]] || die '请取消 DOCKER_HOST/DOCKER_CONTEXT 后卸载本机 Docker。'
  if [[ -f /etc/containerd/config.toml ]]; then
    # Only the top-level storage paths matter; plugin-specific roots are scoped.
    python3 - /etc/containerd/config.toml <<'PY' || return 1
import re, sys
for line in open(sys.argv[1], encoding='utf-8'):
    if line.lstrip().startswith('['):
        break
    match = re.match(r'''\s*(root|state)\s*=\s*['"]([^'"]+)['"]''', line)
    if match and match[2] != {'root': '/var/lib/containerd', 'state': '/run/containerd'}[match[1]]:
        sys.exit('containerd 使用自定义目录，停止完全卸载。')
PY
  fi
  if command -v docker >/dev/null; then
    [[ $(docker context inspect --format '{{.Endpoints.docker.Host}}') == unix:///var/run/docker.sock ]] || die '仅支持卸载本机默认 Docker。'
    details=$(docker info --format '{{json .}}') || die 'Docker 无法连接，未开始卸载，请恢复 Docker 后重试。'
    jq -e '.DockerRootDir == "/var/lib/docker" and .Swarm.LocalNodeState == "inactive" and ([.SecurityOptions[]? | select(contains("rootless"))] | length == 0)' <<< "$details" >/dev/null || die 'Docker 使用自定义目录、Swarm 或 rootless 模式，停止完全卸载。'
    details=$(docker ps -aq) || return 1
    while IFS= read -r id; do
      [[ -n $id ]] || continue
      label=$(docker inspect "$id" --format '{{index .Config.Labels "com.docker.compose.project"}}') || return 1
      [[ $label == mmwx-installer ]] || die "发现其他项目容器 $id，停止完全卸载；可选择保留数据模式。"
    done <<< "$details"
    details=$(docker volume ls -q) || return 1
    while IFS= read -r id; do
      [[ -n $id ]] || continue
      label=$(docker volume inspect "$id" --format '{{index .Labels "com.docker.compose.project"}}') || return 1
      if [[ $label != mmwx-installer ]]; then
        # Anonymous image volumes have no Compose label. Require every attached
        # container to belong to this project; detached unknown volumes stay safe.
        [[ -z $label || $label == '<no value>' ]] || die "发现其他项目存储卷 $id，停止完全卸载。"
        users=$(docker ps -aq --filter "volume=$id") || return 1
        if [[ -z $users ]]; then
          if [[ ! -f $journal ]] || ! jq -e --arg id "$id" '(.volumes // []) | index($id) != null' "$journal" >/dev/null; then
            die "发现其他项目存储卷 $id，停止完全卸载。"
          fi
        fi
        while IFS= read -r owner; do
          [[ -n $owner ]] || continue
          label=$(docker inspect "$owner" --format '{{index .Config.Labels "com.docker.compose.project"}}') || return 1
          [[ $label == mmwx-installer ]] || die "存储卷 $id 被其他项目使用，停止完全卸载。"
        done <<< "$users"
      fi
      volumes+=("$id")
    done <<< "$details"
    details=$(docker network ls -q) || return 1
    while IFS= read -r id; do
      [[ -n $id ]] || continue
      network=$(docker network inspect "$id") || return 1
      name=$(jq -er '.[0].Name' <<< "$network") || return 1
      case "$name" in bridge|host|none) :;;
        *) jq -e '.[0].Labels["com.docker.compose.project"] == "mmwx-installer"' <<< "$network" >/dev/null || die "发现其他项目网络 $name，停止完全卸载。";;
      esac
      if [[ $(jq -r '.[0].Driver' <<< "$network") == bridge ]]; then
        bridge=$(jq -r '.[0] | .Options["com.docker.network.bridge.name"] // ("br-" + .Id[:12])' <<< "$network") || return 1
        [[ $bridge =~ ^[a-zA-Z0-9_.-]{1,15}$ && $bridge != lo ]] || die 'Docker 网桥名称异常。'
        bridges+=("$bridge")
      fi
    done <<< "$details"
  elif [[ -d /var/lib/docker ]]; then
    die 'Docker 命令缺失但数据目录仍存在，无法核对用途，停止卸载。'
  fi
  if systemctl is-active --quiet containerd.service; then
    command -v ctr >/dev/null || die '无法核对 containerd 任务，停止卸载。'
    details=$(ctr --address /run/containerd/containerd.sock namespaces list -q) || return 1
    while IFS= read -r name; do
      [[ -n $name && $name != moby ]] || continue
      id=$(ctr --address /run/containerd/containerd.sock --namespace "$name" containers list -q) || return 1
      [[ -z $id ]] || die "containerd 中存在其他项目：$name，停止卸载。"
    done <<< "$details"
  elif [[ -d /var/lib/containerd && -n $(find /var/lib/containerd -mindepth 1 -print -quit) ]]; then
    die 'containerd 已停止但仍有数据，无法核对其他任务，请恢复 containerd 后重试。'
  fi
  # Validate fixed deletion paths before persisting authorization for retry.
  # Running containers mount overlay paths; those are checked after teardown.
  for name in /var/lib/docker /var/lib/containerd /etc/docker; do
    [[ ! -L $name && $(readlink -m "$name") == "$name" ]] || die "Docker 目录异常：$name。"
  done
  mkdir -p "$ROOT/state" || return 1
  details=$(printf '%s\n' "${volumes[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))') || return 1
  jq -n --argjson volumes "$details" --args '{phase:"prepared",bridges:($ARGS.positional | unique),volumes:$volumes}' "${bridges[@]}" > "$journal.tmp" || return 1
  mv "$journal.tmp" "$journal" || return 1
}
docker_purge_phase() {
  jq --arg phase "$1" '.phase=$phase' "$ROOT/state/docker-purge.json" > "$ROOT/state/docker-purge.json.tmp" &&
    mv "$ROOT/state/docker-purge.json.tmp" "$ROOT/state/docker-purge.json"
}
purge_docker() {
  local phase ids unit package bridge journal=$ROOT/state/docker-purge.json
  local -a packages=()
  phase=$(jq -er .phase "$journal") || return 1
  if [[ $phase == prepared ]] && command -v docker >/dev/null; then
    # Labels cover orphaned containers and networks even if Compose was removed.
    ids=$(docker ps -aq --filter label=com.docker.compose.project=mmwx-installer) || return 1
    while IFS= read -r id; do [[ -z $id ]] || docker rm -f -v "$id" || return 1; done <<< "$ids"
    ids=$(docker network ls -q --filter label=com.docker.compose.project=mmwx-installer) || return 1
    while IFS= read -r id; do [[ -z $id ]] || docker network rm "$id" || return 1; done <<< "$ids"
    [[ -z $(docker ps -aq) ]] || die '出现新的容器，停止 Docker 卸载。'
  fi
  docker_purge_phase stopping || return 1
  for unit in docker.socket docker.service containerd.service; do
    if [[ $(systemctl show --property=LoadState --value "$unit") != not-found ]]; then
      systemctl disable --now "$unit" || return 1
      if systemctl is-active --quiet "$unit"; then return 1; fi
    fi
  done
  docker_purge_paths_check || return 1
  for package in docker-ce docker-ce-cli docker-ce-rootless-extras docker-buildx-plugin docker-compose-plugin containerd.io docker.io docker-compose-v2 docker-compose docker-buildx containerd runc moby-engine moby-cli moby-buildx moby-compose moby-containerd moby-runc; do
    if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -Eq 'installed$|config-files$'; then packages+=("$package"); fi
  done
  if ((${#packages[@]})); then
    local simulation removed candidate known
    simulation=$(apt-get -s purge "${packages[@]}") || return 1
    while IFS= read -r removed; do
      [[ -n $removed ]] || continue
      known=0
      for candidate in "${packages[@]}"; do [[ $removed != "$candidate" ]] || known=1; done
      [[ $known == 1 ]] || die "卸载 Docker 将连带移除 $removed，已停止，请先处理依赖。"
    done < <(awk '$1 == "Remv" || $1 == "Purg" {print $2}' <<< "$simulation")
    env DEBIAN_FRONTEND=noninteractive apt-get purge -y "${packages[@]}" || return 1
  fi
  hash -r
  if command -v docker >/dev/null; then die '仍存在非软件包安装的 Docker 命令，请移除后重试完全卸载。'; fi
  docker_purge_firewall || return 1
  # Only recorded Docker bridges are removed; arbitrary veth/host NICs are kept.
  while IFS= read -r bridge; do
    [[ $bridge =~ ^[a-zA-Z0-9_.-]{1,15}$ && $bridge != lo ]] || return 1
    if ip link show dev "$bridge" >/dev/null 2>&1; then
      ip link delete dev "$bridge" type bridge || return 1
    fi
  done < <(jq -r '.bridges[]' "$journal")
  rm -rf --one-file-system -- /var/lib/docker /var/lib/containerd /etc/docker || return 1
  rm -f /etc/apt/sources.list.d/mmwx-docker.list /etc/apt/keyrings/docker.asc || return 1
  systemctl daemon-reload || return 1
  docker_purge_phase removed
}
remove_services() {
  local unit
  systemctl stop mmwx-cf-sync.timer mmwx-cf-sync.service 2>/dev/null || true
  exec 8>/run/mmwx-cf.lock; flock -w 180 8 || die '防火墙正在更新，请稍后重试卸载。'
  systemctl stop mmwx-network-rollback.timer mmwx-network-rollback.service 2>/dev/null || true
  for unit in mmwx-network-rollback.timer mmwx-network-rollback.service; do
    if systemctl is-active --quiet "$unit"; then die '网络回退任务仍在运行，停止卸载。'; fi
  done
  for unit in mmwx-cf-sync.timer mmwx-cf-sync.service mmwx-firewall.service; do
    if [[ $(systemctl show --property=LoadState --value "$unit") != not-found ]]; then
      run_step "移除后台服务 $unit" systemctl disable --now "$unit" || return 1
    fi
  done
  # Transient rollback units have no [Install] section; stop and reset them.
  systemctl reset-failed mmwx-network-rollback.timer mmwx-network-rollback.service 2>/dev/null || true
  rm -f /etc/systemd/system/docker.service.d/mmwx-firewall.conf
  rm -f /etc/systemd/system/mmwx-firewall.service /etc/systemd/system/mmwx-cf-sync.{service,timer} /etc/systemd/system/mmwx-network-rollback.{service,timer}
  rm -f /var/lib/systemd/timers/stamp-mmwx-cf-sync.timer
  systemctl daemon-reload || return 1
  if [[ -f $ROOT/state/docker-purge.json && $(jq -r .phase "$ROOT/state/docker-purge.json") != prepared ]]; then
    : # Docker was stopped or removed by an interrupted full uninstall.
  elif [[ -f $ROOT/config/compose.yaml || -f $ROOT/compose.yaml ]]; then
    run_step '移除项目容器' dc down --remove-orphans || return 1
  fi
  while iptables -C DOCKER-USER -o br-mmwx-front -j MMWX-CF 2>/dev/null; do iptables -D DOCKER-USER -o br-mmwx-front -j MMWX-CF || return 1; done
  if iptables -nL MMWX-CF >/dev/null 2>&1; then
    iptables -F MMWX-CF && iptables -X MMWX-CF || return 1
  fi
  local setname
  for setname in mmwx_cf mmwx_cf_next; do
    if ipset list "$setname" >/dev/null 2>&1; then ipset destroy "$setname" || return 1; fi
  done
  remove_legacy_cf_rules || return 1
  local backup=$ROOT/state/network-backup
  [[ -d $backup ]] || backup=$ROOT/network-backup
  if [[ ${1:-keep} == keep && -f $backup/state && $(cat "$backup/state") == pending ]]; then
    run_step '恢复未确认的网络设置' restore_install_network || return 1
  fi
}
purge_installation() {
  [[ $ROOT == /opt/mmwx-installer && ! -L $ROOT && $(readlink -f "$ROOT") == /opt/mmwx-installer ]] || die '安装目录异常，停止删除。'
  # A fixed project directory; never follow mounted filesystems during deletion.
  rm -rf --one-file-system -- "$ROOT"
  cleanup_downloads
  rm -f /usr/local/lib/mmwx-installer/runtime.sh
  if [[ -d /usr/local/lib/mmwx-installer ]]; then rmdir /usr/local/lib/mmwx-installer 2>/dev/null || true; fi
}
uninstall_stack() {
  caddy_token_pending_guard
  [[ -d $ROOT ]] || die '未发现安装目录。'
  # Uninstall reads the original layout directly; migration may start containers.
  local mode state
  for state in "$ROOT/state" "$ROOT"; do
    [[ ! -f $state/reinstall.json ]] || die '请先通过菜单 5 继续镜像重装。'
    [[ ! -f $state/update.json ]] || die '请先恢复未完成的更新。'
    [[ ! -f $state/image-rollback.json ]] || die '请先继续未完成的版本回退。'
  done
  printf '1. 卸载并保留数据（默认）\n2. 完全卸载（含 Docker、镜像、网络及全部数据）\n'
  mode=$(ask '选择 [1]：')
  case "$mode" in
    ''|1) mode=keep; confirm '卸载服务并保留数据？' || return 0;;
    2) mode=purge; confirm "完全卸载 Docker、全部镜像、缓存、存储卷和网络，永久删除 $ROOT 中的数据、备份和 Token，并恢复防火墙和 IPv6？" || return 0;;
    *) die '无效选择。';;
  esac
  if [[ $mode == keep && -f $ROOT/state/docker-purge.json ]]; then die '完全卸载尚未完成，请选择完全卸载继续。'; fi
  if [[ $mode == purge ]]; then
    network_restore_preflight || die '网络备份不可用，停止卸载。'
    docker_purge_preflight || die 'Docker 检查失败，停止卸载。'
  fi
  remove_services "$mode" || die '服务清理未完成，数据保留；请从菜单 10 重试。'
  if [[ $mode == purge ]]; then
    run_step '清理 Docker、镜像、缓存和网络' purge_docker || die 'Docker 清理未完成，保留进度；请从菜单 10 重试完全卸载。'
    hash -r
    run_step '恢复安装前的防火墙和 IPv6' restore_install_network || die '网络恢复失败，数据与备份保留；请从菜单 10 重试。'
    purge_installation
    info 'Docker、镜像、缓存、存储卷、虚拟网络及项目数据已删除，防火墙和 IPv6 已恢复。mmwx 管理菜单、系统时区及 Cloudflare DNS 记录保留。'
  else
    info "已卸载容器，数据保留于 $ROOT。运行 mmwx 选择恢复服务。"
  fi
}
uninstall_script() {
  confirm '移除 mmwx 管理命令？容器、数据和后台防火墙继续保留。' || return 0
  # Existing installations may still reference the manager from systemd.
  if [[ -f /etc/systemd/system/mmwx-cf-sync.timer || -f /etc/systemd/system/docker.service.d/mmwx-firewall.conf ]]; then install_units; fi
  if [[ -L /usr/local/bin/mmwx && $(readlink /usr/local/bin/mmwx) == /usr/local/sbin/mmwx-installer ]]; then rm -f /usr/local/bin/mmwx; fi
  rm -f /usr/local/sbin/mmwx-installer
  cleanup_downloads
  info '管理命令已移除。重新下载并运行安装脚本即可恢复管理。'
}
# Caddy management: read-only inspection and narrowly scoped service operations.
caddy_redact() (
  set +x
  python3 -c '
import pathlib, sys
root = pathlib.Path(sys.argv[1])
paths = [root / "config/cloudflare.token", root / "config/caddy.env"]
paths += [root / "state/caddy-token-change" / name for name in
          ("old.token", "old.env", "candidate.token", "candidate.env")]
secrets = set()
try:
    for path in paths:
        if not path.exists():
            continue
        value = path.read_text(encoding="utf-8")
        if path.suffix == ".env":
            for line in value.splitlines():
                key, separator, token = line.partition("=")
                if separator and key.strip() == "CF_API_TOKEN":
                    token = token.strip().strip(chr(34) + chr(39))
                    if token: secrets.add(token)
        elif value.strip():
            secrets.add(value.strip())
except (OSError, UnicodeError):
    print("无法读取脱敏凭据，已隐藏命令输出。", file=sys.stderr)
    sys.exit(1)
for line in sys.stdin:
    for token in sorted(secrets, key=len, reverse=True):
        line = line.replace(token, "[REDACTED]")
    sys.stdout.write(line)
' "$ROOT"
)
caddy_redacted_command() (
  set +x
  set -o pipefail
  "$@" 2>&1 | caddy_redact
)
caddy_step() (
  set +x
  local label=$1
  shift
  # Filtering happens inside the logged command, before run_step writes to disk.
  run_step "$label" caddy_redacted_command "$@"
)
caddy_validate_config() {
  caddy_step '校验 Caddy 配置' dc exec -T caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
}
caddy_ready() {
  python3 - "$ROOT" "$DOMAIN" <<'PY'
import socket, ssl, subprocess, sys, time
root, domain = sys.argv[1:]
deadline = time.monotonic() + 60
command = ["docker", "compose", "--project-name", "mmwx-installer",
           "--project-directory", root + "/config", "-f", root + "/config/compose.yaml",
           "ps", "--status", "running", "-q", "caddy"]
reason = "Caddy 未运行"
while time.monotonic() < deadline:
    remaining = deadline - time.monotonic()
    try:
        result = subprocess.run(command, capture_output=True, text=True,
                                timeout=min(5, remaining), check=False)
        if result.returncode != 0 or not result.stdout.strip():
            reason = "Caddy 未运行或状态不可读"
        else:
            remaining = deadline - time.monotonic()
            if remaining <= 0: break
            context = ssl.create_default_context()
            with socket.create_connection(("127.0.0.1", 443), timeout=min(3, remaining)) as sock:
                remaining = deadline - time.monotonic()
                if remaining <= 0: break
                sock.settimeout(min(3, remaining))
                with context.wrap_socket(sock, server_hostname=domain):
                    print("Caddy 已运行，本机源站 TLS 证书与域名验证通过。")
                    sys.exit(0)
    except ssl.SSLCertVerificationError:
        reason = "本机源站 TLS 证书或域名信任验证失败"
    except (OSError, ssl.SSLError, subprocess.SubprocessError):
        reason = "Caddy 状态或本机源站 TLS 连接未就绪"
    remaining = deadline - time.monotonic()
    if remaining > 0: time.sleep(min(1, remaining))
print("Caddy 在 60 秒内未就绪：" + reason + "。", file=sys.stderr)
sys.exit(1)
PY
}
caddy_certificate_probe() {
  python3 - "$1" "$2" "$3" <<'PY'
import datetime, math, os, socket, ssl, sys, tempfile
source, host, domain = sys.argv[1:]
label = "源站（本机 127.0.0.1）" if source == "origin" else "Cloudflare 边缘（公网 DNS）"
print(label + "；SNI=" + domain)
def connection_error(error):
    if isinstance(error, socket.gaierror):
        return "DNS 解析失败"
    if isinstance(error, ConnectionRefusedError):
        return "连接被拒绝，请检查服务及 443 端口"
    if isinstance(error, TimeoutError):
        return "连接超时，请检查网络和防火墙"
    if isinstance(error, ssl.SSLError):
        return "TLS 握手失败，请检查 HTTPS 配置"
    return "网络连接失败，请检查服务和网络"
def connect(context):
    with socket.create_connection((host, 443), timeout=5) as sock:
        with context.wrap_socket(sock, server_hostname=domain) as tls:
            return tls.getpeercert(), tls.getpeercert(binary_form=True)
verified = True
try:
    cert, _ = connect(ssl.create_default_context())
except ssl.SSLCertVerificationError:
    verified = False
    print("  信任验证失败；以下为未验证的证书信息。")
    try:
        _, der = connect(ssl._create_unverified_context())
        # The unverified TLS API provides DER only; decode a private temporary PEM.
        path = None
        try:
            with tempfile.NamedTemporaryFile(mode="w", suffix=".pem", delete=False) as pem:
                path = pem.name
                pem.write(ssl.DER_cert_to_PEM_cert(der))
            cert = ssl._ssl._test_decode_cert(path)
        finally:
            if path: os.unlink(path)
    except (OSError, ssl.SSLError) as error:
        print("  无法读取未验证证书：" + connection_error(error) + "。")
        sys.exit(1)
    except ValueError:
        print("  未验证证书格式异常。")
        sys.exit(1)
except (OSError, ssl.SSLError) as error:
    print("  " + connection_error(error) + "。")
    sys.exit(1)
except ValueError:
    print("  证书格式异常。")
    sys.exit(1)
try:
    before = ssl.cert_time_to_seconds(cert["notBefore"])
    after = ssl.cert_time_to_seconds(cert["notAfter"])
    now = datetime.datetime.now(datetime.timezone.utc).timestamp()
    days = math.floor((after - now) / 86400)
    names = ", ".join(value for kind, value in cert.get("subjectAltName", ()) if kind in ("DNS", "IP Address"))
    issuer = ", ".join(key + "=" + value for rdn in cert.get("issuer", ()) for key, value in rdn)
    print("  SAN：" + (names or "无"))
    print("  签发者：" + (issuer or "未知"))
    print("  生效时间：" + cert["notBefore"])
    print("  到期时间：" + cert["notAfter"])
    print("  剩余天数：" + str(days))
    if after <= now:
        print("  状态：已过期")
        sys.exit(1)
    if before > now:
        print("  状态：尚未生效")
        sys.exit(1)
    print("  状态：" + ("证书与域名验证通过" if verified else "未验证，不能确认可信"))
    sys.exit(0 if verified else 1)
except (KeyError, TypeError, ValueError, OverflowError):
    print("  证书信息不完整，无法判定有效期。")
    sys.exit(1)
PY
}
caddy_action() {
  local action=$1 result=0 http_status
  case "$action" in
    reload|restart) caddy_require_install write || return $?;;
    status|logs|certificates) caddy_require_install read || return $?;;
    *) printf '无效 Caddy 操作。\n' >&2; return 1;;
  esac
  case "$action" in
    status)
      section 'Caddy 运行状态'
      printf '  域名：%s\n' "$DOMAIN"
      caddy_redacted_command dc ps caddy || return $?
      caddy_redacted_command dc exec -T caddy caddy version;;
    logs) caddy_redacted_command dc logs --tail 80 caddy;;
    reload)
      caddy_validate_config || return $?
      caddy_step '重载 Caddy 配置' dc exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile || return $?
      caddy_ready;;
    restart)
      confirm '重启 Caddy？HTTPS 访问将短暂中断。' || return 0
      caddy_step '重启 Caddy' dc restart caddy || return $?
      caddy_validate_config || return $?
      caddy_ready;;
    certificates)
      caddy_redacted_command caddy_certificate_probe origin 127.0.0.1 "$DOMAIN" || result=1
      caddy_redacted_command caddy_certificate_probe edge "$DOMAIN" "$DOMAIN" || result=1
      printf '\n  公网 HTTPS 状态（独立于源站证书检查）：\n'
      if http_status=$(curl --proto '=https' --connect-timeout 5 --max-time 15 -sS -o /dev/null -w '%{http_code}' "https://$DOMAIN/" 2>/dev/null); then
        printf '  HTTP %s\n' "$http_status"
      else
        printf '  公网 HTTPS 连接失败。\n'
        result=1
      fi
      return "$result";;
  esac
}
caddy_menu() {
  local choice action
  local -a arguments=()
  [[ -z $TOKEN_FILE ]] || arguments+=(--cf-token-file "$TOKEN_FILE")
  while true; do
    section 'Caddy 管理'
    printf '    1  查看运行状态\n    2  查看最近 80 行日志\n    3  校验并重载配置\n    4  重启 Caddy\n    5  查看源站 / Cloudflare 边缘证书\n    6  更换 Cloudflare Token\n\n    0  返回\n\n'
    choice=$(ask '选择：')
    case "$choice" in
      1) action=caddy-status;; 2) action=caddy-logs;; 3) action=caddy-reload;;
      4) action=caddy-restart;; 5) action=caddy-certificates;; 6) action=caddy-token;;
      0) return 0;; *) printf '无效选择。\n'; continue;;
    esac
    if /bin/bash "$SELF" "$action" "${arguments[@]}"; then :; else info '操作未完成，可从菜单重试。'; fi
    [[ -f $SELF ]] || return 0
  done
}
# End Caddy management functions.

usage() {
  cat <<'EOF'
用法（root）：mmwx（管理菜单）或 bash install.sh [install|update|reinstall|rollback|uninstall|status|logs|resume|check|self-update|uninstall-script|caddy]
  --prefix mmwx              子域名前缀（交互输入回车默认 mmwx）
  --zone example.com         Token 授权多个主域名时指定主域名
  --domain panel.example.com  兼容完整域名参数
  --channel stable|beta       安装或更新的发布通道
  --cf-token-file /root/token root 所有、600 权限的 Token 文件
  --yes                      接受全新环境提示；必须五分钟内另开 SSH 执行 confirm-network
安装需确认新 SSH 连接；check 只检查环境，不修改系统。
reinstall 重新拉取当前版本镜像，仅重建妙妙屋容器，保留全部数据和配置。
self-update 从最新正式 Release 更新管理脚本，并校验 SHA-256。
打开管理菜单时自动检测脚本新版本；检测失败不影响使用，菜单 9 手动更新。
trace 查看最近任务及失败原因；trace-follow 实时追踪；log-menu 打开日志与诊断。
caddy 打开网关管理菜单；caddy-token --cf-token-file /root/token 替换 Token。
caddy-status / caddy-logs / caddy-reload / caddy-restart / caddy-certificates 可直接执行。
EOF
}
caddy_require_install() {
  [[ ! -f $ROOT/state.json && ! -f $ROOT/progress.json && ! -d $ROOT/.layout-migration ]] || die '旧目录请先通过菜单 5 完成迁移，再管理 Caddy。'
  local path
  for path in "$ROOT" "$ROOT/config" "$ROOT/state"; do
    [[ -d $path && ! -L $path ]] || die '安装目录缺失或为符号链接。'
  done
  for path in compose.yaml Caddyfile caddy.env cloudflare.token; do
    [[ -f $ROOT/config/$path && ! -L $ROOT/config/$path ]] || die "缺少常规配置文件：$path"
  done
  load_state
  valid_domain "$DOMAIN" || die '安装域名无效。'
}
caddy_require_idle() {
  local task
  for task in reinstall.json update.json image-rollback.json; do
    [[ ! -f $ROOT/state/$task ]] || die '有未完成的维护任务，请先选择菜单 5。'
  done
  if [[ -f $ROOT/state/progress.json ]]; then
    [[ $(jq -r .stage "$ROOT/state/progress.json") == 7 ]] || die '请先通过菜单 5 完成安装。'
  fi
}
caddy_lock_cf() { exec 8>/run/mmwx-cf.lock; flock -w 180 8 || die 'CF 同步正在运行，请稍后重试。'; }
caddy_refresh_runtime() {
  # Old releases updated the menu without updating the timer's private copy.
  # Called with both maintenance/CF locks held, before any credential change.
  local runtime=/usr/local/lib/mmwx-installer/runtime.sh staged
  [[ -f $runtime ]] || return 0
  cmp -s "$SELF" "$runtime" && return 0
  staged=$(mktemp /usr/local/lib/mmwx-installer/.runtime.XXXXXX) || return 1
  if ! install -m 0700 "$SELF" "$staged" || ! mv -f "$staged" "$runtime"; then
    rm -f "$staged"; return 1
  fi
}
caddy_token_pending_guard() {
  [[ ! -e $ROOT/state/caddy-token-change ]] || die 'Token 替换待恢复，请先选择菜单 5。'
}
caddy_token_file_check() {
  [[ -f $1 && ! -L $1 && $(stat -c %u "$1") == 0 && $(stat -c %a "$1") == 600 ]]
}
caddy_token_phase() {
  local dir=$ROOT/state/caddy-token-change
  jq --arg phase "$1" '.phase=$phase' "$dir/journal.json" > "$dir/journal.tmp" || return 1
  mv "$dir/journal.tmp" "$dir/journal.json"
}
caddy_token_stage() (
  set +x
  local dir=$ROOT/state/caddy-token-change staging candidate=''
  caddy_token_pending_guard
  if ! caddy_token_file_check "$ROOT/config/cloudflare.token" || ! caddy_token_file_check "$ROOT/config/caddy.env"; then die '现有凭据必须为 root 所有、600 权限的常规文件。'; fi
  staging=$(mktemp -d "$ROOT/state/.caddy-token-XXXXXX") || return 1
  [[ -n $staging && -d $staging && ! -L $staging ]] || return 1
  trap 'rm -rf -- "$staging"' EXIT
  chmod 700 "$staging" || return 1
  if [[ -n $TOKEN_FILE ]]; then
    caddy_token_file_check "$TOKEN_FILE" || die 'Token 文件必须为 root 所有、600 权限的常规文件。'
    cp "$TOKEN_FILE" "$staging/candidate.token" || return 1
  else
    read -r -s -p '新的 Cloudflare Token：' candidate </dev/tty || die '无法读取 Token。'
    printf '\n' >/dev/tty
    printf '%s\n' "$candidate" > "$staging/candidate.token" || return 1
    unset candidate
  fi
  cp "$ROOT/config/cloudflare.token" "$staging/old.token" || return 1
  cp "$ROOT/config/caddy.env" "$staging/old.env" || return 1
  if ! python3 - "$staging" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
def token(name):
    v = (p / name).read_text().strip()
    if not re.fullmatch(r'[A-Za-z0-9_.-]{20,256}', v):
        raise ValueError()
    return v
try:
    old, new = token('old.token'), token('candidate.token')
    raw = (p / 'old.env').read_bytes()
    matches = list(re.finditer(rb'(?m)^CF_API_TOKEN=([^\r\n]*)', raw))
    if len(matches) != 1 or matches[0].group(1).decode() != old:
        raise ValueError()
    m = matches[0]
    (p / 'candidate.env').write_bytes(raw[:m.start(1)] + new.encode() + raw[m.end(1):])
    (p / 'candidate.token').write_bytes((new + '\n').encode())
except Exception:
    print('Token 格式无效或现有两份凭据不一致。', file=sys.stderr)
    sys.exit(1)
PY
  then return 1; fi
  jq -n --arg domain "$DOMAIN" '{phase:"probing",domain:$domain,zone:"",name:"",value:"",comment:""}' > "$staging/journal.json" || return 1
  chmod 600 "$staging"/* || return 1
  mv "$staging" "$dir" || return 1
)
# Request arguments contain paths only. Never retry POST: a lost response may
# already have created the record. Recovery reconciles the exact random probe.
caddy_token_request() (
  set +x
  local method=$1 endpoint=$2 payload=$3 output=$4 dir=$ROOT/state/caddy-token-change status
  local -a args=()
  local credential
  credential=$(cat "$dir/candidate.token") || return 1
  [[ -n $credential ]] || return 1
  printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "$credential" > "$dir/request.headers" || return 1
  unset credential
  [[ -z $payload ]] || args+=(--data-binary "@$payload")
  status=$(curl --proto '=https' --tlsv1.2 --silent --show-error --connect-timeout 10 --max-time 30 \
    --request "$method" --header "@$dir/request.headers" "${args[@]}" \
    --output "$output" --write-out '%{http_code}' "https://api.cloudflare.com/client/v4$endpoint" 2> "$dir/request.error") || return 1
  [[ $status == 2?? ]] && jq -e '.success == true' "$output" >/dev/null 2>&1
)
caddy_token_cleanup() {
  local require_match=${1:-0} dir=$ROOT/state/caddy-token-change zone name id
  [[ $(jq -r '.txt_clean // false' "$dir/journal.json") != true ]] || return 0
  zone=$(jq -r .zone "$dir/journal.json")
  name=$(jq -r .name "$dir/journal.json")
  [[ -n $zone && -n $name ]] || return 0
  caddy_token_request GET "/zones/$zone/dns_records?type=TXT&name=$name&per_page=100" '' "$dir/records.json" || return 1
  jq -e '(.result|type)=="array" and (.result_info.total_pages // 1)<=1' "$dir/records.json" >/dev/null || return 1
  jq -r --slurpfile j "$dir/journal.json" '.result[] | select(.type=="TXT" and .name==$j[0].name and .content==$j[0].value and .comment==$j[0].comment) | .id' "$dir/records.json" > "$dir/record-ids" || return 1
  # A successful POST's known record must be observed before deletion. An
  # unexpectedly empty list cannot prove it disappeared without our attempt.
  id=$(jq -r '.record_id // ""' "$dir/journal.json") || return 1
  if [[ -n $id && $(jq -r '.delete_started // false' "$dir/journal.json") != true ]]; then
    grep -Fxq "$id" "$dir/record-ids" || return 1
  fi
  if [[ $require_match == 1 ]]; then
    id=$(jq -er .record_id "$dir/journal.json") || return 1
    grep -Fxq "$id" "$dir/record-ids" || return 1
  fi
  while IFS= read -r id; do
    [[ $id =~ ^[a-zA-Z0-9]+$ ]] || return 1
    jq '.delete_started=true' "$dir/journal.json" > "$dir/journal.tmp" && mv "$dir/journal.tmp" "$dir/journal.json" || return 1
    # DELETE errors may mean the successful response was lost. Confirm below.
    caddy_token_request DELETE "/zones/$zone/dns_records/$id" '' "$dir/deleted.json" || true
  done < "$dir/record-ids"
  caddy_token_request GET "/zones/$zone/dns_records?type=TXT&name=$name&per_page=100" '' "$dir/records.json" || return 1
  jq -e --slurpfile j "$dir/journal.json" '(.result|type)=="array" and (.result_info.total_pages // 1)<=1 and ([.result[] | select(.type=="TXT" and .name==$j[0].name and .content==$j[0].value and .comment==$j[0].comment)]|length)==0' "$dir/records.json" >/dev/null || return 1
  jq '.txt_clean=true' "$dir/journal.json" > "$dir/journal.tmp" && mv "$dir/journal.tmp" "$dir/journal.json"
}
caddy_token_probe() {
  local dir=$ROOT/state/caddy-token-change page=1 pages zone random
  printf '[]' > "$dir/zones.json" || return 1
  while true; do
    caddy_token_request GET "/zones?status=active&per_page=50&page=$page" '' "$dir/response.json" || return 1
    jq -e '.result|type=="array"' "$dir/response.json" >/dev/null || return 1
    jq -s '.[0] + .[1].result' "$dir/zones.json" "$dir/response.json" > "$dir/zones.tmp" || return 1
    mv "$dir/zones.tmp" "$dir/zones.json" || return 1
    pages=$(jq -r '.result_info.total_pages // 1' "$dir/response.json")
    [[ $pages =~ ^[0-9]+$ && $pages -le 100 ]] || return 1
    ((page < pages)) || break
    page=$((page+1))
  done
  zone=$(jq -r --arg domain "$DOMAIN" '[.[] | select(.status=="active") | . as $z | select($domain==$z.name or ($domain|endswith("."+$z.name)))] | sort_by(.name|length) | last | .id // ""' "$dir/zones.json")
  [[ $zone =~ ^[a-zA-Z0-9]+$ ]] || return 1
  local value
  random=$(openssl rand -hex 16) || return 1
  value=$(openssl rand -hex 24) || return 1
  jq --arg zone "$zone" --arg name "_mmwx-token-$random.$DOMAIN" --arg value "$value" --arg comment "mmwx-token-check-$random" \
    '.zone=$zone | .name=$name | .value=$value | .comment=$comment' "$dir/journal.json" > "$dir/journal.tmp" || return 1
  mv "$dir/journal.tmp" "$dir/journal.json" || return 1
  jq '{type:"TXT",name:.name,content:.value,ttl:60,comment:.comment}' "$dir/journal.json" > "$dir/create.json" || return 1
  caddy_token_request POST "/zones/$zone/dns_records" "$dir/create.json" "$dir/response.json" || return 1
  jq -e '.result.id|type=="string" and test("^[a-zA-Z0-9]+$")' "$dir/response.json" >/dev/null || return 1
  jq --slurpfile response "$dir/response.json" '.record_id=$response[0].result.id' "$dir/journal.json" > "$dir/journal.tmp" && mv "$dir/journal.tmp" "$dir/journal.json" || return 1
  caddy_token_cleanup 1 || return 1
  caddy_token_phase validated
}
caddy_token_replace_files() {
  local prefix=$1 dir=$ROOT/state/caddy-token-change
  # Both temporary targets stay private and on the same filesystem as config.
  install -m 600 "$dir/$prefix.token" "$ROOT/config/.cloudflare.token.new" &&
    mv -f "$ROOT/config/.cloudflare.token.new" "$ROOT/config/cloudflare.token" &&
    install -m 600 "$dir/$prefix.env" "$ROOT/config/.caddy.env.new" &&
    mv -f "$ROOT/config/.caddy.env.new" "$ROOT/config/caddy.env"
}
caddy_token_discard() {
  rm -f "$ROOT/config/.cloudflare.token.new" "$ROOT/config/.caddy.env.new"
  rm -rf -- "$ROOT/state/caddy-token-change"
}
recover_caddy_token() (
  set +x
  local dir=$ROOT/state/caddy-token-change phase
  caddy_require_install write
  caddy_require_idle
  [[ -d $dir && ! -L $dir && -f $dir/journal.json ]] || die 'Token 恢复记录缺失。'
  phase=$(jq -er .phase "$dir/journal.json") || die 'Token 恢复记录无效。'
  [[ $(jq -r .domain "$dir/journal.json") == "$DOMAIN" ]] || die 'Token 恢复记录的域名不匹配。'
  case "$phase" in
    probing|validated|committed|restored) ;;
    applying|rollback)
      caddy_token_phase rollback || die '无法保存恢复记录。'
      caddy_token_replace_files old || die '旧凭据恢复失败，请重试菜单 5。'
      if ! caddy_step '恢复 Caddy' dc up -d --no-deps --force-recreate --wait --wait-timeout 300 caddy || ! caddy_validate_config || ! caddy_ready; then die 'Caddy 恢复检查未通过，记录保留；请重试菜单 5。'; fi
      caddy_token_phase restored || die '无法保存恢复记录。';;
    *) die '无法识别 Token 恢复阶段，记录保留。';;
  esac
  caddy_token_cleanup || die '临时 TXT 清理失败，旧配置保留；请稍后重试菜单 5。'
  caddy_token_discard || die '凭据暂存清理失败，请重试菜单 5。'
  info 'Token 任务已恢复，证书和业务数据保留。'
)
caddy_token_apply() {
  caddy_token_phase applying || return 1
  caddy_token_replace_files candidate || return 1
  if ! caddy_step '应用 Caddy Token' dc up -d --no-deps --force-recreate --wait --wait-timeout 300 caddy || ! caddy_validate_config || ! caddy_ready; then return 1; fi
  caddy_token_phase committed
}
replace_caddy_token() (
  set +x
  caddy_require_install write
  caddy_require_idle
  caddy_token_pending_guard
  confirm '替换 Cloudflare Token？网关会短暂中断，证书和业务数据保留。' || return 0
  caddy_token_stage || die '无法暂存新 Token，未修改配置。'
  if ! caddy_token_probe; then
    if caddy_token_cleanup; then caddy_token_discard; fi
    die 'Token 权限验证或临时 TXT 清理失败，未修改配置；有待恢复任务时请选择菜单 5。'
  fi
  if ! caddy_token_apply; then
    recover_caddy_token || die '应用失败且恢复未完成，请重试菜单 5。'
    die '新 Token 应用失败，已恢复旧配置。'
  fi
  caddy_token_discard || die 'Token 已生效，暂存清理失败，请通过菜单 5 清理。'
  info 'Cloudflare Token 已替换，现有证书继续使用。'
)
resume_task() {
  if [[ -e $ROOT/state/caddy-token-change ]]; then
    caddy_lock_cf
    caddy_refresh_runtime || die '后台程序更新失败，请重试。'
    recover_caddy_token; return
  fi
  ensure_layout
  install_command
  if [[ -f $ROOT/state/reinstall.json ]]; then
    preflight; finish_reinstall
  elif [[ -f $ROOT/state/update.json ]]; then
    preflight; recover_update
  elif [[ -f $ROOT/state/image-rollback.json ]]; then
    preflight; finish_image_rollback
  elif [[ -f $ROOT/state/progress.json ]] && [[ $(jq -r .stage "$ROOT/state/progress.json") -lt 7 ]]; then
    install_stack
  else
    [[ -f $ROOT/state/state.json ]] || die '没有可恢复的任务，请从菜单选择安装。'
    preflight; load_state; install_units; network_is_ready || die '请检查 UFW/IPv6 配置后恢复。'
    configure_timezone
    render_compose > "$ROOT/config/compose.yaml.tmp"
    mv "$ROOT/config/compose.yaml.tmp" "$ROOT/config/compose.yaml"
    dc config --quiet
    sync_cf; run_step '启动服务' dc up -d --wait --wait-timeout 300; verify_https
    info "已恢复：https://$DOMAIN"
  fi
}
menu_header() {
  local state=$ROOT/state/state.json version='未安装' domain='' task=''
  [[ -f $state ]] || state=$ROOT/state.json
  if command -v jq >/dev/null && [[ -f $state ]]; then
    version=$(jq -r '.version // "未知"' "$state" 2>/dev/null) || version='未知'
    domain=$(jq -r '.domain // ""' "$state" 2>/dev/null) || domain=''
  fi
  if [[ -e $ROOT/state/caddy-token-change ]]; then task='Token 替换待恢复';
  elif [[ -f $ROOT/state/reinstall.json ]]; then task='镜像重装待继续';
  elif [[ -f $ROOT/state/image-rollback.json ]]; then task='版本切换待继续';
  elif [[ -f $ROOT/state/update.json ]]; then task='更新恢复待继续';
  elif command -v jq >/dev/null && [[ -f $ROOT/state/progress.json ]] && [[ $(jq -r .stage "$ROOT/state/progress.json") != 7 ]]; then task='安装待继续'; fi
  section "妙妙屋 X  ·  管理脚本 v$SCRIPT_VERSION"
  printf '  主控  %s\n' "$version"
  [[ -z $domain ]] || printf '  访问  https://%s\n' "$domain"
  [[ -z $task ]] || printf '  任务  %s（菜单 5）\n' "$task"
  [[ -z $SCRIPT_UPDATE_VERSION ]] || printf '  脚本  发现新版本 %s（菜单 9 更新）\n' "$SCRIPT_UPDATE_VERSION"
  printf '\n'
}
menu() {
  local choice action
  local -a arguments=()
  [[ -z $TOKEN_FILE ]] || arguments+=(--cf-token-file "$TOKEN_FILE")
  [[ -z $DOMAIN ]] || arguments+=(--domain "$DOMAIN")
  [[ -z $PREFIX ]] || arguments+=(--prefix "$PREFIX")
  [[ -z $ZONE_NAME ]] || arguments+=(--zone "$ZONE_NAME")
  [[ -z $CHANNEL ]] || arguments+=(--channel "$CHANNEL")
  check_script_update
  while true; do
    menu_header
    printf '  服务\n    1  安装 / 继续安装\n    2  更新主控版本\n    3  运行状态\n    4  查看日志\n    5  继续任务 / 恢复服务\n    6  回退主控版本\n    7  强制重新安装\n\n  管理\n    8  Caddy 管理\n    9  更新管理脚本\n   10  卸载服务\n   11  卸载管理脚本\n\n    0  退出\n\n'
    choice=$(ask '选择：')
    case "$choice" in
      1) action=install;; 2) action=update;; 3) action=status;; 4) action=log-menu;;
      5) action=resume;; 6) action=rollback;;
      7) action=reinstall;; 8) action=caddy;; 9) action=self-update;; 10) action=uninstall;; 11) action=uninstall-script;;
      0) return 0;; *) printf '无效选择。\n'; continue;;
    esac
    if /bin/bash "$SELF" "$action" "${arguments[@]}"; then
      if [[ $action == self-update ]]; then exec /bin/bash /usr/local/sbin/mmwx-installer; fi
      if [[ $action == uninstall-script ]]; then return 0; fi
    else info '操作未完成，可从菜单重试。'; fi
    [[ -f $SELF ]] || return 0
  done
}
main() {
  local -a MENU_ARGUMENTS=("$@")
  if [[ $SELF == /usr/local/lib/mmwx-installer/runtime.sh ]]; then
    [[ $# == 1 ]] || die '后台程序仅接受一个防火墙任务参数。'
    case "${1:-}" in firewall-apply|firewall-sync) ;; *) die '此文件仅用于后台防火墙任务，管理入口已独立安装。';; esac
  fi
  while (($#)); do
    case "$1" in
      install|update|reinstall|uninstall|status|logs|log-menu|trace|trace-follow|resume|check|self-update|uninstall-script|rollback|firewall-apply|firewall-sync|confirm-network|caddy|caddy-status|caddy-logs|caddy-reload|caddy-restart|caddy-certificates|caddy-token) ACTION=$1; shift;;
      --yes) ACCEPT=1; shift;;
      --domain|--prefix|--zone|--channel|--cf-token-file)
        [[ $# -ge 2 ]] || die "缺少参数：$1"
        case "$1" in --domain) DOMAIN=$2;; --prefix) PREFIX=$2;; --zone) ZONE_NAME=$2;; --channel) CHANNEL=$2; CHANNEL_EXPLICIT=1;; --cf-token-file) TOKEN_FILE=$2;; esac; shift 2;;
      -v|--version) printf 'mmwx-installer %s\n' "$SCRIPT_VERSION"; return;;
      -h|--help) usage; return;; *) die "未知参数：$1";;
    esac
  done
  [[ $EUID == 0 ]] || die '请使用 root 运行。'
  if [[ -z $ACTION ]]; then open_installed_menu; return; fi
  case "$ACTION" in install|update|reinstall|uninstall|resume|self-update|uninstall-script|rollback|caddy-reload|caddy-restart|caddy-token) exec 7>/run/mmwx-installer.lock; flock -n 7 || die '另一个安装或维护进程正在运行，请等待。';; esac
  case "$ACTION" in install|update|reinstall|uninstall|resume|rollback|self-update|caddy-reload|caddy-restart|caddy-token|check)
    trace_start "$ACTION" || die '无法创建任务日志。';;
  esac
  if [[ -f $ROOT/state/docker-purge.json ]]; then
    case "$ACTION" in install|update|reinstall|resume|rollback|caddy-reload|caddy-restart|caddy-token)
      die '完全卸载尚未完成，请从菜单 10 继续。';;
    esac
  fi
  case "$ACTION" in caddy-reload|caddy-restart|caddy-token)
    caddy_require_install write; caddy_require_idle; caddy_token_pending_guard; caddy_lock_cf
    caddy_refresh_runtime || die '后台程序更新失败，未修改 Caddy。';;
  esac
  if [[ $ACTION == install && ! -f $ROOT/state/progress.json ]]; then
    printf '\033[1;31m请使用专用服务器安装（全新 Debian / Ubuntu，无其他业务）。\n安装会启用 UFW、禁用 IPv6；请用 IPv4 SSH。\033[0m\n'
    if [[ $ACCEPT == 0 ]]; then confirm '开始安装？' || return 0; fi
  fi
  case "$ACTION" in
    firewall-apply) apply_firewall;; firewall-sync) sync_cf;; confirm-network) confirm_network;;
    check) preflight; info '环境预检通过。';;
    install) install_stack;; update) update_stack;; uninstall) uninstall_stack;;
    reinstall) reinstall_stack;;
    self-update) self_update;; rollback) rollback_stack;;
    uninstall-script) uninstall_script;;
    status) load_state; dc ps; ufw status;; logs) load_state; caddy_redacted_command dc logs --tail 80 caddy mmwx;;
    log-menu) logs_menu;; trace) trace_show;; trace-follow) trace_follow;;
    resume) resume_task;;
    caddy) caddy_menu;;
    caddy-token) replace_caddy_token;;
    caddy-status|caddy-logs|caddy-reload|caddy-restart|caddy-certificates) caddy_action "${ACTION#caddy-}";;
  esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  trap 'trace_finish "$?"; [[ -z $TEMP_TOKEN ]] || rm -f "$TEMP_TOKEN"' EXIT
  trap 'trace_error "$?" "$LINENO" "${FUNCNAME[*]:-main}"' ERR
  trap 'trace_event INTERRUPTED "exit=130"; printf "\n已中断，运行 mmwx 继续。\n"; exit 130' INT TERM
  main "$@"
fi
