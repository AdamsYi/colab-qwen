#!/bin/bash
# 一键关机：停隧道，释放 Colab 运行时（立即停止扣计算单元）。
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
"$HERE/tunnel.sh" stop
"${COLAB:-$HOME/.local/bin/colab}" stop -s colab
"${COLAB:-$HOME/.local/bin/colab}" usage | tail -3
