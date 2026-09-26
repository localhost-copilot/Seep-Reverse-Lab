# MANUAL — macOS 兼容与安装指南

> 适用：macOS 12+（Intel / Apple Silicon）。Linux 亦可使用同一套 POSIX 链路（radare2 走系统安装）。
> 目标：把原本「Windows 绑定」的 Seep 工作台，在 macOS 上做到**核心链路全绿、开箱可用**，且**不破坏 Windows 侧任何文件**。

---

## 一、结论速览

| 能力 | macOS 状态 | 实现方式 |
|---|---|---|
| radare2 全套二进制逆向 | ✅ 原生可用 | 官方 `radare2-arm64-6.2.2.pkg` 重定位进仓库（与 Windows 内置版**同版本**） |
| jadx APK 反编译 | ✅ 原生可用 | `Tool/mcp/posix-bin/jadx` 垫片（修正上游 jar 路径 bug） |
| apktool 解包/回编译 | ✅ 原生可用 | `java -jar apktool.jar`（原本即跨平台） |
| seep MCP（23 工具） | ✅ 原生可用 | `seep_mcp_launcher.py` + 原生 venv |
| 289 篇知识库 / Skills / prompts | ✅ 原生可用 | 纯文本资源 |
| IDA Pro MCP | ✅ 原生可用（需自备授权） | `blacktop/ida-mcp-rs` headless 服务，75 个工具 |
| js-reverse / playwright MCP | ✅ 需 Node 18+ | Node 包，跨平台 |
| Windows `.ps1` / `.bat` 脚本 | ➖ 不再需要 | 已提供对等 `.sh` 实现 |

---

## 二、原本为什么跑不起来（4 个真实根因）

1. **radare2 二进制是 Windows PE**：`Tool/mcp/Tool/safe/radare2/bin/` 下 14 个 `.exe` + 23 个 `.dll`，macOS 无法执行；
2. **MCP 服务端硬编码 `.exe` / `.bat` 路径**：`seep_mcp_server.py` 的 `R2_EXE`/`RABIN2_EXE`/`JADX_BAT` 等常量；
3. **上游 `bin/jadx` 脚本 jar 版本号错误**：硬编码 `jadx-1.5.1-all.jar`，而实际内置 `jadx-1.5.6-all.jar`（Windows 的 `jadx.bat` 是对的）→ 必报 `ClassNotFoundException: jadx.cli.JadxCLI`；
4. **macOS 的 `/usr/bin/java` 是空壳**：装了 JDK 也会输出 `Unable to locate a Java Runtime`，导致 `shutil.which("java")` 误判成功。

此外，随包的 `ida-pro-mcp` 依赖 Windows venv + IDA GUI 插件 + HTTP 13337 端口，在 macOS 上没有对应形态。

---

## 三、兼容层文件清单（全部为新增，不改上游）

| 文件 | 作用 |
|---|---|
| `Tool/mcp/seep_mcp_launcher.py` | **跨平台启动器**。Windows 下完全等同旧行为；macOS/Linux 下在内存中把 Windows 工具路径改写成原生实现，再交回原始 `main()`。 |
| `Tool/mcp/posix-bin/jadx` | jadx POSIX 垫片，动态定位 `lib/jadx-*-all.jar`，规避上游 1.5.1/1.5.6 错配。 |
| `Tool/mcp/Tool/safe/radare2/macos-<arch>/` | 重定位后的官方 r2 6.2.2（`bin/ lib/ share/`）。 |
| `setup/macos/relocate-radare2.sh` | 下载官方 pkg → 解包 → `install_name_tool` 改写绝对路径依赖 → ad-hoc 重签名 → 自检。 |
| `setup/macos/install-ida-mcp.sh` | 探测本机 IDA 版本 → 下载版本匹配的 `ida-mcp`（Darwin）→ SHA-256 校验 → 实机探测。 |
| `setup/macos/smoke-test.py` | 端到端冒烟测试：工具层 + 真实 MCP stdio 协议层。 |
| `setup/install-macos.sh` / `setup/verify-macos.sh` | 与 `install.ps1` / `verify.ps1` 对等的 POSIX 实现。 |
| `check.sh` / `install.sh` | 根目录快捷入口，与 `check.ps1` / `check.bat` 对等。 |

### 为什么不直接改 `seep_mcp_server.py`？

项目红线明确「严禁修改 `seep_mcp_server.py` 的路径常量」。因此本方案**一个字节都不改**该文件，改为在启动器里于运行时改写模块属性（工具函数在调用时才查全局常量，覆写立即生效）。同时**不搬动 `Tool/mcp/Tool/`**，Windows 内置的 `radare2/bin/*.exe` 原样保留。

---

## 四、一键安装

```bash
cd /path/to/Seep-Reverse-Lab
./install.sh                  # 完整安装 + 自检
./install.sh --only-verify    # 只自检
./install.sh --skip-ida       # 不装 IDA MCP
./install.sh --register-dsh   # 额外写入 DSH profile（自动备份）
```

安装脚本依次完成：环境检测 → Python venv + `mcp` → 原生 radare2 内置化 → Java/jadx/apktool 校验 → Node 依赖解压 → IDA MCP 原生化 → MCP 注册 → 全量自检。

**前置依赖**：Python 3.11+、Xcode Command Line Tools（内置化 r2 需要 `install_name_tool`/`codesign`）；
推荐 Node 18+（Web/JS 链路）、JDK 11+（Android 链路，`brew install openjdk`）。

---

## 五、体检

