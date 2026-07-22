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
#   PROXY_ARGS     - 额外代理参数（如 --relay-base URL --model NAME），空格分隔
#   以及 key 环境变量（CSSWITCH_RELAY_KEY 等）
set -euo pipefail

PROXY_SCRIPT="${PROXY_SCRIPT:?}"
PROXY_PORT="${PROXY_PORT:?}"
PROXY_SECRET="${PROXY_SECRET:?}"
PROXY_ADAPTER="${PROXY_ADAPTER:?}"
PROXY_LOG="${PROXY_LOG:-/dev/null}"
PROXY_ARGS="${PROXY_ARGS:-}"

# Signal handler: when watchdog is killed (SIGTERM/SIGINT), also kill the proxy.
# Without this, pkill on watchdog leaves the proxy orphaned, and the new watchdog
# immediately starts another proxy on the same port → "Address already in use".
_current_proxy_pid=""
_shutdown() {
    echo "[$(date '+%H:%M:%S')] watchdog 收到信号，正在关闭..." >> "$PROXY_LOG"
    if [[ -n "$_current_proxy_pid" ]] && kill -0 "$_current_proxy_pid" 2>/dev/null; then
        kill "$_current_proxy_pid" 2>/dev/null || true
        # 等 proxy 退出，最多 5 秒
        for _ in $(seq 1 25); do
            if ! kill -0 "$_current_proxy_pid" 2>/dev/null; then break; fi
            sleep 0.2
        done
        # 还没死就 SIGKILL
        kill -0 "$_current_proxy_pid" 2>/dev/null && kill -9 "$_current_proxy_pid" 2>/dev/null || true
    fi
    exit 0
}
trap _shutdown SIGTERM SIGINT SIGHUP

MAX_RETRIES=50          # 最大连续重启次数（防止无限循环）
MAX_PORT_RETRIES=10     # 端口占用最大重试次数
BASE_DELAY=2            # 首次重启等待秒数
MAX_DELAY=60            # 最大退避秒数
STABLE_THRESHOLD=30     # 运行超过此秒数视为稳定，重置退避
QUICK_EXIT=5            # 低于此秒数视为快速退出（可能是端口占用）

retry=0
port_retry=0
delay="$BASE_DELAY"

while (( retry < MAX_RETRIES )); do
  echo "[$(date '+%H:%M:%S')] 代理启动 (attempt=$((retry+1)), adapter=$PROXY_ADAPTER, port=$PROXY_PORT, args=[$PROXY_ARGS])" >> "$PROXY_LOG"

  start_time=$(date +%s)

  # 启动代理（前台运行，捕获退出码）
  # shellcheck disable=SC2086
  python3 "$PROXY_SCRIPT" \
    --provider "$PROXY_ADAPTER" \
    --port "$PROXY_PORT" \
    --auth-token "$PROXY_SECRET" \
    $PROXY_ARGS \
    >> "$PROXY_LOG" 2>&1 &
  proxy_pid=$!
  _current_proxy_pid="$proxy_pid"

  # 等待代理进程退出
  wait "$proxy_pid" 2>/dev/null || true
  exit_code=$?

  end_time=$(date +%s)
  runtime=$((end_time - start_time))

  echo "[$(date '+%H:%M:%S')] 代理退出 (pid=$proxy_pid, exit=$exit_code, runtime=${runtime}s)" >> "$PROXY_LOG"

  # 检查是否被外部 pkill 杀死（SIGTERM=143, SIGKILL=137）
  # 这些情况下不重启（说明是用户主动停止）
  if (( exit_code == 143 || exit_code == 137 )); then
    echo "[$(date '+%H:%M:%S')] 代理被外部信号终止 (exit=$exit_code)，停止保活。" >> "$PROXY_LOG"
    exit 0
  fi

  # 快速退出（<5s）+ exit code 2 = 端口绑定失败
  if (( runtime < QUICK_EXIT && (exit_code == 2 || exit_code == 0) )); then
    port_retry=$((port_retry + 1))
    if (( port_retry >= MAX_PORT_RETRIES )); then
      echo "[$(date '+%H:%M:%S')] 端口绑定失败达 $MAX_PORT_RETRIES 次，停止保活。" >> "$PROXY_LOG"
      exit 1
    fi
    echo "[$(date '+%H:%M:%S')] 疑似端口占用 (exit=$exit_code, runtime=${runtime}s)，尝试清理..." >> "$PROXY_LOG"
    # 尝试杀死占用端口的进程
    pids=$(ss -tlnp "sport = :${PROXY_PORT}" 2>/dev/null | grep -oP 'pid=\K[0-9]+' || true)
    if [[ -n "$pids" ]]; then
      echo "[$(date '+%H:%M:%S')] 杀死端口占用进程: $pids" >> "$PROXY_LOG"
      echo "$pids" | xargs kill -9 2>/dev/null || true
      sleep 1
    fi
    sleep 2
    continue
  fi

  # 正常运行后退出，重置退避
  if (( runtime >= STABLE_THRESHOLD )); then
    retry=0
    port_retry=0
    delay="$BASE_DELAY"
  fi

  retry=$((retry + 1))

  echo "[$(date '+%H:%M:%S')] ${delay}s 后重启..." >> "$PROXY_LOG"
  sleep "$delay"

  # 指数退避
  delay=$((delay * 2))
  (( delay > MAX_DELAY )) && delay="$MAX_DELAY"
done

echo "[$(date '+%H:%M:%S')] 达到最大重试次数 ($MAX_RETRIES)，停止保活。" >> "$PROXY_LOG"
exit 1
