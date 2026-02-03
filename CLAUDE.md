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

## Changelog

Maintain `CHANGELOG.md` following [Keep a Changelog](https://keepachangelog.com/) format. Every user-facing change must have an entry before release.

## Releasing a New Version

1. Update version in `package.json`
2. Add entry to `CHANGELOG.md`
3. Run `npm install` to sync `package-lock.json`
4. Run tests: `SKIP_INTEGRATION=1 ./test.sh`
5. Commit: `git commit -m "0.x.y"`
6. Tag: `git tag v0.x.y`
7. Push: `git push && git push --tags`
8. Publish: `npm publish` # needs to be done manually due to 2FA

## Style

- Follow existing patterns in `server.js` — switch statements for CLI parsing, Promise wrappers for child_process
- Keep everything in `server.js` unless there's a strong reason to split

## Commit Messages

When committing, generate the commit message by running `git diff --cached` on all staged files and applying the following prompt to the diff output:

```
TASK: Create a Git commit message in the following format:

INSTRUCTIONS:
- Use "Conventional Commits" (https://www.conventionalcommits.org/)
   - PR titles follow `[CATEGORY] short description` where CATEGORY is
     `[FIX]`, `[FEATURE]`, `[REFACTOR]`, `[TEST]`, `[DEPLOY]`, `[PERF]`,
     `[DOCS]`
   - First line should be limited to 50 chars, no trailing punctuation
   - Only the FIRST verb MUST be ALL-CAPS and in [SQUARE BRACKETS], the
     rest of the summary is normal case
   - You MUST indicate breaking changes or required migrations in the
     first line
   - Add a blank line afterwards
- All the following should provide information about the what and why of the changes:
   - Use bullet points
   - Wrap lines at 72 chars
   - Use imperative mood, present tense, active voice
   - If changes are self-explanatory, skip them
   - Do NOT mention comment changes or lockfile/Gemfile updates
   - Do NOT mention that test coverage has been added for the changes
   - Do NOT mention file additions/removals in comments
   - Keep it as SHORT and as CONCISE as possible
   - Do NOT include your own attribution
```
