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
TEST_CHILD_REGISTRY=$(mktemp)
export MCP_AGENTS_TEST_CHILD_REGISTRY="$TEST_CHILD_REGISTRY"

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }

terminate_test_child() {
  local pid="${1:-}"
  [ -n "$pid" ] || return 0
  kill -0 "$pid" 2>/dev/null || return 0
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 20); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.05
  done
  kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
}

cleanup_registered_test_children() {
  [ -f "$TEST_CHILD_REGISTRY" ] || return 0
  while IFS= read -r pid; do terminate_test_child "$pid"; done < "$TEST_CHILD_REGISTRY"
}

on_test_exit() {
  local status=$?
  trap - EXIT
  cleanup_registered_test_children
  rm -f "$TEST_CHILD_REGISTRY"
  exit "$status"
}
trap on_test_exit EXIT

# ── Helper: run tools/list with a given --provider and check for expected tool ──
test_tools_list() {
  local label="$1"
  local provider="$2"
  local expected_tool="$3"
  local expected_timeout="${4:-}"
  local timeout_override="${5:-}"
  local server_command=(node server.js --provider "$provider")
  local output_file
  local status

  if [ -n "$timeout_override" ]; then
    server_command+=(--timeout "$timeout_override")
  fi

  echo "--- $label ---"

  output_file=$(mktemp)
  set +e
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
    sleep 1
  } | $TIMEOUT_CMD 10 "${server_command[@]}" >"$output_file" 2>/dev/null
  status=$?
  set -e
  RESPONSE=$(cat "$output_file")
  rm -f "$output_file"

  if [ "$status" -ne 0 ]; then
    red "FAIL: $label (exit $status)"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  elif echo "$RESPONSE" | jq -e \
    --arg tool "$expected_tool" \
    --arg timeout "$expected_timeout" \
    '.result.tools[] | select(.name == $tool) |
      if $timeout == "" then true
      else (.inputSchema.properties.timeout_ms.description | contains($timeout))
      end' >/dev/null 2>&1; then
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
    # A well-formed MCP result whose text isn't a short "OK" usually means the
    # provider CLI's JSON output shape changed and the wrapper fell back to the
    # raw blob — flag it so drift is obvious, not mysterious.
    if echo "$RESPONSE" | jq -e 'select(.id == 2) | .result.content[0].text | type == "string"' >/dev/null 2>&1; then
      echo "  ⚠ could not extract a clean answer (possible JSON shape drift or model noncompliance)"
    fi
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
test_cli_flag "--help shows GPT-5.6 SOL default" "--help" "gpt-5.6-sol"
test_cli_flag "--help shows xhigh default"  "--help"    "xhigh"
test_cli_flag "--help shows workspace-write default" "--help" "workspace-write"
test_cli_flag "--help shows never default"  "--help"    "never"
test_cli_flag "--help shows codex_idle_timeout" "--help" "codex_idle_timeout"
test_cli_flag "--help shows goal flag"      "--help"    "Persistent objective"
test_cli_flag "--help shows provider timeout defaults" "--help" "claude 900, gemini 300"
test_cli_flag "-h prints usage"             "-h"        "Usage:"
test_cli_flag "--version prints version"    "--version"  "mcp-agents v"
test_cli_flag "-v prints version"           "-v"        "mcp-agents v"
test_cli_error "--bogus exits with error"   "--bogus"   "unknown option"
test_cli_error "--provider without value"                  "--provider"                 "requires a value"
test_cli_error "--model without value"                     "--model"                    "requires a value"
test_cli_error "--model_reasoning_effort without value"    "--model_reasoning_effort"   "requires a value"
test_cli_error "--sandbox_mode without value"              "--sandbox_mode"             "requires a value"
test_cli_error "--approval_policy without value"           "--approval_policy"          "requires a value"
test_cli_error "--goal without value"                      "--goal"                     "requires a value"
test_cli_error "--timeout without value"                    "--timeout"                  "requires a value"
test_cli_error "--timeout with zero"                        "--timeout 0"                "must be a positive number"
test_cli_error "--timeout with negative"                    "--timeout -5"               "must be a positive number"
test_cli_error "--timeout with non-number"                  "--timeout abc"              "must be a positive number"
test_cli_error "--codex_idle_timeout without value"         "--codex_idle_timeout"       "requires a value"
test_cli_error "--codex_idle_timeout non-number"            "--codex_idle_timeout abc"   "non-negative number"
test_cli_error "--codex_idle_timeout negative"              "--codex_idle_timeout -1"    "non-negative number"

# ========== Protocol tests (fast) ==========

# ---------- Ping (all providers) ----------
for p in claude gemini; do
  test_tools_list "tools/list --provider $p → ping" "$p" "ping"
done

# ---------- Claude provider ----------
test_tools_list "tools/list --provider claude → claude_code (900s default)" \
  "claude" "claude_code" "900000"
test_tools_list "tools/list --provider claude honors --timeout override" \
  "claude" "claude_code" "7000" "7"
test_handshake  "handshake --provider claude → claude_code"  "claude" "claude_code"

# ---------- Gemini provider ----------
test_tools_list "tools/list --provider gemini → gemini (300s default)" \
  "gemini" "gemini" "300000"
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
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"codex","arguments":{"prompt":"Reply with ONLY OK","sandbox":"read-only","model_reasoning_effort":"max"}}}'
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
  elif ! echo "$RESPONSE" | grep -q '"reasoning_effort":"max"'; then
    red "FAIL: $label (missing per-session max effort)"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  elif echo "$RESPONSE" | grep -q '"server":"codex_apps"'; then
    red "FAIL: $label (codex_apps started despite features.apps=false)"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  elif echo "$RESPONSE" | grep -Eq '"server":"(claude-code|local-claude-test|local-gemini-test|chrome-devtools|context7|aws-knowledge-mcp-server|openaiDeveloperDocs|google-dev-knowledge|github-knowledge-mcp-server)"'; then
    red "FAIL: $label (inherited MCP server started)"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  elif ! echo "$RESPONSE" | jq -e 'select(.id == 2) | .result.structuredContent.content == "OK"' >/dev/null 2>&1; then
    red "FAIL: $label (codex MCP result shape unexpected — output format may have changed)"
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
printf '%s\n' "$$" >> "$MCP_AGENTS_TEST_CHILD_REGISTRY"
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
    terminate_test_child "$(cat "$pid_file" 2>/dev/null || true)"
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
    terminate_test_child "$(cat "$pid_file" 2>/dev/null || true)"
    rm -rf "$tmpdir"
    return
  fi

  child_pid=$(cat "$pid_file")
  sleep 0.5

  if kill -0 "$child_pid" 2>/dev/null; then
    red "FAIL: $label (child still running: $child_pid)"
    FAIL=$((FAIL + 1))
    terminate_test_child "$child_pid"
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
printf '%s\n' "$$" >> "$MCP_AGENTS_TEST_CHILD_REGISTRY"
# Stub codex mcp-server: echo each received stdin line into the capture file.
# `|| [ -n "$line" ]` also captures a final line with no trailing newline
# (exercises the wrapper's end-of-stdin partial-frame path).
while IFS= read -r line || [ -n "$line" ]; do
  printf '%s\n' "$line" >> "$MCP_AGENTS_TEST_CAPTURE"
done
EOF
  chmod +x "$1/codex"
}

# ── Helper: stub `codex` that snapshots the generated isolated config ──
# before the wrapper cleans up the temporary CODEX_HOME.
write_codex_config_stub() {
  cat >"$1/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$MCP_AGENTS_TEST_CHILD_REGISTRY"
cp "$CODEX_HOME/config.toml" "$MCP_AGENTS_TEST_CONFIG_CAPTURE"
while IFS= read -r _line; do :; done
EOF
  chmod +x "$1/codex"
}

# ── Helper: stub `codex` that simulates auth rotation and creates the stale ──
# PID-named temp file used by the old write-back implementation.
write_codex_auth_rotation_stub() {
  cat >"$1/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$MCP_AGENTS_TEST_CHILD_REGISTRY"
stale="$MCP_AGENTS_TEST_REAL_CODEX_HOME/.auth.json.mcp-agents-${PPID}.tmp"
printf '%s' '{"token":"stale"}' > "$stale"
chmod 0644 "$stale"
printf '%s' '{"token":"rotated"}' > "$CODEX_HOME/auth.json"
while IFS= read -r _line; do :; done
EOF
  chmod +x "$1/codex"
}

# ── Helper: verify the generated isolated Codex config is intentionally lean ──
test_codex_bridge_config_defaults() {
  local label="$1"
  local tmpdir config_capture output_file status expected ok

  echo "--- $label ---"

  tmpdir=$(mktemp -d)
  config_capture="$tmpdir/config.toml"
  output_file="$tmpdir/output.txt"
  write_codex_config_stub "$tmpdir"

  set +e
  {
    sleep 0.2
  } | PATH="$tmpdir:$PATH" MCP_AGENTS_TEST_CONFIG_CAPTURE="$config_capture" \
    $TIMEOUT_CMD 10 $SERVER --provider codex >"$output_file" 2>/dev/null
  status=$?
  set -e

  ok=1
  [ "$status" -eq 0 ] || ok=0
  for expected in \
    'model = "gpt-5.6-sol"' \
    'model_reasoning_effort = "xhigh"' \
    'web_search = "cached"' \
    'check_for_update_on_startup = false' \
    'allow_login_shell = false' \
    '[history]' \
    'persistence = "none"' \
    '[features]' \
    'apps = false' \
    'hooks = false' \
    'plugins = false' \
    'multi_agent = false' \
    'skill_mcp_dependency_install = false'
  do
    grep -Fxq "$expected" "$config_capture" 2>/dev/null || ok=0
  done

  if [ "$ok" -eq 1 ]; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (status=$status)"
    echo "  Config:"
    sed 's/^/    /' "$config_capture" 2>/dev/null || true
    echo "  Output: $(cat "$output_file")"
    FAIL=$((FAIL + 1))
  fi

  rm -rf "$tmpdir"
}

