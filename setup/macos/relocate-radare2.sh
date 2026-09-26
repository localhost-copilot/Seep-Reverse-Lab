#!/usr/bin/env bash
# ==============================================================================
#  Seep Reverse Lab — 把官方 macOS radare2 .pkg 重定位为可搬迁的仓库内置目录
# ==============================================================================
#  官方 pkg 里的 Mach-O 使用绝对路径依赖 (/usr/local/lib/libr_*.dylib) 且没有 LC_RPATH，
#  直接搬到仓库内无法运行。本脚本：
#    1) 解包 pkg（不安装、不写入 /usr/local，完全不动系统）
#    2) 复制 bin/ lib/ share/ 到 Tool/mcp/Tool/safe/radare2/macos-arm64/
#    3) 用 install_name_tool 把 /usr/local/lib/* 改写为 @executable_path/@loader_path
#    4) ad-hoc 重签名（arm64 上修改 Mach-O 后必须重签，否则被内核拒绝执行）
#    5) 自检 rabin2/radare2 是否真的能跑
#
#  用法:
#    setup/macos/relocate-radare2.sh                    # 自动挑 6.2.2（与 Windows 内置版同版本）
#    setup/macos/relocate-radare2.sh -v 6.2.2
#    setup/macos/relocate-radare2.sh -p /path/to/radare2-arm64-6.2.2.pkg
# ==============================================================================
set -euo pipefail

R2_VERSION="6.2.2"
PKG_PATH=""
ARCH_TAG="$(uname -m)"   # arm64 / x86_64

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEST="$ROOT/Tool/mcp/Tool/safe/radare2/macos-$ARCH_TAG"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/seep-r2reloc.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

C_G='\033[32m'; C_Y='\033[33m'; C_R='\033[31m'; C_C='\033[36m'; C_0='\033[0m'
ok()   { printf "  ${C_G}[OK]${C_0} %s\n" "$1"; }
info() { printf "  ${C_C}[..]${C_0} %s\n" "$1"; }
warn() { printf "  ${C_Y}[!!]${C_0} %s\n" "$1"; }
err()  { printf "  ${C_R}[XX]${C_0} %s\n" "$1"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -v|--version) R2_VERSION="$2"; shift 2 ;;
    -p|--pkg)     PKG_PATH="$2";   shift 2 ;;
    -h|--help)    sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) err "未知参数: $1"; exit 2 ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || { err "本脚本仅用于 macOS"; exit 1; }
for t in install_name_tool codesign otool curl; do
  command -v "$t" >/dev/null 2>&1 || { err "缺少系统工具: $t（请安装 Xcode Command Line Tools: xcode-select --install）"; exit 1; }
done

printf "\n  Seep · macOS radare2 内置化 (v%s, %s)\n" "$R2_VERSION" "$ARCH_TAG"

# ---------------------------------------------------------------- 1. 取 pkg
if [ -z "$PKG_PATH" ]; then
  PKG_PATH="$WORK/radare2-$ARCH_TAG-$R2_VERSION.pkg"
  URL="https://github.com/radareorg/radare2/releases/download/$R2_VERSION/radare2-$ARCH_TAG-$R2_VERSION.pkg"
  info "下载 $URL"
  if ! curl -fsSL --connect-timeout 20 --retry 2 -o "$PKG_PATH" "$URL"; then
    err "下载失败（网络不可达）。可手动下载该 pkg 后用 -p 指定路径。"
    exit 1
  fi
fi
[ -f "$PKG_PATH" ] || { err "pkg 不存在: $PKG_PATH"; exit 1; }
ok "pkg 就位 ($(du -h "$PKG_PATH" | cut -f1 | tr -d ' '))"

# ---------------------------------------------------------------- 2. 解包
info "解包 pkg（不安装到 /usr/local）"
pkgutil --expand-full "$PKG_PATH" "$WORK/expanded" >/dev/null 2>&1 \
  || { err "pkgutil 解包失败"; exit 1; }
PAYLOAD="$WORK/expanded/Payload/usr/local"
[ -d "$PAYLOAD/bin" ] || { err "pkg payload 结构异常"; exit 1; }
ok "解包完成"

# ---------------------------------------------------------------- 3. 复制
rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$PAYLOAD/bin"   "$DEST/bin"
cp -R "$PAYLOAD/lib"   "$DEST/lib"
[ -d "$PAYLOAD/share" ] && cp -R "$PAYLOAD/share" "$DEST/share"
rm -f "$DEST/bin/clang-format-radare2" 2>/dev/null || true
ok "复制到 Tool/mcp/Tool/safe/radare2/macos-$ARCH_TAG/"

# ---------------------------------------------------------------- 4. 改写依赖
info "改写 install_name（/usr/local/lib/* -> @executable_path|@loader_path）"
fixed_bin=0; fixed_lib=0

for f in "$DEST"/bin/*; do
  [ -f "$f" ] || continue
  file "$f" | grep -q "Mach-O" || continue
  while IFS= read -r dep; do
    install_name_tool -change "$dep" "@executable_path/../lib/$(basename "$dep")" "$f" 2>/dev/null || true
  done < <(otool -L "$f" | tail -n +2 | awk '{print $1}' | grep '^/usr/local/lib/' || true)
  codesign --force --sign - "$f" >/dev/null 2>&1 || true
  fixed_bin=$((fixed_bin+1))
done

while IFS= read -r f; do
  [ -f "$f" ] && [ ! -L "$f" ] || continue
  file "$f" | grep -q "Mach-O" || continue
  while IFS= read -r dep; do
    install_name_tool -change "$dep" "@loader_path/$(basename "$dep")" "$f" 2>/dev/null || true
  done < <(otool -L "$f" | tail -n +2 | awk '{print $1}' | grep '^/usr/local/lib/' || true)
  install_name_tool -id "@loader_path/$(basename "$f")" "$f" 2>/dev/null || true
  codesign --force --sign - "$f" >/dev/null 2>&1 || true
  fixed_lib=$((fixed_lib+1))
done < <(find "$DEST/lib" -name '*.dylib' -type f)
ok "改写并重签: $fixed_bin 个可执行 + $fixed_lib 个 dylib"

# 清理 pkg 安装时不需要的残留（保持精简）
rm -rf "$DEST/share/man" 2>/dev/null || true

# ---------------------------------------------------------------- 5. 自检
info "自检"
R2BIN="$DEST/bin"
FAILED=0
"$R2BIN/radare2" -v >/dev/null 2>&1 || { err "radare2 无法执行"; FAILED=1; }
"$R2BIN/rabin2"  -v >/dev/null 2>&1 || { err "rabin2 无法执行";  FAILED=1; }
if [ "$FAILED" -eq 0 ]; then
  VER="$("$R2BIN/radare2" -v 2>/dev/null | head -1)"
  ok "radare2 可执行: $VER"
  FUNCS="$("$R2BIN/radare2" -q -e scr.color=0 -c 'aaa; aflc; q' /bin/ls 2>/dev/null | tail -1 | tr -dc '0-9')"
  if [ -n "$FUNCS" ] && [ "$FUNCS" -gt 10 ] 2>/dev/null; then
    ok "分析引擎自检通过（/bin/ls 解析出 $FUNCS 个函数）"
  else
    warn "分析引擎自检异常（aflc 返回: ${FUNCS:-空}）"
  fi
else
  err "radare2 内置化失败"
  exit 1
fi

printf "\n  ${C_G}macOS radare2 %s 已内置到仓库，Windows 版 bin/ 未被改动。${C_0}\n\n" "$R2_VERSION"
