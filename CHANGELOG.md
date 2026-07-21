# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.20.0] - 2026-07-21

### Changed

- A Codex per-request idle or hard timeout now fails **only** the stalled
  `tools/call` (JSON-RPC `-32001`) and keeps the bridge connected, instead of
  tearing down the whole process. A stdio transport close makes MCP clients such
  as Claude Code mark the server `failed` and permanently unregister every
  `mcp__codex__*` tool for the rest of the session, so a single stalled review no
  longer takes the entire Codex bridge down with it. The stalled call's late
  native response is suppressed, Codex is sent a `notifications/cancelled` for
  that request so it stops working, and the Codex process group is still reaped on
  a genuine teardown (client disconnect, signal, or `stdout` `EPIPE`). The lone
  exception is a Codex wedged partway through a response frame that also ignores
  the cancellation: with no safe boundary to inject the error, the wrapper
  escalates to a bounded whole-bridge teardown after the cancel grace. The
  immutable `--timeout` hard deadline always bounds a request, even mid-teardown.

### Documentation

- Recommend a globally installed `mcp-agents` binary (or an absolute
  `node server.js` path) over `npx -y mcp-agents@latest`, which resolves against
  the npm registry on every launch — including reconnects — and can drop the
  tools mid-session on a slow, offline, or stale-cached (`ETARGET`) resolution.

## [0.19.0] - 2026-07-17

### Changed

- Selectively mirror an explicit source Codex Fast-mode opt-in into isolated
  bridge sessions without inheriting unrelated configuration or MCP servers

## [0.18.0] - 2026-07-16

### Added

- Enable network access by default for workspace-write Codex bridge sessions so
  sandboxed commands can reach local development services
- Add the server-owned `--codex-workspace-network=true|false` option and
  `MCP_AGENTS_CODEX_WORKSPACE_NETWORK_ACCESS` environment variable; keep the
  setting out of per-call tool schemas

### Security

- Document that workspace-write network access permits general outbound egress,
  while filesystem writes remain restricted to the workspace

## [0.17.0] - 2026-07-16

### Added

- Let new Codex sessions select `gpt-5.6-sol` or the faster
  `gpt-5.6-terra`, plus `medium`, `high`, `xhigh`, or `max` reasoning;
  keep `gpt-5.6-sol` at `xhigh` as the server default and make replies inherit
  both choices
- Add optional `codex-start` and `codex-reply-start` background calls with
  connection-local status, commentary, paged result, and cancellation tools
- Make background progress available as ordinary MCP tool results so parent
  agents can poll and relay Codex work without depending on UI rendering of
  progress notifications

### Security

- Keep native background request IDs and correlated event frames private while
  allowing blocking Codex calls to continue on the same transport
- Expose only explicitly attributed commentary, strip unsafe terminal controls,
  and bound retained commentary, result capture, pagination, active jobs, and
  record lifetime

## [0.16.0] - 2026-07-15

### Changed

- **Migration:** Replace Codex's broad config-shaped tool schemas with closed,
  curated contracts. New `codex` calls require `prompt`, an absolute `cwd`, an
  explicit `sandbox`, and `model_reasoning_effort` (`xhigh` or `max`), with
  optional `goal`; replies require `prompt` and nonblank `threadId`, with
  optional `goal`
- Reject unsupported, missing, and malformed Codex arguments locally with a
  redacted JSON-RPC `-32602` response instead of silently stripping fields or
  forwarding them to native Codex. Raw model/config/instruction fields and
  per-call approval-policy overrides are no longer accepted
- Keep approval policy server-owned with the non-interactive `never` default;
  operators can still change it at startup with `--approval_policy`

### Fixed

- Queue local validation errors at safe native frame boundaries, reserve their
  request IDs until delivery, and let cancellation remove an undelivered local
  response without forwarding the invalid call or cancellation to Codex

## [0.15.0] - 2026-07-13

### Changed

- Replace generic Codex event-name progress with fail-closed live status:
  explicitly attributed commentary, active plan steps, and redacted lifecycle
  summaries are emitted immediately and then coalesced to at most once per
  second
- Emit 10-second silence notices for progress-aware clients without refreshing
  the wrapper's own idle or hard deadlines. Pending progress stays bounded to
  the latest frame per request and waits for a safe native frame boundary
