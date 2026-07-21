# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# CSSwitch-Linux 项目开发手册

本文档面向后续继续开发 CSSwitch-Linux 的 Claude Code 会话。它记录当前项目状态、关键决策、构建流程和常见坑，优先于任何通用假设。

---

## 1. 项目身份

- **名称**：CSSwitch-Linux
- **定位**：CSSwitch（macOS 原版）的 Linux 移植版。
- **原项目**：https://github.com/SuperJJ007/CSSwitch
- **许可证**：MIT。`LICENSE` 中已合并上游 `shanjunjie` 与本仓库 `Paul-Lin-wj` 的版权声明。
- **验证平台**：Linux x86_64 / WSL2 Ubuntu 22.04。
- **真实 Science 端口**：`8000`（沙箱必须避开此端口）。

---

## 2. 与上游的关系

### 2.1 完全复用的上游内容

这些文件与上游 CSSwitch **字节级相同**，修改前请先考虑是否应在上游修改：

- `proxy/*.py`：`csswitch_proxy.py`、`provider_policy.py`、`anthropic_compat.py`、`dsml_shim.py`、`qwen_proxy.py`
- `scripts/make-virtual-oauth.mjs`
- `scripts/verify-proxy.sh`
- `scripts/self-test.sh`
- `test/*.py`、`test/*.mjs`、`test/mock_upstream.py`、`test/_capability.py`、`test/golden/`
- `CHANGELOG.md`、上游版 `CLAUDE.md`、`LICENSE`（已追加新版权）、`.gitleaks.toml`
- `desktop/src/*`：前端面板 `index.html`、`main.js`、`styles.css`

### 2.2 Linux 移植时已修改的内容

- `scripts/launch-virtual-sandbox.sh`：从 macOS zsh/APFS 克隆改为 Linux bash/`cp`；真实 Science 端口改为 `8000`；已修复 conda 断链问题。
- `scripts/stop-science-sandbox.sh`
- `scripts/doctor.sh`
- `test/test_ops_scripts.sh`、`test/run_all.sh`、`test/run-*.sh`
- `desktop/src-tauri/tauri.conf.json`：目标包 `deb` + `appimage`，资源路径适配 Linux。
- `desktop/src-tauri/Cargo.toml`：包名 `csswitch-linux`，已添加 `license = "MIT"`。
- `desktop/src-tauri/src/*.rs`：claude-science 二进制查找路径、进程管理、资源定位等 Linux 适配。
- `README.md`、`README.en.md`、`docs/LINUX.md`

---

## 3. 架构

```text
CSSwitch-Linux 桌面 app（Tauri 2，正常窗口，420×700）
   │  点击「一键开始」
   ▼
Rust 后端：启动 proxy 子进程 + 写入虚拟 OAuth + 启动沙箱 Science
   │
   ├─── 代理子进程：proxy/csswitch_proxy.py（环境变量注入 Key）
   │              接收 Anthropic 请求 → 透传/翻译 → DeepSeek/Qwen/...
   │
   └─── 沙箱子进程：claude-science serve
                  --data-dir ~/.csswitch/sandbox/home/.claude-science
                  --port 8990
                  ANTHROPIC_BASE_URL 指向本地代理
```

### 3.1 铁律（最高优先级，任何会话都不得违反）

1. **绝不影响用户真实的订阅与登录状态。** 真实 Claude Science 的数据目录是 `~/.claude-science`，登录凭证在 `~/.claude-science/.oauth-tokens`、`active-org.json`、`encryption.key`、`orgs/`、`.key-backups/`。这些文件**只读都要谨慎，绝不复制、绝不修改、绝不删除**。
2. **绝不把真实 OAuth token 复制进任何沙箱。** 沙箱使用本地生成的虚拟 OAuth，与真实 token 无关。
3. **绝不用改过的环境变量去启动用户的真实实例。** 真实实例跑在端口 `8000`。所有沙箱必须用**独立 data-dir + 独立端口 + 独立 HOME**，与 `8000` 完全隔开。
4. **测试默认不碰 Science。** 能用「代理↔上游」单独验证的，就不启动 Science。只有到最终整链联调、且用户明确同意时，才启动沙箱 Science。
5. **第三方 API Key 通过环境变量注入代理子进程**，**绝不进命令行参数**，避免 `ps` 泄露；不进日志；前端只显示末 4 位。
6. 动任何有状态的东西前，先确认它不在铁律清单里；拿不准就停下来问用户。

