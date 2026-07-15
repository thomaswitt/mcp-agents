# mcp-agents

MCP server that wraps AI CLI tools — [Claude Code](https://docs.anthropic.com/en/docs/claude-code), [Antigravity CLI](https://antigravity.google/) (`agy`), and [Codex CLI](https://github.com/openai/codex) — so any MCP client can call them as tools.

## Prerequisites

- **Node.js >= 18**
- At least one of the following CLIs installed and on your `$PATH`:

| CLI | Install |
|-----|---------|
| `claude` | [Claude Code docs](https://docs.anthropic.com/en/docs/claude-code) |
| `agy` | [Google Antigravity](https://antigravity.google/) |
| `codex` | `npm install -g @openai/codex` |

Only the CLI you select with `--provider` needs to be present.

## Install

```bash
npm install -g mcp-agents
```

Global install is the fastest and most reliable startup path. `npx -y mcp-agents`
is functionally equivalent once the MCP server is running, but startup depends on
npm package resolution/cache state before the MCP client can connect.

**Tip:** If your project's `.mcp.json` references `mcp-agents`, add `npm install -g mcp-agents`
to your setup script (e.g. `bin/setup`) so new developers get it automatically.

## Quick test

```bash
# Default provider (codex)
mcp-agents

# Specific provider
mcp-agents --provider claude
mcp-agents --provider gemini
```

The server speaks [JSON-RPC over stdio](https://modelcontextprotocol.io/docs/concepts/transports#stdio). It prints `[mcp-agents] ready (provider: <name>)` to stderr when it's listening.

## Providers & Tools

Each `--provider` flag maps to a single exposed tool:

| Provider | Tool name | CLI command |
|----------|-----------|-------------|
| `claude` | `claude_code` | `claude --model claude-opus-4-8 --effort xhigh -p --output-format json` |
| `gemini` | `gemini` | `agy --sandbox -p <prompt>` |
| `codex` | *(pass-through)* | `codex mcp-server` |

### `claude_code` parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `prompt` | `string` | yes | The prompt to send to Claude Code |
| `timeout_ms` | `integer` | no | Timeout in ms (default: 900 000 / 15 minutes) |

Any additional `tools/call` arguments are ignored (for example `model`, `effort`, or `config`).

Claude is pinned to `claude-opus-4-8` at effort `xhigh`; callers cannot change the model or effort per call. Calls run with `--output-format json`; the server parses the JSON payload and returns the assistant `result` text (or an MCP error if `is_error=true`).
The longer default accommodates deep Opus reviews; callers can still set a
smaller `timeout_ms`, and server operators can override the default with
`--timeout <seconds>`.

### `gemini` parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `prompt` | `string` | yes | The prompt to send to the Antigravity CLI (`agy`) |
| `timeout_ms` | `integer` | no | Timeout in ms (default: 300 000 / 5 minutes) |

Any additional `tools/call` arguments are ignored (for example `model` or `model_reasoning_effort`).

`agy` always runs with `--sandbox` (terminal restrictions enabled); there is no per-call sandbox toggle.

### `codex` (pass-through)

The codex provider passes through to Codex's native MCP server (`codex mcp-server`)
inside an isolated `CODEX_HOME`. The bridge copies `auth.json` into a temporary Codex
home, writes a minimal `config.toml`, and does not inherit your normal external MCP
server list. That keeps Codex from recursively starting other agent tools like Claude
or Gemini during bridge calls.

| CLI Flag | Default | Codex config key |
|----------|---------|-----------------|
| `--model` | `gpt-5.6-sol` | `model` |
| `--model_reasoning_effort` | `xhigh` | `model_reasoning_effort` |

Other startup defaults: `sandbox_mode=workspace-write`, `approval_policy=never`
(configurable for the whole server with `--sandbox_mode` / `--approval_policy`),
`web_search=cached`, `check_for_update_on_startup=false`,
`allow_login_shell=false`, and `history.persistence=none`. Fixed bridge feature
defaults are `features.multi_agent=false`, `features.apps=false`,
`features.plugins=false`, `features.hooks=false`, and
`features.skill_mcp_dependency_install=false`; apps/plugins stay disabled to
keep ChatGPT app/plugin skills — Figma, Gmail, Presentations, etc. — out of the
bridged session context.

The bridge replaces Codex's broad config-shaped native schema with a deliberately
small contract:

| `codex` parameter | Type | Required | Description |
|-------------------|------|----------|-------------|
| `prompt` | `string` | yes | Initial user prompt |
| `cwd` | `string` | yes | Absolute working directory |
| `sandbox` | `string` | yes | `read-only`, `workspace-write`, or `danger-full-access` |
| `model_reasoning_effort` | `string` | yes | `xhigh` or `max` |
| `goal` | `string` | no | Standing objective; `""` suppresses a server-wide goal for this call |

| `codex-reply` parameter | Type | Required | Description |
|-------------------------|------|----------|-------------|
| `prompt` | `string` | yes | Follow-up user prompt |
| `threadId` | `string` | yes | Nonblank thread ID returned by `codex` |
| `goal` | `string` | no | Optional prompt-level reminder of the standing objective |

Both schemas set `additionalProperties: false`. Unsupported, missing, or invalid
arguments are rejected locally with JSON-RPC `-32602` before Codex runs. That
includes native escape hatches such as `model`, `config`, `approval-policy`,
`developer-instructions`, `base-instructions`, and `compact-prompt`; future
upstream schema additions stay hidden until mcp-agents intentionally adopts them.

`approval_policy=never` is intentional for an MCP bridge: a detached tool call
cannot reliably conduct an interactive approval conversation. Operators can pick
`untrusted` or `on-request` for the whole server with `--approval_policy`, but
callers cannot weaken or change that policy per request. Each new session must
still state its sandbox explicitly, so write authority is visible at the call site.

Startup flags (`--model`, `--model_reasoning_effort`) configure the isolated native
Codex server. The model remains server-owned. Each initial `codex` call explicitly
selects one of two allowed reasoning efforts:

| Value | Use for |
|-------|---------|
| `xhigh` | Hard but bounded implementation work |
| `max` | Extra-hard, quality-first work with high architectural, concurrency, data-integrity, or security risk |

The selector applies only when creating a session. Every `codex-reply` inherits
that choice and cannot change it. `ultra` is deliberately unavailable because it
changes execution topology by enabling automatic delegation rather than merely
increasing the session's reasoning effort.

For example, a read-only review starts with:

```json
{
  "prompt": "Review this diff",
  "cwd": "/absolute/path/to/project",
  "sandbox": "read-only",
  "model_reasoning_effort": "max",
  "goal": "Find correctness and security defects"
}
```

**Goal injection.** Set a default objective at server startup with
`--goal "<text>"`, or pass `goal` on a call. mcp-agents turns the initial goal into
Codex's native `developer-instructions` internally:

```json
{
  "prompt": "Refactor the parser",
  "cwd": "/absolute/path/to/project",
  "sandbox": "workspace-write",
  "model_reasoning_effort": "xhigh",
  "goal": "Keep the public API unchanged"
}
```

A developer message persists for the thread, so replies inherit it. A per-call
`goal` on `codex-reply` becomes a concise prompt reminder because the native reply
tool has no developer-instructions field. Direct developer instructions are not
exposed: `goal` is the narrow, auditable standing-objective interface. A per-call
goal overrides the server default; `""` suppresses that default for one call.

The bridge rewrites only `tools/list` responses to advertise these curated
schemas. Normal native frames remain byte-for-byte pass-through; locally generated
validation errors use the same frame-safe queue as progress and recovery messages.

**Precedence within a thread.** The objective set on the initial `codex` call is
a developer-role message and persists for the whole thread, so it takes
precedence: a *different* `goal` supplied later on a `codex-reply` is only a
prompt-level reminder and will not reliably override the standing objective
(verified live — a reply goal that conflicts with the initial one is ignored in
favor of the standing one). The reply reminder works when it is *not* opposed by
a conflicting standing objective. To genuinely change the objective mid-stream,
start a new `codex` call rather than changing it on a `codex-reply`.

> **Note — this is not Codex's native `/goal`.** Codex's `/goal` slash command
> (durable, thread-scoped goal state with lifecycle/budget/evidence-based
> completion) is a TUI-only feature — it is parsed in the Codex terminal UI and
> is *not* reachable through `codex mcp-server`. Prefixing an MCP prompt with
> `/goal …` does **not** activate it; the text is just passed through as a user
> message. This wrapper therefore steers Codex with `developer-instructions`
> (the MCP-native vehicle for a standing objective), which is prompt/role
> conditioning, not the native goal-lifecycle subsystem.

**Per-call liveness.** The codex pass-through tracks every open `tools/call`
independently. `--codex_idle_timeout <seconds>` (default `600`, `0` disables)
bounds how long one call may go without correlated Codex activity. Only a Codex
event carrying that call's `_meta.requestId` (or its matching response or
interactive exchange) refreshes its idle deadline. Codex stderr, client pings,
unrelated requests, and events belonging to another call cannot keep a stalled
call alive. If a call reaches its idle deadline, the wrapper surfaces a JSON-RPC
error (`-32001`), tears down the shared Codex process group, fails any other open
calls, and exits so the MCP client can reconnect to a clean bridge.

`--timeout <seconds>` is also enforced for Codex calls (default `7200`) as an
immutable hard deadline. Correlated activity can extend the idle window but
never this hard deadline. Set the wrapper deadline below the MCP client's own
wall-clock tool timeout when the client must always receive the wrapper's
explicit error before it gives up.

When the incoming request supplies `_meta.progressToken`, the wrapper sends
standard MCP `notifications/progress` updates using that exact token. It never
invents a progress token. The first useful status is immediate; later updates
are coalesced to at most one per second, with the latest status winning. During
otherwise silent work, a `Codex: still running` notice is sent every 10 seconds
and includes the age of the last request-correlated Codex event.

Status text is fail-closed. The bridge exposes explicitly attributed commentary,
the active plan step, and generic lifecycle summaries for commands, patches,
MCP tools, web/image work, and subagents. It does not expose final-answer text,
reasoning, prompts, command strings or output, tool arguments, search queries,
file paths, or token telemetry. Messages are whitespace-normalized and capped
at 200 Unicode code points. Native `codex/event` frames remain byte-for-byte
unchanged; progress is a parallel MCP channel and is normally UI status rather
than additional tool-result/model context.

These notices deliberately keep a progress-aware client's idle window alive,
leaving liveness authority with the wrapper's idle and hard deadlines. They do
not refresh `--codex_idle_timeout`, extend the wrapper's hard deadline, or
extend a client's separate hard wall-clock tool timeout. A generated progress
frame is inserted only at a native newline boundary; if Codex stalls halfway
through a frame, the latest notice waits for a safe boundary and the real idle
watchdog still terminates a permanent stall. Configure the client timeout to
exceed the longest expected Codex run plus response headroom; when it expires,
the client cancels the call and the bounded cancellation path below takes over.

**Terminal-result recovery.** Codex announces the thread ID on an early,
request-correlated session event, so the wrapper retains it before the build
finishes. If Codex later emits its terminal completion event and final agent
message but its native `tools/call` response does not arrive within the short
terminal-response grace period, the wrapper returns an equivalent successful
result containing both `content` and `structuredContent.threadId`. A matching
late native response is discarded, preserving exactly-once JSON-RPC response
semantics. This covers the failure mode where work landed in the tree but the
caller otherwise received neither the result nor the thread ID.

**Cancellation and reconnect.** Client cancellation starts a short,
non-resettable grace period. If Codex does not settle within that bound, the
wrapper synthesizes no response for the canceled ID, fails any other open calls
once, kills and reaps the detached Codex process group, and exits. A native
response that arrives inside the grace period is discarded whenever it can be
intercepted without corrupting a partially forwarded frame. The MCP client can
then reconnect to a fresh bridge; the canceled, potentially write-capable call
is never replayed automatically. Inspect the working tree before manually
retrying it because cancellation does not prove that Codex made no changes.

This legacy bridge deliberately does **not** respawn `codex mcp-server` inside
the existing stdio connection or transparently replay threads. `codex-reply`
state belongs to the old Codex process, so a thread ID from a torn-down child
cannot be resumed after reconnect. Durable same-connection recovery requires a
separate migration from the transparent legacy pass-through to an MCP adapter
over `codex app-server` (`thread/start`, `turn/start`, `turn/interrupt`, and
`thread/resume`).

## Integration with Claude Code

Add entries to your project's `.mcp.json` using a globally installed `mcp-agents`
binary:

```json
{
  "mcpServers": {
    "codex": {
      "command": "mcp-agents",
      "args": ["--provider", "codex"],
      "timeout": 7500000
    },
    "gemini": {
      "command": "mcp-agents",
      "args": ["--provider", "gemini"]
    }
  }
}
```

Override codex defaults at server startup:

```json
{
  "mcpServers": {
    "codex": {
      "command": "mcp-agents",
      "args": ["--provider", "codex", "--model", "gpt-5.6-sol", "--model_reasoning_effort", "xhigh"],
      "timeout": 7500000
    }
  }
}
```

The model is fixed at server startup. Every initial `codex` call must select
`xhigh` or `max`; replies inherit the selection. Raw `model`, `config`, and
per-call approval-policy arguments are rejected before Codex runs. Add
`"--goal", "<text>"` to `args` to provide a default objective (see
[Goal injection](#codex-pass-through) above).

Claude interprets the per-server `timeout` in milliseconds as a hard wall-clock
cap; progress does not extend it. Keep it above the wrapper's `--timeout`
(7,200 seconds by default), including response headroom. A project `.mcp.json`
entry can override a user-level MCP entry of the same name, so put the timeout
on the project entry instead of relying on the user-level copy.

Because the bridge runs in an isolated Codex home, inherited MCP servers from your normal
`~/.codex/config.toml` are intentionally unavailable inside bridged Codex sessions.

<details>
<summary>Alternative: using npx (zero install, slower startup)</summary>

```json
{
  "mcpServers": {
    "codex": {
      "command": "npx",
      "args": ["-y", "mcp-agents", "--provider", "codex"],
      "timeout": 7500000
    }
  }
}
```

`npx` only affects process launch. Once the MCP server is connected, normal
tool-call latency is the same server code either way. Use `npx` when zero install
matters more than startup/cache reliability.

</details>

## Integration with OpenAI Codex

Add two entries to `~/.codex/config.toml` — one per provider you want available.
Give the outer MCP call 60 seconds beyond each mcp-agents budget so the provider
can return its result: 960 seconds for Claude's 900-second budget and 360 seconds
for Gemini's 300-second budget:

```toml
[mcp_servers.claude-code]
command = "mcp-agents"
args = ["--provider", "claude"]
tool_timeout_sec = 960

[mcp_servers.gemini]
command = "mcp-agents"
args = ["--provider", "gemini"]
tool_timeout_sec = 360
```

Then in a Codex session you can call the `claude_code` or `gemini` tools, which shell out to the respective CLIs.

## Development

```bash
npm install
npm link          # symlinks mcp-agents to your local server.js
```

After `npm link`, any edits to `server.js` take effect immediately — no reinstall needed.

Benchmark the startup paths through real `/tmp` project `.mcp.json` files:

```bash
npm run bench:mcp-startup
```

This measures MCP launch through `initialize` and `tools/list`; it does not call
the provider model/tool.

For a manual end-to-end progress check, invoke `codex` from a Claude Code
subagent and verify that commentary/lifecycle messages appear while the tool
call remains blocking, followed by exactly one final tool result. This smoke
check depends on the installed Claude Code UI and is intentionally not a
deterministic test-suite gate.

## How it works

1. An MCP client connects over stdio
2. The server reads `--provider <name>` from its argv (defaults to `codex`)
3. It registers a single tool matching that provider's CLI
4. Client calls `tools/call` with the tool name and a `prompt`
5. The server runs the CLI as a child process and returns tool text (Claude JSON `result`, or stdout/stderr for other providers)

The server keeps a small keepalive timer so Node.js does not exit prematurely
when stdin reaches EOF before an async subprocess registers an active handle.
For Claude and Gemini provider mode, that keepalive is cleared during shutdown:
the server now exits when the MCP stdio connection closes and kills any tracked
detached provider child process groups that would otherwise linger.

## License

MIT
