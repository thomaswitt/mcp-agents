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
test_cli_flag "--help shows GPT-5.5 default" "--help"   "gpt-5.5"
test_cli_flag "--help shows xhigh default"  "--help"    "xhigh"
test_cli_flag "--help shows workspace-write default" "--help" "workspace-write"
test_cli_flag "--help shows never default"  "--help"    "never"
test_cli_flag "--help shows codex_idle_timeout" "--help" "codex_idle_timeout"
test_cli_flag "--help shows goal flag"      "--help"    "Persistent objective"
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

# ── Helper: stub `codex` that snapshots the generated isolated config ──
# before the wrapper cleans up the temporary CODEX_HOME.
write_codex_config_stub() {
  cat >"$1/codex" <<'EOF'
#!/usr/bin/env bash
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
      [ -n "$child_pid" ] && kill -9 "$child_pid" 2>/dev/null
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
# over the forwarded call's parsed JSON-RPC message. Proves the wrapper's goal
# stripping/injection (server-default, per-call override, and suppress paths).
#   $1 label, $2 extra server args, $3 arguments JSON, $4 jq predicate,
#   $5 tool name (optional, default "codex" — pass "codex-reply" to prove the
#      transform is tool-name agnostic)
test_codex_goal_case() {
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

# ── Helper: node stub `codex` mcp-server for the tools/list goal-advertising ──
# tests. Answers initialize, then on tools/list emits a result with codex +
# codex-reply tools (real schema shapes) per MCP_STUB_TLMODE — exercising the
# wrapper's contained-latch rewrite paths. No real codex needed.
write_codex_toolslist_stub() {
  cat >"$1/codex" <<'EOF'
#!/usr/bin/env node
const MODE = process.env.MCP_STUB_TLMODE || "normal";
const SENTINEL = '{"jsonrpc":"2.0","method":"codex/event","params":{"marker":"PASSTHROUGH_SENTINEL"}}';
const STRADDLE = '{"jsonrpc":"2.0","method":"codex/event","params":{"marker":"STRADDLE_SENTINEL"}}';
const STRADDLE_HEAD = STRADDLE.slice(0, 40);   // emitted on initialize, NO newline (orphan head)
const STRADDLE_TAIL = STRADDLE.slice(40);      // emitted on tools/list, completes the frame
function tools(withGoal) {
  const codex = { name: "codex", inputSchema: { type: "object", additionalProperties: false, required: ["prompt"], properties: { prompt: { type: "string" }, "developer-instructions": { type: "string" }, "base-instructions": { type: "string" } } } };
  if (withGoal) codex.inputSchema.properties.goal = { type: "string", description: "STUB_OWN_GOAL_DESC" };
  const reply = { name: "codex-reply", inputSchema: { type: "object", required: ["prompt"], properties: { conversationId: { type: "string" }, threadId: { type: "string" }, prompt: { type: "string" } } } };
  return [codex, reply];
}
const resultLine = (id, withGoal) => JSON.stringify({ jsonrpc: "2.0", id, result: { tools: tools(withGoal) } });
function onToolsList(id) {
  if (MODE === "havegoal") { process.stdout.write(resultLine(id, true) + "\n"); return; }
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
setInterval(() => {}, 1 << 30);
EOF
  chmod +x "$1/codex"
}

# ── Helper: drive initialize + tools/list(id:2) at the stub under MCP_STUB_TLMODE ──
# and assert a jq predicate over the wrapper's stdout (plus an optional byte-for-byte grep).
#   $1 label, $2 stub mode, $3 jq predicate, $4 optional grep -F string
test_codex_toolslist_goal() {
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
  stdio: ["pipe", "pipe", "ignore"],
});
let out = "";
child.stdout.pause();                                   // induce backpressure: stop reading
child.stdout.on("data", (d) => { out += d.toString(); });
child.stdin.on("error", () => {});
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
  process.stdout.write(ok2 && ok3 ? "BP_OK\n" : `BP_FAIL ok2=${ok2} ok3=${ok3}\n`);
  try { child.kill("SIGKILL"); } catch {}
  process.exit(ok2 && ok3 ? 0 : 1);
}, 1800);
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

