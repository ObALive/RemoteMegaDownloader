# MEGA 视频转存分发任务 — 完整归档

> 归档时间：2026-10-06 09:56 (Asia/Shanghai)
> 归档目的：完整记录执行流程、全部踩坑、复跑方法
> 状态：**进行中，卡在 MEGA 下载配额**

---

# 一、任务总览

## 1.1 目标链条

```
他人分享链接  ──导入──▶  你的 MEGA 云盘（中转区）
                              │
                              ├──▶ 每个视频生成一条独立分享链接 ──▶ 交付给你
                              │
                              └──▶ VPS 下载（匿名，走公开链接）──▶ 校验完整性
                                                                      │
                                          确认无误后清空中转区 ◀───────┘
                                                    │
                                              处理下一批（循环）
```

## 1.2 三个参与方

| 角色 | 位置 | 职责 |
|---|---|---|
| **控制端** | 本机 `ob-alive@…` | 账号操作（导入/导出/删除）、编排、校验 |
| **下载端** | VPS `root@43.228.217.193` | 用 MEGAcmd 下载公开链接到本地磁盘 |
| **存储端** | MEGA 账号 `904308289@qq.com` | 中转区 + 生成分享链接 |

## 1.3 为什么这样分工

- 云盘容量有限 → 用"导入→出链→下载→清理"的批次循环周转
- 下载放到 VPS → 不占本机带宽，且 VPS 磁盘 348G 充裕
- 心跳推送 → 避免反复 SSH 轮询浪费上下文

---

# 二、环境清单

## 2.1 本机（控制端）

| 项 | 值 |
|---|---|
| 系统 | Ubuntu 26.04 LTS (resolute), x86_64 |
| MEGAcmd | **2.6.0.2（免 root 解包安装）** |
| 安装位置 | `~/.local/megacmd/` |
| 命令入口 | `~/.local/bin/mega-*`（71 个 wrapper，已在 PATH） |
| sshpass | `~/.local/bin/sshpass`（同样免 root 解包自 `sshpass_1.10`） |
| 凭据 | `~/.ssh/vps_pass`（600） |

### 本机 MEGAcmd 为什么需要 wrapper

官方 deb 里的二进制 `RUNPATH` 被硬编码为 `/opt/megacmd/lib`，无 root 无法创建该目录。
因此每个 `mega-*` 都是薄 wrapper：

```bash
#!/bin/bash
export LD_LIBRARY_PATH="$HOME/.local/megacmd/root/opt/megacmd/lib:$HOME/.local/megacmd/libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$HOME/.local/megacmd/root/usr/bin/mega-xxx" "$@"
```

- 库来源：deb 自带 ffmpeg 库 + 补装的 `libfuse.so.2`
- 重新生成：`~/.local/megacmd/setup-launchers.sh`

## 2.2 VPS（下载端）

| 项 | 值 |
|---|---|
| 地址 | `43.228.217.193`，root |
| 系统 | Ubuntu 22.04.1 LTS, x86_64 |
| 配置 | 8 核 / 15G 内存 / 348G 磁盘（可用 ~314G） |
| MEGAcmd | 2.6.0.2，**系统级安装在 `/usr/bin`** |
| 下载目录 | `/root/megadl/` |
| 承载方式 | **tmux 会话 `megadl`** |

## 2.3 MEGA 账号

| 项 | 值 |
|---|---|
| 邮箱 | `904308289@qq.com` |
| 等级 | 免费（Pro level 0） |
| 总容量 | 25 GB（26,843,545,600 字节） |
| 已用 | 19.27 GB（71 文件 / 37 目录） |
| 剩余 | 5.73 GB |
| ⚠️ 密码 | **未落盘**，需现填（见 §7.2） |

---

# 三、目录与文件清单

## 3.1 本机 `~/.local/megacmd/work/`

