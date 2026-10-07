#!/bin/bash
# Helper: run a command on the VPS over SSH (password auth via sshpass).
# Usage: vps.sh '<remote command>'
export PATH="$HOME/.local/bin:$PATH"
exec env SSHPASS="$(cat "$HOME/.ssh/vps_pass")" \
    sshpass -e ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 \
    root@43.228.217.193 "$@"
