#!/usr/bin/env bash
# Smoke tests for mcp-agents stdio transport.
# Verifies provider servers handle JSON-RPC over stdio and exit cleanly
# after stdin EOF. Timeouts are guardrails, not the expected shutdown path.
set -euo pipefail

cd "$(dirname "$0")"

TEST_REPO_ROOT=$(pwd)
TEST_CODEX_HOME_ROOT="$TEST_REPO_ROOT/tmp/codex-homes"
SERVER="node server.js"
# Resolve once to an ABSOLUTE path: tests that restrict PATH to simulate a
# published install must not lose the harness's own timeout binary.
TIMEOUT_CMD="$(command -v timeout || command -v gtimeout || true)"
if [ -z "$TIMEOUT_CMD" ]; then
  echo "Error: 'timeout' (coreutils) is required. Install via: brew install coreutils"
  exit 1
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
  rmdir "$TEST_CODEX_HOME_ROOT" "$TEST_REPO_ROOT/tmp" 2>/dev/null || true
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

# ── Helper: assert the Claude provider's wrapper-owned tool schemas ──
test_claude_tools_schema() {
  local label="$1"
  local predicate="$2"
  local output_file
  local status

  echo "--- $label ---"

  output_file=$(mktemp)
  set +e
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
    sleep 2
  } | $TIMEOUT_CMD 5 $SERVER --provider claude >"$output_file" 2>/dev/null
  status=$?
  set -e
  RESPONSE=$(cat "$output_file")
  rm -f "$output_file"

  if [ "$status" -eq 0 ] &&
    printf '%s\n' "$RESPONSE" | jq -e "$predicate" >/dev/null 2>&1; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (exit $status)"
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

# ── Helper: official v2 client negotiates modern stdio and exits cleanly ──
test_modern_stdio_provider() {
  local label="$1"
  local provider="$2"
  local expected_tool="$3"
  local tmpdir output_file status

  echo "--- $label ---"

  tmpdir=$(mktemp -d)
  output_file="$tmpdir/output.txt"
  mkdir "$tmpdir/bin"
  cat >"$tmpdir/bin/codex" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf '%s\n' 'codex-cli 0.149.1'
  exit 0
fi
exit 1
EOF
  chmod +x "$tmpdir/bin/codex"
  set +e
  MCP_AGENTS_TEST_STATE_ROOT="$tmpdir/state" \
  MCP_AGENTS_TEST_BIN_DIR="$tmpdir/bin" \
    "$TIMEOUT_CMD" 15 node --input-type=module - \
      "$provider" "$expected_tool" >"$output_file" 2>&1 <<'EOF'
import { appendFileSync } from "node:fs";
import { Client } from "@modelcontextprotocol/client";
import {
  StdioClientTransport,
  getDefaultEnvironment,
} from "@modelcontextprotocol/client/stdio";

const provider = process.argv[2];
const expectedTool = process.argv[3];
const args = ["server.js", "--provider", provider];
if (provider === "codex") {
  args.push("--codex-state-root", process.env.MCP_AGENTS_TEST_STATE_ROOT);
}

const client = new Client(
  { name: "mcp-agents-modern-test", version: "0.0.0" },
  {
    versionNegotiation: {
      mode: { pin: "2026-07-28" },
      probe: { timeoutMs: 1_000, maxRetries: 0 },
    },
  },
);
const transport = new StdioClientTransport({
  command: process.execPath,
  args,
  cwd: process.cwd(),
  env: {
    ...getDefaultEnvironment(),
    PATH: provider === "codex"
      ? `${process.env.MCP_AGENTS_TEST_BIN_DIR}:${process.env.PATH}`
      : process.env.PATH,
  },
  stderr: "pipe",
});
let stderr = "";
transport.stderr?.setEncoding("utf8");
transport.stderr?.on("data", (chunk) => {
  stderr += chunk;
});

let registeredPid = null;
function registerChild() {
  const pid = transport.pid;
  if (pid !== null && pid !== registeredPid) {
    appendFileSync(process.env.MCP_AGENTS_TEST_CHILD_REGISTRY, `${pid}\n`);
    registeredPid = pid;
  }
  return pid;
}

let failure;
try {
  await client.connect(transport);
  registerChild();
  if (client.getProtocolEra() !== "modern") {
    throw new Error(`expected modern era, got ${client.getProtocolEra()}`);
  }
  const { tools } = await client.listTools();
  const names = new Set(tools.map((tool) => tool.name));
  if (!names.has("ping") || !names.has(expectedTool)) {
    throw new Error(`missing expected tools: ${JSON.stringify([...names])}`);
  }
} catch (error) {
  failure = error;
} finally {
  registerChild();
  await client.close().catch(() => {});
}

const pid = registeredPid;
if (pid !== null) {
  for (let attempt = 0; attempt < 40; attempt += 1) {
    try {
      process.kill(pid, 0);
      await new Promise((resolve) => setTimeout(resolve, 50));
    } catch {
      break;
    }
  }
  try {
    process.kill(pid, 0);
    try { process.kill(-pid, "SIGKILL"); } catch {}
    throw new Error(`server child ${pid} survived client close`);
  } catch (error) {
    if (error?.code !== "ESRCH") throw error;
  }
}

if (failure) {
  console.error(failure);
  if (stderr) console.error(stderr);
  process.exit(1);
}
EOF
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (exit $status)"
    cat "$output_file"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$tmpdir"
}

# ── Helper: exercise one black-box HTTP daemon contract ──
test_http_daemon_case() {
  local label="$1"
  local scenario="$2"
  local tmpdir output_file status

  echo "--- $label ---"

  tmpdir=$(mktemp -d)
  output_file="$tmpdir/output.txt"
  set +e
  "$TIMEOUT_CMD" 20 node --input-type=module - \
    "$scenario" "$tmpdir" >"$output_file" 2>&1 <<'EOF'
import {
  appendFileSync,
  chmodSync,
  lstatSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { request as httpRequest, createServer } from "node:http";
import { spawn, spawnSync } from "node:child_process";
import { Client, StreamableHTTPClientTransport } from "@modelcontextprotocol/client";

const scenario = process.argv[2];
const tmpdir = process.argv[3];
const tokenFile = `${tmpdir}/bearer-token`;
const projectRoot = process.cwd();
if (scenario === "shutdown") {
  writeFileSync(`${tmpdir}/agy`, `#!/usr/bin/env node
import { writeFileSync } from "node:fs";
writeFileSync(process.env.MCP_STUB_PROVIDER_PID, String(process.pid));
setInterval(() => {}, 1000);
`);
  chmodSync(`${tmpdir}/agy`, 0o755);
}
const port = await new Promise((resolve, reject) => {
  const probe = createServer();
  probe.once("error", reject);
  probe.listen(0, "127.0.0.1", () => {
    const address = probe.address();
    probe.close((error) => error ? reject(error) : resolve(address.port));
  });
});

const child = spawn(process.execPath, [
  "server.js",
  "--provider", "gemini",
  "--transport", "http",
  "--http-port", String(port),
  "--http-token-file", tokenFile,
], {
  cwd: process.cwd(),
  detached: true,
  stdio: ["pipe", "pipe", "pipe"],
  env: {
    ...process.env,
    PATH: `${tmpdir}:${process.env.PATH}`,
    MCP_STUB_PROVIDER_PID: `${tmpdir}/provider.pid`,
  },
});
appendFileSync(process.env.MCP_AGENTS_TEST_CHILD_REGISTRY, `${child.pid}\n`);
child.stdout.resume();
let stderr = "";
child.stderr.setEncoding("utf8");
child.stderr.on("data", (chunk) => { stderr += chunk; });

const ready = new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error(`HTTP daemon did not become ready: ${stderr}`)), 5_000);
  const inspect = () => {
    if (!stderr.includes("HTTP MCP listening")) return;
    clearTimeout(timer);
    child.stderr.off("data", inspect);
    resolve();
  };
  child.stderr.on("data", inspect);
  child.once("exit", (code, signal) => {
    clearTimeout(timer);
    reject(new Error(`HTTP daemon exited before ready: code=${code} signal=${signal} stderr=${stderr}`));
  });
});

const stop = async () => {
  if (child.exitCode !== null || child.signalCode !== null) return;
  try { child.stdin.end(); } catch {}
  try { process.kill(-child.pid, "SIGTERM"); } catch {}
  await Promise.race([
    new Promise((resolve) => child.once("exit", resolve)),
    new Promise((resolve) => setTimeout(resolve, 2_000)),
  ]);
  try { process.kill(-child.pid, "SIGKILL"); } catch {}
};

const rawRequest = (path, headers = {}) => new Promise((resolve, reject) => {
  const req = httpRequest({
    host: "127.0.0.1",
    port,
    path,
    method: "GET",
    headers,
  }, (response) => {
    response.resume();
    response.once("end", () => resolve(response.statusCode));
  });
  req.once("error", reject);
  req.end();
});

