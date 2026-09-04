# mcp-agents

**Use Codex from Claude Code. Use Claude Code from Codex. One MCP bridge, either direction.**

## TL;DR

> ⚡ `mcp-agents` exposes Claude Code and Codex CLI as MCP tools, so either
> agent can delegate work to the other, request a second opinion, or run an
> independent review without custom glue for each CLI.

> ⚠️ OpenAI has [deprecated `codex mcp-server`](https://learn.chatgpt.com/docs/mcp-server).
> The default `codex` provider keeps MCP at the `mcp-agents` boundary and uses
> [`codex app-server`](https://learn.chatgpt.com/docs/app-server) privately
> underneath. `codex-legacy` is a temporary compatibility lane while supported
> Codex CLI releases still ship the deprecated command—not a foundation for new
> setups.

Install one package, then add one MCP server entry per agent you want to expose.
Each provider has its own tool surface. A client can start it over stdio or
connect to an operator-run HTTP daemon; one process never dynamically routes
every backend.

## Table of contents

- [Why mcp-agents?](#why-mcp-agents)
- [Quickstart](#quickstart)
  - [Claude Code calls Codex](#claude-code-calls-codex)
  - [Codex calls Claude Code](#codex-calls-claude-code)
- [Transport modes](#transport-modes)
- [Providers](#providers)
- [Client configuration](#client-configuration)
- [Provider reference](#provider-reference)
- [Development](#development)
- [How it works](#how-it-works)
- [License](#license)

## Why mcp-agents?

- **Claude ↔ Codex, both ways.** Ask the other agent to implement, review,
  investigate, or challenge a plan without leaving your current client.
- **One MCP integration pattern.** Install one executable and select the agent
  behind each server entry with `--provider`.
- **Long-running work without wishful thinking.** Claude reviews and Codex turns
  have background jobs, bounded result paging, cancellation, and privacy-safe
  progress.
- **A migration path off native Codex MCP.** MCP clients keep a closed,
  wrapper-owned interface while the default Codex provider adapts to App Server.
- **Durable Codex sessions.** Threads, goals, recovery state, leases, and
  liveness survive clean bridge reconnects.
- **Optional remote browser access.** The browser provider can proxy Chrome
  DevTools MCP through an operator-owned, fail-closed browser lease.

## Quickstart

🚀 Install the bridge once, then configure either or both directions.

### Prerequisites

- **Node.js 26 or newer**
- For Claude Code → Codex:
  [Codex CLI](https://github.com/openai/codex) 0.149.1 or newer,
  authenticated and available on Claude Code's `PATH`
- For Codex → Claude Code:
  [Claude Code](https://docs.anthropic.com/en/docs/claude-code), authenticated
  and available on Codex's `PATH`

Only configured providers need their corresponding CLI. The browser provider
has separate lease-helper requirements described in its
[advanced reference](#browser-advanced-remote-chrome-pass-through).

### Install with Mise (recommended)

Add `mcp-agents` to the project's `.tool-versions`:

```text
npm:mcp-agents            latest
```

Then install it through the project's normal Mise setup:

```bash
mise install
mcp-agents --version
```

This keeps the installation and update policy in the project while MCP clients
still launch the direct `mcp-agents` executable. The `latest` value
intentionally tracks the newest published release.

Make sure the MCP client inherits the activated Mise `PATH`. If a GUI client
cannot resolve the shim, use the absolute path reported by
`command -v mcp-agents`.

### Claude Code calls Codex

Add `mcp-agents` to the project's `.mcp.json`:

```json
{
  "mcpServers": {
    "codex": {
      "command": "mcp-agents",
      "args": ["--provider", "codex"],
      "timeout": 7500000
    }
  }
}
```

Restart Claude Code, then verify the server is connected:

```bash
claude mcp list
```

Ask Claude to use Codex for a task, for example:

> Ask Codex to review this implementation plan and identify the riskiest
> assumption.

The `codex` tool starts a durable thread. Its returned `threadId` can be used
with `codex-reply` for follow-up work.

### Codex calls Claude Code

Add the Claude provider to `~/.codex/config.toml`:

```toml
[mcp_servers.claude-code]
command = "mcp-agents"
args = ["--provider", "claude"]
tool_timeout_sec = 960
```

Restart Codex, then verify the server is listed:

```bash
codex mcp list
```

Ask Codex for an independent Claude review, for example:

> Ask Claude for a second opinion on this diff. Focus on correctness and
> regressions.

For substantial reviews, Codex should use `claude-start` →
`claude-status` → `claude-result`. The blocking `claude_code` tool is intended
for small prompts.

This quickstart uses the default client-managed stdio transport. The optional
[shared HTTP mode](#shared-http-daemon) avoids one bridge process per client.

## Transport modes

Both modes expose the same MCP tools. The difference is process ownership and
lifetime.

| Mode | Process lifecycle | Trade-off |
| --- | --- | --- |
| Client-managed stdio (default) | Each MCP client starts and stops its own provider process. | No service setup; every concurrent connection pays its own process, memory, and startup cost. |
| Shared HTTP daemon (optional) | The operator keeps one provider daemon running and clients connect to `http://127.0.0.1:<port>/mcp`. | Faster reconnects and fewer adapter processes; requires service and local-auth configuration. |

Stdio uses
[JSON-RPC over stdio](https://modelcontextprotocol.io/docs/concepts/transports#stdio).
Because the protocol era is chosen by the opening exchange, the bridge logs
twice to stderr: `[mcp-agents] listening (provider: <name>, awaiting protocol
era)` once the transport accepts input, then `[mcp-agents] ready (provider:
<name>, era=<legacy|modern>)` once an era is pinned. The `codex` provider
logs the same pair as `[mcp-agents] Codex MCP adapter listening` and
`[mcp-agents] Codex MCP adapter ready`. Wait for the listening line, not the
ready line, to know the bridge accepts traffic. stdout remains MCP-only.
Use the Quickstart configuration above if you prefer this mode.

### Shared HTTP daemon

HTTP is additive and opt-in. Each daemon serves one of the `codex`, `claude`,
or `gemini` providers. Use a separate port and service for each additional
provider. The raw `browser` and `codex-legacy` providers remain stdio-only.

Test the Codex daemon in a terminal first:

```bash
mcp-agents --provider codex --transport http --http-port 8765
```

It listens only on loopback at `http://127.0.0.1:8765/mcp` and creates a
private bearer-token file. Point Claude Code at it with:

```json
{
  "mcpServers": {
    "codex": {
      "type": "http",
      "url": "http://127.0.0.1:8765/mcp",
      "headers": {
        "X-Mcp-Agents-Project-Root": "${PWD}"
      },
      "headersHelper": "/absolute/path/to/mcp-agents http-auth-headers",
      "timeout": 7500000
    }
  }
}
```

Use the same `mcp-agents` installation for the daemon and `headersHelper`.
Claude Code runs the helper on every connection; it reads the token file and
returns the `Authorization` header without storing the token in `.mcp.json`.
The project-root header is required by the Codex provider so one daemon can
isolate and pool runtimes by canonical project path.

Service managers do not load interactive shell initialization. The examples
below use the absolute path from `command -v mise` and a working directory
whose `.tool-versions` contains `mcp-agents` and its provider CLI. Without
Mise, invoke the absolute `mcp-agents` path directly and set `PATH` for Node.js
and the provider CLI in the service definition.

<details>
<summary>Linux: systemd user service</summary>

Create `~/.config/systemd/user/mcp-agents-codex.service`:

```ini
[Unit]
Description=mcp-agents Codex HTTP daemon

[Service]
Type=simple
WorkingDirectory=/absolute/path/to/project-with-tool-versions
ExecStart=/absolute/path/to/mise exec -- mcp-agents --provider codex --transport http --http-port 8765
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
```

Enable it for the current user:

```bash
systemctl --user daemon-reload
systemctl --user enable --now mcp-agents-codex.service
systemctl --user status mcp-agents-codex.service
```

The user service starts at login. To start it at boot and keep it running after
logout, additionally enable lingering with `loginctl enable-linger "$USER"`
(some distributions require `sudo`). Read logs with
`journalctl --user -u mcp-agents-codex.service`.

</details>

<details>
<summary>macOS: launchd user service</summary>

Create `~/Library/LaunchAgents/dev.mcp-agents.codex.plist`, replacing every
absolute path:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.mcp-agents.codex</string>
  <key>ProgramArguments</key>
  <array>
    <string>/absolute/path/to/mise</string>
    <string>exec</string>
    <string>--</string>
    <string>mcp-agents</string>
    <string>--provider</string>
    <string>codex</string>
    <string>--transport</string>
    <string>http</string>
    <string>--http-port</string>
    <string>8765</string>
  </array>
  <key>WorkingDirectory</key>
  <string>/absolute/path/to/project-with-tool-versions</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
</dict>
</plist>
```

Load and inspect the service:

```bash
launchctl bootstrap "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/dev.mcp-agents.codex.plist"
launchctl print "gui/$(id -u)/dev.mcp-agents.codex"
```

A LaunchAgent starts at login and stays running for that user's session.

</details>

## Providers

### Primary providers

| Provider | Best for | Under the hood | State model |
| --- | --- | --- | --- |
| `codex` | Implementation, reviews, steering, goals, and resumable sessions | Wrapper-owned MCP adapter over `codex app-server --stdio` | Durable threads and native goals |
| `claude` | One-shot help and independent read-only reviews | Claude Code CLI, pinned to Fable 5.1 at `xhigh` effort with Opus 5 fallback | Blocking calls and connection-local review jobs |

### Also supported

| Provider | What it does | Under the hood |
| --- | --- | --- |
| `gemini` | Runs a Gemini-backed agent prompt | Google Antigravity CLI: `agy --sandbox -p <prompt>` |
| `browser` | Proxies Chrome DevTools MCP to an operator-leased remote browser | `chrome-devtools-mcp --browserUrl <leased-loopback-CDP-url>` |
| `codex-legacy` | Temporary compatibility with the former Codex bridge | Deprecated `codex mcp-server` |

The browser provider is an advanced operational capability, not part of the
normal Claude ↔ Codex setup. `codex-legacy` is not a recommended fallback and is
never selected automatically.

## Client configuration

### Mise, npm, or npx

The [Mise installation](#install-with-mise-recommended) is recommended. It
keeps the shared tool and its update policy in `.tool-versions` without adding a
Mise wrapper to every MCP process launch. If you do not use Mise,
`npm install -g mcp-agents` works just as well at runtime and launches the same
executable.

<details>
<summary>Global npm alternative</summary>

```bash
npm install -g mcp-agents
```

Continue to configure clients with `"command": "mcp-agents"`. Add the npm
install to the project setup script so new developers receive it automatically.

</details>

<details>
<summary>Zero-install npx alternative</summary>

```json
{
  "mcpServers": {
    "codex": {
      "command": "npx",
      "args": ["-y", "mcp-agents", "--provider", "codex"],
      "timeout": 7500000
    }
  }
}
```

`npx` only affects startup; connected tool-call behavior is identical. Every
launch and reconnect still resolves the package through npm, with no offline
fallback. Slow networks, registry failures, or stale cache state such as
`ETARGET` can therefore remove the tools for that session. Pinning
`mcp-agents@x.y.z` prevents `@latest` from changing unexpectedly but does not
remove the launch-time registry dependency.

</details>

### Claude Code configuration

The [quickstart](#claude-code-calls-codex) is the recommended project
configuration. To override Codex defaults at server startup:

```json
{
  "mcpServers": {
    "codex": {
      "command": "mcp-agents",
      "args": [
        "--provider",
        "codex",
        "--model",
        "gpt-6-astra",
        "--model_reasoning_effort",
        "xhigh",
        "--codex-workspace-network=false"
      ],
      "timeout": 7500000
    }
  }
}
```

Every initial `codex` call may select `gpt-6-astra` or `gpt-5.6-terra` and
`medium`, `high`, `xhigh`, or `max`. Omitted selectors use the server defaults;
replies inherit the thread's model, effort, sandbox, and subagent policy. Other
models, raw `config`, and per-call approval-policy arguments are rejected before
Codex runs. Add `"--goal", "<text>"` to the server args to provide a default
native durable objective.

Claude Code interprets the per-server `timeout` in milliseconds as a hard
wall-clock cap; progress does not extend it. Keep it above the wrapper's
`--timeout`, which defaults to 7,200 seconds for Codex, including response
headroom. A project `.mcp.json` entry can override a user-level entry of the
same name, so configure the timeout on the project entry.

### OpenAI Codex configuration

The [quickstart](#codex-calls-claude-code) is enough for blocking Claude calls.
For frictionless background reviews, explicitly approve the connection-local
review tools:

```toml
[mcp_servers.claude-code]
command = "mcp-agents"
args = ["--provider", "claude"]
tool_timeout_sec = 960

[mcp_servers.claude-code.tools.claude-start]
approval_mode = "approve"

[mcp_servers.claude-code.tools.claude-status]
approval_mode = "approve"

[mcp_servers.claude-code.tools.claude-result]
approval_mode = "approve"

[mcp_servers.claude-code.tools.claude-cancel]
approval_mode = "approve"
```

The 960-second client timeout preserves compatibility with the blocking
900-second `claude_code` tool. Background reviews do not keep one MCP request
open: `claude-start` returns immediately, and each `claude-status` poll lasts at
most 60 seconds.

### Run from a source checkout

For a personal bridge launched directly from a checkout:

```json
{
  "mcpServers": {
    "codex": {
      "type": "stdio",
      "command": "node",
      "args": [
        "/absolute/path/to/mcp-agents/server.js",
        "--provider",
        "codex",
        "--codex_idle_timeout",
        "0"
      ],
      "env": {},
      "timeout": 3600000
    }
  }
}
```

Bare `node` resolves against the MCP client's `PATH`. If the client does not
initialize nvm, fnm, asdf, or another version manager, use the absolute Node path
reported by `command -v node`.

## Provider reference

### `codex`: App Server-backed MCP

The default Codex provider is a wrapper-owned MCP server backed internally by
the documented stdio JSONL interface of `codex app-server`. It requires Codex
CLI 0.149.1 or newer. OpenAI currently labels App Server experimental and
unsupported for production workloads, so the adapter treats it as a
version-gated private dependency instead of exposing its protocol to MCP
clients.

The outer MCP connection owns initialization, discovery, validation, progress,
jobs, and results; App Server stays lazy. There is no automatic fallback to
native MCP because the providers have different durability, goal, recovery, and
error semantics.

`initialize`, `tools/list`, `ping`, and wrapper-local status tools do not depend
on a healthy Codex child. If a child exits, a later safe operation starts a new
generation against the same durable sessions. A dispatched turn is reported as
`codex_outcome_unknown` and is never replayed automatically because it may
already have changed the workspace.

<details>
<summary>Tool contracts and curated tools</summary>

#### Core calls

| Tool | Purpose |
| --- | --- |
| `codex` | Start a thread and block until its turn completes |
| `codex-reply` | Resume a durable thread and block for the next turn |
| `codex-start`, `codex-reply-start` | Start the equivalent work as a connection-local background job |
| `codex-status`, `codex-commentary`, `codex-result`, `codex-cancel` | Poll, read, collect, or cancel a job |
| `codex-peek` | Read content-free liveness for turns owned by this bridge |

`codex` accepts:

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `prompt` | string | yes | Initial user prompt |
| `cwd` | absolute path | yes | Working directory |
| `sandbox` | string | yes | `read-only`, `workspace-write`, or `danger-full-access` |
| `model` | string | no | `gpt-6-astra` or `gpt-5.6-terra` |
| `model_reasoning_effort` | string | no | `medium`, `high`, `xhigh`, or `max` |
| `allow_subagents` | boolean | no | Enable native in-process Codex subagents for this thread; default `false` |
| `goal` | string | no | Set the native durable objective; `""` suppresses the server default |

`codex-reply` requires `prompt` and a nonblank `threadId`. It may accept `goal`
to replace or clear the native thread goal. Model, effort, sandbox, and subagent
policy are inherited. Both schemas set `additionalProperties: false`; raw App
Server config, instructions, provider selection, and per-call approval policy
remain unavailable.

#### Curated App Server tools

| Tool | Required arguments | Purpose |
| --- | --- | --- |
| `codex-steer` | `threadId`, `prompt` | Add input to the active turn with the wrapper-supplied native turn precondition |
| `codex-goal-set` | `threadId` plus one of `objective`, `status`, `tokenBudget` | Create or update the native durable goal |
| `codex-goal-get`, `codex-goal-clear` | `threadId` | Read counters or clear the goal |
| `codex-review`, `codex-review-start` | `threadId`, `target` | Run a native inline or detached review, blocking or as a job |
| `codex-thread-list` | — | List active or archived durable threads with cursor pagination; rows include prompt previews |
| `codex-thread-read` | `threadId` | Read sanitized metadata and optionally bounded turn history |
| `codex-thread-fork` | `threadId` | Fork all history or through `lastTurnId` |
| `codex-thread-archive`, `codex-thread-unarchive` | `threadId` | Move a thread into or out of the archive |
| `codex-interactions` | — | List unresolved approvals or structured questions |
| `codex-interaction-resolve` | `interactionId` | Resolve with one decision or a set of question answers |

Review targets are closed objects:

```text
{"type":"uncommittedChanges"}
{"type":"baseBranch","branch":"main"}
{"type":"commit","sha":"...","title":"..."}
{"type":"custom","instructions":"..."}
```

Delivery is `inline` by default or `detached`. Thread reads and listings are
bounded to 100 records per call. A listing's `preview` is usually the first user
message, so treat thread-list output as conversation content. Returned history
is otherwise sanitized; the bridge does not expose raw App Server frames,
hidden reasoning, config, arbitrary filesystem operations, or private native
request IDs.

</details>

<details>
<summary>Durable state and recovery</summary>

Each startup working directory gets a project namespace beneath:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/mcp-agents/codex/
  projects/<sha256-of-canonical-startup-cwd>/v1/
```

The durable allowlist contains sessions, archived sessions, Codex's native
thread-writer locks, the native goal store, wrapper operation leases, retention
metadata, and content-free bridge sidecars. General App Server SQLite state,
logs, config, cache, and auth snapshots remain in private per-generation homes
and are removed after the child exits.

App Server initialization gets a 300,000-millisecond budget by default so a
generation can build its private thread index from a large durable session
history. `MCP_AGENTS_CODEX_APP_INIT_TIMEOUT_MS` is measured in milliseconds;
an unset or blank value uses the default, while an invalid value logs a warning
and also uses the default. Zero clamps to one millisecond and does not disable
the timeout. Initialization must succeed before retention starts. If indexing
exceeds the budget, raise the environment value. The first App-backed Codex
tool call's hard deadline includes this lazy initialization and setup time.

Bare `codex app-server` defaults `--session-source` to `vscode`. User-facing
thread listing requests `vscode`, `appServer`, and `subAgentReview` with
`useStateDbOnly`, preserving explicitly MCP-labelled sessions while avoiding
another session-file scan after initialization. Each bridge therefore reads the
index snapshot built for its current App Server generation. Threads created,
resumed, archived, or unarchived by a sibling bridge appear after this child
reconnects or restarts. App Server also returns an empty state-only page when
its private state database is unavailable, so an empty `codex-thread-list`
result does not prove the durable history is empty. The wrapper does not rescan
session files in that case; restart the bridge to build a fresh private index.

| Setting | Default | Environment |
| --- | --- | --- |
| `--codex-state-root <path>` | XDG state path above | `MCP_AGENTS_CODEX_STATE_ROOT` |
| `--codex-session-retention-days <days>` | `30` for eligible `appServer` / `subAgentReview` sessions; `0` disables expiry | `MCP_AGENTS_CODEX_SESSION_RETENTION_DAYS` |
| App Server initialization | `300000` ms; blank uses the default; invalid warns and uses the default; `0` clamps to `1` ms | `MCP_AGENTS_CODEX_APP_INIT_TIMEOUT_MS` |
| `--model <model>` | `gpt-6-astra` | — |
| `--model_reasoning_effort <effort>` | `xhigh` | — |
| `--codex-workspace-network=true\|false` | `true` | `MCP_AGENTS_CODEX_WORKSPACE_NETWORK_ACCESS` |
| `--codex_idle_timeout <seconds>` | `600`; `0` disables | — |
| `--codex_cancel_grace <seconds>` | `30` | `MCP_AGENTS_CODEX_CANCEL_GRACE_MS` |
| `--codex_status_interval <seconds>` | `30` | `MCP_AGENTS_CODEX_STATUS_INTERVAL_MS` |

A custom state root must be absolute and outside the served workspace.
Directories use mode `0700`, files use `0600`, and the process sets umask `0077`
before creating credential-bearing or durable state. Retention runs at startup
and daily, skips live or uncertain ownership, and removes only eligible inactive
thread state older than the configured window. Retention keeps its existing
`appServer` and `subAgentReview` source scope; ordinary `vscode` wrapper threads
remain ineligible because native deletion can also remove spawned descendants
and reverted history.

Multiple bridge processes may share the project store, but wrapper operations
take a per-thread lease and Codex keeps its native writer lock. A live or
uncertain competing owner returns `codex_thread_busy`. Stale wrapper leases are
recovered only after their owner PID is proven dead.

Bridge sidecars contain IDs, PIDs, generation, workspace, sandbox, timestamps,
rollout path, and lifecycle state—never prompts, commentary, model output, or
native request IDs. The lifecycle distinguishes `starting`, `active`,
`waiting_for_input`, `canceling`, `terminal_undelivered`, and
`outcome_unknown`.

Native goals use App Server's thread goal methods rather than prompt
conditioning. Goal status, token budget, usage, and elapsed time survive bridge
restarts. On POSIX, `mcp-agents` shares only Codex's current `goals_1.sqlite`,
`goals_1.sqlite-wal`, and `goals_1.sqlite-shm` files between otherwise isolated
App Server SQLite homes. This compatibility assumption is documented rather
than patch-version-gated; if Codex changes the layout, `mcp-agents` must be
updated to preserve goals across bridge restarts. Durable native goals are
currently unsupported on Windows.

</details>

<details>
<summary>Isolation, approvals, and interactions</summary>

Each App Server generation receives an isolated `CODEX_HOME` and
`CODEX_SQLITE_HOME`. The bridge links only the durable native goal files into
the SQLite home, copies authentication and the model cache, writes a minimal
config, strips external MCP servers and unrelated preferences, and selectively
mirrors an explicit Fast-mode opt-in.

Fast mode is inherited only when both of these settings are present in the
source Codex config:

```toml
service_tier = "fast"

[features]
fast_mode = true
```

All other normal `~/.codex/config.toml` settings remain private to the user's
regular Codex sessions. Native subagents stay off unless the initial call sets
`allow_subagents: true`; even then they are Codex-only in-process workers and
cannot re-enter this MCP bridge.

Workspace-write network access defaults to `true` so commands can reach local
services. Codex does not provide a localhost-only switch: enabling it permits
general outbound access while filesystem writes remain sandbox-bounded.

Approval policy is server-owned and defaults to `never`. Accepted startup values
are `untrusted`, `on-request`, and `never`. The old `on-failure` value is not
supported by App Server and is rejected with a migration error.

App Server approvals and structured questions are correlated to their turn,
assigned wrapper-owned interaction IDs, and resolved exactly once. A client that
advertises MCP form elicitation can answer foreground requests inline. A
foreground call from a non-eliciting client fails with
`codex_interaction_requires_background`; start that work as a background job,
then use `codex-interactions` and `codex-interaction-resolve`. Secret-input
requests are rejected rather than queued or logged. Interaction waiting does
not trigger the idle watchdog, but the immutable hard call deadline continues
to run.

</details>

<details>
<summary>Progress, cancellation, and jobs</summary>

Blocking calls remain the preferred path, including for long builds. When the
caller supplies an MCP progress token, the adapter sends throttled,
privacy-safe status without exposing prompts, final-answer drafts, command
strings or output, paths, tool arguments, or hidden reasoning.

Background jobs remain connection-local. At most eight are active and 32 are
retained for one hour; commentary and final results are read in bounded pages.
Use jobs when work must outlive the caller or a client cannot render MCP
progress.

Cancellation maps to native `turn/interrupt` and is best-effort. A canceled or
timed-out write-capable turn may still have changed the workspace, so inspect
state before retrying. MCP deliberately emits no response after the client has
canceled that request; the bridge still settles its local handler after the
configured grace while retaining liveness and ownership for any native turn
that may still be writing.

While the MCP connection remains open, elapsed time alone never releases
ownership: native completion or generation termination must prove the writer
stopped. Client disconnect cancels connection-local jobs and open turns, then
reaps the private App Server process group within a bounded grace period.

</details>

### `codex-legacy`: temporary native compatibility

`codex-legacy` preserves the complete 0.28 native MCP bridge and runs the
deprecated `codex mcp-server` command directly. It is a migration escape hatch,
not a fallback. It receives security and compatibility fixes but no App
Server-only capabilities, and any later removal will be called out as a
breaking change.

<details>
<summary>Legacy behavior and migration details</summary>

The provider retains `codex`, `codex-reply`, `codex-start`,
`codex-reply-start`, `codex-status`, `codex-commentary`, `codex-result`,
`codex-cancel`, and `codex-peek`, including native MCP framing, validation,
auth handling, watchdogs, and connection-local jobs.

It does not expose App Server-only steering, native goals, reviews, thread
administration, structured interactions, durable project state, retention, or
cross-reconnect recovery. Its `goal` behavior remains the legacy
instruction/prompt transformation.

Exact compatibility also preserves private homes beneath the server startup
directory at `tmp/codex-homes/`. Those directories and copied auth files are
permission-hardened and stale homes are swept, but the provider does not adopt
the App Server provider's external durable-state design.

To temporarily move an existing MCP entry back to native MCP, change only the
provider argument:

```json
{
  "mcpServers": {
    "codex": {
      "type": "stdio",
      "command": "mcp-agents",
      "args": ["--provider", "codex-legacy"],
      "timeout": 7500000
    }
  }
}
```

Keeping the server key as `codex` preserves client-side tool names such as
`mcp__codex__codex`. Running both providers side by side requires two server
keys and therefore two client namespaces; permission and hook rules matching
the old namespace must then be updated. App Server state and retention flags
are rejected by `codex-legacy` rather than silently ignored.

</details>

### `claude`: blocking help and background reviews

For substantial second opinions and code reviews:

1. Call `claude-start` with the complete review prompt and an absolute `cwd`.
2. Call `claude-status` with the returned `jobId` and `cursor`, repeating with
   each new cursor until the state is terminal.
3. When the state is `completed`, call `claude-result` and continue from
   `nextOffset` until `done` is `true`.
4. Call `claude-cancel` if the verdict is no longer needed.

Use the blocking `claude_code` tool only for small prompts that can comfortably
finish inside one MCP request.

<details>
<summary>Claude tool contracts, limits, and isolation</summary>

| Tool | Required arguments | Optional arguments |
| --- | --- | --- |
| `claude-start` | `prompt`, absolute `cwd` | — |
| `claude-status` | `jobId`, `cursor` | `wait_ms` |
| `claude-result` | `jobId` | `offset` |
| `claude-cancel` | `jobId` | — |

`claude-status` long-polls for 10 seconds by default and accepts `wait_ms` up to
60 seconds. Canceling a status poll does not cancel its job. Jobs are one-shot
and local to the current MCP connection: there are no reply sessions, and a
disconnect cancels active work.

The server allows eight active and 32 retained jobs, keeps terminal jobs for
one hour, pages results at 32,768 Unicode code points, and rejects a final
result over 10 MiB. Background reviews have a bridge-owned two-hour deadline;
operators can replace it with `--timeout <seconds>` at server startup.

Claude is pinned to `claude-fable-5-1` at effort `xhigh`, falls back to
`claude-opus-5` when that model is overloaded or unavailable, and runs as a
leaf reviewer. It keeps project instructions and repository context but disables
hooks, subagents, skills, slash commands, external MCP servers, and mutation
tools. Only `Read`, `Glob`, `Grep`, and plan-mode read-only `Bash` inspection
are available. The leaf instruction also forbids test execution, installs,
delegation, and external side effects.

Intermediate model output, tool inputs and results, paths, and reasoning are
not forwarded through MCP; only sanitized phase status and the final verdict
are exposed.

#### `claude_code` parameters

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `prompt` | `string` | yes | Prompt sent to Claude Code |
| `timeout_ms` | `integer` | no | Timeout in milliseconds; default 900,000 / 15 minutes |

Additional `tools/call` arguments such as `model`, `effort`, or `config` are
ignored. Calls run with `--output-format json`; the bridge returns the assistant
`result` text or an MCP error when `is_error=true`.

</details>

### `gemini`: Antigravity prompt runner

The `gemini` provider invokes Google's Gemini-backed Antigravity CLI, `agy`. It
is intentionally a small blocking provider:

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `prompt` | `string` | yes | Prompt sent to `agy` |
| `timeout_ms` | `integer` | no | Timeout in milliseconds; default 300,000 / 5 minutes |

Additional arguments are ignored. `agy` always runs with `--sandbox`; there is
no per-call sandbox toggle.

### `browser`: advanced remote Chrome pass-through

The browser provider starts a local `chrome-devtools-mcp` process and lazily
acquires a remote Chrome lease on the first browser tool call. The MCP server
and every file it writes remain local; only Chrome DevTools Protocol traffic
crosses the operator-provided loopback tunnel.

There are no wrapper-owned acquire, status, release, job, or cancellation
tools. Calls arriving during acquisition share one provisioning attempt and
remain in FIFO order.

<details>
<summary>Browser lease protocol, setup, and safety model</summary>

#### Quick setup with crabbox

The provider pairs well with **crabbox**: ephemeral, single-tenant boxes that
terminate on their own caps.

The injected `acquire` helper leases a box, starts Chromium with a remote
debugging port, opens a matching SSH loopback tunnel, and waits for
`/json/version` on the local port. When ready, it prints inert UTF-8
`key=value` data:

```text
record_version=1
state=ready
generation=<opaque token>
local_cdp_port=<the port you were given>
browser_url=http://127.0.0.1:<that same port>
```

Use a matching SSH `-R` tunnel for `--app-port` when the page under test is
served on the local machine. `status` rechecks the lease, `release` tears it
down, and exit `69` keeps the lane fail-closed.

The provider itself has no cloud or SSH knowledge. The injected command owns
the lease and receives:

```text
acquire --session <id> --local-cdp-port <port> --viewport <WxH> [--app-port <port>]
status --session <id> [--generation <token>]
release --session <id> --generation <token> --reason idle|shutdown
```

Successful acquire output must contain a version-1 ready record, generation,
selected local CDP port, and matching browser URL. Exit `69` returns “GUI not
verified — no browser box available” and never launches a local browser. A
helper-reported local dev-server preflight error is preserved verbatim.

Exit `75` reports a loopback bind race. `mcp-agents` chooses a new port,
restarts the downstream, replays the original MCP initialize capabilities and
initialized notification, and retries at most three times without exposing a
duplicate initialize result.

#### Chrome DevTools MCP resolution

`chrome-devtools-mcp` is deliberately not pinned. Resolution is deterministic:

1. `--browser_command` or `MCP_AGENTS_BROWSER_COMMAND`
2. A package-local resolvable `chrome-devtools-mcp`, then
   `node_modules/.bin/chrome-devtools-mcp`
3. `npx -y chrome-devtools-mcp@latest`

The third path may delay first initialize on npm resolution. Install
`chrome-devtools-mcp` beside `mcp-agents` or provide an explicit command for
faster startup; pin it there when a deployment requires a fixed version. The
package's Node 26 floor stays at or above the downstream's current requirement.

The dependency is development-only. A checkout uses the package-local path;
published consumers use the `npx` fallback unless they install it separately or
provide a command.

| CLI flag | Default | Environment |
| --- | --- | --- |
| `--browser_lease_command <command-or-json-argv>` | required | `MCP_AGENTS_BROWSER_LEASE_COMMAND` |
| `--browser_command <command-or-json-argv>` | resolution order above | `MCP_AGENTS_BROWSER_COMMAND` |
| `--browser_idle_timeout <seconds>` | `600`; `0` disables | `MCP_AGENTS_BROWSER_IDLE_TIMEOUT` |
| `--browser_viewport <WxH>` | `1440x900` | `MCP_AGENTS_BROWSER_VIEWPORT` |
| `--browser_app_port <port>` | omitted | `MCP_AGENTS_BROWSER_APP_PORT` |
| `--browser_log_file <path>` | omitted | `MCP_AGENTS_BROWSER_LOG_FILE` |
| `--browser_allowed_url_pattern <pattern>` | omitted; repeatable | `MCP_AGENTS_BROWSER_ALLOWED_URL_PATTERN` |

The viewport is passed to the lease helper. Chrome DevTools MCP's `--viewport`
is intentionally omitted because it is inert when attaching through
`--browserUrl`.

#### Lease lifecycle and failure semantics

Every complete downstream JSON-RPC frame resets the generation idle timer;
stderr and partial output do not. Idle release has a 60-second cleanup bound,
while shutdown release uses a separate 15-second bound. Both are best-effort
cost optimizations.

If Chrome disappears, the interrupted native connect error is not replayed. A
helper status of `69` enriches it with `browser_lease_replaced`, warning that
the browser was replaced, state was lost, the interrupted outcome is unknown,
and callers must inspect state before retrying. Status `0` preserves the native
error; status `70` remains unknown. The next browser call reacquires and uses
Chrome DevTools MCP's reconnect path.

The client initialize frame and downstream `roots/list` request and response
are forwarded without ID or URI rewriting. After a downstream restart,
responses owed to the terminated process are discarded and old correlations
are retired before a replacement can reuse an ID. This preserves Chrome
DevTools MCP's local file-write allowlist, so `--allowUnrestrictedPaths` is
never passed.

Performance trace and Lighthouse descriptions warn that measurements over a
remote link are not gates. `upload_file` warns that a local path cannot be
handed directly to remote Chromium.

URL restrictions are opt-in because a loopback-only default would break OAuth
and third-party assets. A hardened deployment can repeat:

```bash
--browser_allowed_url_pattern 'http://127.0.0.1/*' \
--browser_allowed_url_pattern 'https://127.0.0.1/*'
```

Use the narrowest patterns compatible with the application. The provider does
not enable experimental page-ID routing: one process owns one lease, profile,
and port.

</details>

## Development

```bash
npm install
npm link
```

`npm link` symlinks `mcp-agents` into the active Node installation. Edits to
`server.js` or `codex-legacy.js` then take effect immediately without a rebuild
or reinstall.

Benchmark launch through real temporary-project MCP configurations:

```bash
npm run bench:mcp-startup
```

The benchmark measures `initialize` through `tools/list` and does not call an
agent model or tool.

Run the deterministic suite without real CLI calls:

```bash
SKIP_INTEGRATION=1 ./test.sh
```

For a real Claude background smoke check, call `claude-start` with a short
review prompt and this repository as `cwd`, poll `claude-status` with every new
cursor, and read the verdict with `claude-result`. For the inverse direction,
have Claude Code call `codex-start`, poll `codex-status`, and read
`codex-result`.

## How it works

1. An MCP client either starts `mcp-agents` over stdio or connects to an
   authenticated loopback HTTP daemon.
2. The server selects one `--provider <name>` at startup; the default is
   `codex`.
3. The selected provider registers its own tools:
   - Claude exposes one blocking tool plus one-shot review jobs.
   - Codex exposes a wrapper-owned MCP surface and lazily starts App Server.
   - Antigravity exposes one blocking prompt tool.
   - Browser proxies a downstream Chrome DevTools MCP server.
   - `codex-legacy` runs the sealed native MCP bridge.
4. The client calls a tool with provider-specific arguments.
5. The bridge normalizes lifecycle and results without leaking vendor protocols
   onto MCP stdout.

Claude review jobs parse stream JSON. The Codex adapter correlates documented
thread, turn, and item events into privacy-safe progress, durable thread IDs,
and retained result pages. The legacy provider transforms and observes native
MCP frames. The browser provider validates every result against its lease
generation.

A small keepalive prevents a stdio bridge from exiting when stdin reaches EOF
before an asynchronous subprocess registers an active handle. When that MCP
connection closes, active Claude and Codex work receives a native interrupt
where available, followed by bounded TERM/KILL fallback. Remaining tracked
detached process groups are reaped before the bridge exits. The HTTP Codex host
instead pools one lazy App Server runtime per canonical project root and reaps
it after the configured idle period.

## License

MIT