- Clear queued progress, silence/coalescing timers, and commentary buffers on
  every request settlement, terminal-grace, cancellation, timeout, and teardown
  path

## [0.14.0] - 2026-07-12

### Added

- Send throttled MCP `notifications/progress` for active Codex calls when the
  caller supplied `_meta.progressToken`; the bridge uses that exact token and
  never invents one. Progress prevents client-side idle expiry but does not
  extend a client's separate hard wall-clock tool timeout
- Capture a Codex thread ID from the early request-correlated session event and
  retain the terminal agent message. If the native final response does not
  arrive within its grace period, synthesize the equivalent successful
  `tools/call` result with `structuredContent.threadId` and suppress a matching
  late response so the caller still receives exactly one result

### Changed

- Replace the global Codex idle watchdog with per-call liveness tracking.
  `--codex_idle_timeout` is now refreshed only by activity correlated through
  the request's `_meta.requestId`; stderr, pings, unrelated client traffic, and
  another call's events can no longer hide a stalled request
- Enforce `--timeout` for Codex as an immutable per-call hard deadline (default
  two hours), independent of correlated progress and the idle watchdog
- Set the tracked Claude project MCP timeout above the Codex bridge deadline so
  the client does not preempt the wrapper's own terminal/error recovery
- Give cancellation a short, non-resettable grace period. A Codex child that
  does not settle is killed and reaped, other open calls receive one teardown
  error, and the wrapper exits so the MCP client can reconnect cleanly. The
  canceled call is never replayed
- Document the legacy recovery boundary: the wrapper does not respawn
  `codex mcp-server` inside the existing stdio connection, and old
  `codex-reply` threads cannot survive a child teardown. Durable thread replay
  and same-connection recovery require a future `codex app-server` adapter

## [0.13.0] - 2026-07-10

### Added

- Let callers select `xhigh` or `max` reasoning effort with a top-level
  `model_reasoning_effort` argument when creating a Codex session. Omitting it
  inherits the server-configured default (`xhigh` by default); replies inherit
  the session choice and cannot change it. Raw `config` effort overrides remain
  stripped, and `ultra` is intentionally unavailable through the selector

### Changed

- Raise the Claude provider's default call timeout from 5 to 15 minutes so
  Opus `xhigh` repository reviews can finish; per-call `timeout_ms` and the
  server-wide `--timeout` override remain available. The Codex integration
  example now gives each outer MCP call 60 seconds of return headroom
- **Migration:** Existing Claude MCP operators must change
  `tool_timeout_sec = 300` to `tool_timeout_sec = 960` in
  `~/.codex/config.toml` and restart Codex; otherwise the outer client still
  cancels Claude calls after 5 minutes

## [0.12.6] - 2026-07-09

### Changed

- Update the default Codex model from `gpt-5.5` to `gpt-5.6-sol` while keeping
  the reasoning effort at `xhigh`

## [0.12.5] - 2026-07-09

### Fixed

- Persist a rotated Codex `auth.json` from the isolated pass-through home back to
  the real `CODEX_HOME` on teardown. Codex rotates its OAuth refresh token in
  place, but the isolated home only copied auth in and was deleted on exit, so
  the canonical `auth.json` kept a stale refresh token and subsequent spawns (or
  any parallel Codex client) failed with "refresh token already used / revoked"
  until a manual `codex login`. The write-back is atomic (exclusive same-dir
  temp + rename) and no-ops when auth is unchanged or absent (API-key mode)

## [0.12.4] - 2026-07-06

### Changed

- Harden the codex pass-through isolated runtime by keeping web search in cached
  mode while disabling update checks, login shells, history persistence, hooks,
  and skill MCP dependency installation in the generated Codex config

## [0.12.3] - 2026-07-03

### Added

- Add `npm run bench:mcp-startup` to measure global-install and `npx` MCP
  startup paths through real `/tmp` project `.mcp.json` files

### Changed

- Clarify that `npx` affects MCP startup/reconnect behavior, not tool-call
  latency once the server is already running

## [0.12.2] - 2026-07-01

### Changed

- The codex pass-through isolated runtime now disables Codex app/plugin
  surfaces by default, keeping bridged sessions aligned with lean local Codex
  defaults and avoiding unrelated plugin skill context in focused coding
  workflows

