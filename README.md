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

## Quick test

```bash
# Default provider (codex)
npx mcp-agents

# Specific provider
npx mcp-agents --provider claude
npx mcp-agents --provider gemini
npx mcp-agents --provider gemini --sandbox false
```

The server speaks [JSON-RPC over stdio](https://modelcontextprotocol.io/docs/concepts/transports#stdio). It prints `[mcp-agents] ready (provider: <name>)` to stderr when it's listening.

## Providers & Tools

Each `--provider` flag maps to a single exposed tool:

| Provider | Tool name | CLI command |
|----------|-----------|-------------|
| `claude` | `claude_code` | `claude -p <prompt>` |
| `gemini` | `gemini` | `gemini [-s] -p <prompt>` |
| `codex` | *(pass-through)* | `codex mcp-server` |

### `claude_code` parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `prompt` | `string` | yes | The prompt to send to Claude Code |
| `timeout_ms` | `integer` | no | Timeout in ms (default: 120 000) |

### `gemini` parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `prompt` | `string` | yes | The prompt to send to Gemini CLI |
| `sandbox` | `boolean` | no | Run in sandbox mode (`-s` flag, default: false) |
| `timeout_ms` | `integer` | no | Timeout in ms (default: 120 000) |

### `codex` (pass-through)

The codex provider passes through to Codex's native MCP server (`codex mcp-server`)
with configurable flags:

| CLI Flag | Default | Codex flag |
|----------|---------|------------|
| `--model` | `gpt-5.3-codex` | `-m <model>` |
| `--model_reasoning_effort` | `high` | `-c model_reasoning_effort=<value>` |

Hardcoded defaults: `-s read-only -a never` (safe for MCP server mode).

## Integration with Claude Code

Add entries to your project's `.mcp.json`:

```json
{
  "mcpServers": {
    "codex": {
      "command": "npx",
      "args": ["-y", "mcp-agents@latest", "--provider", "codex"]
    },
    "gemini": {
      "command": "npx",
      "args": ["-y", "mcp-agents@latest", "--provider", "gemini", "--sandbox", "false"]
    }
  }
}
```

Override codex defaults:

```json
{
  "mcpServers": {
    "codex": {
      "command": "npx",
      "args": ["-y", "mcp-agents@latest", "--provider", "codex", "--model", "o3-pro", "--model_reasoning_effort", "medium"]
    }
  }
}
```

## Integration with OpenAI Codex

Add two entries to `~/.codex/config.toml` — one per provider you want available:

```toml
[mcp_servers.claude-code]
command = "npx"
args = ["-y", "mcp-agents", "--provider", "claude"]

[mcp_servers.gemini]
command = "npx"
args = ["-y", "mcp-agents", "--provider", "gemini", "--sandbox", "false"]
```

Then in a Codex session you can call the `claude_code` or `gemini` tools, which shell out to the respective CLIs.

## How it works

1. An MCP client connects over stdio
2. The server reads `--provider <name>` from its argv (defaults to `codex`)
3. It registers a single tool matching that provider's CLI
4. Client calls `tools/call` with the tool name and a `prompt`
5. The server runs the CLI as a child process and returns stdout (or stderr) as the tool result

The server includes a keepalive timer to prevent Node.js from exiting prematurely when stdin reaches EOF before the async subprocess registers an active handle.

## License

MIT