# ── Helper: verify rotated auth write-back does not reuse stale broad-mode temp files ──
test_codex_auth_persistence_secure_temp() {
  local label="$1"
  local tmpdir real_home output_file status content mode ok

  echo "--- $label ---"

  tmpdir=$(mktemp -d)
  real_home="$tmpdir/real-codex"
  output_file="$tmpdir/output.txt"
  mkdir "$real_home"
  printf '%s' '{"token":"original"}' > "$real_home/auth.json"
  chmod 0644 "$real_home/auth.json"
  write_codex_auth_rotation_stub "$tmpdir"

  set +e
  {
    sleep 0.2
  } | PATH="$tmpdir:$PATH" CODEX_HOME="$real_home" MCP_AGENTS_TEST_REAL_CODEX_HOME="$real_home" \
    $TIMEOUT_CMD 10 $SERVER --provider codex >"$output_file" 2>/dev/null
  status=$?
  set -e

  content=$(cat "$real_home/auth.json" 2>/dev/null || true)
  mode=$(stat -f '%Lp' "$real_home/auth.json" 2>/dev/null || stat -c '%a' "$real_home/auth.json" 2>/dev/null || true)
  ok=1
  [ "$status" -eq 0 ] || ok=0
  [ "$content" = '{"token":"rotated"}' ] || ok=0
  [ "$mode" = "600" ] || ok=0

  if [ "$ok" -eq 1 ]; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (status=$status mode=${mode:-<missing>})"
    echo "  auth.json: $content"
    echo "  Output: $(cat "$output_file")"
    FAIL=$((FAIL + 1))
  fi

  rm -rf "$tmpdir"
}

# ── Helper: node stub `codex` mcp-server for the watchdog tests. Answers ──
# initialize, emits one event for tools/call, then per MCP_STUB_MODE either
# stalls (stays silent → exercises the idle watchdog) or dies (process.exit →
# exercises the child-death path). No real codex needed.
write_codex_watchdog_stub() {
  cat >"$1/codex" <<'EOF'
#!/usr/bin/env node
const MODE = process.env.MCP_STUB_MODE || "stall";
require("fs").appendFileSync(process.env.MCP_AGENTS_TEST_CHILD_REGISTRY, `${process.pid}\n`);
// Record our pid so the test can assert the wrapper actually killed us on
// teardown (no orphaned stalled codex), mirroring the claude shutdown test.
if (process.env.MCP_AGENTS_TEST_PID_FILE) {
  try { require("fs").writeFileSync(process.env.MCP_AGENTS_TEST_PID_FILE, String(process.pid)); } catch {}
}
let buf = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (d) => {
  buf += d;
  let nl;
  while ((nl = buf.indexOf("\n")) !== -1) {
    const line = buf.slice(0, nl); buf = buf.slice(nl + 1);
    let m; try { m = JSON.parse(line); } catch { continue; }
    if (m.method === "initialize") {
      process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: m.id, result: { protocolVersion: "2024-11-05", capabilities: {}, serverInfo: { name: "stub", version: "0" } } }) + "\n");
    } else if (m.method === "tools/call") {
      process.stdout.write(JSON.stringify({ jsonrpc: "2.0", method: "codex/event", params: { msg: "working" } }) + "\n");
      if (MODE === "die") process.exit(0); // codex dies without responding
      // stall: emit nothing further → idle watchdog must fire
    }
  }
});
setInterval(() => {}, 1 << 30);
EOF
  chmod +x "$1/codex"
}

# ── Helper: drive initialize + tools/call(id:2) at a stub codex, asserting the ──
# wrapper synthesizes a JSON-RPC -32001 error for the open id:2 (no hang).
#   $1 label, $2 MCP_STUB_MODE (stall|die), $3 extra server args
run_codex_watchdog_case() {
  local label="$1" mode="$2" extra="$3" expected_status="$4"
  local tmpdir output_file pid_file status RESPONSE child_pid
  local resp_ok=0 child_ok=0
  echo "--- $label ---"

  tmpdir=$(mktemp -d)
  output_file="$tmpdir/out.txt"
  pid_file="$tmpdir/codex.pid"
  write_codex_watchdog_stub "$tmpdir"

  set +e
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"codex","arguments":{"prompt":"hi"}}}'
    sleep 4
  } | PATH="$tmpdir:$PATH" MCP_STUB_MODE="$mode" MCP_AGENTS_TEST_PID_FILE="$pid_file" \
    $TIMEOUT_CMD 12 $SERVER --provider codex $extra >"$output_file" 2>/dev/null
  status=$?
  set -e
  RESPONSE=$(cat "$output_file")
  child_pid=$(cat "$pid_file" 2>/dev/null || true)
  sleep 0.3 # allow the group SIGKILL to take effect before the liveness check

  # The wrapper must surface for the still-open id:2 EXACTLY one error frame
  # that is the -32001 idle/teardown error, and NO result frame for it (no
  # double-respond, no malformed result+error frame), and it must NOT have
  # errored the already-answered id:1.
  if echo "$RESPONSE" | jq -se '
      (map(select(.id == 1 and has("error"))) | length == 0) and
      (map(select(.id == 2 and has("result"))) | length == 0) and
      (map(select(.id == 2 and has("error"))) | length == 1) and
      (map(select(.id == 2 and (.error.code? == -32001))) | length == 1)
    ' >/dev/null 2>&1; then
    resp_ok=1
  fi
  # The wrapper must also tear codex down (no orphaned stalled child).
  if [ -n "$child_pid" ] && ! kill -0 "$child_pid" 2>/dev/null; then
    child_ok=1
  fi

  # Exact exit code, not just "not a timeout": stall tears down via the idle
  # watchdog (exit 1); die exits with codex's own clean code (0). A different
  # code means an unexpected crash.
  if [ "$status" -eq "$expected_status" ] && [ "$resp_ok" -eq 1 ] && [ "$child_ok" -eq 1 ]; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (status=$status want=$expected_status resp_ok=$resp_ok child_ok=$child_ok)"
    echo "  Response: $RESPONSE"
    if [ "$child_ok" -ne 1 ]; then
      echo "  codex stub still alive (orphan): ${child_pid:-<no pid>}"
      terminate_test_child "$child_pid"
    fi
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$tmpdir"
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

# ── Helper: drive one tools/call (with the given `arguments` JSON) through a ──
# capture-stub codex under the given server args, then assert a jq predicate
# over the forwarded call's parsed JSON-RPC message. Proves wrapper-only arg
# sanitization/translation without needing a real Codex session.
#   $1 label, $2 extra server args, $3 arguments JSON, $4 jq predicate,
#   $5 tool name (optional, default "codex")
test_codex_call_transform() {
  local label="$1" server_args="$2" arguments_json="$3" predicate="$4"
  local tool_name="${5:-codex}"
  local tmpdir capture output_file status call_line
  echo "--- $label ---"

  tmpdir=$(mktemp -d)
  capture="$tmpdir/codex_stdin.txt"
  output_file="$tmpdir/output.txt"
  : >"$capture"
  write_codex_capture_stub "$tmpdir"

  set +e
  {
    printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$tool_name\",\"arguments\":$arguments_json}}"
    sleep 0.5
  } | PATH="$tmpdir:$PATH" MCP_AGENTS_TEST_CAPTURE="$capture" \
    $TIMEOUT_CMD 10 $SERVER --provider codex $server_args >"$output_file" 2>/dev/null
  status=$?
  set -e

  call_line=$(grep '"method":"tools/call"' "$capture" 2>/dev/null | tail -1)
  if [ "$status" -eq 0 ] && [ -n "$call_line" ] && \
     echo "$call_line" | jq -e "$predicate" >/dev/null 2>&1; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (status=$status)"
    echo "  Forwarded: $call_line"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$tmpdir"
}

# ── Helper: a per-call sandbox=workspace-write + absolute cwd actually grants ──
# writes end-to-end (real codex). Proves the read-only symptom is fixed.
test_codex_percall_write() {
  local label="$1"
  local probe_dir probe_file output_file status RESPONSE shape_ok
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

  # Two independent checks: the file proves per-call sandbox/cwd granted writes,
  # and the live JSON-shape assertion verifies codex's MCP result envelope still
  # matches what the bridge depends on (so codex output-format drift is caught).
  shape_ok=0
  if echo "$RESPONSE" | jq -e 'select(.id == 2) | (.result.isError != true) and (.result.structuredContent.content | type == "string")' >/dev/null 2>&1; then
    shape_ok=1
  fi

  if [ "$status" -eq 0 ] && [ -f "$probe_file" ] && [ "$shape_ok" -eq 1 ]; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label"
    [ "$status" -eq 0 ] || echo "  server exited non-zero ($status)"
    [ -f "$probe_file" ] || echo "  probe file not created — per-call sandbox/cwd did not grant writes"
    [ "$shape_ok" -eq 1 ] || echo "  ⚠ codex MCP result shape unexpected — output format may have changed"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$probe_dir"
}

