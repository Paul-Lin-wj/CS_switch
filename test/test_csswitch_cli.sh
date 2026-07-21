#!/usr/bin/env bash
# Integration tests for csswitch-cli. No real Science/proxy start; focuses on config and menus.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/scripts/csswitch-cli.sh"
HELPER="$ROOT/scripts/csswitch_config_helper.py"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

export CSSWITCH_DIR="$T"
export CSSWITCH_UI="text"
export PATH="/usr/bin:/bin:$PATH"

echo "== csswitch-cli integration tests =="

# 1. init
bash "$CLI" <<EOF
9
0
EOF
[[ -f "$T/config.json" ]] || { echo "FAIL: config not created"; exit 1; }
mode=$(stat -c "%a" "$T/config.json")
[[ "$mode" == "600" ]] || { echo "FAIL: config.json mode is $mode, expected 600"; exit 1; }
dmode=$(stat -c "%a" "$T")
[[ "$dmode" == "700" ]] || { echo "FAIL: csswitch dir mode is $dmode, expected 700"; exit 1; }

# 2. add profile via helper, verify it appears in list
CSSWITCH_CONFIG="$T/config.json" python3 "$HELPER" add --template deepseek --name "DS" --key sk-test --model deepseek-chat >/dev/null
profiles=$(CSSWITCH_CONFIG="$T/config.json" python3 "$HELPER" list)
echo "$profiles" | grep -q '"name": "DS"' || { echo "FAIL: added profile not in list"; exit 1; }
active=$(CSSWITCH_CONFIG="$T/config.json" python3 "$HELPER" active | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])")
[[ "$active" == "DS" ]] || { echo "FAIL: active profile mismatch"; exit 1; }

# 3. status (no running services, should report stopped and not leak key)
out=$(bash "$CLI" <<EOF
3
0
EOF
)
echo "$out" | grep -q "代理:.*未运行" || { echo "FAIL: status did not report proxy stopped"; exit 1; }
echo "$out" | grep -q "sk-test" && { echo "FAIL: full API key leaked in status"; exit 1; }

# 4. doctor contract: should exit 0 with deps present
CSSWITCH_CONFIG="$T/config.json" "$ROOT/scripts/doctor.sh" >/dev/null || { echo "FAIL: doctor failed"; exit 1; }

# 5. symlink rejection
SYM="$(mktemp -d)"
trap 'rm -rf "$SYM" "$T"' EXIT
real_dir="$SYM/real"
mkdir -p "$real_dir"
ln -s "$real_dir" "$SYM/.csswitch"
if CSSWITCH_CONFIG="$SYM/.csswitch/config.json" python3 "$HELPER" load >/dev/null 2>&1; then
  echo "FAIL: helper followed symlink"
  exit 1
fi
[[ ! -f "$SYM/.csswitch/config.json" ]] || { echo "FAIL: config created under symlink path"; exit 1; }
rm -rf "$SYM"
trap 'rm -rf "$T"' EXIT

echo "ALL PASS"
