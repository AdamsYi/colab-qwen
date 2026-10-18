#!/bin/bash
# 本地 127.0.0.1:8089 → Colab 运行时 8001 的 SSH 隧道，断线自动重连。
# 用法：tunnel.sh start|stop|status
set -uo pipefail

COLAB=${COLAB:-$HOME/.local/bin/colab}
SESSION=colab
LOCAL_PORT=${LOCAL_PORT:-8089}
CONF=$HOME/.config/colab-qwen
PID_FILE=$CONF/tunnel.pid
LOG=$CONF/tunnel.log

loop() {
    while :; do
        ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
            -o "ProxyCommand=$COLAB ssh --proxy-mode -s $SESSION" \
            -L "$LOCAL_PORT:127.0.0.1:8001" root@colab
        echo "[$(date +%T)] 隧道断开，3 秒后重连"
        sleep 3
    done
}

running() { [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; }

case "${1:-status}" in
    start)
        running && { echo "隧道已在运行"; exit 0; }
        mkdir -p "$CONF"
        nohup bash -c "$(declare -f loop); COLAB='$COLAB' SESSION='$SESSION' LOCAL_PORT='$LOCAL_PORT' loop" \
            >>"$LOG" 2>&1 </dev/null &
        echo $! >"$PID_FILE"
        echo "隧道已启动：127.0.0.1:$LOCAL_PORT（日志 $LOG）"
        ;;
    stop)
        if running; then
            pkill -P "$(cat "$PID_FILE")" 2>/dev/null
            kill "$(cat "$PID_FILE")" 2>/dev/null
        fi
        pkill -f "L $LOCAL_PORT:127.0.0.1:8001" 2>/dev/null
        rm -f "$PID_FILE"
        echo "隧道已停止"
        ;;
    status)
        running && echo "隧道运行中" || echo "隧道未运行"
        ;;
esac