# ── Helper: node stub `codex` mcp-server for tools/list schema-rewrite ──
# tests. Answers initialize, then on tools/list emits a result with codex +
# codex-reply tools (real schema shapes) per MCP_STUB_TLMODE — exercising the
# wrapper's contained-latch rewrite paths. No real codex needed.
write_codex_toolslist_stub() {
  cat >"$1/codex" <<'EOF'
#!/usr/bin/env node
const MODE = process.env.MCP_STUB_TLMODE || "normal";
require("fs").appendFileSync(process.env.MCP_AGENTS_TEST_CHILD_REGISTRY, `${process.pid}\n`);
const SENTINEL = '{"jsonrpc":"2.0","method":"codex/event","params":{"marker":"PASSTHROUGH_SENTINEL"}}';
const STRADDLE = '{"jsonrpc":"2.0","method":"codex/event","params":{"marker":"STRADDLE_SENTINEL"}}';
const STRADDLE_HEAD = STRADDLE.slice(0, 40);   // emitted on initialize, NO newline (orphan head)
const STRADDLE_TAIL = STRADDLE.slice(40);      // emitted on tools/list, completes the frame
function tools(withGoal, withEffort) {
  const codex = { name: "codex", inputSchema: { type: "object", additionalProperties: false, required: ["prompt"], properties: { prompt: { type: "string" }, "developer-instructions": { type: "string" }, "base-instructions": { type: "string" } } } };
  if (withGoal) codex.inputSchema.properties.goal = { type: "string", description: "STUB_OWN_GOAL_DESC" };
  const reply = { name: "codex-reply", inputSchema: { type: "object", required: ["prompt"], properties: { conversationId: { type: "string" }, threadId: { type: "string" }, prompt: { type: "string" } } } };
  if (withEffort) {
    const drifted = { type: "string", enum: ["low", "xhigh", "max", "ultra"], description: "STUB_DRIFTED_EFFORT_DESC" };
    codex.inputSchema.properties.model_reasoning_effort = { ...drifted };
    reply.inputSchema.properties.model_reasoning_effort = { ...drifted };
  }
  return [codex, reply];
}
const resultLine = (id, withGoal, withEffort = false) => JSON.stringify({ jsonrpc: "2.0", id, result: { tools: tools(withGoal, withEffort) } });
function onToolsList(id) {
  if (MODE === "havegoal") { process.stdout.write(resultLine(id, true) + "\n"); return; }
  if (MODE === "haveeffort") { process.stdout.write(resultLine(id, false, true) + "\n"); return; }
  if (MODE === "noctools") { process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result: { tools: [{ name: "ping", inputSchema: { type: "object", properties: {} } }] } }) + "\n"); return; }
  if (MODE === "error") { process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, error: { code: -32601, message: "no" } }) + "\n"); return; }
  if (MODE === "interleaved") { process.stdout.write(SENTINEL + "\n"); process.stdout.write(resultLine(id, false) + "\n"); return; }
  if (MODE === "split") { const s = resultLine(id, false); const cut = Math.floor(s.length / 2); process.stdout.write(s.slice(0, cut)); setTimeout(() => process.stdout.write(s.slice(cut) + "\n"), 40); return; }
  if (MODE === "straddle") { process.stdout.write(STRADDLE_TAIL + "\n"); process.stdout.write(resultLine(id, false) + "\n"); return; }
  if (MODE === "partialdie") { const s = resultLine(id, false); process.stdout.write(s.slice(0, Math.floor(s.length / 2)), () => process.exit(0)); return; }
  if (MODE === "nonewlinedie") { process.stdout.write(resultLine(id, false), () => process.exit(0)); return; }
  if (MODE === "bp") { process.stdout.write(JSON.stringify({ jsonrpc: "2.0", method: "codex/event", params: { pad: "x".repeat(200000) } }) + "\n"); process.stdout.write(resultLine(id, false) + "\n"); return; }
  if (MODE === "trailpartialdie") { process.stdout.write(resultLine(id, false) + '\n{"jsonrpc":"2.0","method":"codex/event","params":{"marker":"TRAILING_HEAD', () => process.exit(0)); return; } // result + a NON-tools/list partial head (no newline) then die
  if (MODE === "cancelpartial") { process.stdout.write('{"jsonrpc":"2.0","method":"codex/event","params":{"marker":"CANCEL_PARTIAL'); setTimeout(() => process.exit(0), 900); return; } // a withheld NON-tools/list partial; the driver cancels the tools/list, then we die
  if (MODE === "oversized") { const big = JSON.stringify({ jsonrpc: "2.0", method: "codex/event", params: { marker: "OVERSIZED_MARKER", pad: "x".repeat(11 * 1024 * 1024) } }); process.stdout.write(big + "\n"); process.stdout.write(resultLine(id, false) + "\n", () => setTimeout(() => process.exit(0), 100)); return; }
  process.stdout.write(resultLine(id, false) + "\n"); // normal
}
let buf = "";
let exitTimer;
process.stdin.setEncoding("utf8");
process.stdin.on("data", (d) => {
  buf += d;
  let nl;
  while ((nl = buf.indexOf("\n")) !== -1) {
    const line = buf.slice(0, nl); buf = buf.slice(nl + 1);
    let m; try { m = JSON.parse(line); } catch { continue; }
    if (m.method === "initialize") {
      process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: m.id, result: { protocolVersion: "2024-11-05", capabilities: {}, serverInfo: { name: "stub", version: "0" } } }) + "\n");
      if (MODE === "straddle") process.stdout.write(STRADDLE_HEAD); // orphan head, no newline -> wire mid-frame
    } else if (m.method === "tools/list") {
      onToolsList(m.id);
      // Exit shortly after the LAST response so the wrapper (which waits on codex)
      // can shut down cleanly — the response was already observed, so finalize
      // synthesizes no -32001. partialdie/nonewlinedie self-exit; bp is driver-killed.
      if (MODE !== "partialdie" && MODE !== "nonewlinedie" && MODE !== "bp" && MODE !== "trailpartialdie" && MODE !== "oversized" && MODE !== "cancelpartial") {
        clearTimeout(exitTimer);
        exitTimer = setTimeout(() => process.exit(0), 500);
      }
    }
  }
});
process.stdin.on("end", () => process.exit(0));
setInterval(() => {}, 1 << 30);
EOF
  chmod +x "$1/codex"
}

# ── Helper: drive initialize + tools/list(id:2) at the stub under MCP_STUB_TLMODE ──
# and assert a jq predicate over the wrapper's stdout (plus an optional byte-for-byte grep).
#   $1 label, $2 stub mode, $3 jq predicate, $4 optional grep -F string
test_codex_toolslist_rewrite() {
  local label="$1" mode="$2" predicate="$3" grep_str="${4:-}"
  local tmpdir output_file status RESPONSE ok
  echo "--- $label ---"
  tmpdir=$(mktemp -d)
  output_file="$tmpdir/out.txt"
  write_codex_toolslist_stub "$tmpdir"
  set +e
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
    sleep 1.5
  } | PATH="$tmpdir:$PATH" MCP_STUB_TLMODE="$mode" \
    $TIMEOUT_CMD 12 $SERVER --provider codex >"$output_file" 2>/dev/null
  status=$?
  set -e
  RESPONSE=$(cat "$output_file")
  ok=1
  [ "$status" -eq 0 ] || ok=0
  echo "$RESPONSE" | jq -e "$predicate" >/dev/null 2>&1 || ok=0
  if [ -n "$grep_str" ]; then printf '%s' "$RESPONSE" | grep -Fq "$grep_str" || ok=0; fi
  if [ "$ok" -eq 1 ]; then green "PASS: $label"; PASS=$((PASS + 1)); else
    red "FAIL: $label (status=$status)"; echo "  Response: $RESPONSE"; FAIL=$((FAIL + 1)); fi
  rm -rf "$tmpdir"
}

# ── Helper: two tools/list calls (id:2, id:3) in one session — both rewritten ──
# (latch re-entry).
test_codex_toolslist_reentry() {
  local label="$1" tmpdir output_file status RESPONSE ok
  echo "--- $label ---"
  tmpdir=$(mktemp -d)
  output_file="$tmpdir/out.txt"
  write_codex_toolslist_stub "$tmpdir"
  set +e
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
    sleep 0.2
    printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}'
    sleep 1
  } | PATH="$tmpdir:$PATH" MCP_STUB_TLMODE="normal" \
    $TIMEOUT_CMD 12 $SERVER --provider codex >"$output_file" 2>/dev/null
  status=$?
  set -e
  RESPONSE=$(cat "$output_file")
  ok=1
  [ "$status" -eq 0 ] || ok=0
  echo "$RESPONSE" | jq -e 'select(.id==2) | (.result.tools|map(select(.name=="codex"))[0].inputSchema.properties.goal.type=="string")' >/dev/null 2>&1 || ok=0
  echo "$RESPONSE" | jq -e 'select(.id==3) | (.result.tools|map(select(.name=="codex"))[0].inputSchema.properties.goal.type=="string")' >/dev/null 2>&1 || ok=0
  if [ "$ok" -eq 1 ]; then green "PASS: $label"; PASS=$((PASS + 1)); else
    red "FAIL: $label (status=$status)"; echo "  Response: $RESPONSE"; FAIL=$((FAIL + 1)); fi
  rm -rf "$tmpdir"
}

