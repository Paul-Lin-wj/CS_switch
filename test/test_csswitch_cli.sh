#!/usr/bin/env bash
# Integration tests for csswitch-cli. No real Science/proxy start; focuses on config and menus.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/scripts/csswitch-cli.sh"
HELPER="$ROOT/scripts/csswitch_config_helper.py"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

echo "== csswitch-cli integration tests =="

# --- 1. Init creates dirs and config with correct perms ---
CSSWITCH_DIR="$T/c1" SANDBOX_HOME="$T/c1/sandbox/home" HOME="$T/h1" CSSWITCH_UI=text "$CLI" <<'EOF'
11
0
EOF
[[ -d "$T/c1/logs" ]] || { echo "FAIL: logs dir not created"; exit 1; }
[[ -d "$T/c1/sandbox/home" ]] || { echo "FAIL: sandbox dir not created"; exit 1; }
[[ -f "$T/c1/config.json" ]] || { echo "FAIL: config not created"; exit 1; }
mode=$(stat -c "%a" "$T/c1/config.json")
[[ "$mode" == "600" ]] || { echo "FAIL: config.json mode is $mode, expected 600"; exit 1; }
dmode=$(stat -c "%a" "$T/c1")
[[ "$dmode" == "700" ]] || { echo "FAIL: csswitch dir mode is $dmode, expected 700"; exit 1; }

# --- 2. Add deepseek profile, verify active and masked key ---
CSSWITCH_CONFIG="$T/c1/config.json" python3 "$HELPER" add \
  --template deepseek --name "DS" --key sk-test123 --model deepseek-chat >/dev/null
active=$(CSSWITCH_CONFIG="$T/c1/config.json" python3 "$HELPER" active | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])")
[[ "$active" == "DS" ]] || { echo "FAIL: active profile mismatch: $active"; exit 1; }

# --- 3. Status reports stopped, shows active profile, no key leak ---
out=$(CSSWITCH_DIR="$T/c1" SANDBOX_HOME="$T/c1/sandbox/home" HOME="$T/h1" CSSWITCH_UI=text "$CLI" <<'EOF'
4
0
EOF
)
echo "$out" | grep -q "代理:.*未运行" || { echo "FAIL: status did not report proxy stopped"; exit 1; }
echo "$out" | grep -q "沙箱:.*未运行" || { echo "FAIL: status did not report sandbox stopped"; exit 1; }
echo "$out" | grep -q "DS" || { echo "FAIL: status did not show active profile name"; exit 1; }
echo "$out" | grep -q "sk-test123" && { echo "FAIL: full API key leaked in status"; exit 1; }

# --- 4. Status with no active profile shows "无" ---
CSSWITCH_CONFIG="$T/c1/config.json" python3 "$HELPER" delete \
  "$(CSSWITCH_CONFIG="$T/c1/config.json" python3 "$HELPER" list | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")" >/dev/null
out2=$(CSSWITCH_DIR="$T/c1" SANDBOX_HOME="$T/c1/sandbox/home" HOME="$T/h1" CSSWITCH_UI=text "$CLI" <<'EOF'
4
0
EOF
)
echo "$out2" | grep -q "生效配置: 无" || { echo "FAIL: status did not show '无' for no active profile"; exit 1; }

# --- 5. Start fails gracefully when no active provider ---
out3=$(CSSWITCH_DIR="$T/c1" SANDBOX_HOME="$T/c1/sandbox/home" HOME="$T/h1" CSSWITCH_UI=text "$CLI" <<'EOF' 2>&1
1
0
EOF
)
echo "$out3" | grep -q "没有生效的 provider" || { echo "FAIL: start did not report missing provider"; exit 1; }

# --- 6. Add relay provider with base_url and model ---
CSSWITCH_CONFIG="$T/c1/config.json" python3 "$HELPER" add \
  --template relay --name "Relay" --key sk-relay \
  --base-url "https://example.com/anthropic" --model "test-model" >/dev/null
relay=$(CSSWITCH_CONFIG="$T/c1/config.json" python3 "$HELPER" active | python3 -c "import sys,json; print(json.load(sys.stdin)['model'])")
[[ "$relay" == "test-model" ]] || { echo "FAIL: relay model mismatch"; exit 1; }

# --- 7. Doctor contract: should exit 0 with deps present ---
CSSWITCH_CONFIG="$T/c1/config.json" CSSWITCH_PROVIDER=relay CSSWITCH_ADAPTER=relay \
  CSSWITCH_KEY_PRESENT=1 "$ROOT/scripts/doctor.sh" >/dev/null || { echo "FAIL: doctor failed"; exit 1; }

# --- 8. Stop handles missing Science binary gracefully ---
out4=$(CSSWITCH_DIR="$T/c1" SANDBOX_HOME="$T/c1/sandbox/home" HOME="$T/h1" CSSWITCH_UI=text "$CLI" <<'EOF' 2>&1
3
0
EOF
)
echo "$out4" | grep -q "已停止" || { echo "FAIL: stop did not report stopped"; exit 1; }

# --- 9. Symlink rejection ---
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


# --- 10. Config helper set-secret round-trips correctly ---
CSSWITCH_CONFIG="$T/c1/config.json" python3 "$HELPER" set-secret --secret "test-secret-abc" >/dev/null
sec=$(CSSWITCH_CONFIG="$T/c1/config.json" python3 "$HELPER" load | python3 -c "import sys,json; print(json.load(sys.stdin)['secret'])")
[[ "$sec" == "test-secret-abc" ]] || { echo "FAIL: secret round-trip failed: $sec"; exit 1; }

# --- 11. Status does not leak secret ---
out5=$(CSSWITCH_DIR="$T/c1" SANDBOX_HOME="$T/c1/sandbox/home" HOME="$T/h1" CSSWITCH_UI=text "$CLI" <<'EOF'
4
0
EOF
)
echo "$out5" | grep -q "test-secret-abc" && { echo "FAIL: secret leaked in status output"; exit 1; }

echo "ALL PASS"
