#!/usr/bin/env bash
# ==============================================================================
#  Seep 逆向工作台 —— macOS / Linux 一键安装主入口
# ==============================================================================
#  与 Windows 的 setup/install.ps1 对等，但使用原生 POSIX 实现，不依赖 PowerShell。
#  不改写、不删除 Windows 侧任何文件；所有平台差异都在新增文件里落地。
#
#  本脚本只做：环境检测 → Python venv + mcp → 原生 radare2 内置化 → Java/jadx/apktool
#              校验 → Node 依赖解压 → IDA MCP 原生化 → MCP 注册 → 全量自检
#
#  用法:
#    setup/install-macos.sh                 # 完整安装 + 自检
#    setup/install-macos.sh --only-verify   # 只自检
#    setup/install-macos.sh --skip-ida      # 跳过 IDA MCP 安装
#    setup/install-macos.sh --register-dsh  # 额外写入 DSH profile（会先备份）
#    setup/install-macos.sh --no-network    # 禁止联网（只用仓库内置资源）
# ==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MACOS_DIR="$SCRIPT_DIR/macos"
TOOL_DIR="$ROOT/Tool"
SAFE_DIR="$TOOL_DIR/mcp/Tool/safe"
MCP_DIR="$TOOL_DIR/mcp"
VENV="$MCP_DIR/.venv-macos"
POSIX_BIN="$MCP_DIR/posix-bin"
MCP_REQ="mcp>=1.20,<1.29"
ARCH="$(uname -m)"

C_G='\033[32m'; C_Y='\033[33m'; C_R='\033[31m'; C_C='\033[36m'; C_B='\033[1m'; C_0='\033[0m'
FAILED=()
WARNED=()

ok()   { printf "  ${C_G}[OK]${C_0} %s\n" "$1"; }
info() { printf "  ${C_C}[..]${C_0} %s\n" "$1"; }
warn() { printf "  ${C_Y}[!!]${C_0} %s\n" "$1"; WARNED+=("$1"); }
err()  { printf "  ${C_R}[XX]${C_0} %s\n" "$1"; FAILED+=("$1"); }
step() { printf "\n${C_B}=== %s ===${C_0}\n" "$1"; }

# ------------------------------------------------------------------ 参数
ONLY_VERIFY=0; SKIP_DEPS=0; SKIP_IDA=0; REGISTER_DSH=0; NO_NETWORK=0; ASSUME_YES=0
WANT_PY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --only-verify)  ONLY_VERIFY=1; shift ;;
    --skip-deps)    SKIP_DEPS=1; shift ;;
    --skip-ida)     SKIP_IDA=1; shift ;;
    --register-dsh) REGISTER_DSH=1; shift ;;
    --no-network)   NO_NETWORK=1; shift ;;
    -y|--yes)       ASSUME_YES=1; shift ;;
    --py)           WANT_PY="$2"; shift 2 ;;
    -h|--help)      sed -n '2,22p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) printf "  未知参数: %s\n" "$1"; exit 2 ;;
  esac
done

printf "${C_B}"
cat <<'BANNER'
================================================================
  Seep 逆向工程工作台 — macOS/Linux 一键安装
================================================================
BANNER
printf "${C_0}  根目录: %s\n  平台:   %s %s (%s)\n" "$ROOT" "$(uname -s)" "$(uname -r)" "$ARCH"

if [ "$ONLY_VERIFY" -eq 1 ]; then
  exec "$SCRIPT_DIR/verify-macos.sh" "${@:2}"
fi

# ==============================================================================
# 1. 环境检测
# ==============================================================================
step "环境检测"

if [ "$(uname -s)" != "Darwin" ]; then
  warn "当前系统不是 macOS（$(uname -s)）。原生 radare2 内置化目前只对 macOS 打包；"
  warn "Linux 请使用系统 radare2（本启动器会自动回落）。"
else
  ok "macOS $(sw_vers -productVersion 2>/dev/null || echo '?') / $ARCH"
fi

if xcode-select -p >/dev/null 2>&1; then
  ok "Xcode Command Line Tools 就绪"
else
  warn "未检测到 Xcode Command Line Tools；内置化 radare2 需要 install_name_tool/codesign。"
  warn "如需自动内置 r2，请先执行: xcode-select --install"
fi

FREE_KB="$(df -k "$ROOT" | awk 'NR==2 {print $4}')"
if [ "${FREE_KB:-0}" -lt 2097152 ]; then
  warn "磁盘可用不足 2 GB（$((FREE_KB/1024)) MB），安装过程可能失败"
else
  ok "磁盘可用 $((FREE_KB/1048576)) GB"
