#!/usr/bin/env bash
# CSSwitch 无 GUI 一键启动脚本（非交互式）。
# 用法：先编辑 ~/.csswitch/.env 填入真实 key，然后运行本脚本。
# 交互式用户请改用 scripts/csswitch-cli.sh。
set -euo pipefail

if [[ -n "${CSSWITCH_REPO:-}" ]]; then
  :
else
  CSSWITCH_REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
fi
ENV_FILE="$HOME/.csswitch/.env"
LOG_DIR="$HOME/.csswitch/logs"
mkdir -p "$LOG_DIR"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "错误：缺少配置文件 $ENV_FILE"
  echo "请先创建并填入 provider API key。"
  exit 1
fi

# 导出 .env 中所有变量
set -a
source "$ENV_FILE"
set +a

PROVIDER="${CSSWITCH_PROVIDER:-deepseek}"
PROXY_PORT="${CSSWITCH_PROXY_PORT:-18991}"
SANDBOX_PORT="${CSSWITCH_SANDBOX_PORT:-8990}"
CONTENT_PORT=$((SANDBOX_PORT + 1))

# 校验 provider 对应的 key 是否已设置
case "$PROVIDER" in
  deepseek)            KEY_VAR=DEEPSEEK_API_KEY ;;
  qwen)                KEY_VAR=DASHSCOPE_API_KEY ;;
  openai-custom|openai-responses) KEY_VAR=CSSWITCH_OPENAI_KEY ;;
  relay)               KEY_VAR=CSSWITCH_RELAY_KEY ;;
  *) echo "错误：未知 provider '$PROVIDER'"; exit 1 ;;
esac

if [[ -z "${!KEY_VAR:-}" || "${!KEY_VAR}" == "your-*-key-here" ]]; then
  echo "错误：$KEY_VAR 未在 $ENV_FILE 中设置或仍是占位符"
  exit 1
fi

SANDBOX_HOME="$HOME/.csswitch/sandbox/home"
DATA_DIR="$SANDBOX_HOME/.claude-science"
SCIENCE_BIN="${SCIENCE_BIN:-$HOME/.local/bin/claude-science}"

if [[ ! -x "$SCIENCE_BIN" ]]; then
  echo "错误：找不到 Science 二进制 $SCIENCE_BIN"
  exit 1
fi

# 生成或复用 auth-token（写入文件，供停止脚本和健康检查使用）
SECRET_FILE="$LOG_DIR/headless.secret"
if [[ -f "$SECRET_FILE" ]]; then
  SECRET="$(cat "$SECRET_FILE")"
else
  SECRET="$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")"
  echo "$SECRET" > "$SECRET_FILE"
  chmod 600 "$SECRET_FILE"
fi

# 组装代理启动参数
MULTI_CONFIG_FILE=""
if [[ "${CSSWITCH_MULTI:-0}" == "1" && -n "${CSSWITCH_ACTIVE_PROVIDERS:-}" ]]; then
  # Multi-provider mode: generate config from config helper
  CONFIG_FILE="${CSSWITCH_CONFIG:-$HOME/.csswitch/config.json}"
  MULTI_CONFIG_FILE="$LOG_DIR/multi-config.json"
  CSSWITCH_CONFIG="$CONFIG_FILE" python3 "$CSSWITCH_REPO/scripts/csswitch_config_helper.py" multi-config > "$MULTI_CONFIG_FILE"
  PROXY_ARGS=(--multi-config "$MULTI_CONFIG_FILE" --port "$PROXY_PORT")
  # Export all provider keys from multi-config
  eval "$(python3 -c "
import json
mc = json.load(open('$MULTI_CONFIG_FILE'))
for p in mc.get('providers', []):
    ke, ak = p.get('key_env',''), p.get('api_key','')
    if ke and ak: print(f'export {ke}="{ak}"')
")"
else
  PROXY_ARGS=(
    --provider "$PROVIDER"
    --port "$PROXY_PORT"
  )
  if [[ "$PROVIDER" == "openai-custom" || "$PROVIDER" == "openai-responses" ]] && [[ -n "${CSSWITCH_OPENAI_BASE_URL:-}" ]]; then
    PROXY_ARGS+=(--openai-base "$CSSWITCH_OPENAI_BASE_URL")
  fi
  if [[ "$PROVIDER" == "relay" ]] && [[ -n "${CSSWITCH_RELAY_BASE_URL:-}" ]]; then
    PROXY_ARGS+=(--relay-base "$CSSWITCH_RELAY_BASE_URL")
  fi