## [0.12.1] - 2026-06-29

### Added

- The codex pass-through now advertises the per-call `goal` argument in its
  `tools/list` response: it rewrites only the `codex` and `codex-reply` tool
  schemas to declare an optional `goal` property, so a client's model knows it
  can pass one (models only emit arguments declared in `inputSchema.properties`).
  Without this, the `goal` argument added in 0.12.0 was reachable only when a
  caller was explicitly told to send it. `goal` is still stripped inbound before
  reaching Codex; only `properties` is touched (`required` and
  `additionalProperties` are left intact, so Codex's strict `codex` schema stays
  valid). The native `/goal` subsystem remains unreachable over MCP, so this is
  still discoverability for the developer-instructions/prompt-reminder injection,
  not Codex's goal-lifecycle subsystem

### Fixed

- The rewrite is a "contained latch": the pass-through stays a byte-for-byte raw
  forwarder and only buffers/rewrites while a `tools/list` request is in flight,
  then returns to raw. Observation of codex stdout still runs on the original
  bytes and remains the sole authority for in-flight/idle-watchdog tracking;
  backpressure, oversized frames, mode-boundary straddles, and the synthetic
  `-32001` teardown path are all preserved (every complete frame is flushed so
  none is stranded under backpressure)

## [0.12.0] - 2026-06-29

### Added

- Goal injection for the codex pass-through: give Codex a persistent objective
  via a server-wide `--goal "<text>"` default or a per-call `goal` argument on
  `tools/call`. Codex's native `/goal` is a TUI-only slash command that is not
  reachable through `codex mcp-server` (prefixing an MCP prompt with `/goal …`
  does nothing), so the objective is injected the MCP-correct way: into Codex's
  native `developer-instructions` field (a developer-role message that persists
  thread-wide, so `codex-reply` turns inherit it) for the initial `codex` call,
  merged ahead of any caller-supplied developer instructions; and as a concise
  prompt reminder for a `codex-reply` turn, which has no `developer-instructions`
  field. The wrapper-only `goal` arg is always stripped before reaching Codex (it
  has no `goal` in its schema); a per-call string `goal` overrides the `--goal`
  default (an empty string suppresses it; a non-string value is ignored).
  Injection counts as a mutation, so a `tools/call` with no goal change is still
  forwarded byte-for-byte

## [0.11.0] - 2026-06-26

### Added

- Idle watchdog for the codex pass-through (`--codex_idle_timeout <secs>`,
  default 600, `0` disables). If codex emits nothing while a request is in
  flight for that long, the wrapper synthesizes a JSON-RPC error (`-32001`) for
  the open request(s), kills codex's process group, and exits — converting an
  unbounded post-completion stall into a surfaced error instead of an infinite
  hang. The watchdog resets on any codex stdout/stderr or inbound client
  activity and is suspended while the client backpressures stdout, so healthy
  long or interactive runs are not killed

### Fixed

- The codex pass-through now exits (synthesizing an error for any open request)
  when codex dies or fails to spawn, instead of leaving a childless wrapper
  alive on the client's open stdin — a second way the caller's `tools/call`
  could hang forever
- codex stdout is now piped and forwarded byte-for-byte (was inherited) so the
  wrapper can observe responses for the watchdog; codex now runs in its own
  process group and is torn down group-wide so a stalled codex (and any
  descendants) is never orphaned

## [0.10.2] - 2026-06-17

### Changed

- Normalize `package.json` `bin` (`./server.js` → `server.js`) and
  `repository.url` to npm's canonical forms so `npm publish` no longer emits
  manifest auto-correction warnings. No runtime change — the published `bin`
  already resolved to `server.js`

## [0.10.1] - 2026-06-17

### Fixed

- Parse the `claude` backend's `--output-format json` when it is an array of
  stream events (Claude CLI 2.1.x) rather than a single `{type:"result"}`
  object. The old parser only handled the object form and silently fell back to
  forwarding the raw JSON blob, so MCP callers received the whole event log
  instead of the assistant's answer

### Changed

- The live integration tests now assert the real CLI JSON output shape for both
  the `claude` and `codex` backends (and the codex write-probe checks the MCP
  result envelope, not just the written file), emitting an explicit "output
  format may have changed" diagnostic on mismatch so upstream CLI format drift
  is detected instead of silently misparsed

