# 妙妙屋 X 安装器

<div align="center">
  <img src="assets/MeowX.png" alt="妙妙屋 X" height="180" />
</div>

本项目使用 Docker Compose 部署[妙妙屋 X](https://github.com/iluobei/miaomiaowuX)、PostgreSQL 18 和 Caddy，并配置 Cloudflare DNS、HTTPS 与源站访问防护。管理脚本版本为 **v0.3.0**。

## 功能特性

- 交互式安装、更新和回退主控版本，支持中断后继续任务。
- 自动创建 Cloudflare 代理 DNS 记录，通过 DNS-01 申请和续期 HTTPS 证书。
- 只允许 Cloudflare 回源访问网站，每天刷新 Cloudflare 网段。
- 持久化数据库、应用文件和证书；更新前备份，启动失败时自动恢复。
- 通过 `mmwx` 管理服务、日志、域名、Token 和安装脚本。

## 安装部署

### 环境要求

**仅在专用的全新服务器上安装。** 预检发现其他容器、网站或相关服务时会停止。

| 项目 | 要求 |
| --- | --- |
| 系统 | Debian 12/13 或 Ubuntu 22.04/24.04/26.04，使用 systemd |
| 架构 | AMD64 / ARM64 |
| 网络 | 网卡具有唯一公网 IPv4，并通过 IPv4 SSH 登录；不支持仅有 NAT 私网地址的主机 |
| 权限 | root |
| 资源 | 建议至少 2 GB 内存、10 GB 可用磁盘 |
| 安全组 | 放行 SSH，以及 Cloudflare 到源站的 TCP 80/443 |

安装会启用 UFW、禁用 IPv6，并把系统和容器时区设为 `Asia/Shanghai`。脚本在修改网络前保存配置；完全卸载时恢复 UFW 和 IPv6 配置。

### 准备 Cloudflare

1. 将主域名托管到 Cloudflare，确认区域状态为 **Active**。
2. 将 SSL/TLS 模式设为 **完全（严格）/ Full (strict)**。
3. [创建 API Token](https://dash.cloudflare.com/profile/api-tokens)：使用「编辑区域 DNS」模板，增加「区域 → 区域 → 读取」权限，并将区域资源限定为要使用的主域名。

### 一键安装

以 **root** 身份执行：

```bash
bash -o pipefail -c 'if ! command -v curl >/dev/null || [ ! -s /etc/ssl/certs/ca-certificates.crt ]; then apt-get update && apt-get install -y ca-certificates curl || exit; fi; curl -fsSL -H "Cache-Control: no-cache" "https://github.com/xiangwan6667/mmwx-installer/releases/latest/download/bootstrap.sh?mmwx_check=$(date +%s%N)-$$-$RANDOM" | bash'
```

安装入口会自动注册 `mmwx` 命令。选择 **1 · 安装 / 继续安装**，按提示输入 Token、选择主域名与主控版本，并输入子域名前缀。前缀留空时使用 `mmwx`，例如 `mmwx.example.com`。脚本会创建 DNS 记录；已有且完全匹配的代理 A 记录会复用，其他同名记录冲突时停止。

网络设置完成后，**另开终端通过 IPv4 重新登录 SSH**，再按提示确认连接正常。五分钟内未确认，脚本会恢复原网络设置。安装完成后访问显示的 HTTPS 地址。数据库连接已由环境变量配置，初始化页面无需勾选「使用 PG 数据库」。

## 日常管理

以下命令均以 root 身份执行。运行 `mmwx` 打开菜单：

| 菜单 | 操作 |
| --- | --- |
| 1 | 安装 / 继续安装 |
| 2 | 更新主控版本 |
| 3 | 运行状态 |
| 4 | 查看日志 |
| 5 | 继续任务 / 恢复服务 |
| 6 | 回退主控版本 |
| 7 | 强制重新安装主控 |
| 8 | Caddy 管理 |
| 9 | 更新管理脚本 |
| 10 | 卸载服务 |
| 11 | 卸载管理脚本 |
| 0 | 退出 |

主控可选择最新正式版、最新测试版，或所选通道最近 5 个版本中的指定版本。更新前会检查镜像是否已发布、支持本机架构并完成下载；更新失败会恢复原主控版本、数据库和应用文件。菜单 6 仅切换主控镜像，保留当前数据，因此旧版本仍可能与现有数据库不兼容。菜单 7 重新拉取并重建当前版本的主控，不重建 Caddy 和 PostgreSQL。

最新版镜像尚未就绪时，可经 `y/n` 确认使用同通道上一可用版本；网络、限流或鉴权错误时停止。GitHub API 查询失败时尝试读取发布网页。

菜单 5 用于继续中断的安装或更新、恢复服务，以及完成旧目录迁移。菜单 9 更新管理脚本；旧版没有此入口时，重新执行上方一键安装命令。查看当前脚本版本和参数：

```bash
mmwx --version
mmwx --help
```

### 更新管理脚本

```bash
mmwx self-update
mmwx --version
```

脚本从最新正式 Release 下载，校验 SHA-256 和版本后更新管理入口。打开菜单时会自动检测新版，最多等待 3 秒；仅提示，不自动更新。更新脚本不会重启服务。

**旧版用户请先更新脚本，再安装或重建 Caddy。** v0.3.0 已合并预编译依赖包，旧 Release 的下载地址不再保留。

### 日志与证书

菜单 4 可查看服务日志、任务记录、实时进度和证书诊断。常用命令：

```bash
mmwx trace         # 最近任务与失败原因
mmwx trace-follow  # 实时跟踪任务，Ctrl+C 退出
mmwx logs          # 最近 80 行服务日志
```

任务日志位于 `/opt/mmwx-installer/state/logs/`，记录步骤、退出码及失败位置，写入前脱敏已配置的凭据。证书申请失败时，先检查 Token 权限、区域状态和 DNS；公网访问异常时检查 Cloudflare 的 Full (strict) 设置。ACME 限流时等待提示的重试时间，再从菜单 5 继续。脚本未设置默认申请邮箱，已有 ACME 账户与证书持久保存，请勿反复删除证书目录。

### Caddy 域名与 Token

运行 `mmwx caddy` 或选择菜单 8，可查看状态与日志、校验并重载配置、重启 Caddy、检查 HTTPS，以及更换 Token 或域名。证书检查分别显示本机源站与 Cloudflare 边缘证书的签发者、到期时间和剩余天数。

更换 Token 可在菜单中隐藏输入，也可从权限为 `600`、由 root 所有的文件读取：

```bash
mmwx caddy-token --cf-token-file /root/cloudflare.token
```

新 Token 必须具备当前区域的读取和 DNS 编辑权限。脚本会先用临时 TXT 记录验证权限，成功后才替换凭据并重建 Caddy；失败时恢复旧配置。主控和 PostgreSQL 保持运行。

变更域名可在 Caddy 菜单中操作，或运行：

```bash
mmwx caddy-domain
```

新域名必须位于 Active 区域，当前 Token 须同时有新旧区域的读取与 DNS 编辑权限。脚本为新域名创建或复用代理 A 记录、申请证书并检查 HTTPS，仅重载 Caddy，保留所有容器与数据。成功后自动删除由脚本创建、仍指向本机且未被修改的旧代理 A 记录；其他记录保留。失败或中断后，用主菜单 5 恢复任务；旧解析清理失败时保留新域名服务，恢复任务会重试清理。

## 数据与恢复

业务数据位于 `/opt/mmwx-installer`：

```text
/opt/mmwx-installer/
├── config/              Compose、环境变量、Caddy 配置和 Token
├── data/
│   ├── postgres/        PostgreSQL 数据
│   ├── app/             应用数据
│   ├── subscribes/      订阅文件
│   └── rule_templates/  规则模板
├── certs/               证书及 Caddy 状态
├── backups/             更新前备份
└── state/               任务进度、版本记录、网络恢复配置和日志
```

安装中断后选择菜单 1 或 5；已完成安装后的服务恢复使用菜单 5。重要数据应另行备份到其他机器。主控更新不会重启 Caddy；更新或恢复失败时，可从菜单 4 查看任务日志，再通过菜单 5 继续。

## 架构

```text
用户 → Cloudflare → Caddy :80/:443 → 妙妙屋 X → PostgreSQL 18
                    源站防火墙          Docker 内部网络
```

仅 Caddy 发布 IPv4 TCP 80/443，主控和数据库不发布宿主机端口。网站通过 `DOCKER-USER → MMWX-CF` 与 ipset 限制 Cloudflare 来源，UFW 放行 SSH。Cloudflare 网段每日刷新，Docker 重启时应用防护规则。

Caddy 的 Cloudflare DNS 模块使用本仓库 [v0.3.0 发布包](https://github.com/xiangwan6667/mmwx-installer/releases/tag/v0.3.0)中的预编译依赖，支持 AMD64 / ARM64，并校验 SHA-256；服务器只组装容器镜像，无需编译 Go。

## 卸载

菜单 10 提供两种服务卸载方式；菜单 11 单独移除 `mmwx` 管理入口。

| 操作 | 结果 |
| --- | --- |
| 保留数据（默认） | 删除项目容器、防火墙规则及定时任务；保留项目目录、备份、Token、Docker 和 `mmwx`，可用菜单 5 恢复 |
| 完全卸载 | 删除项目数据、容器、镜像、Docker 网络、引擎及其数据目录、项目防护规则、定时任务和后台程序；恢复安装前的 UFW 与 IPv6 配置。保留 `mmwx`、系统时区及 Cloudflare DNS 记录 |
| 卸载管理脚本 | 删除 `mmwx` 入口；运行中的服务和数据保留 |

保留数据卸载保留当前 UFW 与 IPv6 设置。完全卸载会检查其他容器、卷、网络及 containerd 工作负载；发现其他业务、备份缺失或网络恢复失败时停止清理。旧版备份可能只记录 `all/default/lo` 的 IPv6 设置。卸载管理脚本后，后台防火墙程序仍运行；可重新执行一键安装命令恢复入口。

## 更新日志

查看 [v0.3.0 完整更新日志](CHANGELOG.md) 或 [Releases](https://github.com/xiangwan6667/mmwx-installer/releases)。

## 反馈

问题请提交至 [Issues](https://github.com/xiangwan6667/mmwx-installer/issues)。附上系统版本、架构、脚本版本和相关日志，并移除 Token、密码及业务信息。

## 许可证

本安装器采用 [MIT License](LICENSE)。妙妙屋 X 及其他依赖遵循各自的许可证。
