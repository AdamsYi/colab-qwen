#!/bin/bash
# 一键开机：开 Colab GPU → 拉本仓库部署 → 建本地隧道 → 打印 zcode 填法。
# 用法：mac/up.sh [A100|L4|T4 ...]，不带参数按 A100 → L4 → T4 依次尝试。
set -euo pipefail

COLAB=${COLAB:-$HOME/.local/bin/colab}
SESSION=colab
REPO=${REPO:-AdamsYi/colab-qwen}
CONF=$HOME/.config/colab-qwen
KEY_FILE=$CONF/key
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
LOCAL_PORT=${LOCAL_PORT:-8089}
GPUS=("$@"); (( ${#GPUS[@]} )) || GPUS=(A100 L4 T4)

mkdir -p "$CONF"; chmod 700 "$CONF"
[[ -s "$KEY_FILE" ]] || { echo "sk-colab-$(openssl rand -hex 16)" >"$KEY_FILE"; chmod 600 "$KEY_FILE"; }
API_KEY=$(cat "$KEY_FILE")

# 在运行时里跑一段 Python（colab exec 单次约 60 秒超时，只放短操作）。
run_py() {
    local f; f=$(mktemp "$CONF/exec.XXXXXX.py")
    cat >"$f"
    "$COLAB" exec -s "$SESSION" -f "$f" 2>&1 | grep -v '^\[colab\]' || true
    rm -f "$f"
}

# 1. 开机（已有同名会话就复用）
if "$COLAB" sessions 2>/dev/null | grep -q "^\[$SESSION\]"; then
    echo "复用已有会话 $SESSION"
else
    ok=0
    for g in "${GPUS[@]}"; do
        echo "尝试开 $g ..."
        if "$COLAB" new -s "$SESSION" --gpu "$g" && "$COLAB" status -s "$SESSION" >/dev/null 2>&1; then
            ok=1; break
        fi
    done
    (( ok )) || { echo "开不到 GPU：${GPUS[*]}"; exit 1; }
fi
"$COLAB" status -s "$SESSION" | tail -1

# 2. 拉仓库、写 Key、后台跑 bootstrap
run_py <<EOF
import subprocess, os
open("/content/.qwen_key", "w").write("$API_KEY"); os.chmod("/content/.qwen_key", 0o600)
os.makedirs("/content/logs", exist_ok=True)
subprocess.run("if [ -d /content/colab-qwen ]; then git -C /content/colab-qwen pull -q; "
               "else git clone -q https://github.com/$REPO /content/colab-qwen; fi", shell=True)
subprocess.Popen("exec setsid nohup bash /content/colab-qwen/colab/bootstrap.sh "
                 ">/content/logs/bootstrap.log 2>&1 </dev/null", shell=True)
print("bootstrap 已在后台启动")
EOF

# 3. 等就绪
last=""
while :; do
    st=$(run_py <<'EOF'
try: print(open("/content/logs/status").read().strip())
except FileNotFoundError: print("STARTING")
EOF
)
    st=$(echo "$st" | tail -1)
    [[ "$st" != "$last" ]] && { echo "[$(date +%T)] $st"; last=$st; }
    case "$st" in READY*) break ;; FAILED*) exit 1 ;; esac
    sleep 15
done

# 4. 第一次编译出来的程序存到 GitHub Releases，下次直接拿
need=$(run_py <<'EOF'
import os; print("yes" if os.path.exists("/content/logs/need_upload") else "no")
EOF
)
if [[ "$(echo "$need" | tail -1)" == yes ]]; then
    echo "上传编译好的 llama.cpp 到 GitHub Releases ..."
    tmp=$(mktemp -d)
    "$COLAB" download -s "$SESSION" /content/llama-bin.tar.gz "$tmp/llama-bin.tar.gz"
    gh release view llama-bin -R "$REPO" >/dev/null 2>&1 \
        || gh release create llama-bin -R "$REPO" -t "llama.cpp CUDA 程序" \
            -n "Colab 上编译的 llama-server（sm 75/80/89/90），bootstrap.sh 自动下载。"
    gh release upload llama-bin -R "$REPO" "$tmp/llama-bin.tar.gz" --clobber
    rm -rf "$tmp"
    run_py <<'EOF'
import os; os.remove("/content/logs/need_upload")
EOF
fi

# 5. 本地隧道（断线自动重连）
"$HERE/tunnel.sh" start
for _ in $(seq 1 20); do
    curl -fs -m 5 -o /dev/null "http://127.0.0.1:$LOCAL_PORT/v1/models" -H "Authorization: Bearer $API_KEY" && break
    sleep 3
done

cat <<EOF

已就绪。zcode 填：
  Base URL : http://127.0.0.1:$LOCAL_PORT/v1
  API Key  : $API_KEY
  模型名   : Huihui-Qwen3.8-27B-abliterated
用完关机：$HERE/down.sh
EOF
