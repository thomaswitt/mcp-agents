# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

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
