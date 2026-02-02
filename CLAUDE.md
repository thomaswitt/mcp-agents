# mcp-agents

MCP server that wraps AI CLI tools (Claude Code, Gemini CLI, Codex CLI) as MCP tools for any MCP client.

## Architecture

Single-file server (`server.js`) — ESM, no build step, no transpilation. The `CLI_BACKENDS` object defines all providers; adding a new backend means adding one entry there. Version is read from `package.json` at runtime via `readFileSync` (not import assertions — those differ between Node 18 and 22+).

## Commands

```sh
# Run server
node server.js --provider claude   # or: gemini, codex (default)

# Tests (fast, no real CLI calls)
SKIP_INTEGRATION=1 ./test.sh

# Tests (full, calls real CLIs — requires claude/gemini/codex installed)
./test.sh

# Verify CLI flags
node server.js --help
node server.js --version
```

## Critical: stdout is MCP-only

NEVER write to stdout in server mode — it's the MCP JSON-RPC transport. Use `logErr()` (writes to stderr) for all logging. `console.log` is only safe in `printHelp()` / `parseArgs()` which call `process.exit()` before the server starts.

## Gotchas

- `package.json` must stay in the `files` array — the server reads it at runtime for `VERSION`
- Child process stdin must be closed immediately (`child.stdin?.end()`) or the CLI hangs waiting for EOF
- The `keepAlive` interval prevents premature exit when stdin EOF arrives before async handlers complete
- `engines` requires `>=18` — avoid Node-version-specific syntax like import assertions

## Testing

`test.sh` uses bash helpers that pipe JSON-RPC to the server over stdio. CLI flag tests (`test_cli_flag`, `test_cli_error`) run first, then protocol tests. All tests use `timeout`/`gtimeout` to cap execution since the keepAlive timer prevents natural exit.

## Style

- Follow existing patterns in `server.js` — switch statements for CLI parsing, Promise wrappers for child_process
- Keep everything in `server.js` unless there's a strong reason to split
- Use conventional commits: `feat:`, `fix:`, `docs:`, etc.
