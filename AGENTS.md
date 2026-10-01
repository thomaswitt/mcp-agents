# mcp-agents

MCP server that wraps AI CLI tools (Claude Code, Gemini CLI, Codex CLI) as MCP tools for any MCP client.

## Architecture

The primary ESM server lives in `server.js`; there is no build step or
transpilation. `CLI_BACKENDS` defines the blocking Claude/Gemini commands,
while browser and the default Codex provider have dedicated proxy/adapter
runtimes. The deprecated native MCP implementation is sealed in
`codex-legacy.js` and loaded only for `--provider codex-legacy`, making its
eventual removal one explicit provider/module boundary. Version is read from
`package.json` at runtime via `readFileSync` (not import assertions — the syntax
shifted across Node versions and the runtime read sidesteps that entirely).

## Commands

```sh
# Run server
node server.js --provider claude   # or: gemini, codex (default), codex-legacy

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

`.tool-versions` pins the checkout's Node for mise. `npm link` puts `mcp-agents`
in the *active* Node's global prefix, so switching Node versions orphans the
link — re-run `npm link` if `mcp-agents` disappears from `$PATH`.

## Critical: stdout is MCP-only

NEVER write to stdout in server mode — it's the MCP JSON-RPC transport. Use `logErr()` (writes to stderr) for all logging. `console.log` is only safe in `printHelp()` / `parseArgs()` which call `process.exit()` before the server starts.

## Gotchas

- `package.json` must stay in the `files` array — the server reads it at runtime for `VERSION`
- Child process stdin must be closed immediately (`child.stdin?.end()`) or the CLI hangs waiting for EOF
- The `keepAlive` interval prevents premature exit when stdin EOF arrives before async handlers complete
- `engines` requires `>=26` — raised in 0.28.0 so the browser provider's downstream floor is always satisfied. Older providers ran on 18; do not reintroduce a lower floor without checking `chrome-devtools-mcp`
- `codex` and `codex-legacy` are intentionally separate providers with no
  automatic fallback. `codex` owns the App Server migration and all new Codex
  functionality. `codex-legacy.js` must preserve the complete 0.28 native
  `codex mcp-server` behavior while that upstream command remains supported;
  do not partially reimplement it, route it through App Server, or add App
  Server-only tools/state semantics. Removing the legacy provider later must
  be an explicit breaking change
- Keep `codex-legacy.js` self-contained except for its narrow exported runner.
  Deliberate helper duplication is the deletion boundary, not an invitation to
  couple legacy framing/auth/job behavior back into the App adapter. Its
  private homes remain under `${STARTUP_CWD}/tmp/codex-homes/` for exact
  compatibility; do not silently move them into App durable state
- The `codex` provider is a wrapper-owned MCP server over the documented, version-gated stdio JSONL surface of `codex app-server`; it is NOT a native MCP pass-through. Outer `initialize`, `tools/list`, `ping`, validation, progress, jobs, and local state tools must stay independent of child availability. Never forward raw App Server frames to MCP stdout and never initialize with `experimentalApi`
- Codex tools expose closed wrapper-owned schemas. `codex` requires `prompt`, an **absolute** `cwd`, and `sandbox`, with optional curated model/effort, `allow_subagents`, and native `goal`; `codex-reply` requires `prompt` plus nonblank `threadId`. App Server config/filesystem methods, raw instructions, providers, reply execution settings, and per-call approval policy remain hidden. Validation errors are redacted MCP `-32602` responses and never reach App Server
- App Server children are lazy and generation-scoped. Every pending native request, interaction, and turn carries its generation; late frames from a dead generation are ignored. A child exit rejects already-dispatched turns as `codex_outcome_unknown`, records that state in the sidecar, and NEVER replays them. Only a later safe operation may spawn the next generation
- Completion authority is the stable `turn/completed` notification plus completed `agentMessage` / `exitedReviewMode` items. Deltas are presentation-only. Preserve exactly one MCP result, retain the durable `threadId`, and treat `interrupted` / `failed` as errors even if partial agent text exists
- Durable Codex state is external and project-scoped at `${XDG_STATE_HOME:-$HOME/.local/state}/mcp-agents/codex/projects/<sha256(canonical STARTUP_CWD)>/v1` unless overridden. The allowlist is `sessions/`, `archived_sessions/`, native `thread-writer-locks/`, the native goal store, wrapper `leases/`, retention metadata, and content-free `bridges/` sidecars. Reject roots inside the served workspace, set umask `0077`, and keep directories `0700` / files `0600`
- `owner.json` and `active-turns.json` are the external liveness contract. They may expose bridge/child PIDs, generation, thread/turn IDs, cwd, sandbox, timestamps, rollout path, and only these states: `starting|active|waiting_for_input|canceling|terminal_undelivered|outcome_unknown`. They MUST NOT contain prompts, commentary, model output, reasoning, command data, or private native request IDs. Write them atomically and fail liveness toward uncertainty
- Wrapper per-thread leases reject a live OR uncertain competing owner and recover only a PID-proven-dead stale lease. Codex's native writer-lock directory is shared unchanged; do not delete its lock files manually. Turns, reviews, goals, forks, and archive operations on one thread must not race across bridge processes
- Sessions and archived sessions persist across bridge reconnects. App Server initialization gets a 300-second default budget, overridable through `MCP_AGENTS_CODEX_APP_INIT_TIMEOUT_MS`, to build each generation's private state database. A blank override is unset, invalid values warn and use the default, and zero produces the native request minimum of one millisecond. User-facing thread listing must pass `useStateDbOnly: true` with source kinds `vscode`, `appServer`, and `subAgentReview`; bare `codex app-server` defaults `--session-source` to `vscode`, while `appServer` preserves explicitly MCP-labelled sessions. App Server can collapse private state-database failures into empty state-only pages, so listings must disclose that ambiguity and must not fall back to rescanning session files. Retention keeps its filesystem-backed `appServer` / `subAgentReview` source scope and must not select ordinary `vscode` wrapper threads until native deletion can prove it will not cascade into newer spawned or reverted history. Retention defaults to 30 days, runs at startup and daily, and may delete only an inactive, confidently owned old thread after goal cleanup and native `thread/delete`; live or uncertain bridges, leases, sidecars, malformed retention-journal entries, and partial failures must defer deletion. Background job records remain connection-local
- Native goals use `thread/goal/set|get|clear`, not prompt injection. On POSIX, share only the documented `goals_1.sqlite`, `goals_1.sqlite-wal`, and `goals_1.sqlite-shm` files into isolated `CODEX_SQLITE_HOME`; all other SQLite state remains generation-private. The README owns this compatibility assumption. Preserve SQLite's proven main-DB symlink behavior and validate/chmod the canonical goal DB, WAL, and SHM opportunistically. Durable native goals remain unsupported on Windows
- App Server approvals and structured questions are server-initiated JSON-RPC requests. Approval policy stays server-owned (`never` by default); unexpected approvals under `never` interrupt the turn. Use wrapper interaction IDs, reject secret questions without queueing/logging, resolve once, and cap waiting by the lesser of ten minutes and the turn's remaining hard deadline. Foreground MCP elicitation is allowed only when the client advertises form elicitation; background work falls back to `codex-interactions` / `codex-interaction-resolve`
- `codex-peek` is strictly read-only with respect to observed turns: it starts nothing, arms no observed-turn timer, never returns prompts/model output/commentary or private native IDs, and never converts unknown into absent. A `cwd` filter reports rather than hides a row whose workspace is unknown. The App Server child is multiplexed, so a process-table search cannot prove a particular turn finished
- Native subagents are OFF by default and session-scoped. `allow_subagents: true` enables only Codex's in-process multi-agent gates for that initial thread; replies inherit it. The isolated config still strips the user's external MCP servers and custom roles, so enabled subagents cannot re-enter this bridge or reach Claude/Gemini through them; a trusted project's own `.codex/config.toml` MCP servers are a separate layer and still load per thread. They share the thread sandbox and approval policy, so shared-workspace concurrency remains the caller's risk
- Isolated `CODEX_HOME` / `CODEX_SQLITE_HOME` generations copy `auth.json` and `models_cache.json`, selectively mirror explicit Fast mode and all explicit project trust decisions, and keep unrelated config, MCP servers, logs, and general SQLite state private. Each generation re-reads the source config's `projects.<path>.trust_level` entries, preserving both `trusted` and `untrusted` with native path matching and no trust write-back. Missing config adds no trust; unreadable or invalid config refuses child startup with a redacted `codex_app_server_unavailable` error while MCP discovery stays available. Within `CODEX_SQLITE_HOME`, only the native goal DB/WAL/SHM symlink targets are durable; sessions, archived sessions, and writer locks are linked separately under `CODEX_HOME`. Auth write-back stays conflict-guarded; invalidated, unchanged, or canonically superseded auth must not overwrite the user's current login
- Threads are released with `thread/unsubscribe`; App Server otherwise keeps every subscribed thread loaded for its whole life, with that thread's MCP servers, background terminals, and code-mode session running. Every subscribing request (start, resume, fork, detached review) marks the thread held; the fast path releases it after its work (turn completed, setup failure after start/resume, fork) and a periodic sweep re-checks the rest. Never unsubscribe while an in-process operation owns the thread (active or provisional turn), while Codex runs a native turn on it (`turn/started`/`turn/completed`/`thread/status/changed`), or while its goal is `active` and it has been idle less than the grace period; do the final checks and the unsubscribe write in one synchronous step so a later resume queues behind it in Codex's per-thread order. Never touch trust entries to fix lifetimes: an `untrusted` project skips its AGENTS.md. Before an active goal, `codex-goal-set` runs one non-loading `thread/read` when serving HTTP or when the thread was released: over HTTP it checks containment before any resume, and for a released thread it re-subscribes only if Codex still has it loaded. A thread counts as released-but-loaded only until a confirmed resume, a `notLoaded` answer from `thread/unsubscribe` or `thread/read`, `thread/closed`, archive, retention delete, or a failed unsubscribe being queued for retry. Every resume attempt holds its thread before it is sent and again after it fails (a racing `thread/closed` drops the hold, and a canceled attempt may still subscribe); resumes retry the transient `is closing` refusal. Canceled `thread/start`/`review/start`/`thread/resume` requests, and timed-out resumes, record a late answer's thread via `onLateResult` (consumed on the first answer; kept past the cancel grace or timeout until one arrives); a timed-out start or review terminates its generation instead. Threads started with `allow_subagents` are never released
- Cancellation maps to `turn/interrupt` and remains best-effort: settling a request is not proof a write-capable turn stopped. Per-request faults must not tear down sibling turns. Client EOF cancels connection-local jobs/open turns and boundedly reaps the App Server group, while durable sessions remain resumable

## Testing

`test.sh` uses bash helpers that pipe JSON-RPC to the server over stdio. CLI flag tests (`test_cli_flag`, `test_cli_error`) run first, then protocol tests. The sourceable `test-codex-legacy.sh` fragment owns the complete frozen native MCP regression suite; removing the provider means removing that fragment as one unit. All tests use `timeout`/`gtimeout` to cap execution since the keepAlive timer prevents natural exit.

## Changelog

Maintain `CHANGELOG.md` following [Keep a Changelog](https://keepachangelog.com/) format. Every user-facing change must have an entry before release.

## Releasing a New Version

1. Update version in `package.json`
2. Add entry to `CHANGELOG.md`
3. Run `npm install` to sync `package-lock.json`
4. Run tests: `SKIP_INTEGRATION=1 ./test.sh`
5. Commit: `git commit -m "<see commit message instructions below"`
6. Tag: `git tag -a v0.x.y -m "v0.x.y"`
7. Verify the worktree is clean and the tag points at `HEAD`, then rerun
   `SKIP_INTEGRATION=1 ./test.sh` on that exact release commit
8. Push: `git push --follow-tags` (only allowed manually)
9. Publish: `npm publish` (only allowed manually)

## Style

- Follow existing patterns in `server.js` — switch statements for CLI parsing, Promise wrappers for child_process
- Keep new implementation in `server.js` unless there is a strong reason to
  split it. `codex-legacy.js` is the deliberate compatibility/deletion boundary,
  not a general second home for shared features

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
