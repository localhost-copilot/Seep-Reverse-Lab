#!/usr/bin/env bash
# ==============================================================================
#  Seep 逆向工程工作台 —— macOS/Linux 部署完备性体检 (Verifier)
# ==============================================================================
#  与 Windows 的 setup/verify.ps1 对等：同样输出 6 维度体检卡片与 READY 结论，
#  并把「Windows 独占」的检查项替换为本机原生实现（原生 r2 / POSIX jadx / ida-mcp-rs）。
#
#  用法:
#    ./check.sh                        # 根目录快捷入口
#    setup/verify-macos.sh             # 等价
#    setup/verify-macos.sh --fast      # 跳过端到端冒烟测试（快速静态体检）
#    setup/verify-macos.sh --deep      # 冒烟测试包含真实 APK 反编译/解包
# ==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOL_DIR="$ROOT/Tool"
MCP_DIR="$TOOL_DIR/mcp"
SAFE_DIR="$MCP_DIR/Tool/safe"
VENV="$MCP_DIR/.venv-macos"
KB_DIR="$MCP_DIR/Tool/reverselab/kb"
ARCH="$(uname -m)"

C_G='\033[32m'; C_Y='\033[33m'; C_R='\033[31m'; C_C='\033[36m'; C_B='\033[1m'; C_D='\033[2m'; C_0='\033[0m'

PASS_COUNT=0; FAIL_LIST=(); OPTN_LIST=()
SHOW_BANNER=1; FAST=0; DEEP=0

while [ $# -gt 0 ]; do
  case "$1" in
    --no-banner) SHOW_BANNER=0; shift ;;
    --fast) FAST=1; shift ;;
    --deep) DEEP=1; shift ;;
    -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) shift ;;
  esac
done

check_item() {   # check_item <分类> <名称> <命令...>
  local cat="$1" name="$2"; shift 2
  if "$@" >/dev/null 2>&1; then
    printf "  ${C_G}[√ PASS]${C_0} %s\n" "$name"; PASS_COUNT=$((PASS_COUNT+1))
  else
    printf "  ${C_R}[X FAIL]${C_0} %s\n" "$name"; FAIL_LIST+=("$cat|$name")
  fi
}

check_item_detail() { # check_item_detail <分类> <名称> <详情> <命令...>
  local cat="$1" name="$2" detail="$3"; shift 3
  if "$@" >/dev/null 2>&1; then
    printf "  ${C_G}[√ PASS]${C_0} %s  ${C_D}%s${C_0}\n" "$name" "$detail"; PASS_COUNT=$((PASS_COUNT+1))
  else
    printf "  ${C_R}[X FAIL]${C_0} %s  ${C_D}%s${C_0}\n" "$name" "$detail"; FAIL_LIST+=("$cat|$name")
  fi
}

optn_item() {    # optn_item <分类> <名称> <说明> <命令...>
  local cat="$1" name="$2" note="$3"; shift 3
  if "$@" >/dev/null 2>&1; then
    printf "  ${C_G}[√ PASS]${C_0} %s\n" "$name"; PASS_COUNT=$((PASS_COUNT+1))
  else
    printf "  ${C_Y}[! OPTN]${C_0} %s ${C_D}(%s)${C_0}\n" "$name" "$note"; OPTN_LIST+=("$cat|$name|$note")
  fi
}

section() { printf "\n${C_B}%s${C_0}\n" "$1"; }
have() { [ -e "$1" ]; }

if [ "$SHOW_BANNER" -eq 1 ]; then
  printf "${C_C}"
  cat <<'HDR'
================================================================================
          Seep Reverse Lab — 工作台部署完备性校验与健康体检 (Verifier)
================================================================================
HDR
  printf "${C_0}  工作台物理根目录: %s\n" "$ROOT"
  printf "  宿主操作系统环境: %s %s (%s)\n" "$(uname -s)" "$(uname -r)" "$ARCH"
  printf "  运行模式: %s\n" "$([ "$FAST" -eq 1 ] && echo '快速（跳过冒烟测试）' || echo '标准（含端到端冒烟测试）')"
fi

# -----------------------------------------------------------------------------
section "[1/7] 📁 核心架构与工程目录树"
check_item "架构" "工作台主目录完整 (Tool/)"            have "$TOOL_DIR"
check_item "架构" "技能包目录完整 (Tool/skill/)"         have "$TOOL_DIR/skill"
check_item "架构" "MCP 服务引擎目录 (Tool/mcp/)"         have "$MCP_DIR"
check_item "架构" "系统提示词层 (Tool/prompts/)"         have "$TOOL_DIR/prompts"
check_item_detail "架构" "九大脱敏案例工程 (Tool/cases/)" "$(find "$TOOL_DIR/cases" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ') 个项目" \
  bash -c "[ \$(find '$TOOL_DIR/cases' -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l) -ge 9 ]"