| 文件 | 作用 |
|---|---|
| **`ARCHIVE.md`** | 本文档 |
| `PLAN.md` | 批次导入导出方案（阶段0/阶段N/阶段R） |
| `BLOCKER_quota.md` | 配额阻塞的实测记录与选项 |
| **`bootstrap.sh`** | 一键复跑入口 |
| **`vps.sh`** | SSH 到 VPS 的封装（用 sshpass + 凭据文件） |
| **`dl_round.sh`** | **VPS 侧**下载脚本（配额感知+卡死检测+重试） |
| **`heartbeat.sh`** | **VPS 侧**心跳发生器（推 JSON 到 stdout） |
| **`listen.sh`** | **本机侧**心跳监听器（长连接接收+解析+终止信号） |
| `round01_manifest.tsv` | 第 1 轮下载清单：`文件名⇥字节数⇥链接` |
| `links.tsv` | 第 1 轮 12 条的完整记录：`句柄⇥字节⇥链接⇥路径` |
| `mega_video_links.{md,txt,csv}` | 第 1 轮交付给你的链接文件 |
| `all_files.txt` / `videos.tsv` | 云盘全量文件 / 视频筛选结果 |
| `export_videos.sh` | 批量导出链接的脚本 |
| `state/processed_files.tsv` | **已存文件列表（防重）** |
| `vps_status.txt` | 心跳解析后的可读状态（实时刷新） |
| `vps_status.json` | 最新原始心跳 |
| `vps_signal.txt` | 终止信号：`DONE`/`ERROR`/`INTERRUPTED` |
| `vps_heartbeat.history` | 心跳历史 |
| `listen.log` | 监听器连接日志 |

## 3.2 VPS `/root/megadl/`

| 路径 | 作用 |
|---|---|
| `dl_round.sh` | 下载脚本 |
| `heartbeat.sh` | 心跳脚本 |
| `round01_manifest.tsv` | 第 1 轮清单 |
| `round01/` | 第 1 轮下载目录 |
| `round01/runner.log` | 下载主日志 |
| `round01/download.log` | 逐步日志 |
| `round01/status.tsv` | 每个文件的结果 |
| `round01/.quota_wait` | **存在=正在等配额** |
| `round01/heartbeat.json` | 最新心跳落盘 |
| `round01/.getxfer.*.mega` | 在传临时文件 |

## 3.3 状态文件 schema

`state/processed_files.tsv`（制表符分隔，9 列）：

```
name  size_bytes  source_path  source_handle  source_ref  batch  status  output_link  processed_at
```

- 去重键：`source_handle` 精确匹配优先，跨来源回退 `name` + `size_bytes`
- `status`：`done` / `imported` / `failed` / `skipped`

---

# 四、完整执行流程

## 阶段 0：环境准备（一次性）

```bash
# 1) 本机准备凭据
umask 077; printf '%s' '<VPS密码>' > ~/.ssh/vps_pass; chmod 600 ~/.ssh/vps_pass

# 2) 装 sshpass（免 root）
apt-get download sshpass && dpkg-deb -x sshpass_*.deb ./x && cp ./x/usr/bin/sshpass ~/.local/bin/

# 3) 本机装 MEGAcmd（免 root 解包式）
curl -L -o megacmd.deb https://mega.nz/linux/repo/xUbuntu_24.04/amd64/megacmd-xUbuntu_24.04_amd64.deb
dpkg-deb -x megacmd.deb ~/.local/megacmd/root
apt-get download libfuse2t64 && dpkg-deb -x libfuse2t64_*.deb ~/.local/megacmd/libs
cp ~/.local/megacmd/libs/usr/lib/x86_64-linux-gnu/libfuse.so.2* ~/.local/megacmd/libs/
~/.local/megacmd/setup-launchers.sh        # 生成 71 个 wrapper 到 ~/.local/bin

# 4) VPS 准备
./vps.sh 'apt-get install -y tmux'
scp dl_round.sh heartbeat.sh root@43.228.217.193:/root/megadl/
```

## 阶段 1：清点云盘 + 建立已存列表

```bash
export PATH="$HOME/.local/bin:$PATH"
mega-login '904308289@qq.com' '<密码>'
mega-df                                              # 空间用量
mega-find / --type=f --show-handles > all_files.txt  # 全量文件（含句柄）
grep -iE '\.(mp4|mkv|avi|mov|wmv|flv|webm|m4v|ts|mpg|mpeg|rmvb|3gp|m2ts|vob) <H:' all_files.txt > videos.tsv
```

## 阶段 2：生成分享链接（每个文件一条）

```bash
mega-export -a "/路径/文件.mp4"     # 若已导出会报错，改用下面这条取回
mega-export    "/路径/文件.mp4"     # 读取已存在的导出链接
```

批量脚本见 `export_videos.sh`（含已存在链接的复用、限流 sleep、失败兜底）。

## 阶段 3：VPS 下载（核心循环）

```bash
# 生成清单（文件名⇥字节数⇥链接）
awk -F'\t' '{n=split($4,p,"/"); printf "%s\t%s\t%s\n", p[n], $2, $3}' links.tsv > round01_manifest.tsv
scp round01_manifest.tsv root@43.228.217.193:/root/megadl/

# 在 tmux 中启动（关键：不能用裸 SSH 后台，会挂住会话）
./vps.sh 'tmux kill-session -t megadl 2>/dev/null
tmux new-session -d -s megadl "QUOTA_WAIT=1800 MAX_QUOTA_WAIT=24 \
  bash /root/megadl/dl_round.sh /root/megadl/round01 /root/megadl/round01_manifest.tsv \
  >> /root/megadl/round01/runner.log 2>&1"'
```

