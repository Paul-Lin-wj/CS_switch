#!/usr/bin/env bash
# CSSwitch-Linux interactive CLI.
# Supports dialog/whiptail; falls back to a plain text menu.
set -euo pipefail

# Resource root: explicit CSSWITCH_REPO wins, then derive from script location.
if [[ -n "${CSSWITCH_REPO:-}" ]]; then
  PROJ="$CSSWITCH_REPO"
else
  PROJ="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
fi
HELPER="$PROJ/scripts/csswitch_config_helper.py"
LAUNCH="$PROJ/scripts/launch-virtual-sandbox.sh"
STOP="$PROJ/scripts/stop-science-sandbox.sh"
DOCTOR="$PROJ/scripts/doctor.sh"
WATCHDOG="$PROJ/scripts/proxy-watchdog.sh"

CSSWITCH_DIR="${CSSWITCH_DIR:-$HOME/.csswitch}"
SANDBOX_HOME="${SANDBOX_HOME:-$CSSWITCH_DIR/sandbox/home}"
DATA_DIR="$SANDBOX_HOME/.claude-science"

# Detect UI tool: prefer dialog, then whiptail, then text.
# Environment override (e.g. CSSWITCH_UI=text) for non-interactive/testing use.
# Only use TUI when stdin is a terminal (piped input would crash whiptail/dialog).
UI_TOOL=""
if [[ -n "${CSSWITCH_UI:-}" ]]; then
  case "$CSSWITCH_UI" in
    text) UI_TOOL="" ;;
    dialog|whiptail) UI_TOOL="$CSSWITCH_UI" ;;
    *) echo "未知 CSSWITCH_UI: $CSSWITCH_UI，使用自动检测。" &>2 ;;
  esac
elif [[ -t 0 ]] && command -v dialog &>/dev/null; then
  UI_TOOL="dialog"
elif [[ -t 0 ]] && command -v whiptail &>/dev/null; then
  UI_TOOL="whiptail"
fi

# ---------- helpers ----------
ensure_helper() {
  if [[ ! -x "$HELPER" ]]; then
    echo "ERROR: config helper not found or not executable: $HELPER" >&2
    exit 1
  fi
}

msg() {
  echo "[csswitch-cli] $*"
}

err() {
  echo "ERROR: $*" >&2
}

run_helper() {
  ensure_helper
  CSSWITCH_CONFIG="$CSSWITCH_DIR/config.json" python3 "$HELPER" "$@"
}

# Plain text menu.
text_menu() {
  while true; do
    echo
    echo "=== CSSwitch-Linux CLI ==="
    echo "1) 启动 CSSwitch（代理 + 沙箱）"
    echo "2) 多 provider 启动（从 Claude Code settings.json 导入）"
    echo "3) 停止 CSSwitch"
    echo "4) 查看运行状态"
    echo "5) 切换 API 服务商 / profile"
    echo "6) 添加新的 API 提供商"
    echo "7) 编辑 provider 配置"
    echo "8) 删除 provider"
    echo "9) 输出登录链接"
    echo "10) 初始化 CSSwitch 目录"
    echo "11) 运行诊断"
    echo "0) 退出"
    echo -n "请选择: "
    if ! read -r choice; then
      echo
      echo "再见。"
      exit 0
    fi
    case "$choice" in
      1) do_start ;;
      2) do_start_multi ;;
      3) do_stop ;;
      4) do_status ;;
      5) do_switch ;;
      6) do_add ;;
      7) do_edit ;;
      8) do_delete ;;
      9) do_login_url ;;
      10) do_init ;;
      11) do_doctor ;;
      0) echo "再见。"; exit 0 ;;
      *) echo "无效选项，请重新选择。" ;;
    esac
  done
}

find_science_bin() {
  if [[ -n "${SCIENCE_BIN:-}" ]]; then
    echo "$SCIENCE_BIN"
    return 0
  fi
  local candidates=(
    "$DATA_DIR/bin/claude-science"
    "$HOME/.local/bin/claude-science"
    "/usr/bin/claude-science"
    "/usr/local/bin/claude-science"
    "/opt/claude-science/claude-science"
  )
  for c in "${candidates[@]}"; do
    if [[ -x "$c" ]]; then
      echo "$c"
      return 0
    fi
  done
  if command -v claude-science &>/dev/null; then
    echo "$(command -v claude-science)"
    return 0
  fi
  return 1
}

