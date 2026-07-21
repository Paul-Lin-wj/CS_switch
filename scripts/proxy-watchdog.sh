#!/usr/bin/env bash
# CSSwitch 代理保活包装脚本。
# 在循环中启动代理，进程退出后自动重启（带退避），记录每次重启。
# 用法：由 csswitch-cli.sh 的 do_start 调用，不直接运行。
#
# 环境变量（由调用方设置）：
#   PROXY_SCRIPT   - proxy/csswitch_proxy.py 路径
#   PROXY_PORT     - 代理端口
#   PROXY_SECRET   - path-secret
#   PROXY_ADAPTER  - adapter 名（relay/deepseek/qwen/...）
#   PROXY_LOG      - 日志文件路径
#   以及 key 环境变量（CSSWITCH_RELAY_KEY 等）
set -euo pipefail

PROXY_SCRIPT="${PROXY_SCRIPT:?}"
PROXY_PORT="${PROXY_PORT:?}"
PROXY_SECRET="${PROXY_SECRET:?}"
PROXY_ADAPTER="${PROXY_ADAPTER:?}"
PROXY_LOG="${PROXY_LOG:-/dev/null}"

MAX_RETRIES=50          # 最大连续重启次数（防止无限循环）
BASE_DELAY=2            # 首次重启等待秒数
MAX_DELAY=60            # 最大退避秒数
STABLE_THRESHOLD=30     # 运行超过此秒数视为稳定，重置退避

retry=0
delay="$BASE_DELAY"

while (( retry < MAX_RETRIES )); do
  echo "[$(date '+%H:%M:%S')] 代理启动 (attempt=$((retry+1)), adapter=$PROXY_ADAPTER, port=$PROXY_PORT)" >> "$PROXY_LOG"

  start_time=$(date +%s)

  # 启动代理（前台运行，捕获退出码）
  python3 "$PROXY_SCRIPT" \
    --provider "$PROXY_ADAPTER" \
    --port "$PROXY_PORT" \
    --auth-token "$PROXY_SECRET" \
    >> "$PROXY_LOG" 2>&1 &
  proxy_pid=$!

  # 等待代理进程退出
  wait "$proxy_pid" 2>/dev/null || true
  exit_code=$?

  end_time=$(date +%s)
  runtime=$((end_time - start_time))

  echo "[$(date '+%H:%M:%S')] 代理退出 (pid=$proxy_pid, exit=$exit_code, runtime=${runtime}s)" >> "$PROXY_LOG"

  # 如果运行时间超过阈值，说明是稳定运行后退出，重置退避
  if (( runtime >= STABLE_THRESHOLD )); then
    retry=0
    delay="$BASE_DELAY"
  else
    retry=$((retry + 1))
  fi

  # 检查是否被外部 pkill 杀死（SIGTERM=143, SIGKILL=137）
  # 这些情况下不重启（说明是用户主动停止）
  if (( exit_code == 143 || exit_code == 137 )); then
    echo "[$(date '+%H:%M:%S')] 代理被外部信号终止 (exit=$exit_code)，停止保活。" >> "$PROXY_LOG"
    exit 0
  fi

  echo "[$(date '+%H:%M:%S')] ${delay}s 后重启..." >> "$PROXY_LOG"
  sleep "$delay"

  # 指数退避
  delay=$((delay * 2))
  (( delay > MAX_DELAY )) && delay="$MAX_DELAY"
done

echo "[$(date '+%H:%M:%S')] 达到最大重试次数 ($MAX_RETRIES)，停止保活。" >> "$PROXY_LOG"
exit 1
