#!/bin/bash
# ============================================================================
# MEGA 分享链接无人值守下载器
#
# 功能:
#   1. 自动枚举分享链接中的全部视频（生成清单，只需一次）
#   2. 登录 MEGA 账号（可选匿名）
#   3. 逐个下载，严格校验字节数
#   4. 撞到 MEGA 配额时自动退避等待、周期性重试，直到全部下完
#   5. 全程可断点续做，重启不丢进度
#   6. 持续输出 JSON 心跳，便于外部监控
#
# 用法:
#   mega_autodl.sh init     # 首次：生成清单
#   mega_autodl.sh run      # 开始/继续无人值守下载
#   mega_autodl.sh status   # 查看进度
#   mega_autodl.sh verify   # 校验所有已下载文件
#
# 依赖: MEGAcmd (mega-* 命令)、bash、awk、stat
# ============================================================================
set -uo pipefail

BASE="$(cd "$(dirname "$0")" && pwd)"
CONF="$BASE/config.env"
MANIFEST="$BASE/manifest.tsv"
STATE="$BASE/state/progress.tsv"
HB="$BASE/state/heartbeat.json"
LOGDIR="$BASE/logs"
DLDIR="$BASE/downloads"
LOCK="$BASE/state/autodl.lock"

mkdir -p "$BASE/state" "$LOGDIR" "$DLDIR"

# ---------------------------------------------------------------- 配置
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

SHARE_LINK="${SHARE_LINK:-https://mega.nz/folder/I7EUnZ7Q#dXEScojKVZRvZW67oWyVfg}"
MEGA_USER="${MEGA_USER:-}"              # 留空则匿名下载
MEGA_PASS="${MEGA_PASS:-}"
LOGIN_MODE="${LOGIN_MODE:-account}"     # account | anonymous
STALL_SECS="${STALL_SECS:-120}"         # 多少秒无字节增长判定为卡死
MAX_TRY_PER_FILE="${MAX_TRY_PER_FILE:-3}"
QUOTA_WAIT_MIN="${QUOTA_WAIT_MIN:-900}"      # 配额退避起始 15 分钟
QUOTA_WAIT_MAX="${QUOTA_WAIT_MAX:-3600}"     # 配额退避上限 60 分钟
IDLE_SLEEP="${IDLE_SLEEP:-60}"               # 全部失败后的轮询间隔
EXTRA_SOURCE_DIRS="${EXTRA_SOURCE_DIRS:-}"   # 已有文件的目录(空格分隔)，用于去重
HB_EVERY="${HB_EVERY:-30}"                   # 心跳落盘间隔(秒)

export PATH="/usr/bin:/usr/local/bin:$PATH"

# 隔离的 MEGAcmd 状态目录（不影响同机其它实例）
if [ "${MEGA_ISOLATED_HOME:-1}" = "1" ]; then
    export HOME="$BASE"
fi

LOG="$LOGDIR/autodl.log"
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }

# 提取分享链接的句柄与密钥
LINK_HANDLE="$(printf '%s' "$SHARE_LINK" | sed -n 's|.*/folder/\([A-Za-z0-9_-]*\).*|\1|p')"
LINK_KEY="$(printf '%s' "$SHARE_LINK" | sed -n 's|.*#\([A-Za-z0-9_-]*\).*|\1|p')"

deeplink() { printf 'https://mega.nz/folder/%s#%s/file/%s' "$LINK_HANDLE" "$LINK_KEY" "${1#H:}"; }