## 阶段 4：心跳监听（本机，替代反复 SSH）

```bash
./listen.sh /root/megadl/round01 /root/megadl/round01_manifest.tsv 20 8
#  参数: round_dir  manifest  心跳间隔秒  最大重连次数
#  作为 DSH 后台任务运行；仅在 DONE/ERROR/INTERRUPTED 时结束并通知
```

**心跳字段**（`vps_status.json`）：

```json
{"ts","state","runner","total","completed","skipped","failed",
 "quota_exceeded","quota_waiting","current","current_pct",
 "done_bytes","total_bytes","free_gb","last"}
```

**状态机**：

| state | 含义 | 是否终止 |
|---|---|---|
| `DOWNLOADING` | 正常下载中 | 否 |
| `QUOTA_WAIT` | 撞配额，休眠等待中 | **否（关键）** |
| `DONE` | 全部完成 | ✅ 终止 |
| `ERROR` | runner 停止但未完成 / 配额放弃 | ✅ 终止 |
| `INTERRUPTED` | 检测到 `/root/megadl/STOP` | ✅ 终止 |

## 阶段 5：完整性确认后清空中转区

```bash
# ⚠️ 两步删除，缺一不可（第一步只进回收站，照样占空间）
mega-rm -r -f /staging/<文件名>
mega-rm -r -f "//bin/<文件名>"      # 第二步才真正释放
mega-df                              # 复核空间已释放
```

---

# 五、⚠️ 踩坑清单（最重要的一节）

## 🔴 P1 — `mega-cancel` 是**注销整个账号**，不是取消传输

**这是本次最危险的一次误操作。**

| 命令 | 实际作用 |
|---|---|
| `mega-cancel` | ❌ **注销整个 MEGA 账号** |
| `mega-transfers -c <TAG>` | ✅ 取消传输 |
| `mega-transfers -c -a` | ✅ 取消全部传输 |

**查证结果**（MEGA 官方 SDK `megaapi.h`）：

- `cancelAccount()` → 请求类型 `TYPE_GET_CANCEL_LINK`，官方原文：
  *"a cancellation link will be sent to the email address of the user"*
  → **不改变账号任何状态**，只是发一封注销确认邮件
- `confirmCancelAccount(link, pwd)` → 真正删除，需要**邮件链接 + 账号密码**
- 所以误触的后果 = 邮箱里多一封邮件，**不要点那封邮件的链接**即可

> **规则：永远不要执行 `mega-cancel`、`mega-confirmcancel`、`mega-passwd`。**

## 🔴 P2 — `pkill -f <pattern>` 会把自己的 SSH 会话杀掉

`pkill -f dl_round.sh` 会匹配到**承载该命令的 `bash -c` 自身**（它的命令行里含这个字符串），
于是自杀，命令输出被截断，看起来像"莫名其妙断线"。

**正确做法（三选一）**：
```bash
pkill -x mega-cmd-server        # 按进程名精确匹配
pgrep -f "[d]l_round"           # 括号技巧（命令行里不能出现裸 'dl_round'）
kill <PID>                      # 先 pgrep 拿 PID 再 kill
```
⚠️ 括号技巧**仅在整条命令里没有其它裸 pattern 时有效**——例如命令里还有
`chmod +x /root/megadl/dl_round.sh` 就会失效。

## 🔴 P3 — 裸 SSH 启动后台任务会挂住会话

`ssh host 'nohup cmd &'` 之后 SSH 常常不返回：MEGAcmd 会拉起 `mega-cmd-server`，
子进程继承了通道的 fd，SSH 要等所有 fd 关闭才断开。

**正确做法：用 tmux 承载**
```bash
tmux new-session -d -s megadl "bash /root/megadl/dl_round.sh ... >> log 2>&1"
```
SSH 立即返回，断开也不影响下载。

## 🔴 P4 — 删除文件 = 分享链接**立即失效**

分享链接指向的就是文件本身。删掉 → 链接死。
所以循环节奏必须是：**先确认对方已下载完，再删**。

## 🔴 P5 — `mega-rm` 只进回收站，**仍然占用空间**

`mega-df` 里回收站是独立一行且计入总量。必须再删一次 `//bin/<名字>` 才真正释放。
（MEGA SDK 语义：删除已在回收站里的节点 = 永久删除。）

