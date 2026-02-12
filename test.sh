#!/usr/bin/env bash
# Smoke tests for mcp-agents stdio transport.
# Verifies the server responds to piped JSON-RPC without exiting prematurely.
#
# The keepalive timer means the server won't exit on its own after stdin EOF,
# so we use `timeout` to cap each test run.
set -euo pipefail

cd "$(dirname "$0")"

SERVER="node server.js"
TIMEOUT_CMD="timeout"
if ! command -v timeout >/dev/null 2>&1; then
  if command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD="gtimeout"
  else
    echo "Error: 'timeout' (coreutils) is required. Install via: brew install coreutils"
    exit 1
  fi
fi
PASS=0
FAIL=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }

# ── Helper: run tools/list with a given --provider and check for expected tool ──
test_tools_list() {
  local label="$1"
  local provider="$2"
  local expected_tool="$3"

  echo "--- $label ---"

  RESPONSE=$(
    {
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
      sleep 1
    } | $TIMEOUT_CMD 10 $SERVER --provider "$provider" 2>/dev/null || true
  )

  if echo "$RESPONSE" | jq -e ".result.tools[] | select(.name == \"$expected_tool\")" >/dev/null 2>&1; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  fi
}

# ── Helper: full handshake then tools/list ──
test_handshake() {
  local label="$1"
  local provider="$2"
  local expected_tool="$3"

  echo "--- $label ---"

  RESPONSE=$(
    {
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0.0.1"}}}'
      sleep 0.3
      printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
      sleep 0.3
      printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
      sleep 1
    } | $TIMEOUT_CMD 10 $SERVER --provider "$provider" 2>/dev/null || true
  )

  if echo "$RESPONSE" | grep -q "\"$expected_tool\""; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  fi
}

# ── Helper: full handshake → tools/call with a connectivity check ──
test_connectivity() {
  local label="$1"
  local provider="$2"
  local tool_name="$3"
  local call_timeout="${4:-120}"

  echo "--- $label ---"

  RESPONSE=$(
    {
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0.0.1"}}}'
      sleep 0.3
      printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
      sleep 0.3
      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$tool_name\",\"arguments\":{\"prompt\":\"This is a connectivity test. Reply with exactly: OK\"}}}"
      sleep "$call_timeout"
    } | $TIMEOUT_CMD "$((call_timeout + 10))" $SERVER --provider "$provider" 2>/dev/null || true
  )

  # Success = got a non-error tool result with actual content
  if echo "$RESPONSE" | jq -e '.result.content[0].text' >/dev/null 2>&1 \
     && ! echo "$RESPONSE" | jq -e '.result.isError' >/dev/null 2>&1; then
    local text
    text=$(echo "$RESPONSE" | jq -r '.result.content[0].text' 2>/dev/null | head -1)
    green "PASS: $label → $text"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  fi
}

# ── Helper: test a CLI flag that should succeed (exit 0, stdout matches) ──
test_cli_flag() {
  local label="$1"
  local flag="$2"
  local expected="$3"

  echo "--- $label ---"

  OUTPUT=$($SERVER $flag 2>/dev/null) || true
  EXIT_CODE=${PIPESTATUS[0]:-$?}

  if echo "$OUTPUT" | grep -q "$expected"; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (expected '$expected' in output)"
    echo "  Output: $OUTPUT"
    FAIL=$((FAIL + 1))
  fi
}

# ── Helper: test a CLI flag that should fail (exit non-zero, stderr matches) ──
test_cli_error() {
  local label="$1"
  local flag="$2"
  local expected="$3"

  echo "--- $label ---"

  STDERR_OUTPUT=$($SERVER $flag 2>&1 >/dev/null) || true

  if echo "$STDERR_OUTPUT" | grep -q "$expected"; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (expected '$expected' in stderr)"
    echo "  Stderr: $STDERR_OUTPUT"
    FAIL=$((FAIL + 1))
  fi
}

# ========== CLI flag tests ==========

test_cli_flag "--help prints usage"         "--help"    "Usage:"
test_cli_flag "-h prints usage"             "-h"        "Usage:"
test_cli_flag "--version prints version"    "--version"  "mcp-agents v"
test_cli_flag "-v prints version"           "-v"        "mcp-agents v"
test_cli_error "--bogus exits with error"   "--bogus"   "unknown option"
test_cli_error "--provider without value"                  "--provider"                 "requires a value"
test_cli_error "--model without value"                     "--model"                    "requires a value"
test_cli_error "--model_reasoning_effort without value"    "--model_reasoning_effort"   "requires a value"
test_cli_error "--sandbox without value"                    "--sandbox"                  "requires a value"
test_cli_error "--timeout without value"                    "--timeout"                  "requires a value"
test_cli_error "--timeout with zero"                        "--timeout 0"                "must be a positive number"
test_cli_error "--timeout with negative"                    "--timeout -5"               "must be a positive number"
test_cli_error "--timeout with non-number"                  "--timeout abc"              "must be a positive number"

# ========== Protocol tests (fast) ==========

# ---------- Ping (all providers) ----------
for p in claude gemini; do
  test_tools_list "tools/list --provider $p → ping" "$p" "ping"
done

# ---------- Claude provider ----------
test_tools_list "tools/list --provider claude → claude_code" "claude" "claude_code"
test_handshake  "handshake --provider claude → claude_code"  "claude" "claude_code"

# ---------- Gemini provider ----------
test_tools_list "tools/list --provider gemini → gemini" "gemini" "gemini"
test_handshake  "handshake --provider gemini → gemini"  "gemini" "gemini"

# ========== Integration tests (call real CLIs) ==========

# ── Helper: test codex pass-through (tools/list comes from codex itself) ──
test_codex_passthrough() {
  local label="$1"
  echo "--- $label ---"

  RESPONSE=$(
    {
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0.0.1"}}}'
      sleep 0.3
      printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
      sleep 0.3
      printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
      sleep 3
    } | $TIMEOUT_CMD 10 $SERVER --provider codex 2>/dev/null || true
  )

  if echo "$RESPONSE" | jq -e '.result.tools' >/dev/null 2>&1; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  fi
}

if [ "${SKIP_INTEGRATION:-}" = "1" ]; then
  echo ""
  echo "(Skipping integration tests — SKIP_INTEGRATION=1)"
else
  test_connectivity "call claude (connectivity)" "claude" "claude_code" 30
  test_connectivity "call gemini (connectivity)" "gemini" "gemini"     30
  test_codex_passthrough "codex passthrough (tools/list)"
fi

# ---------- Summary ----------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