### 3.2 关键并发与事务设计（读多文件才能理清）

- **生命周期串行化**：`desktop/src-tauri/src/lifecycle.rs` 提供 `Lifecycle::with_serialized`，所有会改 `AppState` / `config` 的命令（切 profile、改连接、清 key、一键开始、停等）必须经此串行化，防止「读到旧配置 → 起旧代理 → 覆盖新运行态」。
- **三把锁分层**：串行器锁（最外）→ `AppState` 锁（内层，探活期间释放）→ `config::update` 锁（最内层）。`ensure_proxy` / `start_proxy_for` **不**取串行器锁，避免自死锁。
- **Generation token**：清 key / 停 / 切 profile 时 `bump_generation`。`start_proxy_for` 在 spawn 前 capture generation，探活健康回锁后校验 `current_generation()` 是否仍一致；若不一致则杀掉自己刚起的 child、不写回 `st.proxy`，防止旧配置复活。
- **Profile 切换事务**（`set_active_profile_txn`）：scratch 探针校验候选 → 起正式代理并探活 → 健康才 commit `active_id`；失败则 rollback 到旧 active 代理。磁盘 `active_id` 与运行态代理必须一致，杜绝「盘新运行旧」。
- **Agent 复用指纹**：`proxy_fingerprint` 纳入 `template_id`、`api_format`、`adapter`、`base_url`、`model`、`thinking_policy`、`key`，任一语义变化都触发代理重启。
- **Path-secret 持久化**：`config.secret` 一旦生成即落盘复用。因为沙箱把 secret 嵌在 `ANTHROPIC_BASE_URL` 里，代理重启后若 secret 变了，沙箱会拿旧 secret 打新代理 → 全部 403。

### 3.3 资源定位

打包后的 app 通过 `tauri.conf.json` 的 `bundle.resources` 把 `proxy/` 和 `scripts/` 打进资源目录。Rust 后端按以下顺序定位资源根：

1. Tauri resource dir（打包后）。
2. 从可执行文件位置向上回溯到仓库根（开发态，找到 `proxy/csswitch_proxy.py`）。
3. 环境变量 `CSSWITCH_REPO=/path/to/CSSwitch-Linux` 可显式指定。

### 3.4 沙箱启动流程

1. `one_click_login_inner` 先 `ensure_proxy`（复用或重启本地代理）。
2. Rust 原生虚拟 OAuth 写入 `~/.csswitch/sandbox/home/.claude-science`（`oauth_forge.rs`，与 Node `.mjs` 字节兼容）。
3. 调用 `scripts/launch-virtual-sandbox.sh --port <port> --proxy-url http://127.0.0.1:<proxy_port>/<secret> --skip-oauth-forge`。
4. 脚本会：
   - 铁律断言端口不是 8000、data-dir 不在真实 `~/.claude-science` 下。
   - 首次启动时从真实 `~/.claude-science` 复制运行时资产（`bin`、`conda`、`runtime`、`seed-assets`），**不复制登录凭证**；`conda` 目录保留符号链接以避免断链。
   - 设置 `ANTHROPIC_BASE_URL` 指向代理，并通过 `https_proxy` 对 Anthropic 域名做 fast-fail，避免启动时卡在 "Switching organization"。
   - 以 `--detached` 启动 `claude-science serve`。

### 3.5 官方 Claude 模式

`open_official` 直接调用检测到的 `claude-science open`，并显式 `env_remove("ANTHROPIC_BASE_URL")`、`ANTHROPIC_API_KEY`、`ANTHROPIC_AUTH_TOKEN`，确保不影响真实订阅状态。

---

## 4. 目录结构速查