# ── Helper: backpressure regression (Finding 1). A node driver pauses reading ──
# the wrapper's stdout so a large stub burst backpressures it, then resumes and
# asserts BOTH tools/list results survive (no complete frame stranded).
test_codex_toolslist_backpressure() {
  local label="$1" tmpdir status out
  echo "--- $label ---"
  tmpdir=$(mktemp -d)
  write_codex_toolslist_stub "$tmpdir"
  cat >"$tmpdir/driver.mjs" <<'EOF'
import { spawn } from "node:child_process";
const stubDir = process.argv[2], serverDir = process.argv[3];
const child = spawn("node", ["server.js", "--provider", "codex"], {
  cwd: serverDir,
  env: { ...process.env, PATH: stubDir + ":" + process.env.PATH, MCP_STUB_TLMODE: "bp" },
  stdio: ["pipe", "pipe", "pipe"],
});
let out = "";
let err = "";
child.stdout.pause();                                   // induce backpressure: stop reading
child.stdout.on("data", (d) => { out += d.toString(); });
child.stdin.on("error", () => {});
child.stderr.on("data", (data) => { err += data.toString(); });
const send = (o) => { try { child.stdin.write(JSON.stringify(o) + "\n"); } catch {} };
send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "t", version: "0" } } });
setTimeout(() => send({ jsonrpc: "2.0", method: "notifications/initialized" }), 120);
setTimeout(() => { send({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} }); send({ jsonrpc: "2.0", id: 3, method: "tools/list", params: {} }); }, 240);
setTimeout(() => child.stdout.resume(), 800);           // stay paused while the stub bursts -> backpressure
setTimeout(() => {
  let ok2 = false, ok3 = false;
  for (const line of out.split("\n")) {
    if (!line.trim()) continue;
    let m; try { m = JSON.parse(line); } catch { continue; }
    const hasGoal = m.result?.tools?.find((t) => t.name === "codex")?.inputSchema?.properties?.goal?.type === "string";
    if (m.id === 2 && hasGoal) ok2 = true;
    if (m.id === 3 && hasGoal) ok3 = true;
  }
  const ok = ok2 && ok3;
  process.stdout.write(ok ? "BP_OK\n" : `BP_FAIL ok2=${ok2} ok3=${ok3}\n`);
  child.once("close", () => process.exit(ok ? 0 : 1));
  try { child.stdin.end(); } catch {}
  setTimeout(() => { try { child.kill("SIGTERM"); } catch {} }, 1000);
}, 1800);
process.once("SIGTERM", () => {
  child.once("close", () => process.exit(124));
  try { child.kill("SIGTERM"); } catch {}
});
EOF
  set +e
  out=$($TIMEOUT_CMD 15 node "$tmpdir/driver.mjs" "$tmpdir" "$(pwd)" 2>/dev/null)
  status=$?
  set -e
  if [ "$status" -eq 0 ] && printf '%s' "$out" | grep -Fq "BP_OK"; then
    green "PASS: $label"; PASS=$((PASS + 1)); else
    red "FAIL: $label (status=$status, out=$out)"; FAIL=$((FAIL + 1)); fi
  rm -rf "$tmpdir"
}

# ── Helper: like test_codex_toolslist_rewrite but reads the captured FILE ──
# tolerates an unparseable trailing partial or a multi-MB frame: it extracts the
# id:2 result line for jq and greps the file for a marker.
#   $1 label, $2 mode, $3 jq predicate over the id:2 result line, $4 grep -F marker
test_codex_toolslist_file() {
  local label="$1" mode="$2" predicate="$3" grep_str="$4"
  local tmpdir output_file status idline ok
  echo "--- $label ---"
  tmpdir=$(mktemp -d)
  output_file="$tmpdir/out.txt"
  write_codex_toolslist_stub "$tmpdir"
  set +e
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
    sleep 1.5
  } | PATH="$tmpdir:$PATH" MCP_STUB_TLMODE="$mode" \
    $TIMEOUT_CMD 25 $SERVER --provider codex >"$output_file" 2>/dev/null
  status=$?
  set -e
  ok=1
  [ "$status" -eq 0 ] || ok=0
  idline=$(grep -F '"id":2,' "$output_file" 2>/dev/null | tail -1)
  printf '%s' "$idline" | jq -e "$predicate" >/dev/null 2>&1 || ok=0
  if [ -n "$grep_str" ]; then grep -Fq "$grep_str" "$output_file" || ok=0; fi
  if [ "$ok" -eq 1 ]; then green "PASS: $label"; PASS=$((PASS + 1)); else
    red "FAIL: $label (status=$status)"; echo "  idline: ${idline:0:200}"; FAIL=$((FAIL + 1)); fi
  rm -rf "$tmpdir"
}

# ── Helper: cancel a tools/list while a NON-tools/list partial is withheld in ──
# buffer mode, then let codex die — the partial must be forwarded raw on the
# cancel (return-to-raw), not byte-lost at finalize.
test_codex_toolslist_cancel() {
  local label="$1" tmpdir output_file status ok
  echo "--- $label ---"
  tmpdir=$(mktemp -d)
  output_file="$tmpdir/out.txt"
  write_codex_toolslist_stub "$tmpdir"
  set +e
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
    sleep 0.4
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2}}'
    sleep 1.2
  } | PATH="$tmpdir:$PATH" MCP_STUB_TLMODE="cancelpartial" \
    $TIMEOUT_CMD 12 $SERVER --provider codex >"$output_file" 2>/dev/null
  status=$?
  set -e
  ok=1
  [ "$status" -eq 0 ] || ok=0
  grep -Fq "CANCEL_PARTIAL" "$output_file" || ok=0
  if [ "$ok" -eq 1 ]; then green "PASS: $label"; PASS=$((PASS + 1)); else
    red "FAIL: $label (status=$status)"; echo "  out: $(cat "$output_file")"; FAIL=$((FAIL + 1)); fi
  rm -rf "$tmpdir"
}

