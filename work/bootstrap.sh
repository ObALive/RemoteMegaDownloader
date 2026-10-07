#!/bin/bash
# ============================================================================
# MEGA 视频转存分发任务 — 复跑入口
# 文档见同目录 ARCHIVE.md
#
# 用法: bootstrap.sh <子命令> [参数]
#
#   doctor              体检：本机 + VPS 环境是否就绪
#   status              打印当前心跳（纯本地读取，不连 SSH）
#   rounds              列出所有轮次清单及完成度（纯本地）
#   run <NN>            在 VPS 上以 tmux 启动第 NN 轮下载
#   listen <NN>         启动本机心跳监听（前台；建议放后台任务）
#   wait <NN>           启动下载 + 监听（一条龙）
#   stop                中断：置 STOP 标记 + 停 tmux + 清传输队列
#   vps <命令...>       在 VPS 上执行任意命令
#   creds               写入 VPS 凭据到 ~/.ssh/vps_pass
#
# 凭据约定：VPS 密码存 ~/.ssh/vps_pass(600)；MEGA 密码不落盘，用 mega-login 现填。
# ============================================================================
set -uo pipefail

WORK="$(cd "$(dirname "$0")" && pwd)"
VPS_HOST="43.228.217.193"
VPS_USER="root"
VPS_PASS_FILE="$HOME/.ssh/vps_pass"
REMOTE_DIR="/root/megadl"
export PATH="$HOME/.local/bin:$PATH"

c_ok()   { printf '\033[32m✔\033[0m %s\n' "$*"; }
c_bad()  { printf '\033[31m✘\033[0m %s\n' "$*"; }
c_warn() { printf '\033[33m!\033[0m %s\n' "$*"; }
c_info() { printf '\033[36m·\033[0m %s\n' "$*"; }

need_sshpass() {
    command -v sshpass >/dev/null 2>&1 || { c_bad "缺少 sshpass（应在 ~/.local/bin）"; return 1; }
    [ -f "$VPS_PASS_FILE" ] || { c_bad "缺少凭据 $VPS_PASS_FILE，先跑: bootstrap.sh creds"; return 1; }
    return 0
}

vps_run() {   # 在 VPS 上执行命令
    need_sshpass || return 1
    SSHPASS="$(cat "$VPS_PASS_FILE")" sshpass -e ssh \
        -o StrictHostKeyChecking=no -o ConnectTimeout=25 \
        "$VPS_USER@$VPS_HOST" "$@"
}

vps_scp() {   # scp 上传: vps_scp <本地文件>...
    need_sshpass || return 1
    SSHPASS="$(cat "$VPS_PASS_FILE")" sshpass -e scp -o StrictHostKeyChecking=no \
        "$@" "$VPS_USER@$VPS_HOST:$REMOTE_DIR/"
}

# --------------------------------------------------------------------------
cmd_creds() {
    printf 'VPS 密码: '; read -rs pw; echo
    umask 077
    printf '%s' "$pw" > "$VPS_PASS_FILE"
    chmod 600 "$VPS_PASS_FILE"
    c_ok "已写入 $VPS_PASS_FILE (600)"
}

cmd_doctor() {
    echo "===== 本机 ====="
    if command -v mega-version >/dev/null 2>&1; then
        c_ok "MEGAcmd: $(mega-version 2>&1 | head -1)"
    else
        c_bad "MEGAcmd 不可用（wrapper 未在 PATH）"
    fi
    [ -d "$HOME/.local/megacmd/root" ] && c_ok "解包目录存在" || c_bad "缺 ~/.local/megacmd/root"
    [ -d "$HOME/.local/bin" ] && c_ok "wrapper 目录: $(ls "$HOME/.local/bin"/mega-* 2>/dev/null | wc -l) 个"
    command -v sshpass >/dev/null && c_ok "sshpass 可用" || c_bad "缺 sshpass"
    [ -f "$VPS_PASS_FILE" ] && c_ok "VPS 凭据存在(600)" || c_bad "缺 VPS 凭据"

    echo; echo "===== VPS ====="
    vps_run 'echo "  主机: $(hostname)  $(. /etc/os-release; echo $PRETTY_NAME)"
echo "  磁盘: $(df -h / | tail -1 | awk "{print \$4\" 可用\"}")"
command -v mega-cmd >/dev/null && echo "  MEGAcmd: $(mega-version 2>&1|head -1)" || echo "  ✘ 缺 MEGAcmd"
command -v tmux >/dev/null && echo "  tmux: 可用" || echo "  ✘ 缺 tmux"
tmux has-session -t megadl 2>/dev/null && echo "  下载会话: 运行中" || echo "  下载会话: 未运行"
ls '"$REMOTE_DIR"'/dl_round.sh >/dev/null 2>&1 && echo "  dl_round.sh: 已上传" || echo "  ✘ dl_round.sh 未上传"
ls '"$REMOTE_DIR"'/heartbeat.sh >/dev/null 2>&1 && echo "  heartbeat.sh: 已上传" || echo "  ✘ heartbeat.sh 未上传"' 2>&1 | head -20
}

