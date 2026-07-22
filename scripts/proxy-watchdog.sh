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
set -euo pipefail

PROXY_SCRIPT="${PROXY_SCRIPT:?}"
PROXY_PORT="${PROXY_PORT:?}"
PROXY_SECRET="${PROXY_SECRET:?}"
PROXY_ADAPTER="${PROXY_ADAPTER:?}"
PROXY_LOG="${PROXY_LOG:-/dev/null}"
PROXY_ARGS="${PROXY_ARGS:-}"

# Lock file: prevents multiple watchdogs on the same port
LOCK_FILE="/tmp/csswitch-watchdog-${PROXY_PORT}.lock"
_cleanup_lock() { rm -f "$LOCK_FILE" 2>/dev/null || true; }

# Check for stale lock
if [[ -f "$LOCK_FILE" ]]; then
    old_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
        echo "[$(date '+%H:%M:%S')] 另一个 watchdog (PID=$old_pid) 已在运行，退出。" >> "$PROXY_LOG"
        exit 0
    fi
    rm -f "$LOCK_FILE" 2>/dev/null || true
fi
echo $$ > "$LOCK_FILE"

# 启动时记录进程信息（用于事后分析谁杀了 watchdog）
echo "[$(date '+%H:%M:%S')] watchdog 启动 (pid=$$, ppid=$PPID, port=$PROXY_PORT, adapter=$PROXY_ADAPTER)" >> "$PROXY_LOG"
echo "[$(date '+%H:%M:%S')] watchdog 进程树: $(ps -o pid,ppid,stat,cmd -p $$ 2>/dev/null | tail -1)" >> "$PROXY_LOG"

# Signal handler
_current_proxy_pid=""
_shutdown() {
    local sig="${1:-unknown}"
    # 尝试获取信号发送者（Linux 特有）
    local sender=""
    if [[ -f /proc/$$/status ]]; then
        sender=$(grep -i "SigQ\|SigPnd\|SigBlk" /proc/$$/status 2>/dev/null | tr '\n' ' ' || true)
    fi
    # 检查谁可能发了信号：查看同进程组的其他进程
    local pgid=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')
    local group_procs=$(ps -o pid,ppid,cmd -g "${pgid:-$$}" 2>/dev/null | head -10 || true)
    echo "[$(date '+%H:%M:%S')] !! watchdog 收到信号 $sig (pid=$$, ppid=$PPID)" >> "$PROXY_LOG"
    echo "[$(date '+%H:%M:%S')] !! 信号详情: $sender" >> "$PROXY_LOG"
    echo "[$(date '+%H:%M:%S')] !! 同进程组: $group_procs" >> "$PROXY_LOG"
    if [[ -n "$_current_proxy_pid" ]] && kill -0 "$_current_proxy_pid" 2>/dev/null; then
        echo "[$(date '+%H:%M:%S')] !! 杀死代理 (pid=$_current_proxy_pid)" >> "$PROXY_LOG"
        kill -9 "$_current_proxy_pid" 2>/dev/null || true
        wait "$_current_proxy_pid" 2>/dev/null || true
    fi
    _cleanup_lock
    exit 0
}
trap '_shutdown SIGTERM' SIGTERM
trap '_shutdown SIGINT' SIGINT
trap '_shutdown SIGHUP' SIGHUP

MAX_RETRIES=50
MAX_PORT_RETRIES=10
BASE_DELAY=2
MAX_DELAY=60
STABLE_THRESHOLD=30
QUICK_EXIT=5
HEARTBEAT_INTERVAL=60  # 每 60 秒记录一次代理存活状态

retry=0
port_retry=0
delay="$BASE_DELAY"

