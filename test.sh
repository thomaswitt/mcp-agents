#!/usr/bin/env bash
# Smoke tests for mcp-agents stdio transport.
# Verifies provider servers handle JSON-RPC over stdio and exit cleanly
# after stdin EOF. Timeouts are guardrails, not the expected shutdown path.
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
  local output_file
  local status

  echo "--- $label ---"

  output_file=$(mktemp)
  set +e
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
    sleep 1
  } | $TIMEOUT_CMD 10 $SERVER --provider "$provider" >"$output_file" 2>/dev/null
  status=$?
  set -e
  RESPONSE=$(cat "$output_file")
  rm -f "$output_file"

  if [ "$status" -ne 0 ]; then
    red "FAIL: $label (exit $status)"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  elif echo "$RESPONSE" | jq -e ".result.tools[] | select(.name == \"$expected_tool\")" >/dev/null 2>&1; then
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
  local output_file
  local status

  echo "--- $label ---"

  output_file=$(mktemp)
  set +e
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0.0.1"}}}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
    sleep 1
  } | $TIMEOUT_CMD 10 $SERVER --provider "$provider" >"$output_file" 2>/dev/null
  status=$?
  set -e
  RESPONSE=$(cat "$output_file")
  rm -f "$output_file"

  if [ "$status" -ne 0 ]; then
    red "FAIL: $label (exit $status)"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  elif echo "$RESPONSE" | grep -q "\"$expected_tool\""; then
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
  local output_file
  local status

  echo "--- $label ---"

  output_file=$(mktemp)
  set +e
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0.0.1"}}}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    sleep 0.3
    printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$tool_name\",\"arguments\":{\"prompt\":\"This is a connectivity test. Reply with exactly: OK\"}}}"
    sleep "$call_timeout"
  } | $TIMEOUT_CMD "$((call_timeout + 10))" $SERVER --provider "$provider" >"$output_file" 2>/dev/null
  status=$?
  set -e
  RESPONSE=$(cat "$output_file")
  rm -f "$output_file"

  # Success = the tools/call (id:2) returned a non-error result whose text
  # actually starts with "OK" (the requested reply) and is short. A non-empty
  # string is not enough: an "Authentication required…" message (e.g. from an
  # unauthenticated CLI) would otherwise pass the check.
  if [ "$status" -ne 0 ]; then
    red "FAIL: $label (exit $status)"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  elif echo "$RESPONSE" | jq -e 'select(.id == 2) | (.result.isError != true) and (.result.content[0].text | type == "string" and (ascii_upcase | test("^\\s*OK")) and (length < 40))' >/dev/null 2>&1; then
    local text
    text=$(echo "$RESPONSE" | jq -r 'select(.id == 2) | .result.content[0].text // empty' 2>/dev/null | head -c 120)
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
test_cli_flag "--help shows GPT-5.5 default" "--help"   "gpt-5.5"
test_cli_flag "--help shows xhigh default"  "--help"    "xhigh"
test_cli_flag "--help shows workspace-write default" "--help" "workspace-write"
test_cli_flag "--help shows never default"  "--help"    "never"
test_cli_flag "-h prints usage"             "-h"        "Usage:"
test_cli_flag "--version prints version"    "--version"  "mcp-agents v"
test_cli_flag "-v prints version"           "-v"        "mcp-agents v"
test_cli_error "--bogus exits with error"   "--bogus"   "unknown option"
test_cli_error "--provider without value"                  "--provider"                 "requires a value"
test_cli_error "--model without value"                     "--model"                    "requires a value"
test_cli_error "--model_reasoning_effort without value"    "--model_reasoning_effort"   "requires a value"
test_cli_error "--sandbox_mode without value"              "--sandbox_mode"             "requires a value"
test_cli_error "--approval_policy without value"           "--approval_policy"          "requires a value"
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
  local output_file
  local status
  echo "--- $label ---"

  output_file=$(mktemp)
  set +e
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0.0.1"}}}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
    sleep 3
  } | $TIMEOUT_CMD 10 $SERVER --provider codex >"$output_file" 2>/dev/null
  status=$?
  set -e
  RESPONSE=$(cat "$output_file")
  rm -f "$output_file"

  if [ "$status" -ne 0 ]; then
    red "FAIL: $label (exit $status)"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  elif echo "$RESPONSE" | jq -e '.result.tools' >/dev/null 2>&1; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  fi
}

