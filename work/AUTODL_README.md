# MEGA 无人值守下载器 (mega_autodl)

无人值守地把 MEGA 分享链接里的**全部视频**下载到本机，撞到配额自动退避、周期性重试，
直到全部完成。专为「MEGA 免费账号配额每约 6 小时重置一次」的场景设计。

---

## 一、它解决什么问题

MEGA 免费额度约 **5 GB / 窗口（约 6 小时，按 IP 计）**，且**登录账号也一样受限**
（服务端日志原文：*"the current free transfer allowance for your IP address"*）。

所以 61 GB 的任务不可能一次跑完，必须：
- 撞配额就等，等到了自动继续
- 断点续做，重启不丢进度
- 全程无人干预

本程序就是把这个循环自动化。

---

## 二、快速使用

```bash
cd /root/mega_autodl

./mega_autodl.sh status    # 查看进度
./mega_autodl.sh verify    # 校验所有已下载文件的字节数
./mega_autodl.sh run       # 前台运行（调试用；正常由 systemd 托管）
./mega_autodl.sh init      # 重新枚举分享链接生成清单（需先删 manifest.tsv）

# 服务管理
systemctl status  mega-autodl
systemctl restart mega-autodl
systemctl stop    mega-autodl
journalctl -u mega-autodl -f
tail -f /root/mega_autodl/logs/autodl.log
```

---

## 三、目录结构

```
/root/mega_autodl/
├── mega_autodl.sh          主程序
├── config.env              配置（700 权限，含账号密码）
├── manifest.tsv            清单：文件名 ⇥ 字节数 ⇥ 句柄 ⇥ 所在目录
├── downloads/              下载的视频（最终产物）
├── state/
│   ├── progress.tsv        每个文件的处理记录
│   ├── heartbeat.json      实时心跳（外部监控读这个）
│   ├── all_files.txt       分享链接全量文件枚举结果
│   └── videos.txt          筛选出的视频
├── logs/
│   ├── autodl.log          主日志
│   ├── systemd.log         systemd 捕获的输出
│   └── .get_<文件名>.log   单文件下载日志
└── .megaCmd/               隔离的 MEGAcmd 状态（不影响同机其它实例）
```

---

## 四、工作原理

### 1. 枚举阶段（`init`，只需一次）
```
登录分享链接 → mega-find 递归枚举 → 筛出视频 → 逐目录取 名称+大小+句柄 → manifest.tsv
```
关键点：文件夹链接下**绝对路径的 `ls` 会失效**，必须 `cd` 进去再用相对路径列目录。

### 2. 下载阶段（`run`）
对每个视频构造**深层链接**：
```
https://mega.nz/folder/<文件夹句柄>#<密钥>/file/<文件句柄>
```
逐个下载，下载后**严格比对字节数**，一致才算成功。

### 3. 配额退避（核心）
```
撞配额 → 记录 → 退避 900s → 重试 → 1800s → 3600s（上限）→ 一直循环
成功一次 → 退避重置回 900s
```
退避期间心跳状态为 `QUOTA_WAIT`。

### 4. 卡死检测
120 秒字节数无增长 → 判定卡死 → 杀传输 → 清理部分文件 → 重试。

### 5. 断点续做
每次启动都会扫描 `downloads/`，**已存在且字节数正确的文件直接跳过**。
另外 `EXTRA_SOURCE_DIRS` 里的同名同大小文件会被**硬链接**进来，不重复下载、不占额外空间。

---

## 五、配置说明（`config.env`）