check_item "架构" "上游开源验证集 (Tool/upstream/apk-reverse/)" have "$TOOL_DIR/upstream/apk-reverse"
check_item "架构" "MCP 专用运行时强约定 (Tool/mcp/Tool/)"  have "$MCP_DIR/Tool"

# -----------------------------------------------------------------------------
section "[2/7] 📚 攻防实战知识库与战术模板 (KB)"
KB_MD=$(find "$KB_DIR" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
check_item_detail "知识库" "战术实战笔记 (≥280 篇)"       "$KB_MD 篇" \
  bash -c "[ ${KB_MD:-0} -ge 280 ]"
check_item_detail "知识库" "内置 MCP 源码组件 (≥3)"        "$(find "$MCP_DIR/Tool/reverselab/tools/skills/mcp" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ') 个" \
  bash -c "[ \$(find '$MCP_DIR/Tool/reverselab/tools/skills/mcp' -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l) -ge 3 ]"

# -----------------------------------------------------------------------------
section "[3/7] 🧠 智能体指令系统与运行时拦截扩展"
check_item_detail "提示词" "Pi Agent 系统指令 (SYSTEM.md 已脱敏)" "无个人化字符" \
  bash -c "[ -f '$TOOL_DIR/prompts/SYSTEM.md' ] && ! grep -qE '小π|主人' '$TOOL_DIR/prompts/SYSTEM.md'"
check_item "提示词" "通用跨 Agent 规范 (AGENTS.md)"       have "$TOOL_DIR/prompts/AGENTS.md"
check_item "提示词" "Claude Code 项目级规范 (CLAUDE.md)"  have "$ROOT/CLAUDE.md"
check_item "提示词" "DeepSeek Harness 配置 (DSH-PROFILE.md)" have "$ROOT/DSH-PROFILE.md"
check_item "扩展"   "安全放行与 Lab 状态机扩展 (.ts)"      have "$TOOL_DIR/prompts/extensions/security-audit-interceptor.ts"

# -----------------------------------------------------------------------------
section "[4/7] 🛠️ 逆向工程专业技能库 (Skills)"
check_item_detail "Skill" "核心总控调度器 (softseep + ≥8 专题)" \
  "$(find "$TOOL_DIR/skill/softseep/references" -name '*.md' 2>/dev/null | wc -l | tr -d ' ') 篇" \
  bash -c "[ -f '$TOOL_DIR/skill/softseep/SKILL.md' ] && [ \$(find '$TOOL_DIR/skill/softseep/references' -name '*.md' 2>/dev/null | wc -l) -ge 8 ]"
check_item "Skill" "移动端逆向全链路 (apkseep)" \
  bash -c "[ -f '$TOOL_DIR/skill/apkseep/SKILL.md' ] && [ -d '$TOOL_DIR/skill/apkseep/references' ] && [ -d '$TOOL_DIR/skill/apkseep/scripts' ]"
check_item "Skill" "IDA Pro 自动化联动 (ida-reverse)"     have "$TOOL_DIR/skill/ida-reverse/SKILL.md"
check_item "Skill" "通用许可/卡密校验突破规范"             have "$TOOL_DIR/skill/client-license-validation-bypass/SKILL.md"
check_item_detail "Skill" "独立战术安全技能包 (≥5 组)"     "$(find "$TOOL_DIR/skill/safe-skills" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ') 组" \
  bash -c "[ \$(find '$TOOL_DIR/skill/safe-skills' -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l) -ge 5 ]"

# -----------------------------------------------------------------------------
section "[5/7] 🔧 内置工具箱（macOS 原生实现）"

R2_BIN_DIR=""
if [ -x "$SAFE_DIR/radare2/macos-$ARCH/bin/radare2" ]; then
  R2_BIN_DIR="$SAFE_DIR/radare2/macos-$ARCH/bin"; R2_SRC="仓库内置 macos-$ARCH"
elif command -v radare2 >/dev/null 2>&1; then
  R2_BIN_DIR="$(dirname "$(command -v radare2)")"; R2_SRC="系统安装"
fi

if [ -n "$R2_BIN_DIR" ]; then
  R2_VER="$("$R2_BIN_DIR/radare2" -v 2>/dev/null | head -1)"
  check_item_detail "工具箱" "radare2 引擎（原生可执行）" "$R2_SRC · $R2_VER" \
    bash -c "'$R2_BIN_DIR/radare2' -v"
  for t in rabin2 radiff2 rasm2 rahash2; do
    check_item "工具箱" "radare2 套件组件 ($t)" have "$R2_BIN_DIR/$t"
  done
  check_item_detail "工具箱" "分析引擎实跑 (/bin/ls)" \
    "$("$R2_BIN_DIR/radare2" -q -e scr.color=0 -c 'aaa; aflc; q' /bin/ls 2>/dev/null | tail -1 | tr -dc '0-9') 个函数" \
    bash -c "'$R2_BIN_DIR/radare2' -q -e scr.color=0 -c 'aaa; aflc; q' /bin/ls | grep -qE '^[0-9]+$'"
else
  check_item "工具箱" "radare2 引擎（原生可执行）" false
fi

# Windows 版 exe 是否仍完整保留（不做平台破坏）
check_item "工具箱" "Windows 版 radare2 未被破坏 (bin/*.exe 保留)" \
  bash -c "[ -f '$SAFE_DIR/radare2/bin/radare2.exe' ] && [ -f '$SAFE_DIR/radare2/bin/rabin2.exe' ]"

JADX_JAR="$(ls "$SAFE_DIR/jadx"/lib/jadx-*-all.jar 2>/dev/null | head -1)"
check_item_detail "工具箱" "Jadx 反编译引擎" "$(basename "${JADX_JAR:-缺失}")" \
  bash -c "[ -n '$JADX_JAR' ] && [ -f '$MCP_DIR/posix-bin/jadx' ]"
check_item "工具箱" "Apktool 拆解重构环境 (apktool.jar)" have "$SAFE_DIR/apktool/apktool.jar"
check_item "工具箱" "Frida/LSPosed 插桩模板库 (hook-mcp)" have "$SAFE_DIR/hook-mcp/templates"

optn_item "依赖" "js-reverse-mcp 依赖已解压" "运行 setup/install-macos.sh 解压" have "$SAFE_DIR/js-reverse-mcp/node_modules"
optn_item "依赖" "playwright-mcp 依赖已解压" "运行 setup/install-macos.sh 解压" have "$SAFE_DIR/playwright-mcp/node_modules"

# -----------------------------------------------------------------------------
section "[6/7] 🔌 MCP 服务层与外部运行时"

check_item "MCP" "跨平台启动器 (seep_mcp_launcher.py)" have "$MCP_DIR/seep_mcp_launcher.py"
check_item "MCP" "核心服务端脚本 (seep_mcp_server.py)" have "$MCP_DIR/seep_mcp_server.py"
check_item "MCP" "服务端语法自洽 (语法解析)" \
  bash -c "python3 -c \"import ast,sys; ast.parse(open('$MCP_DIR/seep_mcp_server.py',encoding='utf-8').read())\""

if [ -x "$VENV/bin/python" ]; then
  check_item_detail "运行时" "Python venv (3.11+)" "$("$VENV/bin/python" --version 2>&1)" true
  check_item "运行时" "mcp 协议库 (mcp>=1.20,<1.29)" \
    bash -c "'$VENV/bin/python' -c 'import mcp'"
  check_item_detail "MCP" "原生工具链解析 (launcher --diagnose)" \
    "$("$VENV/bin/python" "$MCP_DIR/seep_mcp_launcher.py" --diagnose 2>/dev/null | sed -n 's/.*"version": "\([^"]*\)".*/\1/p' | head -1)" \
    bash -c "'$VENV/bin/python' '$MCP_DIR/seep_mcp_launcher.py' --diagnose | grep -q '\"radare2\"'"
else
  check_item "运行时" "Python venv (Tool/mcp/.venv-macos)" false
fi

IDA_BIN="$SAFE_DIR/ida-mcp-rs/bin/ida-mcp"
optn_item "商业软件" "IDA Pro 授权与 ida-mcp-rs 桥接" "无 IDA 授权时由 Radare2 承接" \
  bash -c "ls /Applications/IDA*.app >/dev/null 2>&1"
optn_item "MCP" "ida-mcp-rs 原生服务 (Darwin)" "运行 setup/macos/install-ida-mcp.sh" \
  bash -c "[ -x '$IDA_BIN' ] && '$IDA_BIN' --version"

check_item "配置" "Claude Code 项目级 MCP 注册 (.mcp.json)" \
  bash -c "[ -f '$ROOT/.mcp.json' ] && grep -q 'seep_mcp_launcher' '$ROOT/.mcp.json'"
check_item "配置" "macOS 权威注册副本 (.mcp.macos.json)" have "$ROOT/.mcp.macos.json"

JAVA_EXE=""
for c in "${JAVA_HOME:-}" /opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home \
         /usr/local/opt/openjdk/libexec/openjdk.jdk/Contents/Home \
         /Library/Java/JavaVirtualMachines/*/Contents/Home \
         "/Applications/Android Studio.app/Contents/jbr/Contents/Home"; do
  [ -n "$c" ] && [ -x "$c/bin/java" ] && "$c/bin/java" -version >/dev/null 2>&1 && { JAVA_EXE="$c/bin/java"; break; }
done
optn_item "运行时" "JDK（jadx/apktool 依赖）" "brew install openjdk" \
  bash -c "[ -n '$JAVA_EXE' ]"

# --- 端到端冒烟测试 -----------------------------------------------------------
if [ "$FAST" -eq 1 ]; then
  printf "  ${C_Y}[! OPTN]${C_0} 端到端冒烟测试 ${C_D}(已按 --fast 跳过)${C_0}\n"
  OPTN_LIST+=("冒烟|端到端冒烟测试|--fast 跳过")
elif [ -x "$VENV/bin/python" ]; then
  SMOKE_ARGS=""
  [ "$DEEP" -eq 1 ] && SMOKE_ARGS="--deep"
  SMOKE_LOG="$(mktemp "${TMPDIR:-/tmp}/seep-smoke.XXXXXX")"
  if "$VENV/bin/python" "$SCRIPT_DIR/macos/smoke-test.py" $SMOKE_ARGS >"$SMOKE_LOG" 2>&1; then
    SUMMARY="$(grep -o '结果:.*' "$SMOKE_LOG" | sed 's/\x1b\[[0-9;]*m//g' | head -1)"
    printf "  ${C_G}[√ PASS]${C_0} 端到端冒烟测试 (MCP stdio 握手 + 实机工具调用)  ${C_D}%s${C_0}\n" "$SUMMARY"
    PASS_COUNT=$((PASS_COUNT+1))
  else
    printf "  ${C_R}[X FAIL]${C_0} 端到端冒烟测试 ${C_D}(日志: %s)${C_0}\n" "$SMOKE_LOG"
    FAIL_LIST+=("冒烟|端到端冒烟测试")
  fi
fi

# -----------------------------------------------------------------------------
section "[7/7] 📚 MANUAL/ 战术手册完备性校验"
check_item "手册" "环境预要求指南 (MANUAL/PREREQUISITES.md)" have "$ROOT/MANUAL/PREREQUISITES.md"
check_item "手册" "IDA Pro 商业软件接入指南 (MANUAL/IDA-PRO.md)" have "$ROOT/MANUAL/IDA-PRO.md"
check_item "手册" "反调试绕过战术手册 (MANUAL/ANTI-DEBUG.md)" have "$ROOT/MANUAL/ANTI-DEBUG.md"
check_item "手册" "通用脱壳前置分析 SOP (MANUAL/UNPACKING.md)" have "$ROOT/MANUAL/UNPACKING.md"
check_item "手册" "PoC 闭环自动化验证 SOP (MANUAL/POC-VALIDATION.md)" have "$ROOT/MANUAL/POC-VALIDATION.md"
check_item "手册" "macOS 兼容与安装指南 (MANUAL/MACOS.md)" have "$ROOT/MANUAL/MACOS.md"

# -----------------------------------------------------------------------------
printf "\n${C_B}================================================================================${C_0}\n"
printf "  ${C_G}[体检报告] 核心检查通过: %d 项${C_0}\n" "$PASS_COUNT"

if [ ${#FAIL_LIST[@]} -gt 0 ]; then
  printf "\n  ${C_R}[!] 发现异常阻断项 (%d 项):${C_0}\n" "${#FAIL_LIST[@]}"
  for e in "${FAIL_LIST[@]}"; do printf "    * [%s] %s\n" "${e%%|*}" "${e##*|}"; done
fi
if [ ${#OPTN_LIST[@]} -gt 0 ]; then
  printf "\n  ${C_Y}[*] 可选/建议关注项 (%d 项):${C_0}\n" "${#OPTN_LIST[@]}"
  for t in "${OPTN_LIST[@]}"; do
    printf "    * [%s] %s  ${C_D}-> %s${C_0}\n" "$(printf '%s' "$t" | cut -d'|' -f1)" "$(printf '%s' "$t" | cut -d'|' -f2)" "$(printf '%s' "$t" | cut -d'|' -f3)"
  done
fi
printf "${C_B}================================================================================${C_0}\n"

if [ ${#FAIL_LIST[@]} -eq 0 ]; then
  printf "\n  ${C_G}🎉 结论: 工作台处于 [READY / 完备就绪] 状态！${C_0}\n"
  printf "  您可以直接在 Agent (DSH / Claude Code / pi) 中发送: ${C_C}lab：${C_0} 开启测试！\n\n"
  exit 0
else
  printf "\n  ${C_R}❌ 结论: 当前工作台存在未满足的核心依赖，请按上述红色项修复。${C_0}\n\n"
  exit 1
fi
