# MEGAcmd 2.6.0 — 本机免 root 安装说明

## 结论：可用 ✅

实测确认（2026-10-05）：

| 检查项 | 结果 |
|---|---|
| 二进制能否运行 | ✅ `mega-cmd` / `mega-cmd-server` / `mega-exec` 全部正常 |
| 动态库依赖 | ✅ 全部解析（`ldd` 无 `not found`） |
| 后台 server 自动拉起 | ✅ 第一条命令即自动启动 `mega-cmd-server` |
| 客户端 ←→ server IPC | ✅ `whoami` / `help` / `version` 均正常返回 |
| 到 MEGA 服务器的登录链路 | ✅ 用不存在的账号实测，返回 MEGA 的认证错误（而非网络错误），说明请求真实到达了 MEGA 认证服务器 |
| 交互式 shell | ✅ 正常 |

---

## 安装来源与方式

- 包：官方 `megacmd-xUbuntu_24.04_amd64.deb`，版本 `2.6.0-2.1`
  来源 `https://mega.nz/linux/repo/xUbuntu_24.04/amd64/`
- 本机是 **Ubuntu 26.04 (resolute)**，MEGA 官方没有对应版本的仓库，且当前用户**没有 root/sudo 权限**，因此采用"解包式安装"，不改动系统目录。

### 目录布局

```
~/.local/megacmd/
├── root/                      # deb 解包内容
│   ├── usr/bin/               #  71 个真实程序（mega-cmd、mega-cmd-server、mega-exec …）
│   └── opt/megacmd/lib/       #  自带 ffmpeg 库（libavcodec/libavformat/libswscale/libavutil）
├── libs/                      # 补装的 libfuse.so.2（deb 依赖，但系统与包内都没有）
├── setup-launchers.sh         # 生成 wrapper 的脚本，升级后重跑即可
└── README.md                  # 本文件
```

### 为什么要 wrapper

程序内 `RUNPATH` 被硬编码为 `/opt/megacmd/lib`，而无 root 无法创建该目录。
因此 `~/.local/bin/` 下的 71 个 `mega-*` 都是薄 wrapper，用 `LD_LIBRARY_PATH`
指向解包出来的库，再 `exec` 真实二进制。

`~/.local/bin` 已在你的 `~/.bashrc` 与 `~/.profile` 中，**新开的终端可直接使用，无需任何额外配置**。

---

## 怎么登录

### 方式一：交互式（推荐，密码不回显）

```bash
mega-cmd
```
进入 `MEGA CMD>` 提示符后：
```
login your@email.com
```
会提示 `Enter password:`，输入时不回显。若账号开了二次验证（2FA），会继续提示输入验证器验证码。

### 方式二：脚本 / 非交互式

```bash
mega-login your@email.com 'yourpassword'
```

开了 2FA 的账号，把验证码一起给出（否则非交互模式下会报参数不足）：

```bash
mega-login --auth-code=123456 your@email.com 'yourpassword'
```

> ⚠️ 命令行传密码会进入 shell 历史与进程列表（`ps`）。介意的话请用交互式 `mega-cmd`。

### 登录非账号目标

```bash
# 公开文件夹链接
mega-login 'https://mega.nz/folder/xxxxxxxx#yyyyyyyy'

# 带密码的链接
mega-login 'https://mega.nz/folder/xxxxxxxx#yyyyyyyy' --password=链接密码

# 可写权限的文件夹链接
mega-login 'https://mega.nz/folder/xxxxxxxx#yyyyyyyy' --auth-key=写入密钥
```

### 登录后确认

```bash
mega-whoami          # 查看当前登录用户
mega-df              # 查看空间用量
mega-ls              # 列云端文件
```

---

## 会话（session）持久化

- 登录后的会话、缓存、同步配置都保存在 `~/.megaCmd/`。
- **关闭终端或重启 server 都不需要重新登录**，与 MEGA 桌面版行为一致。
- `mega-logout` 退出并清理；`mega-logout --keep-session` 保留会话数据。
- `mega-session` 可打印 session ID，之后用 `mega-login <sessionid>` 恢复。

---

## 后台 server 的生命周期（重要）

MEGAcmd 由一个常驻后台进程 `mega-cmd-server` 干活，所有 `mega-*` 命令都只是它的客户端。
第一条命令会自动把它在后台拉起。**退出交互式 shell 时用哪种方式，决定了 server 是否被关掉：**

| 退出方式 | shell | 后台 server |
|---|---|---|
| `Ctrl+D` | 退出 | ✅ 继续运行（已实测验证） |
| `quit --only-shell` / `exit --only-shell` | 退出 | ✅ 继续运行 |
| `quit` / `exit` | 退出 | ❌ **被关闭** |
| `mega-quit` | — | ❌ 被关闭 |

如果你在用 `mega-sync` 同步或 `mega-backup` 备份，**退出时请用 `Ctrl+D` 或 `quit --only-shell`**，
否则后台任务会一起停掉。server 日志：`~/.megaCmd/megacmdserver.log`。

---

## 常用命令速查

| 用途 | 命令 |
|---|---|
| 上传 | `mega-put 本地路径 /云端路径` |
| 下载 | `mega-get /云端路径 本地路径` |
| 列表 | `mega-ls -l /` |
| 建目录 | `mega-mkdir -p /a/b` |
| 移动/改名 | `mega-mv /a /b` |
| 删除 | `mega-rm /a` |
| 空间用量 | `mega-df` |
| 同步 | `mega-sync 本地目录 /云端目录` |
| 备份 | `mega-backup 本地目录 /云端目录` |
| 导出下载链接 | `mega-export -a /云端文件` |
| WebDAV 服务 | `mega-webdav /` |
| 全部命令 | `mega-help` |

任意命令加 `--help` 看详细用法，例如 `mega-put --help`。

---

## 已知限制

1. **无 systemd 服务**：server 由第一条 `mega-*` 命令自动在后台拉起，日志在 `~/.megaCmd/megacmdserver.log`。
2. **`mega-fuse` 挂载未验证**：`/dev/fuse` 存在，但容器环境下挂载可能受限，需要时再测。
3. **非官方支持的发行版组合**：包是给 Ubuntu 24.04 编译的，跑在 26.04 上。已验证核心功能正常（glibc 向后兼容），但属于非官方支持组合。

## 升级 / 卸载

```bash
# 升级：下载新 deb → 重新解包 → 重跑 wrapper 生成脚本
cd ~/.local/megacmd-dl && curl -LO https://mega.nz/linux/repo/xUbuntu_24.04/amd64/megacmd-xUbuntu_24.04_amd64.deb
dpkg-deb -x megacmd-xUbuntu_24.04_amd64.deb ~/.local/megacmd/root
~/.local/megacmd/setup-launchers.sh

# 卸载
rm -rf ~/.local/megacmd ~/.megaCmd ~/.local/bin/mega-*
```

## 关于 ~/MEGAcmd 源码仓库

`~/MEGAcmd` 是 MEGAcmd **2.6.0 的源码**（`sdk` 子模块未初始化），本次**没有编译它**——
直接使用官方预编译包更快且更可靠。源码编译需要 vcpkg 拉取并编译整套依赖
（libcrypto++、libcurl、libsodium…），在本机 2 核 / 2.5G 可用内存的条件下耗时很长。