```bash
./check.sh            # 标准：静态检查 + 端到端冒烟测试
./check.sh --fast     # 快速：跳过冒烟测试
./check.sh --deep     # 深度：附加真实 APK 反编译/解包
```

全部通过时会输出：

```
  🎉 结论: 工作台处于 [READY / 完备就绪] 状态！
  您可以直接在 Agent (DSH / Claude Code / pi) 中发送: lab： 开启测试！
```

单独跑冒烟测试：

```bash
Tool/mcp/.venv-macos/bin/python setup/macos/smoke-test.py --deep
```

---

## 六、IDA Pro MCP（`blacktop/ida-mcp-rs`）

随包的 `ida-pro-mcp` 是「IDA GUI 插件 + Windows venv + HTTP 13337」形态。macOS 改用
[`blacktop/ida-mcp-rs`](https://github.com/blacktop/ida-mcp-rs)：Rust 编写的 **headless** IDA MCP 服务（基于 `idalib`），
官方直接发布 Darwin arm64/x86_64 二进制，**无需 GUI、无需插件、无需 Windows venv**。

```bash
setup/macos/install-ida-mcp.sh          # 自动匹配本机 IDA 版本
setup/macos/install-ida-mcp.sh -v 9.4.4 # 指定版本
```

- 版本号跟随 IDA：IDA 9.4 → `ida-mcp` 9.4.x；脚本会探测 `/Applications/IDA *.app`；
- 安装后实测：`ida-mcp probe --path <样本>`，本机 IDA Professional 9.4 解析 `/bin/ls` 得到 134 个函数；
- 暴露 **75 个工具**（`open_idb`、`decompile`、`callees`、`run_script` …）。

> ⚠️ `seep_ida_status` 工具探测的是旧插件的 HTTP 13337 端口，在 `ida-mcp-rs` 形态下**不适用**——
> 这是原始服务端的行为，按红线未作修改。IDA 能力请直接使用 `ida` MCP 的工具。
> IDA Pro 属商业软件，不随包分发；无授权时核心链路自动由 Radare2 承接（见 `MANUAL/IDA-PRO.md`）。

---

## 七、MCP 注册

安装脚本会写三处：

1. **`.mcp.macos.json`** — macOS 权威副本（绝对路径），随时可重新应用；
2. **`.mcp.json`** — Claude Code 项目级注册，首次改写前备份为 `.mcp.json.seep-windows-backup`；
3. **`setup/macos/dsh-cordis.patch.yml`** — DeepSeek Harness 补丁片段。

### DeepSeek Harness

把 `setup/macos/dsh-cordis.patch.yml` 的内容追加到 `$DSH_PROFILE_DIR/cordis.patch.yml`，
或直接：

```bash
./install.sh --register-dsh     # 自动追加 + 备份 + YAML 校验，失败自动回滚
```

条目形如（`@deepseek-ai/dsh-mcp-client` 要求 `serverName` 与 `transport` 必填）：

```yaml
- id: mcp-seep
  name: '@deepseek-ai/dsh-mcp-client'
  config:
    serverName: seep
    transport: stdio
    command: '<ROOT>/Tool/mcp/.venv-macos/bin/python'
    args:
      - '<ROOT>/Tool/mcp/seep_mcp_launcher.py'
    env:
      PYTHONIOENCODING: utf-8
```

写入后工具以 `mcp__seep__<tool>` 形式暴露（如 `mcp__seep__seep_r2_info`）。**需重载/重启 DSH 生效。**

---

## 八、故障排查

| 现象 | 原因 | 处理 |
|---|---|---|
| `radare2.exe not found at ...` | 启动器未生效（直接跑了 `seep_mcp_server.py`） | 改用 `seep_mcp_launcher.py` 作为 MCP 命令 |
| jadx 报 `ClassNotFoundException: jadx.cli.JadxCLI` | 用了上游 `bin/jadx`（jar 版本号错） | 用 `Tool/mcp/posix-bin/jadx` |
| `Unable to locate a Java Runtime` | 命中 macOS `/usr/bin/java` 空壳 | `brew install openjdk`；启动器会自动探测 keg-only JDK |
| `Library not loaded: /usr/local/lib/libr_*.dylib` | r2 未重定位 | 重跑 `setup/macos/relocate-radare2.sh` |
| r2 被杀（Killed: 9） | Mach-O 改动后未重签名 | 重跑 `relocate-radare2.sh`（内含 ad-hoc 重签） |
| `ida-mcp` 报版本不兼容 | ida-mcp 版本与 IDA 不匹配 | `install-ida-mcp.sh -v <对应版本>` |
| DSH 里看不到 seep 工具 | profile 未重载 | 重启 DSH；确认 `cordis.patch.yml` 已含 `mcp-seep` |

---

## 九、与 Windows 的差异对照

| 项 | Windows | macOS |
|---|---|---|
| 安装 | `setup/install.ps1` | `./install.sh` |
| 体检 | `check.ps1` / `check.bat` | `./check.sh` |
| r2 来源 | 内置 `bin/radare2.exe` | 内置 `macos-<arch>/bin/radare2`（同版本 6.2.2） |
| MCP 入口 | `python seep_mcp_server.py` | `.venv-macos/bin/python seep_mcp_launcher.py` |
| jadx 调用 | `bin/jadx.bat` | `posix-bin/jadx` |
| IDA 桥接 | `ida-pro-mcp`（GUI 插件 + HTTP 13337） | `ida-mcp-rs`（headless stdio） |

两侧互不干扰：macOS 安装脚本从不删除或移动 Windows 文件，Windows 安装脚本也不感知兼容层。
