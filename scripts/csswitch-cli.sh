#!/usr/bin/env bash
# CSSwitch-Linux interactive CLI.
# Supports dialog/whiptail; falls back to a plain text menu.
set -euo pipefail

PROJ="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
HELPER="$PROJ/scripts/csswitch_config_helper.py"
LAUNCH="$PROJ/scripts/launch-virtual-sandbox.sh"
STOP="$PROJ/scripts/stop-science-sandbox.sh"
DOCTOR="$PROJ/scripts/doctor.sh"

CSSWITCH_DIR="${CSSWITCH_DIR:-$HOME/.csswitch}"
SANDBOX_HOME="${SANDBOX_HOME:-$CSSWITCH_DIR/sandbox/home}"
DATA_DIR="$SANDBOX_HOME/.claude-science"

# Detect UI tool: prefer dialog, then whiptail, then text.
UI_TOOL=""
if command -v dialog &>/dev/null; then
  UI_TOOL="dialog"
elif command -v whiptail &>/dev/null; then
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
    echo "2) 停止 CSSwitch"
    echo "3) 查看运行状态"
    echo "4) 切换 API 服务商 / profile"
    echo "5) 添加新的 API 提供商"
    echo "6) 编辑 provider 配置"
    echo "7) 删除 provider"
    echo "8) 输出登录链接"
    echo "9) 初始化 CSSwitch 目录"
    echo "10) 运行诊断"
    echo "0) 退出"
    echo -n "请选择: "
    if ! read -r choice; then
      echo
      echo "再见。"
      exit 0
    fi
    case "$choice" in
      1) do_start ;;
      2) do_stop ;;
      3) do_status ;;
      4) do_switch ;;
      5) do_add ;;
      6) do_edit ;;
      7) do_delete ;;
      8) do_login_url ;;
      9) do_init ;;
      10) do_doctor ;;
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
  local port secret
  port=$(run_helper load | python3 -c "import sys,json; print(json.load(sys.stdin)['proxy_port'])")
  secret=$(run_helper load | python3 -c "import sys,json; print(json.load(sys.stdin).get('secret',''))")
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

do_start() {
  local cfg proxy_port sandbox_port secret
  cfg=$(run_helper load)
  proxy_port=$(echo "$cfg" | python3 -c "import sys,json; print(json.load(sys.stdin)['proxy_port'])")
  sandbox_port=$(echo "$cfg" | python3 -c "import sys,json; print(json.load(sys.stdin)['sandbox_port'])")
  secret=$(echo "$cfg" | python3 -c "import sys,json; print(json.load(sys.stdin).get('secret',''))")

  if [[ "$proxy_port" == "8000" || "$sandbox_port" == "8000" ]]; then
    err "端口 8000 是真实 Science 保留端口，请在配置中修改。"
    return
  fi

  local active
  active=$(run_helper active 2>/dev/null || echo "无")
  if [[ -z "$active" || "$active" == "无" ]]; then
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

  # Determine adapter and key env from template registry.
  local adapter key_env base_editable requires_model
  adapter=$(run_helper templates | python3 -c "import sys,json; t=[x for x in json.load(sys.stdin) if x['id']=='$template_id'][0]; print(t['adapter'])")
  key_env=$(run_helper templates | python3 -c "import sys,json; t=[x for x in json.load(sys.stdin) if x['id']=='$template_id'][0]; print(t['key_env'])")
  base_editable=$(run_helper templates | python3 -c "import sys,json; t=[x for x in json.load(sys.stdin) if x['id']=='$template_id'][0]; print('1' if t['base_url_editable'] else '')")
  requires_model=$(run_helper templates | python3 -c "import sys,json; t=[x for x in json.load(sys.stdin) if x['id']=='$template_id'][0]; print('1' if t['requires_model'] else '')")

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

  # Kill old proxy on same port.
  local script="$PROJ/proxy/csswitch_proxy.py"
  local script_rex
  script_rex=$(python3 -c "import re,sys; print(re.escape(sys.argv[1]))" "$script")
  pkill -f "${script_rex}.*--port ${proxy_port}" || true

  msg "启动代理 (adapter=$adapter, port=$proxy_port)..."
  export "$key_env=$key"
  if [[ "$adapter" == "relay" ]]; then
    [[ -n "$base_url" ]] && export CSSWITCH_RELAY_BASE_URL="$base_url"
    [[ -n "$model" ]] && export CSSWITCH_RELAY_MODEL="$model"
  elif [[ "$adapter" == "openai-custom" || "$adapter" == "openai-responses" ]]; then
    export CSSWITCH_OPENAI_BASE_URL="$base_url"
    [[ -n "$model" ]] && export CSSWITCH_OPENAI_MODEL="$model"
  fi

  mkdir -p "$CSSWITCH_DIR/logs"
  python3 "$script" \
    --provider "$adapter" \
    --port "$proxy_port" \
    --auth-token "$secret" \
    >> "$CSSWITCH_DIR/logs/proxy-cli.log" 2>&1 &
  local proxy_pid=$!

  msg "等待代理就绪..."
  local ok=0
  for _ in $(seq 1 40); do
    if curl -fsS -m 1 "http://127.0.0.1:$proxy_port/$secret/health" &>/dev/null; then
      ok=1
      break
    fi
    sleep 0.1
  done
  if [[ "$ok" == "0" ]]; then
    err "代理启动失败或探活超时，查看 $CSSWITCH_DIR/logs/proxy-cli.log"
    kill "$proxy_pid" 2>/dev/null || true
    return
  fi

  msg "启动沙箱 (port=$sandbox_port)..."
  if ! SANDBOX_HOME="$SANDBOX_HOME" "$LAUNCH" \
    --port "$sandbox_port" \
    --proxy-url "http://127.0.0.1:$proxy_port/$secret" \
    --skip-oauth-forge; then
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

  do_login_url
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
  pkill -f "${script_rex}.*--port ${port}" || true
  msg "已停止。"
}

