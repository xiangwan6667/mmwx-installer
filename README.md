<p align="center">
  <img src="assets/MeowX.png" alt="MeowX 项目图标" width="180" height="180">
</p>

<h1 align="center">妙妙屋 X 安装器</h1>

<div align="center">

[![GitHub Release](https://img.shields.io/github/v/release/xiangwan6667/mmwx-installer?color=blue)](https://github.com/xiangwan6667/mmwx-installer/releases/latest)
[![Installer checks](https://github.com/xiangwan6667/mmwx-installer/actions/workflows/check.yml/badge.svg)](https://github.com/xiangwan6667/mmwx-installer/actions/workflows/check.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

[快速开始](#快速开始) · [日常管理](#日常管理) · [数据与恢复](#数据与恢复) · [卸载](#卸载) · [常见问题](#常见问题)

</div>

通过 Docker Compose 部署 [妙妙屋 X](https://github.com/iluobei/miaomiaowuX)、PostgreSQL 18 和 Caddy，完成 Cloudflare DNS 配置、HTTPS 签发及访问防护。当前管理脚本版本为 **v0.2.13**。

## 功能

- **一键部署**：交互选择域名与版本，自动补齐依赖、创建 DNS 记录并开启小黄云。
- **版本管理**：支持正式版、测试版及指定版本，提供更新、回退和中断任务恢复。
- **自动 HTTPS**：通过 Cloudflare DNS-01 签发证书，仅允许 Cloudflare 回源访问网站。
- **数据持久化**：数据库、应用文件和证书保存于宿主机；更新前自动备份。
- **统一管理**：使用 `mmwx` 查看状态、日志，管理服务和更新脚本。

## 快速开始

### 环境要求

**请使用专用服务器安装，保持系统全新且没有其他业务。**

| 项目 | 要求 |
| --- | --- |
| 系统 | 全新 Debian 12/13 或 Ubuntu 22.04/24.04/26.04，使用 systemd |
| 架构 | AMD64 / ARM64 |
| 网络 | 网卡上具有唯一公网 IPv4，通过 IPv4 SSH 登录；不支持仅有 NAT 私网地址的主机 |
| 权限 | root |
| 资源 | 建议 2 GB 内存、10 GB 可用磁盘 |
| 安全组 | 放行 SSH，以及 Cloudflare 到源站的 TCP 80/443 |

安装会启用 UFW、禁用 IPv6，并将系统和容器时区设为 `Asia/Shanghai`。修改网络前保存原配置，完全卸载时恢复。已有其他容器、网站或相关服务时，预检会停止。

### 准备 Cloudflare

1. 将主域名托管到 Cloudflare，等待区域状态变为 **Active**。
2. 将 SSL/TLS 模式设为 **完全（严格） / Full (strict)**。
3. [创建 API Token](https://dash.cloudflare.com/profile/api-tokens)：使用「编辑区域 DNS」模板，补充「区域 → 区域 → 读取」权限，区域资源选择要使用的主域名。

### 安装

以 **root** 执行以下一行命令：

```bash
bash -o pipefail -c 'if ! command -v curl >/dev/null || [ ! -s /etc/ssl/certs/ca-certificates.crt ]; then apt-get update && apt-get install -y ca-certificates curl || exit; fi; curl -fsSL -H "Cache-Control: no-cache" "https://github.com/xiangwan6667/mmwx-installer/releases/latest/download/bootstrap.sh?mmwx_check=$(date +%s%N)-$$-$RANDOM" | bash'
```

入口会安装管理程序并注册 `mmwx` 命令，无需保留本地下载副本。

1. 选择 **1 · 安装 / 继续安装**，输入 Token、选择主域名和主控版本。
2. 输入子域名前缀，直接回车使用 `mmwx`，例如 `mmwx.example.com`。
3. 网络设置完成后，另开终端通过 IPv4 重新登录 SSH，再按提示确认连接正常；五分钟未确认会恢复原网络设置。
4. 安装成功后，打开显示的 HTTPS 地址。数据库已通过环境变量配置，**无需勾选「使用 PG 数据库」**。

DNS 记录由脚本创建。已有且完全匹配的代理 A 记录会直接复用；其他同名记录冲突时停止。

## 日常管理

以 root 身份在任意目录运行：

```bash
mmwx
```

本文所有命令均以 root 身份执行。

| 菜单 | 操作 |
| --- | --- |
| 1 | 安装 / 继续安装 |
| 2 | 更新主控版本 |
| 3 | 运行状态 |
| 4 | 查看日志 |
| 5 | 继续任务 / 恢复服务 |
| 6 | 回退主控版本 |
| 7 | 强制重新安装 |
| 8 | Caddy 管理 |
| 9 | 更新管理脚本 |
| 10 | 卸载服务 |
| 11 | 卸载管理脚本 |
| 0 | 退出 |

安装和更新可选择最新正式版、最新测试版，或从所选通道最近 **5 个版本**中选择。版本来自上游官方 Releases，GitHub API 不可用时改读发布网页。

脚本会先检查镜像是否发布并支持本机架构。最新版镜像未就绪时，在同一通道最近 5 个版本中寻找上一可用版本，经 `y/n` 确认后使用；指定版本不可用时，可重试或重选。网络、限流和鉴权错误会停止操作。更新前完成镜像检查和下载，选择的镜像与当前运行版本相同时无需重启服务。

更新管理脚本使用菜单 **9**（v0.2.4 为菜单 8，v0.2.3 及更早版本为菜单 7）；旧版没有此入口时，重新执行上方安装命令即可。管理脚本从 GitHub Releases 的最新稳定版本下载，并在安装前按同一发布版本的 `SHA256SUMS` 校验文件及脚本版本。脚本版本可用 `mmwx --version` 查看，命令参数见 `mmwx --help`。

打开 `mmwx` 时自动检测脚本最新正式版，有更新会在菜单顶部提示，选择菜单 **9** 更新。每次启动只检测一次，最多等待 3 秒；检测失败不影响使用，不会自动安装更新，也不占用 GitHub API 配额。

菜单 **4 · 查看日志** 提供服务日志、最近任务、历史任务、实时进度和证书申请诊断。

```bash
mmwx trace         # 最近任务和失败原因
mmwx trace-follow  # 实时跟踪任务进度，Ctrl+C 退出
mmwx logs          # 最近 80 行服务日志
```

任务日志保存在 `state/logs/task-*.log`，记录时间、脚本版本、步骤、退出码、失败位置及摘要；完整步骤输出保存在同目录的 `step-*.log`。日志写入前会脱敏已配置的 Token 和密码。完全卸载会删除这些日志。

证书申请失败会识别 ACME 限流，显示原始原因及 CA 提供的重试时间。不要反复删除证书目录；修复问题或等限流解除后，选择菜单 5 继续。脚本没有设置默认申请邮箱，已有 ACME 账户随证书目录持久保存。[Let’s Encrypt 限制说明](https://letsencrypt.org/docs/rate-limits/)

### Caddy 管理

选择菜单 **8**，或运行 `mmwx caddy`：

| 菜单 | 操作 |
| --- | --- |
| 1 | 容器状态、Caddy 版本与当前域名 |
| 2 | 最近 80 行日志 |
| 3 | 校验并重载配置 |
| 4 | 重启 Caddy |
| 5 | 源站、Cloudflare 边缘证书与公网 HTTPS 状态 |
| 6 | 替换 Cloudflare Token |
| 7 | 变更域名 |

Token 可隐藏输入，也可使用 root 所有、权限为 `600` 的文件：

```bash
mmwx caddy-token --cf-token-file /root/cloudflare.token
```

新 Token 需具有当前域名所属 Active 区域的读取和 DNS 编辑权限。脚本先创建并删除随机临时 TXT，验证通过后更新凭据，仅重建 Caddy；网关短暂中断，妙妙屋和 PostgreSQL 保持运行，现有证书和数据保留。

验证失败不替换凭据；应用失败自动恢复旧配置。断开终端或清理失败时，选择**主菜单 5**恢复任务。待恢复期间暂停 CF 网段定时刷新，并阻止冲突维护操作。Token 不显示在命令参数、终端及管理日志中。

证书检查分别连接本机源站和公网域名，显示签发者、到期时间及剩余天数。公网故障单独报告，不作为 Token 失效的判断依据。旧目录安装需先通过主菜单 5 完成迁移。

#### 变更域名

选择 Caddy 菜单 **7**，或运行：

```bash
mmwx caddy-domain
```

选择当前 Token 授权的主域名，输入子域名前缀（回车使用 `mmwx`），再以 `y/n` 确认。新主域名须已托管至 Cloudflare 并处于 Active 状态；当前 Token 需同时有新旧区域的读取和 DNS 编辑权限。

脚本创建或复用匹配的代理 A 记录，为新域名申请证书，并检查源站与公网 HTTPS。期间保留旧域名，仅重载 Caddy；容器、数据库、业务文件、Token 和已有证书均保留。

切换成功后自动删除旧域名中带安装器标记、仍指向本机且未被修改的代理 A 记录。手工创建或已修改的记录保留。新域名验证失败时恢复旧配置；清理旧解析失败时保留新域名服务，通过主菜单 **5** 重试。域名变更过程中断后也使用菜单 **5** 恢复。

## 数据与恢复

所有业务数据保存在 `/opt/mmwx-installer`，通过目录挂载持久化：

```text
/opt/mmwx-installer/
├── config/              # Compose、环境变量、Caddy 配置、Token
├── data/
│   ├── postgres/        # PostgreSQL 数据
│   ├── app/             # 应用数据
│   ├── subscribes/      # 订阅文件
│   └── rule_templates/  # 规则模板
├── certs/               # 证书及 Caddy 状态
├── backups/             # 更新前备份
└── state/               # 任务进度、版本记录、网络恢复配置及日志
```

### 继续安装或恢复服务

安装中断后选择菜单 **1** 或 **5** 继续。已完成安装、重建容器或保留数据卸载后的恢复，使用菜单 **5**；菜单 1 不会重新初始化已有安装。

旧版目录会在维护时自动迁移，期间短暂停止容器，保留原有数据和凭据。重要数据请另存到其他机器。

### 强制重新安装

菜单 **7** 重新拉取当前版本的妙妙屋镜像，仅强制重建主控容器。Caddy 和 PostgreSQL 保持运行；数据库、应用文件、配置、证书、凭据和备份全部保留，不切换主控版本。

操作前需 `y/n` 确认。镜像准备完成后才重建主控，期间网站会短暂中断；失败或中断后可用菜单 **5** 继续。也可直接运行 `mmwx reinstall`。

仍使用旧版目录时，先通过菜单 5 完成目录迁移，再执行重装。

### 更新失败恢复与手动回退

| 场景 | 行为 |
| --- | --- |
| 更新主控 | 仅停止主控，备份数据库与应用文件，再启动所选版本；Caddy 和 PostgreSQL 保持运行 |
| 新版启动或健康检查失败 | 自动恢复更新前的主控版本、数据库和应用文件 |
| 更新中断 | 菜单 5 继续恢复；若仅停在备份阶段，则启动旧版本，不使用未完成的备份 |
| 菜单 6 手动回退 | 从官方版本列表选择目标，仅切换主控镜像，保留当前数据库和文件；无需曾经安装该版本 |

主控更新及失败恢复不会重启或重载 Caddy。旧版更新任务若已停止网关，恢复时会重新启动该容器。旧目录须先从菜单 5 完成迁移，再更新或回退主控。

手动回退的目标版本启动失败时会切回原镜像。旧版本可能不兼容当前数据库结构，切换镜像不会撤销数据变更。

## 网络与证书

仅 Caddy 发布 IPv4 TCP **80/443**，主控和数据库不发布宿主机端口。UFW 放行 SSH，网站流量通过 `DOCKER-USER → MMWX-CF` 和 `ipset` 限制为 Cloudflare 来源。

Cloudflare 网段每天自动刷新，获取失败时保留现有集合；Docker 重启前会应用防护规则。

Caddy 与 Cloudflare DNS 模块使用本仓库的 [预编译依赖包](https://github.com/xiangwan6667/mmwx-installer/releases/tag/v0.1.0-rc.1)，提供 AMD64 / ARM64 文件并校验 SHA-256。服务器只组装容器镜像，无需编译 Go；依赖包版本与管理脚本版本分别维护。

## 卸载

| 操作 | 删除内容 | 保留内容 |
| --- | --- | --- |
| 菜单 10 → 保留数据（默认） | 容器、本项目防火墙规则及定时任务 | 项目目录、备份、Token、Docker 引擎与镜像、管理命令；可用菜单 5 恢复 |
| 菜单 10 → 完全卸载 | 项目容器及遗留容器、所有 Docker 镜像与网络、Docker 和 containerd 数据目录及软件包、防火墙链与 ipset、定时任务、项目目录、备份、Token 和后台程序；恢复安装前的 UFW 与 IPv6 | `mmwx` 管理命令、系统时区及 Cloudflare DNS 记录 |
| 菜单 11 → 卸载管理脚本 | `mmwx` 管理入口 | 容器、数据和后台防火墙程序，继续提供重启防护及网段刷新 |

两种服务卸载方式都保留 `mmwx` 管理菜单。保留数据模式保留当前 UFW/IPv6 配置，方便恢复服务；完全卸载恢复原 UFW 规则、启用状态和 IPv6 配置。完全卸载前会检查其他容器（包括已停止的容器）、卷、非默认网络及 containerd 工作负载；发现其他业务时拒绝清理。备份缺失或恢复失败时停止删除数据，可从菜单 10 重试。

新安装会记录各网卡的 IPv6 状态；旧版备份仅能恢复当时记录的 `all/default/lo` 配置。移除管理菜单需单独选择菜单 11，之后重新执行安装命令即可恢复入口。

## 常见问题

**安装或更新失败，如何继续？** 重新运行 `mmwx`，选择菜单 5。菜单 4 可查看最近任务和失败摘要；也可运行 `mmwx trace` 查看最新任务，或 `mmwx trace-follow` 实时跟随。完整日志保存在 `state/logs/`，失败时会显示日志路径。

**证书失败或出现 Cloudflare 522？** 先查看菜单 4：证书问题检查 Token 权限、域名 Active 状态与 Full (strict)；522 检查安全组、源站 IPv4 和服务状态。

**能否无人值守安装？** `--yes` 只跳过全新环境提示。仍须在五分钟内从另一 IPv4 SSH 连接执行 `mmwx confirm-network`；其他参数见 `mmwx --help`。

## 反馈与贡献

欢迎通过 [Issues](https://github.com/xiangwan6667/mmwx-installer/issues) 反馈问题，或提交 [Pull Request](https://github.com/xiangwan6667/mmwx-installer/pulls)。反馈时附上系统版本、架构、脚本版本及相关日志，并移除 Token、密码和业务信息。

[查看发布记录](https://github.com/xiangwan6667/mmwx-installer/releases) · [查看自动检查](https://github.com/xiangwan6667/mmwx-installer/actions) · [妙妙屋 X 上游项目](https://github.com/iluobei/miaomiaowuX)

## 许可证

本安装器采用 [MIT License](LICENSE)。妙妙屋 X 及其他依赖遵循各自的许可证。
