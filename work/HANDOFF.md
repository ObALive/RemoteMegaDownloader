# 交接文档 — MEGA 分享链接无人值守下载任务

> 生成时间：2026-10-07 11:30 (Asia/Shanghai)
> 用途：在新对话中继续跟进本任务。**新对话没有上下文，请先完整读完本文。**

---

# 一、一句话概况

在 VPS 上跑了一个 **systemd 托管的无人值守下载器**，把某个 MEGA 分享链接里的
**61 个视频（61.53 GB）** 全部下载到 VPS 本地磁盘。MEGA 免费配额约每 **167 分钟**
开一次窗（每次约 3~7 GB），程序自动探测、抢下、退避、续做。

**当前进度：27/61 完成（35.1%），剩余 34 个 / 39.94 GB，预计还需约 1.4~2 天。**

---

# 二、凭据与访问方式

## VPS
```
ssh root@43.228.217.193
密码: 1qazse432!QAZSE$#@!@
```
- 系统：Ubuntu 22.04 x86_64，8 核 / 15G 内存 / 348G 磁盘（可用 297G）
- 密码已存在本机 `~/.ssh/vps_pass`（600 权限），配合 `sshpass` 使用

## MEGA 账号
```
邮箱: 904308289@qq.com
密码: xxt904308289
等级: 免费（Pro level 0），容量 25 GB
```
> ⚠️ 密码已出现在历史对话中。建议任务结束后改密。

## 本机便捷入口
```bash
~/.local/megacmd/work/vps.sh '<远程命令>'    # 一条命令 SSH 到 VPS
```
它自动用 `~/.ssh/vps_pass` + `sshpass`，无需手输密码。

---

# 三、目标与当前进度

## 源
```
https://mega.nz/folder/I7EUnZ7Q#dXEScojKVZRvZW67oWyVfg
└─ 根目录含 46 个顶层目录（2026-09 / maps / New Year SP / SD1-5 renew … SD48）
└─ 共 313 个文件：200 png + 61 mp4 + 29 txt（另有大量 .zipmod 等）
└─ 视频共 61 个，合计 61.53 GB
```

## 进度快照（2026-10-07 11:30）
```
总计   : 61 个视频 / 61.53 GB
已完成 : 27 个 / 21.59 GB  (35.1%)
剩余   : 34 个 / 39.94 GB
```
- 已完成的 **SD1 ~ SD23 全部下完**（含 New Year SP）
- 缺口：SD6/7/8/9（小文件 9 个）、**SD24~SD38（17 个）**、SD42~SD48（8 个）
- **完整性：已下载 27 个字节数 100% 精确匹配，零损坏、零失败**

---

# 四、系统架构

```
┌─ 本机 ob-alive ────────────────────────────────┐
│  ~/.local/megacmd/       免 root 安装的 MEGAcmd │
│  ~/.local/megacmd/work/  全部脚本、文档、清单    │
│  用途：云盘操作、枚举、生成清单、监控            │
└────────────────┬───────────────────────────────┘
                 │ ssh (sshpass)
┌────────────────▼─ VPS 43.228.217.193 ──────────┐
│  /root/mega_autodl/    ★ 无人值守下载器         │
│    systemd: mega-autodl (enabled, 自启)         │
│    独立 HOME → 独立 mega-cmd-server 实例         │
│  /root/megadl/round01/  旧任务遗留 4 个文件      │
│  /root/mdl_v18_isolated/  MegaDownloader 分析沙箱│
└────────────────────────────────────────────────┘
```

---

# 五、关键文件清单

## 本机 `~/.local/megacmd/work/`

| 文件 | 说明 |
|---|---|
| **`HANDOFF.md`** | 本文档 |
| **`mega_autodl.sh`** | 下载器主程序（本地副本） |
| **`AUTODL_README.md`** | 程序完整文档（原理/配置/心跳/排查） |
| `ARCHIVE.md` | 上一阶段总归档（含 13 条踩坑清单） |
| `PLAN.md` | 批次导入导出方案 |
| `BLOCKER_quota.md` | 配额阻塞的实测记录 |
| `vps.sh` | SSH 封装 |
| `share/share_manifest.tsv` | **61 个视频的清单**：名称⇥字节数⇥句柄⇥目录 |
| `share/share_all_files.txt` | 分享链接全量文件枚举 |
| `listen.sh` / `heartbeat.sh` / `dl_round.sh` | 上一代心跳/下载脚本 |
| `mpress_dump.py` | MPRESS 内存解壳器 |

## VPS `/root/mega_autodl/`