fi

[ -d "$TOOL_DIR" ] || { err "Tool 目录不存在: $TOOL_DIR"; }
[ -d "$TOOL_DIR/mcp/Tool" ] || { err "关键目录缺失: Tool/mcp/Tool（严禁搬移/重命名，seep MCP 硬编码依赖）"; }

# --- Python -------------------------------------------------------------------
# 注意：GUI / Agent 启动的 shell 常常没有把 Homebrew 前缀放进 PATH，
# 因此这里必须显式枚举常见安装前缀，不能只依赖 command -v。
PY=""
pick_python() {
  local ranked=() f ver maj min rank
  for pat in "$WANT_PY" \
             /opt/homebrew/bin/python3.* /usr/local/bin/python3.* \
             /opt/homebrew/opt/python@3.*/bin/python3.* /usr/local/opt/python@3.*/bin/python3.* \
             "$HOME"/.pyenv/versions/3.*/bin/python3 \
             "$(command -v python3.13 2>/dev/null)" "$(command -v python3.12 2>/dev/null)" \
             "$(command -v python3.11 2>/dev/null)" "$(command -v python3.14 2>/dev/null)" \
             "$(command -v python3 2>/dev/null)"; do
    [ -n "$pat" ] || continue
    for f in $pat; do
      [ -x "$f" ] || continue
      ver="$("$f" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null || true)"
      [ -n "$ver" ] || continue
      maj="${ver%%.*}"; min="${ver##*.}"
      [ "$maj" -eq 3 ] || continue
      [ "$min" -ge 11 ] || continue
      # 3.12/3.13 生态兼容性最好，优先；3.11 次之；更新版本再次
      if [ "$min" -eq 12 ] || [ "$min" -eq 13 ]; then rank=$((100 + min))
      elif [ "$min" -eq 11 ]; then rank=90
      else rank=$((50 + min)); fi
      ranked+=("$rank|$f")
    done
  done
  [ ${#ranked[@]} -gt 0 ] || return 1
  printf '%s\n' "${ranked[@]}" | sort -t'|' -k1,1nr | head -1 | cut -d'|' -f2
}
if PY="$(pick_python)"; then
  ok "Python: $("$PY" --version 2>&1) ($PY)"
else
  err "未找到 Python 3.11+（项目要求）。macOS 建议: brew install python@3.12"
fi

# --- Node / Java --------------------------------------------------------------
NODE=""
for pat in /opt/homebrew/bin/node /usr/local/bin/node /opt/homebrew/opt/node@*/bin/node \
           /usr/local/opt/node@*/bin/node "$HOME"/.nvm/versions/node/*/bin/node \
           "$(command -v node 2>/dev/null)"; do
  for f in $pat; do
    [ -x "$f" ] || continue
    maj="$("$f" -v 2>/dev/null | sed 's/^v//; s/\..*//')"
    [ -n "$maj" ] || continue
    if [ "${maj:-0}" -ge 18 ]; then NODE="$f"; break; fi
    [ -z "$NODE" ] && NODE="$f"
  done
  [ -n "$NODE" ] && [ "$("$NODE" -v | sed 's/^v//; s/\..*//')" -ge 18 ] && break
done
if [ -n "$NODE" ]; then
  if [ "$("$NODE" -v | sed 's/^v//; s/\..*//')" -ge 18 ]; then
    ok "Node: $("$NODE" -v) ($NODE)"
  else
    warn "Node 版本偏低: $("$NODE" -v)（js-reverse-mcp/playwright-mcp 需 18+）"
  fi
else
  warn "未找到 node：js-reverse / playwright MCP 将不可用（brew install node）"
fi

JAVA_HOME_FOUND=""
for c in "${JAVA_HOME:-}" \
         "$(/usr/libexec/java_home 2>/dev/null || true)" \
         /opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home \
         /usr/local/opt/openjdk/libexec/openjdk.jdk/Contents/Home \
         /Library/Java/JavaVirtualMachines/*/Contents/Home \
         "$HOME"/Library/Java/JavaVirtualMachines/*/Contents/Home \
         "/Applications/Android Studio.app/Contents/jbr/Contents/Home"; do
  [ -n "$c" ] && [ -x "$c/bin/java" ] && "$c/bin/java" -version >/dev/null 2>&1 && { JAVA_HOME_FOUND="$c"; break; }
done
if [ -n "$JAVA_HOME_FOUND" ]; then
  ok "Java: $("$JAVA_HOME_FOUND/bin/java" -version 2>&1 | head -1) ($JAVA_HOME_FOUND)"
else
  # macOS 上 /usr/bin/java 是空壳，必须显式识别
  warn "未找到可用 JDK（jadx / apktool 需要 JDK 11+）。安装建议: brew install openjdk"
fi

[ ${#FAILED[@]} -gt 0 ] && { printf "\n"; err "环境检测存在阻断项，请先修复后重试（见 MANUAL/PREREQUISITES.md）"; exit 1; }

# ==============================================================================
# 2. Python venv + mcp 协议库
# ==============================================================================
step "Python 依赖（venv: Tool/mcp/.venv-macos）"

if [ ! -x "$VENV/bin/python" ]; then
  info "创建虚拟环境"
  if "$PY" -m venv "$VENV" >/dev/null 2>&1; then
    ok "venv 已创建（$("$VENV/bin/python" --version 2>&1)）"
  else
    err "venv 创建失败"
  fi
else
  ok "venv 已存在（$("$VENV/bin/python" --version 2>&1)）"
fi

if [ -x "$VENV/bin/python" ]; then
  if "$VENV/bin/python" -c "import mcp" >/dev/null 2>&1; then
    ok "mcp 协议库已就绪（$("$VENV/bin/python" -c 'import importlib.metadata as m;print(m.version("mcp"))' 2>/dev/null)）"
  else
    if [ "$NO_NETWORK" -eq 1 ]; then
      err "mcp 未安装且处于 --no-network 模式"
    else
      info "安装 $MCP_REQ"
      "$VENV/bin/python" -m pip install --quiet --disable-pip-version-check "$MCP_REQ" >/tmp/seep-pip.log 2>&1 \
        && ok "mcp 安装完成（$("$VENV/bin/python" -c 'import importlib.metadata as m;print(m.version("mcp"))' 2>/dev/null)）" \
        || { err "mcp 安装失败，详见 /tmp/seep-pip.log"; tail -3 /tmp/seep-pip.log | sed 's/^/      /'; }
    fi
  fi
  # 允许把 venv 交给 MCP 宿主直接调用
  "$VENV/bin/python" -c "import seep_mcp_server" 2>/dev/null && ok "seep_mcp_server 可导入" \
    || info "seep_mcp_server 需经 launcher 导入（正常，缺 mcp 时才会失败）"
fi

# ==============================================================================
# 3. 原生 radare2 内置化
# ==============================================================================
step "radare2 引擎（macOS 原生）"

R2_DIR="$SAFE_DIR/radare2/macos-$ARCH/bin"
if [ -x "$R2_DIR/radare2" ]; then
  ok "仓库内置原生 r2 已就绪: $("$R2_DIR/radare2" -v 2>/dev/null | head -1)"
elif SYS_R2="$(command -v radare2 2>/dev/null)"; then
  ok "使用系统 radare2: $SYS_R2 ($("$SYS_R2" -v 2>/dev/null | head -1))"
elif [ "$NO_NETWORK" -eq 1 ]; then
  err "既无内置原生 r2，也无系统 radare2，且处于 --no-network 模式"
else
  info "内置化官方 radare2（下载 pkg → 重定位 → 重签名）"
  if "$MACOS_DIR/relocate-radare2.sh" >/tmp/seep-r2.log 2>&1; then
    ok "内置化完成: $("$R2_DIR/radare2" -v 2>/dev/null | head -1)"
  else
    err "radare2 内置化失败，详见 /tmp/seep-r2.log；可改用 brew install radare2"
    tail -3 /tmp/seep-r2.log | sed 's/^/      /'
  fi
fi

# ==============================================================================
# 4. jadx / apktool
# ==============================================================================
step "Android 逆向链路（jadx / apktool）"

JADX_JAR="$(ls "$SAFE_DIR/jadx"/lib/jadx-*-all.jar 2>/dev/null | head -1 || true)"
if [ -n "$JADX_JAR" ] && [ -f "$POSIX_BIN/jadx" ]; then
  chmod +x "$POSIX_BIN/jadx" 2>/dev/null || true
  if [ -n "$JAVA_HOME_FOUND" ]; then
    if JAVA_HOME="$JAVA_HOME_FOUND" "$POSIX_BIN/jadx" --version >/dev/null 2>&1; then
      ok "jadx 可用（$(basename "$JADX_JAR")，经 POSIX 垫片修正 1.5.1→1.5.6 的 jar 路径 bug）"
    else
      err "jadx 无法运行（已找到 jar 与 Java，但调用失败）"
    fi
  else
    warn "jadx jar 已就位，但缺少 JDK，未能实跑验证"
  fi
else
  err "jadx 组件缺失（lib/jadx-*-all.jar 或 posix-bin/jadx）"
fi

if [ -f "$SAFE_DIR/apktool/apktool.jar" ]; then
  if [ -n "$JAVA_HOME_FOUND" ] && "$JAVA_HOME_FOUND/bin/java" -jar "$SAFE_DIR/apktool/apktool.jar" --version >/dev/null 2>&1; then
    ok "apktool 可用（$("$JAVA_HOME_FOUND/bin/java" -jar "$SAFE_DIR/apktool/apktool.jar" --version 2>&1 | tail -1)）"
  else
    warn "apktool.jar 已就位，但未能实跑验证（缺 JDK？）"
  fi
else
  err "apktool.jar 缺失"
fi

# ==============================================================================
# 5. Node 依赖解压（首次部署）
# ==============================================================================
step "Web/JS 调试引擎依赖"

if [ "$SKIP_DEPS" -eq 1 ]; then
  info "已按 --skip-deps 跳过"
else
  for pkg in js-reverse-mcp playwright-mcp; do
    d="$SAFE_DIR/$pkg"
    if [ -d "$d/node_modules" ]; then
      ok "$pkg/node_modules 已存在"
    elif [ -f "$d/node_modules.zip" ]; then
      info "解压 $pkg/node_modules.zip"
      if unzip -o -q "$d/node_modules.zip" -d "$d" 2>/dev/null; then
        ok "$pkg 依赖解压完成（$(find "$d/node_modules" -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ') 个包）"
      else
        warn "$pkg 依赖解压失败（可用 ditto 或 7z 手动解压）"
      fi
    else
      warn "$pkg 既无 node_modules 也无 node_modules.zip"
    fi
  done
fi

# ==============================================================================
# 6. IDA MCP 原生化 (blacktop/ida-mcp-rs)
# ==============================================================================
step "IDA Pro MCP（原生化 headless）"

IDA_BIN="$SAFE_DIR/ida-mcp-rs/bin/ida-mcp"
if [ "$SKIP_IDA" -eq 1 ]; then
  info "已按 --skip-ida 跳过"
elif ls /Applications/IDA*.app >/dev/null 2>&1 || [ -n "${IDADIR:-}" ]; then
  if "$MACOS_DIR/install-ida-mcp.sh"; then :; else warn "IDA MCP 安装脚本返回非零（不影响 radare2 链路）"; fi
else
  info "未检测到 IDA Pro，跳过（按规约由 Radare2 自动承接）"
fi
[ -x "$IDA_BIN" ] && ok "ida-mcp 就位（$("$IDA_BIN" --version 2>&1 | head -1)）"

# ==============================================================================
# 7. MCP 注册（Claude Code .mcp.json / DSH profile / pi）
# ==============================================================================
step "MCP 服务注册"

LAUNCHER="$MCP_DIR/seep_mcp_launcher.py"
chmod +x "$LAUNCHER" 2>/dev/null || true
VENV_PY="$VENV/bin/python"

# npx 也走绝对路径：MCP 宿主会清洗环境变量，PATH 里的 npx 不一定解析得到
NODE_CMD=""
if [ -n "$NODE" ]; then
  for cand in "$(dirname "$NODE")/npx" /opt/homebrew/bin/npx /usr/local/bin/npx; do
    [ -x "$cand" ] && NODE_CMD="$cand" && break
  done
fi
[ -n "$NODE_CMD" ] || NODE_CMD="$(command -v npx 2>/dev/null || echo npx)"
[ -x "$NODE_CMD" ] && ok "npx: $NODE_CMD"

register_json() {
  local target="$1"
  "$VENV/bin/python" - "$target" "$VENV_PY" "$LAUNCHER" "$IDA_BIN" "$NODE_CMD" <<'PY'
import json, sys, os
target, venv_py, launcher, ida_bin, node_cmd = sys.argv[1:6]
servers = {
    "seep": {"command": venv_py, "args": [launcher],
             "env": {"PYTHONIOENCODING": "utf-8"}, "transport": "stdio"},
    "js-reverse": {"command": node_cmd, "args": ["-y", "js-reverse-mcp"], "transport": "stdio"},
}
if os.path.isfile(ida_bin) and os.access(ida_bin, os.X_OK):
    servers["ida"] = {"command": ida_bin, "args": [], "transport": "stdio"}
with open(target, "w", encoding="utf-8") as f:
    json.dump({"mcpServers": servers}, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
}

# mac 专用注册文件（权威副本，随时可重新应用）
register_json "$ROOT/.mcp.macos.json" && ok "已生成 .mcp.macos.json"

# Claude Code 项目级注册：首次改写前备份 Windows 原版
if [ ! -f "$ROOT/.mcp.json.seep-windows-backup" ]; then
  cp "$ROOT/.mcp.json" "$ROOT/.mcp.json.seep-windows-backup" 2>/dev/null || true
  ok "已备份原 .mcp.json → .mcp.json.seep-windows-backup（Windows 用 install.ps1 可复原）"
fi
if register_json "$ROOT/.mcp.json"; then
  ok "已注册 Claude Code 项目级 MCP (.mcp.json → 原生 venv/launcher)"
else
  err ".mcp.json 写入失败"
fi

# DSH profile 补丁（默认只生成，--register-dsh 才写入用户目录）
DSH_SNIPPET="$MACOS_DIR/dsh-cordis.patch.yml"
cat > "$DSH_SNIPPET" <<YAML
# Seep Reverse Lab — DeepSeek Harness MCP 注册补丁（macOS/Linux 原生路径）
# 将下面条目追加到 \$DSH_PROFILE_DIR/cordis.patch.yml 末尾即可。
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
- id: mcp-seep
  name: '@deepseek-ai/dsh-mcp-client'
  config:
    serverName: seep
    transport: stdio
    command: '$VENV_PY'
    args:
      - '$LAUNCHER'
    env:
      PYTHONIOENCODING: utf-8

- id: mcp-js-reverse
  name: '@deepseek-ai/dsh-mcp-client'
  config:
    serverName: js-reverse
    transport: stdio
    command: '$NODE_CMD'
    args: ['-y', 'js-reverse-mcp']
YAML
[ -x "$IDA_BIN" ] && cat >> "$DSH_SNIPPET" <<YAML

- id: mcp-ida
  name: '@deepseek-ai/dsh-mcp-client'
  config:
    serverName: ida
    transport: stdio
    command: '$IDA_BIN'
YAML
ok "已生成 DSH 注册补丁: setup/macos/dsh-cordis.patch.yml"

if [ "$REGISTER_DSH" -eq 1 ]; then
  DSH_DIR="${DSH_PROFILE_DIR:-$HOME/.dsh/profiles/desktop}"
  DSH_PATCH="$DSH_DIR/cordis.patch.yml"
  if [ ! -f "$DSH_PATCH" ]; then
    warn "未找到 DSH profile: $DSH_PATCH（跳过，可手动粘贴上面的补丁）"
  elif grep -q "serverName: seep" "$DSH_PATCH" 2>/dev/null; then
    # 幂等保护：DSH 在同一注册作用域内 serverName 必须唯一，重复追加会导致加载失败
    ok "DSH profile 已包含 seep 注册，跳过写入（幂等）"
  else
    BACKUP="$DSH_PATCH.bak-seep-$(date +%Y%m%d-%H%M%S)"
    cp "$DSH_PATCH" "$BACKUP"
    printf '\n' >> "$DSH_PATCH"
    grep -v '^#' "$DSH_SNIPPET" >> "$DSH_PATCH"
    if command -v ruby >/dev/null 2>&1 && ruby -ryaml -e "YAML.load_file('$DSH_PATCH')" >/dev/null 2>&1; then
      ok "已写入 DSH profile 并通过 YAML 校验（备份: $(basename "$BACKUP")）"
      warn "DSH 需要重载/重启才会生效"
    else
      cp "$BACKUP" "$DSH_PATCH"
      err "写入后 YAML 校验失败，已回滚 DSH profile"
    fi
  fi
else
  info "未写入 DSH profile（如需自动注册请加 --register-dsh）"
fi

# ==============================================================================
# 8. 自检
# ==============================================================================
step "自检"
"$SCRIPT_DIR/verify-macos.sh" --no-banner || true

# ==============================================================================
printf "\n${C_B}================================================================${C_0}\n"
if [ ${#FAILED[@]} -eq 0 ]; then
  printf "  ${C_G}安装完成${C_0}\n"
else
  printf "  ${C_Y}部分步骤失败: %s${C_0}\n" "${FAILED[*]}"
fi
if [ ${#WARNED[@]} -gt 0 ]; then
  printf "  提示项 %d 条（见上方 [!!]）\n" "${#WARNED[@]}"
fi
printf "${C_B}================================================================${C_0}\n"

cat <<'NEXT'

  下一步:
    1) 重启你的 Agent 宿主（DSH / Claude Code / pi）
    2) 在对话框输入:  lab：

  体检随时可跑:  ./check.sh
  完整冒烟测试:  Tool/mcp/.venv-macos/bin/python setup/macos/smoke-test.py --deep

NEXT
exit $([ ${#FAILED[@]} -eq 0 ] && echo 0 || echo 1)
