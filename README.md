# colab-qwen

在 Google Colab GPU 上一键部署 Huihui-Qwen3.8-27B-abliterated（llama.cpp），通过官方 Colab CLI 的 SSH 通道映射到本机，给 zcode 等 OpenAI 兼容客户端用。

## 前提（Mac 上一次性准备）

- `uv tool install google-colab-cli`，并登录过一次（`colab sessions`）
- `gh` 已登录（只在第一次上传编译好的程序时用到）

## 用法

```bash
mac/up.sh          # 依次尝试 A100 → L4 → T4；也可指定：mac/up.sh L4
mac/down.sh        # 停隧道并释放运行时，立即停止扣计算单元
mac/tunnel.sh start|stop|status   # 只管本地隧道
```

`up.sh` 结束时会打印 zcode 填法：

- Base URL：`http://127.0.0.1:8089/v1`
- API Key：首次运行生成，存在 `~/.config/colab-qwen/key`，不进仓库
- 模型名：`Huihui-Qwen3.8-27B-abliterated`

## 流程

1. `colab new` 开 GPU 运行时
2. 运行时里 `git clone` 本仓库，后台执行 `colab/bootstrap.sh`：
   - 从本仓库 Releases（tag `llama-bin`）取编译好的 llama-server；没有或不兼容就源码编译（约 15 分钟），编好由 `up.sh` 上传到 Releases，之后不再编译
   - 从 Hugging Face 下载模型（A100 下约 1.5 分钟）
   - 启动 llama-server（8000，带 API Key）和 `tool_sanitizer.py`（8001）
3. 本机建 SSH 隧道 `127.0.0.1:8089 → 运行时 8001`，断线自动重连

## 按显存自动选模型

| 显存 | 模型文件 | 上下文 |
|---|---|---|
| ≥ 38GB（A100） | UD-DW-Q8_K_L（27GB） | 128K |
| ≥ 22GB（L4） | UD-Q4_K_XL（17GB） | 128K |
| 其他（T4） | UD-IQ3_XXS（11GB） | 32K |

KV 缓存统一 q8_0。可用环境变量 `MODEL_FILE`、`CTX` 覆盖。

## tool_sanitizer.py 是干什么的

zcode 这类客户端每次请求带几十个工具定义，里面的 `maxLength`、`maxItems` 等约束会让 llama.cpp 编译工具调用语法时超出规则上限，整次请求报 `failed to parse grammar`。这个小代理在转发前去掉这些约束（不影响工具调用本身）。

## 注意

- 运行时关掉后一切清空，下次 `up.sh` 重新下载模型（程序走 Releases 缓存）
- 只在本机经 SSH 访问，不对公网开放端口