| 路径 | 说明 |
|---|---|
| `mega_autodl.sh` | 主程序（有 `init`/`run`/`status`/`verify` 四个子命令） |
| `config.env` | 配置（700，含账密） |
| `manifest.tsv` | 61 条清单 |
| `downloads/` | **产物：下载好的视频** |
| `state/heartbeat.json` | **实时心跳，监控读这个** |
| `state/progress.tsv` | 每文件处理记录 |
| `logs/autodl.log` | 主日志 |
| `logs/systemd.log` | systemd 捕获输出 |
| `.megaCmd/` | 隔离的 MEGAcmd 状态 |

## VPS 其它（历史遗留，勿删）
- `/root/megadl/round01/` — 上一轮任务的 4 个文件，已被**硬链接**进 downloads/（不占额外空间）
- `/root/mdl_v18_isolated/` — MegaDownloader v1.8 逆向分析沙箱（约 2GB）

---

# 六、⚠️ 必须知道的坑（血泪教训）

## 🔴 1. `mega-cancel` 是「注销整个账号」，不是取消传输
```bash
mega-cancel              # ❌ 触发账号注销流程（会发确认邮件到邮箱）
mega-transfers -c <TAG>  # ✅ 正确的取消传输
mega-transfers -c -a     # ✅ 取消全部传输
```
曾误触一次。查 MEGA SDK 源码确认：`cancelAccount()` 对应 `TYPE_GET_CANCEL_LINK`，
**只发邮件、不改账号状态**；真正删除需要 `confirmCancelAccount(链接, 密码)`。
**永远不要执行 `mega-cancel` / `mega-confirmcancel` / `mega-passwd` / `mega-killsession`。**

## 🔴 2. `pkill -f <pattern>` 会杀掉自己的 SSH 会话
因为承载命令的 `bash -c` 自身命令行里含有该字符串。**栽过两次**。
```bash
pkill -x mega-cmd-server     # ✅ 按进程名精确匹配
kill <显式PID>               # ✅ 最安全
tmux kill-session -t <name>  # ✅ 推荐
```

## 🔴 3. 裸 SSH 启动后台任务会挂住会话
MEGAcmd 会拉起 `mega-cmd-server`，子进程继承通道 fd，SSH 不返回。**必须用 tmux 承载。**

## 🔴 4. 配额报错**只写在服务端日志**，客户端输出是空的
`mega-get` 的 stdout 完全空白，配额警告只在
`$HOME/.megaCmd/megacmdserver.log`：
```
cmd WARN Reached bandwidth quota. ... free transfer allowance for your IP address.
```
**只看客户端输出会永远检测不到配额**（这是第一版的致命 bug，会在 IDLE 空转）。

## 🔴 5. 登录账号**不能**绕过配额
服务端原文：*"the free transfer allowance for **your IP address**"*。
免费账号登录与否是**同一个 IP 池子**。`LOGIN_MODE=auto` 的模式切换**无实际增益**。

## 🟡 6. 删除云端文件 = 分享链接立即失效
分享链接指向文件本身。本任务只下载到本地，不受影响。

## 🟡 7. `mega-rm` 只进回收站，**仍然占空间**
必须再删一次 `//bin/<名字>` 才真正释放。

## 🟡 8. 文件夹链接下**绝对路径的 `ls` 会失效**
```bash
mega-ls "/SD1-5 renew"     # ❌ 返回空
mega-cd "/SD1-5 renew"     # ✅ cd 可以
mega-ls -l video           # ✅ 再用相对路径
```

## 🟡 9. 链接句柄 ≠ 节点句柄
- 节点句柄：`H:Wb52WYSY`（`mega-ls --show-handles` 产出）
- **链接句柄**：URL 里用的（`/file/aGJDxYwK#...`）
用错会报 `Failed to get public node: Not found`。

## 🟡 10. 客户端被 kill 后，**MEGAcmd server 会把传输跑完**
所以在 `mega-transfers` 里看到"幽灵下载"是正常的；判断进度要看 `.getxfer` 或传输队列。

## 🟢 11. 一台机器跑多个 MEGAcmd 实例
用 `HOME=<某目录>` 隔离，会得到独立的 `~/.megaCmd` 和独立的 server 进程。

## 🟢 12. 深层链接可从文件夹链接里单独下载某个文件
```
https://mega.nz/folder/<文件夹句柄>#<密钥>/file/<文件句柄>
```
这是本任务下载机制的基础。

---

# 七、常用操作命令

## 查看进度（最常用）
```bash
ssh root@43.228.217.193 'cd /root/mega_autodl && ./mega_autodl.sh status'
```

