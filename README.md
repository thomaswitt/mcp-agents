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
(both configurable via `--sandbox_mode` / `--approval_policy`, and steerable per
call), `web_search=cached`, `check_for_update_on_startup=false`,
`allow_login_shell=false`, and `history.persistence=none`. Startup feature
defaults (overridable per call via a `config` override, like sandbox/approval)
are `features.multi_agent=false`, `features.apps=false`,
`features.plugins=false`, `features.hooks=false`, and
`features.skill_mcp_dependency_install=false`; apps/plugins stay disabled to
keep ChatGPT app/plugin skills — Figma, Gmail, Presentations, etc. — out of the
bridged session context.

Startup flags (`--model`, `--model_reasoning_effort`) set the model and default
effort for the native Codex MCP server. The initial `codex` tool additionally
advertises an optional top-level `model_reasoning_effort` argument with exactly
two values:

| Value | Use for |
|-------|---------|
| `xhigh` | Hard but bounded implementation work |
| `max` | Extra-hard, quality-first work with high architectural, concurrency, data-integrity, or security risk |

Any other value is stripped and the server-configured default is used.

The selector applies only when creating a new Codex session. Omit it to inherit
the server's `--model_reasoning_effort` setting (`xhigh` by default). Every
`codex-reply` in that session inherits the selected effort; replies cannot
change it and do not advertise the argument. `ultra` is deliberately unavailable
through this selector because it changes execution topology by enabling automatic
delegation, rather than merely increasing the reasoning effort of the session.

Raw model and effort overrides remain blocked. Per-call `model` and the
model/effort keys inside a `config` override are stripped from `tools/call`
before they reach Codex, so callers cannot bypass the two-value selector
(`sandbox`, `cwd`, and `approval-policy` — top-level and the matching `config`
keys — are intentionally left steerable per call). For example, this request:

```json
{
  "prompt": "Review this diff",
  "model": "gpt-5.5-codex",
  "config": { "model_reasoning_effort": "medium" }
}
```

is forwarded to Codex as `{ "prompt": "Review this diff" }`. To select maximum
reasoning for a new session, use the dedicated top-level argument instead:

```json
{
  "prompt": "Implement the accepted specification",
  "model_reasoning_effort": "max"
}
```

**Goal injection.** You can give Codex a persistent objective. Set one at server
startup with `--goal "<text>"`, or per call with a `goal` argument in `tools/call`:

```json
{ "prompt": "Refactor the parser", "goal": "Keep the public API unchanged" }
```

For the initial `codex` call the objective is injected into Codex's native
`developer-instructions` field (a developer-role message), so this is forwarded
to Codex as:

```json
{
  "prompt": "Refactor the parser",
  "developer-instructions": "Persistent objective for this Codex thread (a standing goal — keep pursuing it across turns unless explicitly superseded):\nKeep the public API unchanged"
}
```

A developer message persists for the whole thread, so `codex-reply` follow-ups
inherit the objective automatically. Because `codex-reply` has no
`developer-instructions` field, a per-call `goal` on a reply is instead added as
a concise `Reminder — standing objective for this thread: …` preamble on the
prompt. Any caller-supplied `developer-instructions` are preserved, with the
objective merged ahead of them.

The wrapper-only `goal` argument is always stripped before it reaches Codex (it
is never a native Codex parameter). A per-call `goal` overrides the `--goal`
default for that call; a per-call empty `goal` (`""`) suppresses the default for
that one call; a non-string `goal` is ignored (the `--goal` default still
applies).

So a client's model knows it can pass `goal`, the pass-through advertises it: it
rewrites its own `tools/list` response to declare an optional `goal` property on
the `codex` and `codex-reply` tool schemas (models only generate arguments
declared in a tool's `inputSchema`). Only `properties` is augmented — `required`
and `additionalProperties` are left intact — and the rewrite touches only the
`tools/list` response; every other frame is forwarded byte-for-byte.

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
throttled standard MCP `notifications/progress` updates using that exact token.
It never invents a progress token. These updates keep clients from mistaking an
active Codex call for an idle one, but they extend neither the wrapper's hard
deadline nor a client's separate hard wall-clock tool timeout. Configure the
client timeout to exceed the longest expected Codex run plus response headroom;
when it expires, the client cancels the call and the bounded cancellation path
below takes over.

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
      "args": ["--provider", "codex", "--model", "gpt-5.6-sol", "--model_reasoning_effort", "medium"],
      "timeout": 7500000
    }
  }
}
```

The model is fixed at server startup, while startup effort is the default for new
sessions. An initial `codex` call may select `xhigh` or `max` with the dedicated
top-level `model_reasoning_effort` argument; omission inherits the startup
default, and `codex-reply` calls inherit the session's choice without being able
to change it. Per-call `model` and model/effort keys inside a raw `config`
override are still stripped before reaching Codex, so they cannot bypass these
constraints (`sandbox`/`cwd`/`approval-policy` remain steerable per call). Add
`"--goal", "<text>"` to `args` to inject a persistent objective into every Codex
call (see [Goal injection](#codex-pass-through) above).

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