try {
  await ready;
  const token = readFileSync(tokenFile, "utf8").trim();
  const authorization = `Bearer ${token}`;

  if (scenario === "token") {
    const stats = lstatSync(tokenFile);
    if (!stats.isFile() || stats.isSymbolicLink() || (stats.mode & 0o777) !== 0o600) {
      throw new Error(`token permissions are not 0600: ${(stats.mode & 0o777).toString(8)}`);
    }
    if (!/^[a-f0-9]{64}$/u.test(token)) throw new Error("token format is not 32-byte hex");
    const helper = spawnSync(process.execPath, [
      "server.js", "http-auth-headers", "--http-token-file", tokenFile,
    ], { cwd: process.cwd(), encoding: "utf8" });
    if (helper.status !== 0) throw new Error(`auth helper failed: ${helper.stderr}`);
    const parsed = JSON.parse(helper.stdout);
    if (JSON.stringify(parsed) !== JSON.stringify({ Authorization: authorization })) {
      throw new Error(`unexpected auth helper result: ${helper.stdout}`);
    }
  } else if (scenario === "security") {
    if (await rawRequest("/mcp") !== 401) throw new Error("missing token was not rejected with 401");
    if (await rawRequest("/mcp", { Authorization: "Bearer wrong" }) !== 401) {
      throw new Error("wrong token was not rejected with 401");
    }
    if (await rawRequest("/mcp", {
      Authorization: authorization,
      Origin: "https://evil.example",
    }) !== 403) throw new Error("untrusted Origin was not rejected with 403");
    if (await rawRequest("/mcp", {
      Authorization: authorization,
      Host: "evil.example",
    }) !== 403) throw new Error("untrusted Host was not rejected with 403");
    if (await rawRequest("/not-mcp", { Authorization: authorization }) !== 404) {
      throw new Error("unknown path was not rejected with 404");
    }
    if (await rawRequest("/mcp", { Authorization: authorization }) !== 405) {
      throw new Error("unsupported method was not rejected with 405");
    }
  } else if (scenario === "shutdown") {
    const client = new Client(
      { name: "mcp-agents-http-shutdown-test", version: "0.0.0" },
      { versionNegotiation: { mode: { pin: "2026-07-28" } } },
    );
    const transport = new StreamableHTTPClientTransport(
      new URL(`http://127.0.0.1:${port}/mcp`),
      { requestInit: { headers: { Authorization: authorization } } },
    );
    await client.connect(transport);
    const openCall = client.callTool({
      name: "gemini",
      arguments: { prompt: "stay active" },
    }).catch((error) => ({ transportError: error.message }));
    let providerStarted = false;
    const deadline = Date.now() + 2_000;
    while (Date.now() < deadline) {
      try {
        if (readFileSync(`${tmpdir}/provider.pid`, "utf8").trim()) {
          providerStarted = true;
          break;
        }
      } catch {}
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    if (!providerStarted) {
      const earlyResult = await Promise.race([
        openCall,
        new Promise((resolve) => setTimeout(() => resolve("still pending"), 100)),
      ]);
      throw new Error(
        `provider did not start; result=${JSON.stringify(earlyResult)} stderr=${stderr}`,
      );
    }
    const providerPid = Number(readFileSync(`${tmpdir}/provider.pid`, "utf8"));
    const stoppedAt = Date.now();
    try { process.kill(-child.pid, "SIGTERM"); } catch {}
    const closeInfo = await Promise.race([
      new Promise((resolve) => child.once("exit", (code, signal) =>
        resolve({ code, signal })
      )),
      new Promise((resolve) => setTimeout(() => resolve(null), 3_000)),
    ]);
    await client.close().catch(() => {});
    await Promise.race([
      openCall,
      new Promise((resolve) => setTimeout(resolve, 500)),
    ]);
    if (!closeInfo || Date.now() - stoppedAt >= 3_000) {
      throw new Error(`HTTP daemon did not drain its active provider: ${stderr}`);
    }
    try {
      process.kill(providerPid, 0);
      throw new Error(`provider child ${providerPid} survived HTTP shutdown`);
    } catch (error) {
      if (error?.code !== "ESRCH") throw error;
    }
  } else {
    const versionNegotiation = scenario === "modern"
      ? { mode: { pin: "2026-07-28" } }
      : { mode: "legacy" };
    const client = new Client(
      { name: `mcp-agents-${scenario}-http-test`, version: "0.0.0" },
      { versionNegotiation },
    );
    const transport = new StreamableHTTPClientTransport(
      new URL(`http://127.0.0.1:${port}/mcp`),
      {
        requestInit: {
          headers: {
            Authorization: authorization,
            "X-Mcp-Agents-Project-Root": projectRoot,
          },
        },
      },
    );
    try {
      await client.connect(transport);
      const expectedEra = scenario === "modern" ? "modern" : "legacy";
      if (client.getProtocolEra() !== expectedEra) {
        throw new Error(`expected ${expectedEra}, got ${client.getProtocolEra()}`);
      }
      const result = await client.callTool({ name: "ping", arguments: {} });
      if (result.content?.[0]?.text !== "pong") {
        throw new Error(`unexpected ping result: ${JSON.stringify(result)}`);
      }
      const readyCount = (stderr.match(
        new RegExp(`ready \\(provider: gemini, era=${expectedEra}\\)`, "gu"),
      ) ?? []).length;
      if (readyCount !== 1) {
        throw new Error(`provider readiness was logged ${readyCount} times`);
      }
    } finally {
      await client.close().catch(() => {});
    }
  }
} finally {
  await stop();
}
EOF
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (exit $status)"
    cat "$output_file"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$tmpdir"
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

  set +e
  OUTPUT=$($SERVER $flag 2>/dev/null)
  EXIT_CODE=$?
  set -e

  if [ "$EXIT_CODE" -eq 0 ] && printf '%s' "$OUTPUT" | grep -Fq -- "$expected"; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (exit=$EXIT_CODE, expected '$expected' in output)"
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

# ── Helper: test an invalid workspace-network environment value ──
test_codex_workspace_network_env_error() {
  local label="$1"
  local value="$2"
  local expected="$3"

  echo "--- $label ---"

  STDERR_OUTPUT=$(env MCP_AGENTS_CODEX_WORKSPACE_NETWORK_ACCESS="$value" \
    $SERVER --provider codex 2>&1 >/dev/null) || true

  if echo "$STDERR_OUTPUT" | grep -q "$expected"; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (expected '$expected' in stderr)"
    echo "  Stderr: $STDERR_OUTPUT"
    FAIL=$((FAIL + 1))
  fi
}

# ── Helper: the HTTP auth helper must fail closed when its token is absent ──
test_http_auth_headers_missing_token() {
  local label="$1"
  local tmpdir stderr_output status

  echo "--- $label ---"

  tmpdir=$(mktemp -d)
  set +e
  stderr_output=$($SERVER http-auth-headers \
    --http-token-file "$tmpdir/missing-token" 2>&1 >/dev/null)
  status=$?
  set -e

  if [ "$status" -ne 0 ] &&
    printf '%s' "$stderr_output" | grep -Fq "HTTP bearer token file does not exist"; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (exit=$status)"
    echo "  Stderr: $stderr_output"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$tmpdir"
}

test_http_token_parent_safety() {
  local label="$1"
  local tmpdir shared_dir stderr_output status mode

  echo "--- $label ---"
  tmpdir=$(mktemp -d)
  shared_dir="$tmpdir/shared"
  mkdir "$shared_dir"
  chmod 0755 "$shared_dir"
  set +e
  stderr_output=$($TIMEOUT_CMD 2 $SERVER --provider gemini \
    --transport http --http-port 18766 \
    --http-token-file "$shared_dir/bearer-token" 2>&1 >/dev/null)
  status=$?
  set -e
  mode=$(node -e 'console.log((require("node:fs").statSync(process.argv[1]).mode & 0o777).toString(8))' \
    "$shared_dir")

  if [ "$status" -ne 0 ] && [ "$status" -ne 124 ] && [ "$mode" = "755" ] &&
    printf '%s' "$stderr_output" | grep -Fq "directory permissions"; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (exit=$status, mode=$mode)"
    echo "  Stderr: $stderr_output"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$tmpdir"
}

# ========== CLI flag tests ==========

test_cli_flag "--help prints usage"         "--help"    "Usage:"
test_cli_flag "--help shows GPT-6 Astra default" "--help" "gpt-6-astra"
test_cli_flag "--help shows xhigh default"  "--help"    "xhigh"
test_cli_flag "--help shows workspace-write default" "--help" "workspace-write"
test_cli_flag "--help shows never default"  "--help"    "never"
test_cli_flag "--help shows workspace network default" "--help" "--codex-workspace-network"
test_cli_flag "--help shows codex_idle_timeout" "--help" "codex_idle_timeout"
test_cli_flag "--help shows codex_status_interval default" "--help" "codex_status_interval"
test_cli_flag "--help shows durable Codex state root" "--help" "--codex-state-root"
test_cli_flag "--help explains Codex retention scope" "--help" "vscode sessions are retained"
test_cli_flag "--help shows goal flag"      "--help"    "Native durable goal"
test_cli_flag "--help shows browser provider" "--help" "browser_lease_command"
test_cli_flag "--help shows browser downstream fallback" "--help" "npx chrome-devtools-mcp@latest"
test_cli_flag "--help shows provider timeout defaults" "--help" "claude 900, browser 600, gemini 300"
test_cli_flag "--help shows additive stdio and HTTP transports" "--help" "--transport <stdio|http>"
test_cli_flag "--help shows the HTTP runtime idle timeout" "--help" "--http-runtime-idle-timeout"
test_cli_flag "--help shows the HTTP auth helper" "--help" "http-auth-headers"
test_cli_flag "-h prints usage"             "-h"        "Usage:"
test_cli_flag "--version prints version"    "--version"  "mcp-agents v"
test_cli_flag "-v prints version"           "-v"        "mcp-agents v"
test_cli_error "--bogus exits with error"   "--bogus"   "unknown option"
test_cli_error "--provider without value"                  "--provider"                 "requires a value"
test_cli_error "--model without value"                     "--model"                    "requires a value"
test_cli_error "--model_reasoning_effort without value"    "--model_reasoning_effort"   "requires a value"
test_cli_error "--sandbox_mode without value"              "--sandbox_mode"             "requires a value"
test_cli_error "--approval_policy without value"           "--approval_policy"          "requires a value"
test_cli_error "--codex-workspace-network without value"    "--codex-workspace-network"   "requires a value"
test_cli_error "--codex-workspace-network invalid value"    "--codex-workspace-network maybe" "must be true or false"
test_cli_error "--codex-workspace-network invalid inline"   "--codex-workspace-network=maybe" "must be true or false"
test_codex_workspace_network_env_error \
  "workspace network env rejects invalid value" "maybe" "must be true or false"
test_cli_error "--goal without value"                      "--goal"                     "requires a value"
test_cli_error "--transport without value"                 "--transport"                "requires a value"
test_cli_error "--transport rejects unknown values"        "--transport pipe"           "must be stdio or http"
test_cli_error "--http-port without value"                 "--http-port"                "requires a value"
test_cli_error "--http-port rejects zero"                  "--http-port 0"              "integer from 1 to 65535"
test_cli_error "--http-port rejects values above 65535"    "--http-port 65536"          "integer from 1 to 65535"
test_cli_error "--http-runtime-idle-timeout without value" "--http-runtime-idle-timeout" "requires a value"
test_cli_error "--http-runtime-idle-timeout rejects negative values" \
  "--http-runtime-idle-timeout -1" "non-negative number"
test_cli_error "--http-token-file without value"           "--http-token-file"          "requires a value"
test_cli_error "--http-token-file rejects relative paths"  "--http-token-file token"    "must be absolute"
test_cli_error "--timeout without value"                    "--timeout"                  "requires a value"
test_cli_error "--timeout with zero"                        "--timeout 0"                "must be a positive number"
test_cli_error "--timeout with negative"                    "--timeout -5"               "must be a positive number"
test_cli_error "--timeout with non-number"                  "--timeout abc"              "must be a positive number"
test_cli_error "--timeout below the browser reserve" \
  "--provider browser --timeout 10" "too small for --provider browser"
test_cli_error "--timeout at the browser reserve boundary" \
  "--provider browser --timeout 19" "too small for --provider browser"
# One above the boundary must CLEAR this check: it falls through to the next
# validation, which proves the budget gate accepted it rather than exiting here.
test_cli_error "--timeout just above the browser reserve is accepted" \
  "--provider browser --timeout 20" "browser_lease_command"
test_cli_error "--codex_idle_timeout without value"         "--codex_idle_timeout"       "requires a value"
test_cli_error "--codex_idle_timeout non-number"            "--codex_idle_timeout abc"   "non-negative number"
test_cli_error "--codex_idle_timeout negative"              "--codex_idle_timeout -1"    "non-negative number"
test_cli_error "--codex_status_interval without value"      "--codex_status_interval"     "requires a value"
test_cli_error "--codex_status_interval non-number"         "--codex_status_interval abc" "non-negative number"
test_cli_error "--codex_status_interval negative"           "--codex_status_interval -1"  "non-negative number"
test_cli_error "--codex-state-root without value"          "--codex-state-root"          "requires a value"
test_cli_error "--codex-state-root rejects relative paths" "--codex-state-root relative" "must be absolute"
test_cli_error "--codex session retention without value"   "--codex-session-retention-days" "requires a value"
test_cli_error "--codex session retention rejects fractions" "--codex-session-retention-days 1.5" "non-negative integer"
for non_codex_provider in claude gemini browser; do
  test_cli_error \
    "--codex-state-root rejects $non_codex_provider" \
    "--provider $non_codex_provider --codex-state-root /tmp/mcp-agents-test-state" \
    "only supported by --provider codex"
  test_cli_error \
    "--codex session retention rejects $non_codex_provider" \
    "--provider $non_codex_provider --codex-session-retention-days 30" \
    "only supported by --provider codex"
done
test_cli_error "App Server rejects legacy on-failure approvals" \
  "--provider codex --approval_policy on-failure" \
  "only supported by --provider codex-legacy"
test_cli_error "App Server rejects on-failure before provider selection" \
  "--approval_policy on-failure --provider codex" \
  "only supported by --provider codex-legacy"
test_cli_error "--browser_lease_command without value"       "--provider browser --browser_lease_command" "requires a value"
test_cli_error "--browser_command without value"             "--provider browser --browser_command" "requires a value"
test_cli_error "--browser_idle_timeout rejects negative"      "--provider browser --browser_idle_timeout -1" "non-negative number"
test_cli_error "--browser_viewport rejects malformed value"   "--provider browser --browser_viewport wide" "positive WxH"
test_cli_error "--browser_app_port rejects invalid port"      "--provider browser --browser_app_port 70000" "integer from 1 to 65535"
test_cli_error "browser flags reject the Claude provider"     "--provider claude --browser_idle_timeout 1" "only valid with --provider browser"
test_cli_error "browser flags reject the Gemini provider"     "--provider gemini --browser_viewport 800x600" "only valid with --provider browser"
test_cli_error "browser flags reject the Codex provider"      "--provider codex --browser_command fake" "only valid with --provider browser"
test_cli_error "browser provider requires an injected lease helper" "--provider browser" "browser_lease_command"
test_cli_error "HTTP rejects the browser byte proxy" \
  "--transport http --provider browser" "HTTP transport is not supported by --provider browser"
test_cli_error "HTTP rejects the frozen Codex native proxy" \
  "--transport http --provider codex-legacy" "HTTP transport is not supported by --provider codex-legacy"
test_http_auth_headers_missing_token \
  "HTTP auth helper fails closed when its token file is absent"
test_http_token_parent_safety \
  "HTTP token creation never chmods an existing shared parent"

# ========== Protocol tests (fast) ==========

# ---------- Shared loopback HTTP daemon ----------
test_http_daemon_case \
  "HTTP daemon creates a private token and emits Claude auth headers" "token"
test_http_daemon_case \
  "HTTP daemon rejects unauthorized and cross-origin requests" "security"
test_http_daemon_case \
  "HTTP daemon serves MCP 2026 requests" "modern"
test_http_daemon_case \
  "HTTP daemon preserves stateless legacy requests" "legacy"
test_http_daemon_case \
  "HTTP daemon drains an active provider child on shutdown" "shutdown"

# ---------- MCP 2026-07-28 modern negotiation ----------
test_modern_stdio_provider \
  "modern stdio --provider codex → codex" "codex" "codex"
test_modern_stdio_provider \
  "modern stdio --provider claude → claude_code" "claude" "claude_code"
test_modern_stdio_provider \
  "modern stdio --provider gemini → gemini" "gemini" "gemini"

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
test_claude_tools_schema "Claude tools/list advertises the complete one-shot job API" \
  '(.result.tools | map(.name) | sort) ==
    ["claude-cancel","claude-result","claude-start","claude-status","claude_code","ping"]'
test_claude_tools_schema "Claude job tools expose closed operational schemas" \
  '(.result.tools | map({key:.name,value:.}) | from_entries) as $t |
   (($t["claude-start"].inputSchema |
      (.additionalProperties == false) and
      (.required == ["prompt","cwd"]) and
      ((.properties | keys | sort) == ["cwd","prompt"]) and
      (.properties.cwd.type == "string")) and
    ($t["claude-status"].inputSchema |
      (.additionalProperties == false) and
      (.required == ["jobId","cursor"]) and
      ((.properties | keys | sort) == ["cursor","jobId","wait_ms"]) and
      (.properties.cursor.minimum == 0) and
      (.properties.wait_ms.maximum == 60000)) and
    ($t["claude-result"].inputSchema |
      (.additionalProperties == false) and
      (.required == ["jobId"]) and
      ((.properties | keys | sort) == ["jobId","offset"]) and
      (.properties.offset.minimum == 0)) and
    ($t["claude-cancel"].inputSchema |
      (.additionalProperties == false) and
      (.required == ["jobId"]) and
      ((.properties | keys) == ["jobId"])))'
test_claude_tools_schema "legacy claude_code keeps prompt and caller timeout compatibility" \
  '(.result.tools | map(select(.name == "claude_code"))[0].inputSchema) as $s |
   ($s.additionalProperties == true) and
   ($s.required == ["prompt"]) and
   (($s.properties | keys | sort) == ["prompt","timeout_ms"]) and
   ($s.properties.timeout_ms.minimum == 1)'

# ---------- Gemini provider ----------
test_tools_list "tools/list --provider gemini → gemini (300s default)" \
  "gemini" "gemini" "300000"
test_handshake  "handshake --provider gemini → gemini"  "gemini" "gemini"

# ========== Integration tests (call real CLIs) ==========

# ── Helper: verify wrapper-owned Codex App Server discovery. ──
test_codex_app_discovery() {
  local label="$1"
  local output_file state_dir
  local status
  echo "--- $label ---"

  output_file=$(mktemp)
  state_dir=$(mktemp -d)
  set +e
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"0.0.1"}}}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
    sleep 3
  } | $TIMEOUT_CMD 10 $SERVER --provider codex \
    --codex-state-root "$state_dir" >"$output_file" 2>/dev/null
  status=$?
  set -e
  RESPONSE=$(cat "$output_file")
  rm -f "$output_file"
  rm -rf "$state_dir"

  if [ "$status" -ne 0 ]; then
    red "FAIL: $label (exit $status)"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  elif echo "$RESPONSE" | jq -s -e '
    ([.[] | select(.id == 2)][0].result.tools | map(.name)) as $names |
    (["codex","codex-reply","codex-start","codex-review",
      "codex-thread-list","codex-interactions"] - $names | length == 0) and
    ([.[] | select(
      .method == "codex/event" or
      (((.method // "") | startswith("thread/")) or
       ((.method // "") | startswith("turn/")) or
       ((.method // "") | startswith("item/"))))] | length == 0)
  ' >/dev/null 2>&1; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  fi
}

# ── Helper: verify a real read-only App Server turn and isolated state. ──
test_codex_isolated_runtime() {
  local label="$1"
  local tmpdir state_root state_root_canonical output_file error_file shim_dir capture_dir
  local status state_mode real_codex isolated_home config_ok home_ok

  echo "--- $label ---"

  tmpdir=$(mktemp -d)
  state_root="$tmpdir/state"
  mkdir -p "$state_root"
  state_root_canonical=$(CDPATH='' cd -- "$state_root" && pwd -P)
  output_file="$tmpdir/output.jsonl"
  error_file="$tmpdir/stderr.txt"
  shim_dir="$tmpdir/bin"
  capture_dir="$tmpdir/capture"
  mkdir -p "$shim_dir" "$capture_dir"
  real_codex=$(command -v codex || true)
  if [ -z "$real_codex" ]; then
    red "FAIL: $label (codex executable not found)"
    FAIL=$((FAIL + 1))
    rm -rf "$tmpdir"
    return
  fi
  cat >"$shim_dir/codex" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "app-server" ]; then
  printf '%s' "$CODEX_HOME" > "$MCP_AGENTS_REAL_CODEX_CAPTURE/codex-home"
  cp "$CODEX_HOME/config.toml" "$MCP_AGENTS_REAL_CODEX_CAPTURE/config.toml"
fi
exec "$MCP_AGENTS_REAL_CODEX" "$@"
EOF
  chmod +x "$shim_dir/codex"
  set +e
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"0.0.1"}}}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    sleep 0.3
    printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"codex\",\"arguments\":{\"prompt\":\"Reply with ONLY OK\",\"cwd\":\"$(pwd)\",\"sandbox\":\"read-only\",\"model_reasoning_effort\":\"max\"}}}"
    sleep 60
  } | PATH="$shim_dir:$PATH" MCP_AGENTS_REAL_CODEX="$real_codex" \
    MCP_AGENTS_REAL_CODEX_CAPTURE="$capture_dir" \
    $TIMEOUT_CMD 90 $SERVER --provider codex \
    --codex-state-root "$state_root" >"$output_file" 2>"$error_file"
  status=$?
  set -e
  RESPONSE=$(cat "$output_file")
  state_mode=$(stat -f '%Lp' "$state_root" 2>/dev/null || \
    stat -c '%a' "$state_root" 2>/dev/null || true)
  isolated_home=$(cat "$capture_dir/codex-home" 2>/dev/null || true)
  config_ok=0
  if [ -f "$capture_dir/config.toml" ] &&
    grep -Fq 'apps = false' "$capture_dir/config.toml" &&
    grep -Fq 'hooks = false' "$capture_dir/config.toml" &&
    grep -Fq 'plugins = false' "$capture_dir/config.toml" &&
    grep -Fq 'multi_agent = false' "$capture_dir/config.toml" &&
    ! grep -Fq '[mcp_servers' "$capture_dir/config.toml"; then
    config_ok=1
  fi
  home_ok=1
  case "$isolated_home" in
    ""|"$TEST_REPO_ROOT"|"$TEST_REPO_ROOT"/*) home_ok=0 ;;
  esac

  if [ "$status" -ne 0 ]; then
    red "FAIL: $label (exit $status)"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  elif ! echo "$RESPONSE" | jq -s -e '
    ([.[] | select(.id == 2)] | length == 1) and
    ([.[] | select(.id == 2)][0].result |
      (.isError != true) and
      (.structuredContent.threadId | type == "string" and length > 0) and
      (.structuredContent.content | type == "string" and contains("OK"))) and
    ([.[] | select(
      .method == "codex/event" or
      (((.method // "") | startswith("thread/")) or
       ((.method // "") | startswith("turn/")) or
       ((.method // "") | startswith("item/"))))] | length == 0)
  ' >/dev/null 2>&1; then
    red "FAIL: $label (wrapper result or App Server isolation was unexpected)"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  elif [ ! -d "$state_root/projects" ] || [ "$state_mode" != "700" ]; then
    red "FAIL: $label (private external state was not created with mode 0700)"
    echo "  State: $state_root (mode=${state_mode:-missing})"
    FAIL=$((FAIL + 1))
  elif [ "$home_ok" -ne 1 ] || [ "$config_ok" -ne 1 ]; then
    red "FAIL: $label (isolated CODEX_HOME/config contract was not preserved)"
    echo "  CODEX_HOME: ${isolated_home:-missing}"
    echo "  Config: $(cat "$capture_dir/config.toml" 2>/dev/null || true)"
    FAIL=$((FAIL + 1))
  elif ! grep -Fq "state=$state_root_canonical/projects/" "$error_file"; then
    red "FAIL: $label (adapter did not report the isolated external state root)"
    echo "  Stderr: $(cat "$error_file")"
    FAIL=$((FAIL + 1))
  else
    green "PASS: $label"
    PASS=$((PASS + 1))
  fi
  rm -rf "$tmpdir"
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

# ── Helper: verify shutdown survives a client closing stderr first ──
test_closed_stderr_shutdown() {
  local label="$1"
  local tmpdir output_file status

  echo "--- $label ---"

  tmpdir=$(mktemp -d)
  output_file=$(mktemp)
  set +e
  MCP_AGENTS_TEST_STATE_ROOT="$tmpdir/state" \
    node --input-type=module >"$output_file" 2>&1 <<'EOF'
import { spawn } from "node:child_process";
import { appendFileSync } from "node:fs";

const child = spawn(process.execPath, [
  "server.js",
  "--provider",
  "codex",
  "--codex-state-root",
  process.env.MCP_AGENTS_TEST_STATE_ROOT,
], {
  cwd: process.cwd(),
  detached: true,
  stdio: ["pipe", "pipe", "pipe"],
});

appendFileSync(process.env.MCP_AGENTS_TEST_CHILD_REGISTRY, `${child.pid}\n`);
child.stdout.resume();
const closed = new Promise((resolve) => {
  child.once("exit", (code, signal) => resolve({ kind: "exit", code, signal }));
});
child.stderr.setEncoding("utf8");
let stderr = "";
const ready = new Promise((resolve) => {
  child.stderr.on("data", (chunk) => {
    stderr += chunk;
    if (stderr.includes("Codex MCP adapter listening")) resolve({ kind: "ready" });
  });
});
let startupTimeout;
const startup = await Promise.race([
  ready,
  closed,
  new Promise((resolve) => {
    startupTimeout = setTimeout(() => resolve({ kind: "startup-timeout" }), 5_000);
  }),
]);
clearTimeout(startupTimeout);
if (startup.kind !== "ready") {
  try { process.kill(-child.pid, "SIGKILL"); } catch {}
  await Promise.race([
    closed,
    new Promise((resolve) => setTimeout(resolve, 1_000)),
  ]);
  console.error(`bridge did not become ready: ${JSON.stringify(startup)}\n${stderr}`);
  process.exit(123);
}

child.stderr.destroy();
child.stdin.end();

let timeout;
const result = await Promise.race([
  closed,
  new Promise((resolve) => {
    timeout = setTimeout(() => resolve({ kind: "timeout" }), 3_000);
  }),
]);
clearTimeout(timeout);

if (result.kind === "timeout") {
  try { process.kill(-child.pid, "SIGKILL"); } catch {}
  await Promise.race([
    closed,
    new Promise((resolve) => setTimeout(resolve, 1_000)),
  ]);
  console.error("bridge timed out after stderr closed");
  process.exit(124);
}
if (result.signal !== null) {
  console.error(`bridge exited from signal ${result.signal}`);
  process.exit(125);
}
if (result.code !== 0) {
  console.error(`bridge exited with status ${result.code}`);
  process.exit(126);
}
EOF
  status=$?
  set -e

  case "$status" in
    0)
      green "PASS: $label"
      PASS=$((PASS + 1))
      ;;
    123)
      red "FAIL: $label (bridge did not become ready)"
      cat "$output_file"
      FAIL=$((FAIL + 1))
      ;;
    124)
      red "FAIL: $label (bridge survived closed stderr past 3 seconds)"
      cat "$output_file"
      FAIL=$((FAIL + 1))
      ;;
    125)
      red "FAIL: $label (bridge exited from a signal)"
      cat "$output_file"
      FAIL=$((FAIL + 1))
      ;;
    *)
      red "FAIL: $label (exit $status)"
      cat "$output_file"
      FAIL=$((FAIL + 1))
      ;;
  esac
  rm -rf "$tmpdir"
  rm -f "$output_file"
}

# ── Helper: verify an over-limit frame cannot leave an orphaned bridge ──
# The stdio transport closes itself when a single frame exceeds its read
# buffer, and closing pauses stdin -- so the 'end' event the bridge normally
# shuts down on never arrives. Without a transport-close hook the keepAlive
# interval then holds the process open forever.
test_oversized_frame_shutdown() {
  local label="$1"
  local tmpdir output_file status

  echo "--- $label ---"

  tmpdir=$(mktemp -d)
  output_file=$(mktemp)
  set +e
  MCP_AGENTS_TEST_STATE_ROOT="$tmpdir/state" \
    node --input-type=module >"$output_file" 2>&1 <<'EOF'
import { spawn } from "node:child_process";
import { appendFileSync } from "node:fs";

const child = spawn(process.execPath, [
  "server.js",
  "--provider",
  "codex",
  "--codex-state-root",
  process.env.MCP_AGENTS_TEST_STATE_ROOT,
], {
  cwd: process.cwd(),
  detached: true,
  stdio: ["pipe", "pipe", "pipe"],
});

appendFileSync(process.env.MCP_AGENTS_TEST_CHILD_REGISTRY, `${child.pid}\n`);
child.stdout.resume();
child.stdin.on("error", () => {});
const closed = new Promise((resolve) => {
  child.once("exit", (code, signal) => resolve({ kind: "exit", code, signal }));
});
child.stderr.setEncoding("utf8");
let stderr = "";
const ready = new Promise((resolve) => {
  child.stderr.on("data", (chunk) => {
    stderr += chunk;
    if (stderr.includes("Codex MCP adapter listening")) resolve({ kind: "ready" });
  });
});
let startupTimeout;
const startup = await Promise.race([
  ready,
  closed,
  new Promise((resolve) => {
    startupTimeout = setTimeout(() => resolve({ kind: "startup-timeout" }), 5_000);
  }),
]);
clearTimeout(startupTimeout);
if (startup.kind !== "ready") {
  try { process.kill(-child.pid, "SIGKILL"); } catch {}
  await Promise.race([
    closed,
    new Promise((resolve) => setTimeout(resolve, 1_000)),
  ]);
  console.error(`bridge did not become ready: ${JSON.stringify(startup)}\n${stderr}`);
  process.exit(123);
}

// One frame past the transport's 10 MiB read buffer, with no framing newline.
child.stdin.write(`{"jsonrpc":"2.0","id":1,"method":"ping","params":{"pad":"${"x".repeat(11 * 1024 * 1024)}`);

let timeout;
const result = await Promise.race([
  closed,
  new Promise((resolve) => {
    timeout = setTimeout(() => resolve({ kind: "timeout" }), 5_000);
  }),
]);
clearTimeout(timeout);

if (result.kind === "timeout") {
  try { process.kill(-child.pid, "SIGKILL"); } catch {}
  await Promise.race([
    closed,
    new Promise((resolve) => setTimeout(resolve, 1_000)),
  ]);
  console.error(`bridge survived an over-limit frame as an orphan\n${stderr}`);
  process.exit(124);
}
if (result.signal !== null) {
  console.error(`bridge exited from signal ${result.signal}\n${stderr}`);
  process.exit(125);
}
if (result.code !== 0) {
  console.error(`bridge exited with status ${result.code}\n${stderr}`);
  process.exit(126);
}
if (!stderr.includes("(transport-close)")) {
  console.error(`bridge did not shut down through the transport close hook\n${stderr}`);
  process.exit(127);
}
EOF
  status=$?
  set -e

  case "$status" in
    0)
      green "PASS: $label"
      PASS=$((PASS + 1))
      ;;
    123)
      red "FAIL: $label (bridge did not become ready)"
      cat "$output_file"
      FAIL=$((FAIL + 1))
      ;;
    124)
      red "FAIL: $label (bridge survived an over-limit frame)"
      cat "$output_file"
      FAIL=$((FAIL + 1))
      ;;
    125)
      red "FAIL: $label (bridge exited from a signal)"
      cat "$output_file"
      FAIL=$((FAIL + 1))
      ;;
    127)
      red "FAIL: $label (shutdown did not come from the transport close hook)"
      cat "$output_file"
      FAIL=$((FAIL + 1))
      ;;
    *)
      red "FAIL: $label (exit $status)"
      cat "$output_file"
      FAIL=$((FAIL + 1))
      ;;
  esac
  rm -rf "$tmpdir"
  rm -f "$output_file"
}

# ── Helper: fake Claude CLI for background-job contract tests. It captures ──
# argv/cwd/stdin per process and emits deterministic stream-json, including
# fragmented, malformed, and unknown frames that the bridge must safely ignore.
write_claude_job_stub() {
  cat >"$1/claude" <<'EOF'
#!/usr/bin/env node
const fs = require("fs");
const path = require("path");

const captureDir = process.env.MCP_STUB_CLAUDE_CAPTURE_DIR;
const base = path.join(captureDir, String(process.pid));
const argv = process.argv.slice(2);
const streaming = argv.includes("stream-json");
fs.appendFileSync(process.env.MCP_AGENTS_TEST_CHILD_REGISTRY, `${process.pid}\n`);
fs.writeFileSync(`${base}.json`, JSON.stringify({
  pid: process.pid,
  argv,
  cwd: process.cwd(),
  streaming,
}));

let input = "";
let prompt = "";
let started = false;
const timers = [];
const later = (delay, fn) => timers.push(setTimeout(fn, delay));
const appendSignal = (value) =>
  fs.appendFileSync(`${base}.signals`, `${value}\n`);
const emit = (value) =>
  process.stdout.write(`${JSON.stringify(value)}\n`);
const emitSplit = (value, onFlushed = () => {}) => {
  const line = `${JSON.stringify(value)}\n`;
  // Fragment only inside the ASCII JSON prefix. Splitting a JS string between
  // UTF-16 surrogate halves would make the stub itself corrupt astral text.
  const splitAt = Math.min(17, line.length - 1);
  process.stdout.write(line.slice(0, splitAt));
  later(8, () => process.stdout.write(line.slice(splitAt), onFlushed));
};
const promptText = (message) => {
  const content = message?.message?.content;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .filter((part) => part?.type === "text" && typeof part.text === "string")
    .map((part) => part.text)
    .join("");
};
const finishReview = () => {
  if (started) return;
  started = true;
  if (prompt.startsWith("TIMEOUT") || prompt.startsWith("HANG")) {
    emit({ type: "system", subtype: "init", session_id: `stub-${process.pid}` });
    return;
  }

  later(5, () => emitSplit({
    type: "system",
    subtype: "init",
    session_id: `stub-${process.pid}`,
  }));
  later(20, () => process.stdout.write("this is not json\n"));
  later(25, () => emit({
    type: "future_event",
    prompt: "SENTINEL_PROMPT",
    reasoning: "SENTINEL_REASONING",
  }));
  later(35, () => emit({
    type: "assistant",
    message: {
      role: "assistant",
      content: [{ type: "text", text: "SENTINEL_DRAFT" }],
    },
  }));
  later(45, () => emit({
    type: "stream_event",
    event: {
      type: "content_block_delta",
      delta: { type: "text_delta", text: "SENTINEL_PARTIAL" },
    },
  }));
  later(55, () => emit({
    type: "tool_progress",
    tool_name: "SENTINEL_TOOL",
    command: "SENTINEL_COMMAND",
    path: "/SENTINEL_PATH",
    output: "SENTINEL_OUTPUT",
    prompt: "SENTINEL_PROGRESS_PROMPT",
  }));

  let result = "CLAUDE_REVIEW_OK";
  if (prompt.startsWith("PAGE")) result = "🚀".repeat(32_780);
  if (prompt.startsWith("OVERSIZE")) {
    result = "O".repeat((10 * 1024 * 1024) + 1_024);
  }
  if (prompt.startsWith("EMPTY_THEN_OK")) {
    const attemptFile = path.join(captureDir, "empty-attempt-count");
    let attempt = 0;
    try { attempt = Number(fs.readFileSync(attemptFile, "utf8")); } catch {}
    attempt += 1;
    fs.writeFileSync(attemptFile, String(attempt));
    result = attempt === 1 ? "" : "CLAUDE_RETRY_OK";
  }
  if (prompt.startsWith("PROVIDER_ERROR")) {
    later(80, () => emitSplit(
      {
        type: "result",
        subtype: "error",
        is_error: true,
        result: "SENTINEL_PROVIDER_ERROR",
      },
      () => later(10, () => process.exit(0)),
    ));
  } else {
    later(80, () => emitSplit(
      {
        type: "result",
        subtype: "success",
        is_error: false,
        result,
      },
      () => later(10, () => process.exit(0)),
    ));
  }
};

process.on("SIGTERM", () => {
  appendSignal("SIGTERM");
  if (!prompt.startsWith("TIMEOUT")) process.exit(0);
});
process.on("SIGINT", () => {
  appendSignal("SIGINT");
  if (!prompt.startsWith("TIMEOUT")) process.exit(0);
});

process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  fs.appendFileSync(`${base}.stdin`, chunk);
  input += chunk;
  let newline;
  while ((newline = input.indexOf("\n")) !== -1) {
    const line = input.slice(0, newline);
    input = input.slice(newline + 1);
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      continue;
    }
    if (message?.type === "user" && !started) {
      prompt = promptText(message);
      finishReview();
    }
    if (
      message?.type === "control_request" &&
      message?.request?.subtype === "interrupt"
    ) {
      appendSignal("CONTROL_INTERRUPT");
      if (!prompt.startsWith("TIMEOUT")) later(10, () => process.exit(0));
    }
  }
});
process.stdin.on("end", () => {
  if (streaming) return;
  prompt = input;
  emit({
    type: "result",
    subtype: "success",
    is_error: false,
    result: "LEGACY_CLAUDE_OK",
  });
  later(10, () => process.exit(0));
});
setInterval(() => {}, 1 << 30);
EOF
  chmod +x "$1/claude"
}

# Drives the Claude wrapper-owned background tools and emits one JSON summary.
write_claude_job_driver() {
  cat >"$1/claude-job-driver.mjs" <<'EOF'
import { spawn } from "node:child_process";
import {
  mkdirSync,
  readFileSync,
  readdirSync,
} from "node:fs";

const [stubDir, serverDir, scenario] = process.argv.slice(2);
const captureDir = `${stubDir}/captures`;
mkdirSync(captureDir, { recursive: true });
const terminalStates = new Set(["completed", "failed", "canceled"]);
const child = spawn("node", ["server.js", "--provider", "claude"], {
  cwd: serverDir,
  env: {
    ...process.env,
    PATH: `${stubDir}:${process.env.PATH}`,
    MCP_STUB_CLAUDE_CAPTURE_DIR: captureDir,
    MCP_AGENTS_TEST_CLAUDE_JOB_TIMEOUT_MS:
      scenario === "timeout" ? "400" : "4000",
    MCP_AGENTS_TEST_CLAUDE_JOB_RETENTION_MS:
      scenario === "retention" ? "80" : "3600000",
    MCP_AGENTS_TEST_CLAUDE_CANCEL_TERM_MS: "35",
    MCP_AGENTS_TEST_CLAUDE_CANCEL_KILL_MS: "35",
    MCP_AGENTS_TEST_CLAUDE_MAX_ACTIVE_JOBS:
      scenario === "capacity" ? "2" : "8",
    MCP_AGENTS_TEST_CLAUDE_MAX_RETAINED_JOBS:
      scenario === "retained" ? "2" : "32",
  },
  stdio: ["pipe", "pipe", "pipe"],
});

let stdout = "";
let stderr = "";
let parseBuffer = "";
let nextId = 2;
let driverError;
const frames = [];
const pending = new Map();
const data = {
  starts: [],
  statuses: [],
  results: [],
  cancels: [],
  invalid: [],
  pings: [],
};

child.stdin.on("error", () => {});
child.stdout.setEncoding("utf8");
child.stderr.setEncoding("utf8");
child.stderr.on("data", (chunk) => { stderr += chunk; });
const send = (message) => {
  if (child.stdin.writable) {
    child.stdin.write(`${JSON.stringify(message)}\n`);
  }
};
const request = (method, params, id = nextId++) => new Promise((resolve, reject) => {
  const timer = setTimeout(() => {
    pending.delete(JSON.stringify(id));
    reject(new Error(`request ${JSON.stringify(id)} timed out`));
  }, 3_500);
  pending.set(JSON.stringify(id), {
    resolve: (frame) => {
      clearTimeout(timer);
      resolve(frame);
    },
  });
  send({ jsonrpc: "2.0", id, method, params });
});
const callTool = (name, args, id, meta) => request(
  "tools/call",
  {
    name,
    arguments: args,
    ...(meta ? { _meta: meta } : {}),
  },
  id,
);
const structured = (frame) => frame?.result?.structuredContent;
const startJob = async (prompt) => {
  const frame = await callTool("claude-start", { prompt, cwd: serverDir });
  data.starts.push(frame);
  const jobId = structured(frame)?.jobId;
  if (typeof jobId !== "string" || !jobId) {
    throw new Error(`claude-start did not return a jobId: ${JSON.stringify(frame)}`);
  }
  return { jobId, cursor: structured(frame).cursor ?? 0 };
};
const status = async (jobId, cursor, waitMs = 100) => {
  const frame = await callTool(
    "claude-status",
    { jobId, cursor, wait_ms: waitMs },
  );
  data.statuses.push(frame);
  return frame;
};
const statusUntilTerminal = async (jobId, initialCursor = 0) => {
  let cursor = initialCursor;
  for (let attempt = 0; attempt < 40; attempt += 1) {
    const frame = await status(jobId, cursor, 120);
    const value = structured(frame);
    if (!value) throw new Error(`status missing structuredContent: ${JSON.stringify(frame)}`);
    if (terminalStates.has(value.state)) return frame;
    cursor = value.cursor;
  }
  throw new Error(`job ${jobId} did not become terminal`);
};
const result = async (jobId, offset = 0) => {
  const frame = await callTool("claude-result", { jobId, offset });
  data.results.push(frame);
  return frame;
};
const cancel = async (jobId) => {
  const frame = await callTool("claude-cancel", { jobId });
  data.cancels.push(frame);
  return frame;
};
const ping = async () => {
  const frame = await callTool("ping", {});
  data.pings.push(frame);
  return frame;
};
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const waitForCaptureCount = async (expected) => {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    const count = readdirSync(captureDir)
      .filter((name) => name.endsWith(".json"))
      .length;
    if (count >= expected) return;
    await delay(20);
  }
  throw new Error(`expected ${expected} Claude captures`);
};
const capturedPidForPrompt = (expectedPrompt) => {
  for (const name of readdirSync(captureDir).filter((item) => item.endsWith(".stdin"))) {
    const base = `${captureDir}/${name.slice(0, -6)}`;
    const raw = readFileSync(`${base}.stdin`, "utf8");
    const matched = raw
      .split("\n").filter(Boolean)
      .flatMap((line) => {
        try { return [JSON.parse(line)]; } catch { return []; }
      })
      .some((message) =>
        message?.type === "user" &&
        message?.message?.content === expectedPrompt
      );
    if (matched) return JSON.parse(readFileSync(`${base}.json`, "utf8")).pid;
  }
  return undefined;
};
const pidIsAlive = (pid) => {
  if (!pid) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

child.stdout.on("data", (chunk) => {
  const text = chunk;
  stdout += text;
  parseBuffer += text;
  let newline;
  while ((newline = parseBuffer.indexOf("\n")) !== -1) {
    const line = parseBuffer.slice(0, newline);
    parseBuffer = parseBuffer.slice(newline + 1);
    if (!line) continue;
    let frame;
    try {
      frame = JSON.parse(line);
    } catch {
      continue;
    }
    frames.push(frame);
    const waiter = pending.get(JSON.stringify(frame.id));
    if (waiter) {
      pending.delete(JSON.stringify(frame.id));
      waiter.resolve(frame);
    }
  }
});

const closed = new Promise((resolve) => {
  child.once("close", (code, signal) => resolve({ code, signal }));
});
const hardStop = setTimeout(() => {
  try { child.kill("SIGKILL"); } catch {}
}, 7_000);

try {
  await request("initialize", {
    protocolVersion: "2024-11-05",
    capabilities: {},
    clientInfo: { name: "claude-job-test", version: "0" },
  }, 1);
  send({ jsonrpc: "2.0", method: "notifications/initialized" });

  if (scenario === "lifecycle") {
    const job = await startJob("NORMAL");
    const immediate = await status(job.jobId, 0, 0);
    const terminal = await statusUntilTerminal(
      job.jobId,
      structured(immediate)?.cursor ?? job.cursor,
    );
    data.futureCursor = await status(
      job.jobId,
      (structured(terminal)?.cursor ?? 0) + 1,
      0,
    );
    await result(job.jobId);
    await ping();
    data.lifecycleJobId = job.jobId;
    data.lifecycleTerminal = terminal;
  } else if (scenario === "legacy") {
    data.legacy = await callTool("claude_code", {
      prompt: "LEGACY",
      timeout_ms: 2_000,
      model: "ignored-for-compatibility",
    });
    await ping();
  } else if (scenario === "invalid") {
    data.invalid.push(await callTool("claude-start", {
      prompt: "NORMAL",
      cwd: "relative/path",
    }));
    data.invalid.push(await callTool("claude-start", {
      prompt: "NORMAL",
      cwd: serverDir,
      timeout_ms: 1,
    }));
    data.invalid.push(await callTool("claude-status", {
      jobId: "missing-cursor",
    }));
    data.invalid.push(await callTool("claude-status", {
      jobId: "invalid-wait",
      cursor: 0,
      wait_ms: 60_001,
    }));
    await ping();
  } else if (scenario === "cancel") {
    const hanging = await startJob("HANG");
    const sibling = await startJob("NORMAL SIBLING");
    let running = await status(hanging.jobId, 0, 120);
    if ((structured(running)?.cursor ?? 0) === 0) {
      running = await status(hanging.jobId, 0, 120);
    }
    const waitCursor = structured(running)?.cursor ?? 0;
    const waiterId = "cancel-only-the-waiter";
    data.waiterId = waiterId;
    callTool(
      "claude-status",
      { jobId: hanging.jobId, cursor: waitCursor, wait_ms: 1_000 },
      waiterId,
    ).then((frame) => { data.waiterFrame = frame; }).catch(() => {});
    await delay(30);
    send({
      jsonrpc: "2.0",
      method: "notifications/cancelled",
      params: { requestId: waiterId, reason: "test waiter cancellation" },
    });
    // The MCP SDK may either deliver the handler's prompt abort result or
    // suppress the canceled request's response. Snapshot whichever observable
    // outcome occurred before the explicit job cancellation below.
    await delay(100);
    data.waiterFrameBeforeJobCancel = data.waiterFrame;
    data.afterWaiterCancel = await status(hanging.jobId, waitCursor, 0);
    const firstCancel = await cancel(hanging.jobId);
    data.hangingTerminal = await statusUntilTerminal(
      hanging.jobId,
      structured(firstCancel)?.cursor ?? waitCursor,
    );
    data.hangingPid = capturedPidForPrompt("HANG");
    data.hangingAliveAfterTerminal = pidIsAlive(data.hangingPid);
    data.secondCancel = await cancel(hanging.jobId);
    data.siblingTerminal = await statusUntilTerminal(
      sibling.jobId,
      sibling.cursor,
    );
    await result(sibling.jobId);
    await ping();
    data.hangingJobId = hanging.jobId;
    data.siblingJobId = sibling.jobId;
  } else if (scenario === "timeout") {
    const timedOut = await startJob("TIMEOUT");
    data.timeoutTerminal = await statusUntilTerminal(
      timedOut.jobId,
      timedOut.cursor,
    );
    data.timeoutPid = capturedPidForPrompt("TIMEOUT");
    data.timeoutAliveAfterTerminal = pidIsAlive(data.timeoutPid);
    const followup = await startJob("NORMAL AFTER TIMEOUT");
    data.followupTerminal = await statusUntilTerminal(
      followup.jobId,
      followup.cursor,
    );
    await result(followup.jobId);
    await ping();
  } else if (scenario === "retry") {
    const job = await startJob("EMPTY_THEN_OK");
    data.retryTerminal = await statusUntilTerminal(job.jobId, job.cursor);
    data.retryResult = await result(job.jobId);
  } else if (scenario === "provider-error") {
    const job = await startJob("PROVIDER_ERROR");
    data.providerErrorTerminal = await statusUntilTerminal(
      job.jobId,
      job.cursor,
    );
    data.providerErrorResult = await result(job.jobId);
    await ping();
  } else if (scenario === "progress") {
    const job = await startJob("HANG PROGRESS");
    data.progressStatus = await callTool(
      "claude-status",
      { jobId: job.jobId, cursor: 0, wait_ms: 500 },
      undefined,
      { progressToken: "claude-progress-token" },
    );
    data.progressHeartbeat = await callTool(
      "claude-status",
      {
        jobId: job.jobId,
        cursor: structured(data.progressStatus)?.cursor ?? 0,
        wait_ms: 30,
      },
      undefined,
      { progressToken: "claude-progress-token" },
    );
    await cancel(job.jobId);
    data.progressTerminal = await statusUntilTerminal(
      job.jobId,
      structured(data.cancels.at(-1))?.cursor ?? 0,
    );
  } else if (scenario === "disconnect") {
    const job = await startJob("HANG DISCONNECT");
    data.disconnectStatus = await status(job.jobId, 0, 500);
  } else if (scenario === "paging") {
    const job = await startJob("PAGE");
    await statusUntilTerminal(job.jobId, job.cursor);
    const first = await result(job.jobId, 0);
    const second = await result(
      job.jobId,
      structured(first)?.nextOffset ?? 0,
    );
    data.pageFirst = first;
    data.pageSecond = second;
  } else if (scenario === "oversize") {
    const job = await startJob("OVERSIZE");
    data.oversizeTerminal = await statusUntilTerminal(job.jobId, job.cursor);
    data.oversizeResult = await result(job.jobId);
    await ping();
  } else if (scenario === "retention") {
    const job = await startJob("NORMAL RETENTION");
    await statusUntilTerminal(job.jobId, job.cursor);
    await result(job.jobId);
    await delay(140);
    data.expired = await status(job.jobId, 0, 0);
    await ping();
  } else if (scenario === "capacity") {
    const first = await startJob("HANG A");
    const second = await startJob("HANG B");
    await waitForCaptureCount(2);
    data.capacityRejected = await callTool("claude-start", {
      prompt: "HANG C",
      cwd: serverDir,
    });
    await cancel(first.jobId);
    await cancel(second.jobId);
    await statusUntilTerminal(
      first.jobId,
      structured(data.cancels[0])?.cursor ?? first.cursor,
    );
    await statusUntilTerminal(
      second.jobId,
      structured(data.cancels[1])?.cursor ?? second.cursor,
    );
    await ping();
  } else if (scenario === "retained") {
    const first = await startJob("NORMAL RETAINED ONE");
    await statusUntilTerminal(first.jobId, first.cursor);
    await result(first.jobId);
    const second = await startJob("NORMAL RETAINED TWO");
    await statusUntilTerminal(second.jobId, second.cursor);
    await result(second.jobId);
    const third = await startJob("NORMAL RETAINED THREE");
    data.stillRetained = await status(second.jobId, 0, 0);
    data.evicted = await status(first.jobId, 0, 0);
    await statusUntilTerminal(third.jobId, third.cursor);
    await result(third.jobId);
  } else {
    throw new Error(`unknown scenario ${scenario}`);
  }
} catch (error) {
  driverError = error instanceof Error ? error.message : String(error);
} finally {
  await delay(50);
  try { child.stdin.end(); } catch {}
}

const closeInfo = await closed;
clearTimeout(hardStop);
const captures = readdirSync(captureDir)
  .filter((name) => name.endsWith(".json"))
  .sort()
  .map((name) => {
    const base = `${captureDir}/${name.slice(0, -5)}`;
    const meta = JSON.parse(readFileSync(`${base}.json`, "utf8"));
    let rawStdin = "";
    let signals = [];
    try { rawStdin = readFileSync(`${base}.stdin`, "utf8"); } catch {}
    try {
      signals = readFileSync(`${base}.signals`, "utf8")
        .split("\n").filter(Boolean);
    } catch {}
    const stdinParsed = rawStdin
      .split("\n")
      .filter(Boolean)
      .flatMap((line) => {
        try { return [JSON.parse(line)]; } catch { return []; }
      });
    let alive = false;
    try {
      process.kill(meta.pid, 0);
      alive = true;
    } catch {}
    return { meta, rawStdin, stdinParsed, signals, alive };
  });

if (scenario === "paging") {
  const pageMetrics = (frame) => {
    const contentText = frame?.result?.content?.[0]?.text ?? "";
    const structuredText = frame?.result?.structuredContent?.text ?? "";
    return {
      contentCodePoints: Array.from(contentText).length,
      structuredCodePoints: Array.from(structuredText).length,
      equal: contentText === structuredText,
      allRocket: Array.from(contentText).every((char) => char === "🚀"),
      offset: frame?.result?.structuredContent?.offset,
      nextOffset: frame?.result?.structuredContent?.nextOffset,
      endOffset: frame?.result?.structuredContent?.endOffset,
      done: frame?.result?.structuredContent?.done,
    };
  };
  data.pageMetrics = [
    pageMetrics(data.pageFirst),
    pageMetrics(data.pageSecond),
  ];
  for (const frame of frames) {
    const content = frame?.result?.content?.[0];
    if (typeof content?.text === "string" && content.text.length > 1_000) {
      content.text = `[omitted ${Array.from(content.text).length} code points]`;
    }
    const resultText = frame?.result?.structuredContent;
    if (typeof resultText?.text === "string" && resultText.text.length > 1_000) {
      resultText.text =
        `[omitted ${Array.from(resultText.text).length} code points]`;
    }
  }
}

process.stdout.write(`${JSON.stringify({
  scenario,
  driverError,
  closeInfo,
  frames,
  captures,
  data,
  stderr,
  rawParseTail: parseBuffer,
})}\n`);
EOF
}

test_claude_job() {
  local label="$1"
  local scenario="$2"
  local predicate="$3"
  local tmpdir
  local status
  local summary
  local ok=1

  echo "--- $label ---"
  tmpdir=$(mktemp -d)
  write_claude_job_stub "$tmpdir"
  write_claude_job_driver "$tmpdir"

  set +e
  summary=$(
    $TIMEOUT_CMD 9 node "$tmpdir/claude-job-driver.mjs" \
      "$tmpdir" "$(pwd)" "$scenario" 2>/dev/null
  )
  status=$?
  set -e

  [ "$status" -eq 0 ] || ok=0
  printf '%s' "$summary" | jq -e \
    "(.driverError == null) and (.closeInfo.code == 0) and ($predicate)" \
    >/dev/null 2>&1 || ok=0

  if [ "$ok" -eq 1 ]; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (status=$status)"
    echo "  Summary: ${summary:0:12000}"
    FAIL=$((FAIL + 1))
  fi

  rm -rf "$tmpdir"
}

# ── Helper: a real App Server workspace-write turn honors sandbox + cwd. ──
test_codex_percall_write() {
  local label="$1"
  local probe_dir probe_file state_dir output_file status RESPONSE shape_ok
  echo "--- $label ---"

  probe_dir=$(mktemp -d)
  probe_file="$probe_dir/mcp_agents_probe.txt"
  state_dir=$(mktemp -d)
  output_file=$(mktemp)

  set +e
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"0.0.1"}}}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    sleep 0.3
    printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"codex\",\"arguments\":{\"prompt\":\"Create a file named mcp_agents_probe.txt containing exactly OK in your current working directory. Read it back and reply with only OK after verifying that exact file exists and contains OK; otherwise reply FAILURE.\",\"sandbox\":\"workspace-write\",\"cwd\":\"$probe_dir\",\"model_reasoning_effort\":\"xhigh\"}}}"
    sleep 75
  } | $TIMEOUT_CMD 105 $SERVER --provider codex \
    --codex-state-root "$state_dir" >"$output_file" 2>/dev/null
  status=$?
  set -e
  RESPONSE=$(cat "$output_file")
  rm -f "$output_file"

  shape_ok=0
  if echo "$RESPONSE" | jq -s -e '
    ([.[] | select(.id == 2)] | length == 1) and
    ([.[] | select(.id == 2)][0].result |
      (.isError != true) and
      (.structuredContent.threadId | type == "string" and length > 0) and
      (.structuredContent.content | type == "string")) and
    ([.[] | select(
      .method == "codex/event" or
      (((.method // "") | startswith("thread/")) or
       ((.method // "") | startswith("turn/")) or
       ((.method // "") | startswith("item/"))))] | length == 0)
  ' >/dev/null 2>&1; then
    shape_ok=1
  fi

  if [ "$status" -eq 0 ] && [ -f "$probe_file" ] &&
    [ "$(cat "$probe_file")" = "OK" ] && [ "$shape_ok" -eq 1 ]; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label"
    [ "$status" -eq 0 ] || echo "  server exited non-zero ($status)"
    [ -f "$probe_file" ] || echo "  probe file not created — per-call sandbox/cwd did not grant writes"
    if [ -f "$probe_file" ] && [ "$(cat "$probe_file")" != "OK" ]; then
      echo "  probe file content was not exactly OK"
    fi
    [ "$shape_ok" -eq 1 ] || echo "  App Server wrapper result shape or isolation was unexpected"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$probe_dir" "$state_dir"
}

write_codex_app_server_stub() {
  cat >"$1/codex" <<'EOF'
#!/usr/bin/env node
const fs = require("node:fs");

if (process.argv[2] === "--version") {
  process.stdout.write(`${process.env.MCP_STUB_CODEX_VERSION || "codex-cli 0.149.1"}\n`);
  process.exit(0);
}

const captureDir = process.env.MCP_STUB_APP_CAPTURE_DIR;
const mode = process.env.MCP_STUB_APP_MODE || "normal";
const workspace = process.env.MCP_STUB_APP_WORKSPACE;
const spawnFile = `${captureDir}/app-spawns.jsonl`;
const captureFile = `${captureDir}/app-stdin.jsonl`;
fs.appendFileSync(process.env.MCP_AGENTS_TEST_CHILD_REGISTRY, `${process.pid}\n`);
const previousSpawns = fs.existsSync(spawnFile)
  ? fs.readFileSync(spawnFile, "utf8").split("\n").filter(Boolean).length
  : 0;
const spawnOrdinal = previousSpawns + 1;
const fileMode = (path) => {
  try { return (fs.statSync(path).mode & 0o777).toString(8); }
  catch { return null; }
};
const linkInfo = (path) => {
  try {
    const stat = fs.lstatSync(path);
    return {
      symlink: stat.isSymbolicLink(),
      target: fs.realpathSync(path),
      mode: fileMode(fs.realpathSync(path)),
    };
  } catch { return null; }
};
fs.appendFileSync(spawnFile, `${JSON.stringify({
  pid: process.pid,
  ordinal: spawnOrdinal,
  argv: process.argv.slice(2),
  codexHome: process.env.CODEX_HOME,
  sqliteHome: process.env.CODEX_SQLITE_HOME || null,
  homeMode: fileMode(process.env.CODEX_HOME),
  authMode: fileMode(`${process.env.CODEX_HOME}/auth.json`),
  configMode: fileMode(`${process.env.CODEX_HOME}/config.toml`),
  modelsMode: fileMode(`${process.env.CODEX_HOME}/models_cache.json`),
  storage: {
    sessions: linkInfo(`${process.env.CODEX_HOME}/sessions`),
    archived: linkInfo(`${process.env.CODEX_HOME}/archived_sessions`),
    writerLocks: linkInfo(`${process.env.CODEX_HOME}/thread-writer-locks`),
    goals: process.env.CODEX_SQLITE_HOME
      ? linkInfo(`${process.env.CODEX_SQLITE_HOME}/goals_1.sqlite`)
      : null,
  },
})}\n`);

if (process.argv[2] !== "app-server") {
  process.stderr.write(`expected app-server, got ${process.argv.slice(2).join(" ")}\n`);
  process.exit(64);
}
if (mode === "unavailable") process.exit(127);

let inputBuffer = "";
let threadCounter = 0;
let turnCounter = 0;
let active = null;
const deletedThreads = new Set();
const now = () => Math.floor(Date.now() / 1000);
const thread = (id = "thread-1", turns = []) => ({
  id,
  cliVersion: "0.149.1",
  createdAt: now(),
  updatedAt: now(),
  cwd: workspace,
  ephemeral: false,
  modelProvider: "openai",
  preview: "stub preview",
  projectId: null,
  sessionId: `session-${id}`,
  source: "vscode",
  status: { type: active?.threadId === id ? "active" : "idle", ...(active?.threadId === id ? { activeFlags: [] } : {}) },
  turns,
});
const filterThreadSources = (threads, sourceKinds) =>
  Array.isArray(sourceKinds)
    ? threads.filter((candidate) => sourceKinds.includes(candidate.source))
    : threads;
const turn = (id, status = "inProgress", items = []) => ({
  id,
  status,
  items,
});
const send = (value, callback) => {
  const line = `${JSON.stringify(value)}\n`;
  if (mode === "split" && value.method === "turn/completed") {
    const midpoint = Math.floor(line.length / 2);
    process.stdout.write(line.slice(0, midpoint));
    setTimeout(() => process.stdout.write(line.slice(midpoint), callback), 15);
    return;
  }
  process.stdout.write(line, callback);
};
const respond = (id, result) => send({ id, result });
const notify = (method, params) => send({ method, params });
const completeInitialize = (id) => respond(id, {
  userAgent: "codex-app-stub/0.149.1",
  codexHome: process.env.CODEX_HOME,
  platformFamily: "unix",
  platformOs: process.platform,
});

function completeActive(text = "APP_SERVER_OK", status = "completed") {
  if (!active) return;
  const current = active;
  active = null;
  fs.appendFileSync(
    `${captureDir}/app-completions.jsonl`,
    `${JSON.stringify({ threadId: current.threadId, turnId: current.turnId })}\n`,
  );
  const item = { type: "agentMessage", id: current.itemId, text };
  notify("item/started", {
    threadId: current.threadId,
    turnId: current.turnId,
    item: { ...item, text: "" },
  });
  notify("item/agentMessage/delta", {
    threadId: current.threadId,
    turnId: current.turnId,
    itemId: current.itemId,
    delta: mode === "delta-diff" ? "COMMENTARY_ONLY" : text,
  });
  notify("item/completed", {
    threadId: current.threadId,
    turnId: current.turnId,
    item,
  });
  notify("turn/completed", {
    threadId: current.threadId,
    turn: turn(current.turnId, status, [item]),
  });
}

function startTurn(message, review = false, responseExtra = {}) {
  const threadId = message.params.threadId;
  const turnId = `turn-${++turnCounter}`;
  const itemId = `agent-${turnCounter}`;
  active = { threadId, turnId, itemId, requestId: message.id };
  if (mode === "turn-start-withheld") return;

  const announce = () => {
    respond(message.id, { turn: turn(turnId), ...responseExtra });
    notify("turn/started", { threadId, turn: turn(turnId) });

    if ((mode === "die" || mode === "die-first") &&
        (mode === "die" || spawnOrdinal === 1)) {
      setTimeout(() => process.exit(23), 20);
      return;
    }
    if (mode === "malformed") {
      process.stdout.write('{"method":"turn/completed","params":BROKEN}\n');
      return;
    }
    if (mode === "oversized" || mode === "oversized-complete") {
      process.stdout.write(`${JSON.stringify({ method: "item/agentMessage/delta", params: {
        threadId, turnId, itemId, delta: "x".repeat(11 * 1024 * 1024),
      } })}\n`);
      return;
    }
    if (mode === "auth") {
      active = null;
      notify("error", {
        threadId,
        turnId,
        willRetry: false,
        error: { message: "token expired SECRET", codexErrorInfo: "unauthorized" },
      });
      notify("turn/completed", {
        threadId,
        turn: {
          ...turn(turnId, "failed"),
          error: { message: "token expired SECRET", codexErrorInfo: "unauthorized" },
        },
      });
      return;
    }
    if (review && mode === "review-exited") {
      active = null;
      const item = {
        type: "exitedReviewMode",
        id: itemId,
        review: "REVIEW_FROM_EXITED_MODE",
      };
      notify("item/completed", { threadId, turnId, item });
      notify("turn/completed", {
        threadId,
        turn: turn(turnId, "completed", [item]),
      });
      return;
    }
    if (mode === "noise") process.stdout.write("codex diagnostic on stdout\n");
    if (mode === "peek-reply" && turnCounter > 1) return;
    if ([
      "park",
      "cancel-no-native",
      "approval",
      "question",
      "question-no-elicit",
      "interaction-timeout",
      "secret-question",
      "permission",
      "detached-review",
    ].includes(mode)) {
      if (mode === "approval") {
        send({
          id: `approval-${turnCounter}`,
          method: "item/commandExecution/requestApproval",
          params: {
            threadId,
            turnId,
            itemId: `command-${turnCounter}`,
            startedAtMs: Date.now(),
            command: "printf safe",
            cwd: workspace,
            reason: "stub approval",
          },
        });
      } else if (mode === "permission") {
        send({
          id: `permission-${turnCounter}`,
          method: "item/permissions/requestApproval",
          params: {
            threadId,
            turnId,
            itemId: `permission-item-${turnCounter}`,
            permissions: [{ type: "network", host: "example.test" }],
          },
        });
      } else if ([
        "question",
        "question-no-elicit",
        "interaction-timeout",
        "secret-question",
      ].includes(mode)) {
        send({
          id: `question-${turnCounter}`,
          method: "item/tool/requestUserInput",
          params: {
            threadId,
            turnId,
            itemId: `question-item-${turnCounter}`,
            isBlocking: true,
            questions: [{
              id: "choice",
              header: "Choice",
              question: mode === "secret-question" ? "SENSITIVE_SECRET_PROMPT" : "Pick one",
              isOther: false,
              isSecret: mode === "secret-question",
              options: [
                { label: "Ship", description: "Continue" },
                { label: "Stop", description: "Cancel" },
              ],
            }],
          },
        });
      }
      return;
    }
    setTimeout(
      () => completeActive(review ? "REVIEW_OK" : "APP_SERVER_OK"),
      mode === "delayed" ? 400 : 25,
    );
  };

  if (mode === "early-complete") {
    active = null;
    const item = { type: "agentMessage", id: itemId, text: "EARLY_OK" };
    notify("turn/completed", {
      threadId,
      turn: turn(turnId, "completed", [item]),
    });
    setTimeout(() => {
      respond(message.id, { turn: turn(turnId), ...responseExtra });
      notify("turn/started", { threadId, turn: turn(turnId) });
    }, 10);
    return;
  }
  if (mode === "early-stale") {
    const stale = { type: "agentMessage", id: itemId, text: "STALE_EARLY_RESULT" };
    notify("turn/completed", {
      threadId,
      turn: turn(turnId, "completed", [stale]),
    });
    setTimeout(announce, 100);
    return;
  }
  if (mode === "early-overflow") {
    for (let index = 0; index <= 32; index += 1) {
      notify("turn/completed", {
        threadId,
        turn: turn(`bogus-turn-${index}`, "completed"),
      });
    }
    return;
  }
  if (mode === "early-die-first" && spawnOrdinal === 1) {
    const stale = { type: "agentMessage", id: itemId, text: "STALE_DEAD_RESULT" };
    notify("turn/completed", {
      threadId,
      turn: turn(turnId, "completed", [stale]),
    });
    setTimeout(() => process.exit(23), 10);
    return;
  }

  if (mode === "deferred-question-die") {
    // Ask before the turn/start response resolves. The bridge has no turn for
    // this turnId yet, so it must defer the request and drain it inside
    // registerTurn -- the window where the turn has no awaiter. Then exit, so
    // the turn is rejected while that is still true.
    send({
      id: `question-${turnCounter}`,
      method: "item/tool/requestUserInput",
      params: {
        threadId,
        turnId,
        itemId: `question-item-${turnCounter}`,
        isBlocking: true,
        questions: [{
          id: "choice",
          header: "Choice",
          question: "Pick one",
          isOther: false,
          isSecret: false,
          options: [
            { label: "Ship", description: "Continue" },
            { label: "Stop", description: "Cancel" },
          ],
        }],
      },
    });
    setTimeout(() => {
      respond(message.id, { turn: turn(turnId), ...responseExtra });
      notify("turn/started", { threadId, turn: turn(turnId) });
      setTimeout(() => process.exit(23), 80);
    }, 20);
    return;
  }
  if (mode === "turn-start-delayed") setTimeout(announce, 300);
  else announce();
}

function onMessage(message) {
  fs.appendFileSync(captureFile, `${JSON.stringify(message)}\n`);

  if (message.id === "approval-1" || message.id === "question-1" ||
      String(message.id).startsWith("approval-") ||
      String(message.id).startsWith("question-")) {
    if (message.result?.decision === "accept" ||
        message.result?.decision === "acceptForSession" ||
        message.result?.answers) {
      setTimeout(() => completeActive("INTERACTION_OK"), 10);
    }
    return;
  }
  if (String(message.id).startsWith("permission-")) return;

  switch (message.method) {
    case "initialize":
      if (mode === "init-timeout-first" && spawnOrdinal === 1) break;
      if (mode === "init-reject-first" && spawnOrdinal === 1) {
        send({ id: message.id, error: { code: -32001, message: "init rejected" } });
        break;
      }
      if (mode === "slow-initialize") setTimeout(() => completeInitialize(message.id), 10_500);
      else if (mode === "delayed-initialize") setTimeout(() => completeInitialize(message.id), 25);
      else completeInitialize(message.id);
      break;
    case "initialized":
      break;
    case "thread/start": {
      const id = ["die-first", "early-die-first"].includes(mode)
        ? `thread-${spawnOrdinal}`
        : `thread-${++threadCounter}`;
      const value = thread(id);
      fs.mkdirSync(`${process.env.CODEX_HOME}/sessions/stub`, { recursive: true });
      fs.writeFileSync(
        `${process.env.CODEX_HOME}/sessions/stub/${id}.jsonl`,
        `${JSON.stringify({ threadId: id, cwd: workspace })}\n`,
      );
      const finishStart = () => {
        respond(message.id, {
          thread: value,
          model: message.params.model || "gpt-6-astra",
          modelProvider: "openai",
          cwd: message.params.cwd,
          approvalPolicy: message.params.approvalPolicy || "never",
          approvalsReviewer: "user",
          sandbox: message.params.sandbox || { type: "readOnly" },
        });
        notify("thread/started", { thread: value });
      };
      if (mode === "thread-start-withheld") break;
      if (mode === "thread-start-delayed") setTimeout(finishStart, 300);
      else finishStart();
      break;
    }
    case "thread/resume":
      if (process.env.MCP_STUB_REQUIRE_SESSION === "1" &&
          !fs.existsSync(`${process.env.CODEX_HOME}/sessions/stub/${message.params.threadId}.jsonl`)) {
        send({ id: message.id, error: { code: -32000, message: "durable session missing" } });
        break;
      }
      respond(message.id, {
        thread: thread(message.params.threadId),
        model: "gpt-6-astra",
        modelProvider: "openai",
        cwd: workspace,
        approvalPolicy: "never",
        approvalsReviewer: "user",
        sandbox: { type: "readOnly" },
      });
      break;
    case "turn/start":
      startTurn(message);
      break;
    case "turn/steer":
      respond(message.id, { turnId: message.params.expectedTurnId });
      if (mode === "park") setTimeout(() => completeActive("STEER_OK"), 15);
      break;
    case "turn/interrupt": {
      const interrupted = active;
      if (mode === "cancel-no-native") break;
      respond(message.id, {});
      if (interrupted) {
        active = null;
        notify("turn/completed", {
          threadId: interrupted.threadId,
          turn: turn(interrupted.turnId, "interrupted"),
        });
      }
      break;
    }
    case "thread/goal/set":
      respond(message.id, { goal: {
        threadId: message.params.threadId,
        objective: message.params.objective ?? "existing objective",
        status: message.params.status ?? "active",
        tokenBudget: message.params.tokenBudget ?? null,
        tokensUsed: 12,
        timeUsedSeconds: 3,
        createdAt: now(),
        updatedAt: now(),
      } });
      break;
    case "thread/goal/get":
      respond(message.id, { goal: {
        threadId: message.params.threadId,
        objective: "existing objective", status: "active", tokenBudget: 500,
        tokensUsed: 12, timeUsedSeconds: 3, createdAt: now(), updatedAt: now(),
      } });
      break;
    case "thread/goal/clear":
      respond(message.id, { cleared: true });
      break;
    case "review/start":
      startTurn(
        message,
        true,
        {
          reviewThreadId: mode === "detached-review"
            ? "thread-review-detached"
            : message.params.threadId,
        },
      );
      break;
    case "thread/list":
      if (mode === "retention-newer" && !deletedThreads.has("thread-expired")) {
        respond(message.id, {
          data: filterThreadSources([
            {
              ...thread("thread-expired"),
              createdAt: 1,
              updatedAt: 1,
              recencyAt: 1,
              source: "appServer",
              status: { type: "idle" },
            },
            {
              ...thread("thread-vscode-expired"),
              createdAt: 1,
              updatedAt: 1,
              recencyAt: 1,
              status: { type: "idle" },
            },
            {
              ...thread("thread-fresh"),
              recencyAt: now(),
              source: "appServer",
              status: { type: "idle" },
            },
          ], message.params.sourceKinds),
          nextCursor: null,
        });
      } else if (
        mode === "retention-newer" && message.params.archived &&
        !deletedThreads.has("thread-archived-expired")
      ) {
        respond(message.id, {
          data: filterThreadSources([{
            ...thread("thread-archived-expired"),
            archived: true,
            createdAt: 1,
            updatedAt: 1,
            recencyAt: 1,
            source: "subAgentReview",
            status: { type: "idle" },
          }], message.params.sourceKinds),
          nextCursor: null,
        });
      } else if (mode === "retention-journal") {
        respond(message.id, { data: [], nextCursor: null });
      } else {
        respond(message.id, {
          data: filterThreadSources(
            [thread("thread-listed")],
            message.params.sourceKinds,
          ),
          nextCursor: null,
        });
      }
      break;
    case "thread/read":
      respond(message.id, { thread: thread(message.params.threadId, message.params.includeTurns ? [turn("turn-read", "completed", [
        { type: "agentMessage", id: "agent-read", text: "READ_OK" },
        { type: "reasoning", id: "reasoning-read", summary: ["SECRET_REASONING"] },
      ])] : []) });
      break;
    case "thread/fork":
      respond(message.id, {
        thread: { ...thread("thread-forked"), forkedFromId: message.params.threadId },
        model: "gpt-6-astra",
        modelProvider: "openai",
        cwd: workspace,
        approvalPolicy: "never",
        approvalsReviewer: "user",
        sandbox: { type: "readOnly" },
      });
      break;
    case "thread/archive":
      if (mode === "archive-withheld") break;
      respond(message.id, {});
      break;
    case "thread/unarchive":
      respond(message.id, { thread: thread(message.params.threadId) });
      break;
    case "thread/delete":
      if (mode === "retention-journal") {
        send({
          id: message.id,
          error: {
            code: -32600,
            message: `no rollout found for thread id ${message.params.threadId}`,
          },
        });
      } else {
        deletedThreads.add(message.params.threadId);
        respond(message.id, {});
      }
      break;
    default:
      if (message.id !== undefined) send({ id: message.id, error: { code: -32601, message: `unknown ${message.method}` } });
  }
}

process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  inputBuffer += chunk;
  while (true) {
    const newline = inputBuffer.indexOf("\n");
    if (newline < 0) break;
    const line = inputBuffer.slice(0, newline);
    inputBuffer = inputBuffer.slice(newline + 1);
    if (!line.trim()) continue;
    try { onMessage(JSON.parse(line)); }
    catch (error) { process.stderr.write(`stub input parse error: ${error.message}\n`); }
  }
});
process.stdin.on("end", () => process.exit(0));
EOF
  chmod +x "$1/codex"
}

write_codex_app_server_driver() {
  cat >"$1/app-driver.mjs" <<'EOF'
import fs from "node:fs";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";

const [stubDir, serverDir, scenario, rawServerArgs = ""] = process.argv.slice(2);
const frames = [];
const rawLines = [];
const pending = new Map();
let parseBuffer = "";
let nextId = 1;
let driverError = null;
const projectHash = createHash("sha256").update(fs.realpathSync(serverDir)).digest("hex");
const durableRoot = `${stubDir}/state/mcp-agents/codex/projects/${projectHash}/v1`;
const retentionJournal = `${durableRoot}/retention-journal.json`;
if (scenario === "retention-journal") {
  fs.mkdirSync(durableRoot, { recursive: true });
  fs.writeFileSync(retentionJournal, `${JSON.stringify({
    version: 1,
    bridgeId: "dead-bridge",
    threadId: "thread-missing",
    archived: false,
    status: { type: "idle" },
    startedAt: "2000-01-01T00:00:00.000Z",
  })}\n`);
}
const stubMode = {
  "queued-interaction": "approval",
  "foreground-interaction-hidden": "question",
  "approval-no-elicit": "approval",
  "stale-race": "park",
  "cancel-during-thread-start": "thread-start-withheld",
  "init-timeout-empty": "delayed-initialize",
  "init-timeout-invalid": "delayed-initialize",
  "init-timeout-negative": "delayed-initialize",
  "init-timeout-overflow": "delayed-initialize",
  "init-timeout-zero": "delayed-initialize",
}[scenario] ?? (["peek", "job-compat", "busy", "idle", "cancel", "steer", "hold"].includes(scenario)
  ? "park"
  : ["schema-no-app", "unavailable-call"].includes(scenario)
    ? "unavailable"
    : scenario);
const child = spawn("node", ["server.js", "--provider", "codex", ...rawServerArgs.split(" ").filter(Boolean)], {
  cwd: serverDir,
  detached: true,
  env: {
    ...process.env,
    PATH: `${stubDir}:${process.env.PATH}`,
    CODEX_HOME: `${stubDir}/real-codex-home`,
    XDG_STATE_HOME: `${stubDir}/state`,
    MCP_STUB_APP_CAPTURE_DIR: stubDir,
    MCP_STUB_APP_MODE: stubMode,
    MCP_STUB_APP_WORKSPACE: `${stubDir}/workspace`,
    MCP_STUB_REQUIRE_SESSION: scenario === "restart-reply" ? "1" : "0",
    MCP_STUB_CODEX_VERSION: [
      "goal-default-newer",
      "retention-newer",
      "retention-journal",
    ].includes(scenario)
      ? "codex-cli 0.150.0"
      : "codex-cli 0.149.1",
    ...(["init-timeout-first", "init-reject-first"].includes(scenario)
      ? { MCP_AGENTS_CODEX_APP_INIT_TIMEOUT_MS: "750" }
      : {}),
    ...(scenario === "init-timeout-empty"
      ? { MCP_AGENTS_CODEX_APP_INIT_TIMEOUT_MS: "" }
      : {}),
    ...(scenario === "init-timeout-invalid"
      ? { MCP_AGENTS_CODEX_APP_INIT_TIMEOUT_MS: "600s" }
      : {}),
    ...(scenario === "init-timeout-negative"
      ? { MCP_AGENTS_CODEX_APP_INIT_TIMEOUT_MS: "-1" }
      : {}),
    ...(scenario === "init-timeout-overflow"
      ? { MCP_AGENTS_CODEX_APP_INIT_TIMEOUT_MS: "2147483648" }
      : {}),
    ...(scenario === "init-timeout-zero"
      ? { MCP_AGENTS_CODEX_APP_INIT_TIMEOUT_MS: "0" }
      : {}),
    ...(["turn-start-withheld", "archive-withheld"].includes(scenario)
      ? { MCP_AGENTS_CODEX_APP_MUTATION_TIMEOUT_MS: "120" }
      : {}),
    ...(["cancel-no-native", "cancel-during-thread-start"].includes(scenario)
      ? { MCP_AGENTS_CODEX_CANCEL_GRACE_MS: "120" }
      : {}),
    ...(scenario === "interaction-timeout"
      ? { MCP_AGENTS_CODEX_INTERACTION_TIMEOUT_MS: "1500" }
      : {}),
    ...(scenario === "early-stale"
      ? { MCP_AGENTS_TEST_CODEX_EARLY_COMPLETION_TTL_MS: "40" }
      : {}),
    ...(["retention-newer", "retention-journal"].includes(scenario)
      ? { MCP_AGENTS_CODEX_RETENTION_STARTUP_MS: "50" }
      : {}),
    ...(scenario === "stale-race"
      ? { MCP_AGENTS_TEST_CODEX_STALE_LEASE_DELAY_MS: "100" }
      : {}),
    ...(scenario === "job-compat"
      ? {
          MCP_AGENTS_TEST_CODEX_MAX_ACTIVE_JOBS: "1",
          MCP_AGENTS_TEST_CODEX_MAX_RETAINED_JOBS: "2",
        }
      : {}),
  },
  stdio: ["pipe", "pipe", "pipe"],
});
fs.appendFileSync(process.env.MCP_AGENTS_TEST_CHILD_REGISTRY, `${child.pid}\n`);
let stderr = "";
child.stderr.setEncoding("utf8");
child.stderr.on("data", (chunk) => { stderr += chunk; });

const write = (value) => child.stdin.write(`${JSON.stringify(value)}\n`);
const requestTimeoutMs = scenario === "slow-initialize" ? 13_000 : 3_500;
const request = (method, params = {}) => new Promise((resolve, reject) => {
  const id = nextId++;
  const timer = setTimeout(() => {
    pending.delete(id);
    reject(new Error(`timeout waiting for ${method} (${id})`));
  }, requestTimeoutMs);
  pending.set(id, { resolve, reject, timer, method });
  write({ jsonrpc: "2.0", id, method, params });
});
const notify = (method, params = {}) => write({ jsonrpc: "2.0", method, params });
const discardPending = (id) => {
  const owner = pending.get(id);
  if (!owner) return false;
  clearTimeout(owner.timer);
  pending.delete(id);
  return true;
};

let interactionsDuringRound;
function onFrame(frame) {
  frames.push(frame);
  if (frame.method === "elicitation/create" && frame.id !== undefined) {
    if (scenario === "interaction-timeout") return;
    if (scenario === "foreground-interaction-hidden") {
      // The foreground interaction is pending for as long as this request is
      // unanswered, so ask the background queue about it from inside the round.
      interactionsDuringRound = call("codex-interactions", {});
      void interactionsDuringRound.finally(() => write({
        jsonrpc: "2.0",
        id: frame.id,
        result: { action: "accept", content: { choice: "Ship" } },
      }));
      return;
    }
    if (scenario === "deferred-question-die") {
      // Answer late, so the app-server child is already gone by the time the
      // round resumes and the turn is rejected with nothing awaiting it.
      setTimeout(() => write({
        jsonrpc: "2.0",
        id: frame.id,
        result: { action: "accept", content: { choice: "Ship" } },
      }), 300);
      return;
    }
    const schema = frame.params?.requestedSchema || frame.params?.schema || {};
    const isQuestion = JSON.stringify(schema).includes("choice");
    write({
      jsonrpc: "2.0",
      id: frame.id,
      result: isQuestion
        ? { action: "accept", content: { choice: "Ship" } }
        : { action: "accept", content: { decision: "accept" } },
    });
    return;
  }
  if (frame.id === undefined || !pending.has(frame.id)) return;
  const owner = pending.get(frame.id);
  clearTimeout(owner.timer);
  pending.delete(frame.id);
  owner.resolve(frame);
}

child.stdout.setEncoding("utf8");
child.stdout.on("data", (chunk) => {
  parseBuffer += chunk;
  while (true) {
    const newline = parseBuffer.indexOf("\n");
    if (newline < 0) break;
    const line = parseBuffer.slice(0, newline);
    parseBuffer = parseBuffer.slice(newline + 1);
    if (!line.trim()) continue;
    rawLines.push(line);
    try { onFrame(JSON.parse(line)); }
    catch (error) { driverError ||= `outer parse: ${error.message}`; }
  }
});

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const waitFor = async (predicate, timeoutMs = 1500) => {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return true;
    await sleep(10);
  }
  return false;
};
const readSidecars = () => {
  const found = [];
  const visit = (dir) => {
    if (!fs.existsSync(dir)) return;
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const path = `${dir}/${entry.name}`;
      if (entry.isDirectory()) visit(path);
      else if (entry.name === "active-turns.json") {
        try { found.push(JSON.parse(fs.readFileSync(path, "utf8"))); } catch {}
      }
    }
  };
  visit(`${durableRoot}/bridges`);
  return found;
};
const mcpInitialize = async (elicitation = false) => {
  await request("initialize", {
    protocolVersion: "2025-06-18",
    capabilities: elicitation ? { elicitation: {} } : {},
    clientInfo: { name: "app-driver", version: "0" },
  });
  notify("notifications/initialized");
};
const call = (name, argumentsValue) => request("tools/call", { name, arguments: argumentsValue });
const initialArgs = (prompt = "hello") => ({
  prompt,
  cwd: `${stubDir}/workspace`,
  sandbox: "read-only",
  model: "gpt-6-astra",
  model_reasoning_effort: "high",
});
const data = {};

try {
  if (scenario === "schema" || scenario === "schema-no-app") {
    await mcpInitialize();
    data.tools = await request("tools/list");
    data.resources = await request("resources/list");
    data.templates = await request("resources/templates/list");
    data.prompts = await request("prompts/list");
  } else if (scenario === "reply" || scenario === "restart-reply") {
    await mcpInitialize();
    data.reply = await call("codex-reply", {
      threadId: scenario === "restart-reply" ? "thread-1" : "thread-resume",
      prompt: "continue",
    });
  } else if (scenario === "init-timeout-first" || scenario === "init-reject-first") {
    await mcpInitialize();
    data.first = await call("codex", initialArgs("first generation"));
    data.second = await call("codex", initialArgs("fresh generation"));
  } else if (scenario === "turn-start-withheld") {
    await mcpInitialize();
    data.first = await call("codex", initialArgs("accepted but unacknowledged"));
    data.peek = await call("codex-peek", { threadId: "thread-1" });
    data.second = await call("codex-reply", {
      threadId: "thread-1",
      prompt: "must stay blocked",
    });
  } else if (scenario === "cancel") {
    await mcpInitialize();
    const callId = nextId;
    const open = call("codex", initialArgs("cancel me")).catch((error) => ({ driverError: error.message }));
    if (!await waitFor(() => fs.existsSync(`${stubDir}/app-stdin.jsonl`) &&
      fs.readFileSync(`${stubDir}/app-stdin.jsonl`, "utf8").includes('"method":"turn/start"'))) {
      throw new Error("turn/start was not captured before cancellation");
    }
    notify("notifications/cancelled", { requestId: callId, reason: "test" });
    if (!await waitFor(() => fs.existsSync(`${stubDir}/app-stdin.jsonl`) &&
      fs.readFileSync(`${stubDir}/app-stdin.jsonl`, "utf8")
        .includes('"method":"turn/interrupt"'), 3000)) {
      throw new Error("turn/interrupt was not captured after cancellation");
    }
    data.canceled = await Promise.race([open, sleep(250).then(() => null)]);
    data.ping = await request("ping");
  } else if (scenario === "cancel-no-native") {
    await mcpInitialize();
    const callId = nextId;
    void call("codex", initialArgs("cancel without native completion"));
    for (let attempt = 0; attempt < 50; attempt += 1) {
      const peek = await call("codex-peek", { threadId: "thread-1" });
      if (peek.result?.structuredContent?.turns?.[0]?.state === "running") {
        data.registeredBeforeCancel = true;
        break;
      }
      await sleep(10);
    }
    if (!data.registeredBeforeCancel) throw new Error("turn never registered before cancellation");
    const canceledAt = Date.now();
    notify("notifications/cancelled", { requestId: callId, reason: "test grace" });
    data.sibling = await request("ping");
    await sleep(250);
    data.cancelElapsedMs = Date.now() - canceledAt;
    data.canceledWasPending = discardPending(callId);
    data.canceledResponseCount = frames.filter((frame) => frame.id === callId).length;
    data.peek = await call("codex-peek", { threadId: "thread-1" });
    data.sidecarsAfterCancel = readSidecars();
  } else if (scenario === "cancel-during-thread-start") {
    await mcpInitialize();
    const callId = nextId;
    void call("codex", initialArgs("cancel during setup"));
    if (!await waitFor(() => fs.existsSync(`${stubDir}/app-stdin.jsonl`) &&
      fs.readFileSync(`${stubDir}/app-stdin.jsonl`, "utf8").includes('"method":"thread/start"'))) {
      throw new Error("thread/start was not captured before cancellation");
    }
    const canceledAt = Date.now();
    notify("notifications/cancelled", { requestId: callId, reason: "cancel setup" });
    data.sibling = await request("ping");
    await sleep(250);
    data.cancelElapsedMs = Date.now() - canceledAt;
    data.canceledWasPending = discardPending(callId);
    data.canceledResponseCount = frames.filter((frame) => frame.id === callId).length;
    data.sidecarsAfterCancel = readSidecars();
  } else if (scenario === "goals") {
    await mcpInitialize();
    data.set = await call("codex-goal-set", { threadId: "thread-goal", objective: "ship", status: "active", tokenBudget: 500 });
    data.get = await call("codex-goal-get", { threadId: "thread-goal" });
    data.clear = await call("codex-goal-clear", { threadId: "thread-goal" });
  } else if (scenario === "goal-call") {
    await mcpInitialize();
    data.call = await call("codex", {
      ...initialArgs("goal-bearing turn"),
      goal: "ship safely",
      allow_subagents: true,
    });
  } else if (scenario === "steer") {
    await mcpInitialize();
    data.started = await call("codex-start", initialArgs("park"));
    await sleep(120);
    data.steer = await call("codex-steer", { threadId: "thread-1", prompt: "new direction" });
  } else if (scenario === "peek") {
    await mcpInitialize();
    data.started = await call("codex-start", initialArgs("PRIVATE_PEEK_PROMPT"));
    await sleep(120);
    data.peek = await call("codex-peek", {});
    const jobId = data.started.result?.structuredContent?.jobId;
    data.cancel = await call("codex-cancel", { jobId });
  } else if (scenario === "peek-empty") {
    await mcpInitialize();
    data.peek = await call("codex-peek", {});
    data.filtered = await call("codex-peek", { cwd: `${stubDir}/workspace` });
  } else if (scenario === "peek-reply") {
    await mcpInitialize();
    data.initial = await call("codex", initialArgs("remember workspace"));
    data.started = await call("codex-reply-start", {
      threadId: "thread-1",
      prompt: "park inherited reply",
    });
    data.peek = await call("codex-peek", { threadId: "thread-1" });
    const jobId = data.started.result?.structuredContent?.jobId;
    data.cancel = await call("codex-cancel", { jobId });
  } else if (scenario === "job-compat") {
    await mcpInitialize();
    data.started = await call("codex-start", initialArgs("background compatibility"));
    const jobId = data.started.result?.structuredContent?.jobId;
    data.caughtUp = await call("codex-status", { jobId, cursor: 0, wait_ms: 0 });
    const cursor = data.caughtUp.result?.structuredContent?.cursor;
    const waitedAt = Date.now();
    data.defaultWait = await call("codex-status", { jobId, cursor });
    data.defaultWaitElapsedMs = Date.now() - waitedAt;
    data.pendingResult = await call("codex-result", { jobId, offset: 0 });
    data.capacity = await call("codex-start", initialArgs("excess background job"));
    data.cancel = await call("codex-cancel", { jobId });
  } else if (scenario === "job") {
    await mcpInitialize();
    data.started = await call("codex-start", initialArgs("background"));
    await sleep(120);
    const jobId = data.started.result?.structuredContent?.jobId;
    data.status = await call("codex-status", { jobId, cursor: 0, wait_ms: 500 });
    data.commentary = await call("codex-commentary", { jobId, offset: 0 });
    data.result = await call("codex-result", { jobId, offset: 0 });
  } else if (scenario === "busy") {
    await mcpInitialize();
    data.started = await call("codex-start", initialArgs("first writer"));
    await sleep(120);
    data.reply = await call("codex-reply", { threadId: "thread-1", prompt: "second writer" });
    const jobId = data.started.result?.structuredContent?.jobId;
    data.cancel = await call("codex-cancel", { jobId });
  } else if (scenario === "hold") {
    await mcpInitialize();
    data.started = await call("codex-start", initialArgs("cross-bridge writer"));
    await sleep(1800);
    const jobId = data.started.result?.structuredContent?.jobId;
    data.cancel = await call("codex-cancel", { jobId });
  } else if (scenario === "idle") {
    await mcpInitialize();
    data.call = await call("codex", initialArgs("idle forever"));
    data.ping = await request("ping");
  } else if (scenario === "review" || scenario === "review-exited") {
    await mcpInitialize();
    data.review = await call("codex-review", { threadId: "thread-review", target: { type: "baseBranch", branch: "main" }, delivery: "inline" });
  } else if (scenario === "detached-review") {
    await mcpInitialize();
    data.started = await call("codex-review-start", {
      threadId: "thread-review",
      target: { type: "custom", instructions: "review safely" },
      delivery: "detached",
    });
    await sleep(100);
    data.reply = await call("codex-reply", {
      threadId: "thread-review-detached",
      prompt: "must not overlap detached review",
    });
    const jobId = data.started.result?.structuredContent?.jobId;
    data.cancel = await call("codex-cancel", { jobId });
  } else if (scenario === "threads") {
    await mcpInitialize();
    data.list = await call("codex-thread-list", { cwd: `${stubDir}/workspace`, limit: 10, archived: false });
    data.read = await call("codex-thread-read", { threadId: "thread-listed", includeTurns: true, limit: 5 });
    data.fork = await call("codex-thread-fork", { threadId: "thread-listed", lastTurnId: "turn-read" });
    data.archive = await call("codex-thread-archive", { threadId: "thread-listed" });
    data.unarchive = await call("codex-thread-unarchive", { threadId: "thread-listed" });
  } else if (scenario === "archive-withheld") {
    await mcpInitialize();
    data.first = await call("codex-thread-archive", { threadId: "thread-mutation" });
    data.second = await call("codex-thread-unarchive", { threadId: "thread-mutation" });
  } else if (scenario === "approval" || scenario === "question") {
    await mcpInitialize(true);
    data.result = await call("codex", initialArgs("interact"));
  } else if (scenario === "approval-no-elicit") {
    await mcpInitialize(false);
    data.result = await call("codex", initialArgs("cannot interact"));
  } else if (scenario === "secret-question") {
    await mcpInitialize(true);
    data.result = await call("codex", initialArgs("secret interact"));
  } else if (scenario === "permission") {
    await mcpInitialize(false);
    data.result = await call("codex", initialArgs("permission interact"));
  } else if (scenario === "question-no-elicit") {
    await mcpInitialize(false);
    const startedAt = Date.now();
    data.result = await call("codex", initialArgs("foreground question"));
    data.elapsedMs = Date.now() - startedAt;
  } else if (scenario === "interaction-timeout") {
    await mcpInitialize(true);
    const startedAt = Date.now();
    data.result = await call("codex", initialArgs("let interaction expire"));
    data.elapsedMs = Date.now() - startedAt;
  } else if (scenario === "foreground-interaction-hidden") {
    await mcpInitialize(true);
    data.result = await call("codex", initialArgs("interact"));
    data.duringRound = await interactionsDuringRound;
  } else if (scenario === "deferred-question-die") {
    await mcpInitialize(true);
    data.result = await call("codex", initialArgs("interact"));
    data.ping = await call("ping", {});
  } else if (scenario === "queued-interaction") {
    await mcpInitialize(false);
    data.started = await call("codex-start", initialArgs("interact"));
    await sleep(100);
    data.interactions = await call("codex-interactions", {});
    const interactionId = data.interactions.result?.structuredContent?.interactions?.[0]?.interactionId;
    data.resolved = await call("codex-interaction-resolve", { interactionId, decision: "accept" });
    await sleep(80);
    const jobId = data.started.result?.structuredContent?.jobId;
    data.status = await call("codex-status", { jobId, cursor: 0, wait_ms: 500 });
  } else if (scenario === "die-first" || scenario === "early-die-first") {
    await mcpInitialize();
    data.first = await call("codex", initialArgs("FIRST_MUST_NOT_REPLAY"));
    data.second = await call("codex", initialArgs("SECOND_OK"));
  } else if (scenario === "turn-start-delayed") {
    await mcpInitialize();
    const open = call("codex", initialArgs("delayed start"));
    if (!await waitFor(() => fs.existsSync(`${stubDir}/app-stdin.jsonl`) &&
      fs.readFileSync(`${stubDir}/app-stdin.jsonl`, "utf8").includes('"method":"turn/start"'))) {
      throw new Error("delayed turn/start was not captured");
    }
    data.peek = await call("codex-peek", { threadId: "thread-1" });
    data.sidecarsWhileStarting = readSidecars();
    data.call = await open;
  } else if (scenario === "retention-newer" || scenario === "retention-journal") {
    await mcpInitialize();
    data.list = await call("codex-thread-list", { limit: 5 });
    await sleep(300);
    data.journalExists = fs.existsSync(retentionJournal);
  } else if (scenario === "stale-race") {
    await mcpInitialize();
    const slot = process.env.MCP_STUB_RACE_SLOT || String(process.pid);
    fs.writeFileSync(`${stubDir}/race-ready-${slot}`, "ready\n");
    if (!await waitFor(() => fs.existsSync(process.env.MCP_STUB_START_GATE), 3000)) {
      throw new Error("stale-lease race gate did not open");
    }
    data.started = await call("codex-reply-start", {
      threadId: "thread-stale",
      prompt: "take stale lease",
    });
    const jobId = data.started.result?.structuredContent?.jobId;
    if (jobId) {
      await sleep(400);
      data.cancel = await call("codex-cancel", { jobId });
    }
  } else if (scenario === "invalid") {
    await mcpInitialize();
    data.invalid = await call("codex", { prompt: "missing controls" });
    data.badGoal = await call("codex-goal-set", { threadId: "thread-goal" });
    data.badResolve = await call("codex-interaction-resolve", { interactionId: "i", decision: "accept", answers: [] });
  } else if (scenario === "auth") {
    await mcpInitialize();
    data.first = await call("codex", initialArgs("authenticate"));
    data.second = await call("codex", initialArgs("must be latched"));
  } else {
    await mcpInitialize();
    data.call = await call("codex", initialArgs("hello"));
  }
} catch (error) {
  driverError = error.stack || String(error);
}

await sleep(100);
child.stdin.end();
const closeInfo = await Promise.race([
  new Promise((resolve) => child.once("close", (code, signal) => resolve({ code, signal }))),
  sleep(5000).then(() => {
    try { process.kill(-child.pid, "SIGTERM"); } catch {}
    return { code: null, signal: "timeout" };
  }),
]);
if (closeInfo.signal === "timeout") {
  await sleep(150);
  try { process.kill(-child.pid, "SIGKILL"); } catch {}
  await sleep(50);
}

const readJsonl = (file) => {
  if (!fs.existsSync(file)) return [];
  return fs.readFileSync(file, "utf8").split("\n").filter(Boolean).map((line) => {
    try { return JSON.parse(line); } catch { return { raw: line }; }
  });
};
process.stdout.write(`${JSON.stringify({
  scenario,
  serverDir,
  durableRoot,
  driverError,
  closeInfo,
  frames,
  rawLines,
  data,
  appRequests: readJsonl(`${stubDir}/app-stdin.jsonl`),
  appSpawns: readJsonl(`${stubDir}/app-spawns.jsonl`),
  stderr,
  parseTail: parseBuffer,
})}\n`, () => process.exit(0));
EOF
}

test_codex_http_case() {
  local label="$1" scenario="$2"
  local tmpdir output_file status

  echo "--- $label ---"
  tmpdir=$(mktemp -d)
  output_file="$tmpdir/output.txt"
  mkdir -p "$tmpdir/real-codex-home" "$tmpdir/state" \
    "$tmpdir/project-a" "$tmpdir/project-b"
  printf '%s' '{"token":"stub"}' > "$tmpdir/real-codex-home/auth.json"
  printf '%s' '{}' > "$tmpdir/real-codex-home/models_cache.json"
  printf '%s' 'not a directory' > "$tmpdir/project-file"
  ln -s "$tmpdir/project-a" "$tmpdir/project-link"
  write_codex_app_server_stub "$tmpdir"

  set +e
  MCP_AGENTS_TEST_HTTP_DIR="$tmpdir" \
    "$TIMEOUT_CMD" 20 node --input-type=module - \
      "$scenario" "$(pwd)" >"$output_file" 2>&1 <<'EOF'
import { appendFileSync, readFileSync, readdirSync } from "node:fs";
import { createServer, request as httpRequest } from "node:http";
import { spawn } from "node:child_process";
import { Client, StreamableHTTPClientTransport } from "@modelcontextprotocol/client";

const [scenario, serverDir] = process.argv.slice(2);
const testDir = process.env.MCP_AGENTS_TEST_HTTP_DIR;
const tokenFile = `${testDir}/bearer-token`;
const port = await new Promise((resolve, reject) => {
  const probe = createServer();
  probe.once("error", reject);
  probe.listen(0, "127.0.0.1", () => {
    const address = probe.address();
    probe.close((error) => error ? reject(error) : resolve(address.port));
  });
});

const child = spawn(process.execPath, [
  "server.js",
  "--provider", "codex",
  "--transport", "http",
  "--http-port", String(port),
  "--http-token-file", tokenFile,
  "--http-runtime-idle-timeout", scenario === "pool" ? "10" : "0.15",
  "--codex-state-root", `${testDir}/state/mcp-agents/codex`,
  ...(scenario === "foreground-question" ? ["--approval_policy", "on-request"] : []),
], {
  cwd: serverDir,
  detached: true,
  stdio: ["pipe", "pipe", "pipe"],
  env: {
    ...process.env,
    PATH: `${testDir}:${process.env.PATH}`,
    CODEX_HOME: `${testDir}/real-codex-home`,
    XDG_STATE_HOME: `${testDir}/state`,
    MCP_STUB_APP_CAPTURE_DIR: testDir,
    MCP_STUB_APP_MODE: ["active", "active-request", "shutdown-active"].includes(scenario)
      ? "park"
      : scenario === "post-terminal-grace" ? "delayed"
      : scenario === "uncertain-eviction" ? "die-first"
      : scenario === "foreground-question" ? "question" : "normal",
    MCP_STUB_APP_WORKSPACE: `${testDir}/project-a`,
    MCP_STUB_CODEX_VERSION: "codex-cli 0.149.1",
  },
});
appendFileSync(process.env.MCP_AGENTS_TEST_CHILD_REGISTRY, `${child.pid}\n`);
child.stdout.resume();
let stderr = "";
child.stderr.setEncoding("utf8");
child.stderr.on("data", (chunk) => { stderr += chunk; });

const ready = new Promise((resolve, reject) => {
  const timer = setTimeout(
    () => reject(new Error(`Codex HTTP daemon did not become ready: ${stderr}`)),
    5_000,
  );
  const inspect = () => {
    if (!stderr.includes("HTTP MCP listening")) return;
    clearTimeout(timer);
    child.stderr.off("data", inspect);
    resolve();
  };
  child.stderr.on("data", inspect);
  child.once("exit", (code, signal) => {
    clearTimeout(timer);
    reject(new Error(
      `Codex HTTP daemon exited before ready: code=${code} signal=${signal} stderr=${stderr}`,
    ));
  });
});

const rawRequest = (projectRoot) => new Promise((resolve, reject) => {
  const headers = {
    Authorization: `Bearer ${readFileSync(tokenFile, "utf8").trim()}`,
    "Content-Type": "application/json",
  };
  if (projectRoot !== undefined) {
    headers["X-Mcp-Agents-Project-Root"] = projectRoot;
  }
  const req = httpRequest({
    host: "127.0.0.1",
    port,
    path: "/mcp",
    method: "POST",
    headers,
  }, (response) => {
    response.resume();
    response.once("end", () => resolve(response.statusCode));
  });
  req.once("error", reject);
  req.end("{}");
});

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const waitFor = async (predicate, timeoutMs = 3_000) => {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return true;
    await sleep(20);
  }
  return false;
};
const readJsonl = (path) => {
  try {
    return readFileSync(path, "utf8").split("\n").filter(Boolean).map(JSON.parse);
  } catch {
    return [];
  }
};
const reapCount = () =>
  (stderr.match(/reaped idle Codex runtime/gu) ?? []).length;
const countProjectRuntimes = () => {
  try {
    const projects = `${testDir}/state/mcp-agents/codex/projects`;
    return readdirSync(projects).reduce((count, project) => {
      const bridges = `${projects}/${project}/v1/bridges`;
      try { return count + readdirSync(bridges).length; } catch { return count; }
    }, 0);
  } catch {
    return 0;
  }
};
const openClient = async (projectRoot, era = "modern", { elicit = false } = {}) => {
  const versionNegotiation = era === "modern"
    ? { mode: { pin: "2026-07-28" } }
    : { mode: "legacy" };
  const client = new Client(
    { name: `codex-http-${era}-test`, version: "0.0.0" },
    {
      versionNegotiation,
      ...(elicit ? {
        capabilities: { elicitation: { form: {} } },
        inputRequired: { autoFulfill: true, maxRounds: 8 },
      } : {}),
    },
  );
  if (elicit) {
    client.setRequestHandler("elicitation/create", async () => ({
      action: "accept",
      content: { choice: "Ship" },
    }));
  }
  const transport = new StreamableHTTPClientTransport(
    new URL(`http://127.0.0.1:${port}/mcp`),
    {
      requestInit: {
        headers: {
          Authorization: `Bearer ${readFileSync(tokenFile, "utf8").trim()}`,
          "X-Mcp-Agents-Project-Root": projectRoot,
        },
      },
    },
  );
  await client.connect(transport);
  return client;
};
const initialArgs = (cwd, prompt = "hello") => ({
  prompt,
  cwd,
  sandbox: "read-only",
  model: "gpt-6-astra",
  model_reasoning_effort: "high",
});
const assertToolText = (result, expected) => {
  if (result.content?.[0]?.text !== expected) {
    throw new Error(`expected ${expected}, got ${JSON.stringify(result)}`);
  }
};

const stop = async () => {
  if (child.exitCode !== null || child.signalCode !== null) return;
  try { process.kill(-child.pid, "SIGTERM"); } catch {}
  await Promise.race([
    new Promise((resolve) => child.once("exit", resolve)),
    new Promise((resolve) => setTimeout(resolve, 2_000)),
  ]);
  try { process.kill(-child.pid, "SIGKILL"); } catch {}
};

try {
  await ready;
  if (scenario === "roots") {
    const cases = [
      [undefined, "missing"],
      ["relative", "relative"],
      [`${testDir}/absent`, "nonexistent"],
      [`${testDir}/project-file`, "non-directory"],
    ];
    for (const [projectRoot, description] of cases) {
      const status = await rawRequest(projectRoot);
      if (status !== 400) {
        throw new Error(`${description} project root returned ${status}, expected 400`);
      }
    }
  } else if (scenario === "pool") {
    const [modern, legacy] = await Promise.all([
      openClient(`${testDir}/project-a`, "modern"),
      openClient(`${testDir}/project-link`, "legacy"),
    ]);
    try {
      assertToolText(
        await modern.callTool({ name: "ping", arguments: {} }),
        "pong",
      );
      assertToolText(
        await legacy.callTool({ name: "ping", arguments: {} }),
        "pong",
      );
      if (modern.getProtocolEra() !== "modern" || legacy.getProtocolEra() !== "legacy") {
        throw new Error("modern and legacy clients did not preserve independent MCP eras");
      }
      if (countProjectRuntimes() !== 1) {
        throw new Error(`same canonical root created ${countProjectRuntimes()} runtimes`);
      }
      assertToolText(await modern.callTool({
        name: "codex",
        arguments: initialArgs(`${testDir}/project-a`, "modern client"),
      }), "APP_SERVER_OK");
      assertToolText(await legacy.callTool({
        name: "codex",
        arguments: initialArgs(`${testDir}/project-a`, "legacy client"),
      }), "APP_SERVER_OK");
    } finally {
      await Promise.allSettled([modern.close(), legacy.close()]);
    }

    const isolated = await openClient(`${testDir}/project-b`);
    try {
      assertToolText(await isolated.callTool({
        name: "codex",
        arguments: initialArgs(`${testDir}/project-b`, "isolated project"),
      }), "APP_SERVER_OK");
    } finally {
      await isolated.close();
    }
    await waitFor(() => readJsonl(`${testDir}/app-spawns.jsonl`).length === 2);
    if (readJsonl(`${testDir}/app-spawns.jsonl`).length !== 2) {
      throw new Error("same-root requests did not share one child or projects were not isolated");
    }
    if (countProjectRuntimes() !== 2) {
      throw new Error(`expected two isolated runtimes, got ${countProjectRuntimes()}`);
    }
    const modernReadyCount = (stderr.match(/Codex MCP adapter ready \(era=modern/gu) ?? []).length;
    const legacyReadyCount = (stderr.match(/Codex MCP adapter ready \(era=legacy/gu) ?? []).length;
    if (modernReadyCount !== 2 || legacyReadyCount !== 1) {
      throw new Error(
        `adapter readiness was logged per request instead of per runtime/era: ` +
        `modern=${modernReadyCount} legacy=${legacyReadyCount}`,
      );
    }
  } else if (scenario === "eviction") {
    const first = await openClient(`${testDir}/project-a`);
    assertToolText(await first.callTool({
      name: "codex",
      arguments: initialArgs(`${testDir}/project-a`, "first generation"),
    }), "APP_SERVER_OK");
    await first.close();
    if (!await waitFor(() => stderr.includes("reaped idle Codex runtime"))) {
      throw new Error(`runtime was not reaped after becoming idle: ${stderr}`);
    }
    if (countProjectRuntimes() !== 0) {
      throw new Error("reaped runtime left a live bridge directory");
    }
    const second = await openClient(`${testDir}/project-a`);
    try {
      assertToolText(await second.callTool({
        name: "codex",
        arguments: initialArgs(`${testDir}/project-a`, "second generation"),
      }), "APP_SERVER_OK");
    } finally {
      await second.close();
    }
    if (!await waitFor(() => readJsonl(`${testDir}/app-spawns.jsonl`).length === 2)) {
      throw new Error("request after eviction did not recreate the Codex runtime");
    }
  } else if (scenario === "foreground-question") {
    // Round one returns input_required, and its per-request transport closes
    // once that response is sent, aborting the request's signal. The preserved
    // turn has to survive that abort so round two can answer it.
    const client = await openClient(`${testDir}/project-a`, "modern", { elicit: true });
    try {
      assertToolText(await client.callTool({
        name: "codex",
        arguments: initialArgs(`${testDir}/project-a`, "foreground question"),
      }), "INTERACTION_OK");
    } finally {
      await client.close();
    }
    const interrupts = readJsonl(`${testDir}/app-stdin.jsonl`)
      .filter((message) => message.method === "turn/interrupt");
    if (interrupts.length !== 0) {
      throw new Error(`an HTTP input round interrupted its preserved turn: ${JSON.stringify(interrupts)}`);
    }
  } else if (scenario === "uncertain-eviction") {
    // The first App Server child dies right after accepting turn/start, so the
    // turn's outcome is unknown. Stdio reclaimed that when the bridge exited;
    // the daemon must still evict the idle runtime and free the thread.
    const first = await openClient(`${testDir}/project-a`);
    let lost;
    try {
      lost = await first.callTool({
        name: "codex",
        arguments: initialArgs(`${testDir}/project-a`, "lose the generation"),
      });
    } finally {
      await first.close();
    }
    if (lost.structuredContent?.code !== "codex_outcome_unknown") {
      throw new Error(`child death did not surface as outcome unknown: ${JSON.stringify(lost)}`);
    }
    if (!await waitFor(() => reapCount() > 0, 5_000)) {
      throw new Error(`runtime stranded by child death was never reaped: ${stderr}`);
    }
    const second = await openClient(`${testDir}/project-a`);
    try {
      const reply = await second.callTool({
        name: "codex-reply",
        arguments: { threadId: "thread-1", prompt: "after eviction" },
      });
      if (reply.structuredContent?.code === "codex_thread_busy") {
        throw new Error(`eviction kept the stranded thread lease: ${JSON.stringify(reply)}`);
      }
      assertToolText(reply, "APP_SERVER_OK");
    } finally {
      await second.close();
    }
  } else if (scenario === "active") {
    const starter = await openClient(`${testDir}/project-a`);
    const started = await starter.callTool({
      name: "codex-start",
      arguments: initialArgs(`${testDir}/project-a`, "keep running"),
    });
    const jobId = started.structuredContent?.jobId;
    if (!jobId) throw new Error(`Codex job did not start: ${JSON.stringify(started)}`);
    await starter.close();
    const reapsBeforeActiveWait = reapCount();
    await sleep(500);
    if (reapCount() !== reapsBeforeActiveWait) {
      throw new Error("runtime was reaped while a background job was active");
    }
    const observer = await openClient(`${testDir}/project-link`);
    try {
      const status = await observer.callTool({
        name: "codex-status",
        arguments: { jobId, cursor: 0, wait_ms: 0 },
      });
      if (status.structuredContent?.state !== "running") {
        throw new Error(`shared job was not running: ${JSON.stringify(status)}`);
      }
      await observer.callTool({ name: "codex-cancel", arguments: { jobId } });
    } finally {
      await observer.close();
    }
    if (readJsonl(`${testDir}/app-spawns.jsonl`).length !== 1) {
      throw new Error("active same-root job did not retain one shared App Server");
    }
    if (!await waitFor(() => reapCount() > reapsBeforeActiveWait)) {
      throw new Error("runtime was not reaped after its active job became terminal");
    }
  } else if (scenario === "post-terminal-grace") {
    const starter = await openClient(`${testDir}/project-a`);
    const started = await starter.callTool({
      name: "codex-start",
      arguments: initialArgs(`${testDir}/project-a`, "complete later"),
    });
    if (!started.structuredContent?.jobId) {
      throw new Error(`Codex job did not start: ${JSON.stringify(started)}`);
    }
    await starter.close();
    const reapsBeforeCompletion = reapCount();
    await sleep(250);
    if (reapCount() !== reapsBeforeCompletion) {
      throw new Error("runtime was reaped while the delayed job was active");
    }
    if (!await waitFor(() =>
      readJsonl(`${testDir}/app-completions.jsonl`).length === 1
    )) {
      throw new Error("delayed background job did not complete");
    }
    if (reapCount() !== reapsBeforeCompletion) {
      throw new Error("runtime was reaped as soon as the background job completed");
    }
    await sleep(100);
    if (reapCount() !== reapsBeforeCompletion) {
      throw new Error("runtime did not receive a fresh idle grace period after completion");
    }
    if (!await waitFor(() => reapCount() > reapsBeforeCompletion)) {
      throw new Error("runtime was not reaped after its post-completion idle grace");
    }
  } else if (scenario === "active-request" || scenario === "shutdown-active") {
    const client = await openClient(`${testDir}/project-a`);
    const openCall = client.callTool({
      name: "codex",
      arguments: initialArgs(`${testDir}/project-a`, "foreground work"),
    }).catch((error) => ({ transportError: error.message }));
    if (!await waitFor(() =>
      readJsonl(`${testDir}/app-stdin.jsonl`).some((entry) =>
        entry.method === "turn/start"
      )
    )) throw new Error("foreground request never reached App Server");
    const reapsBeforeActiveWait = reapCount();
    await sleep(500);
    if (reapCount() !== reapsBeforeActiveWait) {
      throw new Error("runtime was reaped while a foreground request was active");
    }
    if (scenario === "active-request") {
      await client.close();
      await Promise.race([openCall, sleep(1_500)]);
      if (!await waitFor(() => reapCount() > reapsBeforeActiveWait)) {
        throw new Error("runtime was not reaped after foreground cancellation settled");
      }
    } else {
      const stoppedAt = Date.now();
      try { process.kill(-child.pid, "SIGTERM"); } catch {}
      const closeInfo = await Promise.race([
        new Promise((resolve) => child.once("exit", (code, signal) =>
          resolve({ code, signal })
        )),
        sleep(3_000).then(() => null),
      ]);
      await client.close().catch(() => {});
      await Promise.race([openCall, sleep(500)]);
      if (!closeInfo || Date.now() - stoppedAt >= 3_000) {
        throw new Error(`daemon did not drain active request: ${stderr}`);
      }
      const appPid = readJsonl(`${testDir}/app-spawns.jsonl`)[0]?.pid;
      if (appPid) {
        try {
          process.kill(appPid, 0);
          throw new Error(`App Server child ${appPid} survived daemon shutdown`);
        } catch (error) {
          if (error?.code !== "ESRCH") throw error;
        }
      }
    }
  } else {
    throw new Error(`unknown scenario: ${scenario}`);
  }
} finally {
  await stop();
}
EOF
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (exit $status)"
    cat "$output_file"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$tmpdir"
}

test_codex_app_case() {
  local label="$1" scenario="$2" predicate="$3" server_args="${4:-}"
  local command_timeout="${5:-9}" tmpdir status summary ok
  echo "--- $label ---"
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/real-codex-home" "$tmpdir/state" "$tmpdir/workspace"
  printf '%s' '{"token":"stub"}' > "$tmpdir/real-codex-home/auth.json"
  printf '%s' '{}' > "$tmpdir/real-codex-home/models_cache.json"
  write_codex_app_server_stub "$tmpdir"
  write_codex_app_server_driver "$tmpdir"
  set +e
  summary=$($TIMEOUT_CMD "$command_timeout" node "$tmpdir/app-driver.mjs" \
    "$tmpdir" "$(pwd)" "$scenario" "$server_args" 2>/dev/null)
  status=$?
  set -e
  ok=1
  [ "$status" -eq 0 ] || ok=0
  printf '%s' "$summary" | jq -e \
    "(.driverError == null) and (.closeInfo.code == 0) and ($predicate)" \
    >/dev/null 2>&1 || ok=0
  if [ "$ok" -eq 1 ]; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (status=$status)"
    echo "  Summary: ${summary:0:16000}"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$tmpdir"
}

test_codex_modern_interaction_case() {
  local label="$1" scenario="$2" predicate="$3"
  local tmpdir status summary ok
  echo "--- $label ---"
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/real-codex-home" "$tmpdir/state" "$tmpdir/workspace"
  printf '%s' '{"token":"stub"}' > "$tmpdir/real-codex-home/auth.json"
  printf '%s' '{}' > "$tmpdir/real-codex-home/models_cache.json"
  write_codex_app_server_stub "$tmpdir"
  cat >"$tmpdir/mcp-wire-proxy.mjs" <<'EOF'
import fs from "node:fs";
import { spawn } from "node:child_process";

const [serverDir, stateRoot] = process.argv.slice(2);
const captureBase = `${process.env.MCP_STUB_APP_CAPTURE_DIR}/mcp-wire-${process.pid}`;
const child = spawn(process.execPath, [
  "server.js",
  "--provider", "codex",
  "--approval_policy", process.env.MCP_STUB_APPROVAL_POLICY,
  "--codex-state-root", stateRoot,
], {
  cwd: serverDir,
  env: process.env,
  stdio: ["pipe", "pipe", "pipe"],
});
fs.appendFileSync(process.env.MCP_AGENTS_TEST_CHILD_REGISTRY, `${child.pid}\n`);

process.stdin.on("data", (chunk) => {
  fs.appendFileSync(`${captureBase}.client.raw`, chunk);
  child.stdin.write(chunk);
});
process.stdin.on("end", () => child.stdin.end());
child.stdout.on("data", (chunk) => {
  fs.appendFileSync(`${captureBase}.server.raw`, chunk);
  process.stdout.write(chunk);
});
child.stderr.pipe(process.stderr);
child.once("close", (code, signal) => {
  process.exitCode = signal ? 1 : (code ?? 1);
});
for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => child.kill(signal));
}
process.once("exit", () => {
  try { child.kill("SIGKILL"); } catch {}
});
EOF

  set +e
  summary=$($TIMEOUT_CMD 12 node --input-type=module - \
    "$tmpdir" "$(pwd)" "$scenario" 2>/dev/null <<'EOF'
import crypto from "node:crypto";
import fs from "node:fs";
import { Client } from "@modelcontextprotocol/client";
import {
  StdioClientTransport,
  getDefaultEnvironment,
} from "@modelcontextprotocol/client/stdio";

const [stubDir, serverDir, scenario] = process.argv.slice(2);
const supportsElicitation = scenario === "question";
const client = new Client(
  { name: "mcp-agents-modern-interaction-test", version: "0.0.0" },
  {
    capabilities: supportsElicitation ? { elicitation: { form: {} } } : {},
    versionNegotiation: {
      mode: { pin: "2026-07-28" },
      probe: { timeoutMs: 1_000, maxRetries: 0 },
    },
    inputRequired: { autoFulfill: true, maxRounds: 8 },
  },
);
let elicitationCount = 0;
if (supportsElicitation) {
  client.setRequestHandler("elicitation/create", async () => {
    elicitationCount += 1;
    return { action: "accept", content: { choice: "Ship" } };
  });
}
const transport = new StdioClientTransport({
  command: process.execPath,
  args: [`${stubDir}/mcp-wire-proxy.mjs`, serverDir, `${stubDir}/state`],
  cwd: serverDir,
  env: {
    ...getDefaultEnvironment(),
    PATH: `${stubDir}:${process.env.PATH}`,
    CODEX_HOME: `${stubDir}/real-codex-home`,
    MCP_AGENTS_TEST_CHILD_REGISTRY: process.env.MCP_AGENTS_TEST_CHILD_REGISTRY,
    MCP_STUB_APP_CAPTURE_DIR: stubDir,
    MCP_STUB_APP_MODE: "question",
    MCP_STUB_APP_WORKSPACE: `${stubDir}/workspace`,
    MCP_STUB_CODEX_VERSION: "codex-cli 0.149.1",
    MCP_STUB_REQUIRE_SESSION: "0",
    MCP_STUB_APPROVAL_POLICY: supportsElicitation ? "on-request" : "never",
  },
  stderr: "pipe",
});
let stderr = "";
transport.stderr?.setEncoding("utf8");
transport.stderr?.on("data", (chunk) => { stderr += chunk; });
const callArguments = {
  prompt: "PRIVATE_MODERN_PROMPT",
  cwd: `${stubDir}/workspace`,
  sandbox: "read-only",
  model: "gpt-6-astra",
  model_reasoning_effort: "high",
};
let result;
let era;
let driverError;
try {
  await client.connect(transport);
  era = client.getProtocolEra();
  fs.appendFileSync(process.env.MCP_AGENTS_TEST_CHILD_REGISTRY, `${transport.pid}\n`);
  result = await client.callTool({ name: "codex", arguments: callArguments });
} catch (error) {
  driverError = error.stack || String(error);
} finally {
  await client.close().catch(() => {});
}
await new Promise((resolve) => setTimeout(resolve, 100));

const readJsonl = (file) => {
  if (!fs.existsSync(file)) return [];
  return fs.readFileSync(file, "utf8").split("\n").filter(Boolean).map((line) => {
    try { return JSON.parse(line); } catch { return { raw: line }; }
  });
};
const wireFiles = fs.readdirSync(stubDir).filter((name) => name.startsWith("mcp-wire-"));
const readWire = (suffix) => wireFiles
  .filter((name) => name.endsWith(suffix))
  .flatMap((name) => readJsonl(`${stubDir}/${name}`));
const serverFrames = readWire(".server.raw");
const clientFrames = readWire(".client.raw");
const inputRequiredFrames = serverFrames.filter((frame) =>
  frame?.result?.resultType === "input_required"
);
// The digest an unkeyed call binding would carry for these exact arguments.
// A continuation must never commit to it, or its prompt is guessable offline.
const canonicalJson = (value) => {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (value !== null && typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) =>
      `${JSON.stringify(key)}:${canonicalJson(value[key])}`
    ).join(",")}}`;
  }
  return JSON.stringify(value);
};
const unkeyedCallHash = crypto.createHash("sha256")
  .update(`codex\n${canonicalJson(callArguments)}`)
  .digest("hex");
const decodedRequestStates = inputRequiredFrames.map((frame) => {
  const state = frame.result.requestState;
  if (typeof state !== "string") return null;
  try {
    const body = state.split(".")[1];
    return JSON.parse(Buffer.from(body, "base64url").toString("utf8"));
  } catch {
    return null;
  }
});
process.stdout.write(`${JSON.stringify({
  scenario,
  driverError,
  era,
  result,
  elicitationCount,
  serverFrames,
  clientFrames,
  inputRequiredFrames,
  decodedRequestStates,
  unkeyedCallHash,
  appRequests: readJsonl(`${stubDir}/app-stdin.jsonl`),
  stderr,
})}\n`);
EOF
  )
  status=$?
  set -e
  ok=1
  [ "$status" -eq 0 ] || ok=0
  printf '%s' "$summary" | jq -e \
    "(.driverError == null) and (.era == \"modern\") and ($predicate)" \
    >/dev/null 2>&1 || ok=0
  if [ "$ok" -eq 1 ]; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (status=$status)"
    echo "  Summary: ${summary:0:16000}"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$tmpdir"
}

test_codex_app_bridge_restart() {
  local label="$1" tmpdir first second first_status second_status ok
  echo "--- $label ---"
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/real-codex-home" "$tmpdir/state" "$tmpdir/workspace"
  printf '%s' '{"token":"stub"}' > "$tmpdir/real-codex-home/auth.json"
  printf '%s' '{}' > "$tmpdir/real-codex-home/models_cache.json"
  write_codex_app_server_stub "$tmpdir"
  write_codex_app_server_driver "$tmpdir"

  set +e
  first=$($TIMEOUT_CMD 9 node "$tmpdir/app-driver.mjs" \
    "$tmpdir" "$(pwd)" "normal" "" 2>/dev/null)
  first_status=$?
  second=$($TIMEOUT_CMD 9 node "$tmpdir/app-driver.mjs" \
    "$tmpdir" "$(pwd)" "restart-reply" "" 2>/dev/null)
  second_status=$?
  set -e

  ok=1
  [ "$first_status" -eq 0 ] && [ "$second_status" -eq 0 ] || ok=0
  printf '%s\n%s\n' "$first" "$second" | jq -s -e '
    (.[0].driverError == null) and (.[1].driverError == null) and
    (.[0].closeInfo.code == 0) and (.[1].closeInfo.code == 0) and
    (.[0].data.call.result.structuredContent.threadId == "thread-1") and
    (.[1].data.reply.result.structuredContent.threadId == "thread-1") and
    (.[1].appSpawns | length == 2) and
    (.[1].appSpawns[0].codexHome != .[1].appSpawns[1].codexHome) and
    (.[1].appSpawns[0].storage.sessions.target ==
      .[1].appSpawns[1].storage.sessions.target) and
    (.[1].appSpawns[0].storage.writerLocks.target ==
      .[1].appSpawns[1].storage.writerLocks.target) and
    (.[1].appSpawns[0].storage.goals.target ==
      .[1].appSpawns[1].storage.goals.target) and
    ([.[1].appRequests[] | select(.method == "thread/start")] | length == 1) and
    ([.[1].appRequests[] | select(.method == "thread/resume" and
      .params.threadId == "thread-1")] | length == 1)
  ' >/dev/null 2>&1 || ok=0

  if [ "$ok" -eq 1 ]; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (first=$first_status, second=$second_status)"
    echo "  First: ${first:0:8000}"
    echo "  Second: ${second:0:8000}"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$tmpdir"
}

test_codex_app_cross_bridge_busy() {
  local label="$1" tmpdir first_file first_pid first_status second second_status ok ready
  echo "--- $label ---"
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/real-codex-home" "$tmpdir/state" "$tmpdir/workspace"
  printf '%s' '{"token":"stub"}' > "$tmpdir/real-codex-home/auth.json"
  printf '%s' '{}' > "$tmpdir/real-codex-home/models_cache.json"
  write_codex_app_server_stub "$tmpdir"
  write_codex_app_server_driver "$tmpdir"
  first_file="$tmpdir/first.json"

  $TIMEOUT_CMD 9 node "$tmpdir/app-driver.mjs" \
    "$tmpdir" "$(pwd)" "hold" "" >"$first_file" 2>/dev/null &
  first_pid=$!
  ready=0
  for _ in $(seq 1 60); do
    if [ -f "$tmpdir/app-stdin.jsonl" ] &&
      rg -q '"method":"turn/start"' "$tmpdir/app-stdin.jsonl"; then
      ready=1
      break
    fi
    sleep 0.05
  done

  set +e
  second=$($TIMEOUT_CMD 9 node "$tmpdir/app-driver.mjs" \
    "$tmpdir" "$(pwd)" "restart-reply" "" 2>/dev/null)
  second_status=$?
  wait "$first_pid"
  first_status=$?
  set -e

  ok=1
  [ "$ready" -eq 1 ] && [ "$first_status" -eq 0 ] &&
    [ "$second_status" -eq 0 ] || ok=0
  printf '%s' "$second" | jq -e '
    (.driverError == null) and
    (.data.reply.result.isError == true) and
    (.data.reply.result.structuredContent.code == "codex_thread_busy") and
    (.appSpawns | length == 2) and
    (.appSpawns[0].storage.writerLocks.target ==
      .appSpawns[1].storage.writerLocks.target) and
    ([.appRequests[] | select(.method == "turn/start")] | length == 1) and
    ([.appRequests[] | select(.method == "thread/resume")] | length == 0)
  ' >/dev/null 2>&1 || ok=0

  if [ "$ok" -eq 1 ]; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (ready=$ready, first=$first_status, second=$second_status)"
    echo "  First: $(head -c 8000 "$first_file" 2>/dev/null || true)"
    echo "  Second: ${second:0:8000}"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$tmpdir"
}

test_codex_app_stale_lease_race() {
  local label="$1" tmpdir project_hash thread_hash lease_dir gate
  local first_file second_file first_pid second_pid first_status second_status
  local ready ok
  echo "--- $label ---"
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/real-codex-home" "$tmpdir/state" "$tmpdir/workspace"
  printf '%s' '{"token":"stub"}' > "$tmpdir/real-codex-home/auth.json"
  printf '%s' '{}' > "$tmpdir/real-codex-home/models_cache.json"
  write_codex_app_server_stub "$tmpdir"
  write_codex_app_server_driver "$tmpdir"

  project_hash=$(node -e \
    'const {createHash}=require("node:crypto");const fs=require("node:fs");process.stdout.write(createHash("sha256").update(fs.realpathSync(process.argv[1])).digest("hex"))' \
    "$(pwd)")
  thread_hash=$(node -e \
    'const {createHash}=require("node:crypto");process.stdout.write(createHash("sha256").update(process.argv[1]).digest("hex"))' \
    "thread-stale")
  lease_dir="$tmpdir/state/mcp-agents/codex/projects/$project_hash/v1/leases"
  mkdir -p "$lease_dir"
  printf '%s\n' \
    '{"version":1,"bridgeId":"dead","pid":99999999,"threadId":"thread-stale","operation":"turn","createdAt":"2000-01-01T00:00:00.000Z"}' \
    > "$lease_dir/$thread_hash.json"

  gate="$tmpdir/race-go"
  first_file="$tmpdir/race-first.json"
  second_file="$tmpdir/race-second.json"
  MCP_STUB_RACE_SLOT=first MCP_STUB_START_GATE="$gate" \
    $TIMEOUT_CMD 9 node "$tmpdir/app-driver.mjs" \
      "$tmpdir" "$(pwd)" "stale-race" "" >"$first_file" 2>/dev/null &
  first_pid=$!
  MCP_STUB_RACE_SLOT=second MCP_STUB_START_GATE="$gate" \
    $TIMEOUT_CMD 9 node "$tmpdir/app-driver.mjs" \
      "$tmpdir" "$(pwd)" "stale-race" "" >"$second_file" 2>/dev/null &
  second_pid=$!

  ready=0
  for _ in $(seq 1 60); do
    if [ -f "$tmpdir/race-ready-first" ] && [ -f "$tmpdir/race-ready-second" ]; then
      ready=1
      break
    fi
    sleep 0.05
  done
  printf '%s\n' 'go' > "$gate"

  set +e
  wait "$first_pid"
  first_status=$?
  wait "$second_pid"
  second_status=$?
  set -e

  ok=1
  [ "$ready" -eq 1 ] && [ "$first_status" -eq 0 ] &&
    [ "$second_status" -eq 0 ] || ok=0
  jq -s -e '
    (map(.driverError == null) | all) and
    (map(.closeInfo.code == 0) | all) and
    ([.[].data.started.result | select(.isError != true)] | length == 1) and
    ([.[].data.started.result | select(.isError == true and
      .structuredContent.code == "codex_thread_busy")] | length == 1)
  ' "$first_file" "$second_file" >/dev/null 2>&1 || ok=0
  if [ -f "$tmpdir/app-stdin.jsonl" ]; then
    jq -s -e '
      ([.[] | select(.method == "thread/resume" and
        .params.threadId == "thread-stale")] | length == 1) and
      ([.[] | select(.method == "turn/start" and
        .params.threadId == "thread-stale")] | length == 1)
    ' "$tmpdir/app-stdin.jsonl" >/dev/null 2>&1 || ok=0
  else
    ok=0
  fi

  if [ "$ok" -eq 1 ]; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (ready=$ready, first=$first_status, second=$second_status)"
    echo "  First: $(head -c 8000 "$first_file" 2>/dev/null || true)"
    echo "  Second: $(head -c 8000 "$second_file" 2>/dev/null || true)"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$tmpdir"
}

# ── Helpers: browser downstream + lease stubs and an MCP stdio driver. ──────
# These exercise the public process boundary: the real server parses real CLI
# argv, forwards real JSON-RPC frames, and shells out to a separately spawned
# lease helper. No browser helper is called past its production interface.
write_browser_mcp_stub() {
  cat >"$1/browser-mcp-stub" <<'EOF'
#!/usr/bin/env node
const fs = require("node:fs");
const path = require("node:path");

const mode = process.env.MCP_STUB_BROWSER_MODE || "normal";
const captureDir = process.env.MCP_STUB_BROWSER_CAPTURE_DIR;
const spawnFile = path.join(captureDir, "downstream-spawns.jsonl");
const rootsFile = path.join(captureDir, "roots-response.txt");
const rootsResponsesFile = path.join(captureDir, "roots-responses.jsonl");
const callCountFile = path.join(captureDir, "browser-call-count");
fs.appendFileSync(process.env.MCP_AGENTS_TEST_CHILD_REGISTRY, `${process.pid}\n`);
const argv = process.argv.slice(2);
fs.appendFileSync(spawnFile, `${JSON.stringify({ pid: process.pid, at: Date.now(), argv })}\n`);
const spawnOrdinal = fs.readFileSync(spawnFile, "utf8")
  .split("\n").filter(Boolean).length;
const stdinFile = path.join(captureDir, `${process.pid}.stdin`);
const send = (value, callback) =>
  process.stdout.write(`${JSON.stringify(value)}\n`, callback);
const initializeResult = (id) => ({
  jsonrpc: "2.0",
  id,
  result: {
    protocolVersion: "2024-11-05",
    capabilities: { tools: {} },
    serverInfo: { name: "browser-stub", version: "1.7.0" },
  },
});
const tools = () => [
  { name: "navigate_page", title: "Navigate title", description: "Navigate", annotations: { readOnlyHint: false }, inputSchema: { type: "object", properties: { url: { type: "string" } } } },
  { name: "performance_start_trace", description: "Start trace", inputSchema: { type: "object", properties: { reload: { type: "boolean" } } } },
  { name: "performance_stop_trace", description: "Stop trace", inputSchema: { type: "object", properties: {} } },
  { name: "performance_analyze_insight", description: "Analyze insight", inputSchema: { type: "object", properties: { insightSetId: { type: "string" } } } },
  { name: "lighthouse_audit", description: "Run Lighthouse", inputSchema: { type: "object", properties: {} } },
  { name: "upload_file", description: "Upload a file", inputSchema: { type: "object", properties: { filePath: { type: "string" } } } },
];
const toolsResult = (id) => ({ jsonrpc: "2.0", id, result: { tools: tools() } });
const result = (id, text = "BROWSER_OK") => send({
  jsonrpc: "2.0",
  id,
  result: {
    content: [{ type: "text", text }],
    structuredContent: { content: text },
  },
});
const connectFailure = (id) => send({
  jsonrpc: "2.0",
  id,
  result: {
    isError: true,
    content: [{ type: "text", text: "Could not connect to Chrome. Failed to fetch browser WebSocket URL." }],
    structuredContent: { content: "Could not connect to Chrome: Failed to fetch browser webSocket URL" },
  },
});
const emitTools = (id) => {
  const line = JSON.stringify(toolsResult(id));
  if (mode === "split") {
    const cut = Math.floor(line.length / 2);
    process.stdout.write(line.slice(0, cut));
    setTimeout(() => process.stdout.write(`${line.slice(cut)}\n`), 30);
  } else if (mode === "interleaved") {
    process.stdout.write('{"jsonrpc":"2.0","method":"notifications/message","params":{"marker":"BROWSER_INTERLEAVED"}}\n');
    process.stdout.write(`${line}\n`);
  } else if (mode === "straddle") {
    process.stdout.write('DLE"}}\n');
    process.stdout.write(`${line}\n`);
  } else if (mode === "partialdie") {
    process.stdout.write(line.slice(0, Math.floor(line.length / 2)), () => process.exit(0));
  } else if (mode === "nonewlinedie") {
    process.stdout.write(line, () => process.exit(0));
  } else if (mode === "oversized") {
    send({ jsonrpc: "2.0", method: "notifications/message", params: { marker: "BROWSER_OVERSIZED", pad: "x".repeat(11 * 1024 * 1024) } });
    process.stdout.write(`${line}\n`);
  } else if (mode === "bp") {
    send({ jsonrpc: "2.0", method: "notifications/message", params: { marker: "BROWSER_BP", pad: "x".repeat(300000) } });
    process.stdout.write(`${line}\n`);
  } else {
    process.stdout.write(`${line}\n`);
  }
};
const nextCallCount = () => {
  let count = 0;
  try { count = Number(fs.readFileSync(callCountFile, "utf8")); } catch {}
  count += 1;
  fs.writeFileSync(callCountFile, String(count));
  return count;
};
const batchedCallIds = [];
let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  input += chunk;
  let newline;
  while ((newline = input.indexOf("\n")) !== -1) {
    const raw = input.slice(0, newline);
    input = input.slice(newline + 1);
    fs.appendFileSync(stdinFile, `${raw}\n`);
    let message;
    try { message = JSON.parse(raw); } catch { continue; }
    if (message.method === "initialize") {
      if (mode !== "hang-init") send(initializeResult(message.id));
      if (mode === "straddle") {
        process.stdout.write('{"jsonrpc":"2.0","method":"notifications/message","params":{"marker":"STRAD');
      }
    } else if (message.method === "notifications/initialized") {
      if (mode === "timeout-no-result" && spawnOrdinal > 1) {
        setTimeout(() => process.stdout.write("LATCH_CLEAR"), 25);
      }
      if (mode === "roots") {
        setTimeout(() => send({ jsonrpc: "2.0", id: "roots-1", method: "roots/list", params: {} }), 20);
      } else if (mode === "restart-roots") {
        setTimeout(() => send({ jsonrpc: "2.0", id: "roots-reused", method: "roots/list", params: {} }), 20);
      }
    } else if (message.method === "tools/list") {
      emitTools(message.id);
    } else if (message.method === "tools/call") {
      const count = nextCallCount();
      if (mode === "die") {
        process.exit(0);
      } else if (mode === "connectfail") {
        if (count === 1 || process.env.MCP_STUB_LEASE_MODE !== "status-absent") connectFailure(message.id);
        else result(message.id, "RECOVERED_NEXT_CALL");
      } else if (mode === "deferred-hard-timeout-recovery") {
        if (spawnOrdinal === 1 && message.id === 4) {
          result(message.id, "CLASSIFIER_OK_4");
        } else if (spawnOrdinal === 1 && message.id === 3) {
          setTimeout(() => result(message.id, "DEFERRED_RAW_3"), 10);
        }
      } else if (mode === "activity") {
        setTimeout(() => send({ jsonrpc: "2.0", method: "notifications/message", params: { activity: 1 } }), 50);
        setTimeout(() => send({ jsonrpc: "2.0", id: "activity-roots", method: "roots/list", params: {} }), 130);
        setTimeout(() => send({ jsonrpc: "2.0", method: "notifications/message", params: { activity: 2 } }), 210);
        setTimeout(() => result(message.id, "ACTIVITY_DONE"), 290);
      } else if (mode === "controlled-result") {
        const timer = setInterval(() => {
          if (!fs.existsSync(path.join(captureDir, `allow-call-${message.id}`))) return;
          clearInterval(timer);
          result(message.id, `RAW_CANCELLED_${message.id}`);
        }, 10);
      } else if (mode === "restart-outstanding" || mode === "restart-outstanding-unsafe") {
        if (mode === "restart-outstanding-unsafe" && spawnOrdinal === 1) {
          process.stdout.write('{"jsonrpc":"2.0","id":999,"result":');
        }
        if (spawnOrdinal > 1) {
          result(message.id, `REPLACEMENT_OK_${message.id}`);
          setTimeout(() => process.stdout.write("LATCH_CLEAR"), 25);
        }
      } else if (mode === "oversized-result") {
        send({
          jsonrpc: "2.0",
          id: message.id,
          result: {
            content: [{ type: "text", text: "RAW_OVERSIZED_RESULT" }],
            structuredContent: {
              content: "RAW_OVERSIZED_RESULT",
              pad: "x".repeat(11 * 1024 * 1024),
            },
          },
        });
      } else if (mode === "oversized-result-id-after") {
        send({
          jsonrpc: "2.0",
          result: {
            content: [{ type: "text", text: "RAW_OVERSIZED_ID_AFTER" }],
            structuredContent: { content: "RAW_OVERSIZED_ID_AFTER" },
          },
          id: message.id,
          pad: "x".repeat(11 * 1024 * 1024),
        });
      } else if (mode === "oversized-complete-id-after") {
        send({
          jsonrpc: "2.0",
          result: {
            content: [{ type: "text", text: "RAW_OVERSIZED_COMPLETE" }],
            structuredContent: { content: "RAW_OVERSIZED_COMPLETE" },
          },
          id: message.id,
          pad: "x".repeat(2048),
        });
      } else if (mode === "finalize-multiframe") {
        batchedCallIds.push(message.id);
        if (batchedCallIds.length === 3) {
          const lines = batchedCallIds.map((id) => JSON.stringify({
            jsonrpc: "2.0",
            id,
            result: {
              content: [{ type: "text", text: `RAW_FINALIZE_${id}` }],
              structuredContent: { content: `RAW_FINALIZE_${id}` },
            },
          })).join("\n");
          process.stdout.write(`${lines}\n`, () => process.exit(0));
        }
      } else if (mode === "malformed-result") {
        process.stdout.write(
          `{"jsonrpc":"2.0","id":${JSON.stringify(message.id)},"result":INVALID}\n`,
        );
        setTimeout(() => process.stdout.write("LATCH_CLEAR"), 25);
      } else if (mode === "timeout-no-result") {
        if (spawnOrdinal === 1) {
          process.stdout.write('{"jsonrpc":"2.0","id":999,"result":');
          setTimeout(() => process.stdout.write("OLD_PROCESS_SHOULD_BE_DEAD"), 1200);
        } else {
          setTimeout(() => process.stdout.write("LATCH_CLEAR"), 25);
        }
      } else if (mode === "call-nonewlinedie") {
        process.stdout.write(JSON.stringify({
          jsonrpc: "2.0",
          id: message.id,
          result: {
            content: [{ type: "text", text: `BROWSER_UNTERMINATED_${message.id}` }],
            structuredContent: { content: `BROWSER_UNTERMINATED_${message.id}` },
          },
        }), () => process.exit(0));
      } else if (mode === "stderr") {
        const timer = setInterval(() => process.stderr.write("noisy but not browser activity\n"), 35);
        setTimeout(() => clearInterval(timer), 350);
      } else {
        result(message.id, `BROWSER_OK_${message.id}`);
      }
    } else if (message.id === "roots-1") {
      fs.writeFileSync(rootsFile, raw);
    } else if (message.id === "roots-reused") {
      fs.appendFileSync(rootsResponsesFile, `${JSON.stringify({
        pid: process.pid,
        spawnOrdinal,
        raw,
      })}\n`);
    }
  }
});
process.stdin.on("end", () => process.exit(0));
setInterval(() => {}, 1 << 30);
EOF
  chmod +x "$1/browser-mcp-stub"
}

write_browser_lease_stub() {
  cat >"$1/browser-identity-stub" <<'EOF'
#!/usr/bin/env node
const fs = require("node:fs");
const http = require("node:http");

const [port, identity, readyFile] = process.argv.slice(2);
const captureDir = process.env.MCP_STUB_BROWSER_CAPTURE_DIR;
fs.appendFileSync(process.env.MCP_AGENTS_TEST_CHILD_REGISTRY, `${process.pid}\n`);
let identityReads = 0;
const server = http.createServer((request, response) => {
  if (request.url !== "/json/version") {
    response.writeHead(404).end();
    return;
  }
  identityReads += 1;
  const respond = () => {
    const reportedIdentity =
      fs.existsSync(`${captureDir}/substitute-after-acquire`) && identityReads > 1
        ? "local-substitute"
        : identity;
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({
      Browser: "Chrome/Test",
      webSocketDebuggerUrl:
        `ws://127.0.0.1:${port}/devtools/browser/${reportedIdentity}`,
    }));
  };
  if (
    fs.existsSync(`${captureDir}/slow-post-identity`) && identityReads > 1
  ) setTimeout(respond, 300);
  else if (fs.existsSync(`${captureDir}/slow-identity`)) setTimeout(respond, 700);
  else respond();
});
const stop = () => server.close(() => process.exit(0));
process.on("SIGTERM", stop);
process.on("SIGINT", stop);
server.listen(Number(port), "127.0.0.1", () => {
  fs.writeFileSync(readyFile, String(process.pid));
});
EOF
  chmod +x "$1/browser-identity-stub"
  cat >"$1/browser-lease-stub" <<'EOF'
#!/usr/bin/env node
const { spawn } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const mode = process.env.MCP_STUB_LEASE_MODE || "ready";
const captureDir = process.env.MCP_STUB_BROWSER_CAPTURE_DIR;
const callsFile = path.join(captureDir, "lease-calls.jsonl");
const releaseCompletionsFile = path.join(captureDir, "release-completions.jsonl");
const countFile = path.join(captureDir, "acquire-count");
const identityStateFile = path.join(captureDir, "identity-current.json");
const termFile = path.join(captureDir, "acquire-terminated.txt");
const args = process.argv.slice(2);
fs.appendFileSync(process.env.MCP_AGENTS_TEST_CHILD_REGISTRY, `${process.pid}\n`);
fs.appendFileSync(callsFile, `${JSON.stringify({ pid: process.pid, at: Date.now(), args })}\n`);
const valueAfter = (flag) => {
  const index = args.indexOf(flag);
  return index === -1 ? undefined : args[index + 1];
};
const acquireCount = () => {
  let count = 0;
  try { count = Number(fs.readFileSync(countFile, "utf8")); } catch {}
  count += 1;
  fs.writeFileSync(countFile, String(count));
  return count;
};
const stopIdentity = () => {
  let state;
  try { state = JSON.parse(fs.readFileSync(identityStateFile, "utf8")); } catch {}
  if (state?.pid) {
    try { process.kill(state.pid, "SIGTERM"); } catch {}
    for (let attempt = 0; attempt < 200; attempt += 1) {
      try { process.kill(state.pid, 0); } catch { break; }
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5);
    }
    try { process.kill(state.pid, 0); process.kill(state.pid, "SIGKILL"); } catch {}
  }
  try { fs.unlinkSync(identityStateFile); } catch {}
};
const startIdentity = (port, identity) => {
  stopIdentity();
  const readyFile = path.join(captureDir, `identity-ready-${process.pid}`);
  const child = spawn(
    process.execPath,
    [path.join(__dirname, "browser-identity-stub"), port, identity, readyFile],
    { detached: true, stdio: "ignore", env: process.env },
  );
  for (let attempt = 0; attempt < 200 && !fs.existsSync(readyFile); attempt += 1) {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5);
  }
  if (!fs.existsSync(readyFile)) {
    try { process.kill(-child.pid, "SIGKILL"); } catch {}
    throw new Error("identity stub failed to bind");
  }
  try { fs.unlinkSync(readyFile); } catch {}
  fs.writeFileSync(identityStateFile, JSON.stringify({
    pid: child.pid,
    port: Number(port),
    identity,
  }));
};
const ready = (count) => {
  const port = valueAfter("--local-cdp-port");
  const wrong = mode === "wrong-port" ? String(Number(port) + 1) : port;
  if (mode !== "wrong-port" && mode !== "malformed" && mode !== "duplicate-proto") {
    startIdentity(port, `remote-gen-${count}`);
  }
  const lines = [
    "record_version=1",
    "state=ready",
    ...(mode === "malformed" ? [] : [`generation=gen-${count}`]),
    "lease_id=cbx_test",
    `local_cdp_port=${wrong}`,
    `browser_url=http://127.0.0.1:${wrong}`,
    `idle_teardown=${mode === "cap-only" ? "cap-only" : "enabled"}`,
    ...(mode === "duplicate-proto" ? ["__proto__=first", "__proto__=second"] : []),
  ];
  process.stdout.write(`${lines.join("\n")}\n`);
  process.exit(0);
};
const command = args[0];
if (command === "acquire") {
  const count = acquireCount();
  if ([
    "acquire-term",
    "acquire-term-timeout",
    "acquire-ignore-term-timeout",
    "acquire-derived-timeout",
  ].includes(mode)) {
    process.on("SIGTERM", () => {
      fs.writeFileSync(termFile, "SIGTERM\n");
      if (mode !== "acquire-ignore-term-timeout") process.exit(69);
    });
    fs.writeFileSync(path.join(captureDir, "acquire-hanging-ready"), "ready\n");
    setInterval(() => {}, 1 << 30);
  } else if (mode === "unavailable-69") {
    process.stderr.write("no capacity\n");
    process.exit(69);
  } else if (mode === "dev-unreachable-69") {
    process.stderr.write("GUI not verified — dev server not reachable at :5100\n");
    process.exit(69);
  } else if (mode === "minio-unreachable-69") {
    process.stderr.write("GUI not verified — MinIO not reachable at :9000\n");
    process.exit(69);
  } else if (mode === "acquire-empty-70") {
    process.exit(70);
  } else if (
    mode === "port-75-always" ||
    (mode === "port-75-once" && count === 1) ||
    (mode === "ready-port-75-second" && count === 2)
  ) {
    setTimeout(() => {
      process.stdout.write("state=port_unavailable\n");
      process.exit(75);
    }, 120);
  } else if (mode === "slow-ready") {
    setTimeout(() => ready(count), 280);
  } else {
    ready(count);
  }
} else if (command === "status") {
  if (mode === "status-ready") process.exit(0);
  if (mode === "status-slow-ready") {
    setTimeout(() => process.exit(0), 300);
    return;
  }
  if (mode === "status-corrupt") process.exit(70);
  process.exit(69);
} else if (command === "release") {
  stopIdentity();
  if (mode === "release-69" || mode === "cap-only") process.exit(69);
  if (mode === "release-empty-70") process.exit(70);
  const reason = valueAfter("--reason");
  const finishRelease = () => {
    fs.appendFileSync(releaseCompletionsFile, `${JSON.stringify({
      pid: process.pid,
      at: Date.now(),
      reason,
    })}\n`);
    process.exit(0);
  };
  if (mode === "slow-idle-release" && reason === "idle") {
    setTimeout(finishRelease, 2200);
  } else if (mode === "slow-shutdown-release" && reason === "shutdown") {
    setTimeout(finishRelease, 650);
  } else {
    finishRelease();
  }
} else {
  process.exit(64);
}
EOF
  chmod +x "$1/browser-lease-stub"
}

write_browser_npx_stub() {
  cat >"$1/npx" <<'EOF'
#!/usr/bin/env node
const { spawn } = require("node:child_process");
const fs = require("node:fs");

fs.appendFileSync(process.env.MCP_AGENTS_TEST_CHILD_REGISTRY, `${process.pid}\n`);
const args = process.argv.slice(2);
fs.appendFileSync(
  process.env.MCP_STUB_NPX_CAPTURE,
  `${JSON.stringify({ pid: process.pid, at: Date.now(), args })}\n`,
);
const child = spawn(process.env.MCP_STUB_NPX_TARGET, args.slice(2), {
  stdio: "inherit",
});
child.on("error", (error) => {
  process.stderr.write(`${error.message}\n`);
  process.exit(1);
});
child.on("close", (code, signal) => {
  if (signal) process.kill(process.pid, signal);
  else process.exit(code ?? 1);
});
EOF
  chmod +x "$1/npx"
}

write_browser_driver() {
  cat >"$1/browser-driver.mjs" <<'EOF'
import { spawn } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";

const [stubDir, serverDir, scenario, browserMode, leaseMode, idle, hard] = process.argv.slice(2);
const captureDir = `${stubDir}/captures`;
const browserCommand = JSON.stringify([`${stubDir}/browser-mcp-stub`, "--stub-base"]);
const leaseCommand = JSON.stringify([`${stubDir}/browser-lease-stub`]);
const child = spawn("node", [
  "server.js",
  "--provider", "browser",
  "--browser_lease_command", leaseCommand,
  "--browser_command", browserCommand,
  "--browser_idle_timeout", idle,
  "--browser_viewport", "1280x720",
  "--browser_app_port", "5100",
  "--browser_log_file", `${stubDir}/browser.log`,
  "--browser_allowed_url_pattern", "http://127.0.0.1/*",
  "--browser_allowed_url_pattern", "https://example.test/*",
  "--timeout", hard,
], {
  cwd: serverDir,
  env: {
    ...process.env,
    MCP_STUB_BROWSER_MODE: browserMode,
    MCP_STUB_LEASE_MODE: leaseMode,
    MCP_STUB_BROWSER_CAPTURE_DIR: captureDir,
    MCP_AGENTS_BROWSER_COMMAND: '["/definitely/not-the-cli-browser"]',
    MCP_AGENTS_BROWSER_LEASE_COMMAND: '["/definitely/not-the-cli-lease"]',
    MCP_AGENTS_TEST_BROWSER_PROGRESS_INTERVAL_MS: "45",
    ...(leaseMode === "acquire-derived-timeout" ? {} : {
      // 180ms lost a race with process spawn: a freshly written file costs
      // ~210ms on its first exec here (~29ms once warm), so the helper was
      // killed before it recorded its invocation. The helper hangs forever in
      // these modes, so a larger budget still times out -- it just stops
      // killing the stub before it can install its SIGTERM handler.
      MCP_AGENTS_TEST_BROWSER_HELPER_TIMEOUT_MS:
        ["acquire-term-timeout", "acquire-ignore-term-timeout"].includes(leaseMode)
          ? "1200"
          : "1500",
    }),
    MCP_AGENTS_TEST_BROWSER_IDENTITY_TIMEOUT_MS: "500",
    MCP_AGENTS_TEST_BROWSER_HELPER_TERM_GRACE_MS: "250",
    MCP_AGENTS_TEST_BROWSER_SHUTDOWN_RELEASE_TIMEOUT_MS: "1500",
    MCP_AGENTS_TEST_BROWSER_FLUSH_STALL_MS: "400",
    ...(scenario === "oversized-complete-id-after" ? {
      MCP_AGENTS_TEST_BROWSER_REWRITE_MAX_BYTES: "512",
    } : {}),
  },
  stdio: ["pipe", "pipe", "pipe"],
});
let out = "";
let err = "";
let parseBuffer = "";
let parseErrors = 0;
let driverError;
let lastNoisyStderrAt;
let rootsRequestCount = 0;
let substituteChild;
let latchClearBeforeClose = false;
const rootsClientResponses = [];
const frames = [];
const frameEvents = [];
const rawLines = [];
const pending = new Map();
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const waitFor = async (predicate, message, timeoutMs = 2000) => {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await delay(10);
  }
  throw new Error(message);
};
const sendRaw = (line) => child.stdin.write(`${line}\n`);
const send = (message) => sendRaw(JSON.stringify(message));
const request = (id, method, params, timeoutMs = 2500) => new Promise((resolve, reject) => {
  const timer = setTimeout(() => {
    pending.delete(JSON.stringify(id));
    reject(new Error(`${method} ${JSON.stringify(id)} timed out`));
  }, timeoutMs);
  pending.set(JSON.stringify(id), {
    resolve: (frame) => { clearTimeout(timer); resolve(frame); },
  });
  send({ jsonrpc: "2.0", id, method, params });
});
const call = (id, token) => request(id, "tools/call", {
  name: "navigate_page",
  arguments: { url: `http://127.0.0.1/${id}` },
  ...(token === undefined ? {} : { _meta: { progressToken: token } }),
});
child.stdin.on("error", () => {});
child.stderr.on("data", (chunk) => {
  const text = chunk.toString();
  err += text;
  if (text.includes("[chrome-devtools] noisy but not browser activity")) {
    lastNoisyStderrAt = Date.now();
  }
});
child.stdout.on("data", (chunk) => {
  const text = chunk.toString();
  out += text;
  parseBuffer += text;
  let newline;
  while ((newline = parseBuffer.indexOf("\n")) !== -1) {
    const line = parseBuffer.slice(0, newline);
    parseBuffer = parseBuffer.slice(newline + 1);
    if (!line) continue;
    rawLines.push(line.length > 100000 ? line.slice(0, 300) : line);
    let frame;
    try { frame = JSON.parse(line); } catch { parseErrors += 1; continue; }
    if (frame.params?.pad) frame.params.pad = `[${frame.params.pad.length} bytes]`;
    if (frame.result?.structuredContent?.pad) {
      frame.result.structuredContent.pad =
        `[${frame.result.structuredContent.pad.length} bytes]`;
    }
    if (frame.pad) frame.pad = `[${frame.pad.length} bytes]`;
    frames.push(frame);
    frameEvents.push({ at: Date.now(), id: frame.id, method: frame.method });
    if (frame.method === "roots/list") {
      if (frame.id === "roots-1") {
        sendRaw('{"jsonrpc":"2.0", "id":"roots-1", "result":{"roots":[{"uri":"file:///workspace","name":"root"}]}}');
      } else if (scenario === "restart-roots" || scenario === "restart-roots-out-of-order") {
        rootsRequestCount += 1;
        const response = (id, name) =>
          `{"jsonrpc":"2.0", "id":${JSON.stringify(id)}, "result":{"roots":[{"uri":"file:///workspace","name":"${name}"}]}}`;
        if (scenario === "restart-roots" ) {
          const name = rootsRequestCount === 1 ? "dead-root" : "replacement-root";
          rootsClientResponses.push({ order: name, id: frame.id });
          sendRaw(response(frame.id, name));
        } else if (rootsRequestCount === 1) {
          rootsClientResponses.push({ order: "held-dead", id: frame.id });
        } else {
          rootsClientResponses.push({ order: "replacement-first", id: frame.id });
          sendRaw(response(frame.id, "replacement-root"));
          if (scenario === "restart-roots-out-of-order") {
            setTimeout(() => {
              rootsClientResponses.push({ order: "stale-second", id: "roots-reused" });
              sendRaw(response("roots-reused", "dead-root"));
            }, 30);
          }
        }
      } else {
        send({ jsonrpc: "2.0", id: frame.id, result: { roots: [] } });
      }
    }
    const waiter = pending.get(JSON.stringify(frame.id));
    if (waiter && (frame.result || frame.error)) {
      pending.delete(JSON.stringify(frame.id));
      waiter.resolve(frame);
    }
  }
});
const closed = new Promise((resolve) => child.once("close", (code, signal) => resolve({ code, signal })));
const hardStop = setTimeout(() => { try { child.kill("SIGKILL"); } catch {} }, 6500);
const initializeParams = {
  protocolVersion: "2024-11-05",
  capabilities: { roots: { listChanged: true }, sampling: {} },
  clientInfo: { name: "browser-driver", version: "0" },
};
try {
  const initialized = request(1, "initialize", initializeParams);
  await initialized;
  if (scenario !== "hang-init") {
    send({ jsonrpc: "2.0", method: "notifications/initialized" });
    if (scenario !== "skip-list") {
      if (scenario === "bp") {
        child.stdout.pause();
        setTimeout(() => child.stdout.resume(), 350);
      }
      await request(2, "tools/list", {});
    }
  }
  if (scenario === "normal" || scenario === "shutdown" || scenario === "idle-zero") {
    await call(3);
    if (scenario === "idle-zero") await delay(260);
  } else if (scenario === "first-call-substitution") {
    writeFileSync(`${captureDir}/substitute-after-acquire`, "ready\n");
    await call(3);
  } else if (scenario === "concurrent-identity-substitution") {
    // Two calls queue on one shared cold acquire (leaseMode "slow-ready" delays
    // "ready" long enough for both to stack up before it resolves), so both are
    // forwarded to downstream under the SAME generation with no pre-flight
    // identity gate between them. The substituted identity mismatches on the
    // first post-response check (the acquire itself consumed read #1), so the
    // first result's classification discards the shared generation. The second
    // result's classification must then be bound to the generation snapshot it
    // was actually issued under, not the now-emptied live generation.
    writeFileSync(`${captureDir}/substitute-after-acquire`, "ready\n");
    const first = call(3);
    const second = call(4);
    await Promise.all([first, second]);
  } else if (scenario === "classifier-identity-toctou") {
    writeFileSync(`${captureDir}/slow-post-identity`, "ready\n");
    await call(3);
  } else if (scenario === "classifier-connect-toctou") {
    await call(3);
  } else if (scenario === "deferred-hard-timeout-recovery") {
    writeFileSync(`${captureDir}/slow-post-identity`, "ready\n");
    const timeout = call(5);
    await delay(120);
    await Promise.all([call(3), call(4), timeout]);
    await delay(100);
  } else if (scenario === "cancel-open-generation-change") {
    const late = call(3);
    await waitFor(() => {
      try {
        return readFileSync(`${captureDir}/browser-call-count`, "utf8") === "1";
      } catch { return false; }
    }, "browser call was not forwarded before cancellation");
    send({
      jsonrpc: "2.0",
      method: "notifications/cancelled",
      params: { requestId: 3, reason: "test open-call cancellation" },
    });
    await waitFor(() => {
      try {
        return readFileSync(`${captureDir}/lease-calls.jsonl`, "utf8")
          .split("\n").filter(Boolean)
          .map((line) => JSON.parse(line))
          .some((entry) => entry.args[0] === "release" && entry.args.includes("idle"));
      } catch { return false; }
    }, "generation was not released while the cancelled call remained open");
    writeFileSync(`${captureDir}/allow-call-3`, "ready\n");
    await late;
  } else if (scenario === "restart-outstanding" || scenario === "restart-outstanding-unsafe") {
    let abandonedError;
    const abandoned = call(3).catch((error) => { abandonedError = error; });
    await waitFor(() => {
      try {
        return readFileSync(`${captureDir}/browser-call-count`, "utf8") === "1";
      } catch { return false; }
    }, "browser call was not outstanding before restart");
    await waitFor(() => {
      try {
        return readFileSync(`${captureDir}/lease-calls.jsonl`, "utf8")
          .split("\n").filter(Boolean)
          .map((line) => JSON.parse(line))
          .some((entry) => entry.args[0] === "release" && entry.args.includes("idle"));
      } catch { return false; }
    }, "generation was not released before restart");
    await call(4);
    if (scenario === "restart-outstanding") {
      await waitFor(() => out.includes("LATCH_CLEAR"), "restart left the rewrite latch armed");
      latchClearBeforeClose = true;
    }
    await abandoned;
    if (abandonedError) throw abandonedError;
  } else if (scenario === "oversized-browser-result") {
    await call(3);
  } else if (scenario === "oversized-id-after-result") {
    await call(3);
  } else if (scenario === "oversized-complete-id-after") {
    await call(3);
  } else if (scenario === "finalize-multiframe") {
    writeFileSync(`${captureDir}/slow-post-identity`, "ready\n");
    await Promise.all([call(3), call(4), call(5)]);
  } else if (scenario === "malformed-browser-result") {
    await call(3);
    await waitFor(() => out.includes("LATCH_CLEAR"), "malformed result pinned the rewrite latch");
    latchClearBeforeClose = true;
  } else if (scenario === "browser-hard-timeout") {
    await call(3);
    await waitFor(() => out.includes("LATCH_CLEAR"), "hard timeout pinned the rewrite latch");
    latchClearBeforeClose = true;
  } else if (scenario === "unterminated-browser-result") {
    await call(3);
  } else if (scenario === "identity-substitution") {
    await call(3);
    const identityState = JSON.parse(
      readFileSync(`${captureDir}/identity-current.json`, "utf8"),
    );
    try { process.kill(identityState.pid, "SIGTERM"); } catch {}
    await waitFor(() => {
      try { process.kill(identityState.pid, 0); return false; } catch { return true; }
    }, "remote identity stub did not stop");
    const readyFile = `${captureDir}/substitute-ready`;
    substituteChild = spawn(process.execPath, [
      `${stubDir}/browser-identity-stub`,
      String(identityState.port),
      "local-substitute",
      readyFile,
    ], { detached: true, stdio: "ignore", env: process.env });
    await waitFor(() => existsSync(readyFile), "substitute identity stub did not bind");
    await call(4);
  } else if (scenario === "identity-unreachable") {
    await call(3);
    const identityState = JSON.parse(
      readFileSync(`${captureDir}/identity-current.json`, "utf8"),
    );
    try { process.kill(identityState.pid, "SIGTERM"); } catch {}
    await waitFor(() => {
      try { process.kill(identityState.pid, 0); return false; } catch { return true; }
    }, "remote identity stub did not stop");
    await call(4);
  } else if (scenario === "slow-identity-idle") {
    await call(3);
    writeFileSync(`${captureDir}/slow-identity`, "ready\n");
    await call(4);
  } else if (scenario === "shutdown-acquire") {
    void call(3).catch(() => undefined);
    await waitFor(
      () => existsSync(`${captureDir}/acquire-hanging-ready`),
      "acquire helper did not enter its cleanup-trapped wait",
    );
  } else if (scenario === "unknown") {
    await request(3, "tools/call", {
      name: "not_advertised",
      arguments: {},
    });
  } else if (scenario === "skip-list") {
    await call(3);
  } else if (scenario === "slow-ready") {
    const first = call(3, "browser-progress");
    const second = call(4, 42);
    const canceled = call(5, { invalid: true }).catch(() => undefined);
    const absent = call(6);
    await delay(55);
    send({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 5, reason: "test" } });
    await Promise.all([first, second, absent]);
    await delay(80);
    void canceled;
  } else if (["unavailable", "dev-unreachable", "minio-unreachable", "acquire-empty", "acquire-timeout", "acquire-kill-timeout", "derived-helper-timeout", "port-once", "restart-roots", "restart-roots-out-of-order", "port-always", "malformed", "wrong-port", "duplicate-proto", "die"].includes(scenario)) {
    await call(3);
  } else if (["status-ready", "status-corrupt", "status-absent"].includes(scenario)) {
    await call(3);
    if (scenario === "status-absent") await call(4);
  } else if (scenario === "roots") {
    await delay(160);
  } else if (scenario === "activity") {
    await call(3);
    await delay(220);
  } else if (scenario === "stderr") {
    send({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "navigate_page", arguments: { url: "http://127.0.0.1/stderr" } } });
    // Hold the noise window open well past the idle release. The release
    // helper stamps its own start time, so its spawn cost must still land
    // inside the noise for the ordering assertion -- release-before-last-noise
    // -- to mean "stderr did not reset idle".
    await delay(900);
  } else if (scenario === "idle-release" || scenario === "release-69" || scenario === "release-70" || scenario === "cap-only") {
    await call(3);
    await delay(260);
  } else if (scenario === "slow-idle-release") {
    await call(3);
    await delay(2450);
  }
} catch (error) {
  driverError = error instanceof Error ? error.message : String(error);
} finally {
  await delay(60);
  try { child.stdin.end(); } catch {}
}
const closeInfo = await closed;
if (substituteChild) {
  try { process.kill(-substituteChild.pid, "SIGTERM"); } catch {}
}
clearTimeout(hardStop);
const readJsonLines = (file) => {
  try {
    return readFileSync(file, "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line));
  } catch { return []; }
};
const spawns = readJsonLines(`${captureDir}/downstream-spawns.jsonl`).map((spawnInfo) => {
  let stdinRaw = "";
  try { stdinRaw = readFileSync(`${captureDir}/${spawnInfo.pid}.stdin`, "utf8"); } catch {}
  const stdin = stdinRaw.split("\n").filter(Boolean).flatMap((line) => {
    try { return [JSON.parse(line)]; } catch { return []; }
  });
  return { ...spawnInfo, stdinRaw, stdin };
});
const leaseCalls = readJsonLines(`${captureDir}/lease-calls.jsonl`);
const acquirePid = leaseCalls.find((callInfo) => callInfo.args[0] === "acquire")?.pid;
let acquireAlive = false;
try { if (acquirePid) process.kill(acquirePid, 0); acquireAlive = Boolean(acquirePid); } catch {}
const releaseCompletions = readJsonLines(`${captureDir}/release-completions.jsonl`);
const rootsResponses = readJsonLines(`${captureDir}/roots-responses.jsonl`);
let rootsResponse;
try { rootsResponse = readFileSync(`${captureDir}/roots-response.txt`, "utf8"); } catch {}
process.stdout.write(`${JSON.stringify({
  scenario,
  driverError,
  closeInfo,
  frames,
  frameEvents,
  rawLines,
  parseErrors,
  stderr: err,
  spawns,
  leaseCalls,
  releaseCompletions,
  rootsResponses,
  rootsClientResponses,
  latchClearBeforeClose,
  lastNoisyStderrAt,
  rootsResponse,
  acquireTerminated: existsSync(`${captureDir}/acquire-terminated.txt`),
  acquireAlive,
  browserLogExists: existsSync(`${stubDir}/browser.log`),
})}\n`);
EOF
}

test_browser_case() {
  local label="$1" scenario="$2" browser_mode="$3" lease_mode="$4"
  local idle="$5" hard="$6" predicate="$7"
  local tmpdir status summary ok warmdir
  echo "--- $label ---"
  tmpdir=$(mktemp -d)
  mkdir "$tmpdir/captures"
  write_browser_mcp_stub "$tmpdir"
  write_browser_lease_stub "$tmpdir"
  write_browser_driver "$tmpdir"
  # macOS pays a one-off scan on a file's FIRST exec: measured here at ~210ms
  # per freshly written file, dropping to ~29ms once that same file is warm.
  # Every case writes its stubs into a new mktemp dir, so cases with sub-second
  # budgets spend that scan inside the window they measure -- the deferred
  # hard-timeout case has 550ms minus a deliberate 280ms wait, leaving ~60ms of
  # headroom cold and ~240ms warm. Pay it up front. acquire-empty-70 exits
  # immediately and the throwaway capture dir keeps it out of this case's
  # captures.
  warmdir=$(mktemp -d)
  MCP_STUB_BROWSER_CAPTURE_DIR="$warmdir" MCP_STUB_LEASE_MODE=acquire-empty-70 \
    "$tmpdir/browser-lease-stub" acquire >/dev/null 2>&1 || true
  rm -rf "$warmdir"
  set +e
  summary=$($TIMEOUT_CMD 9 node "$tmpdir/browser-driver.mjs" \
    "$tmpdir" "$(pwd)" "$scenario" "$browser_mode" "$lease_mode" \
    "$idle" "$hard" 2>/dev/null)
  status=$?
  set -e
  ok=1
  [ "$status" -eq 0 ] || ok=0
  printf '%s' "$summary" | jq -e \
    "(.closeInfo.code == 0) and (.parseErrors == 0) and ($predicate)" \
    >/dev/null 2>&1 || ok=0
  if [ "$ok" -eq 1 ]; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (status=$status)"
    echo "  Summary: ${summary:0:14000}"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$tmpdir"
}

drive_browser_resolution_handshake() {
  local output_file="$1" expected_server_name="$2" client_name="$3"
  local sent_initialized=0
  printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{"roots":{"listChanged":true}},"clientInfo":{"name":"%s","version":"0"}}}\n' \
    "$client_name"
  for _ in $(seq 1 140); do
    if [ "$sent_initialized" -eq 0 ] && jq -e \
      --arg server_name "$expected_server_name" \
      'select(.id == 1 and .result.serverInfo.name == $server_name)' \
      "$output_file" >/dev/null 2>&1; then
      printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
      printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
      sent_initialized=1
    fi
    if [ "$sent_initialized" -eq 1 ] && jq -e \
      'select(.id == 2 and (.result.tools | length > 0))' \
      "$output_file" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.05
  done
  return 1
}

test_browser_local_resolution() {
  local label="$1" tmpdir output_file error_file status ok lease_command
  echo "--- $label ---"
  tmpdir=$(mktemp -d)
  mkdir "$tmpdir/captures"
  output_file="$tmpdir/output.jsonl"
  error_file="$tmpdir/error.txt"
  write_browser_lease_stub "$tmpdir"
  lease_command="[\"$tmpdir/browser-lease-stub\"]"
  set +e
  drive_browser_resolution_handshake \
    "$output_file" "chrome_devtools" "local-resolution-test" | \
    MCP_STUB_BROWSER_CAPTURE_DIR="$tmpdir/captures" \
    MCP_STUB_LEASE_MODE=ready \
    $TIMEOUT_CMD 8 $SERVER --provider browser \
      --browser_lease_command "$lease_command" \
      >"$output_file" 2>"$error_file"
  status=$?
  set -e
  ok=1
  [ "$status" -eq 0 ] || ok=0
  jq -e 'select(.id == 1 and .result.serverInfo.name == "chrome_devtools")' \
    "$output_file" >/dev/null 2>&1 || ok=0
  jq -e 'select(.id == 2 and (.result.tools | length > 0))' \
    "$output_file" >/dev/null 2>&1 || ok=0
  grep -Fq 'source=local package' "$error_file" || ok=0
  grep -Fq 'first startup may wait for npm to resolve chrome-devtools-mcp@latest' "$error_file" && ok=0
  if [ "$ok" -eq 1 ]; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (status=$status)"
    echo "  Output: $(cat "$output_file")"
    echo "  Error: $(cat "$error_file")"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$tmpdir"
}

test_browser_npx_resolution() {
  local label="$1" tmpdir package_dir output_file error_file npx_file
  local status ok lease_command node_bin_dir
  echo "--- $label ---"
  tmpdir=$(mktemp -d)
  package_dir="$tmpdir/published"
  mkdir -p "$tmpdir/captures" "$tmpdir/bin" \
    "$package_dir/node_modules/@modelcontextprotocol"
  cp server.js package.json "$package_dir/"
  ln -s "$(pwd)/node_modules/@modelcontextprotocol/server" \
    "$package_dir/node_modules/@modelcontextprotocol/server"
  ln -s "$(pwd)/node_modules/@modelcontextprotocol/node" \
    "$package_dir/node_modules/@modelcontextprotocol/node"
  write_browser_mcp_stub "$tmpdir"
  write_browser_lease_stub "$tmpdir"
  write_browser_npx_stub "$tmpdir/bin"
  output_file="$tmpdir/output.jsonl"
  error_file="$tmpdir/error.txt"
  npx_file="$tmpdir/npx.jsonl"
  lease_command="[\"$tmpdir/browser-lease-stub\"]"
  node_bin_dir=$(dirname "$(command -v node)")
  set +e
  drive_browser_resolution_handshake \
    "$output_file" "browser-stub" "npx-resolution-test" | \
    PATH="$tmpdir/bin:$node_bin_dir:/usr/bin:/bin" NODE_PATH= \
    MCP_STUB_BROWSER_CAPTURE_DIR="$tmpdir/captures" \
    MCP_STUB_BROWSER_MODE=normal \
    MCP_STUB_LEASE_MODE=ready \
    MCP_STUB_NPX_CAPTURE="$npx_file" \
    MCP_STUB_NPX_TARGET="$tmpdir/browser-mcp-stub" \
    $TIMEOUT_CMD 8 node "$package_dir/server.js" --provider browser \
      --browser_lease_command "$lease_command" \
      >"$output_file" 2>"$error_file"
  status=$?
  set -e
  ok=1
  [ "$status" -eq 0 ] || ok=0
  jq -s -e '
    (length == 1) and
    (.[0].args[0:2] == ["-y", "chrome-devtools-mcp@latest"]) and
    (.[0].args | index("--browserUrl") != null) and
    (.[0].args | index("--viewport") == null)
  ' "$npx_file" >/dev/null 2>&1 || ok=0
  jq -e 'select(.id == 1 and .result.serverInfo.name == "browser-stub")' \
    "$output_file" >/dev/null 2>&1 || ok=0
  jq -e 'select(.id == 2 and (.result.tools | length > 0))' \
    "$output_file" >/dev/null 2>&1 || ok=0
  grep -Fq 'first startup may wait for npm to resolve chrome-devtools-mcp@latest' "$error_file" || ok=0
  grep -Fq 'source=npx fallback' "$error_file" || ok=0
  if [ "$ok" -eq 1 ]; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (status=$status)"
    echo "  Npx: $(cat "$npx_file" 2>/dev/null || true)"
    echo "  Output: $(cat "$output_file")"
    echo "  Error: $(cat "$error_file")"
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
test_closed_stderr_shutdown "closed stderr exits without an EPIPE shutdown spin"
test_oversized_frame_shutdown "an over-limit frame shuts down instead of orphaning the bridge"

# Stub-based Claude one-shot review tests (fast — no real Claude needed).
test_claude_job \
  "Claude background review isolates the leaf CLI and parses fragmented stream-json" \
  "lifecycle" \
  'def arg_after($argv; $flag):
     $argv[(($argv | index($flag)) + 1)];
   (.captures | length == 1) and
   (.captures[0] as $capture |
     ($capture.meta.cwd == "'"$(pwd)"'") and
     ($capture.meta.streaming == true) and
     (arg_after($capture.meta.argv; "--model") == "claude-fable-5-1") and
     (arg_after($capture.meta.argv; "--fallback-model") == "claude-opus-5") and
     (arg_after($capture.meta.argv; "--effort") == "xhigh") and
     (arg_after($capture.meta.argv; "--input-format") == "stream-json") and
     (arg_after($capture.meta.argv; "--output-format") == "stream-json") and
     (arg_after($capture.meta.argv; "--setting-sources") == "project") and
     (arg_after($capture.meta.argv; "--permission-mode") == "plan") and
     (arg_after($capture.meta.argv; "--tools") == "Bash,Glob,Grep,Read") and
     ((arg_after($capture.meta.argv; "--settings") | fromjson) ==
       {"disableAllHooks":true,"disableAgentView":true,"disableArtifact":true}) and
     (arg_after($capture.meta.argv; "--append-system-prompt") |
       (contains("leaf, read-only code reviewer") and
        contains("do not delegate") and
        contains("do not") and
        contains("run tests"))) and
     ($capture.meta.argv | index("--no-session-persistence") != null) and
     ($capture.meta.argv | index("--verbose") != null) and
     ($capture.meta.argv | index("--disable-slash-commands") != null) and
     ($capture.meta.argv | index("--strict-mcp-config") != null) and
     ($capture.meta.argv | index("--include-partial-messages") == null) and
     ($capture.meta.argv | index("--mcp-config") == null) and
     ($capture.meta.argv | index("--dangerously-skip-permissions") == null) and
     ([$capture.stdinParsed[] |
       select(.type == "user" and
         .message == {"role":"user","content":"NORMAL"})] | length == 1)) and
   (.data.starts[0].result.structuredContent |
     (.jobId | type == "string") and
     (.state == "starting") and
     (.cursor == 0) and
     (.resultAvailable == false) and
     (.next.tool == "claude-status")) and
   ([.data.statuses[].result.structuredContent.state] |
     (index("running") != null) and (index("completed") != null)) and
   ([.data.statuses[].result.structuredContent.cursor |
      select(type == "number")] as $cursors |
     ($cursors == ($cursors | sort)) and
     (($cursors | max) >= 3)) and
   (.data.lifecycleTerminal.result.structuredContent |
     (.state == "completed") and
     (.resultAvailable == true) and
     (.next.tool == "claude-result")) and
   (.data.futureCursor.result |
     (.isError == true) and
     (.structuredContent.code == "status_cursor_ahead")) and
   (.data.results[0].result |
     (.isError != true) and
     (.content[0].text == "CLAUDE_REVIEW_OK") and
     (.structuredContent.text == "CLAUDE_REVIEW_OK") and
     (.structuredContent.offset == 0) and
     (.structuredContent.nextOffset == 16) and
     (.structuredContent.endOffset == 16) and
     (.structuredContent.done == true)) and
   (.data.pings[-1].result.content[0].text == "pong") and
   ((.frames | tostring) | contains("SENTINEL_") | not) and
   (.stderr | contains("[mcp-agents] Claude job started")) and
   (.stderr | contains("[mcp-agents] Claude job terminal")) and
   (.stderr | contains("SENTINEL_") | not) and
   (.stderr | contains("NORMAL") | not)'

test_claude_job \
  "legacy claude_code remains blocking and keeps its response shape" \
  "legacy" \
  'def arg_after($argv; $flag):
     $argv[(($argv | index($flag)) + 1)];
   (.captures | length == 1) and
   (.captures[0] as $capture |
     ($capture.meta.streaming == false) and
     ($capture.rawStdin == "LEGACY") and
     (arg_after($capture.meta.argv; "--model") == "claude-fable-5-1") and
     (arg_after($capture.meta.argv; "--fallback-model") == "claude-opus-5") and
     (arg_after($capture.meta.argv; "--effort") == "xhigh") and
     (arg_after($capture.meta.argv; "--output-format") == "json") and
     ($capture.meta.argv | index("--no-session-persistence") != null) and
     ($capture.meta.argv | index("--input-format") == null)) and
   (.data.legacy.result |
     (.isError != true) and
     (.content == [{"type":"text","text":"LEGACY_CLAUDE_OK"}])) and
   (.data.pings[-1].result.content[0].text == "pong")'

test_claude_job \
  "Claude jobs reject relative cwd, caller timeout, and malformed polling locally" \
  "invalid" \
  '(.captures | length == 0) and
   (.data.invalid | length == 4) and
   (.data.invalid | all(
     (.result.isError == true) and
     (.result.structuredContent.code == "invalid_arguments"))) and
   ([.data.invalid[].result.structuredContent.issues[].argument] |
     (index("cwd") != null) and
     (index("timeout_ms") != null) and
     (index("cursor") != null) and
     (index("wait_ms") != null)) and
   (.data.pings[-1].result.content[0].text == "pong")'

test_claude_job \
  "canceling a status waiter leaves its Claude job alive and its sibling completes" \
  "cancel" \
  '([.captures[] |
      select(any(.stdinParsed[];
        .type == "user" and .message.content == "HANG"))] | length == 1) and
   ([.captures[] |
      select(any(.stdinParsed[];
        .type == "user" and .message.content == "HANG"))][0] as $hanging |
     ([$hanging.stdinParsed[] |
       select(.type == "control_request" and
         .request.subtype == "interrupt")] | length == 1) and
     ($hanging.signals | index("CONTROL_INTERRUPT") != null)) and
   ((.data.waiterFrameBeforeJobCancel == null) or
     (.data.waiterFrameBeforeJobCancel.result.structuredContent.state == "running")) and
   (.data.afterWaiterCancel.result.structuredContent |
     (.state == "running") and (.resultAvailable == false)) and
   (.data.hangingTerminal.result.structuredContent.state == "canceled") and
   (.data.hangingPid | type == "number") and
   (.data.hangingAliveAfterTerminal == false) and
   (. as $root |
     .data.secondCancel.result |
       (.isError != true) and
       (.structuredContent.state == "canceled") and
       (.structuredContent.cursor ==
         $root.data.hangingTerminal.result.structuredContent.cursor)) and
   (.data.siblingTerminal.result.structuredContent.state == "completed") and
   ([.data.results[] |
     select(.result.structuredContent.text == "CLAUDE_REVIEW_OK")] | length == 1) and
   (.data.pings[-1].result.content[0].text == "pong")'

test_claude_job \
  "one Claude timeout fails only that job and the server handles a follow-up review" \
  "timeout" \
  '([.captures[] |
      select(any(.stdinParsed[];
        .type == "user" and .message.content == "TIMEOUT"))] | length == 1) and
   ([.captures[] |
      select(any(.stdinParsed[];
        .type == "user" and .message.content == "TIMEOUT"))][0] as $timed |
     ($timed.signals | index("CONTROL_INTERRUPT") != null) and
     ($timed.signals | index("SIGTERM") != null)) and
   (.data.timeoutTerminal.result.structuredContent |
     (.state == "failed") and
     (.message | ascii_downcase | contains("timed out"))) and
   (.data.timeoutPid | type == "number") and
   (.data.timeoutAliveAfterTerminal == false) and
   (.data.followupTerminal.result.structuredContent.state == "completed") and
   ([.data.results[] |
     select(.result.structuredContent.text == "CLAUDE_REVIEW_OK")] | length == 1) and
   (.data.pings[-1].result.content[0].text == "pong")'

test_claude_job \
  "Claude retries one empty terminal result inside the same job and then succeeds" \
  "retry" \
  '(.data.starts | length == 1) and
   (.captures | length == 2) and
   ([.captures[].stdinParsed[] |
     select(.type == "user" and
       .message.content == "EMPTY_THEN_OK")] | length == 2) and
   (.data.retryTerminal.result.structuredContent.jobId ==
     .data.starts[0].result.structuredContent.jobId) and
   (.data.retryTerminal.result.structuredContent.state == "completed") and
   (.data.retryResult.result |
     (.isError != true) and
     (.content[0].text == "CLAUDE_RETRY_OK") and
     (.structuredContent.text == "CLAUDE_RETRY_OK") and
     (.structuredContent.done == true)) and
   ([.data.statuses[].result.structuredContent.message |
     select(contains("retrying after an empty result"))] | length == 1)'

test_claude_job \
  "Claude provider errors become generic failures without leaking provider payloads" \
  "provider-error" \
  '(.captures | length == 1) and
   (.data.providerErrorTerminal.result.structuredContent |
     (.state == "failed") and
     (.message == "Claude: provider returned an error")) and
   (.data.providerErrorResult.result |
     (.isError == true) and
     (.structuredContent.state == "failed") and
     (.structuredContent.resultAvailable == false)) and
   ((.frames | tostring) | contains("SENTINEL_PROVIDER_ERROR") | not) and
   (.stderr | contains("SENTINEL_PROVIDER_ERROR") | not) and
   (.data.pings[-1].result.content[0].text == "pong")'

test_claude_job \
  "Claude status progress uses the supplied token and exposes only sanitized phase text" \
  "progress" \
  '([.frames[] |
      select(.method == "notifications/progress")] as $progress |
     ($progress | length == 2) and
     ($progress[1].params.progress > $progress[0].params.progress) and
     ($progress | all(
       (.params.progressToken == "claude-progress-token") and
       (.params.progress | type == "number") and
       (.params.message | startswith("Claude: ")) and
       (.params.message | contains("SENTINEL") | not)))) and
   (.data.progressStatus.result.structuredContent.state == "running") and
   (.data.progressTerminal.result.structuredContent.state == "canceled")'

test_claude_job \
  "disconnecting with a live Claude job interrupts and reaps its process" \
  "disconnect" \
  '(.captures | length == 1) and
   (.data.disconnectStatus.result.structuredContent.state == "running") and
   (.captures[0] |
     (.alive == false) and
     (.signals | index("CONTROL_INTERRUPT") != null) and
     ([.stdinParsed[] |
       select(.type == "control_request" and
         .request.subtype == "interrupt")] | length == 1))'

test_claude_job \
  "Claude results page by Unicode code point without splitting astral text" \
  "paging" \
  '(.data.pageMetrics ==
     [{"contentCodePoints":32768,
       "structuredCodePoints":32768,
       "equal":true,
       "allRocket":true,
       "offset":0,
       "nextOffset":32768,
       "endOffset":32780,
       "done":false},
      {"contentCodePoints":12,
       "structuredCodePoints":12,
       "equal":true,
       "allRocket":true,
       "offset":32768,
       "nextOffset":32780,
       "endOffset":32780,
       "done":true}])'

test_claude_job \
  "Claude rejects an atomic result over 10 MiB without leaking it through MCP" \
  "oversize" \
  '(.data.oversizeTerminal.result.structuredContent |
     (.state == "failed") and
     (.message | contains("10 MiB"))) and
   (.data.oversizeResult.result |
     (.isError == true) and
     (.structuredContent.state == "failed") and
     (.structuredContent.resultAvailable == false)) and
   ((.frames | tostring | length) < 100000) and
   (.data.pings[-1].result.content[0].text == "pong")'

test_claude_job \
  "Claude terminal jobs expire from connection-local retention" \
  "retention" \
  '(.data.expired.result |
     (.isError == true) and
     (.structuredContent.code == "job_not_found")) and
   (.data.pings[-1].result.content[0].text == "pong")'

test_claude_job \
  "Claude active-job capacity rejects excess work without spawning it" \
  "capacity" \
  '(.captures | length == 2) and
   (.data.capacityRejected.result |
     (.isError == true) and
     (.structuredContent.code == "job_capacity_full") and
     (.structuredContent.activeJobs == 2) and
     (.structuredContent.maxActiveJobs == 2)) and
   ([.data.statuses[].result.structuredContent.state |
     select(. == "canceled")] | length >= 2) and
   (.data.pings[-1].result.content[0].text == "pong")'

test_claude_job \
  "Claude retained-job capacity evicts collected terminal results at the bound" \
  "retained" \
  '(.captures | length == 3) and
   (.data.evicted.result |
     (.isError == true) and
     (.structuredContent.code == "job_not_found")) and
   (.data.stillRetained.result.structuredContent.state == "completed") and
   ([.data.results[].result.structuredContent |
     select(.state == "completed" and .done == true)] | length == 3)'


# App Server adapter contract tests (fast — no real Codex needed).
test_codex_http_case "Codex HTTP rejects invalid project roots before MCP dispatch" \
  "roots"
test_codex_http_case "Codex HTTP pools by canonical root across MCP eras" \
  "pool"
test_codex_http_case "Codex HTTP recreates runtimes after true idle eviction" \
  "eviction"
test_codex_http_case "Codex HTTP evicts a runtime stranded by child death and frees its thread" \
  "uncertain-eviction"
test_codex_http_case "Codex HTTP foreground questions survive their input_required round" \
  "foreground-question"
test_codex_http_case "Codex HTTP retains runtimes while background jobs are active" \
  "active"
test_codex_http_case "Codex HTTP starts idle grace when a background job completes" \
  "post-terminal-grace"
test_codex_http_case "Codex HTTP retains runtimes while foreground requests are active" \
  "active-request"
test_codex_http_case "Codex HTTP shutdown drains an active request and child" \
  "shutdown-active"

test_codex_app_case "Codex discovery is wrapper-owned and never forwarded" \
  "schema" \
  '(.closeInfo.code == 0) and
   ((.data.tools.result.tools | map(.name)) as $names |
     (["codex","codex-reply","codex-start","codex-reply-start",
       "codex-status","codex-commentary","codex-result","codex-cancel",
       "codex-peek","codex-steer","codex-goal-set","codex-goal-get",
       "codex-goal-clear","codex-review","codex-review-start",
       "codex-thread-list","codex-thread-read","codex-thread-fork",
       "codex-thread-archive","codex-thread-unarchive","codex-interactions",
       "codex-interaction-resolve"] - $names | length) == 0) and
   (.data.resources.result.resources == []) and
   (.data.templates.result.resourceTemplates == []) and
   (.data.prompts.result.prompts == []) and
   ([.appRequests[].method |
     select(. == "tools/list" or . == "resources/list" or
            . == "resources/templates/list" or . == "prompts/list")] |
    length == 0)'

test_codex_app_case "Codex discovery stays available when App Server cannot start" \
  "schema-no-app" \
  '(.data.tools.result.tools | map(.name) | index("codex") != null) and
   (.data.resources.result.resources == []) and
   (.data.templates.result.resourceTemplates == []) and
   (.data.prompts.result.prompts == [])'

test_codex_app_case "An unavailable App Server returns a typed result instead of hanging" \
  "unavailable-call" \
  '(.data.call.result.isError == true) and
   (.data.call.result.structuredContent.code == "codex_app_server_unavailable")'

test_codex_app_case "An initialize timeout discards its generation before retry" \
  "init-timeout-first" \
  '(.data.first.result.isError == true) and
   (.data.first.result.structuredContent.code == "codex_app_server_unavailable") and
   (.data.first.result.structuredContent.message |
      contains("can include building its private thread index")) and
   (.data.first.result.structuredContent.message |
      contains("MCP_AGENTS_CODEX_APP_INIT_TIMEOUT_MS")) and
   (.data.first.result.structuredContent.message |
      contains("prune old durable sessions") | not) and
   (.stderr | contains("MCP_AGENTS_CODEX_APP_INIT_TIMEOUT_MS")) and
   (.data.second.result.content[0].text == "APP_SERVER_OK") and
   (.appSpawns | length == 2) and
   ([.appRequests[] | select(.method == "initialize")] | length == 2) and
   ([.appRequests[] | select(.method == "thread/start")] | length == 1)'

test_codex_app_case "An initialize rejection discards its generation before retry" \
  "init-reject-first" \
  '(.data.first.result.isError == true) and
   (.data.first.result.structuredContent.code == "codex_app_server_unavailable") and
   (.data.second.result.content[0].text == "APP_SERVER_OK") and
   (.appSpawns | length == 2) and
   ([.appRequests[] | select(.method == "initialize")] | length == 2) and
   ([.appRequests[] | select(.method == "thread/start")] | length == 1)'

test_codex_app_case "The default init budget exceeds the former 10-second limit" \
  "slow-initialize" \
  '(.data.call.result.content[0].text == "APP_SERVER_OK") and
   (.appSpawns | length == 1) and
   ([.appRequests[] | select(.method == "initialize")] | length == 1) and
   ([.appRequests[] | select(.method == "thread/start")] | length == 1)' \
  "" "25"

test_codex_app_case "An empty init-timeout environment value uses the default" \
  "init-timeout-empty" \
  '(.data.call.result.content[0].text == "APP_SERVER_OK") and
   (.appSpawns | length == 1) and
   ([.appRequests[] | select(.method == "initialize")] | length == 1) and
   (.stderr | contains("invalid MCP_AGENTS_CODEX_APP_INIT_TIMEOUT_MS") | not)'

test_codex_app_case "An invalid init-timeout environment value warns and uses the default" \
  "init-timeout-invalid" \
  '(.data.call.result.content[0].text == "APP_SERVER_OK") and
   (.stderr | contains("invalid MCP_AGENTS_CODEX_APP_INIT_TIMEOUT_MS")) and
   (.stderr | contains("using the 300000ms default"))'

test_codex_app_case "A negative init-timeout environment value warns and uses the default" \
  "init-timeout-negative" \
  '(.data.call.result.content[0].text == "APP_SERVER_OK") and
   (.stderr | contains("invalid MCP_AGENTS_CODEX_APP_INIT_TIMEOUT_MS")) and
   (.stderr | contains("using the 300000ms default"))'

test_codex_app_case "An overflowing init-timeout environment value warns and uses the default" \
  "init-timeout-overflow" \
  '(.data.call.result.content[0].text == "APP_SERVER_OK") and
   (.stderr | contains("invalid MCP_AGENTS_CODEX_APP_INIT_TIMEOUT_MS")) and
   (.stderr | contains("using the 300000ms default"))'

test_codex_app_case "A zero init-timeout environment value keeps the one-millisecond deadline" \
  "init-timeout-zero" \
  '(.data.call.result.isError == true) and
   (.data.call.result.structuredContent.code == "codex_app_server_unavailable") and
   (.data.call.result.structuredContent.message | contains("within 1ms")) and
   (.stderr | contains("invalid MCP_AGENTS_CODEX_APP_INIT_TIMEOUT_MS") | not)'

test_codex_app_case "Codex tools expose closed curated App Server contracts" \
  "schema" \
  '(.data.tools.result.tools | map({key:.name,value:.}) | from_entries) as $t |
   ([$t[] | select(.name | startswith("codex")) |
      .inputSchema.additionalProperties == false] | all) and
   (($t.codex.inputSchema.required | sort) == ["cwd","prompt","sandbox"]) and
   ($t["codex-thread-list"].description | contains("first user message")) and
   (($t["codex-thread-list"].description | contains("empty page")) and
    ($t["codex-thread-list"].description |
      contains("private state database"))) and
   (($t.codex.inputSchema.properties | keys | sort) ==
      ["allow_subagents","cwd","goal","model","model_reasoning_effort","prompt","sandbox"]) and
   (($t["codex-reply"].inputSchema.properties | keys | sort) ==
      ["goal","prompt","threadId"]) and
   (($t["codex-goal-set"].inputSchema.properties.status.enum | sort) ==
      ["active","blocked","budgetLimited","complete","paused","usageLimited"]) and
   (($t["codex-review"].inputSchema.properties.delivery.enum | sort) ==
      ["detached","inline"]) and
   (($t["codex-interaction-resolve"].inputSchema.properties | keys | sort) ==
      ["answers","decision","interactionId"])'

test_codex_app_case "Codex initial calls map to thread/start and turn/start" \
  "normal" \
  '(.data.call.result.isError != true) and
   (.data.call.result.content[0].text == "APP_SERVER_OK") and
   (.data.call.result.structuredContent == {threadId:"thread-1",content:"APP_SERVER_OK"}) and
   ([.frames[] | select(.method == "codex/event")] | length == 0) and
   ([.frames[] | select(
      (((.method // "") | startswith("thread/")) or
       ((.method // "") | startswith("turn/")) or
       ((.method // "") | startswith("item/"))))] |
    length == 0) and
   (.appSpawns[0].argv[0:2] == ["app-server","--stdio"]) and
   ([.appRequests[] | select(.method == "initialize")][0] |
     (.params.clientInfo.name == "mcp-agents") and
     (.params | has("experimentalApi") | not)) and
   ([.appRequests[] | select(.method == "initialized" and (has("id") | not))] |
     length == 1) and
   ([.appRequests[] | select(.method == "thread/start")][0].params |
     (.cwd | endswith("/workspace")) and (.model == "gpt-6-astra") and
     (.sandbox == "read-only")) and
   ([.appRequests[] | select(.method == "turn/start")][0].params |
     (.threadId == "thread-1") and (.effort == "high") and
     (.input == [{type:"text",text:"hello"}]))'

test_codex_app_case "Codex homes link only allowlisted durable project state" \
  "normal" \
  '(.appSpawns[0] |
     (.homeMode == "700") and (.authMode == "600") and
     (.configMode == "600") and (.modelsMode == "600") and
     (.storage.sessions.symlink == true) and
     (.storage.archived.symlink == true) and
     (.storage.writerLocks.symlink == true) and
     (.storage.goals.symlink == true) and
     (.storage.sessions.mode == "700") and
     (.storage.archived.mode == "700") and
     (.storage.writerLocks.mode == "700") and
     (.storage.goals.mode == "600") and
     ([.storage.sessions.target,.storage.archived.target,
       .storage.writerLocks.target,.storage.goals.target] |
       all(contains("/state/mcp-agents/codex/projects/") and
           (contains("/workspace") | not))))'

test_codex_app_case "The isolated child CODEX_HOME stays outside every served workspace" \
  "normal" \
  '(.serverDir as $root |
    .appSpawns[0].codexHome as $home |
    .appSpawns[0].storage.sessions.target as $sessions |
    ([.appRequests[] | select(.method == "thread/start")][0].params.cwd) as $workspace |
    (($home | startswith($root + "/")) | not) and
    (($home | startswith($sessions + "/")) | not) and
    (($home | startswith($workspace + "/")) | not))'

test_codex_app_case "Codex replies resume durable threads before starting turns" \
  "reply" \
  '(.data.reply.result.structuredContent.threadId == "thread-resume") and
   ([.appRequests[] | select(.method == "thread/resume" and
      .params.threadId == "thread-resume")] | length == 1) and
   ([.appRequests[] | select(.method == "turn/start" and
      .params.threadId == "thread-resume" and
      .params.input == [{type:"text",text:"continue"}])] | length == 1)'

test_codex_app_case "An unacknowledged turn start stays outcome-unknown and leased" \
  "turn-start-withheld" \
  '(.data.first.result.isError == true) and
   (.data.first.result.structuredContent.code == "codex_outcome_unknown") and
   (.data.peek.result.structuredContent.turns[0].state == "outcome_unknown") and
   (.data.peek.result.content[0].text |
     contains(", OUTCOME UNKNOWN (not confirmed stopped; may still be writing)") and
     contains("turn(s) have OUTCOME UNKNOWN — NOT confirmed stopped and may still be writing")) and
   (.data.second.result.isError == true) and
   (.data.second.result.structuredContent.code == "codex_thread_busy") and
   ([.appRequests[] | select(.method == "turn/start")] | length == 1) and
   ([.appRequests[] | select(.method == "thread/resume")] | length == 0)'

test_codex_app_case "A delayed turn start is visible as provisional liveness" \
  "turn-start-delayed" \
  '(.data.peek.result.structuredContent.count == 1) and
   (.data.peek.result.structuredContent.turns[0] |
     (.threadId == "thread-1") and (.state == "starting")) and
   ([.data.sidecarsWhileStarting[].turns[] | select(
      .threadId == "thread-1" and .turnId == null and .state == "starting")] |
    length == 1) and
   (.data.call.result.content[0].text == "APP_SERVER_OK")'

test_codex_app_case "A completion racing turn registration is consumed exactly once" \
  "early-complete" \
  '(.data.call.result.content[0].text == "EARLY_OK") and
   (.data.call.result.structuredContent.content == "EARLY_OK") and
   ([.appRequests[] | select(.method == "turn/start")] | length == 1)'

test_codex_app_case "An unmatched early completion expires before turn-id reuse" \
  "early-stale" \
  '(.data.call.result.content[0].text == "APP_SERVER_OK") and
   (.data.call.result | tostring | contains("STALE_EARLY_RESULT") | not)'

test_codex_app_case "Too many unmatched completions fail one generation closed" \
  "early-overflow" \
  '(.data.call.result.isError == true) and
   (.data.call.result.structuredContent.code == "codex_outcome_unknown") and
   (.appSpawns | length == 1) and
   (.stderr | contains("too many unmatched turn completions"))'

test_codex_app_case "MCP cancellation uses direct turn/interrupt and keeps discovery alive" \
  "cancel" \
  '([.appRequests[] | select(.method == "turn/interrupt" and
      .params.threadId == "thread-1" and .params.turnId == "turn-1")] |
   length == 1) and
   (.data.ping.result.content[0].text == "pong")'

test_codex_app_case "Canceled foreground calls settle internally without killing siblings" \
  "cancel-no-native" \
  '(.data.registeredBeforeCancel == true) and
   (.data.canceledWasPending == true) and
   (.data.canceledResponseCount == 0) and
   (.data.cancelElapsedMs >= 200 and .data.cancelElapsedMs < 1000) and
   (.data.sibling.result.content[0].text == "pong") and
   (.data.peek.result.structuredContent.turns[0].state == "canceling") and
   (.data.peek.result.content[0].text |
     contains(", CANCELING (not confirmed stopped)") and
     contains("turn(s) cancelled but NOT confirmed stopped — still writing")) and
   ([.data.sidecarsAfterCancel[].turns[] | select(
      .threadId == "thread-1" and .state == "canceling")] | length == 1) and
   ([.appRequests[] | select(.method == "turn/interrupt")] | length == 1) and
   (.appSpawns | length == 1)'

test_codex_app_case "Cancellation during thread setup clears provisional liveness" \
  "cancel-during-thread-start" \
  '(.data.canceledWasPending == true) and
   (.data.canceledResponseCount == 0) and
   (.data.cancelElapsedMs >= 200 and .data.cancelElapsedMs < 1000) and
   (.data.sibling.result.content[0].text == "pong") and
   ([.data.sidecarsAfterCancel[].turns[] | select(.state == "starting")] | length == 0) and
   ([.appRequests[] | select(.method == "thread/start")] | length == 1) and
   ([.appRequests[] | select(.method == "turn/start")] | length == 0) and
   ([.appRequests[] | select(.method == "turn/interrupt")] | length == 0) and
   (.appSpawns | length == 1)'

test_codex_app_case "Idle timeout interrupts one turn without tearing down App Server" \
  "idle" \
  '(.data.call.result.isError == true) and
   ([.appRequests[] | select(.method == "turn/interrupt")] | length == 1) and
   (.appSpawns | length == 1) and
   (.data.ping.result.content[0].text == "pong")' \
  "--codex_idle_timeout 0.1"

test_codex_app_case "Native goal tools preserve objective, status, budget, and usage" \
  "goals" \
  '([.appRequests[] | select(.method == "thread/goal/set")][0].params ==
      {threadId:"thread-goal",objective:"ship",status:"active",tokenBudget:500}) and
   ([.appRequests[] | select(.method == "thread/goal/get")] | length == 1) and
   ([.appRequests[] | select(.method == "thread/goal/clear")] | length == 1) and
   (.data.set.result.structuredContent.goal.tokensUsed == 12) and
   (.data.get.result.structuredContent.goal.tokenBudget == 500)'

test_codex_app_case "Initial goals become native state before their first turn" \
  "goal-call" \
  '([.appRequests[].method] | index("thread/start")) as $thread |
   ([.appRequests[].method] | index("thread/goal/set")) as $goal |
   ([.appRequests[].method] | index("turn/start")) as $turn |
   ($thread < $goal and $goal < $turn) and
   ([.appRequests[] | select(.method == "thread/goal/set")][0].params |
      (.threadId == "thread-1") and (.objective == "ship safely")) and
   ([.appRequests[] | select(.method == "thread/start")][0].params.config |
      (.features.multi_agent == true) and (.agents.enabled == true)) and
   (.appRequests | tostring | contains("allow_subagents") | not)'

test_codex_app_case "A server goal works on a newer Codex version" \
  "goal-default-newer" \
  '(.data.call.result.isError != true) and
   (.appSpawns[0].storage.goals.symlink == true) and
   ([.appRequests[] | select(.method == "thread/start")] | length == 1) and
   ([.appRequests[] | select(.method == "thread/goal/set")] | length == 1) and
   ([.appRequests[] | select(.method == "turn/start")] | length == 1)' \
  "--goal DEFAULT"

test_codex_app_case "Steering targets the wrapper-tracked active turn" \
  "steer" \
  '([.appRequests[] | select(.method == "turn/steer")][0].params |
      (.threadId == "thread-1") and (.expectedTurnId == "turn-1") and
      (.input == [{type:"text",text:"new direction"}])) and
   (.data.steer.result.isError != true)'

test_codex_app_case "Codex peek preserves liveness identity without prompt leakage" \
  "peek" \
  '(.data.peek.result.structuredContent.count == 1) and
   (.data.peek.result.structuredContent.turns[0] |
      (.tool == "codex") and (.threadId == "thread-1") and
      (.cwd | endswith("/workspace")) and (.cwdInferred == false) and
      (has("jobId")) and
      (has("requestId") | not)) and
   (.data.peek.result | tostring | contains("PRIVATE_PEEK_PROMPT") | not) and
   ([.appRequests[] | select(.method == "turn/interrupt")] | length == 1)'

test_codex_app_case "An empty Codex peek preserves its non-termination warning" \
  "peek-empty" \
  '(.appSpawns == []) and
   (.data.peek.result.structuredContent.count == 0) and
   (.data.peek.result.content[0].text ==
     "No Codex turn is in flight. This is not evidence one finished — an abandoned turn keeps running with nothing left to report.") and
   (.data.filtered.result.content[0].text ==
     "No matching Codex turn is in flight. This is not evidence one finished — an abandoned turn keeps running with nothing left to report.")'

test_codex_app_case "Codex peek marks a reply workspace as inherited" \
  "peek-reply" \
  '(.data.initial.result.content[0].text == "APP_SERVER_OK") and
   (.data.peek.result.structuredContent.turns[0] |
     (.tool == "codex-reply") and (.threadId == "thread-1") and
     (.cwd | endswith("/workspace")) and (.cwdInferred == true)) and
   (.data.peek.result.content[0].text | contains("(inherited)")) and
   ([.appRequests[] | select(.method == "turn/interrupt")] | length == 1)'

test_codex_app_case "Codex jobs preserve pre-App-Server polling metadata" \
  "job-compat" \
  '(.data.caughtUp.result.structuredContent.state == "running") and
   (.data.defaultWait.result.structuredContent.state == "running") and
   (.data.defaultWaitElapsedMs >= 300 and .data.defaultWaitElapsedMs < 1500) and
   (.data.pendingResult.result.structuredContent as $pending |
     ($pending.resultAvailable == false) and
     ($pending.next.tool == "codex-status") and
     ($pending.next.arguments.jobId == .data.started.result.structuredContent.jobId) and
     ($pending.next.arguments.cursor == .data.defaultWait.result.structuredContent.cursor)) and
   (.data.capacity.result |
     (.isError == true) and
     (.structuredContent.code == "capacity_exceeded") and
     (.structuredContent.activeJobs == 1) and
     (.structuredContent.retainedJobs == 1) and
     (.structuredContent.maxActiveJobs == 1) and
     (.structuredContent.maxRetainedJobs == 2))' \
  "--codex_status_interval 0.5"

test_codex_app_case "Codex jobs preserve status, commentary, and result contracts" \
  "job" \
  '(.data.started.result.structuredContent.jobId | type == "string") and
   (.data.started.result | tostring | contains("app/") | not) and
   (.data.status.result.structuredContent.state == "completed") and
   (.data.result.result.structuredContent.state == "completed") and
   (.data.result.result.structuredContent.text == "APP_SERVER_OK") and
   (.data.result.result.content[0].text == "APP_SERVER_OK")'

test_codex_app_case "A second writer cannot start on an active Codex thread" \
  "busy" \
  '(.data.reply.result.isError == true) and
   (.data.reply.result.structuredContent.code == "codex_thread_busy") and
   ([.appRequests[] | select(.method == "turn/start")] | length == 1)'

test_codex_app_case "Review tools use the stable native target union" \
  "review" \
  '([.appRequests[] | select(.method == "review/start")][0].params ==
      {threadId:"thread-review",target:{type:"baseBranch",branch:"main"},delivery:"inline"}) and
   (.data.review.result.content[0].text == "REVIEW_OK")'

test_codex_app_case "Exited review-mode items become the public review result" \
  "review-exited" \
  '(.data.review.result.isError != true) and
   (.data.review.result.content[0].text == "REVIEW_FROM_EXITED_MODE") and
   (.data.review.result.structuredContent.content == "REVIEW_FROM_EXITED_MODE")'

test_codex_app_case "Detached review threads retain an exclusive writer lease" \
  "detached-review" \
  '(.data.started.result.isError != true) and
   (.data.reply.result.isError == true) and
   (.data.reply.result.structuredContent.code == "codex_thread_busy") and
   ([.appRequests[] | select(.method == "review/start")][0].params.delivery == "detached") and
   ([.appRequests[] | select(.method == "thread/resume" and
      .params.threadId == "thread-review-detached")] | length == 0) and
   ([.appRequests[] | select(.method == "turn/interrupt" and
      .params.threadId == "thread-review-detached")] | length == 1)'

test_codex_app_case "Thread tools map to stable history and lifecycle methods" \
  "threads" \
  '([.appRequests[] | select(.method == "thread/list")][0].params |
      (.cwd | endswith("/workspace")) and (.limit == 10) and
      (.archived == false) and (.useStateDbOnly == true) and
      (.sourceKinds == ["vscode","appServer","subAgentReview"])) and
   (.data.list.result.structuredContent.threads[0].id == "thread-listed") and
   (.data.list.result.structuredContent.threads[0].preview == "stub preview") and
   ([.appRequests[] | select(.method == "thread/read")][0].params.includeTurns == true) and
   ([.appRequests[] | select(.method == "thread/fork")][0].params.lastTurnId == "turn-read") and
   ([.appRequests[].method | select(. == "thread/archive")] | length == 1) and
   ([.appRequests[].method | select(. == "thread/unarchive")] | length == 1) and
   (.data.read.result.structuredContent | tostring | contains("READ_OK")) and
   (.data.read.result.structuredContent | tostring | contains("reasoning") | not) and
   (.data.read.result.structuredContent | tostring | contains("SECRET_REASONING") | not)'

test_codex_app_case "An unacknowledged archive remains outcome-unknown and leased" \
  "archive-withheld" \
  '(.data.first.result.isError == true) and
   (.data.first.result.structuredContent.code == "codex_outcome_unknown") and
   (.data.second.result.isError == true) and
   (.data.second.result.structuredContent.code == "codex_thread_busy") and
   ([.appRequests[] | select(.method == "thread/archive")] | length == 1) and
   ([.appRequests[] | select(.method == "thread/unarchive")] | length == 0)'

test_codex_app_case "Prompting policies reject blocking calls without elicitation" \
  "approval-no-elicit" \
  '(.data.result.result.isError == true) and
   (.data.result.result.structuredContent.code == "codex_interaction_requires_background") and
   ([.appRequests[] | select(.method == "thread/start")] | length == 0)' \
  "--approval_policy on-request"

test_codex_app_case "Command approvals round-trip through MCP elicitation" \
  "approval" \
  '([.frames[] | select(.method == "elicitation/create")] | length == 1) and
   ([.appRequests[] | select(.id == "approval-1")][0].result.decision == "accept") and
   (.data.result.result.content[0].text == "INTERACTION_OK")' \
  "--approval_policy on-request"

test_codex_modern_interaction_case \
  "Modern structured input resumes one native turn through input_required" \
  "question" \
  '(.elicitationCount == 1) and
   (.inputRequiredFrames | length == 1) and
   ([.appRequests[] | select(.method == "thread/start")] | length == 1) and
   ([.appRequests[] | select(.method == "turn/start")] | length == 1) and
   ([.appRequests[] | select(.method == "thread/resume")] | length == 0) and
   ([.appRequests[] | select(.id == "question-1")][0].result.answers.choice.answers == ["Ship"]) and
   (.result.content[0].text == "INTERACTION_OK") and
   (([.serverFrames, .clientFrames] | tostring) | contains("question-1") | not) and
   (.decodedRequestStates | length == 1) and
   ([.decodedRequestStates[]?.p | keys] == [["bridgeSessionId","callHash","interactionId","toolName","turnId","v"]]) and
   ((.decodedRequestStates | tostring) |
     test("PRIVATE_MODERN_PROMPT|Pick one|Ship|INTERACTION_OK|dangerous"; "i") | not) and
   (.unkeyedCallHash | test("^[0-9a-f]{64}$")) and
   (.decodedRequestStates[0].p.callHash | test("^[0-9a-f]{64}$")) and
   (.decodedRequestStates[0].p.callHash != .unkeyedCallHash)'

test_codex_modern_interaction_case \
  "Modern foreground input without elicitation fails closed without replay" \
  "question-no-elicit" \
  '(.elicitationCount == 0) and
   (.inputRequiredFrames | length == 0) and
   (.result.isError == true) and
   (.result.structuredContent.code == "codex_interaction_requires_background") and
   ([.appRequests[] | select(.method == "thread/start")] | length == 1) and
   ([.appRequests[] | select(.method == "turn/start")] | length == 1) and
   ([.appRequests[] | select(.method == "thread/resume")] | length == 0) and
   ([.appRequests[] | select(.method == "turn/interrupt")] | length == 1)'

test_codex_app_case "Structured questions round-trip without leaking native ids" \
  "question" \
  '([.frames[] | select(.method == "elicitation/create")] | length == 1) and
   ([.appRequests[] | select(.id == "question-1")][0].result.answers.choice.answers == ["Ship"]) and
   (.data.result.result.content[0].text == "INTERACTION_OK") and
   (.frames | tostring | contains("question-1") | not)' \
  "--approval_policy on-request"

test_codex_app_case "Secret App Server questions fail closed without storage or disclosure" \
  "secret-question" \
  '(.data.result.result.isError == true) and
   (.data.result.result.structuredContent.code == "codex_secret_input_unsupported") and
   (.frames | tostring | contains("SENSITIVE_SECRET_PROMPT") | not) and
   ([.appRequests[] | select(.method == "turn/interrupt")] | length == 1)' \
  "--approval_policy on-request"

test_codex_app_case "Permission requests fail typed with the native empty permission set" \
  "permission" \
  '(.data.result.result.isError == true) and
   (.data.result.result.structuredContent.code == "codex_permissions_unsupported") and
   ([.appRequests[] | select(.id == "permission-1")][0].result == {permissions:{}}) and
   ([.appRequests[] | select(.method == "turn/interrupt")] | length == 1)'

test_codex_app_case "Foreground user input without elicitation fails immediately" \
  "question-no-elicit" \
  '(.data.result.result.isError == true) and
   (.data.result.result.structuredContent.code == "codex_interaction_requires_background") and
   (.data.elapsedMs < 750) and
   ([.frames[] | select(.method == "elicitation/create")] | length == 0) and
   ([.appRequests[] | select(.id == "question-1")][0].result == {answers:{}}) and
   ([.appRequests[] | select(.method == "turn/interrupt")] | length == 1)'

test_codex_app_case "Interaction expiry is capped by the turn hard deadline" \
  "interaction-timeout" \
  '(.data.result.result.isError == true) and
   ((.data.result.result.structuredContent.code == "codex_interaction_timeout") or
    (.data.result.result.content[0].text |
      contains("Fulfilling input required by '\''tools/call'\'' failed: Request timed out"))) and
   (.data.elapsedMs >= 100 and .data.elapsedMs < 1000) and
   ([.frames[] | select(.method == "elicitation/create")] | length == 1) and
   ([.appRequests[] | select(.id == "question-1")][0].result == {answers:{}}) and
   ([.appRequests[] | select(.method == "turn/interrupt")] | length == 1)' \
  "--timeout 0.25"

test_codex_app_case "Background approvals remain resolvable through the queue" \
  "queued-interaction" \
  '(.data.started.result.structuredContent.jobId | type == "string") and
   (.data.interactions.result.structuredContent.interactions | length == 1) and
   (.data.resolved.result.isError != true) and
   ([.appRequests[] | select(.id == "approval-1")][0].result.decision == "accept") and
   (.data.status.result.structuredContent.state == "completed") and
   (.frames | tostring | contains("approval-1") | not)' \
  "--approval_policy on-request"

test_codex_app_case "A deferred foreground question never strands its turn rejection" \
  "deferred-question-die" \
  '(.data.result.error.code == -32602) and
   (.data.result.error.data.reason == "invalid_foreground_interaction_state") and
   (.data.ping.result.content[0].text == "pong") and
   ([.frames[] | select(.method == "elicitation/create")] | length == 1) and
   (.stderr | contains("UnhandledRejection") | not) and
   (.stderr | contains("(stdin-end)"))' \
  "--approval_policy on-request"

test_codex_app_case "Foreground interactions stay out of the background queue" \
  "foreground-interaction-hidden" \
  '([.frames[] | select(.method == "elicitation/create")] | length == 1) and
   (.data.duringRound.result.structuredContent.count == 0) and
   (.data.duringRound.result.structuredContent.interactions == []) and
   (.data.duringRound.result.content[0].text == "No pending Codex interactions.") and
   (.data.result.result.content[0].text == "INTERACTION_OK")' \
  "--approval_policy on-request"

test_codex_app_case "Child death fails one generation and never replays its turn" \
  "die-first" \
  '(.appSpawns | length == 2) and
   (.appSpawns[0].codexHome != .appSpawns[1].codexHome) and
   (.appSpawns[0].storage.sessions.target == .appSpawns[1].storage.sessions.target) and
   (.appSpawns[0].storage.archived.target == .appSpawns[1].storage.archived.target) and
   (.appSpawns[0].storage.writerLocks.target == .appSpawns[1].storage.writerLocks.target) and
   (.appSpawns[0].storage.goals.target == .appSpawns[1].storage.goals.target) and
   (.data.first.result.isError == true) and
   (.data.first.result.structuredContent.code == "codex_outcome_unknown") and
   (.data.second.result.content[0].text == "APP_SERVER_OK") and
   ([.appRequests[] | select(.method == "turn/start") |
      .params.input[0].text] == ["FIRST_MUST_NOT_REPLAY","SECOND_OK"])'

test_codex_app_case "Generation teardown discards unregistered completion state" \
  "early-die-first" \
  '(.appSpawns | length == 2) and
   (.data.first.result.isError == true) and
   (.data.first.result.structuredContent.code == "codex_outcome_unknown") and
   (.data.second.result.content[0].text == "APP_SERVER_OK") and
   (.data.second.result | tostring | contains("STALE_DEAD_RESULT") | not)'

test_codex_app_bridge_restart \
  "Durable sessions resume across fresh bridge processes"
test_codex_app_cross_bridge_busy \
  "Shared leases reject a concurrent writer from another bridge"
test_codex_app_stale_lease_race \
  "Simultaneous stale-lease takeover elects exactly one writer"

test_codex_app_case "Retention clears goals on a newer Codex version" \
  "retention-newer" \
  '(.appSpawns[0].storage.goals.symlink == true) and
   ([.appRequests[] |
      select(.method == "thread/list" and .params.limit == 100) |
      .params | {archived,useStateDbOnly,sourceKinds}] == [
        {archived:false,useStateDbOnly:false,
         sourceKinds:["appServer","subAgentReview"]},
        {archived:true,useStateDbOnly:false,
         sourceKinds:["appServer","subAgentReview"]}
      ]) and
   ([.appRequests[] | select(.method == "thread/delete" and
      .params.threadId == "thread-expired")] | length == 1) and
   ([.appRequests[] | select(.method == "thread/delete" and
      .params.threadId == "thread-archived-expired")] | length == 1) and
   ([.appRequests[] | select(.method == "thread/delete" and
      .params.threadId == "thread-fresh")] | length == 0) and
   ([.appRequests[] | select(.method == "thread/delete" and
      .params.threadId == "thread-vscode-expired")] | length == 0) and
   ([.appRequests[] | select(.method == "thread/goal/clear" and
      .params.threadId == "thread-expired")] | length == 1) and
   ([.appRequests[] | select(.method == "thread/goal/clear" and
      .params.threadId == "thread-archived-expired")] | length == 1) and
   ([.appRequests[] | select(
      (.method == "thread/goal/clear" or .method == "thread/delete") and
      .params.threadId == "thread-archived-expired") | .method] ==
      ["thread/goal/clear","thread/delete"]) and
   ([.appRequests[] | select(.method == "thread/goal/clear" and
      .params.threadId == "thread-vscode-expired")] | length == 0)' \
  "--codex-session-retention-days 1"

test_codex_app_case "Retention journal recovery clears a native missing thread" \
  "retention-journal" \
  '(.data.journalExists == false) and
   ([.appRequests[] | select(.method == "thread/delete" and
      .params.threadId == "thread-missing")] | length == 1) and
   ([.appRequests[] | select(.method == "thread/goal/clear" and
      .params.threadId == "thread-missing")] | length == 1)' \
  "--codex-session-retention-days 1"

test_codex_app_case "Structured unauthorized events latch future Codex turns" \
  "auth" \
  '(.data.first.result.isError == true) and
   (.data.first.result.structuredContent.code == "codex_auth_invalidated") and
   (.data.second.result.isError == true) and
   (.data.second.result.structuredContent.code == "codex_auth_invalidated") and
   ([.appRequests[] | select(.method == "turn/start")] | length == 1) and
   (.frames | tostring | contains("SECRET") | not) and
   ([.frames[] | select(.method == "codex/event")] | length == 0)'

test_codex_app_case "Split App Server frames reassemble without raw event forwarding" \
  "split" \
  '(.data.call.result.content[0].text == "APP_SERVER_OK") and
   ([.frames[] | select(.method == "codex/event")] | length == 0)'

test_codex_app_case "Completed agent items are authoritative over streamed deltas" \
  "delta-diff" \
  '(.data.call.result.content[0].text == "APP_SERVER_OK") and
   (.data.call.result.structuredContent.content == "APP_SERVER_OK") and
   (.data.call.result | tostring | contains("COMMENTARY_ONLY") | not)'

test_codex_app_case "Bounded diagnostic noise is quarantined to stderr" \
  "noise" \
  '(.data.call.result.content[0].text == "APP_SERVER_OK") and
   (.rawLines | map(contains("codex diagnostic")) | any | not) and
   (.stderr | contains("codex diagnostic"))'

test_codex_app_case "Malformed App Server JSON fails the generation closed" \
  "malformed" \
  '(.data.call.result.isError == true) and
   (.data.call.result.structuredContent.code == "codex_outcome_unknown")'

test_codex_app_case "A complete oversized App Server frame fails its generation typed" \
  "oversized-complete" \
  '(.data.call.result.isError == true) and
   (.data.call.result.structuredContent.code == "codex_outcome_unknown") and
   (.frames | tostring | contains("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx") | not) and
   ((.frames | tostring | length) < 100000)'

test_codex_app_case "Closed schemas reject invalid calls before App Server work" \
  "invalid" \
  '(.data.invalid.error.code == -32602) and
   (.data.badGoal.error.code == -32602) and
   (.data.badResolve.error.code == -32602) and
   ([.appRequests[] | select(.method == "thread/start" or
      .method == "thread/goal/set")] | length == 0)'

# Browser resolver and passthrough process-boundary tests. The npx resolver and
# all remaining browser cases use PID-registering downstream/helper stubs, so
# they run anywhere. The FIRST case is different: it starts the REAL
# package-local chrome-devtools-mcp, whose own engines floor rises as the
# unpinned dependency tracks latest. mcp-agents now requires `>=26` so this
# normally passes; the gate stays as a guard for anyone running the suite on an
# older node than the package supports.
browser_local_node_ok=1
if ! node -e '
  const [maj, min] = process.versions.node.split(".").map(Number);
  process.exit(maj > 20 || (maj === 20 && min >= 19) ? 0 : 1);
' 2>/dev/null; then
  browser_local_node_ok=0
fi
if [ "$browser_local_node_ok" -eq 1 ]; then
  test_browser_local_resolution \
    "browser defaults to the package-local downstream without npx"
else
  echo "(Skipping package-local browser resolver test — node $(node -p 'process.versions.node') is below the chrome-devtools-mcp engines floor)"
fi
test_browser_npx_resolution \
  "published browser install invokes the unpinned npx fallback"
test_browser_case "browser startup, argv, lazy acquire, warnings, and shutdown release" \
  "normal" "normal" "ready" "10" "3" \
  'def arg_after($argv; $flag): $argv[(($argv | index($flag)) + 1)];
   (.driverError == null) and (.spawns | length == 1) and
   (.leaseCalls | map(.args[0]) == ["acquire","release"]) and
   (.spawns[0].at <= .leaseCalls[0].at) and
   (.spawns[0] as $spawn | .leaseCalls[0] as $acquire |
     (arg_after($spawn.argv; "--browserUrl") |
       startswith("http://127.0.0.1:")) and
     (arg_after($spawn.argv; "--browserUrl") ==
       ("http://127.0.0.1:" + arg_after($acquire.args; "--local-cdp-port"))) and
     ($spawn.argv | index("--viewport") == null) and
     (arg_after($spawn.argv; "--logFile") | endswith("/browser.log")) and
     ([range(0; $spawn.argv|length) as $i |
       select($spawn.argv[$i] == "--allowedUrlPattern") |
       $spawn.argv[$i+1]] == ["http://127.0.0.1/*","https://example.test/*"]) and
     ($spawn.argv | index("--no-usage-statistics") != null) and
     ($spawn.argv | index("--allowUnrestrictedPaths") == null) and
     ($spawn.argv | index("--allow-unrestricted-paths") == null) and
     ($spawn.argv | index("--headless") == null) and
     ($spawn.argv | index("--isolated") == null) and
     (arg_after($acquire.args; "--app-port") == "5100") and
     (arg_after($acquire.args; "--viewport") == "1280x720") and
     ($spawn.stdin[0].params.capabilities.roots.listChanged == true) and
     ($spawn.stdinRaw | startswith("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{\"roots\":{\"listChanged\":true},\"sampling\":{}},\"clientInfo\":{\"name\":\"browser-driver\",\"version\":\"0\"}}}\n"))) and
   ([.frames[] | select(.id == 2) | .result.tools] | length == 1) and
   ([.frames[] | select(.id == 2) | .result.tools[] |
      select(.name == "performance_start_trace" or
             .name == "performance_stop_trace" or
             .name == "performance_analyze_insight" or
             .name == "lighthouse_audit") |
      (.description | contains("never as a gate"))] | all) and
   ([.frames[] | select(.id == 2) | .result.tools[] |
      select(.name == "upload_file") |
      ((.description | contains("unsupported")) and
       (.inputSchema.properties.filePath.type == "string"))] | all) and
   ([.frames[] | select(.id == 2) | .result.tools[] |
      select(.name == "navigate_page") |
      (.title == "Navigate title" and .annotations.readOnlyHint == false and
       .inputSchema.properties.url.type == "string")] | all) and
   ([.frames[] | select(.id == 2) | .result.tools[].name] | sort) ==
     ["lighthouse_audit","navigate_page","performance_analyze_insight","performance_start_trace","performance_stop_trace","upload_file"] and
   ([.frames[] | select(.id == 3 and .result.structuredContent.content == "BROWSER_OK_3")] | length == 1) and
   ([.stderr | scan("session_id=[0-9a-f-]{36}")] | length == 1) and
   (.leaseCalls[-1].args | index("shutdown") != null)'

test_browser_case "browser split tools/list frame is reassembled and rewritten" \
  "split" "split" "ready" "10" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 2) | .result.tools[].name] | sort) ==
     ["lighthouse_audit","navigate_page","performance_analyze_insight","performance_start_trace","performance_stop_trace","upload_file"] and
   ([.frames[] | select(.id == 2) | .result.tools[] |
     select(.name == "upload_file") |
     (.description | contains("unsupported"))] | all)'
test_browser_case "browser interleaved frame stays byte-identical during rewrite" \
  "interleaved" "interleaved" "ready" "10" "3" \
  '(.driverError == null) and
   (.rawLines | index("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{\"marker\":\"BROWSER_INTERLEAVED\"}}") != null) and
   ([.frames[] | select(.id == 2) | .result.tools[].name] | sort) ==
     ["lighthouse_audit","navigate_page","performance_analyze_insight","performance_start_trace","performance_stop_trace","upload_file"] and
   ([.frames[] | select(.id == 2) | .result.tools[] |
     select(.name == "lighthouse_audit") |
     (.description | contains("never as a gate"))] | all)'
test_browser_case "browser mode-boundary straddle forwards the orphan frame intact" \
  "straddle" "straddle" "ready" "10" "3" \
  '(.driverError == null) and
   (.rawLines | index("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{\"marker\":\"STRADDLE\"}}") != null) and
   ([.frames[] | select(.id == 2 and .result.tools)] | length == 1)'
test_browser_case "browser partial tools/list then child death yields one error" \
  "partialdie" "partialdie" "ready" "10" "3" \
  '([.frames[] | select(.id == 2 and .error.code == -32001)] | length == 1) and
   ([.frames[] | select(.id == 2 and has("result"))] | length == 0)'
test_browser_case "browser complete unterminated tools/list is recovered on exit" \
  "nonewlinedie" "nonewlinedie" "ready" "10" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 2) | .result.tools[].name] | sort) ==
     ["lighthouse_audit","navigate_page","performance_analyze_insight","performance_start_trace","performance_stop_trace","upload_file"] and
   ([.frames[] | select(.id == 2) | .result.tools[] |
     select(.name == "performance_start_trace") |
     (.description | contains("never as a gate"))] | all)'
test_browser_case "browser oversized frame forwards raw and following list rewrites" \
  "oversized" "oversized" "ready" "10" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.params.marker == "BROWSER_OVERSIZED")] | length == 1) and
   ([.frames[] | select(.id == 2) | .result.tools[].name] | sort) ==
     ["lighthouse_audit","navigate_page","performance_analyze_insight","performance_start_trace","performance_stop_trace","upload_file"] and
   ([.frames[] | select(.id == 2) | .result.tools[] |
     select(.name == "upload_file") |
     (.description | contains("unsupported"))] | all)'
test_browser_case "browser tools/list survives client stdout backpressure" \
  "bp" "bp" "ready" "10" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.params.marker == "BROWSER_BP")] | length == 1) and
   ([.frames[] | select(.id == 2 and .result.tools)] | length == 1)'

test_browser_case "browser roots/list round-trip preserves the exact client answer" \
  "roots" "roots" "ready" "10" "3" \
  '(.driverError == null) and
   (.rootsResponse == "{\"jsonrpc\":\"2.0\", \"id\":\"roots-1\", \"result\":{\"roots\":[{\"uri\":\"file:///workspace\",\"name\":\"root\"}]}}") and
   ([.frames[] | select(.id == "roots-1" and .method == "roots/list")] | length == 1) and
   (.leaseCalls | length == 0)'
test_browser_case "browser initialize is tracked and hard-bounded" \
  "hang-init" "hang-init" "ready" "10" "0.18" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 1 and .error.code == -32001)] | length == 1)'
test_browser_case "unplanned browser downstream death fails the open call" \
  "die" "die" "ready" "10" "3" \
  '([.frames[] | select(.id == 3 and .result.isError == true and
     .result.structuredContent.code == "browser_lease_replaced" and
     .result.structuredContent.outcomeUnknown == true)] | length == 1)'

test_browser_case "concurrent cold calls share one acquire, preserve FIFO, and cancel held work" \
  "slow-ready" "normal" "slow-ready" "10" "3" \
   '(.driverError == null) and
   ([.leaseCalls[] | select(.args[0] == "acquire")] | length == 1) and
   (.spawns[0].stdin | map(select(.method == "tools/call") | .id) == [3,4,6]) and
   ([.frames[] | select(.id == 5)] | length == 0) and
   ([.frames[] | select(.method == "notifications/progress") |
      .params.progressToken] | unique | sort) == [42,"browser-progress"] and
   ([.frames[] | select(.method == "notifications/progress" and
      (.params.progressToken | type == "object"))] | length == 0)'
test_browser_case "advertised tool ownership avoids leasing for unknown tools" \
  "unknown" "normal" "ready" "10" "3" \
  '(.driverError == null) and
   ([.leaseCalls[] | select(.args[0] == "acquire")] | length == 0) and
   ([.spawns[0].stdin[] | select(.method == "tools/call" and
      .params.name == "not_advertised")] | length == 1)'
test_browser_case "browser calls conservatively acquire when tools/list was skipped" \
  "skip-list" "normal" "ready" "10" "3" \
  '(.driverError == null) and
   ([.leaseCalls[] | select(.args[0] == "acquire")] | length == 1) and
   ([.spawns[0].stdin[] | select(.method == "tools/call" and .id == 3)] | length == 1)'
test_browser_case "browser acquire exit 69 fails closed with no-box context" \
  "unavailable" "normal" "unavailable-69" "10" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 3 and .result.isError == true and
     .result.structuredContent.code == "browser_unavailable" and
     (.result.content[0].text | contains("GUI not verified — no browser box available")) and
     (.result.content[0].text | contains("Lease helper: no capacity")))] | length == 1) and
   (.stderr | contains("browser lease unavailable: no capacity")) and
   ([.spawns[0].stdin[] | select(.method == "tools/call")] | length == 0)'
test_browser_case "browser dev-server preflight error is surfaced verbatim" \
  "dev-unreachable" "normal" "dev-unreachable-69" "10" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 3 and
     .result.structuredContent.code == "browser_dev_server_unreachable" and
     .result.content[0].text == "GUI not verified — dev server not reachable at :5100")] | length == 1)'
test_browser_case "browser MinIO preflight error stays distinct and verbatim" \
  "minio-unreachable" "normal" "minio-unreachable-69" "10" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 3 and
     .result.structuredContent.code == "browser_minio_unreachable" and
     .result.content[0].text == "GUI not verified — MinIO not reachable at :9000")] | length == 1)'
test_browser_case "browser empty acquire diagnostics fall back to the exit code" \
  "acquire-empty" "normal" "acquire-empty-70" "10" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 3 and
     .result.structuredContent.code == "browser_provisioning_failed" and
     (.result.content[0].text | contains("lease helper exited with code 70")))] | length == 1)'

test_browser_case "browser exit-75 restart replays roots into the new downstream only" \
  "port-once" "normal" "port-75-once" "10" "3" \
  'def arg_after($argv; $flag): $argv[(($argv | index($flag)) + 1)];
   (.driverError == null) and (.spawns | length == 2) and
   ([.leaseCalls[] | select(.args[0] == "acquire")] | length == 2) and
   (arg_after(.spawns[0].argv; "--browserUrl") != arg_after(.spawns[1].argv; "--browserUrl")) and
   (.spawns[1].stdin[0].id as $internalId |
     ($internalId | startswith("mcp-agents/browser/initialize/")) and
     (.spawns[1].stdinRaw | startswith(
       ("{\"jsonrpc\":\"2.0\",\"id\":" + ($internalId | tojson) +
        ",\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{\"roots\":{\"listChanged\":true},\"sampling\":{}},\"clientInfo\":{\"name\":\"browser-driver\",\"version\":\"0\"}}}\n")))) and
   ([.spawns[1].stdin[] | select(.method == "notifications/initialized")] | length == 1) and
   ([.frames[] | select(.id == 1 and has("result"))] | length == 1) and
   ([.frames[] | select((.id | type) == "string" and
      (.id | startswith("mcp-agents/browser/initialize/")))] | length == 0) and
   ([.frames[] | select(.id == 3 and .result.structuredContent.content == "BROWSER_OK_3")] | length == 1)'
test_browser_case "browser restart drops dead roots and round-trips replacement roots" \
  "restart-roots" "restart-roots" "port-75-once" "10" "3" \
  '(.driverError == null) and (.spawns | length == 2) and
   ([.frames[] | select(.id == "roots-reused" and .method == "roots/list")] | length == 2) and
   (.rootsResponses == [{
      "pid": .spawns[1].pid,
      "spawnOrdinal": 2,
      "raw": "{\"jsonrpc\":\"2.0\", \"id\":\"roots-reused\", \"result\":{\"roots\":[{\"uri\":\"file:///workspace\",\"name\":\"replacement-root\"}]}}"
    }]) and
   ([.spawns[0].stdin[] | select(.id == "roots-reused" and has("result"))] | length == 0) and
   ([.spawns[1].stdin[] | select(.id == "roots-reused" and has("result"))] | length == 1) and
   (.spawns[1].stdinRaw | contains("dead-root") | not) and
   ([.frames[] | select(.id == 3 and .result.structuredContent.content == "BROWSER_OK_3")] | length == 1)'
test_browser_case "browser restart correlates roots by generation when replacement answers first" \
  "restart-roots-out-of-order" "restart-roots" "port-75-once" "10" "3" \
  '(.driverError == null) and (.spawns | length == 2) and
   ([.frames[] | select(.method == "roots/list")] | length == 2) and
   ([.frames[] | select(.method == "roots/list") | .id][0] == "roots-reused") and
   ([.frames[] | select(.method == "roots/list") | .id][1] |
      startswith("mcp-agents/browser/downstream-request/")) and
   (.rootsClientResponses | map(.order) ==
      ["held-dead","replacement-first","stale-second"]) and
   (.rootsResponses == [{
      "pid": .spawns[1].pid,
      "spawnOrdinal": 2,
      "raw": "{\"jsonrpc\":\"2.0\",\"id\":\"roots-reused\",\"result\":{\"roots\":[{\"uri\":\"file:///workspace\",\"name\":\"replacement-root\"}]}}"
    }]) and
   ([.spawns[0].stdin[] | select(.id == "roots-reused" and has("result"))] | length == 0) and
   ([.spawns[1].stdin[] | select(.id == "roots-reused" and has("result"))] | length == 1) and
   (.spawns[1].stdinRaw | contains("dead-root") | not) and
   ([.frames[] | select(.id == 3 and .result.structuredContent.content == "BROWSER_OK_3")] | length == 1)'
test_browser_case "browser exit-75 retries are bounded at three attempts" \
  "port-always" "normal" "port-75-always" "10" "3" \
  '(.driverError == null) and (.spawns | length == 3) and
   ([.leaseCalls[] | select(.args[0] == "acquire")] | length == 3) and
   ([.frames[] | select(.id == 3 and
      .result.structuredContent.code == "browser_provisioning_failed" and
      (.result.content[0].text | contains("3 attempts")))] | length == 1)'
test_browser_case "browser malformed ready record fails closed" \
  "malformed" "normal" "malformed" "10" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 3 and
      .result.structuredContent.code == "browser_provisioning_failed")] | length == 1)'
test_browser_case "browser mismatched ready port fails closed" \
  "wrong-port" "normal" "wrong-port" "10" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 3 and
      .result.structuredContent.code == "browser_provisioning_failed")] | length == 1)'
test_browser_case "browser lease records reject duplicate prototype keys" \
  "duplicate-proto" "normal" "duplicate-proto" "10" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 3 and
      .result.structuredContent.code == "browser_provisioning_failed" and
      (.result.content[0].text | contains("duplicate browser lease record key: __proto__")))] | length == 1) and
   ([.spawns[0].stdin[] | select(.method == "tools/call")] | length == 0)'

test_browser_case "browser rejects a different Chrome process on the leased port" \
  "identity-substitution" "normal" "ready" "10" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 3 and .result.structuredContent.content == "BROWSER_OK_3")] | length == 1) and
   ([.frames[] | select(.id == 4 and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.stateLost == true and
      .result.structuredContent.outcomeUnknown == false and
      (.result.content[0].text | contains("call was not executed")))] | length == 1) and
   ([.spawns[0].stdin[] | select(.method == "tools/call") | .id] == [3]) and
   (.stderr | contains("browser lease identity lost"))'
test_browser_case "browser post-verifies the first call on a new generation" \
  "first-call-substitution" "normal" "ready" "10" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 3 and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.stateLost == true and
      .result.structuredContent.outcomeUnknown == true and
      (.result.content[-1].text | contains("never blindly replay")))] | length == 1) and
   ([.spawns[0].stdin[] | select(.method == "tools/call") | .id] == [3]) and
   ([.leaseCalls[] | select(.args[0] == "release" and
      (.args | index("gen-1") != null))] | length == 1)'
test_browser_case "a sibling in-flight result is never forwarded raw after a peer discards the generation" \
  "concurrent-identity-substitution" "normal" "slow-ready" "10" "3" \
  '(.driverError == null) and
   ([.leaseCalls[] | select(.args[0] == "acquire")] | length == 1) and
   ([.spawns[0].stdin[] | select(.method == "tools/call") | .id] == [3, 4]) and
   ([.frames[] | select(.id == 3 and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.stateLost == true and
      .result.structuredContent.outcomeUnknown == true)] | length == 1) and
   ([.frames[] | select(.id == 4 and .result.isError == true and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.stateLost == true and
      .result.structuredContent.outcomeUnknown == true and
      (.result.content[-1].text | contains("never blindly replay")))] | length == 1)'
test_browser_case "browser identity classification fails closed if its generation expires during the check" \
  "classifier-identity-toctou" "normal" "ready" "0.12" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 3 and .result.isError == true and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.outcomeUnknown == true)] | length == 1) and
   ([.frames[] | select(.id == 3 and .result.isError != true and
      .result.structuredContent.content == "BROWSER_OK_3")] | length == 0)'
test_browser_case "browser connect classification fails closed if its generation expires during status" \
  "classifier-connect-toctou" "connectfail" "status-slow-ready" "0.12" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 3 and .result.isError == true and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.outcomeUnknown == true)] | length == 1) and
   ([.frames[] | select(.id == 3 and .result.isError == true and
      (.result.structuredContent | has("code") | not))] | length == 0)'
test_browser_case "hard-timeout recovery suppresses a response already deferred during classification" \
  "deferred-hard-timeout-recovery" "deferred-hard-timeout-recovery" \
  "slow-ready" "10" "0.55" \
  '(.driverError == null) and (.spawns | length == 2) and
   ([.leaseCalls[] | select(.args[0] == "acquire")] | length == 1) and
   ([.spawns[0].stdin[] | select(.method == "tools/call") | .id] == [5, 3, 4]) and
   ([.spawns[1].stdin[] | select(.method == "tools/call")] | length == 0) and
   ([.frames[] | select(.id == 3)] | length == 1) and
   ([.frames[] | select(.id == 3 and .result.isError == true and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.outcomeUnknown == true)] | length == 1) and
   ([.frames[] | select(.id == 3 and
      .result.structuredContent.content == "DEFERRED_RAW_3")] | length == 0) and
   ([.frames[] | select(.id == 4 and
      .result.structuredContent.content == "CLASSIFIER_OK_4")] | length == 1) and
   ([.frames[] | select(.id == 5 and .result.isError == true and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.outcomeUnknown == true)] | length == 1)'
test_browser_case "cancelling an open browser call preserves generation classification" \
  "cancel-open-generation-change" "controlled-result" "ready" "0.12" "3" \
  '(.driverError == null) and
   ([.spawns[0].stdin[] | select(.method == "tools/call") | .id] == [3]) and
   ([.spawns[0].stdin[] | select(.method == "notifications/cancelled" and
      .params.requestId == 3)] | length == 1) and
   ([.leaseCalls[] | select(.args[0] == "release" and
      (.args | index("idle") != null))] | length == 1) and
   ([.frames[] | select(.id == 3 and .result.isError == true and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.outcomeUnknown == true and
      (.result.content[-1].text | contains("never blindly replay")))] | length == 1) and
   ([.frames[] | select(.id == 3 and .result.isError != true and
      .result.structuredContent.content == "RAW_CANCELLED_3")] | length == 0)'
test_browser_case "browser restart resolves an outstanding call and clears its latch" \
  "restart-outstanding" "restart-outstanding" "ready-port-75-second" "0.12" "3" \
  '(.driverError == null) and (.spawns | length == 2) and
   (.latchClearBeforeClose == true) and
   ([.leaseCalls[] | select(.args[0] == "acquire")] | length == 3) and
   ([.spawns[0].stdin[] | select(.method == "tools/call") | .id] == [3]) and
   ([.spawns[1].stdin[] | select(.method == "tools/call") | .id] == [4]) and
   ([.frames[] | select(.id == 3 and .result.isError == true and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.outcomeUnknown == true)] | length == 1) and
   ([.frames[] | select(.id == 4 and
      .result.structuredContent.content == "REPLACEMENT_OK_4")] | length == 1)'
test_browser_case "unsafe browser restart still resolves calls owned by the dead downstream" \
  "restart-outstanding-unsafe" "restart-outstanding-unsafe" "ready-port-75-second" "0.12" "3" \
  '(.driverError == null) and (.spawns | length == 1) and
   ([.frames[] | select(.id == 3 and .result.isError == true and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.outcomeUnknown == true)] | length == 1) and
   ([.frames[] | select(.id == 4 and .result.isError == true and
      .result.structuredContent.code == "browser_provisioning_failed" and
      (.result.structuredContent.message | contains("unsafe frame boundary")))] | length == 1)'
test_browser_case "oversized browser result fails closed instead of forwarding raw" \
  "oversized-browser-result" "oversized-result" "ready" "10" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 3 and .result.isError == true and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.outcomeUnknown == true)] | length == 1) and
   ([.frames[] | select(.id == 3 and
      .result.structuredContent.content == "RAW_OVERSIZED_RESULT")] | length == 0)'
test_browser_case "oversized browser result with id after result fails closed" \
  "oversized-id-after-result" "oversized-result-id-after" "ready" "10" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 3 and .result.isError == true and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.outcomeUnknown == true)] | length == 1) and
   ([.frames[] | select(.id == 3 and
      .result.structuredContent.content == "RAW_OVERSIZED_ID_AFTER")] | length == 0)'
test_browser_case "complete oversized browser result with id after result fails closed" \
  "oversized-complete-id-after" "oversized-complete-id-after" "ready" "10" "3" \
  '(.driverError == null) and
   (.stderr | contains("frame exceeded rewrite cap")) and
   ([.frames[] | select(.id == 3 and .result.isError == true and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.outcomeUnknown == true)] | length == 1) and
   ([.frames[] | select(.id == 3 and .result.isError != true and
      .result.structuredContent.content == "RAW_OVERSIZED_COMPLETE")] | length == 0)'
test_browser_case "browser finalize resolves active and buffered classifier owners" \
  "finalize-multiframe" "finalize-multiframe" "ready" "10" "3" \
  '(.driverError == null) and
   ([.frames[] | select((.id == 3 or .id == 4 or .id == 5) and
      .result.isError == true and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.outcomeUnknown == true)] | map(.id) | sort == [3,4,5]) and
   ([.frames[] | select((.id == 3 or .id == 4 or .id == 5) and
      .result.isError != true and
      (.result.structuredContent.content | startswith("RAW_FINALIZE_")))] | length == 0)'
test_browser_case "malformed browser result resolves lease-loss and clears its tracking" \
  "malformed-browser-result" "malformed-result" "ready" "10" "3" \
  '(.driverError == null) and (.latchClearBeforeClose == true) and
   ([.frames[] | select(.id == 3 and .result.isError == true and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.outcomeUnknown == true)] | length == 1)'
test_browser_case "hard-timed-out browser call resolves lease-loss without permanent tracking" \
  "browser-hard-timeout" "timeout-no-result" "ready" "10" "1" \
  '(.driverError == null) and (.latchClearBeforeClose == true) and
   (.spawns | length == 2) and
   ([.frames[] | select(.id == 3 and .result.isError == true and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.outcomeUnknown == true)] | length == 1) and
   (.rawLines | map(contains("OLD_PROCESS_SHOULD_BE_DEAD")) | any | not)'
test_browser_case "unterminated browser result fails closed during child exit" \
  "unterminated-browser-result" "call-nonewlinedie" "ready" "10" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 3 and .result.isError == true and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.outcomeUnknown == true)] | length == 1) and
   ([.frames[] | select(.id == 3 and .result.isError != true and
      .result.structuredContent.content == "BROWSER_UNTERMINATED_3")] | length == 0)'
test_browser_case "browser suspends idle expiry during a held identity check" \
  "slow-identity-idle" "normal" "ready" "0.12" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 4 and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.stateLost == true and
      .result.structuredContent.outcomeUnknown == false and
      (.result.content[0].text | contains("identity could not be verified")))] | length == 1) and
   ([.spawns[0].stdin[] | select(.method == "tools/call") | .id] == [3]) and
   ([.leaseCalls[] | select(.args[0] == "release" and
      (.args | index("gen-1") != null))] | length == 1)'
test_browser_case "browser unreadable identity releases the discarded generation" \
  "identity-unreachable" "normal" "ready" "10" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 4 and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.stateLost == true and
      .result.structuredContent.outcomeUnknown == false)] | length == 1) and
   ([.spawns[0].stdin[] | select(.method == "tools/call") | .id] == [3]) and
   ([.leaseCalls[] | select(.args[0] == "release" and
      (.args | index("gen-1") != null))] | length == 1)'

test_browser_case "browser shutdown lets an acquiring helper run its TERM cleanup" \
  "shutdown-acquire" "normal" "acquire-term" "10" "3" \
  '(.driverError == null) and (.acquireTerminated == true) and
   (.leaseCalls | map(.args[0]) == ["acquire"]) and
   ([.spawns[0].stdin[] | select(.method == "tools/call") | .id] | length == 0)'
test_browser_case "browser acquire timeout lets the helper run its TERM cleanup" \
  "acquire-timeout" "normal" "acquire-term-timeout" "10" "3" \
  '(.driverError == null) and (.acquireTerminated == true) and
   (.leaseCalls | map(.args[0]) == ["acquire"]) and
   ([.frames[] | select(.id == 3 and
      .result.structuredContent.code == "browser_provisioning_failed" and
      (.result.content[0].text | contains("timed out")))] | length == 1) and
   ([.spawns[0].stdin[] | select(.method == "tools/call") | .id] | length == 0)'
test_browser_case "browser escalates when an acquiring helper ignores TERM" \
  "acquire-kill-timeout" "normal" "acquire-ignore-term-timeout" "10" "3" \
  '(.driverError == null) and (.acquireTerminated == true) and
   (.acquireAlive == false) and
   ([.frames[] | select(.id == 3 and
      .result.structuredContent.code == "browser_provisioning_failed" and
      (.result.content[0].text | contains("timed out")))] | length == 1) and
   ([.spawns[0].stdin[] | select(.method == "tools/call") | .id] | length == 0)'
test_browser_case "browser helper budget stays below its request budget" \
  "derived-helper-timeout" "normal" "acquire-derived-timeout" "10" "20" \
  '(.driverError == null) and (.acquireTerminated == true) and
   ([.frames[] | select(.id == 3 and
      .result.structuredContent.code == "browser_provisioning_failed" and
      (.result.content[0].text | contains("timed out")))] | length == 1) and
   ([.frames[] | select(.id == 3 and .error.code == -32001)] | length == 0) and
   ([.spawns[0].stdin[] | select(.method == "tools/call") | .id] | length == 0)'

test_browser_case "browser status-ready preserves the native connect error" \
  "status-ready" "connectfail" "status-ready" "10" "3" \
  '(.driverError == null) and
   ([.leaseCalls[] | select(.args[0] == "status")] | length == 1) and
   ([.frames[] | select(.id == 3 and .result.isError == true and
      (.result.structuredContent | has("code") | not))] | length == 1)'
test_browser_case "browser corrupt status stays unknown and preserves native error" \
  "status-corrupt" "connectfail" "status-corrupt" "10" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 3 and .result.isError == true and
      (.result.structuredContent | has("code") | not))] | length == 1) and
   (.stderr | contains("status is unknown")) and
   (.stderr | contains("exit 70"))'
test_browser_case "browser absent lease enriches once, never replays, and next call repairs" \
  "status-absent" "connectfail" "status-absent" "10" "3" \
  '(.driverError == null) and
   ([.leaseCalls[] | select(.args[0] == "acquire")] | length == 2) and
   ([.leaseCalls[] | select(.args[0] == "status")] | length == 1) and
   ([.frames[] | select(.id == 3 and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.stateLost == true and
      .result.structuredContent.outcomeUnknown == true and
      (.result.content[-1].text | contains("never blindly replay")))] | length == 1) and
   ([.frames[] | select(.id == 4 and
      .result.structuredContent.content == "RECOVERED_NEXT_CALL")] | length == 1) and
   ([.spawns[0].stdin[] | select(.method == "tools/call")] | map(.id) == [3,4])'

test_browser_case "every downstream frame resets browser lease idle" \
  "activity" "activity" "ready" "0.12" "3" \
  '(.driverError == null) and
   ([.leaseCalls[] | select(.args[0] == "release" and
      (.args | index("idle") != null))] | length == 1) and
   ([.leaseCalls[] | select(.args[0] == "release")][0].at >
     [.frameEvents[] | select(.id == 3)][0].at) and
   ([.frames[] | select(.id == 3 and
      .result.structuredContent.content == "ACTIVITY_DONE")] | length == 1)'
test_browser_case "browser stderr is prefixed and does not reset lease idle" \
  "stderr" "stderr" "ready" "0.12" "3" \
  '(.driverError == null) and
   (.stderr | contains("[chrome-devtools] noisy but not browser activity")) and
   ([.leaseCalls[] | select(.args[0] == "release" and
      (.args | index("idle") != null))] | length == 1) and
   ([.leaseCalls[] | select(.args[0] == "release")][0].at <
     .lastNoisyStderrAt)'
test_browser_case "browser idle timeout releases a ready generation" \
  "idle-release" "normal" "ready" "0.12" "3" \
  '(.driverError == null) and
   ([.leaseCalls[] | select(.args[0] == "release" and
      (.args | index("idle") != null) and
      (.args | index("gen-1") != null))] | length == 1)'
test_browser_case "browser idle timeout zero disables idle release" \
  "idle-zero" "normal" "ready" "0" "3" \
  '(.driverError == null) and
   ([.leaseCalls[] | select(.args[0] == "release" and
      (.args | index("idle") != null))] | length == 0) and
   ([.leaseCalls[] | select(.args[0] == "release" and
      (.args | index("shutdown") != null))] | length == 1)'
test_browser_case "browser idle release exit 69 is nonfatal" \
  "release-69" "normal" "release-69" "0.12" "3" \
  '(.driverError == null) and
   ([.leaseCalls[] | select(.args[0] == "release")] | length >= 1) and
   (.stderr | contains("was nonfatal"))'
test_browser_case "browser empty release diagnostics fall back to the exit code" \
  "release-70" "normal" "release-empty-70" "0.12" "3" \
  '(.driverError == null) and
   ([.leaseCalls[] | select(.args[0] == "release")] | length >= 1) and
   (.stderr | contains("exit 70"))'
test_browser_case "browser cap-only generation still attempts nonfatal release" \
  "cap-only" "normal" "cap-only" "0.12" "3" \
  '(.driverError == null) and
   ([.leaseCalls[] | select(.args[0] == "release" and
      (.args | index("idle") != null))] | length == 1) and
   (.stderr | contains("was nonfatal"))'
test_browser_case "browser shutdown releases the exact acquired generation" \
  "shutdown" "normal" "ready" "10" "3" \
  '(.driverError == null) and
   ([.leaseCalls[] | select(.args[0] == "release" and
      (.args | index("shutdown") != null) and
      (.args | index("gen-1") != null))] | length == 1)'
test_browser_case "browser idle release has time to finish remote cleanup" \
  "slow-idle-release" "normal" "slow-idle-release" "0.12" "5" \
  '(.driverError == null) and
   ([.releaseCompletions[] | select(.reason == "idle")] | length == 1)'
test_browser_case "browser shutdown release is bounded and reaped" \
  "shutdown" "normal" "slow-shutdown-release" "10" "5" \
  '(.driverError == null) and
   ([.releaseCompletions[] | select(.reason == "shutdown")] | length == 1)'

if [ "${SKIP_INTEGRATION:-}" = "1" ]; then
  echo ""
  echo "(Skipping integration tests — SKIP_INTEGRATION=1)"
else
  test_connectivity "call claude (connectivity)" "claude" "claude_code" 30
  test_connectivity "call gemini (connectivity)" "gemini" "gemini"     30
  test_codex_app_discovery "codex wrapper-owned App Server discovery"
  test_codex_isolated_runtime "codex real read-only App Server turn uses isolated state"
  test_codex_percall_write "codex real App Server workspace-write grants writes"
fi

. "$TEST_REPO_ROOT/test-codex-legacy.sh"

test_no_registered_child_leaks "test suite leaves no provider stub children"

# ---------- Summary ----------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