```text
CSSwitch-Linux/
├── desktop/               # Tauri 桌面应用
│   ├── src/               # 前端面板（HTML/CSS/JS，无框架）
│   └── src-tauri/         # Rust 后端
│       ├── src/
│       │   ├── lib.rs     # Tauri command 与进程管家
│       │   ├── config.rs  # ~/.csswitch/config.json 读写（0600、拒 symlink、原子写）
│       │   ├── oauth_forge.rs  # 虚拟 OAuth（Rust 原生，与 Node .mjs 字节兼容）
│       │   ├── proc.rs    # 探活 / which / secret / 上游可达性
│       │   ├── templates.rs    # provider adapter 注册表
│       │   ├── lifecycle.rs    # 代理/沙箱生命周期串行器
│       │   └── scratch.rs # scratch 探针（临时代理校验 key/base_url/模型）
│       ├── tauri.conf.json     # 打包：deb + appimage，资源 proxy/ scripts/
│       └── Cargo.toml
├── proxy/                 # Python 翻译代理（复用上游）
├── scripts/               # 启动/停止/诊断脚本
├── test/                  # 测试套件
├── docs/
│   └── LINUX.md           # Linux 安装与命令行速查
├── findings/              # 本机运行产物（git 忽略）
├── .sandbox/              # 开发态沙箱 HOME（git 忽略）
├── README.md / README.en.md
└── LICENSE
```

---

## 5. 构建与发布

### 5.1 依赖

```bash
sudo apt-get update
sudo apt-get install -y \
  libglib2.0-dev \
  libgtk-3-dev \
  libwebkit2gtk-4.1-dev \
  pkg-config \
  build-essential

# 如需生成 AppImage
sudo apt-get install -y libfuse2
```

还需要：Node.js ≥ 18、npm、Rust（rustup）、Python 3。

### 5.2 开发模式

```bash
cd desktop
npm install
npm run tauri dev
```

开发模式下，Rust 后端直接从项目目录找 `proxy/` 和 `scripts/`；打包后使用 Tauri 资源目录里的副本。

### 5.3 构建发布包

```bash
cd desktop
npm run tauri build
```

产物：

```text
desktop/src-tauri/target/release/bundle/
├── deb/CSSwitch-Linux_0.4.0_amd64.deb
└── appimage/CSSwitch-Linux_0.4.0_amd64.AppImage
```

若只需要 `.deb`，临时修改 `desktop/src-tauri/tauri.conf.json`：

```json
"bundle": {
  "targets": ["deb"]
}
```

---

## 6. 测试

### 6.1 S0 分层验收门

`test/run_all.sh` 汇总 5 层测试：

- `offline`：纯单元，无 loopback / 无网络。
- `loopback`：需 127.0.0.1 bind/connect，含 mock-timing race 有界重试。
- `scripts`：bash 脚本测试、Node OAuth 对拍、运维脚本契约测试。
- `rust`：`cargo fmt --check`、`cargo clippy --all-targets -- -D warnings`、`cargo test`。
- `frontend`：`node --check desktop/src/main.js`。

运行：

```bash
# 本环境无 fail 即可通过
bash test/run_all.sh

# 要求 release-ready：5 层均 pass 且无 env-blocked
bash test/run_all.sh --require-release-ready
```

每层输出形如 `S0_LAYER <name> <status>`，`status` 可为 `pass`、`fail`、`env-blocked`。

### 6.2 单独运行某层

```bash
bash test/run-offline.sh      # Python 代理纯单元测试
bash test/run-loopback.sh     # 需 loopback 的代理测试（含重试）
bash test/run-rust.sh         # fmt + clippy + cargo test
bash test/run-scripts.sh      # 脚本 + Node OAuth 对拍 + ops 测试
bash test/run-frontend.sh     # JS 语法检查
```

### 6.3 单独跑 Rust 测试或 Clippy

```bash
cd desktop/src-tauri

# 仅测试（开发常用）
cargo test

# 带 fmt/clippy（CI/release-ready 用）
cargo fmt --check
cargo clippy --all-targets -- -D warnings
```

注意：`run-rust.sh` 会根据 `python3 test/_capability.py` 判断是否允许 loopback；若 loopback 被禁，会跳过 `scratch.rs` 中的端口 bind 测试（`pick_scratch_port_returns_usable_nonreserved_port`、`two_picks_are_bindable`），其余测试仍跑。

### 6.4 单独跑 Python 代理测试

