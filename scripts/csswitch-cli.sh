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

# Stub implementations; filled in later tasks.
do_start() { msg "start (TODO)"; }
do_stop() { msg "stop (TODO)"; }
do_status() { msg "status (TODO)"; }
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