# ── Helper: Codex lifecycle stub for per-request liveness/recovery tests. ──
write_codex_lifecycle_stub() {
  cat >"$1/codex" <<'EOF'
#!/usr/bin/env node
const fs = require("fs");
const mode = process.env.MCP_STUB_LIFECYCLE_MODE;
fs.appendFileSync(process.env.MCP_AGENTS_TEST_CHILD_REGISTRY, `${process.pid}\n`);
fs.writeFileSync(process.env.MCP_AGENTS_TEST_PID_FILE, String(process.pid));

const timers = [];
const threadId = (id) => `00000000-0000-4000-8000-${String(id).padStart(12, "0")}`;
const send = (message, callback) => process.stdout.write(`${JSON.stringify(message)}\n`, callback);
const eventMessage = (requestId, type, extra = {}) => ({
  jsonrpc: "2.0",
  method: "codex/event",
  params: {
    _meta: { requestId, threadId: threadId(requestId) },
    id: `event-${requestId}-${type}`,
    msg: { type, ...extra },
  },
});
const event = (requestId, type, extra = {}, callback) =>
  send(eventMessage(requestId, type, extra), callback);
const result = (id, content) => send({
  jsonrpc: "2.0",
  id,
  result: {
    content: [{ type: "text", text: content }],
    structuredContent: { threadId: threadId(id), content },
  },
});
const later = (delay, fn) => timers.push(setTimeout(fn, delay));
const every = (delay, fn) => timers.push(setInterval(fn, delay));

function startCall(id) {
  event(id, "session_configured", { thread_id: threadId(id) });
  switch (mode) {
    case "stderr":
      every(30, () => process.stderr.write("still noisy\n"));
      break;
    case "unrelated":
      every(30, () => event(999, "agent_message_content_delta", { delta: "noise" }));
      break;
    case "progress":
      event(id, "item_started", { item: { type: "AgentMessage", id: `commentary-${id}`, phase: "commentary" } });
      for (const delay of [100, 200, 300, 400, 500, 600, 700]) {
        later(delay, () => event(id, "agent_message_content_delta", { item_id: `commentary-${id}`, delta: "." }));
      }
      later(780, () => result(id, `PROGRESS_${id}`));
      break;
    case "tokens":
      event(id, "task_started");
      later(100, () => result(id, `TOKEN_${id}`));
      break;
    case "visibility": {
      event(id, "item_started", { item: { type: "AgentMessage", id: "commentary-safe", phase: "commentary" } });
      later(20, () => event(id, "agent_message_content_delta", { item_id: "commentary-safe", delta: "Working\n on \u0000 tests 🚀" }));
      later(40, () => event(id, "item_started", { item: { type: "AgentMessage", id: "final-secret", phase: "final_answer" } }));
      later(50, () => event(id, "agent_message_content_delta", { item_id: "final-secret", delta: "SENTINEL_FINAL" }));
      later(60, () => event(id, "agent_message_content_delta", { item_id: "unknown", delta: "SENTINEL_UNKNOWN" }));
      later(70, () => event(id, "agent_message", { phase: "final_answer", message: "SENTINEL_FINAL_COMPLETE" }));
      later(80, () => event(id, "agent_message", { message: "SENTINEL_PHASELESS" }));
      later(90, () => event(id, "item_started", { item: { type: "agent_message", id: "wrong-case", phase: "commentary" } }));
      later(95, () => event(id, "agent_message_content_delta", { item_id: "wrong-case", delta: "SENTINEL_WRONG_TYPE" }));
      later(100, () => event(id, "plan_update", { plan: [{ step: "Verify bridge", status: "in_progress" }] }));
      later(150, () => event(id, "exec_command_begin", { command: "SENTINEL_COMMAND" }));
      later(200, () => event(id, "exec_command_end", { exit_code: 7, output: "SENTINEL_OUTPUT" }));
      later(250, () => event(id, "patch_apply_begin", { changes: { "/SENTINEL_PATH_A": {}, "/SENTINEL_PATH_B": {} } }));
      later(300, () => event(id, "mcp_tool_call_begin", { invocation: { server: "safe-server", tool: "safe-tool", arguments: { secret: "SENTINEL_ARGUMENT" } } }));
      later(350, () => event(id, "web_search_end", { query: "SENTINEL_QUERY" }));
      later(400, () => event(id, "raw_response_item", { prompt: "SENTINEL_PROMPT", reasoning: "SENTINEL_REASONING" }));
      later(420, () => event(id, "item_completed", { item: { type: "AgentMessage", id: "completed-safe", phase: "commentary", content: [{ type: "Text", text: "Completed commentary" }] } }));
      later(440, () => event(id, "item_completed", { item: { type: "AgentMessage", id: "completed-final", phase: "final_answer", content: [{ type: "Text", text: "SENTINEL_COMPLETED_FINAL" }] } }));
      later(470, () => event(id, "agent_message", { phase: "commentary", message: "🚀".repeat(250) }));
      later(550, () => result(id, "VISIBLE"));
      break;
    }
    case "coalesce":
      event(id, "task_started");
      later(10, () => event(id, "exec_command_begin", { command: "SENTINEL_COALESCE" }));
      later(20, () => event(id, "plan_update", { plan: [{ step: "Old status", status: "in_progress" }] }));
      later(30, () => event(id, "plan_update", { plan: [{ step: "Latest status", status: "in_progress" }] }));
      later(40, () => event(id, "plan_update", { plan: [{ step: "Latest status", status: "in_progress" }] }));
      later(140, () => result(id, "COALESCED"));
      break;
    case "wait":
      later(650, () => event(id, "unknown_activity", { secret: "SENTINEL_WAIT" }));
      break;
    case "partial":
    case "partialstall": {
      const partial = JSON.stringify(eventMessage(id, "warning", { message: "SAFE" }));
      const splitAt = partial.length - 5;
      process.stdout.write(`${JSON.stringify(eventMessage(id, "task_started"))}\n${partial.slice(0, splitAt)}`);
      if (mode === "partial") {
        later(220, () => process.stdout.write(`${partial.slice(splitAt)}\n`));
        later(360, () => result(id, "PARTIAL"));
      }
      break;
    }
    case "settled":
      event(id, "task_started");
      later(40, () => result(id, "SETTLED"));
      later(120, () => event(id, "exec_command_begin", { command: "SENTINEL_LATE" }));
      break;
    case "terminalstop":
      event(id, "task_started");
      later(30, () => event(id, "task_complete", { last_agent_message: "DONE" }));
      later(100, () => event(id, "exec_command_begin", { command: "SENTINEL_TERMINAL" }));
      break;
    case "terminal":
      later(40, () => event(id, "task_complete", { last_agent_message: "DONE" }));
      break;
    case "terminalexit":
      later(40, () => event(id, "task_complete", { last_agent_message: "DONE" }, () => process.exit(0)));
      break;
    case "native":
      later(40, () => event(id, "turn_complete", { last_agent_message: "DONE" }));
      later(80, () => result(id, "NATIVE"));
      break;
    case "late":
      later(40, () => event(id, "task_complete", { last_agent_message: "DONE" }));
      later(220, () => result(id, "LATE"));
      break;
    case "reuse":
      later(40, () => event(id, "task_complete", { last_agent_message: "DONE" }));
      later(300, () => result(id, "LATE"));
      break;
    case "hard":
      event(id, "task_started");
      every(30, () => event(id, "exec_command_begin", { command: "SENTINEL_HARD" }));
      break;
    case "cancel":
      event(id, "task_started");
      every(30, () => event(id, "exec_command_begin", { command: "SENTINEL_CANCEL" }));
      break;
  }
}

let buf = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (data) => {
  buf += data;
  let newline;
  while ((newline = buf.indexOf("\n")) !== -1) {
    const line = buf.slice(0, newline); buf = buf.slice(newline + 1);
    let message; try { message = JSON.parse(line); } catch { continue; }
    if (message.method === "initialize") {
      send({ jsonrpc: "2.0", id: message.id, result: { protocolVersion: "2024-11-05", capabilities: {}, serverInfo: { name: "lifecycle-stub", version: "0" } } });
    } else if (message.method === "tools/call") {
      fs.appendFileSync(process.env.MCP_AGENTS_TEST_CALL_CAPTURE, `${JSON.stringify({ id: message.id, prompt: message.params?.arguments?.prompt })}\n`);
      startCall(message.id);
    } else if (message.method === "ping") {
      send({ jsonrpc: "2.0", id: message.id, result: {} });
    }
  }
});
process.stdin.on("end", () => process.exit(0));
setInterval(() => {}, 1 << 30);
EOF
  chmod +x "$1/codex"
}

# Drives one lifecycle mode and emits a single JSON summary for jq assertions.
write_codex_lifecycle_driver() {
  cat >"$1/driver.mjs" <<'EOF'
import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";

const [stubDir, serverDir, mode, idle, hard, settle, terminal, cancel, progressConfig] = process.argv.slice(2);
const [progress, wait = "10000"] = progressConfig.split(",");
const pidFile = `${stubDir}/codex.pid`;
const callFile = `${stubDir}/calls.jsonl`;
const started = Date.now();
const child = spawn("node", ["server.js", "--provider", "codex", "--codex_idle_timeout", idle, "--timeout", hard], {
  cwd: serverDir,
  env: {
    ...process.env,
    PATH: `${stubDir}:${process.env.PATH}`,
    MCP_STUB_LIFECYCLE_MODE: mode,
    MCP_AGENTS_TEST_PID_FILE: pidFile,
    MCP_AGENTS_TEST_CALL_CAPTURE: callFile,
    MCP_AGENTS_CODEX_TERMINAL_GRACE_MS: terminal,
    MCP_AGENTS_CODEX_CANCEL_GRACE_MS: cancel,
    MCP_AGENTS_CODEX_PROGRESS_INTERVAL_MS: progress,
    MCP_AGENTS_CODEX_WAIT_INTERVAL_MS: wait,
    MCP_AGENTS_TEST_TIMER_AUDIT: "1",
  },
  stdio: ["pipe", "pipe", "pipe"],
});
let out = "";
let err = "";
let parseBuf = "";
let scenarioStarted = false;
let reuseSent = false;
let bootTimer;
let pingTimer;
let settleTimer;
let fallbackTimer;
child.stdin.on("error", () => {});
child.stderr.on("data", (data) => { err += data.toString(); });
const send = (message) => {
  if (child.stdin.writable) child.stdin.write(`${JSON.stringify(message)}\n`);
};
const call = (id, token, prompt = `call ${id}`) => send({
  jsonrpc: "2.0",
  id,
  method: "tools/call",
  params: {
    name: "codex",
    arguments: { prompt },
    ...(token === undefined ? {} : { _meta: { progressToken: token } }),
  },
});

const startScenario = () => {
  if (scenarioStarted) return;
  scenarioStarted = true;
  send({ jsonrpc: "2.0", method: "notifications/initialized" });
  if (mode === "progress") {
    call(2);
    call(3, "progress-3");
  } else if (mode === "tokens") {
    call(2, "string-token");
    call(3, 42);
    call(4);
    call(5, { invalid: true });
  } else if (mode === "cancel") {
    call(2, "cancel-2");
    call(3);
    setTimeout(() => send({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 2, reason: "test" } }), 60);
  } else {
    const tokenModes = new Set([
      "hard", "visibility", "coalesce", "wait", "partial", "partialstall", "settled", "terminalstop",
    ]);
    call(2, tokenModes.has(mode) ? `${mode}-2` : undefined);
  }
  if (mode === "unrelated") {
    let pingId = 100;
    pingTimer = setInterval(() => send({ jsonrpc: "2.0", id: pingId++, method: "ping", params: {} }), 30);
  }
  settleTimer = setTimeout(() => {
    if (pingTimer) clearInterval(pingTimer);
    try { child.stdin.end(); } catch {}
    fallbackTimer = setTimeout(() => { try { child.kill("SIGTERM"); } catch {} }, 500);
  }, Number(settle));
};
child.stdout.on("data", (data) => {
  const chunk = data.toString();
  out += chunk;
  parseBuf += chunk;
  let newline;
  while ((newline = parseBuf.indexOf("\n")) !== -1) {
    const line = parseBuf.slice(0, newline); parseBuf = parseBuf.slice(newline + 1);
    let frame; try { frame = JSON.parse(line); } catch { continue; }
    if (frame.id === 1 && frame.result) startScenario();
    if (mode === "reuse" && frame.id === 2 && frame.result?.structuredContent?.content === "DONE" && !reuseSent) {
      reuseSent = true;
      call(2, undefined, "REUSED");
    }
  }
});
bootTimer = setInterval(() => {
  try { readFileSync(pidFile, "utf8"); } catch { return; }
  clearInterval(bootTimer);
  send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "lifecycle-test", version: "0" } } });
}, 10);

