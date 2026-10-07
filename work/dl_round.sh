#!/bin/bash
# 在 VPS 上下载某一轮的 MEGA 分享链接（配额感知 + 卡死检测 + 自动重试）
# 用法: dl_round.sh <round_dir> <manifest.tsv>
# manifest 每行: <文件名>\t<期望字节数>\t<链接>
#
# 环境变量:
#   STALL_SECS       字节数多久不变判定为卡死 (默认 90)
#   MAX_TRY          单文件普通重试次数 (默认 3)
#   QUOTA_WAIT       撞配额后休眠秒数 (默认 1200 = 20 分钟)
#   MAX_QUOTA_WAIT   最多等待多少次配额 (默认 30 ≈ 10 小时)
set -uo pipefail

ROUND_DIR="${1:?需要 round_dir}"
MANIFEST="${2:?需要 manifest}"
export PATH="/usr/bin:/usr/local/bin:$PATH"

STALL_SECS="${STALL_SECS:-90}"
MAX_TRY="${MAX_TRY:-3}"
QUOTA_WAIT="${QUOTA_WAIT:-1200}"
MAX_QUOTA_WAIT="${MAX_QUOTA_WAIT:-30}"
CHECK_EVERY=15

mkdir -p "$ROUND_DIR"
STATUS="$ROUND_DIR/status.tsv"
LOG="$ROUND_DIR/download.log"
QUOTA_FLAG="$ROUND_DIR/.quota_wait"
rm -f "$QUOTA_FLAG"
[ -f "$STATUS" ] || printf 'name\texpected\tactual\tstatus\tseconds\tattempts\n' > "$STATUS"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

bytes_now() {
    local t=0 f
    for f in "$ROUND_DIR"/*.mp4 "$ROUND_DIR"/.getxfer.*.mega; do
        [ -f "$f" ] && t=$(( t + $(stat -c %s "$f" 2>/dev/null || echo 0) ))
    done
    echo "$t"
}

cleanup_partial() {
    rm -f "$ROUND_DIR"/.getxfer.*.mega "$ROUND_DIR"/.*.getlog 2>/dev/null
    mega-transfers -c -a >/dev/null 2>&1
}

# 返回: 0=成功  1=普通失败  3=配额超限
fetch_one() {
    local name="$1" link="$2" expected="$3"
    local perlog="$ROUND_DIR/.${name}.getlog"
    local dest="$ROUND_DIR/$name"

    ( cd "$ROUND_DIR" && exec mega-get "$link" ) > "$perlog" 2>&1 &
    local gp=$!

    local last_bytes last_change t=0 stalled=0 rc=0
    last_bytes=$(bytes_now); last_change=$(date +%s)

    while kill -0 "$gp" 2>/dev/null; do
        sleep "$CHECK_EVERY"
        t=$(( t + CHECK_EVERY ))
        local cur; cur=$(bytes_now)

        if grep -qiE 'reached your bandwidth quota|over ?quota|EOVERQUOTA' "$perlog" 2>/dev/null; then
            kill "$gp" 2>/dev/null; sleep 2; cleanup_partial
            return 3
        fi

        if [ "$cur" -gt "$last_bytes" ]; then
            last_bytes=$cur; last_change=$(date +%s)
        else
            local idle=$(( $(date +%s) - last_change ))
            if [ "$idle" -ge "$STALL_SECS" ]; then
                log "  !! 卡死 ${idle}s 无进展, 终止并重试"
                stalled=1
                kill "$gp" 2>/dev/null; sleep 3; cleanup_partial
                break
            fi
        fi
    done

    wait "$gp" 2>/dev/null; rc=$?
    [ "$stalled" = "1" ] && return 2
    [ "$rc" -eq 0 ] && [ -f "$dest" ] && [ "$(stat -c %s "$dest")" = "$expected" ] && return 0
    # 客户端被杀但 server 可能仍在传 -> 再等它一会
    sleep 5
    [ -f "$dest" ] && [ "$(stat -c %s "$dest")" = "$expected" ] && return 0
    return 1
}

n_got=$(ls -1 "$ROUND_DIR"/*.mp4 2>/dev/null | wc -l)
log "===== 开始: 已有 $n_got 个文件, 卡死阈值 ${STALL_SECS}s, 配额等待 ${QUOTA_WAIT}s×${MAX_QUOTA_WAIT} ====="

total=$(grep -c . "$MANIFEST")
idx=0; ok=0; skipped=0; failed=0; quota_waits=0

while IFS=$'\t' read -r name expected link; do
    [ -z "${name:-}" ] && continue
    idx=$((idx + 1))
    dest="$ROUND_DIR/$name"

    if [ -f "$dest" ] && [ "$(stat -c %s "$dest")" = "$expected" ]; then
        log "[$idx/$total] 跳过(已完整) $name"
        skipped=$((skipped + 1))
        grep -q "^$name	" "$STATUS" || printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$expected" "$expected" "SKIP_OK" "0" "0" >> "$STATUS"
        continue
    fi

    log "[$idx/$total] 开始 $name  ($expected bytes)"
    start=$(date +%s)
    attempt=0; result=1

    while :; do
        attempt=$((attempt + 1))
        fetch_one "$name" "$link" "$expected"
        result=$?

        [ "$result" -eq 0 ] && break

        if [ "$result" -eq 3 ]; then
            if [ "$quota_waits" -ge "$MAX_QUOTA_WAIT" ]; then
                log "[$idx/$total] 🛑 配额等待已达上限 ($MAX_QUOTA_WAIT 次), 停止本轮"
                printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$expected" "0" "QUOTA_EXCEEDED" "$(( $(date +%s) - start ))" "$attempt" >> "$STATUS"
                failed=$((failed + 1))
                exit 9
            fi
            quota_waits=$((quota_waits + 1))
            log "[$idx/$total] ⏸ 配额超限, 第 $quota_waits 次等待 ${QUOTA_WAIT}s 后重试 ($name)"
            date '+%F %T' > "$QUOTA_FLAG"
            sleep "$QUOTA_WAIT"
            rm -f "$QUOTA_FLAG"
            log "[$idx/$total] ▶ 配额等待结束, 重试 $name"
            attempt=$((attempt - 1))   # 配额等待不计入普通重试
            continue
        fi

        if [ "$attempt" -ge "$MAX_TRY" ]; then
            log "[$idx/$total] ❌ 失败 $name (尝试 $attempt 次)"
            break
        fi
        log "  第 $((attempt + 1)) 次尝试..."
        sleep 10
    done

    secs=$(( $(date +%s) - start ))
    actual=0; [ -f "$dest" ] && actual=$(stat -c %s "$dest")

    if [ "$result" -eq 0 ]; then
        log "[$idx/$total] ✅ 完成 $name (${secs}s, 尝试 ${attempt} 次)"
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$expected" "$actual" "OK" "$secs" "$attempt" >> "$STATUS"
        ok=$((ok + 1))
        rm -f "$ROUND_DIR/.${name}.getlog"
    else
        log "[$idx/$total] ❌ 失败 $name (${secs}s, 实际 $actual / 期望 $expected)"
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$expected" "$actual" "FAILED" "$secs" "$attempt" >> "$STATUS"
        failed=$((failed + 1))
    fi
done < "$MANIFEST"

log "===== 结束: 新下载 $ok / 跳过 $skipped / 失败 $failed (共 $total) ====="
echo "SUMMARY ok=$ok skipped=$skipped failed=$failed total=$total"
