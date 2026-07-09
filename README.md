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
| `timeout_ms` | `integer` | no | Timeout in ms (default: 300 000 / 5 minutes) |

Any additional `tools/call` arguments are ignored (for example `model`, `effort`, or `config`).

Claude is pinned to `claude-opus-4-8` at effort `xhigh`; callers cannot change the model or effort per call. Calls run with `--output-format json`; the server parses the JSON payload and returns the assistant `result` text (or an MCP error if `is_error=true`).

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

Startup flags (`--model`, `--model_reasoning_effort`) set the model and effort for the native Codex MCP server. Per-call `model` and the model/effort keys inside a `config` override are stripped from `tools/call` before they reach Codex, so a client cannot override the pinned model/effort for a single call (`sandbox`, `cwd`, and `approval-policy` — top-level and the matching `config` keys — are intentionally left steerable per call). For example, this request:

```json
{
  "prompt": "Review this diff",
  "model": "gpt-5.5-codex",
  "config": { "model_reasoning_effort": "medium" }
}
```

is forwarded to Codex as `{ "prompt": "Review this diff" }`. Change the model or effort at server startup instead.

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

**Idle watchdog.** The codex pass-through is transparent, so a Codex session that
stalls after doing work (e.g. its final model turn hangs, or it waits on an
elicitation the client never answers) would otherwise hang the caller's
`tools/call` forever. `--codex_idle_timeout <seconds>` (default `600`, `0`
disables) bounds this: if Codex emits nothing while a request is in flight for
that long, the wrapper returns a JSON-RPC error (`-32001`) for the open
request(s), kills the Codex process group, and exits — turning an unbounded stall
into a surfaced error. The timer resets on any Codex output or inbound client
activity and is suspended while the client backpressures stdout, so healthy long
or interactive runs are not killed. The wrapper also exits (instead of lingering)
if Codex dies or fails to start, so a dead Codex can never leave the caller
hanging.

## Integration with Claude Code

Add entries to your project's `.mcp.json` using a globally installed `mcp-agents`
binary:

```json
{
  "mcpServers": {
    "codex": {
      "command": "mcp-agents",
      "args": ["--provider", "codex"]
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
      "args": ["--provider", "codex", "--model", "gpt-5.6-sol", "--model_reasoning_effort", "medium"]
    }
  }
}
```

The model and effort are fixed at server startup. Per-call `model` and the model/effort keys inside a `config` override sent to the native `codex` tool are stripped before reaching Codex, so they cannot override the startup model/effort (per-call `sandbox`/`cwd`/`approval-policy` are left intact). Add `"--goal", "<text>"` to `args` to inject a persistent objective into every Codex call (see [Goal injection](#codex-pass-through) above).

Because the bridge runs in an isolated Codex home, inherited MCP servers from your normal
`~/.codex/config.toml` are intentionally unavailable inside bridged Codex sessions.

<details>
<summary>Alternative: using npx (zero install, slower startup)</summary>

```json
{
  "mcpServers": {
    "codex": {
      "command": "npx",
      "args": ["-y", "mcp-agents", "--provider", "codex"]
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
Set `tool_timeout_sec = 300` to avoid Codex MCP's default 60s per-tool timeout:

```toml
[mcp_servers.claude-code]
command = "mcp-agents"
args = ["--provider", "claude"]
tool_timeout_sec = 300

[mcp_servers.gemini]
command = "mcp-agents"
args = ["--provider", "gemini"]
tool_timeout_sec = 300
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
