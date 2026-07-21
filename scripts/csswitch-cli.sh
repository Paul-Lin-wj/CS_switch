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
    read -r choice
    case "$choice" in
      1) do_start ;;&
      2) do_stop ;;&
      3) do_status ;;&
      4) do_switch ;;&
      5) do_add ;;&
      6) do_edit ;;&
      7) do_delete ;;&
      8) do_login_url ;;&
      9) do_init ;;&
      10) do_doctor ;;&
      0) echo "再见。"; exit 0 ;;&
      *) echo "无效选项，请重新选择。" ;;
    esac
  done
}

# Stub implementations; filled in later tasks.
do_start() { msg "start (TODO)"; }
do_stop() { msg "stop (TODO)"; }
do_status() { msg "status (TODO)"; }
do_switch() { msg "switch (TODO)"; }
do_add() { msg "add (TODO)"; }
do_edit() { msg "edit (TODO)"; }
do_delete() { msg "delete (TODO)"; }
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
