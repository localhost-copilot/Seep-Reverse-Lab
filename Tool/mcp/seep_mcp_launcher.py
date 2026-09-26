#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
seep MCP 跨平台启动器 (Cross-Platform Launcher)
===============================================================
本文件是 macOS / Linux 上运行 seep MCP 的入口，同时保持 Windows 行为不变。

设计红线（与 CLAUDE.md 一致）：
  * 不修改、不搬移 seep_mcp_server.py 一个字节，也不改动其路径常量；
  * 不搬动 Tool/mcp/Tool/ 目录；
  * 不覆盖 Windows 内置的 radare2/bin/*.exe。
本启动器只在【运行时内存中】把那些硬编码的 Windows 工具路径替换为本机原生实现，
随后把控制权交回原始 seep_mcp_server.main()。

平台差异处理：
  Windows  → 不注入任何补丁，完全等同旧行为（install.ps1 链路不受影响）。
  macOS/Linux →
     1) radare2 套件：优先使用仓库内置 Tool/safe/radare2/macos-<arch>/bin（由
        setup/macos/relocate-radare2.sh 官方 pkg 重定位而来），否则回落到 PATH 中的系统安装；
     2) jadx：注入 posix-bin/jadx 垫片（上游 bin/jadx 的 jar 版本号是错的，见该垫片注释）；
     3) Java：macOS 的 /usr/bin/java 是"空壳"，装了 JDK 也会报 Unable to locate a Java
        Runtime。此处探测真实 JDK（JAVA_HOME / java_home / Homebrew keg-only / Android
        Studio JBR 等）并注入 JAVA_HOME + PATH，保证 _find_java() 与 jadx 脚本都能工作；
     4) 强制 UTF-8 stdio，避免无 locale 环境下中文 JSON 输出损坏。

用法:
    python3 seep_mcp_launcher.py                # MCP stdio 服务（被 MCP 宿主调用）
    python3 seep_mcp_launcher.py --diagnose     # 打印本机工具链解析结果（JSON）
"""

from __future__ import annotations

import glob
import json
import os
import platform
import shutil
import subprocess
import sys

MCP_DIR = os.path.dirname(os.path.abspath(__file__))
SAFE_DIR = os.path.join(MCP_DIR, "Tool", "safe")
POSIX_BIN_DIR = os.path.join(MCP_DIR, "posix-bin")

# seep MCP 中需要按平台改写的工具路径常量 → 对应的原生可执行文件名
R2_TOOL_MAP = (
    ("R2_EXE", "radare2"),
    ("RABIN2_EXE", "rabin2"),
    ("RADIFF2_EXE", "radiff2"),
    ("RASM2_EXE", "rasm2"),
    ("RAHASH2_EXE", "rahash2"),
)

IS_WINDOWS = sys.platform == "win32"


# ---------------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------------
def _is_executable(path: str) -> bool:
    return bool(path) and os.path.isfile(path) and os.access(path, os.X_OK)


def _works(cmd: list) -> bool:
    """真正执行一次，用于识破 macOS /usr/bin/java 这类"存在但报错"的空壳。"""
    try:
        proc = subprocess.run(cmd, capture_output=True, timeout=20)
        return proc.returncode == 0
    except Exception:
        return False


# ---------------------------------------------------------------------------
# Java 运行时探测
# ---------------------------------------------------------------------------
def _valid_java_home(path: str) -> str:
    if not path:
        return ""
    exe = os.path.join(path, "bin", "java")
    if not _is_executable(exe) or not _works([exe, "-version"]):
        return ""
    return os.path.abspath(path)


def _detect_java_home() -> str:
    candidates = []
    if os.environ.get("JAVA_HOME"):
        candidates.append(os.environ["JAVA_HOME"])

    if sys.platform == "darwin":
        try:
            proc = subprocess.run(["/usr/libexec/java_home"], capture_output=True, text=True, timeout=20)
            if proc.returncode == 0 and proc.stdout.strip():
                candidates.append(proc.stdout.strip())
        except Exception:
            pass

    for pattern in (
        "/opt/homebrew/opt/openjdk*/libexec/openjdk.jdk/Contents/Home",   # Apple Silicon Homebrew (keg-only)
        "/usr/local/opt/openjdk*/libexec/openjdk.jdk/Contents/Home",      # Intel Homebrew
        "/Library/Java/JavaVirtualMachines/*/Contents/Home",              # 官方 JDK 安装
        os.path.expanduser("~/Library/Java/JavaVirtualMachines/*/Contents/Home"),
        "/Applications/Android Studio.app/Contents/jbr/Contents/Home",    # Android Studio 自带 JBR
    ):
        candidates.extend(sorted(glob.glob(pattern), reverse=True))

    for cand in candidates:
        home = _valid_java_home(cand)
        if home:
            return home
    return ""


def apply_java_env() -> str:
    """确保 PATH 中的 java 是真实可用的 JDK，返回 java 可执行路径（可能为空）。"""
    found = shutil.which("java")
    if found and _works([found, "-version"]):
        return found

    home = _detect_java_home()
    if home:
        os.environ["JAVA_HOME"] = home
        os.environ["PATH"] = os.path.join(home, "bin") + os.pathsep + os.environ.get("PATH", "")
        return os.path.join(home, "bin", "java")
    return ""


