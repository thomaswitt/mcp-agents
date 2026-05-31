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

Global install is **strongly recommended** over `npx -y mcp-agents@latest`. The `npx`
approach performs a network round-trip on every cold start, which can exceed MCP client
connection timeouts and cause "stream disconnected" errors.

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
| `--model` | `gpt-5.5` | `model` |
| `--model_reasoning_effort` | `xhigh` | `model_reasoning_effort` |

Hardcoded defaults: `sandbox_mode=read-only`, `approval_policy=never`,
`features.multi_agent=false`.

Startup flags (`--model`, `--model_reasoning_effort`) set the model and effort for the native Codex MCP server. Per-call `model` and `config` arguments are stripped from `tools/call` before they reach Codex, so a client cannot override the pinned model/effort (or the read-only/never sandbox config) for a single call. For example, this request:

```json
{
  "prompt": "Review this diff",
  "model": "gpt-5.5-codex",
  "config": { "model_reasoning_effort": "medium" }
}
```

is forwarded to Codex as `{ "prompt": "Review this diff" }`. Change the model or effort at server startup instead.

## Integration with Claude Code

Add entries to your project's `.mcp.json` (requires `npm i -g mcp-agents`):

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
      "args": ["--provider", "codex", "--model", "gpt-5.5", "--model_reasoning_effort", "medium"]
    }
  }
}
```

The model and effort are fixed at server startup. Per-call `model` and `config` arguments sent to the native `codex` tool are stripped before reaching Codex, so they cannot override the startup defaults.

Because the bridge runs in an isolated Codex home, inherited MCP servers from your normal
`~/.codex/config.toml` are intentionally unavailable inside bridged Codex sessions.

<details>
<summary>Alternative: using npx (slower, not recommended)</summary>

```json
{
  "mcpServers": {
    "codex": {
      "command": "npx",
      "args": ["-y", "mcp-agents@latest", "--provider", "codex"]
    }
  }
}
```

> **Warning:** `npx -y mcp-agents@latest` performs a network round-trip on every cold
> start (~70s), which can exceed MCP client connection timeouts.

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