# ---------------------------------------------------------------- 锁
acquire_lock() {
    if [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
        log "另一个实例正在运行 (PID $(cat "$LOCK"))，退出"
        exit 0
    fi
    echo $$ > "$LOCK"
    trap 'rm -f "$LOCK"; log "收到终止信号，退出"' INT TERM
}

# ---------------------------------------------------------------- 心跳
write_heartbeat() {
    local state="$1" cur="${2:-}" pct="${3:-0}"
    local total done_n done_b total_b failed free_gb
    total=0; done_n=0; done_b=0; total_b=0; failed=0

    if [ -f "$MANIFEST" ]; then
        while IFS=$'\t' read -r n s h d; do
            [ -z "${n:-}" ] && continue
            total=$((total + 1)); total_b=$((total_b + s))
            if [ -f "$DLDIR/$n" ] && [ "$(stat -c %s "$DLDIR/$n" 2>/dev/null || echo 0)" = "$s" ]; then
                done_n=$((done_n + 1)); done_b=$((done_b + s))
            fi
        done < "$MANIFEST"
    fi
    [ -f "$STATE" ] && failed=$(awk -F'\t' '$2=="FAILED"{n++}END{print n+0}' "$STATE")
    free_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')

    cat > "$HB.tmp" <<EOF
{"ts":"$(date '+%F %T')","state":"$state","total":$total,"completed":$done_n,
 "failed":$failed,"bytes_done":$done_b,"bytes_total":$total_b,
 "percent":$(( total_b > 0 ? done_b * 100 / total_b : 0 )),
 "current":"$cur","current_pct":$pct,"free_gb":$free_gb,"pid":$$}
EOF
    tr -d '\n' < "$HB.tmp" | sed 's/  */ /g' > "$HB"
    mv -f "$HB.tmp" "$HB" 2>/dev/null || true
}

# ---------------------------------------------------------------- 清单生成
cmd_init() {
    log "===== 初始化：枚举分享链接 ====="
    if [ -f "$MANIFEST" ]; then
        log "清单已存在（$(grep -c . "$MANIFEST") 条），如需重建请先删除 $MANIFEST"
        return 0
    fi

    mega-logout >/dev/null 2>&1; sleep 2
    log "登录分享链接..."
    if ! mega-login "$SHARE_LINK" >/dev/null 2>&1; then
        log "✘ 分享链接登录失败"; return 1
    fi
    sleep 3

    log "枚举全部文件..."
    mega-find / --type=f --show-handles 2>/dev/null | sed 's/[[:space:]]*$//' > "$BASE/state/all_files.txt"
    log "  找到 $(grep -c . "$BASE/state/all_files.txt") 个文件"

    # 视频白名单
    local ext='\.(mp4|mkv|avi|mov|wmv|flv|webm|m4v|ts|mpg|mpeg|rmvb|3gp|m2ts|vob)$'
    grep -iE "$ext <H:" "$BASE/state/all_files.txt" > "$BASE/state/videos.txt"
    log "  其中视频 $(grep -c . "$BASE/state/videos.txt") 个"

    # 逐个视频所在目录取 名称+大小+句柄
    : > "$MANIFEST"
    local lastdir="" curdir
    while IFS= read -r line; do
        curdir="$(printf '%s' "$line" | sed -E 's#^/[^/]*##; s#/[^/]* <H:[A-Za-z0-9]+>$##')"
        if [ "$curdir" != "$lastdir" ]; then
            mega-cd "$curdir" >/dev/null 2>&1
            lastdir="$curdir"
        fi
        mega-ls -l --show-handles 2>/dev/null | awk -v D="$curdir" 'NR>1 && NF>=7 && $6 ~ /^H:/ {
            name=""; for(i=7;i<=NF;i++) name=name (length(name)?" ":"") $i;
            if (name ~ /\.(mp4|mkv|avi|mov|wmv|flv|webm|m4v|ts|mpg|mpeg|rmvb|3gp|m2ts|vob)$/)
                printf "%s\t%s\t%s\t%s\n", name, $3, $6, D
        }' >> "$MANIFEST"
    done < "$BASE/state/videos.txt"

    # 去重（同名同大小只留一条）
    awk -F'\t' '!seen[$1"|"$2]++' "$MANIFEST" > "$MANIFEST.dedup" && mv "$MANIFEST.dedup" "$MANIFEST"

    mega-logout >/dev/null 2>&1
    local n tot
    n=$(grep -c . "$MANIFEST")
    tot=$(awk -F'\t' '{s+=$2}END{print s+0}' "$MANIFEST")
    log "✅ 清单生成完毕：$n 个视频，共 $(awk -v b="$tot" 'BEGIN{printf "%.2f GB", b/1073741824}')"
}

