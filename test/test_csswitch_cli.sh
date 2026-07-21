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

# 2. add profile via helper (easier than interactive)
CSSWITCH_CONFIG="$T/config.json" python3 "$HELPER" add --template deepseek --name "DS" --key sk-test --model deepseek-chat >/dev/null
active=$(CSSWITCH_CONFIG="$T/config.json" python3 "$HELPER" active | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])")
[[ "$active" == "DS" ]] || { echo "FAIL: active profile mismatch"; exit 1; }

# 3. status (no running services, should report stopped)
out=$(bash "$CLI" <<EOF
3
0
EOF
)
echo "$out" | grep -q "代理:.*未运行" || { echo "FAIL: status did not report proxy stopped"; exit 1; }

# 4. doctor contract: should exit 0 with deps present
CSSWITCH_CONFIG="$T/config.json" "$ROOT/scripts/doctor.sh" >/dev/null || { echo "FAIL: doctor failed"; exit 1; }

echo "ALL PASS"