# ── Helper: verify codex bridge starts with an isolated runtime ──
test_codex_isolated_runtime() {
  local label="$1"
  local output_file
  local status

  echo "--- $label ---"

  output_file=$(mktemp)
  set +e
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0.0.1"}}}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"codex","arguments":{"prompt":"Reply with ONLY OK","sandbox":"read-only"}}}'
    sleep 8
  } | $TIMEOUT_CMD 45 $SERVER --provider codex >"$output_file" 2>/dev/null
  status=$?
  set -e
  RESPONSE=$(cat "$output_file")
  rm -f "$output_file"

  if [ "$status" -ne 0 ]; then
    red "FAIL: $label (exit $status)"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  elif ! echo "$RESPONSE" | grep -q '"reasoning_effort":"xhigh"'; then
    red "FAIL: $label (missing xhigh session config)"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  elif ! echo "$RESPONSE" | grep -q '"server":"codex_apps"'; then
    red "FAIL: $label (missing codex_apps startup)"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  elif echo "$RESPONSE" | grep -Eq '"server":"(claude-code|local-claude-test|local-gemini-test|chrome-devtools|context7|aws-knowledge-mcp-server|openaiDeveloperDocs|google-dev-knowledge|github-knowledge-mcp-server)"'; then
    red "FAIL: $label (inherited MCP server started)"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  elif ! echo "$RESPONSE" | jq -e 'select(.id == 2) | .result.structuredContent.content == "OK"' >/dev/null 2>&1; then
    red "FAIL: $label"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  else
    green "PASS: $label"
    PASS=$((PASS + 1))
  fi
}

# ── Helper: verify provider shutdown kills an in-flight detached child ──
test_provider_shutdown_kills_child() {
  local label="$1"
  local tmpdir pid_file output_file status child_pid

  echo "--- $label ---"

  tmpdir=$(mktemp -d)
  pid_file="$tmpdir/claude.pid"
  output_file="$tmpdir/output.txt"

  cat >"$tmpdir/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s' "$$" > "$MCP_AGENTS_TEST_PID_FILE"
sleep 30
printf '%s\n' '{"type":"result","result":"OK","is_error":false}'
EOF
  chmod +x "$tmpdir/claude"

  set +e
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0.0.1"}}}'
    sleep 0.2
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    sleep 0.2
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"claude_code","arguments":{"prompt":"sleep"}}}'
    sleep 1
  } | PATH="$tmpdir:$PATH" MCP_AGENTS_TEST_PID_FILE="$pid_file" \
    $TIMEOUT_CMD 5 $SERVER --provider claude >"$output_file" 2>/dev/null
  status=$?
  set -e

  if [ "$status" -ne 0 ]; then
    red "FAIL: $label (exit $status)"
    cat "$output_file"
    FAIL=$((FAIL + 1))
    rm -rf "$tmpdir"
    return
  fi

  for _ in $(seq 1 20); do
    if [ -s "$pid_file" ]; then
      break
    fi
    sleep 0.1
  done

  if [ ! -s "$pid_file" ]; then
    red "FAIL: $label (missing child pid)"
    cat "$output_file"
    FAIL=$((FAIL + 1))
    rm -rf "$tmpdir"
    return
  fi

  child_pid=$(cat "$pid_file")
  sleep 0.5

  if kill -0 "$child_pid" 2>/dev/null; then
    red "FAIL: $label (child still running: $child_pid)"
    FAIL=$((FAIL + 1))
  else
    green "PASS: $label"
    PASS=$((PASS + 1))
  fi

  rm -rf "$tmpdir"
}

# ── Helper: stub `codex` on PATH that mirrors received stdin into a capture ──
# file, so we can assert exactly what the wrapper forwarded — no real codex.
write_codex_capture_stub() {
  cat >"$1/codex" <<'EOF'
#!/usr/bin/env bash
# Stub codex mcp-server: echo each received stdin line into the capture file.
# `|| [ -n "$line" ]` also captures a final line with no trailing newline
# (exercises the wrapper's end-of-stdin partial-frame path).
while IFS= read -r line || [ -n "$line" ]; do
  printf '%s\n' "$line" >> "$MCP_AGENTS_TEST_CAPTURE"
done
EOF
  chmod +x "$1/codex"
}

