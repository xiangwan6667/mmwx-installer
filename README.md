# 妙妙屋 X 全新服务器安装器

**仅限全新服务器。安装会启用 UFW、关闭全机 IPv6，并限制网页端口只能由 Cloudflare 访问。请通过 IPv4 SSH 操作。**

独立 Bash 安装器，使用官方妙妙屋 X Docker 镜像。适合只承载管理面板的服务器：Caddy → 妙妙屋 X → PostgreSQL 18。容器通过 Docker bridge 通信，应用端口和数据库端口均不发布到宿主机。Xray 节点应部署在远程 Agent 上。

## 安装前准备

1. 准备 Debian 12/13 或 Ubuntu 22.04/24.04/26.04，AMD64/ARM64，root 权限及可用公网 IPv4。建议至少 2 GB 内存、10 GB 空闲磁盘。Caddy 模块在发布前预编译，服务器下载并校验产物后组装镜像，无需编译 Go。
2. 将主域名托管到 [Cloudflare](https://dash.cloudflare.com/)：添加域名，并在域名注册商处将 NS 改成 Cloudflare 分配的两条地址。等待区域状态为 **Active**。仅在 Cloudflare 添加站点而不修改 NS，不能签发证书。
3. 在该区域的 SSL/TLS → 概述选择 **完全（严格）/ Full (strict)**。
4. 打开 [API Token 页面](https://dash.cloudflare.com/profile/api-tokens)，选择创建令牌 → 自定义令牌。权限添加 `Zone / DNS / Edit` 与 `Zone / Zone / Read`；区域资源只选托管的主域名。不要使用 Global API Key。Token 用于签发和自动续期，安装完成后仍需保留其有效性。
5. 准备面板子域名，例如 `panel.example.com`。脚本通过 API 创建 A 记录并开启小黄云。同名记录完全匹配时复用；遇到不同 IP、AAAA 或 CNAME 时停止并解释，不覆盖现有记录。
6. 云厂商安全组也要允许当前 SSH 端口，以及 Cloudflare 回源访问 TCP 80/443。本脚本只能管理服务器内部防火墙。

## 运行

在目标服务器终端执行：

```bash
curl -fsSL https://raw.githubusercontent.com/xiangwan6667/mmwx-installer/main/install.sh -o mmwx-install.sh
sudo bash mmwx-install.sh
```

按菜单选择安装，输入域名、Token 和版本通道。Token 输入不会显示。脚本实时查询 GitHub Releases，显示最新正式版和 Beta 的版本号与发布时间；镜像未发布时明确失败，不退回 `latest`。镜像下载后固定 digest。

启用 UFW 后，**另开一个终端，重新通过 IPv4 SSH 登录**，再按提示确认。五分钟内未确认会自动恢复之前的网络配置，安装不会继续。

安装完成后打开面板 HTTPS 地址，按妙妙屋 X 初始化向导创建管理员。无需在面板中再次部署 Nginx 或 HTTPS 证书，证书由 Caddy DNS-01 管理。80 只用于 HTTPS 跳转，443 提供面板，均只接受 Cloudflare IPv4 回源。

## 参数与维护

```bash
# 只读预检
sudo bash mmwx-install.sh check

# 指定输入（Token 文件必须属于 root，权限 600）
sudo bash mmwx-install.sh install --domain panel.example.com --channel stable --cf-token-file /root/mmwx-cloudflare.token

# 更新默认沿用已保存通道；也可明确选择
sudo mmwx-installer update --channel stable
sudo mmwx-installer update --channel beta

sudo mmwx-installer status
sudo mmwx-installer logs
sudo mmwx-installer uninstall
sudo mmwx-installer resume
```

`--yes` 用于受控自动化：跳过全新环境确认，但仍须在五分钟内从新的 IPv4 SSH 会话执行 `sudo mmwx-installer confirm-network`。没有此确认，部署会停止并回退网络。

更新先停面板、备份 PostgreSQL 和应用文件，然后切换版本。失败时重建应用数据库并还原备份，保留失败版本的文件用于排查。跨版本数据库降级不保证兼容，请谨慎从 Beta 切回较旧正式版。PostgreSQL 主版本保持 18，不执行数据库大版本升级。

卸载停止并移除本项目容器，删除本项目网页过滤规则和定时任务；保留 `/opt/mmwx-installer` 数据、Docker、SSH 规则、UFW 启用状态和 IPv6 禁用设置。`resume` 复用保留数据恢复服务。卸载不会删除 Cloudflare DNS 记录。

## 防火墙与排错

Docker 发布端口会绕过普通 UFW INPUT 规则，因此同时维护 `DOCKER-USER` 过滤链。过滤规则会在 Docker 启动前建立；每日从 Cloudflare 官方 IPv4 列表更新，下载或验证失败保留原规则。只发布 IPv4 TCP 80/443，PostgreSQL 与面板没有宿主机端口映射。

- 提示非全新环境：使用干净服务器，不要为了绕过检查而删除未知项目。
- 区域读取失败：确认 NS 已生效、区域 Active、Token 有 Zone Read 权限且授权了正确区域。
- DNS 创建失败：检查 DNS Edit 权限与同名记录。
- 证书失败：检查 Caddy 日志、Token 是否过期、域名是否托管成功、服务器是否能访问 Cloudflare API 和 ACME 服务。
- 访问循环跳转：Cloudflare 必须使用 Full (strict)，不能用 Flexible。
- Cloudflare 522：检查安全组和回源 IP，执行 `sudo mmwx-installer firewall-sync`，再检查 `journalctl -u mmwx-cf-sync.service`。
- 日志可能包含业务信息；对外提交前请自行脱敏，不要公开 Token、env 文件和数据库备份。

## 开发验证

```bash
bash -n install.sh
shellcheck install.sh tests/*.sh
sudo bash tests/test.sh
sudo bash tests/lifecycle.sh
```

`tests/smoke.sh` 仅供指定的可丢弃测试机使用，测试正式版和 Beta 的 PostgreSQL + Caddy bridge 部署。真实 DNS-01、Cloudflare 回源及 SSH/防火墙测试需要授权的服务器和测试域名，不能由静态检查代替。
