#!/usr/bin/env bash
# ==============================================================================
#  Seep Reverse Lab — macOS IDA MCP 原生化安装 (blacktop/ida-mcp-rs)
# ==============================================================================
#  背景：
#    随包的 ida-pro-mcp 是「IDA GUI 插件 + Windows venv + HTTP 13337」形态，
#    在 macOS 上既没有可用 venv，也没有对应的插件二进制。
#    ida-mcp-rs 是 Rust 编写的 headless IDA MCP 服务（基于 idalib），官方直接
#    发布 Darwin arm64/x86_64 版，工具以 stdio MCP 形式暴露，无需 GUI、无需插件。
#
#  行为：
#    1) 探测本机 IDA 版本（/Applications/IDA *.app），选择版本号匹配的 ida-mcp 发行版
#       （ida-mcp 版本号跟随 IDA 版本：IDA 9.4 → ida-mcp 9.4.x）
#    2) 下载对应 Darwin 压缩包，用上游 checksums.txt 校验 SHA-256
#    3) 安装到 Tool/mcp/Tool/safe/ida-mcp-rs/bin/ida-mcp
#    4) 实机自检 ida-mcp --version
#    未检测到 IDA Pro 时：跳过安装并提示（按 CLAUDE.md 红线 3，自动由 Radare2 承接）
#
#  用法:
#    setup/macos/install-ida-mcp.sh              # 自动匹配本机 IDA 版本
#    setup/macos/install-ida-mcp.sh -v 9.4.4     # 指定 ida-mcp 版本
#    setup/macos/install-ida-mcp.sh --force      # 即使没有 IDA 也安装（离线预置）
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEST="$ROOT/Tool/mcp/Tool/safe/ida-mcp-rs"
REPO="blacktop/ida-mcp-rs"

C_G='\033[32m'; C_Y='\033[33m'; C_R='\033[31m'; C_C='\033[36m'; C_0='\033[0m'
ok()   { printf "  ${C_G}[OK]${C_0} %s\n" "$1"; }
info() { printf "  ${C_C}[..]${C_0} %s\n" "$1"; }
warn() { printf "  ${C_Y}[!!]${C_0} %s\n" "$1"; }
err()  { printf "  ${C_R}[XX]${C_0} %s\n" "$1"; }

WANT_VERSION=""
FORCE=0
SKIP_CHECKSUM=0
NO_PROBE=0

while [ $# -gt 0 ]; do
  case "$1" in
    -v|--version) WANT_VERSION="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --no-checksum) SKIP_CHECKSUM=1; shift ;;
    --no-probe) NO_PROBE=1; shift ;;
    -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) err "未知参数: $1"; exit 2 ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || { err "本脚本仅用于 macOS"; exit 1; }

printf "\n  Seep · macOS IDA MCP 原生化 (blacktop/ida-mcp-rs)\n"

# ---------------------------------------------------------------- 1. 探测 IDA
IDA_HOME=""
IDA_VER=""
if [ -n "${IDADIR:-}" ] && [ -d "${IDADIR}" ]; then
  IDA_HOME="$IDADIR"
fi
if [ -z "$IDA_HOME" ]; then
  for app in /Applications/IDA*.app "$HOME"/Applications/IDA*.app; do
    [ -d "$app" ] || continue
    if [ -d "$app/Contents/MacOS" ]; then
      IDA_HOME="$app/Contents/MacOS"
      break
    fi
  done
fi

if [ -n "$IDA_HOME" ]; then
  IDA_VER="$(basename "$(dirname "$(dirname "$IDA_HOME")")" | sed -n 's/.*[^0-9]\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')"
  ok "检测到 IDA: $IDA_HOME (版本 ${IDA_VER:-未知})"
else
  warn "未检测到 IDA Pro 安装（/Applications/IDA *.app）"
  if [ "$FORCE" -ne 1 ]; then
    warn "跳过 ida MCP 安装。按项目规约，无 IDA 授权时由 Radare2 自动承接，不影响核心链路；"
    warn "如需预置二进制可加 --force，或阅读 MANUAL/IDA-PRO.md。"
    exit 0
  fi
  warn "--force 已启用，安装最新 ida-mcp 备用。"
fi

# ---------------------------------------------------------------- 2. 选定版本
ARCH_TAG="$(uname -m)"
case "$ARCH_TAG" in
  arm64)  ASSET_ARCH="Darwin_arm64" ;;
  x86_64) ASSET_ARCH="Darwin_x86_64" ;;
  *) err "不支持的架构: $ARCH_TAG"; exit 1 ;;
esac

if [ -n "$WANT_VERSION" ]; then
  TAG="v$WANT_VERSION"
