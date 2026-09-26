#!/usr/bin/env bash
# ==============================================================================
#  Seep Reverse Lab — 根目录快捷体检入口 (macOS / Linux)
# ==============================================================================
#  与 Windows 的 check.ps1 / check.bat 对等。
#
#  用法:
#    ./check.sh              # 标准体检（含端到端冒烟测试）
#    ./check.sh --fast       # 快速静态体检
#    ./check.sh --deep       # 附加真实 APK 反编译/解包验证
# ==============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/setup/verify-macos.sh" "$@"
