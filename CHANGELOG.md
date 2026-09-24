# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.31.0] - 2026-09-24

### Added

- Add an opt-in authenticated loopback Streamable HTTP transport for the
  wrapper-owned `codex`, `claude`, and `gemini` providers. Codex HTTP requests
  share idle-reaped App Server runtimes by canonical project root while each
  request retains independent MCP connection state; stdio remains the default.
- Negotiate both legacy MCP and revision `2026-07-28` over stdio for the
  wrapper-owned `codex`, `claude`, and `gemini` providers. Foreground Codex
  interactions now resume through signed, content-free `input_required`
  rounds; the raw `browser` and `codex-legacy` transport boundaries are
  unchanged.

### Changed

- Limit foreground Codex calls from legacy stdio clients to eight input or
  approval rounds; calls requiring a ninth round return a tool error.

### Fixed

- Keep a foreground Codex turn's completion promise handled for its whole
  life. A question that arrives before the turn has an awaiter left the
  rejection unobserved, so a single deferred question could take the whole
  bridge down through the fatal `unhandledRejection` path.
- Shut down when the stdio transport closes without an stdin `end` event. An
  over-limit JSON-RPC frame closes the transport and pauses stdin, which
  previously left the `keepAlive` interval holding an orphaned bridge process
  alive after the client disconnected.
- Hide foreground interactions from `codex-interactions` and refuse them in
  `codex-interaction-resolve`. Settling one out-of-band stranded the turn and
  never released its thread lease, so every later operation on that thread
  failed with `codex_thread_busy`.
- Offer MCP form elicitation only to clients that actually declare it. A
  client declaring URL-mode elicitation alone was offered a form request the
  SDK then refused, wedging the turn instead of falling back to the
  background interaction queue.
- Reclaim an idle HTTP Codex runtime after its App Server child dies
  mid-turn. Records stranded by the lost generation pinned the runtime, and
  their thread leases left every later operation on that thread
  `codex_thread_busy` for the daemon's lifetime; those leases are now released
  when the runtime shuts down and the lost process group is proven gone.
- Keep a foreground Codex question over HTTP answerable. The request's abort
  listener outlived its `input_required` round, and HTTP aborts that signal as
  soon as the response is sent, so the question interrupted the turn it was
  waiting on.
- Cancel a blocking `claude` or `gemini` call, and kill its CLI process group,
  when its MCP request is canceled or its HTTP client disconnects, instead of
  letting the child run to its full timeout.
- Refuse an HTTP Codex call, reply, or review whose workspace lies outside the
  project root that routed the request, so its sessions and leases are not
  recorded under another project's state.
- Keep an idle HTTP Codex runtime until every finished background job has been
  read or has passed its one-hour retention, instead of discarding unread
  results about 50 minutes early.
- Validate the HTTP bearer token through the opened descriptor without
  following symlinks, and refuse a token whose directory is not private to the
  current user on reads as well as on creation.
- Refuse HTTP request bodies over 10 MiB with `413` before buffering them.

## [0.30.2] - 2026-09-16

### Fixed

- Treat a blank `MCP_AGENTS_CODEX_APP_INIT_TIMEOUT_MS` as unset instead of a
  one-millisecond deadline, and warn before using the 300-second default for
  malformed or out-of-range values.
- Describe thread-index construction as one possible cause of an App Server
  initialization timeout and direct operators only to the safe timeout override.

### Changed

- Document that thread listings expose App Server prompt previews and that an
  empty indexed page may mean the generation's private state database is
  unavailable rather than that durable history is empty.

## [0.30.1] - 2026-09-15

### Fixed

- Increase the default Codex App Server initialization budget from 10 to 300
  seconds, so projects with large durable session histories can finish building
  a generation's private thread index instead of entering a restart loop.
- Serve user-facing thread listings from the initialized generation's state
  database without rescanning session files, and include the bare App Server's
  default source kind (`vscode`) so ordinary wrapper threads appear alongside
  explicit `appServer` and `subAgentReview` sessions.
- Keep retention on its existing source scope so the corrected `vscode`
  discovery does not make ordinary wrapper threads newly eligible for native
  deletion, which can also remove spawned descendants and reverted history.