## 看心跳（机器可读）
```bash
ssh root@43.228.217.193 'cat /root/mega_autodl/state/heartbeat.json'
# 字段: ts/state/total/completed/failed/bytes_done/bytes_total/percent/free_gb
# state: STARTING | DOWNLOADING | QUOTA_WAIT | IDLE | DONE
```

## 其它
```bash
# 校验所有已下载文件
ssh root@43.228.217.193 'cd /root/mega_autodl && ./mega_autodl.sh verify'

# 实时日志
ssh root@43.228.217.193 'tail -f /root/mega_autodl/logs/autodl.log'

# 服务管理
ssh root@43.228.217.193 'systemctl status|restart|stop mega-autodl'

# 列出缺哪些
ssh root@43.228.217.193 'cd /root/mega_autodl && for f in $(cut -f1 manifest.tsv); do [ -f "downloads/$f" ] || echo "$f"; done'
```

## 本机 MEGAcmd（云盘操作）
```bash
export PATH="$HOME/.local/bin:$PATH"
mega-whoami; mega-df; mega-ls /; mega-export
```

---

# 八、后续可选事项

| 事项 | 说明 |
|---|---|
| **完成通知** | 目前需主动查。可加 Telegram Bot / 邮件，在 `state=DONE` 时推送 |
| **加速：接入本机** | 本机是**另一个出口 IP**，有独立匿名配额池，可望翻倍（约 0.7 天完成）。用户此前要求"所有下载在 VPS"，需其点头 |
| **加速：MEGA Pro** | 彻底解除限制，40GB 一小时内可完 |
| **清理** | 任务完成后可删 `/root/mdl_v18_isolated/`（约 2GB） |
| **收尾** | 下完后建议 `./mega_autodl.sh verify` 全量校验一次 |

---

# 九、已经做过的、有结论的事（避免重复劳动）

## 9.1 本机 MEGAcmd 免 root 安装 ✅
- 官方 deb `megacmd-xUbuntu_24.04_amd64.deb` 解包到 `~/.local/megacmd/root`
- 二进制 `RUNPATH` 硬编码 `/opt/megacmd/lib`（无 root 建不了），
  故 71 个 `mega-*` 都是 wrapper，用 `LD_LIBRARY_PATH` 指向解包目录
- 补装了 `libfuse.so.2`
- 重新生成 wrapper：`~/.local/megacmd/setup-launchers.sh`

## 9.2 MEGA 配额特性（实测结论）✅
- 免费额度约 **5 GB / 窗口**，窗口约 **167 分钟**
- **按 IP 计**，登录账号也一样受限
- `--ignore-quota-warn` 无效（服务端仍拒绝）
- 等待 9 小时后仍未恢复（只漏过约 165MB），说明不是简单的 6 小时重置

## 9.3 MegaDownloader v1.8 **不能**绕过限流 ✅
用户提供 `MegaDownloader_v1.8.exe`，要求验证。结论：
- 安装包是 Inno Setup，解出单个 `MegaDownloader.exe`
- 该 exe 是 **MPRESS 加壳的原生 PE**（CLI Header RVA=0），Mono 无法加载
- **自写内存扫描器成功解壳**，拿到 9 个托管程序集
- 静态分析其配额相关代码，**只有"识别+延时重试"，另有限速器（减速用），无任何绕过机制**
- 尝试在 Linux 运行：越过 MPRESS、越过 ObjectListView 卫星程序集 bug（用 Cecil 打补丁），
  最终卡在 **Wine-Mono 的 `GdipGetGenericFontFamilySansSerif` 缺陷**，未能启动 GUI
- 详见 `~/megadownloader-revival-linux/V18_FINDINGS.md`

## 9.4 上一轮任务（round01）已合并 ✅
- 曾为用户云盘里的 12 个文件（SD39~SD48）生成独立分享链接并下载
- 发现这 12 个文件**就是分享链接里的同一批**（大小完全一致）
- 旧任务已停止，其 4 个已下载文件被**硬链接**进新程序的 downloads/，零浪费

---

# 十、当前状态摘要（供快速接手）

```
服务      : mega-autodl  active + enabled，重启 0 次
进度      : 27/61 (35.1%)，21.59 GB / 61.53 GB
缺口      : 34 个 / 39.94 GB
完整性    : 已下载部分零损坏、零失败
配置      : QUOTA_WAIT_MIN=900, QUOTA_WAIT_MAX=900（固定 15 分钟轮询）
当前        QUOTA_WAIT（等下一个配额窗口）
预计      : 约 1.4~2 天完成
磁盘      : 297 GB 可用，充足
```

**一句话：不需要任何干预，等着就行。想查进度就运行第七节第一条命令。**
