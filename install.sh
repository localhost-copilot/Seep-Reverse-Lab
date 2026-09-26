#!/usr/bin/env bash
# ==============================================================================
#  Seep Reverse Lab — 根目录快捷安装入口 (macOS / Linux)
# ==============================================================================
#  与 Windows 的 setup/install.ps1 对等。
#
#  用法:
#    ./install.sh                 # 完整安装 + 自检
#    ./install.sh --only-verify   # 只自检
#    ./install.sh --register-dsh  # 额外写入 DSH profile（会先备份）
# ==============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/setup/install-macos.sh" "$@"