## [0.30.0] - 2026-09-07

### Changed

- Update the default Codex model from `gpt-5.6-sol` to `gpt-6-astra` on both
  the `codex` and `codex-legacy` providers; new sessions may still select the
  faster `gpt-5.6-terra`. Operators who pinned `--model gpt-5.6-sol` in their
  MCP client config should switch it to `gpt-6-astra`; the per-session enum
  no longer offers `gpt-5.6-sol`.
- Pin the `claude` backend to `claude-fable-5-1` at effort `xhigh` and pass
  `--fallback-model claude-opus-5` so blocking calls and background reviews
  fall back to Opus 5 when Fable 5.1 is overloaded or unavailable.

## [0.29.2] - 2026-09-05

### Fixed

- Exit cleanly when an MCP client's stderr pipe closes instead of repeatedly
  raising `EPIPE` during shutdown and leaving a CPU-spinning bridge process.

## [0.29.1] - 2026-08-29

### Fixed

- Allow durable native goals on newer Codex releases instead of rejecting every
  version other than 0.149.1.

## [0.29.0] - 2026-08-26

### Added

- Add a wrapper-owned MCP adapter over `codex app-server`'s documented stdio JSONL
  protocol. Existing blocking, reply, background-job, status, commentary,
  result, cancellation, and peek tools keep their closed MCP contracts while
  App Server remains an internal implementation detail.
- Expose curated App Server capabilities through closed schemas: race-safe
  steering, durable native goal set/get/clear with usage counters, native code
  reviews, bounded thread list/read/fork/archive/unarchive operations, and an
  interaction queue for approvals and structured user input.
- Persist project-scoped sessions, archived sessions, native writer locks, goal
  state, operation leases, and content-free bridge liveness sidecars outside the
  served workspace. Add `--codex-state-root` and
  `--codex-session-retention-days` with matching environment variables; the
  default retention window is 30 days.
- Translate eligible foreground App Server interactions into MCP elicitation
  when the client advertises it. Background jobs expose the same pending
  interactions through `codex-interactions` and
  `codex-interaction-resolve`, without disclosing native request IDs.
- Preserve the complete 0.28 native MCP bridge as the explicit, deprecated
  `codex-legacy` provider while supported Codex CLI releases still ship
  `codex mcp-server`. It retains the former schemas, framing, jobs, liveness,
  auth handling, watchdogs, and legacy goal transformation as one removable
  compatibility boundary.

### Changed

- **BREAKING:** change `--provider codex` from the native MCP bridge to
  `codex app-server` and require Codex CLI 0.149.1 or newer for that provider.
  Use `--provider codex-legacy` for temporary native MCP compatibility; there
  is no automatic fallback between the providers because their durability,
  goal, recovery, and error semantics differ. The outer MCP server now owns
  discovery and validation, so `initialize`, `tools/list`, `ping`, and local
  status tools remain available even while the App Server child is absent or
  restarting.
- **BREAKING:** reject `--approval_policy on-failure` for `--provider codex`,
  which App Server does not support. Use `on-request` or `never` instead. The
  `codex-legacy` provider retains the former native MCP setting.
- Reject App Server-only durable-state and retention flags for every provider
  other than `codex` instead of silently ignoring them.
- Use native `thread/start`, `thread/resume`, `turn/start`, `turn/interrupt`,
  `turn/steer`, `review/start`, and thread-goal methods. A configured or
  per-call goal now enters Codex's durable native goal lifecycle instead of
  being approximated with prompt or developer-instruction injection.
- Lazily start App Server generations and restart only for later safe calls.
  An in-flight turn whose child exits is reported as `outcome_unknown` and is
  never replayed automatically; durable thread IDs remain resumable across a
  clean bridge reconnect.

### Security

- Keep each App Server generation's config, auth snapshot, cache, logs, and
  general SQLite state isolated while allowlisting only project sessions,
  writer locks, and the version-gated native goal store into durable state.
  State roots inside the served workspace, unsafe symlinks, unknown goal-store
  layouts, and ambiguous cross-process thread ownership fail closed.