```bash
cd /mnt/e/mywork/CS_switch_Linux

# 纯单元
python3 -m unittest test.test_proxy_units test.test_provider_policy test.test_anthropic_compat test.test_dsml_shim test.test_capability -v

# 需 loopback
python3 -m unittest test.test_proxy_connect test.test_proxy_stream test.test_proxy_dsml_e2e test.test_proxy_auth test.test_proxy_golden -v
```

### 6.5 实机测试（会启动沙箱 Science，需用户明确同意）

```bash
bash test/real_machine_guard.sh
```

见 `test/REAL_MACHINE_TEST.md`。实机测试会真正启动沙箱 Science，请确保：

- 已配置有效的第三方 API Key；
- 已明确同意启动沙箱；
- 理解铁律：不影响真实 `~/.claude-science` 与端口 `8000`。

---

## 7. 常用命令速查

```bash
# 起代理（命令行调试）
cd /mnt/e/mywork/CS_switch_Linux
DEEPSEEK_API_KEY=your-key python3 proxy/csswitch_proxy.py \
  --provider deepseek --port 18991 --auth-token SECRET

# 起沙箱（命令行调试；app 一键流程会自带 --skip-oauth-forge）
SCIENCE_BIN=/home/muadib/.local/bin/claude-science \
SANDBOX_HOME=/home/muadib/.csswitch/sandbox/home \
bash scripts/launch-virtual-sandbox.sh --port 8990 \
  --proxy-url http://127.0.0.1:18991/SECRET

# 只跑护栏检查，不真起沙箱
bash scripts/launch-virtual-sandbox.sh --port 8990 \
  --proxy-url http://127.0.0.1:18991/SECRET --dry-run

# 停沙箱
bash scripts/stop-science-sandbox.sh

# 诊断
bash scripts/doctor.sh

# 验证运行中代理（零上游花费）
bash scripts/verify-proxy.sh http://127.0.0.1:18991/SECRET

# 启动桌面开发模式
cd desktop
npm run tauri dev

# 打包
cd desktop
npm run tauri build
```

---

## 8. 已知问题与决策记录

### 8.1 conda 断链导致沙箱首次启动失败

- **现象**：`cp: 对 '.../ar' 调用 stat 失败: 没有那个文件或目录`
- **原因**：`scripts/launch-virtual-sandbox.sh` 用 `cp -rL` 复制 `~/.claude-science/conda/`，但 conda 的 gcc 包里存在断链。
- **修复**：`conda` 目录改用 `cp -r` 保留符号链接；`bin` / `runtime` / `seed-assets` 仍用 `cp -rL`。
- **文件**：`scripts/launch-virtual-sandbox.sh`

### 8.2 AppImage 打包需要 libfuse2

- **现象**：`failed to bundle project: failed to run linuxdeploy`
- **解决**：`sudo apt-get install libfuse2`

### 8.3 WSL2 下窗口不显示

- **解决**：`export DISPLAY=:0` 或 `GDK_BACKEND=x11 csswitch-linux`

### 8.4 代理环境变量

跑 `gh`/`git`/`npm` 前注意大小写代理变量。本仓库主要涉及 Tauri 下载和 AppImage 工具下载，如网络异常，可尝试：

```bash
export HTTPS_PROXY=http://127.0.0.1:7890 HTTP_PROXY=http://127.0.0.1:7890 ALL_PROXY=http://127.0.0.1:7890
```

### 8.5 配置位置

- 运行时配置：`~/.csswitch/config.json`（权限 0600）
- 沙箱数据：`~/.csswitch/sandbox/home/.claude-science`
- 日志：`~/.csswitch/logs/`

---

## 9. 继续开发时的检查清单

修改前确认：

- [ ] 如果是 `proxy/` 或 `test/*.py` 的改动，先考虑是否应在上游 CSSwitch 修改。
- [ ] 任何涉及 `~/.claude-science` 真实目录的操作，必须只读且谨慎。
- [ ] 新增文件若含潜在敏感信息，同步更新 `.gitignore`。
- [ ] 修改 `README.md` 时同步更新 `README.en.md`。
- [ ] 修改构建配置后，至少跑 `bash test/run_all.sh`。

---

**最后更新**：2026-07-21
