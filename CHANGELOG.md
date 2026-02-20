# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

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