cmd_status() {
    echo "===== 当前状态 ====="
    if [ -f "$WORK/vps_status.txt" ]; then cat "$WORK/vps_status.txt"; else c_warn "无心跳记录"; fi
    echo
    sig="$(cat "$WORK/vps_signal.txt" 2>/dev/null)"
    if [ -z "$sig" ]; then c_info "无终止信号 → 任务仍在进行"; else c_warn "终止信号: $sig"; fi
    echo
    echo "===== 最近心跳 ====="
    tail -4 "$WORK/vps_heartbeat.history" 2>/dev/null \
      | grep -o '"ts":"[^"]*"\|"state":"[^"]*"\|"done_bytes":[0-9]*' | paste - - - || true
}

cmd_rounds() {
    for m in "$WORK"/round*_manifest.tsv; do
        [ -f "$m" ] || continue
        r="$(basename "$m" _manifest.tsv)"
        st="$WORK/$r.status.local"
        printf '\n=== %s (%s 个文件) ===\n' "$r" "$(grep -c . "$m")"
        awk -F'\t' '{printf "  %-30s %10.2f GB\n", $1, $2/1073741824}' "$m"
        c_info "完成度请看: bootstrap.sh status"
    done
}

cmd_run() {
    local rn="${1:?用法: bootstrap.sh run <NN>}"
    local rdir="$REMOTE_DIR/round$rn"
    local mfst="$REMOTE_DIR/round${rn}_manifest.tsv"
    vps_run "test -f '$mfst'" || { c_bad "VPS 上找不到清单 $mfst"; return 1; }
    vps_run "tmux kill-session -t megadl 2>/dev/null
tmux new-session -d -s megadl 'QUOTA_WAIT=1800 MAX_QUOTA_WAIT=24 bash $REMOTE_DIR/dl_round.sh $rdir $mfst >> $rdir/runner.log 2>&1'
sleep 6
tmux has-session -t megadl 2>/dev/null && echo SESSION_OK || echo SESSION_FAIL
tail -3 $rdir/runner.log" 2>&1 | tail -6
    c_ok "已在 tmux 会话 megadl 中启动第 $rn 轮"
}

cmd_listen() {
    local rn="${1:?用法: bootstrap.sh listen <NN>}"
    local iv="${2:-20}" rc="${3:-20}"
    rm -f "$WORK/vps_signal.txt"
    exec "$WORK/listen.sh" "$REMOTE_DIR/round$rn" "$REMOTE_DIR/round${rn}_manifest.tsv" "$iv" "$rc"
}

cmd_wait() {
    local rn="${1:?用法: bootstrap.sh wait <NN>}"
    cmd_run "$rn" || return 1
    cmd_listen "$rn" "${2:-20}" "${3:-20}"
}

cmd_stop() {
    c_warn "中断任务..."
    vps_run 'touch '"$REMOTE_DIR"'/STOP
tmux kill-session -t megadl 2>/dev/null && echo "tmux 会话已停"
mega-transfers -c -a 2>&1 | head -2' 2>&1 | head -4
    c_ok "已发送中断信号"
}

# --------------------------------------------------------------------------
sub="${1:-help}"; shift 2>/dev/null || true
case "$sub" in
    doctor)  cmd_doctor ;;
    status)  cmd_status ;;
    rounds)  cmd_rounds ;;
    run)     cmd_run "$@" ;;
    listen)  cmd_listen "$@" ;;
    wait)    cmd_wait "$@" ;;
    stop)    cmd_stop ;;
    creds)   cmd_creds ;;
    vps)     vps_run "$@" ;;
    *)  awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0" ;;
esac
