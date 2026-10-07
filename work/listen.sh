#!/bin/bash
# 本机侧心跳监听器
# 通过【一条】长连接 SSH 接收 VPS 推送的 JSON 心跳，解析后写本地状态文件。
# 收到 DONE / ERROR / INTERRUPTED 即退出。断线自动重连。
#
# 用法: listen.sh <round_dir> <manifest> [interval] [max_reconnect]
set -uo pipefail

ROUND="${1:?round_dir}"
MANIFEST="${2:?manifest}"
INTERVAL="${3:-10}"
MAX_RECONN="${4:-8}"

WORK="$(cd "$(dirname "$0")" && pwd)"
STATUS_TXT="$WORK/vps_status.txt"
STATUS_JSON="$WORK/vps_status.json"
SIGNAL="$WORK/vps_signal.txt"
HISTORY="$WORK/vps_heartbeat.history"

export PATH="$HOME/.local/bin:$PATH"
SSH_OPTS=(-o StrictHostKeyChecking=no -o ConnectTimeout=25 -o ServerAliveInterval=20 -o ServerAliveCountMax=6)

: > "$SIGNAL"
log() { echo "[$(date '+%F %T')] $*" >> "$WORK/listen.log"; }

jget() { printf '%s' "$1" | grep -o "\"$2\":[^,}]*" | head -1 | cut -d: -f2- | tr -d '"'; }

attempt=0
while [ "$attempt" -lt "$MAX_RECONN" ]; do
    attempt=$((attempt + 1))
    log "连接 VPS (第 $attempt 次)"

    while IFS= read -r line; do
        case "$line" in
            \{*\}) ;;
            *) continue ;;
        esac

        printf '%s\n' "$line" > "$STATUS_JSON"
        printf '%s\n' "$line" >> "$HISTORY"

        ts=$(jget "$line" ts);          state=$(jget "$line" state)
        total=$(jget "$line" total);    comp=$(jget "$line" completed)
        failed=$(jget "$line" failed);  cur=$(jget "$line" current)
        pct=$(jget "$line" current_pct); doneb=$(jget "$line" done_bytes)
        totb=$(jget "$line" total_bytes); free=$(jget "$line" free_gb)
        quota=$(jget "$line" quota_exceeded)

        gpct=0; [ "${totb:-0}" -gt 0 ] && gpct=$(( doneb * 100 / totb ))
        printf '%s | %-11s | 文件 %s/%s (%d%%) | 字节 %d%% | 当前: %s %s%% | 失败 %s | 磁盘余 %sG | 配额超限 %s\n' \
            "$ts" "$state" "$comp" "$total" "$(( comp * 100 / (total>0?total:1) ))" \
            "$gpct" "${cur:-无}" "$pct" "$failed" "$free" "$quota" > "$STATUS_TXT"

        case "$state" in
            DONE|ERROR|INTERRUPTED)
                printf '%s\n' "$state" > "$SIGNAL"
                log "收到终止信号: $state"
                echo "SIGNAL=$state completed=$comp/$total failed=$failed quota=$quota"
                echo "详情: $STATUS_TXT"
                exit 0
                ;;
        esac
    done < <(SSHPASS="$(cat "$HOME/.ssh/vps_pass")" sshpass -e ssh "${SSH_OPTS[@]}" \
                root@43.228.217.193 "bash /root/megadl/heartbeat.sh '$ROUND' '$MANIFEST' '$INTERVAL'" 2>>"$WORK/listen.log")

    log "连接断开，5 秒后重连"
    sleep 5
done

echo "SIGNAL=LISTENER_GAVE_UP attempts=$attempt"
echo "最后状态: $(cat "$STATUS_TXT" 2>/dev/null)"
exit 1
