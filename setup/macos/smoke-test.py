#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
seep 工作台 —— macOS / Linux 端到端冒烟测试
===============================================================
两层验证：
  A. 进程内工具层：经 seep_mcp_launcher 注入原生路径后，直接调用 MCP 工具函数，
     覆盖 radare2 全家桶、jadx、apktool、知识库、Hook 生成。
  B. 协议层：以真实 MCP stdio 客户端握手，initialize → tools/list → tools/call，
     验证 AI 宿主（DSH / Claude Code / pi）实际走的链路可用。

用法:
    <venv>/bin/python setup/macos/smoke-test.py            # 核心用例（默认）
    <venv>/bin/python setup/macos/smoke-test.py --deep     # 追加真实 APK 反编译/解包
退出码 0 = 全部通过。
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
MCP_DIR = os.path.join(ROOT, "Tool", "mcp")
SAFE_DIR = os.path.join(MCP_DIR, "Tool", "safe")

sys.path.insert(0, MCP_DIR)

GREEN, RED, YELLOW, CYAN, DIM, RESET = "\033[32m", "\033[31m", "\033[33m", "\033[36m", "\033[2m", "\033[0m"

PASSED: list = []
FAILED: list = []
SKIPPED: list = []


def check(name: str, condition: bool, detail: str = "") -> bool:
    if condition:
        PASSED.append(name)
        print("  %s[PASS]%s %s%s" % (GREEN, RESET, name, ("  %s%s%s" % (DIM, detail, RESET)) if detail else ""))
    else:
        FAILED.append((name, detail))
        print("  %s[FAIL]%s %s%s" % (RED, RESET, name, ("  -> %s" % detail) if detail else ""))
    return condition


def skip(name: str, why: str) -> None:
    SKIPPED.append(name)
    print("  %s[SKIP]%s %s  %s%s%s" % (YELLOW, RESET, name, DIM, why, RESET))


def section(title: str) -> None:
    print("\n%s%s%s" % (CYAN, title, RESET))


# ---------------------------------------------------------------------------
# A. 进程内工具层
# ---------------------------------------------------------------------------
def phase_tools(deep: bool) -> None:
    section("[A] 工具层 — seep MCP 原生路径注入与实机调用")

    import seep_mcp_launcher as launcher
    import seep_mcp_server as srv

    overrides = launcher.build_overrides()
    launcher.apply_overrides(srv, overrides)
    java = launcher.apply_java_env()          # 与真实启动路径一致：注入真实 JDK
    check("平台补丁注入（%d 个路径常量）" % len(overrides), len(overrides) >= 5,
          "R2_EXE -> %s" % overrides.get("R2_EXE", "(未注入)"))
    check("Java 运行时探测（识破 macOS /usr/bin/java 空壳）", bool(java), java or "未找到真实 JDK")

    elf = os.path.join(SAFE_DIR, "ida-pro-mcp", "tests", "typed_fixture.elf")

    # --- seep_status ---
    status = json.loads(srv.seep_status())
    comp = status["components"]
    r2 = comp["radare2_suite"]
    check("seep_status: radare2 套件 Ready", r2["status"] == "Ready",
          "version=%s" % r2.get("version"))
    check("seep_status: 版本号为 6.2.2", "6.2.2" in str(r2.get("version", "")), str(r2.get("version")))
    check("seep_status: jadx Ready", "Ready" in comp["jadx_decompiler"]["status"],
          comp["jadx_decompiler"]["path"])
    check("seep_status: apktool Ready", "Ready" in comp["apktool"]["status"])
    check("seep_status: Java 运行时可用", comp["java_runtime"]["status"] == "Ready"
          and "Unable to locate" not in comp["java_runtime"]["detail"],
          comp["java_runtime"]["detail"][:90])
    check("seep_status: 知识库可检索", "Ready" in comp["reverselab_knowledge_base"]["status"],
          comp["reverselab_knowledge_base"]["status"])

    # --- radare2 引擎 ---
    if os.path.isfile(elf):
        info = srv.seep_r2_info(elf)
        check("seep_r2_info: 解析内置 ELF 样本", ("ELF" in info.upper() or "elf" in info.lower())
              and "[ERROR]" not in info, info.strip().splitlines()[0] if info.strip() else "")

        strings = srv.seep_r2_strings(elf, filter_text="hi", limit=5)
        check("seep_r2_strings: 关键词过滤命中", "typed fixture says hi" in strings)

        disasm = srv.seep_r2_disasm(elf, target="main", lines=20)
        check("seep_r2_disasm: 反汇编 main", "main" in disasm and "[ERROR]" not in disasm)

        decomp = srv.seep_r2_decompile(elf, target="main")
        check("seep_r2_decompile: 伪代码/反编译输出", "main" in decomp and "[ERROR]" not in decomp)
    else:
        skip("radare2 ELF 用例", "内置样本 typed_fixture.elf 不存在")

    funcs = srv.seep_r2_functions("/bin/ls")
    check("seep_r2_functions: 分析 /bin/ls", "[ERROR]" not in funcs and len(funcs) > 200,
          "%d 字节输出" % len(funcs))

    asm = srv.seep_r2_asm("xor eax, eax; ret", arch="x86", bits=64)
    check("seep_r2_asm: 汇编 x86", "31c0" in asm, asm.strip()[:40])
    dis = srv.seep_r2_asm(asm.strip()[:8], arch="x86", bits=64, disasm=True) if "31c0" in asm else ""
    check("seep_r2_asm: 反汇编回译", "xor" in dis, dis.strip()[:40])

    # --- 知识库 / 战术资产 ---
    kb = srv.seep_kb_search("JWT", limit=3)
    check("seep_kb_search: 知识库命中 JWT", "jwt" in kb.lower())
    chk = srv.seep_kb_checklist("web_first_30_min")
    check("seep_kb_checklist: 目录清单可读", "Web CTF" in chk)
    hook = srv.seep_apk_gen_hook("frida", "com.sec.Validator", "isVip",
                                 return_type="boolean", hook_timing="replace")
    check("seep_apk_gen_hook: 生成 Frida 脚本", "Java.perform" in hook)

    # --- 真实 APK：jadx / apktool ---
    apk = os.path.join(ROOT, "Tool", "upstream", "apk-reverse", "tests", "fixtures", "apk", "plain.apk")
    if not os.path.isfile(apk):
        skip("jadx / apktool 真实 APK 用例", "未找到 plain.apk 样本")
        return

    if not deep:
        skip("seep_apk_decompile (jadx 真实反编译)", "默认跳过，加 --deep 启用")
        skip("seep_apk_unpack (apktool 真实解包)", "默认跳过，加 --deep 启用")
        return

    import shutil as _sh
    import tempfile

    workdir = tempfile.mkdtemp(prefix="seep-smoke-")
    try:
        out = srv.seep_apk_decompile(apk, output_dir=os.path.join(workdir, "jadx_src"))
        produced = os.path.isdir(os.path.join(workdir, "jadx_src"))
        check("seep_apk_decompile: jadx 实机反编译 APK", produced and "ERROR" not in out.splitlines()[0],
              os.path.basename(out.splitlines()[0]) if out else "")

        out2 = srv.seep_apk_unpack(apk, output_dir=os.path.join(workdir, "apktool_out"))
        manifest = os.path.join(workdir, "apktool_out", "AndroidManifest.xml")
        check("seep_apk_unpack: apktool 实机解包 APK", os.path.isfile(manifest),
              "AndroidManifest.xml %s" % ("已生成" if os.path.isfile(manifest) else "缺失"))
    finally:
        _sh.rmtree(workdir, ignore_errors=True)


