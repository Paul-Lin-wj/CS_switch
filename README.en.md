<p align="center">
  <img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License">
  <img src="https://img.shields.io/badge/platform-Linux%20x86_64-1d1d1f.svg" alt="Linux x86_64">
  <img src="https://img.shields.io/badge/built%20with-Tauri%202-C25A34.svg" alt="Tauri 2">
</p>

# CSSwitch-Linux

CSSwitch-Linux is the Linux port of CSSwitch, a local model switcher for Claude Science. It routes Science's inference requests to third-party model APIs, allowing you to use DeepSeek, Qwen (Tongyi Qianwen), Kimi, MiniMax, GLM, OpenRouter, relay providers, or any OpenAI-compatible endpoint inside Claude Science without a Claude subscription.

This repository is for both:

- **End users**: Download the `.deb`, enter a third-party API key, click **Start**.
- **Developers / contributors**: Read the project structure and build instructions to package, debug, or extend providers.

> Verified on **Linux x86_64 / WSL2 Ubuntu 22.04**.
>
> **Original project**: the macOS version is maintained by the original author at [github.com/SuperJJ007/CSSwitch](https://github.com/SuperJJ007/CSSwitch). This repository is the Linux port.
>
> License: MIT. See [LICENSE](./LICENSE).

---

## Table of Contents

- [1. Introduction](#1-introduction)
- [2. How It Works](#2-how-it-works)
- [3. Project Structure](#3-project-structure)
- [4. Core Files](#4-core-files)
- [5. Requirements](#5-requirements)
- [6. Installation](#6-installation)
- [7. Usage](#7-usage)
- [8. Configuration](#8-configuration)
- [9. Packaging and Release](#9-packaging-and-release)
- [10. Development](#10-development)
- [11. Testing](#11-testing)
- [12. Troubleshooting](#12-troubleshooting)
- [13. Security and Disclaimer](#13-security-and-disclaimer)

---

## 1. Introduction

### 1.1 Why CSSwitch

Claude Science is Anthropic's AI agent tool for research, data analysis, code execution, and more. By default it requires:

1. Signing in with a Claude account.
2. Routing model inference through Anthropic's services.

CSSwitch inserts a local control layer that decouples **login ticket** from **model inference**:

- **Login ticket**: A locally generated virtual OAuth credential convinces Science it is signed in, without copying your real Claude credentials.
- **Model inference**: Science's Anthropic API requests are translated or passed through to a third-party provider.

### 1.2 Key Features

- Manage multiple profiles; save different keys, models, or relay URLs for the same provider.
- Native Anthropic-compatible endpoints (DeepSeek, Kimi, MiniMax, etc.) are passed through when possible, preserving tool use, thinking, and streaming.
- Qwen and custom OpenAI endpoints are translated by the local Python proxy.
- One-click start: launches proxy, generates virtual OAuth, starts isolated sandbox Science, and opens the browser.
- "Official Claude" mode lets subscribers switch back to the real Claude Science at any time.
- Closing the app stops the proxy by default; the sandbox can be kept alive.

---

## 2. How It Works

```text
┌─────────────────────────────────────────────────────────────┐
│                     User Desktop / WSL2                    │
│  ┌─────────────────┐     One-click    ┌──────────────────┐  │
│  │ CSSwitch Panel  │ ───────────────► │  Tauri Backend   │  │
│  │ (HTML/CSS/JS)   │                  │  (Rust process   │  │
│  └─────────────────┘                  │   manager)       │  │
│                                       └────────┬─────────┘  │
│                                                │             │
│                          1. Start proxy        │             │
│                          2. Write virtual OAuth│             │
│                          3. Start sandbox      │             │
│                          4. Open browser       │             │
│                                                ▼             │
│  ┌────────────────────────────────────────────────────────┐ │
│  │              CSSwitch Local Proxy                       │ │
│  │  proxy/csswitch_proxy.py                                │ │
│  │  - Accepts Anthropic Messages / Responses requests      │ │
│  │  - Passes through or translates per provider strategy   │ │
│  │  - Injects third-party API key via environment variable │ │
│  └────────────────────────────────────────────────────────┘ │
│                          │                                   │
│                          ▼                                   │
│  ┌────────────────────────────────────────────────────────┐ │
│  │        Isolated Sandbox Claude Science                  │ │
│  │  HOME = ~/.csswitch/sandbox/home                        │ │
│  │  data-dir = ~/.csswitch/sandbox/home/.claude-science    │ │
│  │  port = 8990 (default)                                  │ │
│  └────────────────────────────────────────────────────────┘ │
│                          │                                   │
│                          ▼                                   │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐  ┌────────┐ │
│  │ DeepSeek   │  │ Alibaba    │  │ Kimi       │  │ OpenAI │ │
│  │ (native    │  │ Qwen       │  │ (native    │  │ compat │ │
│  │ Anthropic) │  │ (translat) │  │ Anthropic) │  │ endpoint│ │
│  └────────────┘  └────────────┘  └────────────┘  └────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### 2.1 Data Flow

1. You interact with sandbox Science in the browser.
2. Science sends model requests to `http://127.0.0.1:8990` (sandbox port, default).
3. Science uses `ANTHROPIC_BASE_URL` pointing to the CSSwitch proxy address.
4. The proxy translates or passes through the request to the third-party provider.
5. The third-party response is translated back to Anthropic format and returned to Science.

### 2.2 Virtual OAuth Ticket

Science requires a valid OAuth token, organization, and encryption key on startup. CSSwitch generates a set of **local virtual credentials** inside the sandbox data-dir:

- Account: `virtual@localhost.invalid`
- Encryption: HKDF-SHA256 + AES-256-GCM v2
- Byte-compatible with the legacy Node `.mjs` forger

These credentials exist only in the sandbox directory and do not copy any login information from your real `~/.claude-science`.

---

## 3. Project Structure

```text
CSSwitch-Linux/
├── CHANGELOG.md              # Release changelog
├── CLAUDE.md                 # Project iron rules and architecture cheat sheet
├── LICENSE                   # MIT license
├── README.md                 # Chinese README
├── README.en.md              # This file
├── desktop/                  # Tauri desktop app
│   ├── README.md             # Desktop-specific notes
│   ├── package.json          # npm scripts and dependencies
│   ├── src/                  # Frontend panel (HTML/CSS/JS, no framework)
│   │   ├── index.html
│   │   ├── main.js
│   │   └── styles.css
│   └── src-tauri/            # Rust backend
│       ├── Cargo.toml
│       ├── tauri.conf.json   # Tauri config: window, bundle, resources
│       ├── build.rs
│       └── src/
│           ├── main.rs       # Binary entry point
│           ├── lib.rs        # Tauri commands and process manager
│           ├── config.rs     # ~/.csswitch/config.json read/write
│           ├── oauth_forge.rs# Virtual OAuth forger (Rust native)
│           ├── proc.rs       # Process liveness / which / secret generation
│           ├── templates.rs  # Provider adapter registry
│           ├── lifecycle.rs  # Proxy/sandbox lifecycle management
│           └── scratch.rs    # Temporary/debug logic
├── docs/
│   └── LINUX.md              # Linux install and CLI quick reference
├── proxy/                    # Python translation proxy
│   ├── csswitch_proxy.py     # Main proxy entry
│   ├── provider_policy.py    # Provider policy and model resolution
│   ├── anthropic_compat.py   # Anthropic ↔ OpenAI protocol translation
│   ├── dsml_shim.py          # Pass-through shim for DS/Kimi/MiniMax/GLM
│   └── qwen_proxy.py         # Early Qwen-only proxy (merged)
├── scripts/                  # Start/stop/diagnostic scripts
│   ├── launch-virtual-sandbox.sh   # Start isolated sandbox Science
│   ├── stop-science-sandbox.sh     # Stop sandbox
│   ├── make-virtual-oauth.mjs      # Virtual OAuth forger (Node fallback)
│   ├── doctor.sh                   # Environment diagnostics
│   ├── verify-proxy.sh             # Proxy health check
│   └── self-test.sh                # Offline regression suite entry
├── test/                     # Test suite
│   ├── run_all.sh            # Offline regression entry
│   ├── run-scripts.sh        # Script tests
│   ├── run-rust.sh           # Rust unit tests
│   ├── run-offline.sh        # Proxy offline tests
│   ├── run-loopback.sh       # Loopback tests
│   ├── run-frontend.sh       # Frontend panel tests
│   ├── real_machine_guard.sh # Real-machine test guard
│   ├── REAL_MACHINE_TEST.md  # Real-machine test guide
│   ├── mock_upstream.py      # Mock upstream for tests
│   ├── golden/               # Golden test data
│   └── test_*.py             # pytest files
└── findings/                 # Evidence, analysis, diagnostics (gitignored)
```

---

## 4. Core Files

### 4.1 Proxy Layer

| File | Description |
|------|-------------|
| `proxy/csswitch_proxy.py` | Main proxy. Starts HTTP server, accepts Anthropic requests, passes through or translates per `--provider deepseek/qwen/relay/openai-custom/openai-responses`. |
| `proxy/provider_policy.py` | Pure provider-policy functions: model name resolution, model mapping, capability matching, nonce generation. |
| `proxy/anthropic_compat.py` | Protocol translation between Anthropic Messages/Responses and OpenAI Chat Completions/Responses. |
| `proxy/dsml_shim.py` | Pass-through shim for DeepSeek, Kimi, MiniMax, GLM native Anthropic-compatible endpoints. |

### 4.2 Desktop Backend (Rust)

| File | Description |
|------|-------------|
| `desktop/src-tauri/src/lib.rs` | Backend main entry. Exposes Tauri commands: `set_mode`, `open_official`, `start_proxy`, `stop_proxy`, `start_sandbox`, `open_sandbox_url`, etc. |
| `desktop/src-tauri/src/config.rs` | Multi-profile config I/O. Path `~/.csswitch/config.json`, mode `0600`, rejects symlinks, atomic writes. |
| `desktop/src-tauri/src/oauth_forge.rs` | Rust-native virtual OAuth forger. HKDF-SHA256 + AES-256-GCM, byte-compatible with Node `.mjs`. |
| `desktop/src-tauri/src/proc.rs` | Subprocess management, liveness checks, `which` fallback, one-time secret generation, upstream reachability. |
| `desktop/src-tauri/src/templates.rs` | Provider adapter registry: `deepseek`, `qwen`, `relay`, `openai-custom`, `openai-responses`. |
| `desktop/src-tauri/src/lifecycle.rs` | Proxy and sandbox process start/stop/health-reuse logic. |

### 4.3 Frontend Panel

| File | Description |
|------|-------------|
| `desktop/src/index.html` | Panel markup: provider selection, profile list, key input, status lights, start button. |
| `desktop/src/main.js` | Panel interaction logic. Calls Tauri commands, manages status lights, handles profile CRUD. |
| `desktop/src/styles.css` | Panel styles. |

### 4.4 Scripts

| File | Description |
|------|-------------|
| `scripts/launch-virtual-sandbox.sh` | Starts isolated sandbox Science. Copies runtime assets (preserving conda symlinks), writes virtual OAuth, sets `ANTHROPIC_BASE_URL`, runs `claude-science serve`. |
| `scripts/stop-science-sandbox.sh` | Finds and stops the sandbox Science process by data-dir. |
| `scripts/doctor.sh` | Read-only environment diagnostics: dependencies, keys, ports, permissions, iron-rule self-check. |
| `scripts/verify-proxy.sh` | Verifies running proxy `/health` and `/v1/models`, zero upstream cost. |
| `scripts/self-test.sh` | Offline regression suite wrapper, calls `test/run_all.sh`. |
| `scripts/make-virtual-oauth.mjs` | Node virtual OAuth forger. Desktop app uses the Rust native version; standalone script uses this as fallback. |

### 4.5 Config and Build

| File | Description |
|------|-------------|
| `desktop/src-tauri/tauri.conf.json` | Tauri app config: 420×700 window, resource bundling (`proxy/` and `scripts/`), target formats `deb` and `appimage`. |
| `desktop/src-tauri/Cargo.toml` | Rust dependencies: `tauri`, `serde`, `aes-gcm`, `hkdf`, `sha2`, `base64`. |
| `desktop/package.json` | npm scripts; only depends on `@tauri-apps/cli`. |

---

## 5. Requirements

### 5.1 Required

- **Linux x86_64** (verified on Ubuntu 22.04 / WSL2)
- **Claude Science** binary:
  - Search order: `$HOME/.local/bin/claude-science` → `/usr/bin/claude-science` → `/usr/local/bin/claude-science` → `/opt/claude-science/claude-science` → `$PATH`
  - Override with environment variable `SCIENCE_BIN=/path/to/claude-science`
- **Python 3**: required to run the proxy
- **Third-party API key**: DeepSeek, DashScope, Kimi, MiniMax, GLM, OpenRouter, relay, etc.

### 5.2 Build-only Requirements

- **Node.js** ≥ 18 and **npm**
- **Rust** toolchain (install via [rustup](https://rustup.rs))
- **System dependencies** (Debian/Ubuntu):

```bash
sudo apt-get update
sudo apt-get install -y \
  libglib2.0-dev \
  libgtk-3-dev \
  libwebkit2gtk-4.1-dev \
  pkg-config \
  build-essential
```

- **AppImage extra** (only if generating `.AppImage`):

```bash
sudo apt-get install -y libfuse2
```

---

## 6. Installation

### 6.1 Option 1: Install from `.deb` (recommended for end users)

1. Download `CSSwitch-Linux_x.x.x_amd64.deb` from [GitHub Releases](../../releases/latest).
2. Install:

```bash
sudo dpkg -i CSSwitch-Linux_0.4.0_amd64.deb
sudo apt-get install -f
```

3. Launch:

```bash
# From the applications menu, click CSSwitch-Linux
# Or from the command line:
csswitch-linux
```

> If the window does not appear under WSL2, check `DISPLAY` and `WAYLAND_DISPLAY`:
> ```bash
> export DISPLAY=:0
> # Or force X11
> GDK_BACKEND=x11 csswitch-linux
> ```

### 6.2 Option 2: User-level Install (no sudo)

For users without root access or who want a quick test:

```bash
# Assuming the .deb is in the current directory
mkdir -p ~/.local/share/CSSwitch-Linux
mkdir -p ~/.local/bin
dpkg -x CSSwitch-Linux_0.4.0_amd64.deb ~/.local/share/CSSwitch-Linux
ln -sf ~/.local/share/CSSwitch-Linux/usr/bin/csswitch-linux ~/.local/bin/csswitch-linux

# Launch
~/.local/bin/csswitch-linux
```

### 6.3 Option 3: Build from Source

See [Section 9: Packaging and Release](#9-packaging-and-release).

---

## 7. Usage

### 7.1 First Launch

1. Start the CSSwitch panel.
2. Select a provider (e.g., DeepSeek).
3. Enter your API key.
4. Optional: change model name, base URL, etc.
5. Click **Set Active** to save the profile.
6. Click **Start** (一键开始).

### 7.2 What Happens After Clicking Start

1. The backend selects an adapter based on the current profile's `template_id`.
2. Starts `proxy/csswitch_proxy.py` as a subprocess, injecting the key via environment variable.
3. Generates a one-time path secret; the proxy only accepts requests containing it.
4. The Rust backend writes virtual OAuth credentials into the sandbox data-dir.
5. Starts isolated sandbox Science:
   - `HOME = ~/.csswitch/sandbox/home`
   - `data-dir = ~/.csswitch/sandbox/home/.claude-science`
   - Port defaults to `8990`
   - `ANTHROPIC_BASE_URL` points to the local proxy
6. Opens the system browser to sandbox Science.

### 7.3 Official Claude Mode

Switch to **Official Claude** mode in the panel:

- The backend stops the CSSwitch proxy.
- It launches/opens your real Claude Science instance (port `8000`).
- No `ANTHROPIC_BASE_URL` injection; models go through Anthropic's official service.

This mode does not affect your real login state.

### 7.4 Starting the Sandbox from the Command Line (no GUI)

If you prefer not to use the desktop panel, start manually:

```bash
cd /path/to/CSSwitch-Linux

# 1. Start proxy
DEEPSEEK_API_KEY=your-key python3 proxy/csswitch_proxy.py \
  --provider deepseek --port 18991 --auth-token SECRET &

# 2. Start sandbox
SCIENCE_BIN=/home/muadib/.local/bin/claude-science \
SANDBOX_HOME=/home/muadib/.csswitch/sandbox/home \
bash scripts/launch-virtual-sandbox.sh --port 8990 \
  --proxy-url http://127.0.0.1:18991/SECRET

# 3. Stop sandbox
bash scripts/stop-science-sandbox.sh
```

> For Qwen, replace `--provider deepseek` with `--provider qwen` and use `DASHSCOPE_API_KEY`.

---

## 8. Configuration

Config file path: `~/.csswitch/config.json`, mode `0600`.

### 8.1 Example Config

```json
{
  "schema_version": 2,
  "profiles": [
    {
      "id": "profile-uuid-1",
      "name": "DeepSeek Main",
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

### 8.2 Field Reference

| Field | Description |
|-------|-------------|
| `schema_version` | Config schema version, currently `2`. |
| `profiles` | Array of profiles. |
| `id` / `name` | Unique profile ID and display name. |
| `template_id` | Adapter template: `deepseek`, `qwen`, `relay`, `openai-custom`, `openai-responses`. Determines runtime behavior and UI capabilities. |
| `category` | Provider category, usually same as `template_id`. |
| `api_format` | Upstream API format: `anthropic` or `openai`. |
| `base_url` | Custom base URL; empty means use provider default. |
| `api_key` | Third-party API key. Stored in full locally; UI only shows last 4 digits. |
| `model` | Default model name. |
| `active_id` | ID of the currently active profile. |
| `proxy_port` | Local proxy port, default `18991`. |
| `sandbox_port` | Sandbox Science port, default `8990`. |
| `secret` | Proxy path secret. Empty on first run; persisted after generation. |
| `mode` | Runtime mode: `proxy` (third-party) or `official` (real Claude Science). |

### 8.3 Supported Providers

| Provider | Description | Default base URL |
|----------|-------------|------------------|
| `deepseek` | DeepSeek native Anthropic-compatible endpoint | `https://api.deepseek.com/beta` |
| `qwen` | Alibaba DashScope / Tongyi Qianwen | `https://dashscope.aliyuncs.com/compatible-mode/v1` |
| `relay` | Relay / custom OpenAI-compatible endpoint | user-provided |
| `openai-custom` | Custom OpenAI Chat Completions endpoint | user-provided |
| `openai-responses` | Custom OpenAI Responses endpoint | user-provided |

---

## 9. Packaging and Release

### 9.1 Before Building

Ensure the dependencies in [Section 5.2](#52-build-only-requirements) are installed.

```bash
# Enter desktop directory
cd desktop

# Install Node dependencies
npm install
```

### 9.2 Build Release Packages

```bash
cd desktop
npm run tauri build
```

Default output:

```text
desktop/src-tauri/target/release/bundle/
├── deb/CSSwitch-Linux_0.4.0_amd64.deb
└── appimage/CSSwitch-Linux_0.4.0_amd64.AppImage
```

> If `.AppImage` build fails with `failed to run linuxdeploy`, install `libfuse2`:
> ```bash
> sudo apt-get install libfuse2
> ```

### 9.3 Build Only `.deb`

Tauri CLI currently has no separate `--target deb` flag. If you do not need AppImage, temporarily edit `desktop/src-tauri/tauri.conf.json`:

```json
"bundle": {
  "targets": ["deb"]
}
```

Then rerun `npm run tauri build`.

### 9.4 Development Mode

```bash
cd desktop
npm run tauri dev
```

In dev mode, the Rust backend locates `proxy/` and `scripts/` directly from the project root. After bundling, it uses the Tauri resource directory copies.

---

## 10. Development

### 10.1 Directory Conventions

- **Python proxy**: All provider logic lives in `proxy/`. `provider_policy.py` is the lowest layer and must not import `csswitch_proxy.py` to avoid circular imports.
- **Rust backend**: Process manager logic in `lib.rs`; config in `config.rs`; virtual OAuth in `oauth_forge.rs`; process utilities in `proc.rs`.
- **Frontend panel**: Plain HTML/CSS/JS, no framework, kept lightweight.

### 10.2 Resource Paths

The bundled app includes `proxy/` and `scripts/` via `tauri.conf.json`:

```json
"resources": {
  "../../proxy": "proxy",
  "../../scripts": "scripts"
}
```

The Rust backend resolves resources via `asset_root()` in this order:

1. After bundling: Tauri resource directory.
2. In dev: walk up from the executable to the repository root (finds `proxy/csswitch_proxy.py`).
3. Environment variable `CSSWITCH_REPO=/path/to/CSSwitch-Linux` can override.

### 10.3 Pre-commit Checks

```bash
# Rust unit tests
cd desktop/src-tauri
cargo test

# Python proxy offline tests
cd /path/to/CSSwitch-Linux
bash test/run_all.sh

# Real-machine tests (starts sandbox Science; requires explicit user consent)
bash test/real_machine_guard.sh
```

---

## 11. Testing

### 11.1 Offline Regression Suite

```bash
bash test/run_all.sh
```

This script automatically:

1. Starts a mock upstream.
2. Starts the CSSwitch proxy.
3. Runs Python unit tests, golden tests, and streaming tests.
4. Runs Rust unit tests.
5. Runs script tests.
6. Stops all test processes.

### 11.2 Run Tests Individually

```bash
# Python proxy tests
cd test
python3 -m pytest test_anthropic_compat.py test_provider_policy.py test_proxy_units.py -v

# Rust unit tests
cd desktop/src-tauri
cargo test

# Script guard tests
bash test/test_ops_scripts.sh
```

### 11.3 Real-machine Tests

See `test/REAL_MACHINE_TEST.md`. Real-machine tests actually start sandbox Science. Ensure:

- A valid third-party API key is configured.
- You explicitly consent to starting the sandbox.
- You understand the iron rules: real `~/.claude-science` and port `8000` are not affected.

---

## 12. Troubleshooting

### Q1: Start fails with `cp: .../ar: stat failed: No such file or directory`

**Cause**: `scripts/launch-virtual-sandbox.sh` uses `cp -rL` to dereference symlinks, but conda's gcc package contains dangling symlinks.

**Fix**: Already fixed. The `conda` directory is now copied with `cp -r` preserving symlinks. Upgrade to the latest version or repackage and reinstall.

### Q2: Window does not open and terminal shows nothing

```bash
# Check display environment
echo $DISPLAY
echo $WAYLAND_DISPLAY

# Force X11 on WSL2
GDK_BACKEND=x11 csswitch-linux
```

### Q3: Proxy fails to start with "invalid key"

- Make sure you entered the key for the selected provider, not a Claude API key.
- Check network access to the provider's base URL.
- Relay users: verify whether `base_url` should end with `/v1`.

### Q4: Sandbox Science stuck at "Switching organization"

This is usually the sandbox's profile request to `claude.ai` being blocked. CSSwitch handles this via `https_proxy` fast-fail. If it still hangs, verify the proxy is running:

```bash
bash scripts/verify-proxy.sh http://127.0.0.1:18991/your-secret
```

### Q5: AppImage build fails with `failed to run linuxdeploy`

Install FUSE2:

```bash
sudo apt-get install libfuse2
```

### Q6: How to Uninstall

```bash
# System install
sudo dpkg -r csswitch-linux

# User-level install
rm -rf ~/.local/share/CSSwitch-Linux ~/.local/bin/csswitch-linux
rm -rf ~/.csswitch
```

---

## 13. Security and Disclaimer

### 13.1 Iron Rules

This project strictly follows these principles:

1. **Never copy real OAuth tokens**: Files in the real Claude Science data directory `~/.claude-science` such as `.oauth-tokens`, `encryption.key`, `active-org.json`, and `.key-backups/` are treated with extreme care and are **never copied, modified, or deleted**.
2. **Sandbox isolation**: Independent `HOME`, independent data-dir, and independent port (default `8990`), completely separate from the real instance on port `8000`.
3. **Keys via environment variables**: Third-party API keys are passed to the proxy subprocess via environment variables and **never appear in command-line arguments**, avoiding `ps` leakage.
4. **Virtual OAuth generated locally**: OAuth tokens, organizations, and encryption keys inside the sandbox are locally generated virtual credentials unrelated to real accounts.

### 13.2 Disclaimer

- CSSwitch is a third-party community tool and is not affiliated with Anthropic.
- Using third-party model APIs is subject to the terms of service of the respective platforms.
- This project is not responsible for any account suspension, data loss, or service interruption.
- Use at your own risk and in compliance with applicable laws and agreements.

---

## Related Links

- [Original author / upstream CSSwitch (macOS)](https://github.com/SuperJJ007/CSSwitch)
- [CHANGELOG.md](./CHANGELOG.md)
- [CLAUDE.md](./CLAUDE.md)
- [docs/LINUX.md](./docs/LINUX.md)
- [GitHub Releases](../../releases/latest)
- [Report a bug](https://github.com/SuperJJ007/CSSwitch/issues/new?template=bug_report.yml)
