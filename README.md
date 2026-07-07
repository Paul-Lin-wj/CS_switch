<p align="center">
  <img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License">
  <img src="https://img.shields.io/badge/platform-Linux%20x86_64-1d1d1f.svg" alt="Linux x86_64">
  <img src="https://img.shields.io/badge/built%20with-Tauri%202-C25A34.svg" alt="Tauri 2">
</p>

# CSSwitch-Linux

CSSwitch-Linux 是 CSSwitch 的 Linux 移植版本，让你在没有 Claude 订阅的情况下，也能在 **Claude Science** 中使用 DeepSeek、通义千问、Kimi、MiniMax、GLM、OpenRouter、中转站或任意 OpenAI 兼容端点。

本仓库面向两类用户：

- **普通用户**：下载 `.deb` 安装，填上第三方 API Key，点击「一键开始」即可。
- **开发者/贡献者**：阅读项目结构与构建说明，自行打包、调试、扩展 provider。

> 本版本已验证 **x86_64 / WSL2 Ubuntu 22.04**。
>
> **原项目地址**：macOS 原版由原作者维护在 [github.com/SuperJJ007/CSSwitch](https://github.com/SuperJJ007/CSSwitch)。本仓库是其在 Linux 上的移植版本。
>
> 许可证：MIT。详见 [LICENSE](./LICENSE)。

---

## 目录

- [1. 项目简介](#1-项目简介)
- [2. 工作原理](#2-工作原理)
- [3. 项目结构](#3-项目结构)
- [4. 核心文件说明](#4-核心文件说明)
- [5. 环境要求](#5-环境要求)
- [6. 安装](#6-安装)
- [7. 使用指南](#7-使用指南)
- [8. 配置详解](#8-配置详解)
- [9. 打包与发布](#9-打包与发布)
- [10. 开发](#10-开发)
- [11. 测试](#11-测试)
- [12. 常见问题](#12-常见问题)
- [13. 安全与免责声明](#13-安全与免责声明)

---

## 1. 项目简介

### 1.1 为什么需要 CSSwitch

Claude Science 是 Anthropic 面向科研、数据分析、代码执行等场景的 AI Agent 工具。它默认要求：

1. 通过 Claude 账号登录；
2. 模型推理走 Anthropic 服务。

CSSwitch 在本地插入一个控制层，把「登录门票」和「模型推理」解耦：

- **登录门票**：用本地生成的虚拟 OAuth 让 Science 认为已登录，不复制你的真实 Claude 凭证。
- **模型推理**：把 Science 发出的 Anthropic API 请求翻译/透传到第三方 provider。

### 1.2 核心能力

- 支持多 profile 管理，同一家 provider 可保存多组 Key / 模型 / 中转地址。
- 原生 Anthropic 兼容端点优先透传（DeepSeek、Kimi、MiniMax 等），保留工具调用、thinking、流式输出。
- Qwen 与自定义 OpenAI 端点通过本地 Python 代理做协议转换。
- 一键启动：自动起代理 → 生成虚拟 OAuth → 启动隔离沙箱 Science → 打开浏览器。
- 保留「官方 Claude」模式，有订阅的用户可随时切回真实 Science。
- 退 app 默认停止代理，沙箱 Science 可选保留。

---

## 2. 工作原理

```text
┌─────────────────────────────────────────────────────────────┐
│                     用户桌面 / WSL2                          │
│  ┌─────────────────┐     一键开始     ┌──────────────────┐   │
│  │ CSSwitch 面板   │ ───────────────> │  Tauri 后端      │   │
│  │ (HTML/CSS/JS)   │                  │  (Rust 进程管家) │   │
│  └─────────────────┘                  └────────┬─────────┘   │
│                                                │              │
│                          1. 启动代理           │              │
│                          2. 写入虚拟 OAuth     │              │
│                          3. 启动沙箱 Science   │              │
│                          4. 打开浏览器         │              │
│                                                ▼              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │              CSSwitch 本地代理                          │  │
│  │  proxy/csswitch_proxy.py                                │  │
│  │  - 接收 Anthropic Messages / Responses 请求             │  │
│  │  - 按 provider 策略透传或翻译为 OpenAI 格式              │  │
│  │  - 注入第三方 API Key（环境变量，不进命令行）            │  │
│  └────────────────────────────────────────────────────────┘  │
│                          │                                    │
│                          ▼                                    │
│  ┌────────────────────────────────────────────────────────┐  │
│  │        隔离沙箱 Claude Science                          │  │
│  │  HOME = ~/.csswitch/sandbox/home                        │  │
│  │  data-dir = ~/.csswitch/sandbox/home/.claude-science    │  │
│  │  port = 8990（默认）                                    │  │
│  └────────────────────────────────────────────────────────┘  │
│                          │                                    │
│                          ▼                                    │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐  ┌─────────┐ │
│  │ DeepSeek   │  │ 阿里千问   │  │ Kimi       │  │ OpenAI  │ │
│  │ (原生      │  │ (OpenAI    │  │ (原生      │  │ 兼容    │ │
│  │ Anthropic) │  │ 翻译)      │  │ Anthropic) │  │ 端点    │ │
│  └────────────┘  └────────────┘  └────────────┘  └─────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### 2.1 数据流

1. 你在浏览器里与沙箱 Science 交互。
2. Science 把模型请求发到 `http://127.0.0.1:8990`（沙箱端口，默认）。
3. Science 内部把 `ANTHROPIC_BASE_URL` 指向 CSSwitch 代理地址。
4. 代理把请求翻译/透传到第三方 provider。
5. 第三方返回后，代理再翻译回 Anthropic 格式给 Science。

### 2.2 虚拟 OAuth 门票

Science 启动时必须读到有效的 OAuth token、org、encryption key。CSSwitch 在沙箱 data-dir 里生成一套**本地虚拟凭证**：

- 账号：`virtual@localhost.invalid`
- 加密：HKDF-SHA256 + AES-256-GCM v2
- 与旧版 `.mjs` 伪造器字节级兼容

这些凭证只存在于沙箱目录，不复制真实 `~/.claude-science` 里的任何登录信息。

---

## 3. 项目结构

```text
CSSwitch-Linux/
├── CHANGELOG.md              # 版本变更日志
├── CLAUDE.md                 # 项目铁律与架构速查（必读）
├── LICENSE                   # MIT 许可证
├── README.md                 # 本文件
├── README.en.md              # 英文 README
├── desktop/                  # Tauri 桌面应用
│   ├── README.md             # 桌面端说明
│   ├── package.json          # npm 脚本与依赖
│   ├── src/                  # 前端面板（HTML/CSS/JS，无框架）
│   │   ├── index.html
│   │   ├── main.js
│   │   └── styles.css
│   └── src-tauri/            # Rust 后端
│       ├── Cargo.toml
│       ├── tauri.conf.json   # Tauri 配置：窗口、打包、资源
│       ├── build.rs
│       └── src/
│           ├── main.rs       # 二进制入口
│           ├── lib.rs        # Tauri command 与进程管家逻辑
│           ├── config.rs     # ~/.csswitch/config.json 读写
│           ├── oauth_forge.rs# 虚拟 OAuth 伪造器（Rust 原生）
│           ├── proc.rs       # 探活 / which / secret 生成
│           ├── templates.rs  # provider adapter 注册表
│           ├── lifecycle.rs  # 代理/沙箱生命周期管理
│           └── scratch.rs    # 临时/调试逻辑
├── docs/
│   └── LINUX.md              # Linux 安装与命令行速查
├── proxy/                    # Python 翻译代理
│   ├── csswitch_proxy.py     # 主代理入口
│   ├── provider_policy.py    # provider 策略与模型解析
│   ├── anthropic_compat.py   # Anthropic ↔ OpenAI 协议转换
│   ├── dsml_shim.py          # DeepSeek / Kimi / MiniMax 等透传 shim
│   └── qwen_proxy.py         # 早期千问专用代理（已合并）
├── scripts/                  # 启动/停止/诊断脚本
│   ├── launch-virtual-sandbox.sh   # 启动隔离沙箱 Science
│   ├── stop-science-sandbox.sh     # 停止沙箱
│   ├── make-virtual-oauth.mjs      # 虚拟 OAuth 伪造器（Node 版，fallback）
│   ├── doctor.sh                   # 环境诊断
│   ├── verify-proxy.sh             # 代理健康检查
│   └── self-test.sh                # 离线回归套件入口
├── test/                     # 测试套件
│   ├── run_all.sh            # 离线回归总入口
│   ├── run-scripts.sh        # 脚本测试
│   ├── run-rust.sh           # Rust 单元测试
│   ├── run-offline.sh        # 代理离线测试
│   ├── run-loopback.sh       # 回环测试
│   ├── run-frontend.sh       # 前端面板测试
│   ├── real_machine_guard.sh # 实机测试护栏
│   ├── REAL_MACHINE_TEST.md  # 实机测试说明
│   ├── mock_upstream.py      # 测试用的上游 mock
│   ├── golden/               # golden 测试数据
│   └── test_*.py             # pytest 测试文件
└── findings/                 # 证据、分析、诊断记录（git 忽略）
```

---

## 4. 核心文件说明

### 4.1 代理层

| 文件 | 说明 |
|------|------|
| `proxy/csswitch_proxy.py` | 主代理。启动 HTTP 服务，接收 Anthropic 请求，按 provider 透传或翻译。支持 `--provider deepseek/qwen/relay/openai-custom/openai-responses`。 |
| `proxy/provider_policy.py` | provider 策略纯函数。模型名解析、模型映射、能力匹配、nonce 生成。 |
| `proxy/anthropic_compat.py` | Anthropic Messages / Responses 与 OpenAI Chat Completions / Responses 之间的协议转换。 |
| `proxy/dsml_shim.py` | DeepSeek、Kimi、MiniMax、GLM 等原生 Anthropic 兼容端点的透传 shim，尽量保留工具调用与 thinking。 |

### 4.2 桌面后端（Rust）

| 文件 | 说明 |
|------|------|
| `desktop/src-tauri/src/lib.rs` | 后端主入口。暴露 Tauri command：`set_mode`、`open_official`、`start_proxy`、`stop_proxy`、`start_sandbox`、`open_sandbox_url` 等。 |
| `desktop/src-tauri/src/config.rs` | 多 profile 配置读写。路径 `~/.csswitch/config.json`，权限 0600，拒绝符号链接，原子写。 |
| `desktop/src-tauri/src/oauth_forge.rs` | Rust 原生虚拟 OAuth 伪造器。HKDF-SHA256 + AES-256-GCM，与 Node 版 `.mjs` 字节兼容。 |
| `desktop/src-tauri/src/proc.rs` | 子进程管理、探活、`which` 兜底、一次性 secret 生成、上游可达性检查。 |
| `desktop/src-tauri/src/templates.rs` | provider adapter 模板注册表：`deepseek`、`qwen`、`relay`、`openai-custom`、`openai-responses`。 |
| `desktop/src-tauri/src/lifecycle.rs` | 代理进程与沙箱进程的启动、停止、健康复用逻辑。 |

### 4.3 前端面板

| 文件 | 说明 |
|------|------|
| `desktop/src/index.html` | 面板结构：provider 选择、profile 列表、key 输入、状态灯、一键开始按钮。 |
| `desktop/src/main.js` | 面板交互逻辑。调用 Tauri command，管理状态灯，处理 profile 增删改。 |
| `desktop/src/styles.css` | 面板样式。 |

### 4.4 脚本

| 文件 | 说明 |
|------|------|
| `scripts/launch-virtual-sandbox.sh` | 启动隔离沙箱 Science。复制运行时资产（不解引用 conda 断链）、写入虚拟 OAuth、设置 `ANTHROPIC_BASE_URL`、启动 `claude-science serve`。 |
| `scripts/stop-science-sandbox.sh` | 按 data-dir 查找并停止沙箱 Science 进程。 |
| `scripts/doctor.sh` | 只读环境诊断：检查依赖、key、端口、权限、铁律自检。 |
| `scripts/verify-proxy.sh` | 验证运行中代理的 `/health` 和 `/v1/models`，零上游花费。 |
| `scripts/self-test.sh` | 离线回归套件包装，调用 `test/run_all.sh`。 |
| `scripts/make-virtual-oauth.mjs` | Node 版虚拟 OAuth 伪造器。桌面 app 用 Rust 原生版，独立运行脚本时作 fallback。 |

### 4.5 配置与构建

| 文件 | 说明 |
|------|------|
| `desktop/src-tauri/tauri.conf.json` | Tauri 应用配置：窗口尺寸 420×700、资源打包（`proxy/` 和 `scripts/`）、目标包格式 `deb` 和 `appimage`。 |
| `desktop/src-tauri/Cargo.toml` | Rust 依赖：`tauri`、`serde`、`aes-gcm`、`hkdf`、`sha2`、`base64`。 |
| `desktop/package.json` | npm 脚本，仅依赖 `@tauri-apps/cli`。 |

---

## 5. 环境要求

### 5.1 必需

- **Linux x86_64**（已验证 Ubuntu 22.04 / WSL2）
- **Claude Science** 二进制：
  - 默认查找顺序：`$HOME/.local/bin/claude-science` → `/usr/bin/claude-science` → `/usr/local/bin/claude-science` → `/opt/claude-science/claude-science` → `$PATH`
  - 也可通过环境变量 `SCIENCE_BIN=/path/to/claude-science` 显式指定
- **Python 3**：代理运行时需要
- **第三方 API Key**：DeepSeek、DashScope、Kimi、MiniMax、GLM、OpenRouter、中转站等

### 5.2 仅构建时需要

- **Node.js** ≥ 18 与 **npm**
- **Rust** 工具链（建议通过 [rustup](https://rustup.rs) 安装）
- **系统依赖**（Debian/Ubuntu）：

```bash
sudo apt-get update
sudo apt-get install -y \
  libglib2.0-dev \
  libgtk-3-dev \
  libwebkit2gtk-4.1-dev \
  pkg-config \
  build-essential
```

- **AppImage 额外需要**（如要生成 `.AppImage`）：

```bash
sudo apt-get install -y libfuse2
```

---

## 6. 安装

### 6.1 方式一：下载 .deb 安装（推荐普通用户）

1. 从 [GitHub Releases](../../releases/latest) 下载 `CSSwitch-Linux_x.x.x_amd64.deb`。
2. 安装：

```bash
sudo dpkg -i CSSwitch-Linux_0.4.0_amd64.deb
sudo apt-get install -f
```

3. 启动：

```bash
# 从应用菜单点击 CSSwitch-Linux
# 或命令行：
csswitch-linux
```

> 若首次在 WSL2 下窗口不显示，检查 `DISPLAY` 与 `WAYLAND_DISPLAY`：
> ```bash
> export DISPLAY=:0
> # 或强制走 X11
> GDK_BACKEND=x11 csswitch-linux
> ```

### 6.2 方式二：用户级安装（无需 sudo）

适合无 root 权限或想快速验证：

```bash
# 假设 .deb 已下载到当前目录
mkdir -p ~/.local/share/CSSwitch-Linux
mkdir -p ~/.local/bin
dpkg -x CSSwitch-Linux_0.4.0_amd64.deb ~/.local/share/CSSwitch-Linux
ln -sf ~/.local/share/CSSwitch-Linux/usr/bin/csswitch-linux ~/.local/bin/csswitch-linux

# 启动
~/.local/bin/csswitch-linux
```

### 6.3 方式三：从源码构建后安装

见 [第 9 节：打包与发布](#9-打包与发布)。

---

## 7. 使用指南

### 7.1 首次启动

1. 启动 CSSwitch 面板。
2. 选择 provider（如 DeepSeek）。
3. 填入 API Key。
4. 可选：修改模型名、base_url、温度等参数。
5. 点击「设为当前」保存 profile。
6. 点击「一键开始」。

### 7.2 一键开始后发生什么

1. 后端根据当前 profile 的 `template_id` 选择 adapter。
2. 启动 `proxy/csswitch_proxy.py` 子进程，把 Key 以环境变量注入。
3. 生成一次性 path secret，代理只接受带该 secret 的请求。
4. Rust 后端在沙箱 data-dir 写入虚拟 OAuth 凭证。
5. 启动隔离沙箱 Science：
   - `HOME = ~/.csswitch/sandbox/home`
   - `data-dir = ~/.csswitch/sandbox/home/.claude-science`
   - 端口默认 `8990`
   - `ANTHROPIC_BASE_URL` 指向本地代理
6. 打开系统浏览器访问沙箱 Science。

### 7.3 官方 Claude 模式

在面板中切换到「官方 Claude」模式：

- 后端停止 CSSwitch 代理。
- 直接启动/打开你真实的 Claude Science 实例（端口 `8000`）。
- 不注入 `ANTHROPIC_BASE_URL`，模型走 Anthropic 官方。

此模式不影响你的真实登录状态。

### 7.4 命令行启动沙箱（不打开 GUI）

如果你不想用桌面面板，可以手动分步启动：

```bash
cd /path/to/CSSwitch-Linux

# 1. 起代理
DEEPSEEK_API_KEY=your-key python3 proxy/csswitch_proxy.py \
  --provider deepseek --port 18991 --auth-token SECRET &

# 2. 起沙箱
SCIENCE_BIN=/home/muadib/.local/bin/claude-science \
SANDBOX_HOME=/home/muadib/.csswitch/sandbox/home \
bash scripts/launch-virtual-sandbox.sh --port 8990 \
  --proxy-url http://127.0.0.1:18991/SECRET

# 3. 停止沙箱
bash scripts/stop-science-sandbox.sh
```

> 千问示例把 `--provider deepseek` 换成 `--provider qwen`，Key 换成 `DASHSCOPE_API_KEY`。

---

## 8. 配置详解

配置文件位置：`~/.csswitch/config.json`，权限 `0600`。

### 8.1 配置结构示例

```json
{
  "schema_version": 2,
  "profiles": [
    {
      "id": "profile-uuid-1",
      "name": "DeepSeek 主账号",
      "template_id": "deepseek",
      "category": "deepseek",
      "api_format": "anthropic",
      "base_url": "",
      "api_key": "sk-...",
      "model": "deepseek-chat"
    }
  ],
  "active_id": "profile-uuid-1",
  "proxy_port": 18991,
  "sandbox_port": 8990,
  "secret": "",
  "mode": "proxy"
}
```

### 8.2 字段说明

| 字段 | 说明 |
|------|------|
| `schema_version` | 配置 schema 版本，当前为 `2`。 |
| `profiles` | profile 数组。 |
| `id` / `name` | profile 唯一标识与显示名。 |
| `template_id` | adapter 模板：`deepseek`、`qwen`、`relay`、`openai-custom`、`openai-responses`。决定运行行为与 UI 能力。 |
| `category` | provider 分类，通常与 `template_id` 相同。 |
| `api_format` | 上游 API 格式：`anthropic` 或 `openai`。 |
| `base_url` | 自定义 base_url，空字符串表示用 provider 默认值。 |
| `api_key` | 第三方 API Key。存储时完整保留，前端只显示末 4 位。 |
| `model` | 默认模型名。 |
| `active_id` | 当前生效的 profile ID。 |
| `proxy_port` | 本地代理端口，默认 `18991`。 |
| `sandbox_port` | 沙箱 Science 端口，默认 `8990`。 |
| `secret` | 代理 path-secret，首次为空，由后端生成后持久化。 |
| `mode` | 运行模式：`proxy`（第三方）或 `official`（真实 Claude Science）。 |

### 8.3 支持的 provider

| provider | 说明 | 默认 base_url |
|----------|------|---------------|
| `deepseek` | DeepSeek 原生 Anthropic 兼容端点 | `https://api.deepseek.com/beta` |
| `qwen` | 阿里 DashScope / 通义千问 | `https://dashscope.aliyuncs.com/compatible-mode/v1` |
| `relay` | 中转站 / 自定义 OpenAI 兼容端点 | 用户填写 |
| `openai-custom` | 自定义 OpenAI Chat Completions 端点 | 用户填写 |
| `openai-responses` | 自定义 OpenAI Responses 端点 | 用户填写 |

---

## 9. 打包与发布

### 9.1 构建前准备

确保已安装 [第 5.2 节](#52-仅构建时需要) 的依赖。

```bash
# 进入桌面端目录
cd desktop

# 安装 Node 依赖
npm install
```

### 9.2 构建发布包

```bash
cd desktop
npm run tauri build
```

构建产物默认输出到：

```text
desktop/src-tauri/target/release/bundle/
├── deb/CSSwitch-Linux_0.4.0_amd64.deb
└── appimage/CSSwitch-Linux_0.4.0_amd64.AppImage
```

> 若 `.AppImage` 构建失败提示 `failed to run linuxdeploy`，请安装 `libfuse2`：
> ```bash
> sudo apt-get install libfuse2
> ```

### 9.3 只构建 .deb

Tauri CLI 目前没有单独的 `--target deb` 开关。若不需要 AppImage，可临时修改 `desktop/src-tauri/tauri.conf.json`：

```json
"bundle": {
  "targets": ["deb"]
}
```

然后重新运行 `npm run tauri build`。

### 9.4 开发模式运行

```bash
cd desktop
npm run tauri dev
```

开发模式下，Rust 后端会直接从项目目录找 `proxy/` 和 `scripts/`；打包后会使用 Tauri 资源目录里的副本。

---

## 10. 开发

### 10.1 目录约定

- **Python 代理**：所有 provider 相关逻辑放在 `proxy/`；`provider_policy.py` 是最底层，不依赖 `csswitch_proxy.py`，避免循环导入。
- **Rust 后端**：进程管家逻辑在 `lib.rs`；配置在 `config.rs`；虚拟 OAuth 在 `oauth_forge.rs`；子进程工具在 `proc.rs`。
- **前端面板**：无框架原生 HTML/CSS/JS，保持轻量。

### 10.2 资源路径

打包后的 app 通过 `tauri.conf.json` 的 `bundle.resources` 把 `proxy/` 和 `scripts/` 打进资源目录：

```json
"resources": {
  "../../proxy": "proxy",
  "../../scripts": "scripts"
}
```

Rust 后端用 `asset_root()` 按以下顺序定位资源：

1. 打包后：Tauri 资源目录。
2. 开发态：从可执行文件位置向上回溯到仓库根（找到 `proxy/csswitch_proxy.py`）。
3. 环境变量 `CSSWITCH_REPO=/path/to/CSSwitch-Linux` 可显式指定。

### 10.3 提交前检查

```bash
# Rust 单元测试
cd desktop/src-tauri
cargo test

# Python 代理离线测试
cd /path/to/CSSwitch-Linux
bash test/run_all.sh

# 实机测试（会启动沙箱 Science，需用户明确同意）
bash test/real_machine_guard.sh
```

---

## 11. 测试

### 11.1 离线回归套件

```bash
bash test/run_all.sh
```

该脚本会自动：

1. 启动 mock 上游；
2. 启动 CSSwitch 代理；
3. 运行 Python 单元测试、golden 测试、流式测试；
4. 运行 Rust 单元测试；
5. 运行脚本测试；
6. 停止所有测试进程。

### 11.2 单独运行测试

```bash
# Python 代理测试
cd test
python3 -m pytest test_anthropic_compat.py test_provider_policy.py test_proxy_units.py -v

# Rust 单元测试
cd desktop/src-tauri
cargo test

# 脚本护栏测试
bash test/test_ops_scripts.sh
```

### 11.3 实机测试

见 `test/REAL_MACHINE_TEST.md`。实机测试会真正启动沙箱 Science，请确保：

- 已配置有效的第三方 API Key；
- 已明确同意启动沙箱；
- 理解铁律：不影响真实 `~/.claude-science` 与端口 `8000`。

---

## 12. 常见问题

### Q1: 一键开始报错 `cp: .../ar: 调用 stat 失败: 没有那个文件或目录`

**原因**：`scripts/launch-virtual-sandbox.sh` 用 `cp -rL` 解引用符号链接，但 conda 的 gcc 包里存在断链。

**解决**：已修复。`conda` 目录改用 `cp -r` 保留符号链接。请升级到最新版或重新打包安装。

### Q2: 窗口打不开，终端无输出

```bash
# 检查显示环境
echo $DISPLAY
echo $WAYLAND_DISPLAY

# WSL2 下强制 X11
GDK_BACKEND=x11 csswitch-linux
```

### Q3: 代理启动失败，提示 key 无效

- 确认填的是对应 provider 的 Key，不是 Claude API Key。
- 检查网络能否访问 provider 的 base_url。
- 中转站用户确认 `base_url` 末尾是否带 `/v1`。

### Q4: 沙箱 Science 卡在 "Switching organization"

通常是沙箱到 `claude.ai` 的 profile 请求被阻塞。CSSwitch 已通过 `https_proxy` fast-fail 处理。若仍卡住，检查代理是否正常运行：

```bash
bash scripts/verify-proxy.sh http://127.0.0.1:18991/your-secret
```

### Q5: AppImage 打包失败 `failed to run linuxdeploy`

安装 FUSE2：

```bash
sudo apt-get install libfuse2
```

### Q6: 如何卸载

```bash
# 系统级安装
sudo dpkg -r csswitch-linux

# 用户级安装
rm -rf ~/.local/share/CSSwitch-Linux ~/.local/bin/csswitch-linux
rm -rf ~/.csswitch
```

---

## 13. 安全与免责声明

### 13.1 铁律保障

本项目严格遵守以下原则：

1. **绝不复制真实 OAuth token**：真实 Claude Science 数据目录 `~/.claude-science` 里的 `.oauth-tokens`、`encryption.key`、`active-org.json`、`.key-backups/` 等**只读都要谨慎，绝不复制、修改、删除**。
2. **沙箱完全隔离**：独立 `HOME`、独立 data-dir、独立端口（默认 `8990`），与真实实例端口 `8000` 完全分开。
3. **Key 通过环境变量注入**：第三方 API Key 以环境变量传给代理子进程，**不会出现在命令行参数**，避免 `ps` 泄露。
4. **虚拟 OAuth 本地生成**：沙箱里的 OAuth token、org、encryption key 都是本地随机生成的虚拟凭证，与真实账号无关。

### 13.2 免责声明

- CSSwitch 是第三方社区工具，与 Anthropic 无关。
- 使用第三方模型 API 需遵守对应平台的服务条款。
- 本项目不对任何账号封禁、数据丢失或服务中断负责。
- 请在合法、授权、自担风险的前提下使用。

---

## 相关链接

- [原作者 / 上游项目 CSSwitch（macOS 版）](https://github.com/SuperJJ007/CSSwitch)
- [CHANGELOG.md](./CHANGELOG.md)
- [CLAUDE.md](./CLAUDE.md)
- [docs/LINUX.md](./docs/LINUX.md)
- [GitHub Releases](../../releases/latest)
- [报告问题](https://github.com/SuperJJ007/CSSwitch/issues/new?template=bug_report.yml)
