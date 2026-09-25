# 妙妙屋 X 安装器

通过 Docker Compose 部署妙妙屋 X、PostgreSQL 18 和 Caddy。自动创建 Cloudflare DNS 记录、签发证书，并限制网站仅接受 Cloudflare 回源。

当前为预发布版，建议先在测试环境使用。

## 安装条件

- 全新 Debian 12/13 或 Ubuntu 22.04/24.04/26.04，AMD64 / ARM64。
- root 权限、独立公网 IPv4；建议 2 GB 内存、10 GB 可用磁盘。
- 主域名已托管到 Cloudflare，区域状态为 **Active**，SSL/TLS 模式为 **完全（严格）**。
- [Cloudflare API Token](https://dash.cloudflare.com/profile/api-tokens) 具备该域名的 **Zone Read** 和 **DNS Edit** 权限。
- 云厂商安全组允许 SSH，以及 Cloudflare 访问 TCP 80/443。

安装会启用 UFW、关闭 IPv6，并将服务器及容器时区设为 `Asia/Shanghai`。请通过 IPv4 SSH 操作。

## 安装

以 root 用户执行（首次运行会安装下载依赖）：

```bash
apt-get update && apt-get install -y ca-certificates curl && \
curl -fsSL https://raw.githubusercontent.com/xiangwan6667/mmwx-installer/main/install.sh -o mmwx-install.sh && \
bash mmwx-install.sh
```

选择 **1**，按提示输入 Token、选择主域名和版本。子域名前缀默认 `mmwx`，回车即可；DNS 记录和小黄云由脚本创建。同名记录冲突时停止，不覆盖已有配置。

网络设置完成后，另开终端重新登录 SSH，再确认连接正常。五分钟未确认会恢复原网络设置。

安装成功后访问显示的 HTTPS 地址。**数据库由环境变量管理，无需勾选「使用 PG 数据库」。**

## 管理

```bash
sudo mmwx
```

root 用户直接运行 `mmwx`。

| 菜单 | 用途 |
| --- | --- |
| 1 | 安装 / 继续安装 |
| 2 | 更新主控版本 |
| 3 / 4 | 状态 / 日志 |
| 5 | 继续中断任务 / 恢复服务 |
| 6 | 卸载：保留数据或完全卸载 |
| 7 | 确认新 SSH 连接 |
| 8 | 更新管理脚本 |
| 9 | 回退主控容器版本 |

安装和更新支持最新正式版、最新 Beta，或从最近 **5 个发布版本**中选择。GitHub API 不可用时自动读取官方发布网页；对应镜像尚未发布时会停止。

更新前会备份数据库和应用文件；更新失败或中断后的恢复会还原这份备份。菜单 **9** 是独立的手动回退：从更新历史选择主控镜像，**不还原数据库和文件**。旧版本可能不兼容已升级的数据库结构。

旧版没有菜单 8 时，重新下载脚本并运行一次，选 **5** 应用新版配置。安装中断则选 **1**。

## 数据与卸载

数据通过宿主机目录挂载持久化，重建容器不会清空。

| 目录（位于 `/opt/mmwx-installer`） | 内容 |
| --- | --- |
| `config/` | Compose、环境变量、Caddy 配置及 Token |
| `data/postgres/` | PostgreSQL 数据 |
| `data/app/`、`data/subscribes/`、`data/rule_templates/` | 应用文件 |
| `certs/` | 证书及 Caddy 状态 |
| `backups/` | 更新前备份 |
| `state/` | 安装进度、版本记录及网络恢复配置 |

旧版目录会在恢复服务时自动整理，迁移期间短暂停止容器，原有数据直接迁移，不重新初始化。

- **保留数据**：移除容器及本项目防火墙规则，保留数据和管理命令；菜单 5 可恢复。
- **完全卸载**：同时删除上述目录、备份、保存的 Token 和管理命令，需再次确认。

两种模式均保留 Docker、系统 SSH/UFW/IPv6/时区设置及 Cloudflare DNS 记录。持久化不等于备份，重要数据请另存到其他机器。

## 网络

仅 Caddy 发布 IPv4 TCP 80/443，主控和数据库不发布宿主机端口。

Cloudflare 网段统一存入 `ipset`，由 `DOCKER-USER → MMWX-CF` 链过滤容器流量。UFW 保留 SSH 放行和默认入站拒绝，不再逐条列出 CF 网段。旧规则在更新主控或恢复服务时自动清理；CF 网段每天刷新，获取失败保留现有集合。

证书失败时先查看菜单 4，检查 Token 权限、域名托管状态和 Full (strict) 设置。Cloudflare 522 则检查安全组与源站 IPv4。对外提供日志前，请移除 Token、密码和业务信息。