# ── Helper: like test_codex_toolslist_goal but reads the captured FILE so it ──
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

test_provider_shutdown_kills_child "stdin shutdown kills detached claude child"

# Stub-based codex filtering tests (fast — no real codex needed)
test_codex_bridge_config_defaults "codex bridge writes lean isolated config"
test_codex_auth_persistence_secure_temp "codex auth write-back uses secure exclusive temp"
test_codex_strips_only_model_effort "codex strips model/effort, keeps sandbox/cwd/approval"
test_codex_passes_through_unmodified "codex forwards no-strip tools/call byte-for-byte"

# Stub-based codex goal injection tests (fast — no real codex needed).
# For the initial `codex` tool the goal goes into developer-instructions (the
# MCP-correct, thread-persistent vehicle) and the prompt is left untouched; for
# `codex-reply` (no developer-instructions field) it is a concise prompt reminder.
test_codex_goal_case "codex injects per-call goal into developer-instructions" \
  "" \
  '{"prompt":"hi","goal":"SHIPSAFE"}' \
  '.params.arguments | ((has("goal")|not) and (.prompt == "hi") and (.["developer-instructions"]|test("SHIPSAFE")))'
test_codex_goal_case "codex injects server --goal into developer-instructions" \
  "--goal SERVERGOAL" \
  '{"prompt":"hi"}' \
  '.params.arguments | ((.prompt == "hi") and (.["developer-instructions"]|test("SERVERGOAL")))'
test_codex_goal_case "codex per-call goal overrides server --goal" \
  "--goal SERVERGOAL" \
  '{"prompt":"hi","goal":"CALLGOAL"}' \
  '.params.arguments | ((has("goal")|not) and (.["developer-instructions"]|test("CALLGOAL")) and (.["developer-instructions"]|test("SERVERGOAL")|not))'
test_codex_goal_case "codex blank per-call goal suppresses server --goal" \
  "--goal SERVERGOAL" \
  '{"prompt":"hi","goal":""}' \
  '.params.arguments | ((has("goal")|not) and (.prompt == "hi") and (has("developer-instructions")|not))'
# A malformed (non-string) per-call goal is dropped without disturbing the
# configured server default (must NOT suppress it like an empty string does).
test_codex_goal_case "codex non-string per-call goal keeps server --goal" \
  "--goal SERVERGOAL" \
  '{"prompt":"hi","goal":false}' \
  '.params.arguments | ((has("goal")|not) and (.["developer-instructions"]|test("SERVERGOAL")))'
# The objective is merged AHEAD of any caller-supplied developer-instructions
# (order asserted via index), which are preserved.
test_codex_goal_case "codex merges goal ahead of existing developer-instructions" \
  "" \
  '{"prompt":"hi","goal":"GOALX","developer-instructions":"EXISTINGDEV"}' \
  '.params.arguments | ((has("goal")|not) and (.prompt == "hi") and (.["developer-instructions"]|startswith("Persistent objective")) and (.["developer-instructions"]|test("EXISTINGDEV")) and ((.["developer-instructions"]|index("GOALX")) < (.["developer-instructions"]|index("EXISTINGDEV"))))'
# codex-reply has no developer-instructions field, so the goal is a concise
# prompt reminder PREFIXED to the prompt (order asserted); conversationId kept.
test_codex_goal_case "codex-reply injects per-call goal as prompt reminder" \
  "" \
  '{"conversationId":"abc","prompt":"continue","goal":"STAYFOCUSED"}' \
  '.params.arguments | ((has("goal")|not) and (.conversationId == "abc") and (has("developer-instructions")|not) and (.prompt|startswith("Reminder")) and (.prompt|test("continue")) and ((.prompt|index("STAYFOCUSED")) < (.prompt|index("continue"))))' \
  "codex-reply"
# Multi-word goal text survives intact.
test_codex_goal_case "codex injects multi-word per-call goal" \
  "" \
  '{"prompt":"hi","goal":"keep the public API unchanged"}' \
  '.params.arguments | (.["developer-instructions"]|test("keep the public API unchanged"))'