## 🟡 P6 — 深层链接可以只导入**文件夹链接里的单个文件**

`src/megacmdcommonutils.cpp:127` 的 `getPublicLinkHandle()` 明确解析：

```
https://mega.nz/folder/<文件夹句柄>#<密钥>/file/<文件句柄>     → 单个文件
https://mega.nz/folder/<文件夹句柄>#<密钥>/folder/<子目录句柄>  → 子目录
```

这是"分批导入"能成立的前提。

## 🟡 P7 — `mega-import` **不需要登出**个人账号

`src/megacmdexecuter.cpp:9934` 起：文件夹链接由**独立辅助 API 实例**（`apiFolder_0..4`）登录，
再 `api->copyNode()` 服务端复制。个人账号全程保持登录。
（辅助实例不够时用 `mega-configure` 调 `exported_folders_sdks`。）

## 🟡 P8 — MEGA 免费下载配额 ≈ **5GB / 窗口**

实测：下满约 5.3GB 后被拒。报错原文：

```
You have reached your bandwidth quota. ... Alternatively, you can try again in 5 hours.
Use --ignore-quota-warn to initiate nevertheless
```

**关键结论（实测）**：
- 匿名（未登录）下载 → 受限
- **登录成免费账号后下载自己账号内的文件 → 同样受限**
- `--ignore-quota-warn` → **无效**，服务端仍拒绝（`Error starting request: -11`）
- 等待 9 小时后 **仍未恢复**（只漏过约 165MB）

## 🟡 P9 — 客户端被 kill 后，**server 会继续把传输跑完**

`timeout 30 mega-get <link>` 杀掉的是命令行客户端；`mega-cmd-server` 是独立进程，
传输会继续并在后台完成。
→ 这解释了"为什么莫名多出一个已完成的文件"，也意味着**看进度要看 `.getxfer` 或 `mega-transfers`，不能只看客户端输出**。

## 🟡 P10 — **链接句柄 ≠ 节点句柄**（我犯过）

| 类型 | 例子 | 用在哪 |
|---|---|---|
| 节点句柄 | `H:Wb52WYSY` | `mega-ls --show-handles`、`mega-find` |
| **链接句柄** | `/file/aGJDxYwK#slGr...` | **公开链接 URL 里用的** |

用节点句柄拼 URL 会得到 `Failed to get public node: Not found`。

## 🟢 P11 — 重复下载同名文件会产生 `(1)` 后缀

同一文件下两次 → `SD41 full uncen (1).mp4`，白占空间。收尾时要检查并清理。

## 🟢 P12 — 配额提示里的秒数可能是**负数**

见过 `try again in -12619 seconds`：客户端缓存的截止时间已过期，服务端仍拒绝，两边不一致。
→ 不能只信这句话，要用实际下载测试判断。

## 🟢 P13 — 本机 PATH 已经包含 `~/.local/bin`

`~/.bashrc` 与 `~/.profile` 都已处理，新开终端直接可用 `mega-*`，无需额外配置。

---

# 六、当前进度与断点

## 6.1 第 1 轮（12 个视频）

| 状态 | 数量 | 明细 |
|---|---|---|
| ✅ 已下载并校验 | **4** | SD39 stelle ver full / SD39 full video / SD40 full / SD41 full uncen |
| ⏳ 待下载 | 8 | SD42 / SD43 / SD44 / SD45 / SD46×2 / SD47 / SD48 |

- 已下载合计：**5,882,677,159 字节（5.48 GB）**
- 剩余：约 **11.5 GB**
- 校验方式：逐文件比对字节数与清单完全一致

## 6.2 现场状态（归档时刻）

| 项 | 状态 |
|---|---|
| VPS tmux `megadl` | 运行中，`QUOTA_WAIT`（等配额，30min×24 ≈ 12h 窗口） |
| 本机监听器 | 运行中（DSH 后台任务） |
| MEGA 账号 | 本机已登录；VPS 已登出（用匿名下载） |
| 阻塞 | MEGA 下载配额未恢复 |

## 6.3 依据的配额窗口推算

| 时间 | 事件 | 字节 |
|---|---|---|
| 00:09 | 你自己测试下载 | 1.41 GB |
| 00:16 | SD39 stelle | 1.41 GB |
| 00:17 | SD40 | 1.49 GB |
| 00:18 | SD41 下到 67% 卡死（配额耗尽，连接被静默切断） | ~1.03 GB |
| | **累计触发上限** | **≈ 5.3 GB** |