proxy_health() {
  local cfg port secret
  cfg=$(run_helper load)
  port=$(echo "$cfg" | python3 -c "import sys,json; print(json.load(sys.stdin)['proxy_port'])")
  secret=$(echo "$cfg" | python3 -c "import sys,json; print(json.load(sys.stdin).get('secret',''))")
  if [[ -z "$secret" ]]; then
    return 1
  fi
  curl -fsS -m 1 "http://127.0.0.1:$port/$secret/health" &>/dev/null
}

sandbox_running() {
  local bin
  bin=$(find_science_bin) || return 1
  HOME="$SANDBOX_HOME" "$bin" status --data-dir "$DATA_DIR" 2>/dev/null | grep -q '"running": *true'
}

# Import API configs from Claude Code settings.json files into CSSwitch profiles.
# Reads ~/.claude/settings.json, settings.json.kimi, settings.json.bak etc.
do_import_settings() {
  local claude_dir="$HOME/.claude"
  if [[ ! -d "$claude_dir" ]]; then
    err "未找到 $claude_dir 目录"
    return 1
  fi

  local imported=0
  local profile_ids=()

  # Scan all settings.json* files
  for f in "$claude_dir"/settings.json "$claude_dir"/settings.json.*; do
    [[ -f "$f" ]] || continue
    [[ -s "$f" ]] || continue
    [[ "$f" == *.bak ]] && continue

    # Extract provider info from the settings file
    local info
    info=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    env = d.get('env', {})
    base_url = env.get('ANTHROPIC_BASE_URL', '')
    token = env.get('ANTHROPIC_AUTH_TOKEN', '')
    model = env.get('ANTHROPIC_MODEL', '')
    if not base_url or not token:
        sys.exit(1)
    # Determine template based on URL
    if 'kimi' in base_url.lower() or 'moonshot' in base_url.lower():
        tpl = 'kimi'
    elif 'bigmodel' in base_url.lower() or 'zhipu' in base_url.lower() or 'glm' in base_url.lower():
        sys.exit(1)  # skip GLM
    elif 'xiaomimimo' in base_url.lower() or 'mimo' in base_url.lower():
        tpl = 'relay'
    elif 'deepseek' in base_url.lower():
        tpl = 'deepseek'
    elif 'dashscope' in base_url.lower() or 'qwen' in base_url.lower():
        tpl = 'qwen'
    elif 'minimax' in base_url.lower():
        tpl = 'minimax'
    elif 'openrouter' in base_url.lower():
        tpl = 'openrouter'
    else:
        tpl = 'relay'
    # Derive a name from filename
    fname = sys.argv[1].split('/')[-1]
    name = fname.replace('settings.json', '').strip('.') or 'default'
    print(json.dumps({'name': name, 'template_id': tpl, 'base_url': base_url,
                       'api_key': token, 'model': model}))
except Exception as e:
    sys.exit(1)
" "$f" 2>/dev/null) || continue

    local name tpl_id base_url api_key model
    name=$(echo "$info" | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])")
    tpl_id=$(echo "$info" | python3 -c "import sys,json; print(json.load(sys.stdin)['template_id'])")
    base_url=$(echo "$info" | python3 -c "import sys,json; print(json.load(sys.stdin)['base_url'])")
    api_key=$(echo "$info" | python3 -c "import sys,json; print(json.load(sys.stdin)['api_key'])")
    model=$(echo "$info" | python3 -c "import sys,json; print(json.load(sys.stdin)['model'])")

    # Check if this profile already exists (by name)
    local existing
    existing=$(run_helper list 2>/dev/null | python3 -c "
import sys, json
try:
    profiles = json.load(sys.stdin)
    for p in profiles:
        if p['name'] == sys.argv[1]:
            print(p['id']); break
    else:
        print('')
except: print('')
" "$name" 2>/dev/null)

    if [[ -n "$existing" ]]; then
      profile_ids+=("$existing")
      msg "已存在: $name ($tpl_id) — 跳过"
    else
      local add_args=(--template "$tpl_id" --name "$name" --key "$api_key")
      [[ -n "$base_url" && "$tpl_id" == "relay" ]] && add_args+=(--base-url "$base_url")
      [[ -n "$model" ]] && add_args+=(--model "$model")
      local result
      result=$(run_helper add "${add_args[@]}" 2>/dev/null)
      local pid
      pid=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
      if [[ -n "$pid" ]]; then
        profile_ids+=("$pid")
        msg "已导入: $name ($tpl_id) ← $f"
        imported=$((imported + 1))
      else
        err "导入失败: $f"
      fi
    fi
  done

  if [[ ${#profile_ids[@]} -lt 2 ]]; then
    err "至少需要 2 个不同的 provider 才能使用多 provider 模式（当前 ${#profile_ids[@]} 个）"
    return 1
  fi

  # Set active providers
  local ids_csv
  ids_csv=$(IFS=,; echo "${profile_ids[*]}")
  run_helper set-active-providers "$ids_csv" >/dev/null
  msg "已激活 ${#profile_ids[@]} 个 provider，模式切换为 multi"
  return 0
}


do_start() {
  local cfg proxy_port sandbox_port secret
  cfg=$(run_helper load)
  proxy_port=$(echo "$cfg" | python3 -c "import sys,json; print(json.load(sys.stdin)['proxy_port'])")
  sandbox_port=$(echo "$cfg" | python3 -c "import sys,json; print(json.load(sys.stdin)['sandbox_port'])")
  secret=$(echo "$cfg" | python3 -c "import sys,json; print(json.load(sys.stdin).get('secret',''))")

  if ! [[ "$proxy_port" =~ ^[0-9]+$ ]] || ! [[ "$sandbox_port" =~ ^[0-9]+$ ]]; then
    err "端口配置无效，必须为整数。"
    return
  fi
  if (( proxy_port == 8000 || sandbox_port == 8000 )); then
    err "端口 8000 是真实 Science 保留端口，请在配置中修改。"
    return
  fi
  if (( proxy_port == sandbox_port )); then
    err "代理端口与沙箱端口不能相同。"
    return
  fi

  local active
  active=$(run_helper active 2>/dev/null || echo "")
  if [[ -z "$active" || "$active" == *"error"* ]]; then
    err "没有生效的 provider，请先添加或切换。"
    return
  fi

  local template_id key key_env adapter base_url model
  template_id=$(echo "$active" | python3 -c "import sys,json; print(json.load(sys.stdin)['template_id'])")
  key=$(echo "$active" | python3 -c "import sys,json; print(json.load(sys.stdin).get('api_key',''))")
  base_url=$(echo "$active" | python3 -c "import sys,json; print(json.load(sys.stdin).get('base_url',''))")
  model=$(echo "$active" | python3 -c "import sys,json; print(json.load(sys.stdin).get('model',''))")

  if [[ -z "$key" ]]; then
    err "生效 profile 缺少 API Key，请先编辑。"
    return
  fi

  # Determine adapter and key env from template registry (single read, safe quoting).
  local adapter key_env base_editable requires_model
  local tpl_json
  tpl_json=$(run_helper templates | python3 -c "
import sys, json, json as j
tid = j.dumps(sys.argv[1])
tpls = json.load(sys.stdin)
t = next(x for x in tpls if x['id'] == j.loads(tid))
print(t['adapter'])
print(t['key_env'])
print('1' if t['base_url_editable'] else '')
print('1' if t['requires_model'] else '')
" "$template_id")
  adapter=$(echo "$tpl_json" | sed -n '1p')
  key_env=$(echo "$tpl_json" | sed -n '2p')
  base_editable=$(echo "$tpl_json" | sed -n '3p')
  requires_model=$(echo "$tpl_json" | sed -n '4p')

  if [[ "$base_editable" == "1" && -z "$base_url" ]]; then
    err "该 provider 需要 base_url，请先编辑配置。"
    return
  fi
  if [[ "$requires_model" == "1" && -z "$model" ]]; then
    err "该 provider 需要 model，请先编辑配置。"
    return
  fi

  # Generate secret if missing.
  if [[ -z "$secret" ]]; then
    secret=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
    run_helper set-secret --secret "$secret" >/dev/null
  fi

  # Kill old proxy watchdog + proxy on same port（多重保障）。
  local script="$PROJ/proxy/csswitch_proxy.py"
  local script_rex
  script_rex=$(python3 -c "import re,sys; print(re.escape(sys.argv[1]))" "$script")
  # 方法 1：pkill 匹配脚本路径 + 端口
  pkill -f "${script_rex}.*--port ${proxy_port}" 2>/dev/null || true
  # 方法 2：匹配 watchdog（端口在环境变量，不在命令行）
  local _all_wd
  _all_wd=$(pgrep -f "proxy-watchdog" 2>/dev/null) || true
  if [[ -n "$_all_wd" ]]; then
    while IFS= read -r _wp; do
      if [[ -r "/proc/$_wp/environ" ]] && grep -qz "PROXY_PORT=${proxy_port}" "/proc/$_wp/environ" 2>/dev/null; then
        kill "$_wp" 2>/dev/null || true
      fi
    done <<< "$_all_wd"
  fi
  # 方法 3：按端口查找并杀死占用进程（兜底 pkill 匹配失败的情况）
  local pids
  pids=$(ss -tlnp "sport = :${proxy_port}" 2>/dev/null | grep -oP 'pid=\K[0-9]+' || true)
  if [[ -n "$pids" ]]; then
    echo "$pids" | xargs kill -9 2>/dev/null || true
  fi
  # 等待端口释放（最多 3 秒）
  for _ in $(seq 1 30); do
    if ! ss -tlnp "sport = :${proxy_port}" 2>/dev/null | grep -q "LISTEN"; then
      break
    fi
    sleep 0.1
  done

  mkdir -p "$CSSWITCH_DIR/logs"

  # Check if multi-provider mode
  local cfg_mode env_vars
  cfg_mode=$(run_helper load | python3 -c "import sys,json; print(json.load(sys.stdin).get('mode','proxy'))")
  local multi_config_file=""

  if [[ "$cfg_mode" == "multi" ]]; then
    multi_config_file="$CSSWITCH_DIR/logs/multi-config.json"
    run_helper multi-config > "$multi_config_file"
    msg "启动代理 (mode=multi, port=$proxy_port, 带保活)..."
    # Collect all API keys from multi-config into env file
    local env_file="$CSSWITCH_DIR/logs/multi-env.sh"
    python3 -c "
import json
mc = json.load(open('$multi_config_file'))
with open('$env_file', 'w') as f:
    for p in mc.get('providers', []):
        ke, ak = p.get('key_env',''), p.get('api_key','')
        if ke and ak: f.write(f'export {ke}={ak}\n')
"
    env_vars=()
    while IFS= read -r line; do
      [[ -n "$line" ]] && env_vars+=("$line")
    done < "$env_file"
    rm -f "$env_file"
  else
    msg "启动代理 (adapter=$adapter, port=$proxy_port, 带保活)..."
    env_vars=("$key_env=$key")
    if [[ "$adapter" == "relay" ]]; then
      [[ -n "$base_url" ]] && env_vars+=("CSSWITCH_RELAY_BASE_URL=$base_url")
      [[ -n "$model" ]] && env_vars+=("CSSWITCH_RELAY_MODEL=$model")
    elif [[ "$adapter" == "openai-custom" || "$adapter" == "openai-responses" ]]; then
      [[ -n "$base_url" ]] && env_vars+=("CSSWITCH_OPENAI_BASE_URL=$base_url")
      [[ -n "$model" ]] && env_vars+=("CSSWITCH_OPENAI_MODEL=$model")
    fi
  fi

  # 用 watchdog 包装代理
  # 构建代理额外参数（base_url/model 以 CLI 参数传递，比环境变量继承更可靠）
  local proxy_args=""
  if [[ "$cfg_mode" == "multi" ]]; then
    # multi 模式：代理通过 --multi-config 读取所有 provider 配置（含 key）
    proxy_args+=" --multi-config $multi_config_file"
  elif [[ "$adapter" == "relay" ]]; then
    [[ -n "$base_url" ]] && proxy_args+=" --relay-base $base_url"
  elif [[ "$adapter" == "openai-custom" || "$adapter" == "openai-responses" ]]; then
    [[ -n "$base_url" ]] && proxy_args+=" --openai-base $base_url"
  fi
  # model 通过环境变量 CSSWITCH_RELAY_MODEL / CSSWITCH_OPENAI_MODEL 传递（已设在 env_vars 中）

  # 把 watchdog 所需变量加入 env_vars（env 会丢弃前缀变量，必须显式传入）
  env_vars+=("PROXY_SCRIPT=$script")
  env_vars+=("PROXY_PORT=$proxy_port")
  env_vars+=("PROXY_SECRET=$secret")
  env_vars+=("PROXY_ADAPTER=${adapter:-relay}")
  env_vars+=("PROXY_ARGS=$proxy_args")
  env_vars+=("PROXY_LOG=$CSSWITCH_DIR/logs/proxy-cli.log")

  nohup env "${env_vars[@]}" bash "$WATCHDOG" \
    >> "$CSSWITCH_DIR/logs/proxy-watchdog.log" 2>&1 &
  local proxy_pid=$!

  msg "等待代理就绪..."
  local ok=0
  for _ in $(seq 1 60); do
    # watchdog 已退出 → 代理无法启动，立即报错
    if ! kill -0 "$proxy_pid" 2>/dev/null; then
      err "代理进程已退出，查看 $CSSWITCH_DIR/logs/proxy-cli.log"
      return
    fi
    if curl -fsS -m 1 "http://127.0.0.1:$proxy_port/$secret/health" &>/dev/null; then
      ok=1
      break
    fi
    sleep 0.2
  done
  if [[ "$ok" == "0" ]]; then
    err "代理探活超时（12 秒），查看 $CSSWITCH_DIR/logs/proxy-cli.log"
    kill "$proxy_pid" 2>/dev/null || true
    return
  fi

  msg "启动沙箱 (port=$sandbox_port)..."
  local no_sandbox_flag="--no-sandbox"
  echo -n "是否使用 --no-sandbox 解除沙箱网络限制（允许镜像站下载）? [Y/n] "
  read -r no_sandbox_ans
  if [[ "$no_sandbox_ans" == "n" || "$no_sandbox_ans" == "N" ]]; then
    no_sandbox_flag=""
  fi

  local launch_args=(
    --port "$sandbox_port"
    --proxy-url "http://127.0.0.1:$proxy_port/$secret"
  )
  [[ -n "$no_sandbox_flag" ]] && launch_args+=("$no_sandbox_flag")

  if ! SANDBOX_HOME="$SANDBOX_HOME" "$LAUNCH" "${launch_args[@]}"; then
    err "沙箱启动失败，已停止代理。请检查日志后重试。"
    kill "$proxy_pid" 2>/dev/null || true
    return
  fi

  msg "等待沙箱就绪..."
  ok=0
  for _ in $(seq 1 80); do
    if curl -fsS -m 1 "http://127.0.0.1:$sandbox_port/health" &>/dev/null; then
      ok=1
      break
    fi
    sleep 0.1
  done
  if [[ "$ok" == "0" ]]; then
    err "沙箱启动后探活超时。"
    return
  fi

  local content_port=$((sandbox_port + 1))
  local bin
  bin=$(find_science_bin) || { err "找不到 claude-science 二进制"; return; }

  echo ""
  echo "=== 启动完成 ==="
  echo "本地访问："
  echo "  主界面 : http://127.0.0.1:$sandbox_port"
  echo "  内容页 : http://127.0.0.1:$content_port"
  echo ""
  echo "通过 SSH 从本地电脑远程访问（在你的电脑上执行）："
  local remote_ip
  remote_ip="$(hostname -I | awk '{print $1}')"
  echo "  ssh -L ${sandbox_port}:localhost:${sandbox_port} -L ${content_port}:localhost:${content_port} $(whoami)@${remote_ip}"
  echo ""
  echo "然后在本机浏览器打开："
  echo "  http://localhost:${sandbox_port}"
  echo ""
  do_login_url
}

do_start_multi() {
  msg "=== 多 Provider 启动 ==="

  # Ensure config dir exists
  if [[ ! -d "$CSSWITCH_DIR" ]]; then
    err "CSSwitch 目录不存在，请先初始化（选项 9）"
    return
  fi

  # Import settings from Claude Code if no multi-provider config yet
  local current_mode
  current_mode=$(run_helper load 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('mode','proxy'))" 2>/dev/null)

  if [[ "$current_mode" != "multi" ]]; then
    msg "从 Claude Code settings.json 导入 API 配置..."
    if ! do_import_settings; then
      err "导入失败。请先手动添加至少 2 个 provider（选项 5），然后用 set-active-providers 激活。"
      return
    fi
  fi

  # Show current multi-provider config
  local mc n_providers default_prefix
  mc=$(run_helper multi-config 2>/dev/null)
  n_providers=$(echo "$mc" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('providers',[])))")
  default_prefix=$(echo "$mc" | python3 -c "import sys,json; print(json.load(sys.stdin).get('default_prefix',''))")

  msg "已配置 $n_providers 个 provider，默认: $default_prefix"
  echo "$mc" | python3 -c '
import sys, json
mc = json.load(sys.stdin)
for p in mc.get("providers", []):
    print("  " + p["prefix"] + ": " + p["name"] + " (" + p["template_id"] + ")")
'

  # Launch using do_start (which detects mode=multi automatically)
  do_start
}

print_access_info() {
  local sandbox_port content_port
  sandbox_port=$(run_helper load | python3 -c "import sys,json; print(json.load(sys.stdin)['sandbox_port'])")
  content_port=$((sandbox_port + 1))
  echo ""
  echo "=== 访问信息 ==="
  echo "  主界面 : http://127.0.0.1:$sandbox_port"
  echo "  内容页 : http://127.0.0.1:$content_port"
}

do_stop() {
  msg "停止沙箱..."
  SANDBOX_HOME="$SANDBOX_HOME" "$STOP" || true
  msg "停止代理..."
  local port
  port=$(run_helper load | python3 -c "import sys,json; print(json.load(sys.stdin)['proxy_port'])")
  local script="$PROJ/proxy/csswitch_proxy.py"
  local script_rex
  script_rex=$(python3 -c "import re,sys; print(re.escape(sys.argv[1]))" "$script")

  # 1) 停 watchdog：用 /proc/<pid>/environ 匹配 PROXY_PORT
  local wd_pids=""
  local all_wd
  all_wd=$(pgrep -f "proxy-watchdog" 2>/dev/null) || true
  if [[ -n "$all_wd" ]]; then
    while IFS= read -r _wp; do
      if [[ -r "/proc/$_wp/environ" ]] && grep -qz "PROXY_PORT=${port}" "/proc/$_wp/environ" 2>/dev/null; then
        wd_pids="$wd_pids $_wp"
      fi
    done <<< "$all_wd"
  fi
  wd_pids=$(echo "$wd_pids" | tr ' ' '
' | grep -v '^$' | sort -u || true)
  if [[ -n "$wd_pids" ]]; then
    echo "$wd_pids" | xargs kill 2>/dev/null || true
    for _ in $(seq 1 30); do
      local still_alive=""
      for _wp in $wd_pids; do
        kill -0 "$_wp" 2>/dev/null && still_alive="1"
      done
      [[ -z "$still_alive" ]] && break
      sleep 0.2
    done
  fi

  # 2) 停 proxy（如果 watchdog 没杀干净）
  local px_pids
  px_pids=$(pgrep -f "${script_rex}.*--port ${port}" 2>/dev/null || true)
  if [[ -n "$px_pids" ]]; then
    echo "$px_pids" | xargs kill 2>/dev/null || true
    for _ in $(seq 1 30); do
      if ! echo "$px_pids" | xargs kill -0 2>/dev/null; then break; fi
      sleep 0.2
    done
    # 还没死就 SIGKILL
    echo "$px_pids" | xargs kill -0 2>/dev/null && echo "$px_pids" | xargs kill -9 2>/dev/null || true
  fi

  # 3) 兜底：等待端口释放（最多 5 秒）
  for _ in $(seq 1 50); do
    if ! ss -tlnp "sport = :${port}" 2>/dev/null | grep -q "LISTEN"; then
      break
    fi
    sleep 0.1
  done

  # 4) 最终兜底：按端口 SIGKILL
  local pids
  pids=$(ss -tlnp "sport = :${port}" 2>/dev/null | grep -oP 'pid=\K[0-9]+' || true)
  if [[ -n "$pids" ]]; then
    echo "$pids" | xargs kill -9 2>/dev/null || true
  fi
  msg "已停止。"
}

do_status() {
  local proxy_status="未运行"
  local sandbox_status="未运行"
  proxy_health && proxy_status="运行中"
  sandbox_running && sandbox_status="运行中"
  local active
  active=$(run_helper active 2>/dev/null || echo "")
  if [[ -z "$active" || "$active" == *"error"* ]]; then
    active="无"
  else
    active=$(echo "$active" | python3 -c "import sys,json; d=json.load(sys.stdin); d.pop('api_key',None); print(json.dumps(d,ensure_ascii=False))")
  fi
  echo "=== 运行状态 ==="
  echo "代理:   $proxy_status"
  echo "沙箱:   $sandbox_status"
  echo "生效配置: $active"
}
do_switch() {
  local profiles
  profiles=$(run_helper list)
  if [[ "$profiles" == "[]" ]]; then
    err "还没有 provider，请先添加。"
    return
  fi
  echo "=== 选择要切换的 provider ==="
  local i=1
  local ids=()
  local names=()
  while IFS= read -r line; do
    local id name template model
    id=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
    name=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])")
    template=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin)['template_id'])")
    model=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('model',''))")
    echo "$i) $name [$template] ${model:+model=$model}"
    ids+=("$id")
    names+=("$name")
    i=$((i+1))
  done < <( echo "$profiles" | python3 -c "import sys,json; [print(json.dumps(p)) for p in json.load(sys.stdin)]" )
  echo -n "请输入编号: "
  read -r idx
  if ! [[ "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > ${#ids[@]} )); then
    err "无效编号"
    return
  fi
  local chosen="${ids[$((idx-1))]}"
  run_helper set-active "$chosen"
  msg "已切换到: ${names[$((idx-1))]}"
}

do_add() {
  local templates
  templates=$(run_helper templates)
  echo "=== 选择 provider 模板 ==="
  local i=1
  local ids=()
  local names=()
  while IFS= read -r line; do
    local id name
    id=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
    name=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])")
    echo "$i) $name"
    ids+=("$id")
    names+=("$name")
    i=$((i+1))
  done < <( echo "$templates" | python3 -c "import sys,json; [print(json.dumps(t)) for t in json.load(sys.stdin)]" )
  echo -n "请输入编号: "
  read -r idx
  if ! [[ "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > ${#ids[@]} )); then
    err "无效编号"
    return
  fi
  local tpl="${ids[$((idx-1))]}"
  local tpl_name="${names[$((idx-1))]}"

  local base_url_editable requires_model
  base_url_editable=$(echo "$templates" | python3 -c "import sys,json; t=[x for x in json.load(sys.stdin) if x['id']=='$tpl'][0]; print('1' if t['base_url_editable'] else '')")
  requires_model=$(echo "$templates" | python3 -c "import sys,json; t=[x for x in json.load(sys.stdin) if x['id']=='$tpl'][0]; print('1' if t['requires_model'] else '')")

  echo -n "显示名称: "
  read -r name
  echo -n "API Key: "
  read -rs key
  echo
  local base_url=""
  if [[ "$base_url_editable" == "1" ]]; then
    echo -n "Base URL: "
    read -r base_url
  fi
  local model=""
  if [[ "$requires_model" == "1" ]]; then
    echo -n "模型名: "
    read -r model
  fi
  local args=("--template" "$tpl" "--name" "$name" "--key" "$key")
  [[ -n "$base_url" ]] && args+=("--base-url" "$base_url")
  [[ -n "$model" ]] && args+=("--model" "$model")
  run_helper add "${args[@]}"
  msg "已添加并激活: $name [$tpl_name]"
}

do_edit() {
  local profiles
  profiles=$(run_helper list)
  echo "=== 选择要编辑的 provider ==="
  local i=1
  local ids=()
  local names=()
  while IFS= read -r line; do
    local id name
    id=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
    name=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])")
    echo "$i) $name"
    ids+=("$id")
    names+=("$name")
    i=$((i+1))
  done < <( echo "$profiles" | python3 -c "import sys,json; [print(json.dumps(p)) for p in json.load(sys.stdin)]" )
  echo -n "请输入编号: "
  read -r idx
  if ! [[ "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > ${#ids[@]} )); then
    err "无效编号"
    return
  fi
  local pid="${ids[$((idx-1))]}"
  echo -n "新显示名称 (留空不变): "
  read -r name
  echo -n "新 API Key (留空不变): "
  read -rs key
  echo
  echo -n "新 Base URL (留空不变): "
  read -r base_url
  echo -n "新模型名 (留空不变): "
  read -r model
  local args=()
  [[ -n "$name" ]] && args+=("--name" "$name")
  [[ -n "$key" ]] && args+=("--key" "$key")
  [[ -n "$base_url" ]] && args+=("--base-url" "$base_url")
  [[ -n "$model" ]] && args+=("--model" "$model")
  run_helper edit "$pid" "${args[@]}"
  msg "已更新: ${names[$((idx-1))]}"
}

do_delete() {
  local profiles
  profiles=$(run_helper list)
  echo "=== 选择要删除的 provider ==="
  local i=1
  local ids=()
  local names=()
  while IFS= read -r line; do
    local id name
    id=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
    name=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])")
    echo "$i) $name"
    ids+=("$id")
    names+=("$name")
    i=$((i+1))
  done < <( echo "$profiles" | python3 -c "import sys,json; [print(json.dumps(p)) for p in json.load(sys.stdin)]" )
  echo -n "请输入编号: "
  read -r idx
  if ! [[ "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > ${#ids[@]} )); then
    err "无效编号"
    return
  fi
  echo -n "确认删除 ${names[$((idx-1))]}? [y/N] "
  read -r confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    msg "已取消删除。"
    return
  fi
  run_helper delete "${ids[$((idx-1))]}"
  msg "已删除。"
}
do_login_url() {
  local bin
  bin=$(find_science_bin) || { err "找不到 claude-science 二进制"; return; }
  if ! sandbox_running; then
    err "沙箱未运行，请先启动。"
    return
  fi
  local url
  url=$(HOME="$SANDBOX_HOME" "$bin" url --data-dir "$DATA_DIR" 2>/dev/null | grep -Eo 'https?://[^ ]+' | head -1)
  if [[ -z "$url" ]]; then
    # Fallback to port if url command returns nothing usable.
    local port
    port=$(run_helper load | python3 -c "import sys,json; print(json.load(sys.stdin)['sandbox_port'])")
    url="http://127.0.0.1:$port"
  fi
  msg "登录链接: $url"
  if [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && command -v xdg-open &>/dev/null; then
    xdg-open "$url" 2>/dev/null || true
  fi
}

do_doctor() {
  local cfg adapter has_key
  cfg=$(run_helper load)
  local active_json
  active_json=$(run_helper active 2>/dev/null || echo "")
  if [[ -z "$active_json" || "$active_json" == *"error"* ]]; then
    adapter=""
    has_key="0"
  else
    adapter=$(echo "$active_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('template_id',''))")
    has_key=$(echo "$active_json" | python3 -c "import sys,json; print('1' if json.load(sys.stdin).get('api_key') else '0')")
  fi
  local proxy_port sandbox_port
  proxy_port=$(echo "$cfg" | python3 -c "import sys,json; print(json.load(sys.stdin)['proxy_port'])")
  sandbox_port=$(echo "$cfg" | python3 -c "import sys,json; print(json.load(sys.stdin)['sandbox_port'])")
  CSSWITCH_PROVIDER="${adapter:-}" \
  CSSWITCH_ADAPTER="${adapter:-}" \
  CSSWITCH_KEY_PRESENT="$has_key" \
  CSSWITCH_PROXY_PORT="$proxy_port" \
  CSSWITCH_SANDBOX_PORT="$sandbox_port" \
  CSSWITCH_CONFIG="$CSSWITCH_DIR/config.json" \
    "$DOCTOR"
}

do_init() {
  msg "初始化 CSSwitch 目录: $CSSWITCH_DIR"
  mkdir -p "$CSSWITCH_DIR/logs" "$SANDBOX_HOME"
  chmod 700 "$CSSWITCH_DIR" "$CSSWITCH_DIR/logs" "$SANDBOX_HOME"
  if [[ -d "$CSSWITCH_DIR/sandbox" ]]; then
    chmod 700 "$CSSWITCH_DIR/sandbox"
  fi
  if run_helper load >/dev/null; then
    msg "已创建默认配置: $CSSWITCH_DIR/config.json"
  else
    err "创建默认配置失败。"
  fi
}

tui_menu() {
  local height=20 width=60
  local choice_file
  choice_file=$(mktemp)
  trap 'rm -f "$choice_file"' EXIT
  while true; do
    if [[ "$UI_TOOL" == "dialog" ]]; then
      dialog --clear --title "CSSwitch-Linux CLI" --menu "选择操作" "$height" "$width" 10 \
        1 "启动 CSSwitch" \
        2 "多 provider 启动" \
        3 "停止 CSSwitch" \
        4 "查看运行状态" \
        5 "切换 API 服务商" \
        6 "添加新的 API 提供商" \
        7 "编辑 provider 配置" \
        8 "删除 provider" \
        9 "输出登录链接" \
        10 "初始化 CSSwitch 目录" \
        11 "运行诊断" \
        0 "退出" \
        2>"$choice_file" || true
    else
      whiptail --title "CSSwitch-Linux CLI" --menu "选择操作" "$height" "$width" 10 \
        1 "启动 CSSwitch" \
        2 "多 provider 启动" \
        3 "停止 CSSwitch" \
        4 "查看运行状态" \
        5 "切换 API 服务商" \
        6 "添加新的 API 提供商" \
        7 "编辑 provider 配置" \
        8 "删除 provider" \
        9 "输出登录链接" \
        10 "初始化 CSSwitch 目录" \
        11 "运行诊断" \
        0 "退出" \
        2>"$choice_file" || true
    fi
    local choice
    choice=$(cat "$choice_file" 2>/dev/null || echo "")
    [[ -z "$choice" ]] && continue
    case "$choice" in
      0) clear; echo "再见。"; exit 0 ;;
      1) clear; do_start ;;
      2) clear; do_start_multi ;;
      3) clear; do_stop ;;
      4) clear; do_status ;;
      5) clear; do_switch ;;
      6) clear; do_add ;;
      7) clear; do_edit ;;
      8) clear; do_delete ;;
      9) clear; do_login_url ;;
      10) clear; do_init ;;
      11) clear; do_doctor ;;
    esac
    [[ "$choice" != "0" ]] && { echo "按 Enter 继续..."; read -r; }
  done
}

main() {
  ensure_helper
  if [[ ! -d "$CSSWITCH_DIR" ]]; then
    echo "CSSwitch 目录不存在，请先运行初始化（选项 9）。" >&2
  fi
  if [[ -n "$UI_TOOL" ]]; then
    tui_menu
  else
    text_menu
  fi
}

main "$@"
