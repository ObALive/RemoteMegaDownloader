#!/bin/bash
# VPS 侧心跳发生器：每隔 INTERVAL 秒向 stdout 推送一行 JSON 心跳。
# 供本机通过一条长连接 SSH 接收并解析。同时把最新心跳原子写入 heartbeat.json。
#
# 用法: heartbeat.sh <round_dir> <manifest> [interval_sec]
set -uo pipefail

ROUND="${1:?round_dir}"
MANIFEST="${2:?manifest}"
INTERVAL="${3:-10}"
HB_JSON="$ROUND/heartbeat.json"
STATUS_TSV="$ROUND/status.tsv"
[ -f "$ROUND/../STOP" ] && rm -f "$ROUND/../STOP"

emit() {
    local ts state runner total completed failed skipped
    local done_bytes total_bytes cur cur_bytes cur_pct free_gb last quota

    ts=$(date '+%F %T')

    # runner 状态
    if pgrep -f "dl_round.sh" >/dev/null 2>&1; then runner=running; else runner=stopped; fi

    # 逐条比对清单
    total=0; completed=0; failed=0; skipped=0; done_bytes=0; total_bytes=0
    while IFS=$'\t' read -r name expected link; do
        [ -z "${name:-}" ] && continue
        total=$((total + 1))
        total_bytes=$((total_bytes + expected))
        if [ -f "$ROUND/$name" ]; then
            actual=$(stat -c %s "$ROUND/$name" 2>/dev/null || echo 0)
            if [ "$actual" = "$expected" ]; then
                completed=$((completed + 1))
                done_bytes=$((done_bytes + actual))
            fi
        fi
    done < "$MANIFEST"

    # 失败/配额计数
    if [ -f "$STATUS_TSV" ]; then
        failed=$(awk -F'\t' '$4=="FAILED"{n++}END{print n+0}' "$STATUS_TSV")
        skipped=$(awk -F'\t' '$4=="SKIP_OK"{n++}END{print n+0}' "$STATUS_TSV")
    fi
    # 配额等待中(非终止) vs 配额彻底放弃(终止)
    quota_wait=false
    [ -f "$ROUND/.quota_wait" ] && quota_wait=true
    quota=false
    grep -qs 'QUOTA_EXCEEDED' "$STATUS_TSV" 2>/dev/null && quota=true
    [ -f "$ROUND/../.need_attention" ] && quota=true

    # 当前正在下载的文件 + 进度
    cur=""; cur_bytes=0; cur_pct=0
    xfer=$(ls -1 "$ROUND"/.getxfer.*.mega 2>/dev/null | head -1)
    if [ -n "$xfer" ]; then
        cur_bytes=$(stat -c %s "$xfer" 2>/dev/null || echo 0)
        # 找出与在传文件对应的名字（取最近修改的 .getlog）
        glog=$(ls -1t "$ROUND"/.*.getlog 2>/dev/null | head -1)
        if [ -n "$glog" ]; then
            cur=$(basename "$glog"); cur="${cur#.}"; cur="${cur%.getlog}"
        fi
        # 期望值
        exp=$(awk -F'\t' -v n="$cur" '$1==n{print $2}' "$MANIFEST")
        [ -n "${exp:-}" ] && [ "$exp" -gt 0 ] && cur_pct=$(( cur_bytes * 100 / exp ))
        done_bytes=$((done_bytes + cur_bytes))
    fi

    free_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
    last=$(tail -1 "$ROUND/runner.log" 2>/dev/null | tr -d '\r' | cut -c1-90)

    # --- 状态判定 ---
    if [ -f "$ROUND/../STOP" ]; then
        state=INTERRUPTED
    elif [ "$quota" = "true" ]; then
        state=ERROR
    elif [ "$quota_wait" = "true" ]; then
        state=QUOTA_WAIT
    elif [ "$runner" = "stopped" ]; then
        if [ "$completed" -ge "$total" ] && [ "$failed" -eq 0 ]; then state=DONE; else state=ERROR; fi
    elif [ "$total" -gt 0 ] && [ "$completed" -ge "$total" ]; then
        state=DONE
    else
        state=DOWNLOADING
    fi

    printf '{"ts":"%s","state":"%s","runner":"%s","total":%d,"completed":%d,"skipped":%d,"failed":%d,"quota_exceeded":%s,"quota_waiting":%s,"current":"%s","current_pct":%d,"done_bytes":%d,"total_bytes":%d,"free_gb":%s,"last":"%s"}\n' \
        "$ts" "$state" "$runner" "$total" "$completed" "$skipped" "$failed" "$quota" "$quota_wait" \
        "$cur" "$cur_pct" "$done_bytes" "$total_bytes" "$free_gb" "$last" | tee "$HB_JSON.tmp"
    mv -f "$HB_JSON.tmp" "$HB_JSON"

    case "$state" in
        DONE|ERROR|INTERRUPTED) exit 0 ;;
    esac
}

# 首帧立即发，之后按间隔发；整体最多跑 24 小时
deadline=$(( $(date +%s) + 86400 ))
while :; do
    emit
    [ "$(date +%s)" -ge "$deadline" ] && exit 0
    sleep "$INTERVAL"
done