# ── Helper: codex passthrough strips model/effort (and the profile/provider ──
# bypass vectors) while leaving sandbox/cwd/approval intact for per-call control.
test_codex_strips_only_model_effort() {
  local label="$1"
  local tmpdir capture output_file status call_line ok bad good
  echo "--- $label ---"

  tmpdir=$(mktemp -d)
  capture="$tmpdir/codex_stdin.txt"
  output_file="$tmpdir/output.txt"
  : >"$capture"
  write_codex_capture_stub "$tmpdir"

  # Every key that MUST be stripped carries an "evil" marker (in its value, or
  # in the dotted key name), and every key that MUST survive does not — so a
  # single "no evil leaked through" assertion covers the whole denylist incl.
  # dotted-path overrides (profiles.*, model_providers.*).
  set +e
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"codex","arguments":{"prompt":"hi","model":"evil-model","sandbox":"read-only","cwd":"/tmp/wsroot","approval-policy":"never","config":{"model":"evil-model","model_reasoning_effort":"evil-effort","profile":"evil-profile","profiles":{"p":{"model":"evil-x"}},"profiles.evil.model":"evil-y","model_provider":"evil-prov","model_providers":{"m":{"base_url":"http://evil"}},"model_providers.x.base_url":"http://evil2","openai_base_url":"http://evil3","chatgpt_base_url":"http://evil4","model_catalog_json":"evil-json","plan_mode_reasoning_effort":"evil-plan","review_model":"evil-review","sandbox_mode":"danger-full-access","approval_policy":"never","cwd":"/tmp/wsroot"}}}}'
    sleep 0.5
  } | PATH="$tmpdir:$PATH" MCP_AGENTS_TEST_CAPTURE="$capture" \
    $TIMEOUT_CMD 10 $SERVER --provider codex >"$output_file" 2>/dev/null
  status=$?
  set -e

  call_line=$(grep '"method":"tools/call"' "$capture" 2>/dev/null | tail -1)
  ok=1
  # No stripped key (model/effort/profile/provider/base-url/plan/review, incl.
  # dotted variants) may survive — none of the kept keys contains "evil".
  printf '%s' "$call_line" | grep -q 'evil' && ok=0
  for good in '"sandbox":"read-only"' '"sandbox_mode":"danger-full-access"' '"approval-policy":"never"' '"approval_policy":"never"' '"cwd":"/tmp/wsroot"'; do
    printf '%s' "$call_line" | grep -q "$good" || ok=0
  done

  if [ "$status" -eq 0 ] && [ -n "$call_line" ] && [ "$ok" -eq 1 ]; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (status=$status)"
    echo "  Forwarded: $call_line"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$tmpdir"
}

# ── Helper: a tools/call with nothing to strip is forwarded byte-for-byte ──
# (no JSON re-serialization), preserving MCP stdio framing exactly.
test_codex_passes_through_unmodified() {
  local label="$1"
  local tmpdir capture output_file status input captured
  echo "--- $label ---"

  tmpdir=$(mktemp -d)
  capture="$tmpdir/codex_stdin.txt"
  output_file="$tmpdir/output.txt"
  : >"$capture"
  write_codex_capture_stub "$tmpdir"

  # Multibyte UTF-8 in the prompt: proves the raw-byte buffering forwards
  # non-ASCII content intact (the motivation for the Buffer rewrite).
  input='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"codex","arguments":{"prompt":"höhö 日本語 🚀 — ünïcödé","sandbox":"workspace-write","cwd":"/tmp/x"}}}'

  set +e
  {
    printf '%s\n' "$input"
    sleep 0.5
  } | PATH="$tmpdir:$PATH" MCP_AGENTS_TEST_CAPTURE="$capture" \
    $TIMEOUT_CMD 10 $SERVER --provider codex >"$output_file" 2>/dev/null
  status=$?
  set -e

  captured=$(grep '"method":"tools/call"' "$capture" 2>/dev/null | tail -1)
  if [ "$status" -eq 0 ] && [ "$captured" = "$input" ]; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (status=$status)"
    echo "  Expected: $input"
    echo "  Captured: $captured"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$tmpdir"
}

# ── Helper: a per-call sandbox=workspace-write + absolute cwd actually grants ──
# writes end-to-end (real codex). Proves the read-only symptom is fixed.
test_codex_percall_write() {
  local label="$1"
  local probe_dir probe_file output_file status RESPONSE
  echo "--- $label ---"

  probe_dir=$(mktemp -d)
  probe_file="$probe_dir/mcp_agents_probe.txt"
  output_file=$(mktemp)

  set +e
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0.0.1"}}}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    sleep 0.3
    printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"codex\",\"arguments\":{\"prompt\":\"Create a file named mcp_agents_probe.txt containing exactly OK in your current working directory, then reply with only OK.\",\"sandbox\":\"workspace-write\",\"cwd\":\"$probe_dir\"}}}"
    sleep 30
  } | $TIMEOUT_CMD 50 $SERVER --provider codex >"$output_file" 2>/dev/null
  status=$?
  set -e
  RESPONSE=$(cat "$output_file")
  rm -f "$output_file"

  if [ -f "$probe_file" ]; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (probe file not created — per-call sandbox/cwd did not grant writes)"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$probe_dir"
}

test_provider_shutdown_kills_child "stdin shutdown kills detached claude child"

# Stub-based codex filtering tests (fast — no real codex needed)
test_codex_strips_only_model_effort "codex strips model/effort, keeps sandbox/cwd/approval"
test_codex_passes_through_unmodified "codex forwards no-strip tools/call byte-for-byte"

if [ "${SKIP_INTEGRATION:-}" = "1" ]; then
  echo ""
  echo "(Skipping integration tests — SKIP_INTEGRATION=1)"
else
  test_connectivity "call claude (connectivity)" "claude" "claude_code" 30
  test_connectivity "call gemini (connectivity)" "gemini" "gemini"     30
  test_codex_passthrough "codex passthrough (tools/list)"
  test_codex_isolated_runtime "codex passthrough (isolated runtime)"
  test_codex_percall_write "codex per-call workspace-write grants writes"
fi

# ---------- Summary ----------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