do_status() {
  local proxy_status="未运行"
  local sandbox_status="未运行"
  proxy_health && proxy_status="运行中"
  sandbox_running && sandbox_status="运行中"
  local active
  active=$(run_helper active 2>/dev/null || echo "")
  if [[ -z "$active" ]]; then
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
  local base_url_arg=""
  if [[ "$base_url_editable" == "1" ]]; then
    echo -n "Base URL: "
    read -r base_url
    base_url_arg="--base-url $base_url"
  fi
  local model_arg=""
  if [[ "$requires_model" == "1" ]]; then
    echo -n "模型名: "
    read -r model
    model_arg="--model $model"
  fi
  run_helper add --template "$tpl" --name "$name" --key "$key" $base_url_arg $model_arg
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
do_login_url() { msg "login url (TODO)"; }
do_doctor() { msg "doctor (TODO)"; }

do_init() {
  msg "初始化 CSSwitch 目录: $CSSWITCH_DIR"
  mkdir -p "$CSSWITCH_DIR/logs" "$SANDBOX_HOME"
  chmod 700 "$CSSWITCH_DIR" "$CSSWITCH_DIR/logs" "$SANDBOX_HOME"
  if [[ -d "$CSSWITCH_DIR/sandbox" ]]; then
    chmod 700 "$CSSWITCH_DIR/sandbox"
  fi
  if [[ ! -f "$CSSWITCH_DIR/config.json" ]]; then
    tmp_config="$(mktemp "$CSSWITCH_DIR/.config.json.tmp.XXXXXX")"
    run_helper load > "$tmp_config"
    chmod 600 "$tmp_config"
    mv "$tmp_config" "$CSSWITCH_DIR/config.json"
    msg "已创建默认配置: $CSSWITCH_DIR/config.json"
  else
    msg "配置已存在，跳过创建。"
  fi
}

main() {
  ensure_helper
  if [[ ! -d "$CSSWITCH_DIR" ]]; then
    echo "CSSwitch 目录不存在，请先运行 '初始化 CSSwitch 目录'（选项 9）。" >&2
  fi
  text_menu
}

main "$@"