fi

echo "=== CSSwitch headless 启动 ==="
echo "provider : $PROVIDER"
echo "proxy    : 127.0.0.1:$PROXY_PORT (auth-token enabled)"
echo "sandbox  : 127.0.0.1:$SANDBOX_PORT (content port $CONTENT_PORT)"
echo "停止脚本 : $CSSWITCH_REPO/scripts/csswitch-stop-headless.sh"
echo ""

# 清理旧进程
"$CSSWITCH_REPO/scripts/stop-science-sandbox.sh" >/dev/null 2>&1 || true
pkill -f "csswitch_proxy.py" >/dev/null 2>&1 || true
sleep 0.5

# 启动代理（key 通过环境变量注入，不进入 ps 命令行）
echo "[1/2] 启动代理 ..."
export "$KEY_VAR"="${!KEY_VAR}"
python3 "$CSSWITCH_REPO/proxy/csswitch_proxy.py" "${PROXY_ARGS[@]}" --auth-token "$SECRET" > "$LOG_DIR/proxy.log" 2>&1 &
PROXY_PID=$!
echo "$PROXY_PID" > "$LOG_DIR/proxy.pid"

# 等待代理就绪
for i in $(seq 1 30); do
  if curl -sS "http://127.0.0.1:$PROXY_PORT/$SECRET/health" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$PROXY_PID" 2>/dev/null; then
    echo "代理进程意外退出，日志："
    tail -n 20 "$LOG_DIR/proxy.log"
    exit 1
  fi
  sleep 0.2
done

# 启动沙箱
# claude-science 调用 micromamba 时带 --no-rc，会忽略 .condarc；
# 因此不能 export MAMBARC/CONDARC（与 --no-rc 冲突会 Abort）。
# 我们用 conda/bin/micromamba wrapper 把 -c conda-forge 翻译成清华镜像 URL，
# 并用 CONDA_CHANNELS 兜底无 -c 的场景。
export CONDA_CHANNELS="https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud/conda-forge,https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud/bioconda,https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/main"

# 默认沙箱代理会阻止 mirrors.tuna.tsinghua.edu.cn，导致 MCP 环境无法下载包；
# --no-sandbox 解除网络限制。data-dir/HOME 仍是隔离的，真实实例 8000 不受影响。
echo "[2/2] 启动隔离沙箱 Science（--no-sandbox 以允许镜像站下载）..."
SCIENCE_BIN="$SCIENCE_BIN" \
SANDBOX_HOME="$SANDBOX_HOME" \
bash "$CSSWITCH_REPO/scripts/launch-virtual-sandbox.sh" \
  --port "$SANDBOX_PORT" \
  --proxy-url "http://127.0.0.1:$PROXY_PORT/$SECRET" \
  --no-sandbox

# 获取访问信息
echo ""
echo "=== 启动完成 ==="
echo "沙箱状态："
HOME="$SANDBOX_HOME" "$SCIENCE_BIN" status --data-dir "$DATA_DIR" || true

echo ""
echo "本地访问："
echo "  主界面 : http://127.0.0.1:$SANDBOX_PORT"
echo "  内容页 : http://127.0.0.1:$CONTENT_PORT"
echo ""
echo "通过 SSH 从本地电脑远程访问（在你的电脑上执行）："
REMOTE_IP="$(hostname -I | awk '{print $1}')"
echo "  ssh -L ${SANDBOX_PORT}:localhost:${SANDBOX_PORT} -L ${CONTENT_PORT}:localhost:${CONTENT_PORT} $(whoami)@${REMOTE_IP}"
echo ""
echo "然后在本机浏览器打开："
echo "  http://localhost:${SANDBOX_PORT}"
echo ""
echo "一次性登录链接："
HOME="$SANDBOX_HOME" "$SCIENCE_BIN" url --data-dir "$DATA_DIR" || true