| 项 | 说明 |
|---|---|
| `SHARE_LINK` | 要下载的分享链接 |
| `MEGA_USER` / `MEGA_PASS` | MEGA 账号；留空则纯匿名 |
| `LOGIN_MODE` | `account` / `anonymous` / `auto`（撞配额自动切换，推荐） |
| `STALL_SECS` | 多少秒无增长判定卡死，默认 120 |
| `MAX_TRY_PER_FILE` | 单文件普通重试次数，默认 3 |
| `QUOTA_WAIT_MIN` / `QUOTA_WAIT_MAX` | 配额退避起始 / 上限秒数，默认 900 / 3600 |
| `IDLE_SLEEP` | 本轮无进展时的轮询间隔，默认 60 |
| `EXTRA_SOURCE_DIRS` | 去重来源目录（空格分隔） |
| `MEGA_ISOLATED_HOME` | `1`=用本目录作 HOME，隔离 MEGAcmd 状态 |

> ⚠️ `config.env` 含明文密码，权限已设为 `700`。若介意，可改为 `LOGIN_MODE=anonymous` 并清空账密。

---

## 六、心跳格式

`state/heartbeat.json`，每轮更新：

```json
{"ts":"2026-10-06 10:33:29","state":"QUOTA_WAIT","total":61,"completed":4,
 "failed":0,"bytes_done":5882677159,"bytes_total":66071081736,
 "percent":8,"current":"...","current_pct":0,"free_gb":313,"pid":902731}
```

`state` 取值：`STARTING` / `DOWNLOADING` / `QUOTA_WAIT` / `IDLE` / `DONE`

外部监控示例：
```bash
jq -r '"\(.completed)/\(.total)  \(.percent)%  \(.state)"' /root/mega_autodl/state/heartbeat.json
```

---

## 七、重要发现与注意事项

### ⚠️ 登录账号**不能**绕过配额
服务端日志原文：
```
Reached bandwidth quota. ... the current free transfer allowance for your IP address.
```
免费账号的限额**按 IP 计**，登录与否是同一个池子。`LOGIN_MODE=auto` 的切换因此
**没有实际增益**（但无害）。真正的解法只有三个：等窗口、升 Pro、加出口 IP。

### ⚠️ 配额报错只写在**服务端日志**
`mega-get` 的客户端输出是**空的**，配额警告只出现在
`$HOME/.megaCmd/megacmdserver.log`。程序必须 tail 该文件的新增部分才能检测到。
（这是踩过的坑：只看客户端输出会永远检测不到配额，程序会在 IDLE 空转。）

### ⚠️ 删除文件会让分享链接失效
本程序只下载到本地，不碰云端文件，因此不受影响。

### ⚠️ MEGAcmd 命令命名陷阱
- `mega-cancel` = **注销整个账号**（不是取消传输！）
- 取消传输要用 `mega-transfers -c <TAG>` 或 `-c -a`

### 隔离设计
程序用 `HOME=/root/mega_autodl`，拥有**独立的 `mega-cmd-server` 实例**，
不会干扰同机上其它 MEGAcmd 使用。

---

## 八、预期耗时（按 5 GB/6h 估算）

| 阶段 | 数据量 | 预计 |
|---|---|---|
| 已完成 | 5.48 GB | — |
| 剩余 | 56.05 GB | **约 12 个配额窗口 ≈ 3 天** |

实际取决于 MEGA 当时给出的动态额度。

---

## 九、故障排查

| 症状 | 检查 |
|---|---|
| 一直 `QUOTA_WAIT` | 正常，等窗口。看服务端日志确认是否真配额 |
| 一直 `IDLE` | 检查网络、链接是否失效 |
| `DOWNLOADS` 有 `.getxfer.*` 残留 | 程序会自动清；手动清可 `rm downloads/.getxfer.*` |
| 服务反复重启 | `journalctl -u mega-autodl -n 50` |
| 想换分享链接 | 停服务 → 删 `manifest.tsv` → 改 `config.env` → `init` → 启服务 |

---

## 十、当前任务

- 源：`https://mega.nz/folder/I7EUnZ7Q#dXEScojKVZRvZW67oWyVfg`
- 共 **61 个视频 / 61.53 GB**
- 其中 4 个（5.48 GB）已从上一轮任务硬链接认领
- 交付位置：`/root/mega_autodl/downloads/`
