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
- `test/test_ops_scripts.sh`
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
│       │   ├── lifecycle.rs    # 代理/沙箱生命周期
│       │   └── scratch.rs
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

还需要：Node.js ≥ 18、npm、Rust（rustup）。

### 5.2 构建发布包

```bash
cd desktop
npm install
npm run tauri build
```

产物：

```text
desktop/src-tauri/target/release/bundle/
├── deb/CSSwitch-Linux_0.4.0_amd64.deb
└── appimage/CSSwitch-Linux_0.4.0_amd64.AppImage
```

### 5.3 开发模式

```bash
cd desktop
npm run tauri dev
```

### 5.4 测试

```bash
# 离线回归套件
bash test/run_all.sh

# Rust 单元测试
cd desktop/src-tauri && cargo test

# 实机测试（会启动沙箱 Science，需用户明确同意）
bash test/real_machine_guard.sh
```

---

## 6. 安装方式

### 6.1 系统级安装

```bash
sudo dpkg -i CSSwitch-Linux_0.4.0_amd64.deb
sudo apt-get install -f
csswitch-linux
```

### 6.2 用户级安装（无需 sudo）

```bash
mkdir -p ~/.local/share/CSSwitch-Linux ~/.local/bin
dpkg -x CSSwitch-Linux_0.4.0_amd64.deb ~/.local/share/CSSwitch-Linux
ln -sf ~/.local/share/CSSwitch-Linux/usr/bin/csswitch-linux ~/.local/bin/csswitch-linux
~/.local/bin/csswitch-linux
```

---

## 7. 已知问题与决策记录

### 7.1 conda 断链导致沙箱首次启动失败

- **现象**：`cp: 对 '.../ar' 调用 stat 失败: 没有那个文件或目录`
- **原因**：`scripts/launch-virtual-sandbox.sh` 用 `cp -rL` 复制 `~/.claude-science/conda/`，但 conda 的 gcc 包里存在断链。
- **修复**：`conda` 目录改用 `cp -r` 保留符号链接；`bin` / `runtime` / `seed-assets` 仍用 `cp -rL`。
- **文件**：`scripts/launch-virtual-sandbox.sh`

### 7.2 AppImage 打包需要 libfuse2

- **现象**：`failed to bundle project: failed to run linuxdeploy`
- **解决**：`sudo apt-get install libfuse2`

### 7.3 WSL2 下窗口不显示

- **解决**：`export DISPLAY=:0` 或 `GDK_BACKEND=x11 csswitch-linux`

### 7.4 代理环境变量

跑 `gh`/`git`/`npm` 前注意大小写代理变量。本仓库主要涉及 Tauri 下载和 AppImage 工具下载，如网络异常，可尝试：

```bash
export HTTPS_PROXY=http://127.0.0.1:7890 HTTP_PROXY=http://127.0.0.1:7890 ALL_PROXY=http://127.0.0.1:7890
```

### 7.5 配置位置

- 运行时配置：`~/.csswitch/config.json`（权限 0600）
- 沙箱数据：`~/.csswitch/sandbox/home/.claude-science`
- 日志：`~/.csswitch/logs/`

---

## 8. .gitignore 重点

已配置防止私人信息入库：

- `~` 相关本地数据：`.csswitch/`、`.claude-science/`、`.key-backups/`、`.oauth-tokens`、`encryption.key`、`active-org.json`
- 密钥：`.env`、`.env.*`、`*.pem`、`*.key`、`*.crt`、`*.cer`、`*secret*`、`*token*`
- 运行产物：`.sandbox/`、`target/`、`node_modules/`、`*.pyc`、`.pytest_cache/`
- 本地工作区：`.superpowers/`、`findings/auto-maint/*`、`.claude/`、`scratchpad/`

---

## 9. 继续开发时的检查清单

修改前确认：

- [ ] 如果是 `proxy/` 或 `test/*.py` 的改动，先考虑是否应在上游 CSSwitch 修改。
- [ ] 任何涉及 `~/.claude-science` 真实目录的操作，必须只读且谨慎。
- [ ] 新增文件若含潜在敏感信息，同步更新 `.gitignore`。
- [ ] 修改 `README.md` 时同步更新 `README.en.md`。
- [ ] 修改构建配置后，至少跑 `cargo test` 和 `bash test/run_all.sh`。

---

## 10. 常用命令速查

```bash
# 起代理
cd /mnt/e/mywork/CSSwitch-Linux
python3 proxy/csswitch_proxy.py --provider deepseek --port 18991 --auth-token SECRET

# 起沙箱
SCIENCE_BIN=/home/muadib/.local/bin/claude-science \
SANDBOX_HOME=/home/muadib/.csswitch/sandbox/home \
bash scripts/launch-virtual-sandbox.sh --port 8990 \
  --proxy-url http://127.0.0.1:18991/SECRET

# 停沙箱
bash scripts/stop-science-sandbox.sh

# 诊断
bash scripts/doctor.sh

# 验证代理
bash scripts/verify-proxy.sh http://127.0.0.1:18991/SECRET

# 启动桌面
cd desktop
npm run tauri dev

# 打包
cd desktop
npm run tauri build
```

---

**最后更新**：2026-07-07