# ---------------------------------------------------------------- 登录
# $1 = account | anonymous（缺省用 LOGIN_MODE）
do_login() {
    local mode="${1:-$LOGIN_MODE}"
    [ "$mode" = "auto" ] && mode="account"

    if [ "$mode" = "anonymous" ] || [ -z "$MEGA_USER" ]; then
        mega-logout >/dev/null 2>&1; sleep 1
        log "模式：匿名下载（IP 配额池）"
        return 0
    fi
    if mega-whoami 2>/dev/null | grep -q "$MEGA_USER"; then
        log "模式：账号下载（已登录 $MEGA_USER）"
        return 0
    fi
    log "登录账号 $MEGA_USER ..."
    mega-logout >/dev/null 2>&1; sleep 1
    if mega-login "$MEGA_USER" "$MEGA_PASS" >/dev/null 2>&1; then
        log "✅ 账号登录成功（账号配额池）"
    else
        log "⚠️  账号登录失败，降级为匿名下载"
        mega-logout >/dev/null 2>&1; sleep 1
    fi
}

# ---------------------------------------------------------------- 去重：从既有目录认领
reclaim_existing() {
    [ -z "$EXTRA_SOURCE_DIRS" ] && return 0
    local n s h d src n_rec=0
    while IFS=$'\t' read -r n s h d; do
        [ -z "${n:-}" ] && continue
        [ -f "$DLDIR/$n" ] && continue
        for src in $EXTRA_SOURCE_DIRS; do
            if [ -f "$src/$n" ] && [ "$(stat -c %s "$src/$n")" = "$s" ]; then
                ln "$src/$n" "$DLDIR/$n" 2>/dev/null || cp -n "$src/$n" "$DLDIR/$n" 2>/dev/null
                log "  认领已有文件: $n"
                n_rec=$((n_rec + 1)); break
            fi
        done
    done < "$MANIFEST"
    [ "$n_rec" -gt 0 ] && log "从既有目录认领 $n_rec 个文件（硬链接，不占额外空间）"
    return 0
}

is_complete() {   # $1=name $2=size
    local f="$DLDIR/$1"
    [ -f "$f" ] && [ "$(stat -c %s "$f" 2>/dev/null || echo 0)" = "$2" ]
}

