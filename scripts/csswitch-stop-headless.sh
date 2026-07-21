#!/usr/bin/env bash
# CSSwitch 无 GUI 停止脚本（配合 csswitch-start-headless.sh 使用）。
set -euo pipefail

if [[ -n "${CSSWITCH_REPO:-}" ]]; then
  :
else
  CSSWITCH_REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
fi
LOG_DIR="$HOME/.csswitch/logs"
SANDBOX_HOME="$HOME/.csswitch/sandbox/home"
SCIENCE_BIN="${SCIENCE_BIN:-$HOME/.local/bin/claude-science}"

echo "=== 停止 CSSwitch ==="

# 停止沙箱
SCIENCE_BIN="$SCIENCE_BIN" \
SANDBOX_HOME="$SANDBOX_HOME" \
bash "$CSSWITCH_REPO/scripts/stop-science-sandbox.sh" || true

# 停止代理
if [[ -f "$LOG_DIR/proxy.pid" ]]; then
  PROXY_PID="$(cat "$LOG_DIR/proxy.pid")"
  if kill -0 "$PROXY_PID" 2>/dev/null; then
    kill "$PROXY_PID"
    echo "代理进程 $PROXY_PID 已停止"
  fi
  rm -f "$LOG_DIR/proxy.pid"
fi

# 兜底清理
pkill -f "csswitch_proxy.py" >/dev/null 2>&1 || true

echo "已清理完成。真实 Science 实例（端口 8000）不受影响。"
