#!/usr/bin/env bash
# Independent installer. Never invoke the upstream install script.
set -Eeuo pipefail
umask 077
ROOT=/opt/mmwx-installer
UPSTREAM=iluobei/miaomiaowuX
CHANNEL='' DOMAIN='' PREFIX='' ZONE_NAME='' TOKEN_FILE='' ACTION='' ACCEPT=0 TEMP_TOKEN='' CHANNEL_EXPLICIT=0 STAGE=0 VERSION=''
APP_IMAGE='' CADDY_IMAGE='' PG_IMAGE=postgres:18-alpine
SELF=$(readlink -f "${BASH_SOURCE[0]}")

info() { printf '\033[36m%s\033[0m\n' "$*"; }
die() { printf '\033[31m错误：%s\033[0m\n' "$*" >&2; exit 1; }
ask() { local value; read -r -p "$1" value </dev/tty || die '无法读取终端，请下载脚本后运行。'; printf '%s' "$value"; }
is_yes() { [[ $1 == y || $1 == Y ]]; }
confirm() {
  local answer
  while true; do
    answer=$(ask "$1 [y/n]：")
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
dc() { docker compose --project-name mmwx-installer --project-directory "$ROOT" -f "$ROOT/compose.yaml" "$@"; }
valid_domain() {
  [[ $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ && ${#1} -le 253 ]]
}
select_release() {
  jq -ce --arg channel "$1" '[.[] | select(.draft == false and (.prerelease == ($channel == "beta"))) | select(.published_at != null)] | sort_by(.published_at) | last | select(. != null)'
}
recent_releases() {
  jq -ce '[.[] | select(.draft == false and .published_at != null)] | unique_by(.tag_name) | sort_by(.published_at) | reverse | .[:5]'
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
  local rows='[]' page html parsed
  html=$(get "https://github.com/$UPSTREAM/releases/latest") || return 1
  parsed=$(parse_release_html <<<"$html") || return 1
  rows=$parsed
  for page in $(seq 1 10); do
    html=$(get "https://github.com/$UPSTREAM/releases?page=$page") || return 1
    parsed=$(parse_release_html <<<"$html") || return 1
    rows=$(printf '%s\n%s\n' "$rows" "$parsed" | jq -cs 'add | unique_by(.tag_name)')
    if select_release beta <<<"$rows" >/dev/null; then break; fi
    [[ $html == *'rel="next"'* || $html == *'>Next<'* ]] || break
  done
  printf '%s\n' "$rows"
}
fetch_releases() {
  local rows='[]' page result
  for page in $(seq 1 20); do
    if ! result=$(get "https://api.github.com/repos/$UPSTREAM/releases?per_page=100&page=$page" 2>/dev/null) || ! jq -e 'type == "array"' <<<"$result" >/dev/null 2>&1; then
      printf '版本 API 暂不可用，改用官方发布页面。\n' >&2
      fetch_releases_web
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
    env_file: [caddy.env]
    environment: {TZ: Asia/Shanghai}
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./caddy-data:/data
      - ./caddy-config:/config
      - /usr/share/zoneinfo/Asia/Shanghai:/etc/localtime:ro
      - /usr/share/zoneinfo/Asia/Shanghai:/usr/share/zoneinfo/Asia/Shanghai:ro
    networks: [frontend]
    depends_on:
      mmwx: {condition: service_healthy}
  mmwx:
    image: $APP_IMAGE
    restart: unless-stopped
    env_file: [app.env]
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
      - ./data:/app/data
      - ./subscribes:/app/subscribes
      - ./rule_templates:/app/rule_templates
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
    env_file: [postgres.env]
    environment: {POSTGRES_DB: mmwx, POSTGRES_USER: mmwx, TZ: Asia/Shanghai, PGTZ: Asia/Shanghai}
    command: [postgres, -c, timezone=Asia/Shanghai, -c, log_timezone=Asia/Shanghai]
    volumes:
      - ./postgres-data:/var/lib/postgresql
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
  local proxies=''
  if [[ -f $ROOT/cloudflare-v4.txt ]]; then
    validate_cidrs < "$ROOT/cloudflare-v4.txt"
    proxies="trusted_proxies static $(tr '\n' ' ' < "$ROOT/cloudflare-v4.txt")"
  fi
  cat <<EOF
{
  servers {
    protocols h1 h2
    $proxies
    client_ip_headers CF-Connecting-IP
  }
}
$DOMAIN {
  tls {
    dns cloudflare {env.CF_API_TOKEN}
    resolvers 1.1.1.1 1.0.0.1
  }
  reverse_proxy mmwx:12889
}
EOF
}

preflight() {
  [[ $(uname -s) == Linux && $EUID == 0 ]] || die '请在 Linux 服务器上使用 root / sudo 运行。'
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
    if [[ ! -f $ROOT/state.json && ! -f $ROOT/progress.json ]] && [[ -n $(docker ps -aq) ]]; then die '发现已有容器，停止安装。'; fi
  fi
  if [[ ! -f $ROOT/state.json ]]; then
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
    [[ ! -e $ROOT/compose.yaml || -f $ROOT/progress.json ]] || die "发现未知安装文件：$ROOT。"
  fi
}
dependencies() {
  info '安装基础依赖……'
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl jq python3 ufw ipset openssl >/dev/null
}
configure_timezone() {
  if [[ ! -f /usr/share/zoneinfo/Asia/Shanghai ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tzdata >/dev/null
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
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
    systemctl enable --now docker
  fi
  docker compose version >/dev/null || die '缺少 Docker Compose 插件。'
  if [[ -f /etc/docker/daemon.json ]]; then
    jq -e '(."firewall-backend" // "iptables") == "iptables" and (.ipv6 // false) == false and (.iptables // true) == true' /etc/docker/daemon.json >/dev/null || die 'Docker 网络配置不兼容；请使用全新环境。'
  fi
  iptables -nL DOCKER-USER >/dev/null || die '需要 Docker iptables 后端的 DOCKER-USER 链。'
}
build_caddy() {
  local builddir architecture asset
  case $(uname -m) in x86_64) architecture=amd64;; aarch64) architecture=arm64;; *) die '不支持的架构。';; esac
  asset="caddy-linux-$architecture.gz"
  builddir=$(mktemp -d)
  info '下载预编译的 Caddy + Cloudflare 模块（服务器无需编译）……'
  get "https://github.com/xiangwan6667/mmwx-installer/releases/download/v0.1.0-rc.1/$asset" -o "$builddir/$asset"
  get 'https://github.com/xiangwan6667/mmwx-installer/releases/download/v0.1.0-rc.1/SHA256SUMS' -o "$builddir/SHA256SUMS"
  (cd "$builddir"; grep -E "^[a-f0-9]{64}  $asset$" SHA256SUMS | sha256sum -c -) || { rm -rf "$builddir"; die 'Caddy 下载校验失败。'; }
  gzip -dc "$builddir/$asset" > "$builddir/caddy"
  chmod 0755 "$builddir/caddy"
  cat > "$builddir/Dockerfile" <<'EOF'
FROM caddy:2.11.4
COPY caddy /usr/bin/caddy
EOF
  info '组装 Caddy 容器镜像……'
  docker build --pull -t mmwx-installer-caddy:2.11.4-cf0.2.4 "$builddir" || { rm -rf "$builddir"; die 'Caddy 构建失败，请检查网络、内存和磁盘。'; }
  rm -rf "$builddir"
  CADDY_IMAGE=mmwx-installer-caddy:2.11.4-cf0.2.4
  docker run --rm --network none "$CADDY_IMAGE" caddy list-modules | grep -qx dns.providers.cloudflare || die 'Caddy 缺少 Cloudflare 模块。'
}
choose_version() {
  local pages selected mode
  pages=$(fetch_releases) || die '无法读取官方版本，请检查 GitHub 网络连接后用 mmwx 继续。'
  info '选择版本：'
  for mode in stable beta; do
    selected=$(select_release "$mode" <<<"$pages") || selected=null
    jq -r --arg mode "$mode" 'if . == null then "\($mode)：暂无" else "\($mode)：\(.tag_name)  \(.published_at)" end' <<<"$selected"
  done
  if [[ -z $CHANNEL || ( $ACTION == update && $CHANNEL_EXPLICIT == 0 && $ACCEPT == 0 ) ]]; then
    local choice
    choice=$(ask "1=正式版 / 2=Beta / 3=指定版本 [回车沿用 ${CHANNEL:-stable}]：")
    case "$choice" in
      '') CHANNEL=${CHANNEL:-stable};; 1) CHANNEL=stable;; 2) CHANNEL=beta;;
      3)
        local recent count number
        recent=$(recent_releases <<<"$pages")
        count=$(jq length <<<"$recent")
        [[ $count -gt 0 ]] || die '没有可选版本。'
        jq -r 'to_entries[] | "\(.key+1). \(.value.tag_name)  \(.value.published_at[:10])"' <<<"$recent"
        number=$(ask '版本编号：')
        [[ $number =~ ^[1-5]$ && $number -le $count ]] || die '无效编号。'
        selected=$(jq -c --argjson index "$((number-1))" '.[$index]' <<<"$recent")
        CHANNEL=$(jq -r 'if .prerelease then "beta" else "stable" end' <<<"$selected")
        ;;
      *) die '无效选择。';;
    esac
  else
    selected=''
  fi
  [[ $CHANNEL == stable || $CHANNEL == beta ]] || die 'channel 只能是 stable 或 beta。'
  if [[ ${choice:-} != 3 ]]; then selected=$(select_release "$CHANNEL" <<<"$pages") || die "没有可用的 $CHANNEL 版本。"; fi
  VERSION=$(jq -r .tag_name <<<"$selected")
  [[ $VERSION =~ ^v?[0-9][A-Za-z0-9._-]*$ ]] || die '上游版本号格式异常。'
  APP_IMAGE="ghcr.io/iluobei/miaomiaowux:${VERSION#v}"
  info "选择 $VERSION；检查对应镜像……"
  docker pull "$APP_IMAGE" || die "镜像尚未发布或下载失败：$APP_IMAGE。不会改用 latest。"
  APP_IMAGE=$(docker image inspect "$APP_IMAGE" --format '{{index .RepoDigests 0}}')
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
权限：Zone / DNS / Edit + Zone / Zone / Read；区域只选你的主域名。
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
apply_firewall() {
  local ranges=$ROOT/cloudflare-v4.txt cidr
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
  numbers=$(LC_ALL=C ufw status numbered | sed -nE 's/^\[[[:space:]]*([0-9]+)\][[:space:]]+80,443\/tcp[[:space:]]+ALLOW IN[[:space:]]+.*[[:space:]]#[[:space:]]mmwx-cf[[:space:]]*$/\1/p' | sort -rn)
  while IFS= read -r number; do
    [[ -n $number ]] || continue
    ufw --force delete "$number" >/dev/null
  done <<<"$numbers"
}
sync_cf() {
  exec 8>/run/mmwx-cf.lock; flock -n 8 || exit 0
  local old=$ROOT/cloudflare-v4.txt new=$ROOT/cloudflare-v4.new
  fetch_cf "$new" || { printf 'Cloudflare IP 更新失败，保留现有规则。\n' >&2; return 1; }
  mv "$new" "$old"
  apply_firewall
  remove_legacy_cf_rules
  if [[ -f $ROOT/state.json ]]; then
    DOMAIN=$(jq -er .domain "$ROOT/state.json")
    render_caddy > "$ROOT/Caddyfile.next"
    # Keep the inode: Caddy mounts this individual file.
    cat "$ROOT/Caddyfile.next" > "$ROOT/Caddyfile"
    rm -f "$ROOT/Caddyfile.next"
    if [[ -n $(dc ps --status running -q caddy) ]]; then dc exec -T caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null; fi
  fi
}
network_setup() {
  local port
  if [[ -f $ROOT/network-backup/state ]]; then
    if [[ $(cat "$ROOT/network-backup/state") == confirmed ]]; then
      network_is_ready || die '已确认的网络设置发生变化，请检查 UFW/IPv6 后继续。'
      apply_firewall
      remove_legacy_cf_rules
      return
    fi
    if [[ $(cat "$ROOT/network-backup/state") == pending ]]; then
      systemctl stop mmwx-network-rollback.timer 2>/dev/null || true
      /bin/bash "$ROOT/network-backup/rollback.sh"
    fi
    systemctl stop mmwx-network-rollback.timer mmwx-network-rollback.service 2>/dev/null || true
    systemctl reset-failed mmwx-network-rollback.service 2>/dev/null || true
  fi
  SSH_PORTS=$(ss -H -lntp | awk '/sshd/ {n=split($4,a,":"); print a[n]}' | sort -nu)
  [[ -n $SSH_PORTS ]] || die '无法识别 sshd 监听端口，停止网络修改。'
  install -d "$ROOT/network-backup"
  if [[ ! -f $ROOT/network-backup/ufw-status ]]; then
    cp -a /etc/ufw "$ROOT/network-backup/ufw"
    cp -a /etc/default/ufw "$ROOT/network-backup/ufw-default"
    for port in all default lo; do sysctl -n "net.ipv6.conf.$port.disable_ipv6" > "$ROOT/network-backup/ipv6-$port"; done
    ufw status | head -1 > "$ROOT/network-backup/ufw-status"
  fi
  fetch_cf "$ROOT/cloudflare-v4.txt" || die 'Cloudflare IP 列表获取失败。'
  install_units
  for port in $SSH_PORTS; do ufw allow "$port/tcp" comment mmwx-ssh; done
  # Schedule recovery before changing networking; cancelled only after operator acknowledgement.
  cat > "$ROOT/network-backup/rollback.sh" <<'EOF'
#!/bin/bash
set -eu
root=/opt/mmwx-installer
exec 9>/run/mmwx-network.lock
flock 9
test "$(cat "$root/network-backup/state")" != confirmed || exit 0
printf 'rolled-back\n' > "$root/network-backup/state"
ufw disable
cp -a "$root/network-backup/ufw/." /etc/ufw/
cp -a "$root/network-backup/ufw-default" /etc/default/ufw
rm -f /etc/sysctl.d/90-mmwx-ipv4-only.conf
for interface in all default lo; do sysctl -w "net.ipv6.conf.$interface.disable_ipv6=$(cat "$root/network-backup/ipv6-$interface")"; done
if grep -qx 'Status: active' "$root/network-backup/ufw-status"; then ufw --force enable; fi
EOF
  chmod 700 "$ROOT/network-backup/rollback.sh"
  printf 'pending\n' > "$ROOT/network-backup/state"
  systemd-run --collect --unit=mmwx-network-rollback --on-active=5m /bin/bash "$ROOT/network-backup/rollback.sh"
  cat > /etc/sysctl.d/90-mmwx-ipv4-only.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF
  sysctl -p /etc/sysctl.d/90-mmwx-ipv4-only.conf
  sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw
  ufw default deny incoming
  ufw default allow outgoing
  ufw --force enable
  apply_firewall
  remove_legacy_cf_rules
  info '请另开终端，通过 IPv4 重新 SSH 登录；5 分钟未确认将恢复网络。'
  if [[ $ACCEPT == 0 ]]; then
    confirm '新 SSH 已登录成功？' || die '未确认，等待网络回退；稍后用 mmwx 继续。'
    confirm_network
  else
    info '新终端运行 mmwx，在菜单中确认 SSH。'
    local attempt
    for ((attempt=0; attempt<56; attempt++)); do
      [[ $(cat "$ROOT/network-backup/state") == confirmed ]] && break
      [[ $(cat "$ROOT/network-backup/state") != rolled-back ]] || die '网络已自动恢复，安装停止。'
      sleep 5
    done
    [[ $(cat "$ROOT/network-backup/state") == confirmed ]] || die '未在期限内确认新 SSH，安装停止并等待网络回退。'
  fi
}
network_is_ready() {
  [[ $(sysctl -n net.ipv6.conf.all.disable_ipv6) == 1 ]] &&
    grep -qx 'IPV6=no' /etc/default/ufw && ufw status | grep -qx 'Status: active'
}
confirm_network() {
  exec 9>/run/mmwx-network.lock; flock 9
  [[ -f $ROOT/network-backup/state && $(cat "$ROOT/network-backup/state") == pending ]] || die '没有待确认的网络变更，或网络已回退。'
  systemctl is-active --quiet mmwx-network-rollback.timer || die '网络确认期限已过。'
  [[ ${SSH_CONNECTION:-} != *:* ]] || die '请通过 IPv4 SSH 确认。'
  network_is_ready || die '网络状态不符合预期，请等待回退。'
  printf 'confirmed\n' > "$ROOT/network-backup/state"
  systemctl stop mmwx-network-rollback.timer
  systemctl reset-failed mmwx-network-rollback.service 2>/dev/null || true
  flock -u 9
  info '已确认 SSH，取消网络自动回退。'
}
install_command() {
  if [[ $SELF != /usr/local/sbin/mmwx-installer ]]; then install -m 0700 "$SELF" /usr/local/sbin/mmwx-installer; fi
  if [[ -e /usr/local/bin/mmwx || -L /usr/local/bin/mmwx ]]; then
    [[ $(readlink -f /usr/local/bin/mmwx) == /usr/local/sbin/mmwx-installer ]] || die '已有 mmwx 命令，未覆盖。'
  else ln -s /usr/local/sbin/mmwx-installer /usr/local/bin/mmwx; fi
}
install_units() {
  install_command
  install -d /etc/systemd/system/docker.service.d
  cat > /etc/systemd/system/docker.service.d/mmwx-firewall.conf <<'EOF'
[Service]
ExecStartPre=/usr/local/sbin/mmwx-installer firewall-apply
EOF
  cat > /etc/systemd/system/mmwx-firewall.service <<'EOF'
[Unit]
Description=MMWX Cloudflare container firewall
After=docker.service ufw.service
PartOf=docker.service ufw.service
Before=mmwx-stack.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mmwx-installer firewall-apply
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
ExecStart=/usr/local/sbin/mmwx-installer firewall-sync
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
  systemctl enable mmwx-firewall.service
  systemctl enable --now mmwx-cf-sync.timer
}
save_state() {
  jq -n --arg domain "$DOMAIN" --arg channel "$CHANNEL" --arg version "$VERSION" --arg app "$APP_IMAGE" --arg caddy "$CADDY_IMAGE" --arg pg "$PG_IMAGE" '{domain:$domain,channel:$channel,version:$version,app:$app,caddy:$caddy,pg:$pg}' > "$ROOT/state.json.tmp"
  mv "$ROOT/state.json.tmp" "$ROOT/state.json"
}
verify_https() {
  local attempt
  info '等待 Caddy 完成 DNS-01 签发并验证 HTTPS（最多五分钟）……'
  for ((attempt=0; attempt<60; attempt++)); do
    if curl -fsS --noproxy '*' --max-time 5 --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/" -o /dev/null 2>/dev/null; then
      if curl -fsSL --max-redirs 3 --max-time 15 "https://$DOMAIN/" -o /dev/null; then return 0; fi
    fi
    sleep 5
  done
  die '容器已启动，但 HTTPS 验证未通过。检查 Caddy 日志、Token、Cloudflare Full (strict) 和安全组，不能视为安装成功。'
}
load_state() {
  [[ -f $ROOT/state.json ]] || die '未发现本安装器的安装记录。'
  DOMAIN=$(jq -er .domain "$ROOT/state.json")
  CHANNEL=${CHANNEL:-$(jq -er .channel "$ROOT/state.json")}
  VERSION=$(jq -er .version "$ROOT/state.json")
  APP_IMAGE=$(jq -er .app "$ROOT/state.json")
  CADDY_IMAGE=$(jq -er .caddy "$ROOT/state.json")
  PG_IMAGE=$(jq -er .pg "$ROOT/state.json")
}
checkpoint() {
  STAGE=$1
  jq -n --argjson stage "$STAGE" --arg domain "$DOMAIN" --arg channel "$CHANNEL" --arg version "$VERSION" --arg app "$APP_IMAGE" --arg caddy "$CADDY_IMAGE" --arg pg "$PG_IMAGE" '{stage:$stage,domain:$domain,channel:$channel,version:$version,app:$app,caddy:$caddy,pg:$pg}' > "$ROOT/progress.json.tmp"
  mv "$ROOT/progress.json.tmp" "$ROOT/progress.json"
}
load_progress() {
  jq -e '.stage|type=="number" and .>=0 and .<=7' "$ROOT/progress.json" >/dev/null || die '安装进度异常。'
  STAGE=$(jq -r .stage "$ROOT/progress.json")
  DOMAIN=$(jq -r '.domain // ""' "$ROOT/progress.json")
  CHANNEL=$(jq -r '.channel // ""' "$ROOT/progress.json")
  VERSION=$(jq -r '.version // ""' "$ROOT/progress.json")
  APP_IMAGE=$(jq -r '.app // ""' "$ROOT/progress.json")
  CADDY_IMAGE=$(jq -r '.caddy // ""' "$ROOT/progress.json")
  PG_IMAGE=$(jq -r '.pg // "postgres:18-alpine"' "$ROOT/progress.json")
}
prepare_secrets() {
  local password
  if [[ -f $ROOT/postgres.env ]]; then
    password=$(sed -n 's/^POSTGRES_PASSWORD=//p' "$ROOT/postgres.env")
    [[ $password =~ ^[a-f0-9]{64}$ ]] || die '数据库密码文件格式异常，未覆盖。'
  else
    [[ ! -d $ROOT/postgres-data ]] || die '存在数据库数据但密码文件丢失，停止操作。'
    password=$(openssl rand -hex 32)
    printf 'POSTGRES_PASSWORD=%s\n' "$password" > "$ROOT/postgres.env.tmp"
    mv "$ROOT/postgres.env.tmp" "$ROOT/postgres.env"
  fi
  printf 'MMWX_DATABASE_PASSWORD=%s\n' "$password" > "$ROOT/app.env.tmp"
  mv "$ROOT/app.env.tmp" "$ROOT/app.env"
  if [[ ! -f $ROOT/caddy.env ]]; then
    [[ -f $ROOT/cloudflare.token ]] || die '缺少 Token，请重新提供。'
    printf 'CF_API_TOKEN=%s\n' "$(cat "$ROOT/cloudflare.token")" > "$ROOT/caddy.env.tmp"
    mv "$ROOT/caddy.env.tmp" "$ROOT/caddy.env"
  fi
}
install_stack() {
  preflight
  [[ ! -f $ROOT/update.json ]] || die '有未完成的更新，请选择「继续任务 / 恢复服务」。'
  if [[ -f $ROOT/progress.json ]]; then
    load_progress
    [[ $STAGE -lt 7 ]] || die '已安装，请在菜单选择更新或恢复服务。'
    info "继续安装（阶段 $STAGE/7）"
  elif [[ -f $ROOT/state.json ]]; then
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
    if [[ -z $TOKEN_FILE && -f $ROOT/cloudflare.token ]]; then TOKEN_FILE=$ROOT/cloudflare.token; fi
    if [[ -z $TOKEN_FILE ]]; then
      token_guide
      TOKEN_FILE=$(mktemp); TEMP_TOKEN=$TOKEN_FILE
      local token
      read -r -s -p 'Cloudflare Token：' token </dev/tty; printf '\n'
      printf '%s' "$token" > "$TOKEN_FILE"
    fi
    dns_check
    printf '%s' "$CF_TOKEN" > "$ROOT/cloudflare.token.tmp"
    mv "$ROOT/cloudflare.token.tmp" "$ROOT/cloudflare.token"
    unset CF_TOKEN
    checkpoint 2
  fi
  install_docker
  if ((STAGE<3)); then choose_version; checkpoint 3; fi
  if ((STAGE<4)); then
    build_caddy
    docker pull "$PG_IMAGE"
    PG_IMAGE=$(docker image inspect "$PG_IMAGE" --format '{{index .RepoDigests 0}}')
    checkpoint 4
  fi
  if ((STAGE<5)); then
    prepare_secrets
    render_compose > "$ROOT/compose.yaml.tmp"
    mv "$ROOT/compose.yaml.tmp" "$ROOT/compose.yaml"
    render_caddy > "$ROOT/Caddyfile"
    dc config --quiet
    checkpoint 5
  fi
  network_setup
  render_caddy > "$ROOT/Caddyfile"
  save_state
  checkpoint 6
  dc up -d --wait --wait-timeout 300
  verify_https
  checkpoint 7
  printf '\n安装完成：https://%s\n管理菜单：mmwx\n数据库由环境变量管理，无需勾选「使用 PG 数据库」。\n' "$DOMAIN"
}
write_update_progress() {
  jq -n --arg phase "$1" --arg backup "$2" '{phase:$phase,backup:$backup}' > "$ROOT/update.json.tmp"
  mv "$ROOT/update.json.tmp" "$ROOT/update.json"
}
recover_update() {
  local backup phase directory
  backup=$(jq -er .backup "$ROOT/update.json")
  phase=$(jq -er .phase "$ROOT/update.json")
  [[ $backup == "$ROOT/backups/"* && ${backup#"$ROOT/backups/"} != */* && -d $backup ]] || die '更新备份路径异常。'
  [[ -f $backup/compose.yaml && -f $backup/state.json ]] || die '更新恢复文件缺失。'
  case "$phase" in
    backing-up) ;; # No new version has started; existing data is still authoritative.
    deploying|restoring)
      [[ -s $backup/database.dump && -s $backup/files.tar.gz ]] || die '更新备份不完整，停止恢复。'
      write_update_progress restoring "$backup"
      dc stop mmwx caddy
      dc up -d --wait --wait-timeout 120 postgres
      dc exec -T postgres dropdb -U mmwx --if-exists --force mmwx
      dc exec -T postgres createdb -U mmwx -O mmwx mmwx
      dc exec -T postgres pg_restore -U mmwx -d mmwx --exit-on-error < "$backup/database.dump"
      mkdir -p "$backup/restored"
      tar -xzf "$backup/files.tar.gz" -C "$backup/restored"
      for directory in data subscribes rule_templates; do
        if [[ -d $ROOT/$directory && ! -e $backup/failed-$directory ]]; then
          mv "$ROOT/$directory" "$backup/failed-$directory"
        fi
        # Fixed project-owned directories only; retry starts from the same snapshot.
        rm -rf "${ROOT:?}/$directory"
        cp -a "$backup/restored/$directory" "$ROOT/$directory"
      done
      ;;
    *) die '未知更新阶段。';;
  esac
  cp "$backup/compose.yaml" "$ROOT/compose.yaml"
  cp "$backup/state.json" "$ROOT/state.json"
  dc up -d --wait --wait-timeout 300
  rm -f "$ROOT/update.json"
  info "已恢复更新前的版本。备份：$backup"
}
update_stack() {
  preflight
  install_command
  if [[ -f $ROOT/update.json ]]; then recover_update; return; fi
  [[ ! -f $ROOT/image-rollback.json ]] || die '请先继续未完成的版本回退。'
  [[ ! -f $ROOT/progress.json ]] || [[ $(jq -r .stage "$ROOT/progress.json") == 7 ]] || die '请先继续完成安装。'
  load_state
  configure_timezone
  local backup
  choose_version
  mkdir -p "$ROOT/backups"
  backup=$(mktemp -d "$ROOT/backups/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
  cp "$ROOT/compose.yaml" "$ROOT/state.json" "$backup/"
  write_update_progress backing-up "$backup"
  dc stop mmwx caddy
  if ! dc exec -T postgres pg_dump -U mmwx -d mmwx -Fc > "$backup/database.dump"; then
    dc start mmwx caddy; rm -f "$ROOT/update.json"; die '数据库备份失败，已重新启动旧版本。'
  fi
  if ! tar -czf "$backup/files.tar.gz" -C "$ROOT" data subscribes rule_templates; then
    dc start mmwx caddy; rm -f "$ROOT/update.json"; die '文件备份失败，已重新启动旧版本。'
  fi
  write_update_progress deploying "$backup"
  render_compose > "$ROOT/compose.yaml.tmp"
  mv "$ROOT/compose.yaml.tmp" "$ROOT/compose.yaml"
  if dc up -d --wait --wait-timeout 300; then
    save_state
    rm -f "$ROOT/update.json"
    sync_cf; info "更新完成：$VERSION。备份：$backup"
  else
    recover_update
    die '新版本健康检查失败，已恢复旧版本和数据库。'
  fi
}
self_update() {
  local downloaded staged
  downloaded=$(mktemp)
  if ! get https://raw.githubusercontent.com/xiangwan6667/mmwx-installer/main/install.sh -o "$downloaded"; then
    rm -f "$downloaded"; die '下载失败，保留当前管理脚本。'
  fi
  if ! head -1 "$downloaded" | grep -qx '#!/usr/bin/env bash' || ! bash -n "$downloaded" || ! grep -q '^self_update() {' "$downloaded"; then
    rm -f "$downloaded"; die '管理脚本校验失败，保留当前版本。'
  fi
  if [[ -e /usr/local/bin/mmwx || -L /usr/local/bin/mmwx ]]; then
    [[ $(readlink -f /usr/local/bin/mmwx) == /usr/local/sbin/mmwx-installer ]] || { rm -f "$downloaded"; die '已有其他 mmwx 命令。'; }
  fi
  staged=$(mktemp /usr/local/sbin/.mmwx-installer.XXXXXX)
  install -m 0700 "$downloaded" "$staged"
  rm -f "$downloaded"
  mv -f "$staged" /usr/local/sbin/mmwx-installer
  [[ -L /usr/local/bin/mmwx ]] || ln -s /usr/local/sbin/mmwx-installer /usr/local/bin/mmwx
  info '管理脚本已更新。'
}
finish_image_rollback() {
  load_state
  VERSION=$(jq -er .version "$ROOT/image-rollback.json")
  APP_IMAGE=$(jq -er .app "$ROOT/image-rollback.json")
  CHANNEL=$(jq -er .channel "$ROOT/image-rollback.json")
  docker pull "$APP_IMAGE"
  render_compose > "$ROOT/compose.yaml.tmp"
  mv "$ROOT/compose.yaml.tmp" "$ROOT/compose.yaml"
  # Only recreate the controller. PostgreSQL, Caddy and all persisted data stay in place.
  dc up -d --no-deps --wait --wait-timeout 300 mmwx
  save_state
  rm -f "$ROOT/image-rollback.json"
  info "主控已切换至 $VERSION，数据库和文件未还原。"
}
rollback_stack() {
  preflight; load_state
  [[ ! -f $ROOT/update.json ]] || die '请先恢复未完成的更新。'
  if [[ -f $ROOT/image-rollback.json ]]; then finish_image_rollback; return; fi
  local snapshot version number index=0
  local -a choices=()
  while IFS= read -r snapshot; do
    version=$(jq -er .version "$snapshot") || continue
    [[ $(jq -r .app "$snapshot") != "$APP_IMAGE" ]] || continue
    choices+=("$snapshot")
    index=$((index+1))
    printf '%s. %s (%s)\n' "$index" "$version" "$(basename "$(dirname "$snapshot")")"
    [[ $index -lt 5 ]] || break
  done < <(find "$ROOT/backups" -mindepth 2 -maxdepth 2 -name state.json -type f 2>/dev/null | sort -r)
  [[ $index -gt 0 ]] || die '暂无历史版本。可在更新中选择近期版本。'
  number=$(ask '回退版本编号：')
  [[ $number =~ ^[1-5]$ && $number -le $index ]] || die '无效编号。'
  snapshot=${choices[$((number-1))]}
  confirm '只回退主控版本，保留当前数据；旧版本可能不兼容当前数据库。继续？' || return 0
  jq '{version,app,channel}' "$snapshot" > "$ROOT/image-rollback.json.tmp"
  mv "$ROOT/image-rollback.json.tmp" "$ROOT/image-rollback.json"
  finish_image_rollback
}
remove_services() {
  if [[ -f $ROOT/compose.yaml ]]; then dc down; fi
  systemctl stop mmwx-network-rollback.timer mmwx-network-rollback.service 2>/dev/null || true
  if [[ -f $ROOT/network-backup/state && $(cat "$ROOT/network-backup/state") == pending ]]; then
    /bin/bash "$ROOT/network-backup/rollback.sh"
  fi
  systemctl disable --now mmwx-cf-sync.timer mmwx-firewall.service
  rm -f /etc/systemd/system/docker.service.d/mmwx-firewall.conf
  while iptables -C DOCKER-USER -o br-mmwx-front -j MMWX-CF 2>/dev/null; do iptables -D DOCKER-USER -o br-mmwx-front -j MMWX-CF; done
  if iptables -nL MMWX-CF >/dev/null 2>&1; then iptables -F MMWX-CF; iptables -X MMWX-CF; fi
  ipset destroy mmwx_cf 2>/dev/null || true
  remove_legacy_cf_rules
  rm -f /etc/systemd/system/mmwx-firewall.service /etc/systemd/system/mmwx-cf-sync.{service,timer}
  systemctl daemon-reload
}
purge_installation() {
  [[ $ROOT == /opt/mmwx-installer && ! -L $ROOT && $(readlink -f "$ROOT") == /opt/mmwx-installer ]] || die '安装目录异常，停止删除。'
  # A fixed project directory; never follow mounted filesystems during deletion.
  rm -rf --one-file-system -- "$ROOT"
  if [[ -L /usr/local/bin/mmwx && $(readlink /usr/local/bin/mmwx) == /usr/local/sbin/mmwx-installer ]]; then rm -f /usr/local/bin/mmwx; fi
  rm -f /usr/local/sbin/mmwx-installer
  if command -v docker >/dev/null; then
    docker image rm mmwx-installer-caddy:2.11.4-cf0.2.4 >/dev/null 2>&1 || true
  fi
}
uninstall_stack() {
  [[ -d $ROOT ]] || die '未发现安装目录。'
  [[ ! -f $ROOT/update.json ]] || die '请先恢复未完成的更新。'
  [[ ! -f $ROOT/image-rollback.json ]] || die '请先继续未完成的版本回退。'
  local mode
  printf '1. 卸载并保留数据（默认）\n2. 完全卸载（删除数据、备份和 Token）\n'
  mode=$(ask '选择 [1]：')
  case "$mode" in
    ''|1) mode=keep; confirm '卸载服务并保留数据？' || return 0;;
    2) mode=purge; confirm "完全卸载并永久删除 $ROOT 中的数据、备份和 Token？" || return 0;;
    *) die '无效选择。';;
  esac
  remove_services
  if [[ $mode == purge ]]; then
    purge_installation
    info '已完全卸载本项目。Docker、系统网络/时区设置及 Cloudflare DNS 记录保留。'
  else
    info "已卸载容器，数据保留于 $ROOT。运行 mmwx 选择恢复服务。"
  fi
}
usage() {
  cat <<'EOF'
用法：mmwx（管理菜单）或 sudo bash install.sh [install|update|uninstall|status|logs|resume|check]
  --prefix mmwx              子域名前缀（交互输入回车默认 mmwx）
  --zone example.com         Token 授权多个主域名时指定主域名
  --domain panel.example.com  兼容完整域名参数
  --channel stable|beta       安装或更新的发布通道
  --cf-token-file /root/token root 所有、600 权限的 Token 文件
  --yes                      接受全新环境提示；必须五分钟内另开 SSH 执行 confirm-network
安装需确认新 SSH 连接；check 只检查环境，不修改系统。
EOF
}
resume_task() {
  install_command
  if [[ -f $ROOT/update.json ]]; then
    preflight; recover_update
  elif [[ -f $ROOT/image-rollback.json ]]; then
    preflight; finish_image_rollback
  elif [[ -f $ROOT/progress.json ]] && [[ $(jq -r .stage "$ROOT/progress.json") -lt 7 ]]; then
    install_stack
  else
    [[ -f $ROOT/state.json ]] || die '没有可恢复的任务，请从菜单选择安装。'
    preflight; load_state; install_units; network_is_ready || die '请检查 UFW/IPv6 配置后恢复。'
    configure_timezone
    render_compose > "$ROOT/compose.yaml.tmp"
    mv "$ROOT/compose.yaml.tmp" "$ROOT/compose.yaml"
    dc config --quiet
    sync_cf; dc up -d --wait --wait-timeout 300; verify_https
    info "已恢复：https://$DOMAIN"
  fi
}
menu() {
  local choice action
  local -a arguments=()
  [[ -z $TOKEN_FILE ]] || arguments+=(--cf-token-file "$TOKEN_FILE")
  [[ -z $DOMAIN ]] || arguments+=(--domain "$DOMAIN")
  [[ -z $PREFIX ]] || arguments+=(--prefix "$PREFIX")
  [[ -z $ZONE_NAME ]] || arguments+=(--zone "$ZONE_NAME")
  [[ -z $CHANNEL ]] || arguments+=(--channel "$CHANNEL")
  while true; do
    printf '\n妙妙屋 X\n1. 安装 / 继续安装\n2. 更新版本\n3. 状态\n4. 日志\n5. 继续任务 / 恢复服务\n6. 卸载\n7. 确认新 SSH 连接\n8. 更新管理脚本\n9. 回退主控版本\n0. 退出\n'
    choice=$(ask '选择：')
    case "$choice" in
      1) action=install;; 2) action=update;; 3) action=status;; 4) action=logs;;
      5) action=resume;; 6) action=uninstall;;
      7) confirm '已通过 IPv4 重新登录成功？' || continue; action=confirm-network;;
      8) action=self-update;; 9) action=rollback;;
      0) return 0;; *) printf '无效选择。\n'; continue;;
    esac
    if /bin/bash "$SELF" "$action" "${arguments[@]}"; then
      if [[ $action == self-update ]]; then exec /bin/bash /usr/local/sbin/mmwx-installer; fi
    else info '操作未完成，可从菜单重试。'; fi
    [[ -f $SELF ]] || return 0
  done
}
main() {
  while (($#)); do
    case "$1" in
      install|update|uninstall|status|logs|resume|check|self-update|rollback|firewall-apply|firewall-sync|confirm-network) ACTION=$1; shift;;
      --yes) ACCEPT=1; shift;;
      --domain|--prefix|--zone|--channel|--cf-token-file)
        [[ $# -ge 2 ]] || die "缺少参数：$1"
        case "$1" in --domain) DOMAIN=$2;; --prefix) PREFIX=$2;; --zone) ZONE_NAME=$2;; --channel) CHANNEL=$2; CHANNEL_EXPLICIT=1;; --cf-token-file) TOKEN_FILE=$2;; esac; shift 2;;
      -h|--help) usage; return;; *) die "未知参数：$1";;
    esac
  done
  [[ $EUID == 0 ]] || die '请用 sudo / root 运行。'
  if [[ -z $ACTION ]]; then menu; return; fi
  case "$ACTION" in install|update|uninstall|resume|self-update|rollback) exec 7>/run/mmwx-installer.lock; flock -n 7 || die '另一个安装或维护进程正在运行，请等待。';; esac
  if [[ $ACTION == install && ! -f $ROOT/progress.json ]]; then
    printf '\033[1;31m仅限全新环境：启用 UFW、禁用 IPv6；请用 IPv4 SSH。\033[0m\n'
    if [[ $ACCEPT == 0 ]]; then confirm '开始安装？' || return 0; fi
  fi
  case "$ACTION" in
    firewall-apply) exec 8>/run/mmwx-cf.lock; flock 8; apply_firewall;; firewall-sync) sync_cf;; confirm-network) confirm_network;;
    check) preflight; info '环境预检通过。';;
    install) install_stack;; update) update_stack;; uninstall) uninstall_stack;;
    self-update) self_update;; rollback) rollback_stack;;
    status) load_state; dc ps; ufw status;; logs) load_state; dc logs --tail 80 caddy mmwx;;
    resume) resume_task;;
  esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  trap '[[ -z $TEMP_TOKEN ]] || rm -f "$TEMP_TOKEN"' EXIT
  trap 'printf "操作未完成，可运行 mmwx 继续（第 %s 行）。\n" "$LINENO" >&2' ERR
  trap 'printf "\n已中断，运行 mmwx 继续。\n"; exit 130' INT TERM
  main "$@"
fi