# ---------------------------------------------------------------------------
# B. MCP 协议层
# ---------------------------------------------------------------------------
async def phase_mcp_protocol() -> None:
    section("[B] 协议层 — 真实 MCP stdio 握手（AI 宿主实际链路）")

    try:
        from mcp import ClientSession, StdioServerParameters
        from mcp.client.stdio import stdio_client
    except ImportError as exc:
        check("MCP 客户端库可用", False, str(exc))
        return

    launcher = os.path.join(MCP_DIR, "seep_mcp_launcher.py")
    params = StdioServerParameters(
        command=sys.executable,
        args=[launcher],
        env={**os.environ, "PYTHONIOENCODING": "utf-8", "PYTHONUTF8": "1"},
    )

    try:
        async with stdio_client(params) as (read, write):
            async with ClientSession(read, write) as session:
                init = await session.initialize()
                check("initialize 握手成功",
                      bool(getattr(init, "serverInfo", None)),
                      "server=%s" % getattr(getattr(init, "serverInfo", None), "name", "?"))

                tools = await session.list_tools()
                names = [t.name for t in tools.tools]
                check("tools/list 返回工具清单", len(names) >= 20, "共 %d 个工具" % len(names))
                for expected in ("seep_status", "seep_r2_info", "seep_r2_cmd", "seep_apk_decompile",
                                 "seep_kb_search", "seep_auto_triage"):
                    check("工具已注册: %s" % expected, expected in names)

                res = await session.call_tool("seep_status", {})
                payload = "".join(getattr(c, "text", "") for c in res.content)
                data = json.loads(payload)
                ok = data["components"]["radare2_suite"]["status"] == "Ready"
                check("tools/call seep_status（经协议返回真实状态）", ok,
                      "r2=%s" % data["components"]["radare2_suite"].get("version"))

                res2 = await session.call_tool("seep_r2_info", {"binary_path": "/bin/ls"})
                payload2 = "".join(getattr(c, "text", "") for c in res2.content)
                check("tools/call seep_r2_info(/bin/ls)", "mach0" in payload2.lower() or "64" in payload2,
                      payload2.strip().splitlines()[0] if payload2.strip() else "")
    except Exception as exc:
        check("MCP stdio 会话", False, "%s: %s" % (type(exc).__name__, exc))


# ---------------------------------------------------------------------------
def main() -> int:
    parser = argparse.ArgumentParser(description="seep macOS/Linux 端到端冒烟测试")
    parser.add_argument("--deep", action="store_true", help="追加真实 APK 的 jadx 反编译与 apktool 解包")
    args = parser.parse_args()

    print("=" * 72)
    print("  seep 工作台 · macOS/Linux 端到端冒烟测试")
    print("  Python: %s" % sys.version.split()[0])
    print("  仓库根: %s" % ROOT)
    print("=" * 72)

    try:
        phase_tools(args.deep)
    except Exception:
        check("工具层执行", False, traceback.format_exc().strip().splitlines()[-1])

    try:
        asyncio.run(phase_mcp_protocol())
    except Exception as exc:
        check("协议层执行", False, "%s: %s" % (type(exc).__name__, exc))

    print("\n" + "=" * 72)
    print("  结果: %s%d 通过%s / %s%d 失败%s / %s%d 跳过%s"
          % (GREEN, len(PASSED), RESET, RED, len(FAILED), RESET, YELLOW, len(SKIPPED), RESET))
    if FAILED:
        print("\n  失败明细:")
        for name, detail in FAILED:
            print("    - %s  %s" % (name, detail))
    print("=" * 72)
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