## [0.10.0] - 2026-06-17

### Changed

- The codex pass-through now lets callers control `sandbox`, `cwd`, and
  `approval-policy` per `tools/call` — both the top-level args and the matching
  `config.sandbox_mode` / `config.approval_policy` / `config.cwd` /
  `config.sandbox_workspace_write` keys. Previously the entire `config` object
  was stripped, which silently dropped a caller's per-call sandbox escalation and
  left Codex stuck in the server's `workspace-write` default — surfacing as
  "workspace is read-only / danger-full-access refused". Model and reasoning
  effort stay pinned and cannot be overridden per call

### Security

- Replace the blunt `["model", "config"]` strip list with key-aware stripping
  that removes only the model/effort pin vectors: the top-level `model` arg and,
  inside any `config` override map, `model`, `model_reasoning_effort`, `profile`,
  `profiles`, `model_provider`, `model_providers`, `openai_base_url`,
  `chatgpt_base_url`, `model_catalog_json`. This closes two pin bypasses (a
  `profile`/`profiles` carrying its own model/effort, and provider/base-url
  re-pointing the pinned model name to another backend)

### Fixed

- Buffer the codex pass-through's stdin as raw bytes and split on the newline
  byte (`0x0a`) instead of decoding each read chunk to a string before splitting.
  A multibyte UTF-8 sequence straddling two read chunks could otherwise be
  re-encoded non-byte-for-byte, breaking the byte-for-byte framing guarantee for
  forwarded JSON-RPC frames

## [0.9.0] - 2026-06-09

### Changed

- The codex pass-through now defaults to `sandbox_mode = "workspace-write"`
  (previously hard-coded to `read-only`), so Codex can edit files in its
  workspace by default; `approval_policy` stays `never`
- Both values are now configurable at server startup via the new
  `--sandbox_mode <mode>` and `--approval_policy <policy>` flags instead of
  being hard-coded. Per-call overrides remain stripped (`model`/`config`), so
  the startup configuration still applies to every `tools/call`

## [0.8.0] - 2026-05-31

### Changed

- Pin the `claude` backend to `claude-opus-4-8` at effort `xhigh` by passing `--model claude-opus-4-8 --effort xhigh` to the Claude CLI

### Security

- Strip per-call `model` and `config` arguments from the codex pass-through's `tools/call` requests so a client cannot override the pinned model/effort (or the read-only/never sandbox config) for a single call. Model and effort are now fixed at server startup for all providers

## [0.7.0] - 2026-05-22

### Changed

- The `gemini` provider now spawns Google's Antigravity CLI (`agy`) instead of the legacy `gemini` binary; it runs with `--sandbox -p <prompt>`. The MCP tool name (`gemini`) and `--provider gemini` flag are unchanged
- Antigravity has no `--approval-mode=plan` equivalent, so `--sandbox` (terminal restrictions) is now the only confinement applied
- Bump `@modelcontextprotocol/sdk` from `^1.0.0` to `^1.29.0`

### Fixed

- Run the `agy`/Antigravity backend in an isolated temporary working directory (created per call, removed afterwards) so the agentic CLI cannot create workspace files such as `.antigravitycli/`, edit `.gitignore`, or stage changes in the directory the MCP server was started in

### Security

- Clear all 4 npm audit advisories (1 high, 3 moderate) by pinning patched transitive dependencies via `overrides`: `fast-uri` `^3.1.2`, `hono` `^4.12.22`, `ip-address` `^10.2.0`. These packages belong to the MCP SDK's HTTP transport, which the stdio server never exercises

## [0.6.6] - 2026-04-24

### Changed

- Update the default Codex model from `gpt-5.4` to `gpt-5.5` (reasoning effort stays `xhigh`)
- Refresh README examples and `--help` test assertion to reference `gpt-5.5`

## [0.6.5] - 2026-03-31

### Changed

- Default Codex MCP startup reasoning effort to `xhigh` instead of `high`
- Document native per-call Codex overrides via `config.model_reasoning_effort`
- Run the Codex bridge in an isolated temporary `CODEX_HOME` so it does not inherit external MCP servers from the user's normal Codex config
- Disable Codex multi-agent mode in the bridge runtime to prevent recursive delegation through other LLM-backed tools

