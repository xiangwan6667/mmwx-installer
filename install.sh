#!/usr/bin/env bash
# Independent installer. Never invoke the upstream install script.
set -Eeuo pipefail
umask 077
ROOT=/opt/mmwx-installer
UPSTREAM=iluobei/miaomiaowuX
CHANNEL='' DOMAIN='' TOKEN_FILE='' ACTION='' ACCEPT=0 TEMP_TOKEN='' CHANNEL_EXPLICIT=0
APP_IMAGE='' CADDY_IMAGE='' PG_IMAGE=postgres:18-alpine
SELF=$(readlink -f "${BASH_SOURCE[0]}")

info() { printf '\033[36m%s\033[0m\n' "$*"; }
die() { printf '\033[31m错误：%s\033[0m\n' "$*" >&2; exit 1; }
ask() { local value; read -r -p "$1" value </dev/tty || die '无法读取终端，请下载脚本后运行。'; printf '%s' "$value"; }
get() { curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 15 --max-time 90 --retry 2 "$@"; }
dc() { docker compose --project-name mmwx-installer --project-directory "$ROOT" -f "$ROOT/compose.yaml" "$@"; }
valid_domain() {
  [[ $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ && ${#1} -le 253 ]]
}
select_release() {
  jq -ce --arg channel "$1" '[.[] | select(.draft == false and (.prerelease == ($channel == "beta"))) | select(.published_at != null)] | sort_by(.published_at) | last | select(. != null)'
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
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./caddy-data:/data
      - ./caddy-config:/config
    networks: [frontend]
    depends_on:
      mmwx: {condition: service_healthy}
  mmwx:
    image: $APP_IMAGE
    restart: unless-stopped
    env_file: [app.env]
    environment:
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
    environment: {POSTGRES_DB: mmwx, POSTGRES_USER: mmwx}
    volumes: ["./postgres-data:/var/lib/postgresql"]
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
    if [[ ! -f $ROOT/state.json ]] && [[ -n $(docker ps -aq) ]]; then die '发现已有容器，停止安装。'; fi
  fi
  if [[ ! -f $ROOT/state.json ]]; then
    for service in nginx caddy apache2 httpd mmwx postgresql; do
      if systemctl list-unit-files --no-legend "$service.service" 2>/dev/null | grep -q "^$service.service"; then
        die "发现已有服务 $service，请使用全新环境。"
      fi
    done
    [[ -z $(ss -H -lnt '( sport = :80 or sport = :443 )') ]] || die '80 或 443 已被占用。'
    for path in /etc/mmwx /opt/miaomiaowux /usr/local/bin/mmwx; do [[ ! -e $path ]] || die "发现已有安装：$path"; done
    [[ ! -e $ROOT/compose.yaml ]] || die "发现未完成安装，保留现场：$ROOT。请先检查日志。"
  fi
}
dependencies() {
  info '安装基础依赖……'
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl jq python3 ufw ipset openssl >/dev/null
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
  local pages='[]' page result selected
  for page in $(seq 1 20); do
    result=$(get "https://api.github.com/repos/$UPSTREAM/releases?per_page=100&page=$page") || die 'GitHub 版本查询失败，请稍后重试。'
    jq -e 'type == "array"' <<<"$result" >/dev/null || die 'GitHub 返回异常。'
    pages=$(jq -cs '.[0]+.[1]' <(printf '%s' "$pages") <(printf '%s' "$result"))
    [[ $(jq length <<<"$result") -eq 100 ]] || break
  done
  info '官方可用版本（按发布时间选择）：'
  for mode in stable beta; do
    selected=$(select_release "$mode" <<<"$pages") || selected=null
    jq -r --arg mode "$mode" 'if . == null then "\($mode)：暂无可用版本" else "\($mode)：\(.tag_name)  发布时间：\(.published_at)" end' <<<"$selected"
  done
  if [[ -z $CHANNEL || ( $ACTION == update && $CHANNEL_EXPLICIT == 0 && $ACCEPT == 0 ) ]]; then
    local choice
    choice=$(ask "选择 1=正式版（推荐）/ 2=Beta [回车沿用 ${CHANNEL:-stable}]：")
    case "$choice" in '') CHANNEL=${CHANNEL:-stable};; 1) CHANNEL=stable;; 2) CHANNEL=beta;; *) die '无效选择。';; esac
  fi
  [[ $CHANNEL == stable || $CHANNEL == beta ]] || die 'channel 只能是 stable 或 beta。'
  selected=$(select_release "$CHANNEL" <<<"$pages") || die "没有可用的 $CHANNEL 版本。"
  VERSION=$(jq -r .tag_name <<<"$selected")
  [[ $VERSION =~ ^v?[0-9][A-Za-z0-9._-]*$ ]] || die '上游版本号格式异常。'
  APP_IMAGE="ghcr.io/iluobei/miaomiaowux:${VERSION#v}"
  info "选择 $VERSION；检查对应镜像……"
  docker pull "$APP_IMAGE" || die "镜像尚未发布或下载失败：$APP_IMAGE。不会改用 latest。"
  APP_IMAGE=$(docker image inspect "$APP_IMAGE" --format '{{index .RepoDigests 0}}')
}
dns_check() {
  valid_domain "$DOMAIN" || die '请输入小写完整域名，例如 cs.example.com，不带 https://、路径或通配符。'
  [[ -f $TOKEN_FILE && ! -L $TOKEN_FILE ]] || die 'Token 文件不存在或为符号链接。'
  [[ $(stat -c %u "$TOKEN_FILE") == 0 && $(stat -c %a "$TOKEN_FILE") == 600 ]] || die 'Token 文件必须属于 root，权限为 600。'
  local token headers zone records ipv4 operation payload response
  token=$(cat "$TOKEN_FILE")
  [[ $token =~ ^[A-Za-z0-9_.-]{20,256}$ ]] || die 'Token 格式异常，请检查是否误复制了空格或引号。'
  headers=$(mktemp); printf 'Authorization: Bearer %s\n' "$token" > "$headers"
  zone=$(get -H "@$headers" 'https://api.cloudflare.com/client/v4/zones?status=active&per_page=50' | jq -er --arg domain "$DOMAIN" '[.result[] | .name as $zone | select($domain == $zone or ($domain | endswith("."+$zone)))] | sort_by(.name|length) | last.id // empty') || { rm -f "$headers"; die '无法读取域名区域，请检查 Zone Read 权限和区域授权。'; }
  records=$(get -H "@$headers" "https://api.cloudflare.com/client/v4/zones/$zone/dns_records?name=$DOMAIN") || { rm -f "$headers"; die 'DNS 查询失败。'; }
  ipv4=$(get https://api4.ipify.org)
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
准备工作：
1. 先把主域名托管到 Cloudflare：https://dash.cloudflare.com/ → 添加域名。
   在购买域名的注册商处，把 NS 改为 Cloudflare 指定的两条服务器地址。
   等待 Cloudflare 显示 Active（有效）后再继续；只添加站点但不改 NS 不算托管完成。
   本脚本会用 API 自动创建面板子域名的 A 记录并开启小黄云，无需手动创建。
2. SSL/TLS → 概述 → 选择「完全（严格）」。本安装器会禁用服务器 IPv6。
3. https://dash.cloudflare.com/profile/api-tokens → 创建令牌 → 自定义令牌。
   权限：Zone / DNS / Edit，以及 Zone / Zone / Read。
   区域资源：Include / Specific zone / 仅选择你的域名。不要使用 Global API Key。
4. Token 只用于 DNS-01 签发与续期。不要撤销它，也不要把它发到聊天或提交 GitHub。
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
sync_cf() {
  exec 8>/run/mmwx-cf.lock; flock -n 8 || exit 0
  local old=$ROOT/cloudflare-v4.txt new=$ROOT/cloudflare-v4.new cidr
  fetch_cf "$new" || { printf 'Cloudflare IP 更新失败，保留现有规则。\n' >&2; return 1; }
  # Add new permits first, then remove only rules previously owned by this project.
  while IFS= read -r cidr; do ufw allow from "$cidr" to any port 80,443 proto tcp comment mmwx-cf >/dev/null; done < "$new"
  if [[ -f $old ]]; then
    while IFS= read -r cidr; do
      grep -Fxq "$cidr" "$new" || ufw delete allow from "$cidr" to any port 80,443 proto tcp >/dev/null
    done < "$old"
  fi
  mv "$new" "$old"
  apply_firewall
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
  SSH_PORTS=$(ss -H -lntp | awk '/sshd/ {n=split($4,a,":"); print a[n]}' | sort -nu)
  [[ -n $SSH_PORTS ]] || die '无法识别 sshd 监听端口，停止网络修改。'
  install -d "$ROOT/network-backup"
  cp -a /etc/ufw "$ROOT/network-backup/ufw"
  cp -a /etc/default/ufw "$ROOT/network-backup/ufw-default"
  ufw status | head -1 > "$ROOT/network-backup/ufw-status"
  for port in all default lo; do sysctl -n "net.ipv6.conf.$port.disable_ipv6" > "$ROOT/network-backup/ipv6-$port"; done
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
  systemd-run --unit=mmwx-network-rollback --on-active=5m /bin/bash "$ROOT/network-backup/rollback.sh"
  cat > /etc/sysctl.d/90-mmwx-ipv4-only.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF
  sysctl -p /etc/sysctl.d/90-mmwx-ipv4-only.conf
  sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw
  ufw default deny incoming
  ufw default allow outgoing
  while IFS= read -r port; do ufw allow from "$port" to any port 80,443 proto tcp comment mmwx-cf; done < "$ROOT/cloudflare-v4.txt"
  ufw --force enable
  apply_firewall
  info '请另开终端，通过 IPv4 重新 SSH 登录。五分钟内执行 sudo mmwx-installer confirm-network，否则恢复原网络配置。'
  if [[ $ACCEPT == 0 ]]; then
    [[ $(ask '确认新 SSH 已连接成功后，输入 SSH_OK：') == SSH_OK ]] || die '未确认 SSH，等待自动恢复网络。'
    confirm_network
  else
    local attempt
    for ((attempt=0; attempt<56; attempt++)); do
      [[ $(cat "$ROOT/network-backup/state") == confirmed ]] && break
      [[ $(cat "$ROOT/network-backup/state") != rolled-back ]] || die '网络已自动恢复，安装停止。'
      sleep 5
    done
    [[ $(cat "$ROOT/network-backup/state") == confirmed ]] || die '未在期限内确认新 SSH，安装停止并等待网络回退。'
  fi
}
confirm_network() {
  exec 9>/run/mmwx-network.lock; flock 9
  [[ -f $ROOT/network-backup/state && $(cat "$ROOT/network-backup/state") == pending ]] || die '没有待确认的网络变更，或网络已回退。'
  systemctl is-active --quiet mmwx-network-rollback.timer || die '网络确认期限已过。'
  [[ ${SSH_CONNECTION:-} != *:* ]] || die '请通过 IPv4 SSH 确认。'
  if [[ $(sysctl -n net.ipv6.conf.all.disable_ipv6) != 1 ]] || ! grep -qx 'IPV6=no' /etc/default/ufw || ! ufw status | grep -qx 'Status: active'; then die '实际网络状态不符合预期，请等待回退。'; fi
  printf 'confirmed\n' > "$ROOT/network-backup/state"
  systemctl stop mmwx-network-rollback.timer
  systemctl reset-failed mmwx-network-rollback.service 2>/dev/null || true
  flock -u 9
  info '已确认 SSH，取消网络自动回退。'
}
install_units() {
  if [[ $SELF != /usr/local/sbin/mmwx-installer ]]; then install -m 0700 "$SELF" /usr/local/sbin/mmwx-installer; fi
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
install_stack() {
  preflight
  [[ ! -f $ROOT/state.json ]] || die '本项目已安装，请选择更新。数据保留重装请运行 resume。'
  token_guide
  [[ -n $DOMAIN ]] || DOMAIN=$(ask '输入面板域名：')
  if [[ -z $TOKEN_FILE ]]; then
    TOKEN_FILE=$(mktemp); TEMP_TOKEN=$TOKEN_FILE
    local token
    read -r -s -p '粘贴 API Token（不显示）：' token </dev/tty; printf '\n'
    printf '%s' "$token" > "$TOKEN_FILE"
  fi
  dependencies
  dns_check
  install_docker
  choose_version
  build_caddy
  docker pull "$PG_IMAGE"
  PG_IMAGE=$(docker image inspect "$PG_IMAGE" --format '{{index .RepoDigests 0}}')
  install -d -m 0700 "$ROOT"
  local password
  password=$(openssl rand -hex 32)
  printf 'POSTGRES_PASSWORD=%s\n' "$password" > "$ROOT/postgres.env"
  printf 'MMWX_DATABASE_PASSWORD=%s\n' "$password" > "$ROOT/app.env"
  printf 'CF_API_TOKEN=%s\n' "$CF_TOKEN" > "$ROOT/caddy.env"
  unset CF_TOKEN password
  render_compose > "$ROOT/compose.yaml"
  render_caddy > "$ROOT/Caddyfile"
  dc config --quiet
  network_setup
  render_caddy > "$ROOT/Caddyfile"
  save_state
  dc up -d --wait --wait-timeout 300
  verify_https
  printf '\n安装与 HTTPS 验证完成。访问 https://%s 完成管理员初始化。\n查看日志：sudo mmwx-installer logs\n' "$DOMAIN"
}
update_stack() {
  preflight; load_state
  local backup
  backup="$ROOT/backups/$(date -u +%Y%m%dT%H%M%SZ)"
  choose_version
  mkdir -p "$backup"
  cp "$ROOT/compose.yaml" "$ROOT/state.json" "$backup/"
  dc stop mmwx caddy
  if ! dc exec -T postgres pg_dump -U mmwx -d mmwx -Fc > "$backup/database.dump"; then
    dc start mmwx caddy; die '数据库备份失败，已重新启动旧版本。'
  fi
  if ! tar -czf "$backup/files.tar.gz" -C "$ROOT" data subscribes rule_templates; then
    dc start mmwx caddy; die '文件备份失败，已重新启动旧版本。'
  fi
  render_compose > "$ROOT/compose.yaml"
  if dc up -d --wait --wait-timeout 300; then
    save_state; sync_cf; info "更新完成：$VERSION。备份：$backup"
  else
    dc stop mmwx caddy
    dc exec -T postgres dropdb -U mmwx --if-exists --force mmwx
    dc exec -T postgres createdb -U mmwx -O mmwx mmwx
    dc exec -T postgres pg_restore -U mmwx -d mmwx --exit-on-error < "$backup/database.dump"
    cp "$backup/compose.yaml" "$ROOT/compose.yaml"
    mkdir "$backup/restored"
    tar -xzf "$backup/files.tar.gz" -C "$backup/restored"
    for directory in data subscribes rule_templates; do
      mv "$ROOT/$directory" "$backup/failed-$directory"
      mv "$backup/restored/$directory" "$ROOT/$directory"
    done
    dc up -d --wait --wait-timeout 300
    die '新版本健康检查失败，已恢复旧版本和数据库。'
  fi
}
uninstall_stack() {
  load_state
  [[ $(ask '卸载容器并保留数据，输入 UNINSTALL：') == UNINSTALL ]] || die '已取消。'
  dc down
  systemctl disable --now mmwx-cf-sync.timer mmwx-firewall.service
  rm -f /etc/systemd/system/docker.service.d/mmwx-firewall.conf
  while iptables -C DOCKER-USER -o br-mmwx-front -j MMWX-CF 2>/dev/null; do iptables -D DOCKER-USER -o br-mmwx-front -j MMWX-CF; done
  if iptables -nL MMWX-CF >/dev/null 2>&1; then iptables -F MMWX-CF; iptables -X MMWX-CF; fi
  ipset destroy mmwx_cf 2>/dev/null || true
  while IFS= read -r cidr; do ufw delete allow from "$cidr" to any port 80,443 proto tcp; done < "$ROOT/cloudflare-v4.txt"
  rm -f /etc/systemd/system/mmwx-firewall.service /etc/systemd/system/mmwx-cf-sync.{service,timer}
  systemctl daemon-reload
  info "已卸载容器。数据保留于 $ROOT；SSH/UFW/IPv6 设置保留。恢复：sudo mmwx-installer resume"
}
usage() {
  cat <<'EOF'
用法：sudo bash install.sh [install|update|uninstall|status|logs|resume|check]
  --domain panel.example.com  面板域名
  --channel stable|beta       安装或更新的发布通道
  --cf-token-file /root/token root 所有、600 权限的 Token 文件
  --yes                      接受全新环境提示；必须五分钟内另开 SSH 执行 confirm-network
安装需确认新 SSH 连接；check 只检查环境，不修改系统。
EOF
}
main() {
  while (($#)); do
    case "$1" in
      install|update|uninstall|status|logs|resume|check|firewall-apply|firewall-sync|confirm-network) ACTION=$1; shift;;
      --yes) ACCEPT=1; shift;;
      --domain|--channel|--cf-token-file)
        [[ $# -ge 2 ]] || die "缺少参数：$1"
        case "$1" in --domain) DOMAIN=$2;; --channel) CHANNEL=$2; CHANNEL_EXPLICIT=1;; --cf-token-file) TOKEN_FILE=$2;; esac; shift 2;;
      -h|--help) usage; return;; *) die "未知参数：$1";;
    esac
  done
  if [[ -z $ACTION ]]; then
    printf '\033[1;31m仅限全新环境运行！会启用 UFW 并全机禁用 IPv6。请使用 IPv4 SSH。\033[0m\n'
    printf '1. 安装\n2. 更新（默认沿用已选通道，可用 --channel 切换）\n3. 卸载（保留数据）\n4. 查看状态\n'
    case $(ask '请选择：') in 1) ACTION=install;; 2) ACTION=update;; 3) ACTION=uninstall;; 4) ACTION=status;; *) die '无效选择。';; esac
  fi
  [[ $EUID == 0 ]] || die '请用 sudo / root 运行。'
  case "$ACTION" in install|update|uninstall|resume) exec 7>/run/mmwx-installer.lock; flock -n 7 || die '另一个安装或维护进程正在运行，请等待。';; esac
  if [[ $ACTION == install ]]; then
    printf '\033[1;31m仅限全新环境！会启用 UFW、禁用全机 IPv6，仅允许 Cloudflare 访问网页端口。\033[0m\n'
    if [[ $ACCEPT == 0 ]]; then [[ $(ask '确认已准备好 IPv4 SSH 和全新服务器，输入 INSTALL：') == INSTALL ]] || die '已取消。'; fi
  fi
  case "$ACTION" in
    firewall-apply) exec 8>/run/mmwx-cf.lock; flock 8; apply_firewall;; firewall-sync) sync_cf;; confirm-network) confirm_network;;
    check) preflight; info '环境预检通过。';;
    install) install_stack;; update) update_stack;; uninstall) uninstall_stack;;
    status) load_state; dc ps; ufw status;; logs) load_state; dc logs --tail 80 caddy mmwx;;
    resume) preflight; load_state; install_units; sync_cf; dc up -d --wait --wait-timeout 300; verify_https;;
  esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  trap '[[ -z $TEMP_TOKEN ]] || rm -f "$TEMP_TOKEN"' EXIT
  trap 'printf "操作失败（第 %s 行）。保留现场，请检查前面的错误；不要反复重装。\n" "$LINENO" >&2' ERR
  main "$@"
fi
