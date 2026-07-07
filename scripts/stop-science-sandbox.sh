#!/usr/bin/env bash
# 停止隔离沙箱 Science（只停沙箱 data-dir 的守护进程，绝不影响真实实例 8000）。
set -euo pipefail
PROJ="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
SANDBOX_HOME="${SANDBOX_HOME:-$PROJ/.sandbox/home}"
DATA_DIR="$SANDBOX_HOME/.claude-science"
# 优先级：显式 SCIENCE_BIN > 沙箱内已克隆 runtime > 用户家目录默认 binary。
if [ -n "${SCIENCE_BIN:-}" ]; then
  BIN="$SCIENCE_BIN"
elif [ -x "$DATA_DIR/bin/claude-science" ]; then
  BIN="$DATA_DIR/bin/claude-science"
else
  BIN="${HOME}/.local/bin/claude-science"
fi

if [[ ! -d "$DATA_DIR" ]]; then echo "沙箱不存在，无需停止。"; exit 0; fi

if HOME="$SANDBOX_HOME" "$BIN" stop --data-dir "$DATA_DIR" 2>&1 | tail -2; then
  echo "沙箱已停。真实实例 8000 未受影响。"
else
  rc=${PIPESTATUS[0]}
  echo "停止失败（退出码 $rc）。真实实例 8000 未受影响。" >&2
  exit "$rc"
fi
