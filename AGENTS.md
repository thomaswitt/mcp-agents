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

## Local Install

```sh
npm install && npm link
```

## Critical: stdout is MCP-only

NEVER write to stdout in server mode — it's the MCP JSON-RPC transport. Use `logErr()` (writes to stderr) for all logging. `console.log` is only safe in `printHelp()` / `parseArgs()` which call `process.exit()` before the server starts.

## Gotchas

- `package.json` must stay in the `files` array — the server reads it at runtime for `VERSION`
- Child process stdin must be closed immediately (`child.stdin?.end()`) or the CLI hangs waiting for EOF
- The `keepAlive` interval prevents premature exit when stdin EOF arrives before async handlers complete
- `engines` requires `>=18` — avoid Node-version-specific syntax like import assertions
- The Codex tools expose closed wrapper-owned schemas. `codex` requires `prompt`, an **absolute** `cwd`, and `sandbox`, with optional `model` (`gpt-5.6-sol|gpt-5.6-terra`), `model_reasoning_effort` (`medium|high|xhigh|max`), and `goal`; omitted selectors use the server defaults (`gpt-5.6-sol|xhigh`). `codex-reply` requires `prompt` and nonblank `threadId`, with optional `goal`. `additionalProperties` is false. Other models, raw `config`, `approval-policy`, direct developer/base/compact instructions, reply model/sandbox/cwd/effort, missing fields, and malformed values are rejected locally with redacted JSON-RPC `-32602` responses and never reach Codex. Approval policy is server-owned (`never` by default, startup-overridable)
- The isolated Codex config always includes `[sandbox_workspace_write] network_access`, defaulting to `true` so workspace-write sessions can reach local services. Operators can change it server-wide with `--codex-workspace-network=true|false` or `MCP_AGENTS_CODEX_WORKSPACE_NETWORK_ACCESS` (CLI wins); it MUST stay out of per-call schemas. Enabled means general outbound access because Codex has no localhost-only toggle, while filesystem writes remain workspace-bounded. The table is ignored by read-only and danger-full-access sessions
- The isolated Codex config selectively mirrors Fast mode only when the source `$CODEX_HOME/config.toml` explicitly contains both top-level `service_tier = "fast"` and `[features].fast_mode = true`. The conservative reader fails closed to Standard mode and MUST NOT inherit unrelated settings or MCP servers. The opt-in is read once at bridge startup
- `transformCodexToolCall` only receives already-validated calls. It preserves the curated initial-session native `model`, translates wrapper effort to native `config.model_reasoning_effort`, and strips/injects wrapper-only `goal`: initial goals become native `developer-instructions`, while reply goals become prompt reminders. Codex's native `/goal` is TUI-only. Accepted frames with nothing to transform (notably a goal-free `codex-reply`) MUST remain byte-for-byte unchanged. The stdin pump therefore buffers raw bytes and splits only on newline byte `0x0a`
- The **OUTBOUND** path replaces the native `codex`/`codex-reply` input schemas in a `tools/list` RESPONSE with the exact curated contracts while preserving other tool metadata. This remains a **contained latch**: steady state stays a raw byte-for-byte forwarder (`forwardChunk`); only while a `tools/list` request id is outstanding does it buffer-and-rewrite that response (`flushRewriteBuf`), then return to raw. `observeOutgoing` runs on ORIGINAL bytes and remains the sole authority for native in-flight/watchdog tracking. Invariants covered by stub tests: non-`tools/list` frames stay byte-for-byte; every complete buffered frame flushes even under backpressure; oversized frames forward raw; a mode-boundary straddle raw-skips the orphan tail; finalize recovers complete unterminated frames; every finalize write is guarded
- Locally generated `-32602` responses use the same frame-safe generated queue as progress/recovery frames: never splice them into a partial native frame, reserve request IDs until the response is queued to stdout, drop an undelivered response on cancellation, and swallow cancellation while the local response is queued or recently delivered. Invalid calls never reach native Codex
- **A per-request fault MUST NOT be resolved with a process-level teardown.** `finalize()` kills every other in-flight request, every background job, and the isolated `CODEX_HOME` — which holds Codex's `sessions/`, so every `threadId` in the process becomes permanently unresumable (`codex-reply` → `Session not found for thread_id`). Timeouts (`abortRequestNoTeardown`) and cancellations (`onCancelGraceExpired`) therefore settle the single request locally and suppress Codex's late response. The ONLY per-request condition that may still escalate to teardown is a stream wedged mid-frame with no safe boundary to inject a frame at, and it retries once before doing so. `cancelGraceMs` (`--codex_cancel_grace`, `MCP_AGENTS_CODEX_CANCEL_GRACE_MS`, default 30s) must stay generous: a Codex mid-turn does not service MCP cancellation promptly, and a short grace turns the escalation path into the default path
- Abandoning a request does NOT stop Codex — the turn keeps running with `sandbox_mode=workspace-write` and can still write to the workspace long after the client gave up (the "zombie writer"). `noteAbandonedTurn`/`noteAbandonedTurnSettled` exist purely so this is greppable on stderr rather than inferred from a surprising diff. Background jobs make it worse: a `codex-start` job lives in the bridge's job table, NOT in the client's task registry, so a harness "stop task" cannot reach it — only `codex-cancel` with its `jobId` can. Because a job is polled through this process, it can never survive a reconnect usefully, so client stdin EOF cancels every non-terminal job and open request and a bounded wind-down (`MCP_AGENTS_CODEX_CLIENT_GONE_GRACE_MS`) reaps the group if Codex keeps working anyway
- The isolated Codex home copies `auth.json` AND `models_cache.json` from the real `CODEX_HOME`; without the cache every bridge start is a cold Codex install that re-fetches ~280 KB. Homes left by bridges that died without cleanup are swept at startup (`sweepStaleCodexHomes`, 12h) — each holds a copy of `auth.json`

## Testing

`test.sh` uses bash helpers that pipe JSON-RPC to the server over stdio. CLI flag tests (`test_cli_flag`, `test_cli_error`) run first, then protocol tests. All tests use `timeout`/`gtimeout` to cap execution since the keepAlive timer prevents natural exit.

## Changelog

Maintain `CHANGELOG.md` following [Keep a Changelog](https://keepachangelog.com/) format. Every user-facing change must have an entry before release.

## Releasing a New Version

1. Update version in `package.json`
2. Add entry to `CHANGELOG.md`
3. Run `npm install` to sync `package-lock.json`
4. Run tests: `SKIP_INTEGRATION=1 ./test.sh`
5. Commit: `git commit -m "<see commit message instructions below"`
6. Tag: `git tag -a v0.x.y -m "v0.x.y"`
7. Push: `git push --follow-tags` (only allowed manually)
8. Publish: `npm publish` (only allowed manually)

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