- Create credential-bearing and durable paths under a process-wide `0077`
  umask, validate private directories/files before reuse, and publish only
  content-free liveness metadata. Prompts, model output, commentary, and native
  request IDs never enter sidecars.
- Keep approval policy server-owned. Blocking calls that cannot safely conduct
  an interaction are rejected or interrupted instead of silently approving it;
  first resolution wins and unresolved interactions expire within the call's
  remaining hard deadline.

## [0.28.0] - 2026-08-21

### Added

- Add a separate `browser` passthrough provider that starts
  `chrome-devtools-mcp` locally and attaches it to a remote CDP endpoint
  supplied by an injected lease command, so browser automation can run against
  a Chromium on another machine while the MCP server and every screenshot stay
  local. Acquisition is lazy on the first advertised tool call, concurrent
  calls share one FIFO provisioning barrier, and idle/shutdown release is
  bounded and best-effort.
- Add browser-prefixed command, lease, idle, viewport, app-port, log-file, and
  repeatable URL allow-pattern settings with CLI-over-environment precedence.
  The lease command accepts JSON argv, so a path containing a space survives
  intact. The downstream resolves from an explicit command, a package-local
  install, or an `npx …@latest` fallback; Chrome DevTools MCP remains a dev
  dependency only and is deliberately unpinned, since result verification does
  not depend on any single release's reconnect behavior.
- Annotate remote-invalid performance, Lighthouse, and upload tools directly in
  their advertised descriptions without changing schemas or other metadata, so
  callers see why a tool cannot work over a tunnel rather than finding it
  missing.
- Preserve the complete MCP roots negotiation through the proxy, including raw
  `roots/list` server requests and client responses. A port-race restart
  replays the client's original initialize capabilities into the replacement
  child, so local screenshot paths retain their negotiated roots.

### Changed

- **BREAKING**: raise the supported Node floor to `>=26` (was `>=18`). The
  browser provider's downstream `chrome-devtools-mcp` already requires a Node
  newer than 18, and that floor rises as the unpinned dependency tracks latest,
  so one current floor replaces a split one. Consumers on Node 18-25 must
  upgrade Node to install this release.
- Reject a browser `--timeout` of 19s or less at startup. The provider reserves
  18s of the request budget for identity verification and the first tool call,
  so a smaller budget pinned lease acquisition to a 1s floor: acquisition could
  never succeed, raising `--timeout` anywhere inside that range changed nothing,
  and the runtime error blamed the lease command instead of the flag. The 600s
  browser default is unaffected.

### Security

- Never forward a browser tool result that cannot be proven to have come from
  the leased browser. Every result is checked against the lease generation its
  call was issued under, and a mismatch, an unverifiable identity, a discarded
  generation, an unrecoverable frame id, a cancelled-but-outstanding call, a
  downstream restart, or a hard timeout all resolve as a typed
  `browser_lease_replaced` error instead. The classifiers default to that
  fail-closed result and assign the native frame only on an affirmative
  still-live match, so a code path that omits the check fails safe rather than
  leaking. A silently substituted browser would otherwise make a passing UI
  check meaningless.
- Fail browser provisioning closed on unavailable, malformed, mismatched, or
  exhausted port attempts without ever launching a local browser.
- Keep Chrome DevTools MCP's roots-based file allowlist enabled by never
  passing `--allowUnrestrictedPaths`. URL allow patterns are configurable for
  hardened deployments but remain opt-in for general browser compatibility.

## [0.27.0] - 2026-08-07

### Fixed

- Create isolated Codex homes under the server startup directory's private
  `tmp/codex-homes/` tree instead of the OS temp directory. Codex 0.147 refuses
  to create its PATH helper aliases beneath `/tmp`; the new `0700` directories
  and `0600` runtime files preserve isolation without triggering that safety
  check. Startup still sweeps stale homes from the legacy OS-temp location.
- Interpret Codex's correlated `unauthorized` event as a process-wide auth
  failure, replace its duplicate native event/result with one structured
  `codex_auth_invalidated` tool error, fail background jobs with the same stable
  code, and reject new turns locally until the bridge reconnects. State-only
  tools remain available for inspecting or collecting existing jobs.