# ---------------------------------------------------------------------------
# 原生工具定位
# ---------------------------------------------------------------------------
def bundled_r2_bin_dir() -> str:
    """仓库内置的、经重定位的原生 radare2 套件目录。"""
    tags = []
    arch = platform.machine()
    if sys.platform == "darwin":
        tags = ["macos-%s" % arch, "macos-arm64", "macos-x86_64"]
    elif sys.platform.startswith("linux"):
        tags = ["linux-%s" % arch, "linux-x86_64", "linux-arm64"]
    for tag in tags:
        d = os.path.join(SAFE_DIR, "radare2", tag, "bin")
        if os.path.isfile(os.path.join(d, "radare2")) and os.path.isfile(os.path.join(d, "rabin2")):
            return d
    return ""


def system_r2_bin_dir() -> str:
    """系统安装（Homebrew / 发行版包管理器）的 radare2 套件目录。"""
    found = shutil.which("radare2")
    if not found:
        return ""
    for d in (os.path.dirname(found), os.path.dirname(os.path.realpath(found))):
        if os.path.isfile(os.path.join(d, "radare2")) and os.path.isfile(os.path.join(d, "rabin2")):
            return d
    return ""


def resolve_r2_bin_dir() -> str:
    return bundled_r2_bin_dir() or system_r2_bin_dir()


def resolve_jadx_shim() -> str:
    """返回 jadx 垫片路径；必要时补上可执行位（Git 检出可能丢失 mode）。"""
    shim = os.path.join(POSIX_BIN_DIR, "jadx")
    if not os.path.isfile(shim):
        return ""
    if not os.access(shim, os.X_OK):
        try:
            os.chmod(shim, 0o755)
        except OSError:
            return ""
    if not glob.glob(os.path.join(SAFE_DIR, "jadx", "lib", "jadx-*-all.jar")):
        return ""
    return shim if os.access(shim, os.X_OK) else ""


# ---------------------------------------------------------------------------
# 补丁应用
# ---------------------------------------------------------------------------
def build_overrides() -> dict:
    """计算本机应注入的常量覆写表。Windows 返回空表。"""
    if IS_WINDOWS:
        return {}

    overrides = {}

    r2_dir = resolve_r2_bin_dir()
    if r2_dir:
        for attr, exe in R2_TOOL_MAP:
            path = os.path.join(r2_dir, exe)
            if _is_executable(path):
                overrides[attr] = path

    jadx = resolve_jadx_shim()
    if jadx:
        overrides["JADX_BAT"] = jadx

    return overrides


def apply_overrides(server_module, overrides: dict) -> dict:
    applied = {}
    for attr, value in overrides.items():
        setattr(server_module, attr, value)
        applied[attr] = value
    return applied


# ---------------------------------------------------------------------------
# 自检 / 诊断
# ---------------------------------------------------------------------------
def diagnose() -> dict:
    r2_dir = resolve_r2_bin_dir()
    r2_version = ""
    if r2_dir:
        try:
            r2_version = subprocess.run(
                [os.path.join(r2_dir, "radare2"), "-v"],
                capture_output=True, text=True, timeout=30
            ).stdout.splitlines()[0]
        except Exception:
            r2_version = "unavailable"

    java = apply_java_env()
    jadx = resolve_jadx_shim()

    return {
        "platform": "%s %s (%s)" % (platform.system(), platform.release(), platform.machine()),
        "python": sys.version.split()[0],
        "launcher": os.path.abspath(__file__),
        "windows_mode_passthrough": IS_WINDOWS,
        "overrides": build_overrides(),
        "radare2": {
            "source": ("bundled" if bundled_r2_bin_dir() else ("system" if r2_dir else "missing")),
            "bin_dir": r2_dir or None,
            "version": r2_version or None,
        },
        "java": java or None,
        "jadx_shim": jadx or None,
        "apktool_jar": (os.path.join(SAFE_DIR, "apktool", "apktool.jar")
                        if os.path.isfile(os.path.join(SAFE_DIR, "apktool", "apktool.jar")) else None),
    }


# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------
def _force_utf8_stdio() -> None:
    os.environ.setdefault("PYTHONIOENCODING", "utf-8")
    os.environ.setdefault("PYTHONUTF8", "1")
    for stream in (sys.stdin, sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")  # type: ignore[union-attr]
        except Exception:
            pass


def main() -> int:
    argv = sys.argv[1:]

    if "--diagnose" in argv:
        print(json.dumps(diagnose(), indent=2, ensure_ascii=False))
        return 0

    _force_utf8_stdio()

    # macOS 的 /usr/bin/java 只是空壳：必须在服务端被调用前把真实 JDK 注入 JAVA_HOME/PATH，
    # 否则 seep_mcp_server._find_java() 会拿到这个空壳，jadx / apktool 全线失败。
    java = apply_java_env()

    # 让 seep_mcp_server 能被直接 import（其 __main__ 受 if 保护，import 无副作用）
    if MCP_DIR not in sys.path:
        sys.path.insert(0, MCP_DIR)

    import seep_mcp_server as server_module

    applied = apply_overrides(server_module, build_overrides())
    if os.environ.get("SEEP_LAUNCHER_DEBUG"):
        print("[seep-launcher] applied: %s | java=%s" % (json.dumps(applied, ensure_ascii=False), java or "-"),
              file=sys.stderr)

    server_module.main()
    return 0


if __name__ == "__main__":
    sys.exit(main())