bytes_in_dldir() {
    local t=0 f
    shopt -s nullglob
    for f in "$DLDIR"/* "$DLDIR"/.getxfer.*; do
        [ -f "$f" ] && t=$(( t + $(stat -c %s "$f" 2>/dev/null || echo 0) ))
    done
    shopt -u nullglob
    echo "$t"
}

# 下载单个文件；返回 0=成功 3=配额超限 2=卡死 1=其它失败
#
# 注意：MEGA 的配额警告只写在【服务端日志】里，客户端 mega-get 的输出是空的，
#       所以必须同时盯 $HOME/.megaCmd/megacmdserver.log 的新增部分。
fetch_one() {
    local name="$1" size="$2" link="$3"
    local dest="$DLDIR/$name" perlog="$LOGDIR/.get_$name.log"
    local slog="$HOME/.megaCmd/megacmdserver.log"
    local off=0
    [ -f "$slog" ] && off=$(stat -c %s "$slog")

    ( cd "$DLDIR" && exec mega-get "$link" ) > "$perlog" 2>&1 &
    local gp=$!
    local last_b last_t idle cur stalled=0 rc=0 hit=0

    last_b=$(bytes_in_dldir); last_t=$(date +%s)

    while kill -0 "$gp" 2>/dev/null; do
        sleep 15

        # --- 配额检测（两处都查）---
        hit=0
        grep -qiE 'reached your bandwidth quota|EOVERQUOTA|over ?quota' "$perlog" 2>/dev/null && hit=1
        if [ "$hit" = "0" ] && [ -f "$slog" ]; then
            tail -c +$((off + 1)) "$slog" 2>/dev/null \
              | grep -qiE 'Reached bandwidth quota|EOVERQUOTA' && hit=1
        fi
        if [ "$hit" = "1" ]; then
            kill "$gp" 2>/dev/null; sleep 2
            mega-transfers -c -a >/dev/null 2>&1
            rm -f "$DLDIR"/.getxfer.* "$DLDIR"/.*.getlog 2>/dev/null
            return 3
        fi

        cur=$(bytes_in_dldir)
        if [ "$cur" -gt "$last_b" ]; then
            last_b=$cur; last_t=$(date +%s)
        else
            idle=$(( $(date +%s) - last_t ))
            if [ "$idle" -ge "$STALL_SECS" ]; then
                # 长时间零进展也可能是配额（无显式报错时的兜底）
                if [ -f "$slog" ] && tail -c +$((off + 1)) "$slog" 2>/dev/null \
                     | grep -qiE 'quota|RETRYING'; then
                    log "    !! ${idle}s 零进展且服务端出现 quota 迹象 -> 按配额处理"
                    kill "$gp" 2>/dev/null; sleep 3
                    mega-transfers -c -a >/dev/null 2>&1
                    rm -f "$DLDIR"/.getxfer.* "$DLDIR"/.*.getlog 2>/dev/null
                    return 3
                fi
                log "    !! 卡死 ${idle}s，终止重试"
                stalled=1
                kill "$gp" 2>/dev/null; sleep 3
                mega-transfers -c -a >/dev/null 2>&1
                rm -f "$DLDIR"/.getxfer.* "$DLDIR"/.*.getlog 2>/dev/null
                break
            fi
        fi
    done
    wait "$gp" 2>/dev/null; rc=$?

    [ "$stalled" = "1" ] && return 2
    # 客户端被 kill 但 server 可能仍在传，给它一点时间
    local w=0
    while [ "$w" -lt 30 ]; do
        is_complete "$name" "$size" && { rm -f "$perlog"; return 0; }
        sleep 3; w=$((w + 3))
    done
    [ "$rc" -eq 0 ] && is_complete "$name" "$size" && { rm -f "$perlog"; return 0; }
    return 1
}

# ---------------------------------------------------------------- 主循环
cmd_run() {
    acquire_lock
    [ -f "$MANIFEST" ] || cmd_init || { log "✘ 无清单且初始化失败"; exit 1; }
    reclaim_existing

    local cur_mode="$LOGIN_MODE"
    [ "$cur_mode" = "auto" ] && cur_mode="account"
    do_login "$cur_mode"

    local total; total=$(grep -c . "$MANIFEST")
    log "===== 开始下载：$total 个视频 ====="
    write_heartbeat "STARTING"

    local quota_wait=$QUOTA_WAIT_MIN
    local round=0

    while :; do
        round=$((round + 1))
        local pending=0 progressed=0 hit_quota=0 idx=0

        while IFS=$'\t' read -r name size handle dir; do
            [ -z "${name:-}" ] && continue
            idx=$((idx + 1))

            if is_complete "$name" "$size"; then continue; fi
            pending=$((pending + 1))

            local link; link="$(deeplink "$handle")"
            log "[$idx/$total] 下载 $name  ($size 字节)"
            write_heartbeat "DOWNLOADING" "$name" 0

            local attempt=0 result=1
            while [ "$attempt" -lt "$MAX_TRY_PER_FILE" ]; do
                attempt=$((attempt + 1))
                fetch_one "$name" "$size" "$link"
                result=$?
                [ "$result" -eq 0 ] && break
                [ "$result" -eq 3 ] && break          # 配额，跳出交给外层退避
                [ "$attempt" -lt "$MAX_TRY_PER_FILE" ] && { log "    第 $attempt 次失败，重试"; sleep 10; }
            done

            if [ "$result" -eq 0 ]; then
                log "    ✅ 完成 $name"
                printf '%s\t%s\t%s\n' "$name" "DONE" "$(date '+%F %T')" >> "$STATE"
                progressed=1
                quota_wait=$QUOTA_WAIT_MIN     # 成功后退避重置
                write_heartbeat "DOWNLOADING" "$name" 100
            elif [ "$result" -eq 3 ]; then
                log "    ⏸ 配额超限，本轮停止，退避 ${quota_wait}s"
                printf '%s\t%s\t%s\n' "$name" "QUOTA" "$(date '+%F %T')" >> "$STATE"
                hit_quota=1
                break
            else
                log "    ❌ 失败 $name（$attempt 次尝试）"
                printf '%s\t%s\t%s\n' "$name" "FAILED" "$(date '+%F %T')" >> "$STATE"
            fi
        done < "$MANIFEST"

        # 是否全部完成
        local done_n=0
        while IFS=$'\t' read -r n s h d; do
            [ -z "${n:-}" ] && continue
            is_complete "$n" "$s" && done_n=$((done_n + 1))
        done < "$MANIFEST"

        if [ "$done_n" -ge "$total" ]; then
            log "🎉 全部完成！$done_n/$total"
            write_heartbeat "DONE"
            rm -f "$LOCK"
            return 0
        fi

        log "----- 第 $round 轮结束：完成 $done_n/$total，待下 $pending -----"

        if [ "$hit_quota" = "1" ]; then
            write_heartbeat "QUOTA_WAIT"
            # auto 模式：账号配额 与 匿名 IP 配额 是两个独立池子，撞墙就换池
            if [ "$LOGIN_MODE" = "auto" ]; then
                if [ "$cur_mode" = "account" ]; then cur_mode="anonymous"; else cur_mode="account"; fi
                log "配额退避 ${quota_wait}s，并切换下载模式 -> $cur_mode"
                do_login "$cur_mode"
            else
                log "配额退避 ${quota_wait}s（上限 ${QUOTA_WAIT_MAX}s）..."
            fi
            sleep "$quota_wait"
            quota_wait=$(( quota_wait * 2 )); [ "$quota_wait" -gt "$QUOTA_WAIT_MAX" ] && quota_wait=$QUOTA_WAIT_MAX
        elif [ "$progressed" = "0" ]; then
            write_heartbeat "IDLE"
            log "本轮无进展，${IDLE_SLEEP}s 后重试"
            sleep "$IDLE_SLEEP"
        fi
    done
}

# ---------------------------------------------------------------- 状态/校验
cmd_status() {
    local total=0 done_n=0 done_b=0 total_b=0
    while IFS=$'\t' read -r n s h d; do
        [ -z "${n:-}" ] && continue
        total=$((total + 1)); total_b=$((total_b + s))
        if is_complete "$n" "$s"; then done_n=$((done_n + 1)); done_b=$((done_b + s)); fi
    done < "$MANIFEST" 2>/dev/null
    printf '总计   : %d 个视频 / %.2f GB\n' "$total" "$(awk -v b="$total_b" 'BEGIN{print b/1073741824}')"
    printf '已完成 : %d 个 / %.2f GB (%.1f%%)\n' "$done_n" "$(awk -v b="$done_b" 'BEGIN{print b/1073741824}')" \
           "$(awk -v a="$done_b" -v b="$total_b" 'BEGIN{print (b>0?a*100/b:0)}')"
    printf '剩余   : %d 个 / %.2f GB\n' "$((total - done_n))" "$(awk -v a="$done_b" -v b="$total_b" 'BEGIN{print (b-a)/1073741824}')"
    [ -f "$HB" ] && { echo "心跳   :"; cat "$HB"; echo; }
}

cmd_verify() {
    local bad=0 n s h d
    while IFS=$'\t' read -r n s h d; do
        [ -z "${n:-}" ] && continue
        if [ ! -f "$DLDIR/$n" ]; then printf '缺失  %s\n' "$n"; bad=$((bad + 1)); continue; fi
        local a; a=$(stat -c %s "$DLDIR/$n")
        [ "$a" != "$s" ] && { printf '大小不符  %s (本地 %s / 期望 %s)\n' "$n" "$a" "$s"; bad=$((bad + 1)); }
    done < "$MANIFEST"
    [ "$bad" -eq 0 ] && echo "✅ 全部校验通过" || echo "⚠️  $bad 个文件有问题"
    return 0
}

case "${1:-help}" in
    init)   cmd_init ;;
    run)    cmd_run ;;
    status) cmd_status ;;
    verify) cmd_verify ;;
    *)      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