- Prevent stale isolated auth from overwriting a newer `codex login` or another
  bridge's token rotation during cleanup. Auth write-back now requires the
  isolated copy to have changed while canonical auth still matches this
  bridge's startup snapshot, and known-invalidated auth is never persisted.

## [0.26.0] - 2026-08-06

### Fixed

- Treat Codex `turn_aborted` events as terminal failures when the bridge answers
  on Codex's behalf: synthesized foreground responses are errors, background jobs
  fail, and teardown recovery never reports success. Native foreground responses
  remain byte-for-byte passthrough; if one settles an aborted turn, the bridge now
  warns on stderr instead of silently implying the native result was bridge-owned.
  Abort errors also warn that applied writes remain in the workspace.
- A terminal event that acknowledges a requested cancellation now gets its own
  bounded frame-boundary grace instead of inheriting the pre-confirmation wait;
  duplicate terminal events cannot consume that grace. Only a stream still wedged
  after the post-confirmation grace retains the existing bounded escalation. Job
  status distinguishes an honored abort from a turn that completed after
  cancellation was requested and whose result was discarded. An unacknowledged
  cancellation remains explicitly abandoned and may still be writing to the
  workspace.
- Preserve terminal evidence that arrives just before a cancellation, so an
  already-aborted turn is confirmed immediately instead of being downgraded to
  an unacknowledged cancellation. A cancellation that starts mid-frame also
  releases response suppression when the already-forwarded native response is
  observed, preventing phantom request-id reservations and bridge teardown.

## [0.25.0] - 2026-07-25

### Added

- `codex-peek` lists the Codex turns the server currently has in flight — blocking
  and background alike — read-only and immediate. Steering callers to blocking
  dispatch (0.24.0) left one gap: a blocking call is opaque until it returns, and
  nothing outside the bridge can see it. The `codex mcp-server` child is long-lived
  and multiplexes every request, so a caller inspecting the process table finds no
  per-turn process and can conclude a running build is dead. That happened: a healthy
  20-minute build was cancelled four seconds after its last file write, on the
  strength of a `pgrep` that structurally could not have matched it. Each row carries
  a handle — `requestId` for a client call, `jobId` for a background job — plus
  `state` (`running` or `canceling`), the `threadId` once Codex reports one, the
  workspace, `elapsedSeconds`, and `lastActivitySeconds`: small and falling means
  healthy however large `elapsedSeconds` grows. Optional `cwd` / `threadId` /
  `requestId` filters narrow the list, and `ambiguous` marks a filter that still
  matches several turns.
- Turn workspaces are remembered per thread (bounded, 64 entries) so a `codex-reply`
  turn — which takes no `cwd` argument, inheriting the workspace of the thread it
  continues — can still be reported with one, flagged `cwdInferred`.

### Notes

- An empty `codex-peek` is **not** evidence a turn finished, and the tool says so in
  its own output: an abandoned turn keeps running inside Codex with no in-flight
  request left to report. The count of such turns is returned as `abandonedTurnsProcessWide` — named for its
  scope, since an abandoned turn retains no workspace to filter on. A `cwd` filter also
  compares normalised paths, not symlink-resolved ones.
- A **cancelled** turn is listed with `state: "canceling"` for the cancellation grace
  window, because cancellation is best-effort: during it Codex is still executing under
  `workspace-write`. Once the grace expires the row is gone and only
  `abandonedTurnsProcessWide` remembers it — still not confirmed stopped. Omitting those rows would answer "nothing in
  flight" to the caller who most needs a yes — someone deciding whether it is safe to
  send a second writer into that tree.
- A `cwd` filter never hides a turn whose workspace could not be recovered; such rows
  are reported with `cwdUnknown` so "I cannot tell" cannot become "nothing is running
  there". The thread→workspace map is LRU, so the long-lived thread you keep replying
  to is not evicted ahead of idle newer ones.
- `codex-peek` never returns prompts or model output, never reports itself, and never
  discloses a job's private native request id — jobs are addressed by `jobId`.

## [0.24.0] - 2026-07-25

### Added