## [0.6.0] - 2026-03-31

### Fixed

- Shut down Claude and Gemini provider servers when the MCP stdio connection closes instead of leaving idle `mcp-agents` processes behind
- Kill tracked detached provider child process groups during shutdown so abandoned CLI runs do not linger after the parent server exits

## [0.5.8] - 2026-03-29

### Changed

- Gemini CLI now always runs with `-s --approval-mode=plan` (sandbox + plan-only mode)
- Remove `sandbox` CLI flag and tool parameter (always enabled)

## [0.5.7] - 2026-03-18

### Changed

- Update the default Codex model from `gpt-5.3-codex` to `gpt-5.4`
- Refresh README examples to use `gpt-5.4` for Codex startup overrides

## [0.5.6] - 2026-02-20

### Added

- Add project `.mcp.json` with local Codex and Gemini MCP server entries

### Fixed

- Retry Claude `tools/call` once when the CLI exits successfully with empty output, then return an explicit MCP error if it is still empty
- Add structured stderr diagnostics for empty-output retries without logging prompt content
- Tighten connectivity integration checks to require non-empty tool text output
- Run Claude CLI in `--output-format json` mode and parse `result`/`is_error` so MCP returns assistant text instead of raw JSON

## [0.5.5] - 2026-02-20

### Fixed

- Document Codex MCP timeout override in the OpenAI Codex section with explicit `tool_timeout_sec = 300` examples
- Remove redundant Gemini `--sandbox false` examples and keep `--sandbox true` as an optional override

## [0.5.4] - 2026-02-20

### Fixed

- Ignore unsupported tool-call arguments for `claude_code` and `gemini` instead of letting callers force backend model-like parameters
- Accept extra tool-call keys while logging them as ignored, improving compatibility with clients that attach additional metadata

### Changed

- Document 5-minute default timeout (`300000ms`) for `claude_code` and `gemini`
- Clarify that Codex model selection (`--model`, `--model_reasoning_effort`) is startup configuration, not `tools/call` input

## [0.5.3] - 2026-02-18

### Fixed

- Codex passthrough now uses `-c key=value` config overrides after `mcp-server` subcommand instead of top-level `-m`/`-s`/`-a` flags
- Forward SIGTERM/SIGINT/SIGHUP to codex child process to prevent orphans
- Capture codex stderr for visibility into crashes and errors

### Changed

- Recommend global install (`npm i -g mcp-agents`) over `npx -y` to avoid MCP connection timeouts from slow npm lookups

## [0.5.2] - 2026-02-12

### Added

- `--timeout <seconds>` flag to set default timeout per CLI call (default: 300s)

### Fixed

- Kill entire process group on timeout to prevent orphan child processes

## [0.5.1] - 2026-02-11

### Changed

- Higher timeout: 30s -> 5m

## [0.5.0] - 2026-02-11

### Changed

- Claude backend now pipes prompts via stdin instead of `-p` argument, fixing quoting and length issues with complex prompts

## [0.4.0] - 2026-02-06

### Added

- `--sandbox` flag to control Gemini sandbox mode at startup (default: false)

### Changed

- Gemini sandbox mode now defaults to off (was on)

## [0.3.6] - 2026-02-05

### Changed

- Codex default model is now `gpt-5.3-codex`

## [0.3.5] - 2026-02-03

### Changed

- Codex provider now runs as native MCP pass-through (`codex mcp-server`) instead of `codex exec`

### Added

- `--model` flag to set Codex model (default: `gpt-5.2-codex`)
- `--model_reasoning_effort` flag to set reasoning effort (default: `high`)

## [0.3.2] - 2026-02-03

### Fixed

- Claude CLI backend now passes `--no-session-persistence` to prevent session state leaking between MCP tool invocations

## [0.3.1] - 2025-06-06

### Added

- Gemini CLI backend (`--provider gemini`)
- Codex CLI backend (`--provider codex`)
- `--provider` flag to select backend (default: `codex`)
- `--help` / `-h` and `--version` / `-v` CLI flags
- `ping` tool for health checks
- Comprehensive test suite (`test.sh`)

## [0.2.1] - 2025-05-30

### Added

- Initial MCP server wrapping Claude Code CLI
