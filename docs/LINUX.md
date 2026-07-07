# CSSwitch-Linux 安装与运行

## 依赖

- Linux（已验证 x86_64 / WSL2）
- `python3`（代理需要）
- `claude-science` 二进制在 `~/.local/bin/claude-science` 或在 `PATH` 中
- 构建桌面 app 需要：Node.js、Rust、webkit2gtk（Debian/Ubuntu: `libwebkit2gtk-4.1-dev`）

## 开发运行

```bash
cd desktop
npm install
npm run tauri dev
```

## 仅运行代理（不启动 GUI）

```bash
CSSWITCH_RELAY_BASE_URL=https://api.kimi.com/coding/ \
CSSWITCH_RELAY_KEY=your-key \
CSSWITCH_RELAY_MODEL=your-model \
python3 proxy/csswitch_proxy.py --provider relay --port 18991
```

## 一键启动沙箱（命令行）

```bash
# 1. 起代理
python3 proxy/csswitch_proxy.py --provider relay --port 18991 --auth-token SECRET &

# 2. 起沙箱
SCIENCE_BIN=/home/muadib/.local/bin/claude-science \
SANDBOX_HOME=/home/muadib/.csswitch/sandbox/home \
bash scripts/launch-virtual-sandbox.sh --port 8990 \
  --proxy-url http://127.0.0.1:18991/SECRET

# 3. 停止
bash scripts/stop-science-sandbox.sh
```

## 注意事项

- 真实 Science 实例默认端口为 `8000`，CSSwitch 不会占用该端口。
- 沙箱使用独立的 `HOME` 和 `data-dir`（`~/.csswitch/sandbox/home`），不影响真实 `~/.claude-science`。
