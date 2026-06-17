# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
