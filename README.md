# mcp-agents

MCP server that wraps AI CLI tools — [Claude Code](https://docs.anthropic.com/en/docs/claude-code), [Gemini CLI](https://github.com/google-gemini/gemini-cli), and [Codex CLI](https://github.com/openai/codex) — so any MCP client can call them as tools.

## Prerequisites

- **Node.js >= 18**
- At least one of the following CLIs installed and on your `$PATH`:

| CLI | Install |
|-----|---------|
| `claude` | [Claude Code docs](https://docs.anthropic.com/en/docs/claude-code) |
| `gemini` | `npm install -g @anthropic-ai/gemini-cli` |
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

# Optional: enable Gemini sandbox mode
mcp-agents --provider gemini --sandbox true
```

The server speaks [JSON-RPC over stdio](https://modelcontextprotocol.io/docs/concepts/transports#stdio). It prints `[mcp-agents] ready (provider: <name>)` to stderr when it's listening.

## Providers & Tools

Each `--provider` flag maps to a single exposed tool:

| Provider | Tool name | CLI command |
|----------|-----------|-------------|
| `claude` | `claude_code` | `claude -p --output-format json` |
| `gemini` | `gemini` | `gemini [-s] -p <prompt>` |
| `codex` | *(pass-through)* | `codex mcp-server` |

### `claude_code` parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `prompt` | `string` | yes | The prompt to send to Claude Code |
| `timeout_ms` | `integer` | no | Timeout in ms (default: 300 000 / 5 minutes) |

Any additional `tools/call` arguments are ignored (for example `model` or `model_reasoning_effort`).

Claude calls run with `--output-format json`; the server parses the JSON payload and returns the assistant `result` text (or an MCP error if `is_error=true`).

### `gemini` parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `prompt` | `string` | yes | The prompt to send to Gemini CLI |
| `sandbox` | `boolean` | no | Run in sandbox mode (`-s` flag, default: false) |
| `timeout_ms` | `integer` | no | Timeout in ms (default: 300 000 / 5 minutes) |

Any additional `tools/call` arguments are ignored (for example `model` or `model_reasoning_effort`).

### `codex` (pass-through)

The codex provider passes through to Codex's native MCP server (`codex mcp-server`)
using `-c key=value` config overrides:

| CLI Flag | Default | Codex config key |
|----------|---------|-----------------|
| `--model` | `gpt-5.3-codex` | `model` |
| `--model_reasoning_effort` | `high` | `model_reasoning_effort` |

Hardcoded defaults: `sandbox_mode=read-only`, `approval_policy=never` (safe for MCP server mode).

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

Optional Gemini sandbox mode in `.mcp.json`:

```json
{
  "mcpServers": {
    "gemini": {
      "command": "mcp-agents",
      "args": ["--provider", "gemini", "--sandbox", "true"]
    }
  }
}
```

Override codex defaults at server startup (not via `tools/call` arguments):

```json
{
  "mcpServers": {
    "codex": {
      "command": "mcp-agents",
      "args": ["--provider", "codex", "--model", "gpt-5.3-codex", "--model_reasoning_effort", "medium"]
    }
  }
}
```

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

Optional Gemini sandbox mode in Codex config:

```toml
[mcp_servers.gemini]
command = "mcp-agents"
args = ["--provider", "gemini", "--sandbox", "true"]
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

The server includes a keepalive timer to prevent Node.js from exiting prematurely when stdin reaches EOF before the async subprocess registers an active handle.

## License

MIT
