<h1 align="center">妙妙屋 X 安装器</h1>

<div align="center">

[![GitHub Release](https://img.shields.io/github/v/release/xiangwan6667/mmwx-installer?color=blue)](https://github.com/xiangwan6667/mmwx-installer/releases/latest)
[![Installer checks](https://github.com/xiangwan6667/mmwx-installer/actions/workflows/check.yml/badge.svg)](https://github.com/xiangwan6667/mmwx-installer/actions/workflows/check.yml)

[快速开始](#快速开始) · [日常管理](#日常管理) · [数据与恢复](#数据与恢复) · [卸载](#卸载) · [常见问题](#常见问题)

</div>

通过 Docker Compose 部署 [妙妙屋 X](https://github.com/iluobei/miaomiaowuX)、PostgreSQL 18 和 Caddy，完成 Cloudflare DNS 配置、HTTPS 签发及访问防护。当前管理脚本版本为 **v0.2.2**。

## 功能

- **一键部署**：交互选择域名与版本，自动补齐依赖、创建 DNS 记录并开启小黄云。
- **版本管理**：支持正式版、测试版及指定版本，提供更新、回退和中断任务恢复。
- **自动 HTTPS**：通过 Cloudflare DNS-01 签发证书，仅允许 Cloudflare 回源访问网站。
- **数据持久化**：数据库、应用文件和证书保存于宿主机；更新前自动备份。
- **统一管理**：使用 `mmwx` 查看状态、日志，管理服务和更新脚本。

## 快速开始

### 环境要求

| 项目 | 要求 |
| --- | --- |
| 系统 | 全新 Debian 12/13 或 Ubuntu 22.04/24.04/26.04，使用 systemd |
| 架构 | AMD64 / ARM64 |
| 网络 | 网卡上具有唯一公网 IPv4，通过 IPv4 SSH 登录；不支持仅有 NAT 私网地址的主机 |
| 权限 | root |
| 资源 | 建议 2 GB 内存、10 GB 可用磁盘 |
| 安全组 | 放行 SSH，以及 Cloudflare 到源站的 TCP 80/443 |

安装会启用 UFW、禁用 IPv6，并将系统和容器时区设为 `Asia/Shanghai`。已有其他容器、网站或相关服务时，预检会停止。

### 准备 Cloudflare

1. 将主域名托管到 Cloudflare，等待区域状态变为 **Active**。
2. 将 SSL/TLS 模式设为 **完全（严格） / Full (strict)**。
3. [创建 API Token](https://dash.cloudflare.com/profile/api-tokens)：使用「编辑区域 DNS」模板，补充「区域 → 区域 → 读取」权限，区域资源选择要使用的主域名。

### 安装

以 **root** 执行以下一行命令：

```bash
bash -o pipefail -c 'if ! command -v curl >/dev/null || [ ! -s /etc/ssl/certs/ca-certificates.crt ]; then apt-get update && apt-get install -y ca-certificates curl || exit; fi; curl -fsSL https://raw.githubusercontent.com/xiangwan6667/mmwx-installer/main/bootstrap.sh | bash'
```

入口会安装管理程序并注册 `mmwx` 命令，无需保留本地下载副本。

1. 选择 **1 · 安装 / 继续安装**，输入 Token、选择主域名和主控版本。
2. 输入子域名前缀，直接回车使用 `mmwx`，例如 `mmwx.example.com`。
3. 网络设置完成后，另开终端通过 IPv4 重新登录 SSH，再按提示确认连接正常；五分钟未确认会恢复原网络设置。
4. 安装成功后，打开显示的 HTTPS 地址。数据库已通过环境变量配置，**无需勾选「使用 PG 数据库」**。

DNS 记录由脚本创建。已有且完全匹配的代理 A 记录会直接复用；其他同名记录冲突时停止。

## 日常管理

在任意目录运行：

```bash
sudo mmwx
```

root 用户直接运行 `mmwx`。

| 菜单 | 操作 |
| --- | --- |
| 1 | 安装 / 继续安装 |
| 2 | 更新主控版本 |
| 3 | 运行状态 |
| 4 | 查看日志 |
| 5 | 继续任务 / 恢复服务 |
| 6 | 回退主控版本 |
| 7 | 更新管理脚本 |
| 8 | 卸载服务 |
| 9 | 卸载管理脚本 |
| 0 | 退出 |

安装和更新可选择最新正式版、最新测试版，或从所选通道最近 **5 个版本**中选择。版本来自上游官方 Releases，GitHub API 不可用时改读发布网页；对应容器镜像尚未发布时会停止。

更新管理脚本使用菜单 **7**；旧版没有此入口时，重新执行上方安装命令即可。脚本版本可用 `mmwx --version` 查看，命令参数见 `mmwx --help`。

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

### 更新失败恢复与手动回退

| 场景 | 行为 |
| --- | --- |
| 更新主控 | 停止主控和网关，备份数据库与应用文件，再启动所选版本 |
| 新版启动或健康检查失败 | 自动恢复更新前的主控版本、数据库和应用文件 |
| 更新中断 | 菜单 5 继续恢复；若仅停在备份阶段，则启动旧版本，不使用未完成的备份 |
| 菜单 6 手动回退 | 从官方版本列表选择目标，仅切换主控镜像，保留当前数据库和文件；无需曾经安装该版本 |

手动回退的目标版本启动失败时会切回原镜像。旧版本可能不兼容当前数据库结构，切换镜像不会撤销数据变更。

## 网络与证书

仅 Caddy 发布 IPv4 TCP **80/443**，主控和数据库不发布宿主机端口。UFW 放行 SSH，网站流量通过 `DOCKER-USER → MMWX-CF` 和 `ipset` 限制为 Cloudflare 来源。

Cloudflare 网段每天自动刷新，获取失败时保留现有集合；Docker 重启前会应用防护规则。

Caddy 与 Cloudflare DNS 模块使用本仓库的 [预编译依赖包](https://github.com/xiangwan6667/mmwx-installer/releases/tag/v0.1.0-rc.1)，提供 AMD64 / ARM64 文件并校验 SHA-256。服务器只组装容器镜像，无需编译 Go；依赖包版本与管理脚本版本分别维护。

## 卸载

| 操作 | 删除内容 | 保留内容 |
| --- | --- | --- |
| 菜单 8 → 保留数据（默认） | 容器、本项目防火墙规则及定时任务 | 项目目录、备份、Token 和管理命令，可用菜单 5 恢复 |
| 菜单 8 → 完全卸载 | 上述内容，以及项目目录、备份、Token、管理命令和后台程序 | Docker、系统网络/时区设置及 Cloudflare DNS 记录 |
| 菜单 9 → 卸载管理脚本 | `mmwx` 管理入口 | 容器、数据和后台防火墙程序，继续提供重启防护及网段刷新 |

两种服务卸载方式均保留系统 SSH/UFW/IPv6/时区设置和 Cloudflare DNS 记录。完全卸载会再次确认删除数据；仅卸载管理脚本后，重新执行安装命令即可恢复管理入口。

## 常见问题

**安装或更新失败，如何继续？** 重新运行 `mmwx`，选择菜单 5。耗时步骤的完整日志保存在 `state/logs/`，失败时会显示日志路径。

**证书失败或出现 Cloudflare 522？** 先查看菜单 4：证书问题检查 Token 权限、域名 Active 状态与 Full (strict)；522 检查安全组、源站 IPv4 和服务状态。

**能否无人值守安装？** `--yes` 只跳过全新环境提示。仍须在五分钟内从另一 IPv4 SSH 连接执行 `sudo mmwx confirm-network`；其他参数见 `mmwx --help`。

## 反馈与贡献

欢迎通过 [Issues](https://github.com/xiangwan6667/mmwx-installer/issues) 反馈问题，或提交 [Pull Request](https://github.com/xiangwan6667/mmwx-installer/pulls)。反馈时附上系统版本、架构、脚本版本及相关日志，并移除 Token、密码和业务信息。

[查看发布记录](https://github.com/xiangwan6667/mmwx-installer/releases) · [查看自动检查](https://github.com/xiangwan6667/mmwx-installer/actions) · [妙妙屋 X 上游项目](https://github.com/iluobei/miaomiaowuX)