while (( retry < MAX_RETRIES )); do
  echo "[$(date '+%H:%M:%S')] 代理启动 (attempt=$((retry+1)), adapter=$PROXY_ADAPTER, port=$PROXY_PORT, args=[$PROXY_ARGS])" >> "$PROXY_LOG"

  start_time=$(date +%s)

  # 启动代理
  # shellcheck disable=SC2086
  python3 "$PROXY_SCRIPT" \
    --provider "$PROXY_ADAPTER" \
    --port "$PROXY_PORT" \
    --auth-token "$PROXY_SECRET" \
    $PROXY_ARGS \
    >> "$PROXY_LOG" 2>&1 &
  proxy_pid=$!
  _current_proxy_pid="$proxy_pid"
  echo "[$(date '+%H:%M:%S')] 代理进程启动 (pid=$proxy_pid)" >> "$PROXY_LOG"

  # 心跳监控 + 等待退出
  last_heartbeat=$start_time
  while kill -0 "$proxy_pid" 2>/dev/null; do
    sleep 1
    now=$(date +%s)
    if (( now - last_heartbeat >= HEARTBEAT_INTERVAL )); then
      echo "[$(date '+%H:%M:%S')] 代理心跳 (pid=$proxy_pid, runtime=$((now - start_time))s)" >> "$PROXY_LOG"
      last_heartbeat=$now
    fi
  done

  wait "$proxy_pid" 2>/dev/null || true
  exit_code=$?

  end_time=$(date +%s)
  runtime=$((end_time - start_time))

  # 详细的退出分析
  signal_name=""
  if (( exit_code >= 128 )); then
    sig_num=$((exit_code - 128))
    case $sig_num in
      1) signal_name="SIGHUP" ;;
      2) signal_name="SIGINT" ;;
      3) signal_name="SIGQUIT" ;;
      6) signal_name="SIGABRT" ;;
      9) signal_name="SIGKILL" ;;
      11) signal_name="SIGSEGV" ;;
      13) signal_name="SIGPIPE" ;;
      14) signal_name="SIGALRM" ;;
      15) signal_name="SIGTERM" ;;
      *) signal_name="SIG$sig_num" ;;
    esac
  fi

  echo "[$(date '+%H:%M:%S')] 代理退出 (pid=$proxy_pid, exit=$exit_code, signal=$signal_name, runtime=${runtime}s)" >> "$PROXY_LOG"

  # 检查代理进程的退出原因（如果可能）
  if [[ -f /proc/$proxy_pid/status ]]; then
    echo "[$(date '+%H:%M:%S')] 代理退出时状态: $(grep -E 'State|SigPnd|SigBlk' /proc/$proxy_pid/status 2>/dev/null | tr '\n' ' ')" >> "$PROXY_LOG"
  fi

  # SIGTERM/SIGKILL = 外部主动停止
  if (( exit_code == 143 || exit_code == 137 )); then
    _cleanup_lock
    echo "[$(date '+%H:%M:%S')] 代理被外部信号终止 (exit=$exit_code, signal=$signal_name)，停止保活。" >> "$PROXY_LOG"
    exit 0
  fi

  # 快速退出 = 端口绑定失败
  if (( runtime < QUICK_EXIT && (exit_code == 2 || exit_code == 0) )); then
    port_retry=$((port_retry + 1))
    if (( port_retry >= MAX_PORT_RETRIES )); then
      _cleanup_lock
      echo "[$(date '+%H:%M:%S')] 端口绑定失败达 $MAX_PORT_RETRIES 次，停止保活。" >> "$PROXY_LOG"
      exit 1
    fi
    echo "[$(date '+%H:%M:%S')] 疑似端口占用 (exit=$exit_code, runtime=${runtime}s)，尝试清理..." >> "$PROXY_LOG"
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
  delay=$((delay * 2))
  (( delay > MAX_DELAY )) && delay="$MAX_DELAY"
done

_cleanup_lock
echo "[$(date '+%H:%M:%S')] 达到最大重试次数 ($MAX_RETRIES)，停止保活。" >> "$PROXY_LOG"
exit 1