# An unknown/future tool name is NOT goal-injected: the wrapper-only `goal` arg
# is still stripped (never leaked) but neither the prompt nor developer-
# instructions is mutated, preserving byte-for-byte behavior for unsupported tools.
test_codex_goal_case "codex unknown tool name is not goal-injected" \
  "--goal SERVERGOAL" \
  '{"prompt":"hi","goal":"X"}' \
  '.params.arguments | ((has("goal")|not) and (.prompt == "hi") and (has("developer-instructions")|not))' \
  "some-other-tool"

# Stub-based codex tools/list goal-advertising tests (fast — no real codex needed).
# The wrapper rewrites ONLY the tools/list RESPONSE to add a `goal` property to the
# advertised codex/codex-reply schemas; everything else stays byte-for-byte.
test_codex_toolslist_goal "tools/list advertises goal on codex AND codex-reply" \
  "normal" \
  'select(.id==2) | ((.result.tools|map(select(.name=="codex"))[0].inputSchema.properties.goal.type=="string") and (.result.tools|map(select(.name=="codex-reply"))[0].inputSchema.properties.goal.type=="string"))'
test_codex_toolslist_goal "tools/list keeps additionalProperties:false on codex, none on codex-reply" \
  "normal" \
  'select(.id==2) | ((.result.tools|map(select(.name=="codex"))[0].inputSchema.additionalProperties==false) and (.result.tools|map(select(.name=="codex-reply"))[0].inputSchema|has("additionalProperties")|not))'
test_codex_toolslist_goal "tools/list does not add goal to required; keeps other props" \
  "normal" \
  'select(.id==2) | ((.result.tools|map(select(.name=="codex"))[0].inputSchema|(.required|index("goal")|not) and (.properties["developer-instructions"]!=null) and (.properties.prompt!=null)) and (.result.tools|map(select(.name=="codex-reply"))[0].inputSchema.properties.conversationId!=null))'
test_codex_toolslist_goal "tools/list forwards interleaved notification byte-for-byte + rewrites result" \
  "interleaved" \
  'select(.id==2) | (.result.tools|map(select(.name=="codex"))[0].inputSchema.properties.goal.type=="string")' \
  '{"jsonrpc":"2.0","method":"codex/event","params":{"marker":"PASSTHROUGH_SENTINEL"}}'
test_codex_toolslist_goal "tools/list reassembles a split frame and rewrites it" \
  "split" \
  'select(.id==2) | (.result.tools|map(select(.name=="codex"))[0].inputSchema.properties.goal.type=="string")'
test_codex_toolslist_reentry "tools/list latch re-entry: two calls both rewritten"
test_codex_toolslist_goal "tools/list idempotent: existing goal preserved (not overwritten)" \
  "havegoal" \
  'select(.id==2) | (.result.tools|map(select(.name=="codex"))[0].inputSchema.properties.goal.description=="STUB_OWN_GOAL_DESC")'
test_codex_toolslist_goal "tools/list with no codex tools forwarded byte-for-byte" \
  "noctools" \
  'select(.id==2) | ((.result.tools|length==1) and (.result.tools[0].name=="ping") and (.result.tools[0].inputSchema.properties|has("goal")|not))'
test_codex_toolslist_goal "tools/list error response forwarded unchanged" \
  "error" \
  'select(.id==2) | (.error.code==-32601)'
test_codex_toolslist_goal "tools/list partial-then-die yields one -32001 (no hang)" \
  "partialdie" \
  'select(.id==2) | (has("error") and .error.code==-32001)'
test_codex_toolslist_goal "tools/list finalize recovers a complete-but-unterminated frame" \
  "nonewlinedie" \
  'select(.id==2) | (.result.tools|map(select(.name=="codex"))[0].inputSchema.properties.goal.type=="string")'
test_codex_toolslist_backpressure "tools/list both responses survive backpressure (no strand)"
test_codex_toolslist_goal "tools/list mode-boundary straddle reassembled byte-for-byte + rewritten" \
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
  test_codex_isolated_runtime "codex passthrough (isolated runtime)"
  test_codex_percall_write "codex per-call workspace-write grants writes"
fi

# ---------- Summary ----------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
