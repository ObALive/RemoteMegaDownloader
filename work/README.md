# MEGA 视频转存分发任务 — 工作目录索引

> 入口文档：**[ARCHIVE.md](ARCHIVE.md)** ← 先看这个（完整流程 + 全部踩坑 + 复跑指引）
> 快捷入口：`./bootstrap.sh help`

## 快速上手

```bash
cd ~/.local/megacmd/work

./bootstrap.sh doctor       # 体检本机 + VPS 环境
./bootstrap.sh status       # 看当前进度（纯本地，不连 SSH）
./bootstrap.sh rounds       # 列出各轮清单
./bootstrap.sh wait 01      # 启动第 1 轮：下载 + 心跳监听（一条龙）
./bootstrap.sh stop         # 中断
```

## 文件地图

### 📘 文档
| 文件 | 内容 |
|---|---|
| **`ARCHIVE.md`** | **总归档**：任务总览 / 环境 / 流程 / 踩坑清单 / 复跑指引 / 命令白名单 |
| `PLAN.md` | 批次导入导出方案（阶段 0 / N / R） |
| `BLOCKER_quota.md` | MEGA 下载配额阻塞的实测记录与备选方案 |

### 🔧 脚本
| 文件 | 运行位置 | 作用 |
|---|---|---|
| `bootstrap.sh` | 本机 | **复跑入口**（doctor/status/rounds/run/listen/wait/stop/creds/vps） |
| `listen.sh` | 本机 | 心跳监听器：一条长连接接收 VPS 心跳，解析后写状态，终止时才退出 |
| `dl_round.sh` | **VPS** | 下载脚本：配额感知 + 卡死检测 + 自动重试 + 断点续做 |
| `heartbeat.sh` | **VPS** | 心跳发生器：周期性把 JSON 心跳推到 stdout |
| `vps.sh` | 本机 | SSH 封装（sshpass + 凭据文件） |
| `export_videos.sh` | 本机 | 批量把云盘文件导出成独立分享链接 |

### 📊 数据与状态
| 文件 | 内容 |
|---|---|
| `state/processed_files.tsv` | **已存文件列表（防重复导入）**，9 列 schema 见 ARCHIVE §3.3 |
| `links.tsv` | 第 1 轮 12 条：`句柄⇥字节⇥链接⇥路径` |
| `round01_manifest.tsv` | 第 1 轮下载清单：`文件名⇥字节数⇥链接` |
| `all_files.txt` / `videos.tsv` | 云盘全量文件 / 视频筛选结果 |
| `vps_status.txt` | **当前进度（实时刷新）** |
| `vps_status.json` | 最新原始心跳 |
| `vps_signal.txt` | 终止信号 `DONE`/`ERROR`/`INTERRUPTED`（空=仍在跑） |
| `vps_heartbeat.history` | 心跳历史 |
| `mega_video_links.{md,txt,csv}` | 第 1 轮交付的链接 |

### 🔑 凭据（不在本目录）
| 路径 | 说明 |
|---|---|
| `~/.ssh/vps_pass` | VPS root 密码，权限 600 |
| — | **MEGA 密码不落盘**，用 `mega-login` 现填 |

## 当前进度

第 1 轮 **4/12** 已下载并校验（5.48 GB），剩余 8 个约 11.5 GB。
阻塞：MEGA 免费下载配额（≈5GB/窗口）未恢复。详见 `ARCHIVE.md` §6。

## ⛔ 安全红线

**绝对不要执行**：`mega-cancel`（= 注销整个账号，不是取消传输）、
`mega-confirmcancel`、`mega-passwd`、`mega-killsession`。

取消传输的正确命令是 **`mega-transfers -c <TAG>`**。