child.once("close", (code, signal) => {
  clearInterval(bootTimer);
  clearTimeout(settleTimer);
  clearTimeout(fallbackTimer);
  if (pingTimer) clearInterval(pingTimer);
  setTimeout(() => {
    let parseErrors = 0;
    const frames = out.split("\n").filter(Boolean).flatMap((line) => {
      try { return [JSON.parse(line)]; } catch { parseErrors += 1; return []; }
    });
    let stubPid = null;
    try { stubPid = Number(readFileSync(pidFile, "utf8")); } catch {}
    let stubAlive = false;
    try { if (stubPid) process.kill(stubPid, 0); stubAlive = Boolean(stubPid); } catch {}
    let calls = [];
    try { calls = readFileSync(callFile, "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line)); } catch {}
    const timerAudits = [...err.matchAll(/settled timer count=(\d+)/g)].map((match) => Number(match[1]));
    process.stdout.write(`${JSON.stringify({ code, signal, elapsedMs: Date.now() - started, stubAlive, calls, frames, parseErrors, rawHasProgress: out.includes('"method":"notifications/progress"'), timerAudits })}\n`);
    process.exit(0);
  }, 80);
});

process.once("SIGTERM", () => {
  try { child.kill("SIGTERM"); } catch {}
  setTimeout(() => process.exit(124), 1000);
});
EOF
}

test_codex_lifecycle() {
  local label="$1" mode="$2" idle="$3" hard="$4" settle="$5"
  local terminal="$6" cancel="$7" progress="$8" predicate="$9"
  local tmpdir status summary ok
  echo "--- $label ---"
  tmpdir=$(mktemp -d)
  write_codex_lifecycle_stub "$tmpdir"
  write_codex_lifecycle_driver "$tmpdir"
  set +e
  summary=$($TIMEOUT_CMD 8 node "$tmpdir/driver.mjs" "$tmpdir" "$(pwd)" "$mode" "$idle" "$hard" "$settle" "$terminal" "$cancel" "$progress" 2>/dev/null)
  status=$?
  set -e
  ok=1
  [ "$status" -eq 0 ] || ok=0
  printf '%s' "$summary" | jq -e "$predicate" >/dev/null 2>&1 || ok=0
  if [ "$ok" -eq 1 ]; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (status=$status)"
    echo "  Summary: ${summary:0:10000}"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$tmpdir"
}

test_no_registered_child_leaks() {
  local label="$1" survivors="" pid
  echo "--- $label ---"
  for _ in $(seq 1 30); do
    survivors=""
    while IFS= read -r pid; do
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then survivors="$survivors $pid"; fi
    done < "$TEST_CHILD_REGISTRY"
    [ -z "$survivors" ] && break
    sleep 0.1
  done
  if [ -z "$survivors" ]; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (survivors:$survivors)"
    FAIL=$((FAIL + 1))
    cleanup_registered_test_children
  fi
}

test_provider_shutdown_kills_child "stdin shutdown kills detached claude child"

# Stub-based codex filtering tests (fast — no real codex needed)
test_codex_bridge_config_defaults "codex bridge writes lean isolated config"
test_codex_auth_persistence_secure_temp "codex auth write-back uses secure exclusive temp"
test_codex_strips_only_model_effort "codex strips model/effort, keeps sandbox/cwd/approval"
test_codex_passes_through_unmodified "codex forwards no-strip tools/call byte-for-byte"

# Stub-based per-session effort tests (fast — no real Codex needed). The
# wrapper-only top-level arg is accepted only on a new `codex` call, translated
# into Codex's config map, and never forwarded in its wrapper form.
test_codex_call_transform "codex translates per-session xhigh effort" \
  "" \
  '{"prompt":"hi","model_reasoning_effort":"xhigh"}' \
  '.params.arguments | ((has("model_reasoning_effort")|not) and (.config == {"model_reasoning_effort":"xhigh"}))'
test_codex_call_transform "codex translates per-session max effort and keeps config" \
  "" \
  '{"prompt":"hi","model_reasoning_effort":"max","config":{"sandbox_mode":"workspace-write","cwd":"/tmp/work"}}' \
  '.params.arguments | ((has("model_reasoning_effort")|not) and (.config.model_reasoning_effort == "max") and (.config.sandbox_mode == "workspace-write") and (.config.cwd == "/tmp/work"))'
test_codex_call_transform "codex applies per-session effort when config is null" \
  "" \
  '{"prompt":"hi","model_reasoning_effort":"max","config":null}' \
  '.params.arguments | ((has("model_reasoning_effort")|not) and (.config == {"model_reasoning_effort":"max"}))'
# Sanitize every raw model-envelope bypass before applying the validated
# wrapper value. A conflicting nested xhigh, dotted effort, profile, provider,
# and alternate model must not beat the requested max.
test_codex_call_transform "codex validated effort wins over raw config bypasses" \
  "" \
  '{"prompt":"hi","model":"evil-model","model_reasoning_effort":"max","config":{"model":"evil-model","model_reasoning_effort":"xhigh","model_reasoning_effort.level":"ultra","profile":"evil-profile","profiles":{"evil":{"model_reasoning_effort":"ultra"}},"model_provider":"evil-provider","model_providers":{"evil":{"base_url":"http://evil"}},"plan_mode_reasoning_effort":"ultra","review_model":"evil-review","sandbox_mode":"workspace-write"}}' \
  '.params.arguments | ((has("model")|not) and (has("model_reasoning_effort")|not) and (.config == {"sandbox_mode":"workspace-write","model_reasoning_effort":"max"}))'

# Unsupported and malformed wrapper values are stripped. The call still
# forwards and inherits the server default; no invalid or raw nested effort is
# allowed to reach Codex.
test_codex_call_transform "codex strips unsupported ultra effort" \
  "" \
  '{"prompt":"hi","model_reasoning_effort":"ultra","config":{"model_reasoning_effort":"max","sandbox_mode":"read-only"}}' \
  '.params.arguments | ((has("model_reasoning_effort")|not) and (.config == {"sandbox_mode":"read-only"}))'
test_codex_call_transform "codex strips unsupported named effort" \
  "" \
  '{"prompt":"hi","model_reasoning_effort":"medium"}' \
  '.params.arguments | ((has("model_reasoning_effort")|not) and (has("config")|not))'
test_codex_call_transform "codex strips non-string effort" \
  "" \
  '{"prompt":"hi","model_reasoning_effort":false,"config":{"profiles":{"evil":{"model_reasoning_effort":"max"}}}}' \
  '.params.arguments | ((has("model_reasoning_effort")|not) and (has("config")|not))'
test_codex_call_transform "codex-reply cannot change session effort" \
  "" \
  '{"conversationId":"abc","prompt":"continue","model_reasoning_effort":"max","config":{"model_reasoning_effort":"xhigh"}}' \
  '.params.arguments | ((has("model_reasoning_effort")|not) and (has("config")|not) and (.conversationId == "abc") and (.prompt == "continue"))' \
  "codex-reply"

# Goal and effort are independent wrapper features: both transformations must
# compose on an initial call while preserving caller config/instructions.
test_codex_call_transform "codex composes per-session max effort with goal" \
  "" \
  '{"prompt":"hi","model_reasoning_effort":"max","goal":"SHIPSAFE","developer-instructions":"EXISTINGDEV","config":{"sandbox_mode":"workspace-write"}}' \
  '.params.arguments | ((has("model_reasoning_effort")|not) and (has("goal")|not) and (.config.model_reasoning_effort == "max") and (.config.sandbox_mode == "workspace-write") and (.["developer-instructions"]|test("SHIPSAFE")) and (.["developer-instructions"]|test("EXISTINGDEV")) and ((.["developer-instructions"]|index("SHIPSAFE")) < (.["developer-instructions"]|index("EXISTINGDEV"))))'

# Stub-based codex goal injection tests (fast — no real codex needed).
# For the initial `codex` tool the goal goes into developer-instructions (the
# MCP-correct, thread-persistent vehicle) and the prompt is left untouched; for
# `codex-reply` (no developer-instructions field) it is a concise prompt reminder.
test_codex_call_transform "codex injects per-call goal into developer-instructions" \
  "" \
  '{"prompt":"hi","goal":"SHIPSAFE"}' \
  '.params.arguments | ((has("goal")|not) and (.prompt == "hi") and (.["developer-instructions"]|test("SHIPSAFE")))'
test_codex_call_transform "codex injects server --goal into developer-instructions" \
  "--goal SERVERGOAL" \
  '{"prompt":"hi"}' \
  '.params.arguments | ((.prompt == "hi") and (.["developer-instructions"]|test("SERVERGOAL")))'
test_codex_call_transform "codex per-call goal overrides server --goal" \
  "--goal SERVERGOAL" \
  '{"prompt":"hi","goal":"CALLGOAL"}' \
  '.params.arguments | ((has("goal")|not) and (.["developer-instructions"]|test("CALLGOAL")) and (.["developer-instructions"]|test("SERVERGOAL")|not))'
test_codex_call_transform "codex blank per-call goal suppresses server --goal" \
  "--goal SERVERGOAL" \
  '{"prompt":"hi","goal":""}' \
  '.params.arguments | ((has("goal")|not) and (.prompt == "hi") and (has("developer-instructions")|not))'
# A malformed (non-string) per-call goal is dropped without disturbing the
# configured server default (must NOT suppress it like an empty string does).
test_codex_call_transform "codex non-string per-call goal keeps server --goal" \
  "--goal SERVERGOAL" \
  '{"prompt":"hi","goal":false}' \
  '.params.arguments | ((has("goal")|not) and (.["developer-instructions"]|test("SERVERGOAL")))'
# The objective is merged AHEAD of any caller-supplied developer-instructions
# (order asserted via index), which are preserved.
test_codex_call_transform "codex merges goal ahead of existing developer-instructions" \
  "" \
  '{"prompt":"hi","goal":"GOALX","developer-instructions":"EXISTINGDEV"}' \
  '.params.arguments | ((has("goal")|not) and (.prompt == "hi") and (.["developer-instructions"]|startswith("Persistent objective")) and (.["developer-instructions"]|test("EXISTINGDEV")) and ((.["developer-instructions"]|index("GOALX")) < (.["developer-instructions"]|index("EXISTINGDEV"))))'
# codex-reply has no developer-instructions field, so the goal is a concise
# prompt reminder PREFIXED to the prompt (order asserted); conversationId kept.
test_codex_call_transform "codex-reply injects per-call goal as prompt reminder" \
  "" \
  '{"conversationId":"abc","prompt":"continue","goal":"STAYFOCUSED"}' \
  '.params.arguments | ((has("goal")|not) and (.conversationId == "abc") and (has("developer-instructions")|not) and (.prompt|startswith("Reminder")) and (.prompt|test("continue")) and ((.prompt|index("STAYFOCUSED")) < (.prompt|index("continue"))))' \
  "codex-reply"
# Multi-word goal text survives intact.
test_codex_call_transform "codex injects multi-word per-call goal" \
  "" \
  '{"prompt":"hi","goal":"keep the public API unchanged"}' \
  '.params.arguments | (.["developer-instructions"]|test("keep the public API unchanged"))'
# An unknown/future tool name is NOT goal-injected: the wrapper-only `goal` arg
# is still stripped (never leaked) but neither the prompt nor developer-
# instructions is mutated, preserving byte-for-byte behavior for unsupported tools.
test_codex_call_transform "codex unknown tool name is not goal-injected" \
  "--goal SERVERGOAL" \
  '{"prompt":"hi","goal":"X"}' \
  '.params.arguments | ((has("goal")|not) and (.prompt == "hi") and (has("developer-instructions")|not))' \
  "some-other-tool"

# Stub-based Codex tools/list schema tests (fast — no real Codex needed).
# The wrapper rewrites ONLY the tools/list RESPONSE to advertise its wrapper
# fields; everything else stays byte-for-byte.
test_codex_toolslist_rewrite "tools/list advertises goal on codex AND codex-reply" \
  "normal" \
  'select(.id==2) | ((.result.tools|map(select(.name=="codex"))[0].inputSchema.properties.goal.type=="string") and (.result.tools|map(select(.name=="codex-reply"))[0].inputSchema.properties.goal.type=="string"))'
test_codex_toolslist_rewrite "tools/list advertises exact xhigh|max effort on codex only" \
  "normal" \
  'select(.id==2) | ((.result.tools|map(select(.name=="codex"))[0].inputSchema.properties.model_reasoning_effort | ((.type == "string") and (.enum == ["xhigh","max"]) and (has("default")|not))) and (.result.tools|map(select(.name=="codex-reply"))[0].inputSchema.properties|has("model_reasoning_effort")|not))'
test_codex_toolslist_rewrite "tools/list explains effort choice and reply inheritance" \
  "normal" \
  'select(.id==2) | (.result.tools|map(select(.name=="codex"))[0].inputSchema.properties.model_reasoning_effort.description|ascii_downcase) as $d | (($d|test("new codex session")) and ($d|test("xhigh.*hard")) and ($d|test("max.*extra-hard")) and ($d|test("repl.*inherit")) and ($d|test("cannot change")) and ($d|test("omit.*server.*default")))'
# If upstream Codex starts declaring this property itself, mcp-agents still
# owns the policy: constrain codex to the two allowed values and remove the
# property from codex-reply rather than exposing upstream drift such as ultra.
test_codex_toolslist_rewrite "tools/list constrains drifted upstream effort schema" \
  "haveeffort" \
  'select(.id==2) | ((.result.tools|map(select(.name=="codex"))[0].inputSchema.properties.model_reasoning_effort | ((.type == "string") and (.enum == ["xhigh","max"]) and (.description != "STUB_DRIFTED_EFFORT_DESC"))) and (.result.tools|map(select(.name=="codex-reply"))[0].inputSchema.properties|has("model_reasoning_effort")|not))'
test_codex_toolslist_rewrite "tools/list keeps additionalProperties:false on codex, none on codex-reply" \
  "normal" \
  'select(.id==2) | ((.result.tools|map(select(.name=="codex"))[0].inputSchema.additionalProperties==false) and (.result.tools|map(select(.name=="codex-reply"))[0].inputSchema|has("additionalProperties")|not))'
test_codex_toolslist_rewrite "tools/list keeps wrapper fields optional and other props intact" \
  "normal" \
  'select(.id==2) | ((.result.tools|map(select(.name=="codex"))[0].inputSchema|(.required|index("goal")|not) and (.required|index("model_reasoning_effort")|not) and (.properties["developer-instructions"]!=null) and (.properties.prompt!=null)) and (.result.tools|map(select(.name=="codex-reply"))[0].inputSchema.properties.conversationId!=null))'
test_codex_toolslist_rewrite "tools/list forwards interleaved notification byte-for-byte + rewrites result" \
  "interleaved" \
  'select(.id==2) | (.result.tools|map(select(.name=="codex"))[0].inputSchema.properties.goal.type=="string")' \
  '{"jsonrpc":"2.0","method":"codex/event","params":{"marker":"PASSTHROUGH_SENTINEL"}}'
test_codex_toolslist_rewrite "tools/list reassembles a split frame and rewrites it" \
  "split" \
  'select(.id==2) | (.result.tools|map(select(.name=="codex"))[0].inputSchema.properties.goal.type=="string")'
test_codex_toolslist_reentry "tools/list latch re-entry: two calls both rewritten"
test_codex_toolslist_rewrite "tools/list idempotent: existing goal preserved (not overwritten)" \
  "havegoal" \
  'select(.id==2) | (.result.tools|map(select(.name=="codex"))[0].inputSchema.properties.goal.description=="STUB_OWN_GOAL_DESC")'
test_codex_toolslist_rewrite "tools/list with no codex tools forwarded byte-for-byte" \
  "noctools" \
  'select(.id==2) | ((.result.tools|length==1) and (.result.tools[0].name=="ping") and (.result.tools[0].inputSchema.properties|has("goal")|not) and (.result.tools[0].inputSchema.properties|has("model_reasoning_effort")|not))'
test_codex_toolslist_rewrite "tools/list error response forwarded unchanged" \
  "error" \
  'select(.id==2) | (.error.code==-32601)'
test_codex_toolslist_rewrite "tools/list partial-then-die yields one -32001 (no hang)" \
  "partialdie" \
  'select(.id==2) | (has("error") and .error.code==-32001)'
test_codex_toolslist_rewrite "tools/list finalize recovers a complete-but-unterminated frame" \
  "nonewlinedie" \
  'select(.id==2) | (.result.tools|map(select(.name=="codex"))[0].inputSchema.properties.goal.type=="string")'
test_codex_toolslist_backpressure "tools/list both responses survive backpressure (no strand)"
test_codex_toolslist_rewrite "tools/list mode-boundary straddle reassembled byte-for-byte + rewritten" \
  "straddle" \
  'select(.id==2) | (.result.tools|map(select(.name=="codex"))[0].inputSchema.properties.goal.type=="string")' \
  '{"jsonrpc":"2.0","method":"codex/event","params":{"marker":"STRADDLE_SENTINEL"}}'
# Latch-boundary return-to-raw: a trailing NON-tools/list partial after the
# rewritten result must be forwarded raw (not withheld/byte-lost) when codex dies.
test_codex_toolslist_file "tools/list trailing partial after result is forwarded raw (not lost)" \
  "trailpartialdie" \
  '.result.tools|map(select(.name=="codex"))[0].inputSchema.properties.goal.type=="string"' \
  "TRAILING_HEAD"
# Oversized (>10 MiB) frame in the latch window is forwarded raw without parsing,
# and the subsequent tools/list result is still rewritten.
test_codex_toolslist_file "tools/list oversized frame forwarded raw, result still rewritten" \
  "oversized" \
  '.result.tools|map(select(.name=="codex"))[0].inputSchema.properties.goal.type=="string"' \
  "OVERSIZED_MARKER"
# Cancel path: a tools/list cancel that empties the latch while a non-tools/list
# partial is withheld must flush it raw (not byte-lose it when codex then dies).
test_codex_toolslist_cancel "tools/list cancel flushes a withheld partial raw (not lost)"

# Stub-based per-request Codex lifecycle tests.
test_codex_lifecycle "codex stderr does not reset request idle deadline" \
  "stderr" "0.3" "2" "1000" "80" "100" "0" \
  '(.code == 1) and (.stubAlive == false) and
   ([.frames[] | select(.id == 2 and .error.code == -32001 and (.error.message | ascii_downcase | contains("idle")))] | length == 1) and
   ([.frames[] | select(.id == 2 and has("result"))] | length == 0)'
test_codex_lifecycle "codex unrelated pings/events do not reset request idle deadline" \
  "unrelated" "0.3" "2" "1000" "80" "100" "0" \
  '(.code == 1) and (.stubAlive == false) and
   ([.frames[] | select(.id == 2 and .error.code == -32001 and (.error.message | ascii_downcase | contains("idle")))] | length == 1) and
   ([.frames[] | select((.id // 0) >= 100 and has("result"))] | length >= 1)'
test_codex_lifecycle "codex matching events extend idle and progress uses supplied token only" \
  "progress" "0.3" "2" "1000" "80" "100" "60" \
  '(.code == 0) and (.stubAlive == false) and
   ([.frames[] | select(.id == 2 and .result.structuredContent.content == "PROGRESS_2")] | length == 1) and
   ([.frames[] | select(.id == 3 and .result.structuredContent.content == "PROGRESS_3")] | length == 1) and
   ([.frames[] | select(.method == "notifications/progress")] as $p |
     (($p | length) >= 1) and ([$p[] | select(.params.progressToken != "progress-3")] | length == 0))'
test_codex_lifecycle "codex progress accepts string/numeric tokens and rejects missing/invalid tokens" \
  "tokens" "0.5" "2" "350" "80" "100" "20" \
  '(.code == 0) and
   ([.frames[] | select(.id >= 2 and .id <= 5 and has("result"))] | length == 4) and
   ([.frames[] | select(.method == "notifications/progress") | .params.progressToken] | sort) == [42, "string-token"]'
test_codex_lifecycle "codex progress allowlist exposes useful status and redacts hostile fields" \
  "visibility" "1" "2" "750" "80" "100" "30" \
  '(.code == 0) and (.parseErrors == 0) and
   ([.frames[] | select(.method == "notifications/progress" and .params.progressToken == "visibility-2")] as $p |
     ($p | length) >= 7 and
     ([$p[].params.progress] as $seq | ($seq == ($seq | sort)) and (($seq | unique | length) == ($seq | length))) and
     ([$p[].params.message] | all((length <= 200) and startswith("Codex: "))) and
     (([$p[].params.message] | join(" ")) as $messages |
       ($messages | contains("Working on tests 🚀")) and
       ($messages | contains("working on: Verify bridge")) and
       ($messages | contains("running a command")) and
       ($messages | contains("command finished (exit 7)")) and
       ($messages | contains("applying changes to 2 file(s)")) and
       ($messages | contains("calling safe-server/safe-tool")) and
       ($messages | contains("web search finished")) and
       ($messages | contains("Completed commentary")) and
       ($messages | contains("SENTINEL_") | not)))'
test_codex_lifecycle "codex progress is immediate then coalesces latest distinct status" \
  "coalesce" "0.5" "2" "350" "80" "100" "80" \
  '(.code == 0) and
   ([.frames[] | select(.method == "notifications/progress") | .params.message] ==
     ["Codex: started", "Codex: working on: Latest status"])'
test_codex_lifecycle "codex silence notices report event age without extending idle" \
  "wait" "1.25" "3" "2400" "80" "100" "20,250" \
  '(.code == 1) and (.elapsedMs >= 1700) and (.elapsedMs < 2300) and
   ([.frames[] | select(.method == "notifications/progress") | .params.message] as $messages |
     ($messages | any(contains("still running; last activity 0s ago"))) and
     ($messages | any(contains("still running; last activity 1s ago")))) and
   ([.frames[] | select(.id == 2 and .error.code == -32001 and (.error.message | ascii_downcase | contains("idle")))] | length == 1)'
test_codex_lifecycle "codex progress waits for a safe boundary and keeps only the latest frame" \
  "partial" "0.5" "2" "600" "80" "100" "20,60" \
  '(.code == 0) and (.parseErrors == 0) and
   ([.frames[] | select(.method == "notifications/progress")] | length == 1) and
   ([.frames[] | select(.method == "notifications/progress") | .params.message | contains("still running")] | all) and
   ([.frames[] | select(.id == 2 and .result.structuredContent.content == "PARTIAL")] | length == 1)'
test_codex_lifecycle "codex permanent partial stall never splices progress and still idles out" \
  "partialstall" "0.25" "2" "600" "80" "100" "20,60" \
  '(.code == 1) and (.rawHasProgress == false) and
   ([.frames[] | select(.id == 2 and .error.code == -32001 and (.error.message | ascii_downcase | contains("idle")))] | length == 1)'
test_codex_lifecycle "codex settlement clears progress and silence timers" \
  "settled" "0.5" "2" "300" "80" "100" "20,60" \
  '(.code == 0) and
   ((.timerAudits | length) >= 1) and (.timerAudits | all(. == 0)) and
   ([.frames[] | select(.id == 2 and .result.structuredContent.content == "SETTLED")] | length == 1) and
   ([.frames[] | select(.method == "notifications/progress")] | length == 1)'
test_codex_lifecycle "codex terminal grace stops progress before fallback settlement" \
  "terminalstop" "0.5" "2" "350" "150" "100" "20,60" \
  '(.code == 0) and
   ([.frames[] | select(.id == 2 and .result.structuredContent.content == "DONE")] | length == 1) and
   ([.frames[] | select(.method == "notifications/progress")] | length == 1)'
test_codex_lifecycle "codex terminal event synthesizes result with early thread id" \
  "terminal" "0.3" "2" "350" "80" "100" "0" \
  '(.code == 0) and (.stubAlive == false) and
   ([.frames[] | select(.id == 2 and .result.content[0].text == "DONE" and .result.structuredContent == {"threadId":"00000000-0000-4000-8000-000000000002","content":"DONE"})] | length == 1) and
   ([.frames[] | select(.id == 2 and has("error"))] | length == 0)'
test_codex_lifecycle "codex terminal event survives immediate child exit" \
  "terminalexit" "0.3" "2" "350" "80" "100" "0" \
  '(.code == 0) and (.stubAlive == false) and
   ([.calls[] | select(.id == 2 and .prompt == "call 2")] | length == 1) and
   ([.frames[] | select(.id == 2 and .result.content[0].text == "DONE" and .result.structuredContent == {"threadId":"00000000-0000-4000-8000-000000000002","content":"DONE"})] | length == 1) and
   ([.frames[] | select(.id == 2 and has("error"))] | length == 0)'
test_codex_lifecycle "codex native result inside terminal grace wins" \
  "native" "0.3" "2" "300" "150" "100" "0" \
  '(.code == 0) and (.stubAlive == false) and
   ([.frames[] | select(.id == 2 and .result.structuredContent.content == "NATIVE")] | length == 1) and
   ([.frames[] | select(.id == 2 and (.result.structuredContent.content // "") == "DONE")] | length == 0)'
test_codex_lifecycle "codex late native result is suppressed after terminal fallback" \
  "late" "0.3" "2" "400" "70" "100" "0" \
  '(.code == 0) and (.stubAlive == false) and
   ([.frames[] | select(.id == 2 and has("result"))] | length == 1) and
   ([.frames[] | select(.id == 2 and .result.structuredContent.content == "DONE")] | length == 1) and
   ([.frames[] | select(.id == 2 and .result.structuredContent.content == "LATE")] | length == 0)'
test_codex_lifecycle "codex request-id reuse is rejected while late response is suppressed" \
  "reuse" "0.3" "2" "600" "70" "100" "0" \
  '(.code == 1) and (.stubAlive == false) and
   ([.calls[] | select(.id == 2 and .prompt == "call 2")] | length == 1) and
   ([.calls[] | select(.prompt == "REUSED")] | length == 0) and
   ([.frames[] | select(.id == 2 and has("result"))] | length == 1) and
   ([.frames[] | select(.id == 2 and .result.structuredContent.content == "DONE")] | length == 1) and
   ([.frames[] | select(.id == 2 and .result.structuredContent.content == "LATE")] | length == 0) and
   ([.frames[] | select(.id == 2 and has("error"))] | length == 1) and
   ([.frames[] | select(.id == 2 and .error.code == -32001 and (.error.message | ascii_downcase | contains("reused")))] | length == 1)'
test_codex_lifecycle "codex hard deadline is immutable despite matching progress" \
  "hard" "0.3" "0.55" "1000" "80" "100" "0" \
  '(.code == 1) and (.stubAlive == false) and
   ([.frames[] | select(.id == 2 and .error.code == -32001 and (.error.message | ascii_downcase | test("hard|deadline")))] | length == 1) and
   ([.frames[] | select(.method == "notifications/progress" and .params.progressToken == "hard-2")] | length >= 1)'
test_codex_lifecycle "codex cancellation tears wrapper down after bounded grace" \
  "cancel" "2" "2" "800" "80" "100" "0" \
  '(.code == 1) and (.elapsedMs < 1000) and (.stubAlive == false) and
   ([.frames[] | select(.id == 2 and (has("result") or has("error")))] | length == 0) and
   ([.frames[] | select(.id == 3 and .error.code == -32001)] | length == 1)'

# Stub-based codex watchdog/child-death tests (fast — no real codex needed)
run_codex_watchdog_case "codex idle watchdog synthesizes error for stalled call" \
  "stall" "--codex_idle_timeout 1" 1
run_codex_watchdog_case "codex child death synthesizes error (no childless hang)" \
  "die" "--codex_idle_timeout 30" 0

if [ "${SKIP_INTEGRATION:-}" = "1" ]; then
  echo ""
  echo "(Skipping integration tests — SKIP_INTEGRATION=1)"
else
  test_connectivity "call claude (connectivity)" "claude" "claude_code" 30
  test_connectivity "call gemini (connectivity)" "gemini" "gemini"     30
  test_codex_passthrough "codex passthrough (tools/list)"
  test_codex_isolated_runtime "codex passthrough (isolated runtime + per-session max)"
  test_codex_percall_write "codex per-call workspace-write grants writes"
fi

test_no_registered_child_leaks "test suite leaves no provider stub children"

# ---------- Summary ----------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