- `--codex_status_interval <seconds>` (default `30`, env
  `MCP_AGENTS_CODEX_STATUS_INTERVAL_MS`, `0` disables) bounds how often a background
  job's status cursor may advance, coalescing intermediate progress into one wake. It
  is clamped to the largest delay `setTimeout` can represent, so an absurd value cannot
  invert into a bump per event.

### Changed

- **A background job's status cursor now advances at most every 30 seconds by
  default, instead of once per second.** Every cursor advance wakes a `codex-status`
  long-poll, and each wake costs the polling agent a full model turn over its
  accumulated transcript — so the old cadence made `wait_ms` meaningless (a status
  call returns immediately whenever the cursor is behind the head) and turned a
  40-minute build into hundreds of poll turns. Only intermediate progress updates are
  paced — lifecycle transitions (first `running`, cancellation, terminal) bypass the
  interval, so completion is never delayed; `lastActivitySeconds` is stamped from raw
  Codex events, so stall detection is unchanged; commentary retention is untouched.
  Progress *notifications* keep their own 1-second cadence — they cost the caller no
  context, so a progress-aware UI stays as live as before.
- **`codex-status`'s `wait_ms` now defaults to the status interval** (capped at
  `60000`) instead of a flat `10000`. Pacing the cursor alone does not bound wakeups —
  a caught-up poller is still re-woken by the heartbeat — so a flat 10s default would
  have kept waking callers roughly six times a minute regardless of the new cadence.
- `codex-start` / `codex-reply-start` now say plainly that the blocking `codex` /
  `codex-reply` call is preferred even for long builds, and that a job is for work
  that must outlive its caller. `codex-status` documents both wake sources and that
  `wait_ms` is a ceiling on idle waiting, not a floor on poll spacing.

### Fixed

- The "Cancellation and reconnect" section of the README still described the
  pre-`f672ece` behaviour — that an unacknowledged cancellation kills the Codex
  process group and exits the bridge. It now matches the code: the request is settled
  locally, the bridge and sibling calls survive, only a mid-frame wedge escalates to a
  bounded teardown, and cancellation is best-effort and never proof that Codex stopped.
  The per-call-liveness and cancellation paragraphs said an idle-timeout cancellation is
  sent "so it stops working" and described a single grace; both now say plainly that the
  request is settled rather than the writer stopped, and that the mid-frame escalation
  arms a second grace.

## [0.23.0] - 2026-07-24

### Added

- Add `claude-start`, `claude-status`, `claude-result`, and `claude-cancel` for
  reliable one-shot Claude reviews. Jobs return immediately, expose bounded
  cursor-based status polling, retain paged final results, and use a
  bridge-owned two-hour deadline instead of holding one MCP call open for the
  entire review. The blocking `claude_code` contract remains available for
  short prompts.

### Changed

- Emit strictly increasing MCP progress values and content-free Claude job
  start/terminal lifecycle logs for operational visibility.

### Security

- Run background Claude reviews as fixed Opus 4.8/xhigh leaf sessions with
  project context but no hooks, subagents, skills, slash commands, external MCP
  servers, mutation tools, or caller-controlled model/effort/timeout. Only
  sanitized phase status crosses MCP before the final verdict; prompts are
  never echoed in progress or bridge logs, and drafts, reasoning, tool
  inputs/results, provider errors, and diagnostics stay private.

## [0.22.0] - 2026-07-24

### Added

- `allow_subagents` (boolean, default `false`) on `codex` and `codex-start` lets
  a new session use Codex's native in-process subagents (`spawn_agent`,
  `wait_agent`, and friends). Session-scoped like `sandbox`: replies inherit it
  and cannot change it. The flag flips ONLY the native multi-agent gates
  (`agents.enabled` and `features.multi_agent`) through a per-call config
  override — the isolated home still writes no `[mcp_servers]`, so subagents
  are Codex-only and cannot re-enter this bridge or reach other LLM-backed
  tools (Claude/Gemini). Residual caveat: native subagents inherit the
  session's `approval_policy` and `sandbox_mode`, so under `workspace-write`
  with `approval_policy=never` several agents may write the SAME workspace
  concurrently. Codex's agent control coordinates them, but the caller still
  scopes the commission.