---

# 七、复跑指引

## 7.1 一键检查当前状态（不连 SSH）

```bash
cd ~/.local/megacmd/work
cat vps_status.txt            # 可读状态
cat vps_signal.txt            # 终止信号（空=仍在跑）
tail -5 vps_heartbeat.history # 心跳历史
```

## 7.2 凭据准备（**密码不落盘**）

```bash
# VPS 密码（唯一持久化的凭据，600 权限）
umask 077; printf '%s' '<VPS密码>' > ~/.ssh/vps_pass; chmod 600 ~/.ssh/vps_pass

# MEGA 密码：仅在需要时通过环境变量传入，不写文件
export MEGA_USER='904308289@qq.com'
read -rsp 'MEGA 密码: ' MEGA_PASS; echo
mega-login "$MEGA_USER" "$MEGA_PASS"
```

> **安全约定**：MEGA 密码不写入任何文件。此前它曾因一条失败命令被回显进
> `~/.megaCmd/megacmdserver.log`，已清除并把该日志权限收紧为 600。
> 注意 DSH 的会话存档里仍会有对话原文。

## 7.3 断点续跑（配额恢复后）

脚本**天生可重入**：已存在且字节数正确的文件会被跳过。

```bash
cd ~/.local/megacmd/work
./vps.sh 'tmux kill-session -t megadl 2>/dev/null
tmux new-session -d -s megadl "QUOTA_WAIT=1800 MAX_QUOTA_WAIT=24 \
  bash /root/megadl/dl_round.sh /root/megadl/round01 /root/megadl/round01_manifest.tsv \
  >> /root/megadl/round01/runner.log 2>&1"'

rm -f vps_signal.txt vps_heartbeat.history
./listen.sh /root/megadl/round01 /root/megadl/round01_manifest.tsv 30 20 &
```

## 7.4 可调参数

| 脚本 | 环境变量 | 默认 | 含义 |
|---|---|---|---|
| `dl_round.sh` | `STALL_SECS` | 90 | 多少秒无字节增长算卡死 |
| | `MAX_TRY` | 3 | 单文件普通重试次数 |
| | `QUOTA_WAIT` | 1200 | 撞配额后休眠秒数 |
| | `MAX_QUOTA_WAIT` | 30 | 最多等多少次配额 |
| `listen.sh` | 第3参数 | 10 | 心跳间隔秒 |
| | 第4参数 | 8 | SSH 最大重连次数 |

## 7.5 开启下一轮（第 2 轮及以后）

1. `mega-find` 枚举新分享链接 → 筛视频 → 与 `state/processed_files.tsv` 去重
2. 按 `min(19.5GB, 当前可用−0.3GB)` 装箱分批
3. 逐个 `mega-import "<深层链接>/file/<句柄>" /staging/`
4. 逐个 `mega-export -a` 生成链接
5. 生成新 `roundNN_manifest.tsv`，重复阶段 3~5
6. **确认下载完再清空** `/staging/`

## 7.6 中断/停止

```bash
./vps.sh 'touch /root/megadl/STOP'      # 心跳检测到 → INTERRUPTED（非破坏性）
./vps.sh 'tmux kill-session -t megadl'  # 硬停
./vps.sh 'mega-transfers -c -a'         # 清传输队列
```

---

# 八、已知限制与后续选项

| 限制 | 影响 | 选项 |
|---|---|---|
| 免费配额 ~5GB/窗口 | 第 1 轮剩 11.5GB 需 ≥3 个窗口 | ①自动等待续传 ②升级 Pro ③增加出口 IP |
| 配额无法查询 | 只能靠试探 | 网页端账号页可看剩余传输配额 |
| Ubuntu 26.04 非官方支持组合 | 核心功能已验证正常 | 属非官方组合，留意异常 |
| 单文件 > 可用空间 | 永远装不下 | 提前算出并单独报告 |
| 源链接被撤销 | 任务中断 | 状态文件支持断点续做 |

---

# 九、命令白名单（安全约定）

**允许使用**：
`mega-login` `mega-logout` `mega-whoami` `mega-df` `mega-ls` `mega-find` `mega-tree`
`mega-import` `mega-export` `mega-get` `mega-put` `mega-mkdir` `mega-rm` `mega-mv` `mega-cp`
`mega-transfers` `mega-session` `mega-help` `mega-version` `mega-webdav`

**绝对禁止**：
`mega-cancel`（注销账号）、`mega-confirmcancel`（确认注销）、`mega-passwd`（改密码）、
`mega-killsession`（杀会话）——除非用户明确逐条书面要求。
