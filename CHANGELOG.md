# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

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