### Fixed

- The `[features] multi_agent = false` hard-disable is ineffective on Codex
  >= 0.145.0: upstream stabilized the flag (on by default) and bridge sessions
  still received the collab tools — verified empirically by a bridge session
  spawning a live subagent despite the flag. The isolated config now also
  writes `[agents] enabled = false`, the gate 0.145.0 actually honors
  (`multi_agent = false` stays for older Codex versions). Commissioned
  sessions are guaranteed leaves again unless the caller opts in with
  `allow_subagents`.
- The `[agents]` off switch is version-gated: Codex 0.102–0.144 parse a
  boolean under `[agents]` as a custom agent role and hard-fail config
  loading at startup, which would have broken the whole codex provider on
  those versions. The bridge now probes `codex --version` once at startup and
  emits the `[agents]` line (and the matching `agents.enabled` opt-in
  override) only on >= 0.145.0; older versions keep the feature flag, which
  both parses everywhere and still gates their collab tools. An unparseable
  version assumes modern Codex, failing toward subagents staying off.
- Multi-agent V2 lifecycle activity (`sub_agent_activity`, Codex >= 0.145.0)
  now surfaces in MCP progress next to the older `collab_agent_*` events.

## [0.21.0] - 2026-07-22

### Fixed

- A client cancellation that Codex does not acknowledge in time no longer tears
  the whole bridge down. 0.20.0 removed the whole-bridge teardown from the
  *timeout* path but left it on the *cancellation* path, where it fired far more
  often: every ESC, aborted turn, or subagent teardown sends
  `notifications/cancelled`, and a Codex mid-turn does not service it within the
  grace. The teardown killed every **other** in-flight request, every background
  job, and the isolated `CODEX_HOME` — which holds the Codex `sessions/`
  directory, so every `threadId` in the process became permanently unresumable
  and the next `codex-reply` failed with `Session not found for thread_id`.
  A cancelled request now costs exactly one request: its id is settled locally,
  Codex's late response is suppressed, and peers keep running. Teardown remains
  only for a stream wedged mid-frame with no safe boundary, and even that now
  retries once before escalating.
- The default cancel grace is raised from 3s to 30s. Three seconds was far below
  what a Codex running sandboxed commands needs to acknowledge a cancellation, so
  the escalation path was effectively the default path.
- A background job (`codex-start`) whose cancellation goes unacknowledged is now
  driven to a terminal `canceled` state instead of sitting in `canceling`
  forever, which previously hung every `codex-status` long-poll against it.
- Background jobs no longer outlive the client that dispatched them. A job is
  polled by `jobId` through the bridge process, so once the client disconnects
  nothing can ever read its result — but Codex kept executing it, writing to the
  workspace, invisible to the client's own task registry (a harness "stop task"
  cannot reach an mcp-agents job; only `codex-cancel` can, and the `jobId` died
  with the connection). Client stdin EOF now cancels every non-terminal job and
  every open request, and a bounded wind-down reaps the Codex process group if it
  keeps working anyway.

### Added

- `--codex_cancel_grace <secs>` sets how long Codex may take to acknowledge a
  cancellation before the bridge abandons the request (the bridge stays
  connected). CLI flag wins over `MCP_AGENTS_CODEX_CANCEL_GRACE_MS`.
- Abandoned Codex turns are now logged explicitly on stderr — once when the
  wrapper stops waiting (naming the `thread_id`, `job_id`, and sandbox mode, and
  warning that the workspace may still have a live writer) and again if the turn
  later finishes and its result is discarded. A tree that changed under an agent
  can now be explained from the log instead of inferred.
- Stale isolated Codex homes (`$TMPDIR/mcp-agents-codex-*`) older than 12h are
  swept at startup. Each one is left behind by a bridge that died without running
  cleanup and holds a copy of `auth.json`, so they were both disk litter and
  credential sprawl.

### Changed

- The isolated Codex home is seeded with `models_cache.json` from the real
  `CODEX_HOME`. Every bridge start was otherwise a cold Codex install that
  re-fetched ~280 KB before becoming useful — repeated per session, per
  reconnect.

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
