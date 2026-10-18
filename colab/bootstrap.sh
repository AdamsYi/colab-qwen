#!/bin/bash
# 在 Colab 运行时里执行：取 llama.cpp 程序、下载模型、启动服务。
# 由 mac/up.sh 通过 colab exec 在后台调用；进度写在 /content/logs/status。
# 可用环境变量覆盖：MODEL_FILE、CTX、REPO。
set -uo pipefail

REPO=${REPO:-AdamsYi/colab-qwen}
HF_REPO=huihui-ai/Huihui-Qwen3.8-27B-abliterated-GGUF
MMPROJ=mmproj-model-bf16.gguf
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
LOG=/content/logs
BIN=/content/llama-bin
MODELS=/content/models
mkdir -p "$LOG" "$MODELS"
# Colab 的显卡驱动库（libcuda）在 /usr/lib64-nvidia，只在 notebook 内核环境里配了路径。
export LD_LIBRARY_PATH=/usr/lib64-nvidia:${LD_LIBRARY_PATH:-}
status() { echo "$*" >"$LOG/status"; echo "[$(date +%T)] $*"; }

API_KEY=$(cat /content/.qwen_key 2>/dev/null) || { status "FAILED 没有 /content/.qwen_key"; exit 1; }

# 只为当前这张卡编译（A100=80、L4=89、T4=75、G4=120），Releases 按架构分别存。
SM=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -1 | tr -d .)
BIN_URL=https://github.com/$REPO/releases/download/llama-bin/llama-bin-sm$SM.tar.gz

# 按显存挑量化和上下文：A100 40G 跑 Q8，24G 跑 Q4，T4 16G 跑 IQ3。
VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)
if [[ -z "${MODEL_FILE:-}" ]]; then
    if (( VRAM >= 38000 )); then MODEL_FILE=Huihui-Qwen3.8-27B-abliterated-UD-DW-Q8_K_L.gguf; CTX=${CTX:-131072}
    elif (( VRAM >= 22000 )); then MODEL_FILE=Huihui-Qwen3.8-27B-abliterated-UD-Q4_K_XL.gguf; CTX=${CTX:-131072}
    else MODEL_FILE=Huihui-Qwen3.8-27B-abliterated-UD-IQ3_XXS.gguf; CTX=${CTX:-32768}
    fi
fi
CTX=${CTX:-131072}
echo "VRAM=${VRAM}MiB MODEL=$MODEL_FILE CTX=$CTX"

# 模型下载和取程序并行。
status "DOWNLOADING 模型 $MODEL_FILE"
pip -q install -U huggingface_hub hf_xet >/dev/null 2>&1
( hf download "$HF_REPO" "$MODEL_FILE" "$MMPROJ" --local-dir "$MODELS" >"$LOG/dl.log" 2>&1 \
    && touch "$LOG/dl.ok" ) &
DL_PID=$!

if [[ ! -x "$BIN/llama-server" ]]; then
    if curl -fsSL "$BIN_URL" -o /content/llama-bin.tar.gz; then
        mkdir -p "$BIN" && tar -xzf /content/llama-bin.tar.gz -C "$BIN"
        echo "已从 Releases 取到编译好的程序"
    fi
fi
if ! LD_LIBRARY_PATH=$BIN:$LD_LIBRARY_PATH "$BIN/llama-server" --version >/dev/null 2>&1; then
    # 这张卡第一次用或程序不兼容：源码编译（约 8 分钟），编好打包等 up.sh 取回上传。
    status "BUILDING 首次编译 llama.cpp sm$SM（约 8 分钟）"
    rm -rf "$BIN" /content/llama.cpp
    export PATH=/usr/local/cuda/bin:$PATH CUDACXX=/usr/local/cuda/bin/nvcc
    git clone --depth 1 https://github.com/ggml-org/llama.cpp /content/llama.cpp >"$LOG/build.log" 2>&1 \
    && cmake -S /content/llama.cpp -B /content/llama.cpp/build -DGGML_CUDA=ON \
        -DCMAKE_CUDA_ARCHITECTURES="$SM" -DLLAMA_CURL=OFF >>"$LOG/build.log" 2>&1 \
    && cmake --build /content/llama.cpp/build --config Release -j "$(nproc)" --target llama-server >>"$LOG/build.log" 2>&1 \
    || { status "FAILED 编译失败，见 $LOG/build.log"; exit 1; }
    mkdir -p "$BIN" && cp -a /content/llama.cpp/build/bin/. "$BIN/"
    tar -czf /content/llama-bin.tar.gz -C "$BIN" .
    echo "$SM" >"$LOG/need_upload"
fi

status "DOWNLOADING 等模型下载完"
wait "$DL_PID"
[[ -f "$LOG/dl.ok" ]] || { status "FAILED 模型下载失败，见 $LOG/dl.log"; exit 1; }

status "LOADING 加载模型"
pkill -x llama-server; pkill -f 'tool_sanitizer:app'; sleep 2
cd /content
LD_LIBRARY_PATH=$BIN:$LD_LIBRARY_PATH setsid nohup "$BIN/llama-server" \
    -m "$MODELS/$MODEL_FILE" --mmproj "$MODELS/$MMPROJ" \
    --host 127.0.0.1 --port 8000 -c "$CTX" --parallel 1 -ngl 999 --flash-attn on \
    --cache-type-k q8_0 --cache-type-v q8_0 --jinja --no-context-shift \
    --alias Huihui-Qwen3.8-27B-abliterated --api-key "$API_KEY" \
    >"$LOG/server.log" 2>&1 </dev/null &
SANITIZER_UPSTREAM=http://127.0.0.1:8000 setsid nohup python3 -m uvicorn --app-dir "$HERE" \
    --host 127.0.0.1 --port 8001 --no-access-log tool_sanitizer:app \
    >"$LOG/sanitizer.log" 2>&1 </dev/null &

for _ in $(seq 1 120); do
    if curl -fs -m 2 http://127.0.0.1:8000/health >/dev/null; then
        status "READY $MODEL_FILE ctx=$CTX"
        exit 0
    fi
    pgrep -x llama-server >/dev/null || { status "FAILED llama-server 退出，见 $LOG/server.log"; exit 1; }
    sleep 5
done
status "FAILED 加载超时，见 $LOG/server.log"
exit 1