else
  info "查询上游发行版列表"
  TAGS="$(curl -fsSL --connect-timeout 20 "https://api.github.com/repos/$REPO/releases?per_page=50" 2>/dev/null \
          | grep -o '"tag_name": *"[^"]*"' | sed 's/.*"tag_name": *"//; s/"$//' || true)"
  if [ -z "$TAGS" ]; then
    err "无法获取发行版列表（网络不可达）"
    exit 1
  fi
  if [ -n "$IDA_VER" ]; then
    TAG="$(printf '%s\n' "$TAGS" | grep -E "^v${IDA_VER//./\\.}\." | head -1 || true)"
    if [ -z "$TAG" ]; then
      warn "上游暂无与 IDA ${IDA_VER} 匹配的版本，回落最新版"
    fi
  fi
  [ -n "${TAG:-}" ] || TAG="$(printf '%s\n' "$TAGS" | head -1)"
fi
VER="${TAG#v}"
ASSET="ida-mcp_${VER}_${ASSET_ARCH}.tar.gz"
ok "目标发行版: $TAG / $ASSET"

# 若已安装同版本则跳过
if [ -f "$DEST/VERSION" ] && [ "$(cat "$DEST/VERSION")" = "$VER" ] && [ -x "$DEST/bin/ida-mcp" ]; then
  ok "已是 $VER，无需重新安装（$(du -h "$DEST/bin/ida-mcp" | cut -f1 | tr -d ' ')）"
  "$DEST/bin/ida-mcp" --version 2>/dev/null | sed 's/^/    /' || true
  exit 0
fi

# ---------------------------------------------------------------- 3. 下载与校验
WORK="$(mktemp -d "${TMPDIR:-/tmp}/seep-ida.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
BASE="https://github.com/$REPO/releases/download/$TAG"

info "下载 $ASSET"
curl -fsSL --connect-timeout 20 --retry 2 -o "$WORK/$ASSET" "$BASE/$ASSET" \
  || { err "下载失败: $BASE/$ASSET"; exit 1; }

if [ "$SKIP_CHECKSUM" -ne 1 ]; then
  info "校验 SHA-256"
  if curl -fsSL --connect-timeout 20 -o "$WORK/checksums.txt" "$BASE/checksums.txt" 2>/dev/null; then
    EXPECT="$(grep " $ASSET\$" "$WORK/checksums.txt" | awk '{print $1}' | head -1)"
    ACTUAL="$(shasum -a 256 "$WORK/$ASSET" | awk '{print $1}')"
    if [ -n "$EXPECT" ] && [ "$EXPECT" = "$ACTUAL" ]; then
      ok "校验和一致 (${ACTUAL:0:16}…)"
    elif [ -n "$EXPECT" ]; then
      err "校验和不一致！期望 $EXPECT 实际 $ACTUAL"
      exit 1
    else
      warn "checksums.txt 中未找到该资产，跳过校验"
    fi
  else
    warn "无法获取 checksums.txt，跳过校验"
  fi
fi

# ---------------------------------------------------------------- 4. 安装
info "解包安装到 Tool/mcp/Tool/safe/ida-mcp-rs/"
mkdir -p "$WORK/x" "$DEST/bin"
tar xzf "$WORK/$ASSET" -C "$WORK/x"
SRC_BIN="$(find "$WORK/x" -maxdepth 2 -type f -name 'ida-mcp' | head -1)"
[ -n "$SRC_BIN" ] || { err "压缩包内未找到 ida-mcp 可执行文件"; exit 1; }

install -m 0755 "$SRC_BIN" "$DEST/bin/ida-mcp"
for extra in LICENSE README.md; do
  f="$(find "$WORK/x" -maxdepth 2 -type f -name "$extra" | head -1)"
  [ -n "$f" ] && install -m 0644 "$f" "$DEST/$extra"
done
printf '%s\n' "$VER" > "$DEST/VERSION"
printf 'source: https://github.com/%s/releases/tag/%s\nasset: %s\n' "$REPO" "$TAG" "$ASSET" > "$DEST/PROVENANCE.txt"
ok "已安装 ida-mcp $VER"

# ---------------------------------------------------------------- 5. 自检
info "自检"
if OUT="$("$DEST/bin/ida-mcp" --version 2>&1)"; then
  ok "可执行: $OUT"
else
  err "ida-mcp 无法执行: $OUT"
  exit 1
fi

if [ "$NO_PROBE" -ne 1 ]; then
  # probe 需要可写目录（会在样本旁落 .i64），故复制一个小样本到临时目录实跑
  info "idalib 实机探测（载入样本并跑自动分析，约 10 秒）"
  PWORK="$(mktemp -d "${TMPDIR:-/tmp}/seep-idaprobe.XXXXXX")"
  cp /bin/ls "$PWORK/sample" 2>/dev/null || true
  if [ -f "$PWORK/sample" ]; then
    PROBE_OUT="$("$DEST/bin/ida-mcp" probe --path "$PWORK/sample" 2>&1 || true)"
    RUNTIME_LINE="$(printf '%s' "$PROBE_OUT" | grep -o 'IDA runtime version: [^ ]*' | head -1 || true)"
    FUNCS="$(printf '%s' "$PROBE_OUT" | sed -n 's/.*"function_count": *\([0-9]*\).*/\1/p' | head -1 || true)"
    if [ -n "$RUNTIME_LINE" ]; then
      ok "$RUNTIME_LINE"
      ok "分析链路可用（样本解析出 ${FUNCS:-?} 个函数）"
    else
      warn "idalib 探测未成功："
      printf '%s\n' "$PROBE_OUT" | tail -3 | sed 's/^/      /'
      warn "若为授权或版本问题，请阅读 MANUAL/IDA-PRO.md；核心链路仍由 Radare2 承接。"
    fi
  else
    warn "无法准备探测样本，跳过 idalib 实机探测"
  fi
  rm -rf "$PWORK"
fi

printf "\n  ${C_G}IDA MCP 就绪${C_0}：stdio 服务，命令为\n    %s\n\n" "$DEST/bin/ida-mcp"
