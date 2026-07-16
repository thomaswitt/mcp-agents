#!/usr/bin/env node
/* eslint-disable no-console */

import { randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import {
  closeSync,
  copyFileSync,
  existsSync,
  mkdtempSync,
  openSync,
  readFileSync,
  renameSync,
  rmSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, isAbsolute, join } from "node:path";
import { fileURLToPath } from "node:url";

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const VERSION = JSON.parse(
  readFileSync(join(__dirname, "package.json"), "utf8"),
).version;

const DEFAULT_TIMEOUT_MS = 300_000;
const DEFAULT_CLAUDE_TIMEOUT_MS = 900_000;
const DEFAULT_CODEX_TIMEOUT_MS = 7_200_000;
const DEFAULT_CODEX_MODEL = "gpt-5.6-sol";
const DEFAULT_CODEX_MODEL_REASONING_EFFORT = "xhigh";
const DEFAULT_CODEX_SANDBOX_MODE = "workspace-write";
const DEFAULT_CODEX_APPROVAL_POLICY = "never";
// Correlated watchdogs for the codex pass-through. Only a codex/event carrying
// the matching MCP request id extends a call's idle window; stderr, pings, and
// unrelated calls cannot keep a wedged request alive. 0 disables the idle cap.
const DEFAULT_CODEX_IDLE_TIMEOUT_MS = 600_000;
const DEFAULT_CODEX_TERMINAL_GRACE_MS = 1_000;
const DEFAULT_CODEX_CANCEL_GRACE_MS = 3_000;
const DEFAULT_CODEX_PROGRESS_INTERVAL_MS = 1_000;
const DEFAULT_CODEX_WAIT_INTERVAL_MS = 10_000;
const MAX_CODEX_STATUS_WAIT_MS = 60_000;
const MAX_CODEX_PROGRESS_CODEPOINTS = 200;
const MAX_CODEX_PAGE_CODEPOINTS = 32_768;
const MAX_CODEX_COMMENTARY_BYTES = 1024 * 1024;
const MAX_ACTIVE_CODEX_JOBS = 8;
const MAX_RETAINED_CODEX_JOBS = 32;
const CODEX_JOB_RETENTION_MS = 60 * 60 * 1_000;
const MAX_SUPPRESSED_CODEX_RESPONSES = 32;
const DEFAULT_CLAUDE_MODEL = "claude-opus-4-8";
const DEFAULT_CLAUDE_EFFORT = "xhigh";
const CODEX_PER_SESSION_REASONING_EFFORT_ARG = "model_reasoning_effort";
const CODEX_PER_SESSION_REASONING_EFFORTS = ["xhigh", "max"];
const CODEX_PER_SESSION_REASONING_EFFORT_SET = new Set(
  CODEX_PER_SESSION_REASONING_EFFORTS,
);
const CODEX_SANDBOXES = ["read-only", "workspace-write", "danger-full-access"];
const CODEX_SANDBOX_SET = new Set(CODEX_SANDBOXES);
const CODEX_TOOL_CONTRACTS = {
  codex: {
    allowed: ["prompt", "cwd", "sandbox", CODEX_PER_SESSION_REASONING_EFFORT_ARG, "goal"],
    required: ["prompt", "cwd", "sandbox", CODEX_PER_SESSION_REASONING_EFFORT_ARG],
  },
  "codex-reply": {
    allowed: ["prompt", "threadId", "goal"],
    required: ["prompt", "threadId"],
  },
};
const CODEX_JOB_TOOL_CONTRACTS = {
  "codex-start": {
    allowed: [...CODEX_TOOL_CONTRACTS.codex.allowed],
    required: [...CODEX_TOOL_CONTRACTS.codex.required],
  },
  "codex-reply-start": {
    allowed: [...CODEX_TOOL_CONTRACTS["codex-reply"].allowed],
    required: [...CODEX_TOOL_CONTRACTS["codex-reply"].required],
  },
  "codex-status": {
    allowed: ["jobId", "cursor", "wait_ms"],
    required: ["jobId", "cursor"],
  },
  "codex-commentary": {
    allowed: ["jobId", "offset"],
    required: ["jobId"],
  },
  "codex-result": {
    allowed: ["jobId", "offset"],
    required: ["jobId"],
  },
  "codex-cancel": {
    allowed: ["jobId"],
    required: ["jobId"],
  },
};
const CODEX_JOB_TOOL_NAMES = Object.keys(CODEX_JOB_TOOL_CONTRACTS);
const TERMINAL_CODEX_JOB_STATES = new Set(["completed", "failed", "canceled"]);
const MAX_BUFFER_BYTES = 10 * 1024 * 1024;
const CLAUDE_EMPTY_OUTPUT_MAX_ATTEMPTS = 2;
const SIGNAL_CODES = { SIGHUP: 1, SIGINT: 2, SIGKILL: 9, SIGTERM: 15 };
const SHUTDOWN_TIMEOUT_MS = 3_000;
let fatalShutdown;

const testTunableMs = (name, fallback) => {
  const value = process.env[name];
  if (value == null) return fallback;
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? Math.round(parsed) : fallback;
};

// ---------------------------------------------------------------------------
// CLI Backend Definitions
// ---------------------------------------------------------------------------

const CLI_BACKENDS = {
  claude: {
    command: "claude",
    toolName: "claude_code",
    description:
      `Run Claude Code CLI with a prompt (via stdin), pinned to ${DEFAULT_CLAUDE_MODEL} at effort ${DEFAULT_CLAUDE_EFFORT}. Supports prompt + optional timeout_ms only; other arguments (model/effort/config) are ignored.`,
    stdinPrompt: true,
    buildArgs: () => [
      "--model",
      DEFAULT_CLAUDE_MODEL,
      "--effort",
      DEFAULT_CLAUDE_EFFORT,
      "--no-session-persistence",
      "-p",
      "--output-format",
      "json",
    ],
    extraProperties: {},
    defaultTimeoutMs: DEFAULT_CLAUDE_TIMEOUT_MS,
  },
  gemini: {
    command: "agy",
    toolName: "gemini",
    description:
      "Run the Antigravity CLI (`agy`, Google's Gemini-backed agent) with a prompt. Always runs in --sandbox mode (terminal restrictions enabled).",
    stdinPrompt: false,
    isolateCwd: true,
    buildArgs: (prompt) => ["--sandbox", "-p", prompt],
    extraProperties: {},
  },
  codex: {
    passthrough: true,
  },
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Never write debug logs to stdout (it breaks MCP stdio transport).
 * Use stderr only.
 */
function logErr(message) {
  process.stderr.write(`${message}\n`);
}

/**
 * Defensive string conversion for tool args.
 * @param {unknown} value
 * @returns {string}
 */
function toStringArg(value) {
  if (typeof value === "string") return value;
  if (value == null) return "";
  return String(value);
}

/**
 * Normalize provider output and parse Claude's JSON print format when present.
 * `--output-format json` emits either a single `{type:"result"}` object or
 * (newer CLIs, e.g. 2.1.x) an array of stream events whose final
 * `type:"result"` entry holds the answer; both are supported.
 * @param {string} provider
 * @param {string} output
 * @returns {{ text: string, isError: boolean }}
 */
function normalizeToolOutput(provider, output) {
  if (provider !== "claude") return { text: output, isError: false };

  const trimmed = output.trim();
  if (!trimmed) return { text: "", isError: false };

  try {
    const parsed = JSON.parse(trimmed);
    // Resolve the result event from either shape. Scanning from the end finds
    // the terminal result without depending on Array.prototype.findLast
    // (keeps the Node >=18 floor — see engines).
    let result = parsed;
    if (Array.isArray(parsed)) {
      result = null;
      for (let i = parsed.length - 1; i >= 0; i--) {
        const event = parsed[i];
        if (event && typeof event === "object" && event.type === "result") {
          result = event;
          break;
        }
      }
    }
    if (result && typeof result === "object" && result.type === "result") {
      return {
        text: toStringArg(result.result),
        isError: result.is_error === true,
      };
    }
  } catch {
    // Fall back to raw text if output shape changes or isn't JSON.
  }

  return { text: output, isError: false };
}

/**
 * Print usage information to stdout.
 */
function printHelp() {
  const providers = Object.keys(CLI_BACKENDS).join(", ");
  console.log(`mcp-agents v${VERSION}

Usage: mcp-agents [options]

Options:
  --provider <name>              CLI backend to use (${providers}) [default: codex]
  --model <model>                Codex model [default: ${DEFAULT_CODEX_MODEL}]
  --model_reasoning_effort <e>   Codex reasoning effort [default: ${DEFAULT_CODEX_MODEL_REASONING_EFFORT}]
  --sandbox_mode <mode>          Codex sandbox mode: read-only, workspace-write,
                                 danger-full-access [default: ${DEFAULT_CODEX_SANDBOX_MODE}]
  --approval_policy <policy>     Codex approval policy: untrusted, on-failure,
                                 on-request, never [default: ${DEFAULT_CODEX_APPROVAL_POLICY}]
  --goal <text>                  Persistent objective injected into every Codex
                                 call (as developer-instructions, or a prompt
                                 reminder on codex-reply); per-call \`goal\` arg
                                 overrides it [default: none]
  --codex_idle_timeout <secs>    Codex pass-through idle watchdog; 0 disables
                                 [default: ${DEFAULT_CODEX_IDLE_TIMEOUT_MS / 1000}]
  --timeout <seconds>            Default timeout per call
                                 [default: codex ${DEFAULT_CODEX_TIMEOUT_MS / 1000}, claude ${DEFAULT_CLAUDE_TIMEOUT_MS / 1000}, gemini ${DEFAULT_TIMEOUT_MS / 1000}]
  --help, -h                     Show this help message
  --version, -v                  Show version number`);
}

/**
 * Parse CLI flags from process.argv.
 * Handles --help, --version, --provider, --model, --model_reasoning_effort,
 * --sandbox_mode, --approval_policy, --goal, --codex_idle_timeout, and unknown
 * flags.
 * @returns {{ provider: string, model?: string, modelReasoningEffort?: string, sandboxMode?: string, approvalPolicy?: string, goal?: string, codexIdleTimeoutMs?: number, defaultTimeoutMs?: number }}
 */
function parseArgs() {
  const args = process.argv.slice(2);
  let provider = "codex";
  let model;
  let modelReasoningEffort;
  let sandboxMode;
  let approvalPolicy;
  let goal;
  let codexIdleTimeoutMs;
  let defaultTimeoutMs;

  for (let i = 0; i < args.length; i++) {
    switch (args[i]) {
      case "--help":
      case "-h":
        printHelp();
        process.exit(0);
        break;
      case "--version":
      case "-v":
        console.log(`mcp-agents v${VERSION}`);
        process.exit(0);
        break;
      case "--provider":
        if (i + 1 >= args.length) {
          process.stderr.write("error: --provider requires a value\n");
          process.exit(1);
        }
        provider = args[++i];
        break;
      case "--model":
        if (i + 1 >= args.length) {
          process.stderr.write("error: --model requires a value\n");
          process.exit(1);
        }
        model = args[++i];
        break;
      case "--model_reasoning_effort":
        if (i + 1 >= args.length) {
          process.stderr.write(
            "error: --model_reasoning_effort requires a value\n",
          );
          process.exit(1);
        }
        modelReasoningEffort = args[++i];
        break;
      case "--sandbox_mode":
        if (i + 1 >= args.length) {
          process.stderr.write("error: --sandbox_mode requires a value\n");
          process.exit(1);
        }
        sandboxMode = args[++i];
        break;
      case "--approval_policy":
        if (i + 1 >= args.length) {
          process.stderr.write("error: --approval_policy requires a value\n");
          process.exit(1);
        }
        approvalPolicy = args[++i];
        break;
      case "--goal":
        if (i + 1 >= args.length) {
          process.stderr.write("error: --goal requires a value\n");
          process.exit(1);
        }
        goal = args[++i];
        break;
      case "--codex_idle_timeout": {
        if (i + 1 >= args.length) {
          process.stderr.write("error: --codex_idle_timeout requires a value\n");
          process.exit(1);
        }
        const secs = Number(args[++i]);
        if (!Number.isFinite(secs) || secs < 0) {
          process.stderr.write(
            "error: --codex_idle_timeout must be a non-negative number\n",
          );
          process.exit(1);
        }
        codexIdleTimeoutMs = Math.round(secs * 1000);
        break;
      }
      case "--timeout": {
        if (i + 1 >= args.length) {
          process.stderr.write("error: --timeout requires a value\n");
          process.exit(1);
        }
        const secs = Number(args[++i]);
        if (!(secs > 0)) {
          process.stderr.write("error: --timeout must be a positive number\n");
          process.exit(1);
        }
        defaultTimeoutMs = Math.round(secs * 1000);
        break;
      }
      default:
        process.stderr.write(`error: unknown option: ${args[i]}\n`);
        process.exit(1);
    }
  }

  return {
    provider,
    model,
    modelReasoningEffort,
    sandboxMode,
    approvalPolicy,
    goal,
    codexIdleTimeoutMs,
    defaultTimeoutMs,
  };
}

/**
 * Run a CLI command and return stdout (or stderr if stdout is empty).
 * Uses spawn with detached:true so the entire process group can be killed
 * on timeout — prevents orphan child processes.
 * @param {string} command
 * @param {string[]} args
 * @param {{
 *   timeoutMs?: number,
 *   stdinData?: string,
 *   cwd?: string,
 *   onSpawn?: (childInfo: { pid?: number, killGroup: () => void }) => void,
 *   onSettled?: (pid?: number) => void,
 * }} [opts]
 * @returns {Promise<{ output: string, stdoutBytes: number, stderrBytes: number, durationMs: number }>}
 */
function runCli(command, args, opts = {}) {
  const timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const stdinData = opts.stdinData;
  const cwd = opts.cwd;
  const onSpawn = opts.onSpawn;
  const onSettled = opts.onSettled;
  const startedAt = Date.now();

  return new Promise((resolve, reject) => {
    let stdout = "";
    let stderr = "";
    let stdoutLen = 0;
    let stderrLen = 0;
    let settled = false;

    const child = spawn(command, args, {
      cwd,
      detached: true,
      stdio: ["pipe", "pipe", "pipe"],
      env: { ...process.env, NO_COLOR: "1" },
    });

    // Pipe prompt via stdin to avoid arg-quoting issues, then close.
    child.stdin?.on("error", () => {}); // ignore EPIPE if child exits early
    if (stdinData != null) {
      child.stdin?.end(stdinData, "utf8");
    } else {
      child.stdin?.end();
    }

    const killGroup = () => {
      try { process.kill(-child.pid, "SIGKILL"); } catch {}
    };
    onSpawn?.({ pid: child.pid, killGroup });

    const done = (err) => {
      clearTimeout(timer);
      if (settled) return;
      settled = true;
      onSettled?.(child.pid);
      err ? reject(err) : resolve({
        output: (stdout || stderr || "").trimEnd(),
        stdoutBytes: stdoutLen,
        stderrBytes: stderrLen,
        durationMs: Date.now() - startedAt,
      });
    };

    child.stdout.on("data", (chunk) => {
      stdoutLen += chunk.length;
      if (stdoutLen > MAX_BUFFER_BYTES) {
        killGroup();
        done(new Error(`${command} stdout maxBuffer exceeded`));
      } else {
        stdout += chunk;
      }
    });

    child.stderr.on("data", (chunk) => {
      stderrLen += chunk.length;
      if (stderrLen > MAX_BUFFER_BYTES) {
        killGroup();
        done(new Error(`${command} stderr maxBuffer exceeded`));
      } else {
        stderr += chunk;
      }
    });

    // Kill entire process group on timeout (prevents orphan processes).
    const timer = setTimeout(() => {
      killGroup();
    }, timeoutMs);
    timer.unref();

    child.on("error", (err) => {
      done(new Error(`Failed to start ${command}: ${err.message}`));
    });

    child.on("close", (code, signal) => {
      if (signal || code !== 0) {
        const reason = signal ? `killed by ${signal}` : `exit code ${code}`;
        const details = [
          `${command} failed: ${reason}`,
          stderr ? `stderr:\n${stderr}` : null,
        ]
          .filter(Boolean)
          .join("\n");
        done(new Error(details));
        return;
      }
      done(null);
    });
  });
}

/**
 * Create a fresh, empty working directory under the OS temp dir for an
 * agentic CLI. Agentic CLIs (e.g. agy/Antigravity) treat their cwd as a
 * workspace and write project files into it; running them here keeps them
 * from mutating whatever directory the MCP server was started in.
 * @param {string} provider
 * @returns {string}
 */
function createIsolatedWorkdir(provider) {
  return mkdtempSync(join(tmpdir(), `mcp-agents-${provider}-`));
}

/**
 * Resolve the source Codex home used by the parent process.
 * @returns {string}
 */
function resolveCodexHome() {
  return process.env.CODEX_HOME || join(process.env.HOME || tmpdir(), ".codex");
}

/**
 * Quote a string for TOML output.
 * @param {string} value
 * @returns {string}
 */
function toTomlString(value) {
  return JSON.stringify(value);
}

/**
 * Build the minimal config for the isolated Codex bridge runtime.
 * @param {{ model: string, modelReasoningEffort: string, sandboxMode: string, approvalPolicy: string }} opts
 * @returns {string}
 */
function buildCodexBridgeConfig({
  model,
  modelReasoningEffort,
  sandboxMode,
  approvalPolicy,
}) {
  return [
    `model = ${toTomlString(model)}`,
    `model_reasoning_effort = ${toTomlString(modelReasoningEffort)}`,
    `approval_policy = ${toTomlString(approvalPolicy)}`,
    `sandbox_mode = ${toTomlString(sandboxMode)}`,
    'web_search = "cached"',
    "check_for_update_on_startup = false",
    "allow_login_shell = false",
    "",
    "[history]",
    'persistence = "none"',
    "",
    "[features]",
    "apps = false",
    "hooks = false",
    "plugins = false",
    "multi_agent = false",
    "skill_mcp_dependency_install = false",
    "",
  ].join("\n");
}

/**
 * Create an isolated Codex home that preserves auth but strips inherited MCP servers.
 * @param {{ model: string, modelReasoningEffort: string, sandboxMode: string, approvalPolicy: string }} opts
 * @returns {string}
 */
function createIsolatedCodexHome({
  model,
  modelReasoningEffort,
  sandboxMode,
  approvalPolicy,
}) {
  const codexHome = mkdtempSync(join(tmpdir(), "mcp-agents-codex-"));
  // If auth copy or config write throws after the dir exists, remove the
  // partially-prepared dir before rethrowing so it is never leaked.
  try {
    const sourceAuthPath = join(resolveCodexHome(), "auth.json");
    const targetAuthPath = join(codexHome, "auth.json");
    const configPath = join(codexHome, "config.toml");

    if (existsSync(sourceAuthPath)) {
      copyFileSync(sourceAuthPath, targetAuthPath);
    }

    writeFileSync(
      configPath,
      buildCodexBridgeConfig({
        model,
        modelReasoningEffort,
        sandboxMode,
        approvalPolicy,
      }),
      "utf8",
    );

    return codexHome;
  } catch (err) {
    try { rmSync(codexHome, { recursive: true, force: true }); } catch {}
    throw err;
  }
}

/**
 * Persist a refreshed auth.json from the isolated Codex home back to the real
 * CODEX_HOME. Codex rotates its OAuth refresh token in place during a request;
 * because createIsolatedCodexHome() only copies auth.json IN and the temp home
 * is removed on teardown, the rotated token is otherwise lost and the canonical
 * auth.json keeps a stale (soon-revoked) refresh token — so the next bridge
 * spawn, and any parallel Codex client, hits "refresh token already used /
 * revoked" until a manual `codex login`.
 *
 * Best-effort and synchronous (runs from the process "exit" path). Writes
 * atomically via an exclusive same-directory temp + rename so the canonical
 * auth.json is never left truncated and never inherits stale temp permissions.
 * No-ops when auth was never copied in (API-key mode) or when the token is
 * unchanged.
 */
function persistIsolatedCodexAuth(isolatedCodexHome) {
  try {
    const realHome = resolveCodexHome();
    const canonical = join(realHome, "auth.json");
    const rotated = join(isolatedCodexHome, "auth.json");
    if (!existsSync(rotated) || !existsSync(canonical)) return;

    const rotatedBuf = readFileSync(rotated);
    if (rotatedBuf.equals(readFileSync(canonical))) return; // unchanged → skip

    const tmp = join(
      realHome,
      `.auth.json.mcp-agents-${process.pid}-${randomUUID()}.tmp`,
    );
    let fd;
    try {
      fd = openSync(tmp, "wx", 0o600);
      writeFileSync(fd, rotatedBuf);
      closeSync(fd);
      fd = undefined;
      renameSync(tmp, canonical); // atomic replace on the same filesystem
    } catch (err) {
      if (fd !== undefined) {
        try { closeSync(fd); } catch {}
      }
      try { unlinkSync(tmp); } catch {}
      throw err;
    }
    logErr("[mcp-agents] persisted refreshed Codex auth.json back to CODEX_HOME");
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    logErr(`[mcp-agents] failed to persist Codex auth.json: ${msg}`);
  }
}

/**
 * Build the text for codex's native `developer-instructions` field (a
 * developer-role message) from a goal. This is the MCP-correct vehicle for a
 * standing objective: it is higher-altitude than the user prompt and persists
 * across the thread. It is NOT codex's `/goal` subsystem — that is a TUI-only
 * slash command (parsed in codex-rs/tui, e.g. chatwidget/slash_dispatch.rs) and
 * is not reachable through the MCP `codex`/`codex-reply` tool surface.
 * @param {string} goal
 * @returns {string}
 */
function buildGoalDeveloperInstructions(goal) {
  return (
    "Persistent objective for this Codex thread (a standing goal — keep " +
    "pursuing it across turns unless explicitly superseded):\n" +
    goal.trim()
  );
}

/**
 * Prepend a concise goal reminder to a prompt. Used for `codex-reply` turns,
 * which expose no `developer-instructions` field, so the prompt is the only
 * vehicle left to restate the standing objective. A blank goal leaves the
 * prompt untouched.
 * @param {string} prompt
 * @param {string} goal
 * @returns {string}
 */
function applyGoalPreamble(prompt, goal) {
  const trimmedGoal = (goal ?? "").trim();
  const body = prompt ?? "";
  if (!trimmedGoal) return body;
  return `Reminder — standing objective for this thread: ${trimmedGoal}\n\n${body}`;
}

/**
 * Transform one already-validated newline-delimited `tools/call` frame before
 * forwarding it to native Codex:
 *   1. Translate the wrapper-only initial-session `model_reasoning_effort` into
 *      native `config.model_reasoning_effort`.
 *   2. Inject the wrapper-only goal — codex's native `/goal` is a TUI-only slash
 *      command, not
 *      reachable via MCP, so a wrapper-only `goal` arg is always stripped and the
 *      objective is injected the MCP-correct way: into `developer-instructions`
 *      (a developer-role message) for the initial `codex` call, or as a concise
 *      prompt reminder for a `codex-reply` turn (which has no
 *      `developer-instructions` field). A per-call `goal` overrides the
 *      server-wide `--goal` default (`opts.serverGoal`); a blank per-call goal
 *      suppresses the default for that call.
 * Non-`tools/call`, unparseable, and nothing-to-change lines are returned
 * byte-for-byte unchanged so the MCP framing is preserved; any actual mutation
 * re-serializes the message (the intended, framing-safe path for a changed
 * message).
 * @param {string} line
 * @param {{ serverGoal?: string }} [opts]
 * @returns {string}
 */
function transformCodexToolCall(line, opts = {}) {
  const trimmed = line.trim();
  if (!trimmed) return line;

  let msg;
  try {
    msg = JSON.parse(trimmed);
  } catch {
    return line; // not JSON (e.g. partial/keepalive) — pass through untouched
  }

  const args =
    msg && typeof msg === "object" && msg.method === "tools/call"
      ? msg.params?.arguments
      : null;
  if (!args || typeof args !== "object") return line;

  const toolName = msg.params?.name;
  if (!CODEX_TOOL_CONTRACTS[toolName]) return line;
  let changed = false;
  let effortLog;

  if (toolName === "codex") {
    const requestedSessionEffort = args[CODEX_PER_SESSION_REASONING_EFFORT_ARG];
    delete args[CODEX_PER_SESSION_REASONING_EFFORT_ARG];
    args.config = { model_reasoning_effort: requestedSessionEffort };
    effortLog = `applied per-session reasoning effort ${requestedSessionEffort}`;
    changed = true;
  }

  // ── Goal injection ────────────────────────────────────────────────────────
  // A validated per-call `goal` (including "") replaces the server default for
  // this call. The wrapper field is never forwarded to native Codex.
  let goalLog;
  let goalSource = "server";
  let effectiveGoal = opts.serverGoal;
  if ("goal" in args) {
    const perCallGoal = args.goal;
    delete args.goal;
    goalLog = "stripped per-call goal arg";
    effectiveGoal = perCallGoal;
    goalSource = "per-call";
    changed = true;
  }
  if (typeof effectiveGoal === "string" && effectiveGoal.trim()) {
    if (toolName === "codex") {
      // Initial `codex` call: the native developer-instructions field is the
      // correct, thread-persistent vehicle for a standing objective.
      args["developer-instructions"] = buildGoalDeveloperInstructions(effectiveGoal);
      goalLog = `injected ${goalSource} goal into developer-instructions`;
      changed = true;
    } else if (toolName === "codex-reply" && typeof args.prompt === "string") {
      // codex-reply has no developer-instructions field, so restate the
      // objective as a concise prompt reminder.
      args.prompt = applyGoalPreamble(args.prompt, effectiveGoal);
      goalLog = `injected ${goalSource} goal into codex-reply prompt`;
      changed = true;
    }
  }

  if (!changed) return line;
  if (effortLog) {
    logErr(`[mcp-agents] codex passthrough: ${effortLog}`);
  }
  if (goalLog) {
    logErr(`[mcp-agents] codex passthrough: ${goalLog}`);
  }
  return JSON.stringify(msg);
}

const CODEX_GOAL_PROPERTY_DESCRIPTION =
  "Optional standing objective. mcp-agents injects it as developer instructions " +
  "for a new session or a prompt reminder for a reply. An empty string suppresses " +
  "the server-wide goal for this call.";
const CODEX_PER_SESSION_REASONING_EFFORT_PROPERTY_DESCRIPTION =
  "Reasoning effort for this new session: xhigh for hard, bounded work or max " +
  "for quality-first work requiring deeper exploration. Replies inherit it.";

function codexToolPresentation(toolName) {
  if (toolName === "codex") {
    return {
      description:
        "Start a Codex session with an explicit workspace, sandbox, reasoning effort, " +
        "and optional standing goal.",
      inputSchema: {
        type: "object",
        properties: {
          prompt: {
            type: "string",
            description: "Initial user prompt for the Codex session.",
          },
          cwd: {
            type: "string",
            description: "Absolute working directory for the session.",
          },
          sandbox: {
            type: "string",
            enum: [...CODEX_SANDBOXES],
            description: "Sandbox mode for the session; it cannot change on replies.",
          },
          [CODEX_PER_SESSION_REASONING_EFFORT_ARG]: {
            type: "string",
            enum: [...CODEX_PER_SESSION_REASONING_EFFORTS],
            description: CODEX_PER_SESSION_REASONING_EFFORT_PROPERTY_DESCRIPTION,
          },
          goal: {
            type: "string",
            description: CODEX_GOAL_PROPERTY_DESCRIPTION,
          },
        },
        required: [...CODEX_TOOL_CONTRACTS.codex.required],
        additionalProperties: false,
      },
    };
  }
  if (toolName === "codex-reply") {
    return {
      description:
        "Continue a Codex session by thread ID. Sandbox and reasoning effort are inherited.",
      inputSchema: {
        type: "object",
        properties: {
          prompt: {
            type: "string",
            description: "Next user prompt for the Codex session.",
          },
          threadId: {
            type: "string",
            description: "Thread ID returned by the initial codex call.",
          },
          goal: {
            type: "string",
            description: CODEX_GOAL_PROPERTY_DESCRIPTION,
          },
        },
        required: [...CODEX_TOOL_CONTRACTS["codex-reply"].required],
        additionalProperties: false,
      },
    };
  }
  if (toolName === "codex-start") {
    const presentation = codexToolPresentation("codex");
    return {
      ...presentation,
      description:
        "Start an optional background Codex job. This returns immediately; call " +
        "codex-status with the returned job ID and cursor until the job is terminal.",
    };
  }
  if (toolName === "codex-reply-start") {
    const presentation = codexToolPresentation("codex-reply");
    return {
      ...presentation,
      description:
        "Start an optional background reply on an existing Codex thread. This returns " +
        "immediately; call codex-status until the job is terminal.",
    };
  }
  if (toolName === "codex-status") {
    return {
      description:
        "Poll a background Codex job. At the current cursor this waits for new status " +
        "or a heartbeat, producing an ordinary transcript-visible tool result.",
      inputSchema: {
        type: "object",
        properties: {
          jobId: { type: "string", description: "Opaque job ID returned by a start tool." },
          cursor: {
            type: "integer",
            minimum: 0,
            description: "Status cursor returned by the previous start or status result.",
          },
          wait_ms: {
            type: "integer",
            minimum: 0,
            maximum: MAX_CODEX_STATUS_WAIT_MS,
            description: "Long-poll duration in milliseconds; defaults to 10000.",
          },
        },
        required: [...CODEX_JOB_TOOL_CONTRACTS[toolName].required],
        additionalProperties: false,
      },
    };
  }
  if (toolName === "codex-commentary") {
    return {
      description:
        "Read retained, explicit user-visible commentary from a background Codex job. " +
        "This never exposes hidden reasoning and does not wait for new content.",
      inputSchema: {
        type: "object",
        properties: {
          jobId: { type: "string", description: "Opaque job ID returned by a start tool." },
          offset: {
            type: "integer",
            minimum: 0,
            description: "Absolute Unicode code-point offset; defaults to 0.",
          },
        },
        required: [...CODEX_JOB_TOOL_CONTRACTS[toolName].required],
        additionalProperties: false,
      },
    };
  }
  if (toolName === "codex-result") {
    return {
      description:
        "Read the final output of a completed background Codex job in bounded pages.",
      inputSchema: {
        type: "object",
        properties: {
          jobId: { type: "string", description: "Opaque job ID returned by a start tool." },
          offset: {
            type: "integer",
            minimum: 0,
            description: "Absolute Unicode code-point result offset; defaults to 0.",
          },
        },
        required: [...CODEX_JOB_TOOL_CONTRACTS[toolName].required],
        additionalProperties: false,
      },
    };
  }
  if (toolName === "codex-cancel") {
    return {
      description: "Idempotently cancel a background Codex job.",
      inputSchema: {
        type: "object",
        properties: {
          jobId: { type: "string", description: "Opaque job ID returned by a start tool." },
        },
        required: [...CODEX_JOB_TOOL_CONTRACTS[toolName].required],
        additionalProperties: false,
      },
    };
  }
  return undefined;
}

function validateCodexToolCallMessage(msg) {
  if (!msg || typeof msg !== "object" || msg.method !== "tools/call") return undefined;
  const toolName = msg.params?.name;
  const contract = CODEX_TOOL_CONTRACTS[toolName] ?? CODEX_JOB_TOOL_CONTRACTS[toolName];
  if (!contract) return undefined;
  const args = msg.params?.arguments;
  if (!args || typeof args !== "object" || Array.isArray(args)) {
    return {
      toolName,
      allowedArguments: [...contract.allowed],
      requiredArguments: [...contract.required],
      issues: [{ argument: "arguments", problem: "must be an object" }],
    };
  }

  const issues = [];
  for (const argument of contract.required) {
    if (!Object.hasOwn(args, argument)) {
      issues.push({ argument, problem: "is required" });
    }
  }
  const allowed = new Set(contract.allowed);
  for (const argument of Object.keys(args).sort()) {
    if (!allowed.has(argument)) {
      issues.push({ argument, problem: "is not supported" });
    }
  }
  if (Object.hasOwn(args, "prompt") && typeof args.prompt !== "string") {
    issues.push({ argument: "prompt", problem: "must be a string" });
  }
  if (Object.hasOwn(args, "cwd")) {
    if (typeof args.cwd !== "string") {
      issues.push({ argument: "cwd", problem: "must be a string" });
    } else if (!isAbsolute(args.cwd)) {
      issues.push({ argument: "cwd", problem: "must be an absolute path" });
    }
  }
  if (
    Object.hasOwn(args, "sandbox") &&
    (typeof args.sandbox !== "string" || !CODEX_SANDBOX_SET.has(args.sandbox))
  ) {
    issues.push({
      argument: "sandbox",
      problem: `must be one of: ${CODEX_SANDBOXES.join(", ")}`,
    });
  }
  if (Object.hasOwn(args, CODEX_PER_SESSION_REASONING_EFFORT_ARG)) {
    const effort = args[CODEX_PER_SESSION_REASONING_EFFORT_ARG];
    if (typeof effort !== "string" || !CODEX_PER_SESSION_REASONING_EFFORT_SET.has(effort)) {
      issues.push({
        argument: CODEX_PER_SESSION_REASONING_EFFORT_ARG,
        problem: `must be one of: ${CODEX_PER_SESSION_REASONING_EFFORTS.join(", ")}`,
      });
    }
  }
  if (Object.hasOwn(args, "goal") && typeof args.goal !== "string") {
    issues.push({ argument: "goal", problem: "must be a string" });
  }
  if (Object.hasOwn(args, "threadId")) {
    if (typeof args.threadId !== "string") {
      issues.push({ argument: "threadId", problem: "must be a string" });
    } else if (!args.threadId.trim()) {
      issues.push({ argument: "threadId", problem: "must not be blank" });
    }
  }
  if (Object.hasOwn(args, "jobId")) {
    if (typeof args.jobId !== "string") {
      issues.push({ argument: "jobId", problem: "must be a string" });
    } else if (!args.jobId.trim()) {
      issues.push({ argument: "jobId", problem: "must not be blank" });
    }
  }
  if (
    Object.hasOwn(args, "cursor") &&
    (!Number.isInteger(args.cursor) || args.cursor < 0)
  ) {
    issues.push({ argument: "cursor", problem: "must be a nonnegative integer" });
  }
  if (
    Object.hasOwn(args, "wait_ms") &&
    (!Number.isInteger(args.wait_ms) || args.wait_ms < 0 ||
      args.wait_ms > MAX_CODEX_STATUS_WAIT_MS)
  ) {
    issues.push({
      argument: "wait_ms",
      problem: `must be an integer from 0 to ${MAX_CODEX_STATUS_WAIT_MS}`,
    });
  }
  if (
    Object.hasOwn(args, "offset") &&
    (!Number.isInteger(args.offset) || args.offset < 0)
  ) {
    issues.push({ argument: "offset", problem: "must be a nonnegative integer" });
  }

  return issues.length > 0
    ? {
      toolName,
      allowedArguments: [...contract.allowed],
      requiredArguments: [...contract.required],
      issues,
    }
    : undefined;
}

function codexInvalidParamsFrame(id, validation) {
  return {
    jsonrpc: "2.0",
    id,
    error: {
      code: -32602,
      message: `mcp-agents: invalid arguments for ${validation.toolName}`,
      data: validation,
    },
  };
}

/**
 * Mutate a parsed `tools/list` response in place, replacing native Codex's broad
 * config-shaped inputs with the exact strict mcp-agents contract. Other tool
 * fields and non-Codex tools remain untouched.
 * @param {any} msg
 * @returns {boolean}
 */
function rewriteCodexToolsListMessage(msg) {
  const tools = msg?.result?.tools;
  if (!Array.isArray(tools)) return false;
  let changed = false;
  for (const tool of tools) {
    if (!tool || typeof tool !== "object") continue;
    const presentation = codexToolPresentation(tool.name);
    if (!presentation) continue;
    if (tool.description !== presentation.description) {
      tool.description = presentation.description;
      changed = true;
    }
    if (JSON.stringify(tool.inputSchema) !== JSON.stringify(presentation.inputSchema)) {
      tool.inputSchema = presentation.inputSchema;
      changed = true;
    }
  }
  const existingNames = new Set(
    tools.filter((tool) => tool && typeof tool.name === "string").map((tool) => tool.name),
  );
  const hasCodex = existingNames.has("codex");
  const hasCodexReply = existingNames.has("codex-reply");
  const availableJobTools = CODEX_JOB_TOOL_NAMES.filter((toolName) => {
    if (toolName === "codex-start") return hasCodex;
    if (toolName === "codex-reply-start") return hasCodexReply;
    return hasCodex || hasCodexReply;
  });
  for (const toolName of availableJobTools) {
    const presentation = codexToolPresentation(toolName);
    const existing = tools.find((tool) => tool?.name === toolName);
    if (existing) {
      if (existing.description !== presentation.description) {
        existing.description = presentation.description;
        changed = true;
      }
      if (JSON.stringify(existing.inputSchema) !== JSON.stringify(presentation.inputSchema)) {
        existing.inputSchema = presentation.inputSchema;
        changed = true;
      }
      continue;
    }
    tools.push({ name: toolName, ...presentation });
    changed = true;
  }
  return changed;
}

/**
 * Spawn codex mcp-server as a pass-through. codex stdout is forwarded back to
 * the client byte-for-byte, but the client's stdin is intercepted line-by-line
 * so the curated call contract can be validated and transformed before reaching
 * codex. Invalid calls are answered locally with JSON-RPC invalid-params errors.
 * Per-request idle and hard deadlines convert unbounded Codex stalls into
 * surfaced JSON-RPC errors. Correlated events also provide client-visible MCP
 * progress and enough terminal metadata to recover a missing final response.
 * @param {{ model?: string, modelReasoningEffort?: string, sandboxMode?: string, approvalPolicy?: string, idleTimeoutMs?: number, hardTimeoutMs?: number, goal?: string }} opts
 */
function runCodexPassthrough({
  model,
  modelReasoningEffort,
  sandboxMode,
  approvalPolicy,
  idleTimeoutMs,
  hardTimeoutMs,
  goal,
}) {
  const resolvedModel = model || DEFAULT_CODEX_MODEL;
  const resolvedModelReasoningEffort =
    modelReasoningEffort || DEFAULT_CODEX_MODEL_REASONING_EFFORT;
  const resolvedSandboxMode = sandboxMode || DEFAULT_CODEX_SANDBOX_MODE;
  const resolvedApprovalPolicy = approvalPolicy || DEFAULT_CODEX_APPROVAL_POLICY;
  const resolvedIdleTimeoutMs = idleTimeoutMs ?? DEFAULT_CODEX_IDLE_TIMEOUT_MS;
  const resolvedHardTimeoutMs = hardTimeoutMs ?? DEFAULT_CODEX_TIMEOUT_MS;
  const terminalGraceMs = testTunableMs(
    "MCP_AGENTS_CODEX_TERMINAL_GRACE_MS",
    DEFAULT_CODEX_TERMINAL_GRACE_MS,
  );
  const cancelGraceMs = testTunableMs(
    "MCP_AGENTS_CODEX_CANCEL_GRACE_MS",
    DEFAULT_CODEX_CANCEL_GRACE_MS,
  );
  const progressIntervalMs = testTunableMs(
    "MCP_AGENTS_CODEX_PROGRESS_INTERVAL_MS",
    DEFAULT_CODEX_PROGRESS_INTERVAL_MS,
  );
  const waitIntervalMs = testTunableMs(
    "MCP_AGENTS_CODEX_WAIT_INTERVAL_MS",
    DEFAULT_CODEX_WAIT_INTERVAL_MS,
  );
  const commentaryByteLimit = testTunableMs(
    "MCP_AGENTS_TEST_COMMENTARY_BYTES",
    MAX_CODEX_COMMENTARY_BYTES,
  );
  // Server-wide default goal (string or undefined); per-call `goal` overrides it.
  const resolvedGoal = goal;
  let isolatedCodexHome;

  try {
    isolatedCodexHome = createIsolatedCodexHome({
      model: resolvedModel,
      modelReasoningEffort: resolvedModelReasoningEffort,
      sandboxMode: resolvedSandboxMode,
      approvalPolicy: resolvedApprovalPolicy,
    });
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    logErr(`[mcp-agents] failed to prepare isolated codex home: ${msg}`);
    process.exitCode = 1;
    return;
  }

  const args = ["mcp-server"];
  let cleanedUp = false;
  const cleanupIsolatedCodexHome = () => {
    if (cleanedUp || !isolatedCodexHome) return;
    cleanedUp = true;

    // Write any rotated OAuth token back to the real CODEX_HOME before the temp
    // home (and its refreshed auth.json) is removed.
    persistIsolatedCodexAuth(isolatedCodexHome);
    try {
      rmSync(isolatedCodexHome, { recursive: true, force: true });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      logErr(`[mcp-agents] failed to clean isolated codex home: ${msg}`);
    }
  };

  logErr(
    `[mcp-agents] passthrough: codex ${args.join(" ")} ` +
      `(model=${resolvedModel}, reasoning_effort=${resolvedModelReasoningEffort}, ` +
      `sandbox_mode=${resolvedSandboxMode}, approval_policy=${resolvedApprovalPolicy}, ` +
      `goal=${resolvedGoal && resolvedGoal.trim() ? "set" : "none"}, ` +
      `idle_timeout_ms=${resolvedIdleTimeoutMs}, hard_timeout_ms=${resolvedHardTimeoutMs}, ` +
      `isolated_home=true)`,
  );

  const child = spawn("codex", args, {
    env: { ...process.env, CODEX_HOME: isolatedCodexHome },
    // stdin is piped so we can strip per-call overrides; stdout is piped (not
    // inherited) so the wrapper can both forward responses byte-for-byte AND
    // observe them for the idle watchdog. detached:true puts codex in its own
    // process group so a stall is torn down group-wide (mirrors runCli).
    detached: true,
    stdio: ["pipe", "pipe", "pipe"],
  });

  const NEWLINE = 0x0a;
  // Clean the isolated home on any exit path, not just the ones we route through
  // hardExit() (e.g. a global uncaughtException handler calling process.exit).
  process.once("exit", () => cleanupIsolatedCodexHome());

  // Install signal teardown IMMEDIATELY after spawn (before the heavier wiring
  // below) so a signal in the startup window can never orphan the detached
  // group. `finalize` is a forward reference — safe because the handler body
  // only runs when a signal fires, which is after this synchronous setup
  // completes and `finalize` is defined.
  for (const sig of ["SIGTERM", "SIGINT", "SIGHUP"]) {
    process.once(sig, () => {
      finalize({
        reason: `signal ${sig}`,
        emit: false,
        exitCode: 128 + SIGNAL_CODES[sig],
      });
    });
  }

  // ── Liveness / lifecycle state ──────────────────────────────────────────
  let finalizing = false;
  let exited = false;
  let stdoutPaused = false; // process.stdout backpressured (downstream, not idle)
  let lastForwardedByteWasNewline = true; // nothing forwarded yet
  let stdoutObsBuf = Buffer.alloc(0); // observation copy of codex stdout
  let skippingFrame = false; // mid-skip of an oversized stdout frame (resync at \n)
  let droppedFrameResponseId; // partial oversized frame's classified id (cleared at its newline)
  let observationDropLogged = false; // log the first observation-cap drop only

  // ── Curated-schema rewrite and private-job frame filter ──────────────────
  // While a `tools/list` request id or private job is outstanding the forwarder
  // switches from raw passthrough to bounded frame buffering. It rewrites the
  // advertised Codex inputs and suppresses private job responses/events, then
  // returns to raw when no latch remains.
  // Observation above stays the SOLE authority for inFlight/the watchdog; this
  // path only changes HOW bytes reach the wire.
  const pendingToolsListIds = new Set(); // idKey(id) of outstanding tools/list requests (the latch)
  const suppressedResponseIds = new Set(); // late native responses already synthesized upstream
  let rewriteBuf = Buffer.alloc(0); // buffer-mode accumulator; holds ≤1 trailing partial after a flush
  let rewriteSkipUntilNewline = false; // forwarding raw to the next newline (oversized frame or mode-boundary align)
  let rewriteSkipReleaseId; // idKey to release when the skipped frame's newline lands (oversized response only)
  let rewriteDropUntilNewline = false; // discarding an oversized suppressed response through its delimiter
  let rewriteDropReleaseId;
  let oversizedToolsListLogged = false; // log the first rewrite-cap drop only
  const generatedFrames = [];
  const locallyHandledResponseIds = new Set();
  const privateJobRequestIds = new Set();
  let flushGeneratedFrames = () => {};

  // ── In-flight request tracking ──────────────────────────────────────────
  // Every request owns its own lifecycle and progress timers.
  // JSON-RPC numeric `1` and string `"1"` remain distinct keys.
  const inFlight = new Map();
  const serverRequestParents = new Map();
  const jobs = new Map();
  const jobsByNativeRequest = new Map();
  const privateRequestPrefix = process.env.MCP_AGENTS_TEST_PRIVATE_PREFIX ??
    `mcp-agents/job/${randomUUID()}/`;
  let privateRequestSequence = 0;
  const idKey = (id) => `${typeof id}:${id}`;
  const rememberLocallyHandledResponse = (requestKey) => {
    locallyHandledResponseIds.add(requestKey);
    if (locallyHandledResponseIds.size > MAX_SUPPRESSED_CODEX_RESPONSES) {
      locallyHandledResponseIds.delete(locallyHandledResponseIds.values().next().value);
    }
  };
  const clearTimer = (entry, name) => {
    if (!entry?.[name]) return;
    clearTimeout(entry[name]);
    entry[name] = undefined;
  };
  const clearEntryTimers = (entry) => {
    for (const name of [
      "idleTimer",
      "hardTimer",
      "terminalTimer",
      "cancelTimer",
      "progressFlushTimer",
      "waitTimer",
      "localWaitTimer",
    ]) {
      clearTimer(entry, name);
    }
  };
  const dropQueuedFrames = (requestKey, kind) => {
    for (let index = generatedFrames.length - 1; index >= 0; index -= 1) {
      const frame = generatedFrames[index];
      if (frame.kind === kind && frame.requestKey === requestKey) {
        generatedFrames.splice(index, 1);
      }
    }
  };
  const dropQueuedProgress = (requestKey) =>
    dropQueuedFrames(requestKey, "progress");
  const dropQueuedLocalResponse = (requestKey) =>
    dropQueuedFrames(requestKey, "local_response");
  const stopEntryProgress = (entry) => {
    if (!entry) return;
    clearTimer(entry, "progressFlushTimer");
    clearTimer(entry, "waitTimer");
    entry.pendingProgressMessage = undefined;
    entry.commentaryItemIds?.clear();
    entry.commentaryBuffers?.clear();
    dropQueuedProgress(idKey(entry.id));
  };
  const clearAllEntryTimers = () => {
    for (const entry of inFlight.values()) clearEntryTimers(entry);
  };
  const stopAllEntryProgress = () => {
    for (const entry of inFlight.values()) stopEntryProgress(entry);
  };
  const settleInFlight = (id) => {
    if (id == null) return undefined;
    const key = idKey(id);
    const entry = inFlight.get(key);
    if (!entry) return undefined;
    clearEntryTimers(entry);
    stopEntryProgress(entry);
    if (process.env.MCP_AGENTS_TEST_TIMER_AUDIT === "1") {
      const liveTimerCount = Object.entries(entry).filter(
        ([name, timer]) => name.endsWith("Timer") && timer != null,
      ).length;
      logErr(`[mcp-agents:test] settled timer count=${liveTimerCount}`);
    }
    inFlight.delete(key);
    pendingToolsListIds.delete(key);
    for (const [serverRequestKey, parentKey] of serverRequestParents) {
      if (parentKey === key) serverRequestParents.delete(serverRequestKey);
    }
    return entry;
  };
  const armEntryIdle = (entry) => {
    clearTimer(entry, "idleTimer");
    if (
      !(resolvedIdleTimeoutMs > 0) || finalizing || stdoutPaused ||
      entry.state !== "open"
    ) return;
    entry.idleTimer = setTimeout(() => {
      if (finalizing || inFlight.get(idKey(entry.id)) !== entry) return;
      finalize({
        reason:
          `request ${JSON.stringify(entry.id)} idle timeout ` +
          `(${Math.round(resolvedIdleTimeoutMs / 1000)}s)`,
        emit: true,
        exitCode: 1,
      });
    }, resolvedIdleTimeoutMs);
  };
  const armEntryHard = (entry) => {
    if (!(resolvedHardTimeoutMs > 0)) return;
    entry.hardTimer = setTimeout(() => {
      if (finalizing || inFlight.get(idKey(entry.id)) !== entry) return;
      finalize({
        reason:
          `request ${JSON.stringify(entry.id)} hard timeout ` +
          `(${Math.round(resolvedHardTimeoutMs / 1000)}s)`,
        emit: true,
        exitCode: 1,
      });
    }, resolvedHardTimeoutMs);
  };
  const addInFlight = (msg) => {
    if (msg.id == null) return true;
    const key = idKey(msg.id);
    // Once an id is legitimately reused, a later cancellation belongs to the
    // new request rather than the earlier locally answered one.
    locallyHandledResponseIds.delete(key);
    if (inFlight.has(key) || suppressedResponseIds.has(key)) {
      const entry = inFlight.get(key) ?? {
        id: msg.id,
        method: msg.method,
        toolName: msg.method === "tools/call" ? msg.params?.name : undefined,
        threadId: undefined,
      };
      clearEntryTimers(entry);
      entry.state = "open";
      inFlight.set(key, entry);
      finalize({
        reason:
          `request id ${JSON.stringify(msg.id)} was reused before the prior ` +
          `Codex response settled`,
        emit: true,
        exitCode: 1,
      });
      return false;
    }
    const suppliedProgressToken = msg.params?._meta?.progressToken;
    const progressToken =
      typeof suppliedProgressToken === "string" ||
      (typeof suppliedProgressToken === "number" && Number.isFinite(suppliedProgressToken))
        ? suppliedProgressToken
        : undefined;
    const entry = {
      id: msg.id,
      method: msg.method,
      toolName: msg.method === "tools/call" ? msg.params?.name : undefined,
      progressToken,
      threadId: undefined,
      state: "open",
      lastAgentMessage: undefined,
      progressSequence: 0,
      startedAt: Date.now(),
      lastActivityAt: Date.now(),
      lastProgressQueuedAt: undefined,
      lastProgressDeliveredAt: undefined,
      lastWaitAttemptAt: undefined,
      lastProgressMessage: undefined,
      pendingProgressMessage: undefined,
      hasUsefulProgress: false,
      commentaryItemIds: new Set(),
      commentaryBuffers: new Map(),
      fallbackReady: false,
    };
    inFlight.set(key, entry);
    armEntryIdle(entry);
    armEntryHard(entry);
    armProgressWait(entry);
    return true;
  };
  const hasEmittableInFlight = () => {
    for (const entry of inFlight.values()) {
      if (!entry.internalJob && entry.state !== "canceled") return true;
    }
    return false;
  };
  const canArmResponseSuppression = () =>
    lastForwardedByteWasNewline && rewriteBuf.length === 0 &&
    !rewriteSkipUntilNewline && !rewriteDropUntilNewline;
  const canInjectGeneratedFrame = () =>
    !stdoutPaused && canArmResponseSuppression();
  const queueGeneratedFrame = (frame, { requestKey, kind } = {}) => {
    const queued = {
      buffer: Buffer.from(`${JSON.stringify(frame)}\n`, "utf8"),
      requestKey,
      kind,
    };
    if (kind === "progress") {
      // Backpressure or a partial native frame can delay injection. Retain only
      // the latest progress update for this request so silence cannot grow an
      // unbounded side queue.
      dropQueuedProgress(requestKey);
    }
    generatedFrames.push(queued);
    queueMicrotask(() => flushGeneratedFrames());
  };
  const generatedFrameIsLive = (frame) => {
    const entry = inFlight.get(frame.requestKey);
    if (frame.kind === "progress") {
      return !finalizing && entry != null && entry.state === "open";
    }
    if (frame.kind === "local_response") {
      return entry != null && entry.state === "local_response";
    }
    return true;
  };
  const normalizeProgressText = (value) => {
    if (typeof value !== "string") return "";
    return value
      .replace(/[\u0000-\u001f\u007f-\u009f]/gu, " ")
      .replace(/\s+/gu, " ")
      .trim();
  };
  const formatProgressMessage = (value) => {
    const normalized = normalizeProgressText(value);
    if (!normalized) return undefined;
    return Array.from(`Codex: ${normalized}`)
      .slice(0, MAX_CODEX_PROGRESS_CODEPOINTS)
      .join("");
  };
  const markGeneratedFrameDelivered = (frame) => {
    if (frame.kind === "local_response") {
      const entry = inFlight.get(frame.requestKey);
      if (entry?.state === "local_response") {
        if (entry.startJobId) {
          const job = jobs.get(entry.startJobId);
          if (job?.startRequestKey === frame.requestKey) job.startRequestKey = undefined;
        }
        rememberLocallyHandledResponse(frame.requestKey);
        settleInFlight(entry.id);
      }
      return;
    }
    if (frame.kind !== "progress") return;
    const entry = inFlight.get(frame.requestKey);
    if (!entry || entry.state !== "open") return;
    entry.lastProgressDeliveredAt = Date.now();
    entry.lastWaitAttemptAt = undefined;
    clearTimer(entry, "waitTimer");
    armProgressWait(entry);
  };
  const codePointLength = (value) => Array.from(value ?? "").length;
  const sanitizeCommentaryText = (value) => {
    if (typeof value !== "string") return "";
    return value
      .replace(/\r/gu, "")
      .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f]/gu, "")
      .replace(/[\u2028\u2029\u202a-\u202e\u2066-\u2069]/gu, "");
  };
  const localToolResult = (text, structuredContent, { isError = false } = {}) => ({
    content: [{ type: "text", text }],
    structuredContent,
    ...(isError ? { isError: true } : {}),
  });
  const prepareLocalEntry = (entry, state = "local_response") => {
    clearEntryTimers(entry);
    stopEntryProgress(entry);
    entry.state = state;
  };
  const detachLocalWaiter = (entry) => {
    if (!entry?.waitJobId) return;
    jobs.get(entry.waitJobId)?.waiters.delete(idKey(entry.id));
    entry.waitJobId = undefined;
    clearTimer(entry, "localWaitTimer");
  };
  const queueLocalToolResponse = (entry, result) => {
    detachLocalWaiter(entry);
    prepareLocalEntry(entry);
    queueGeneratedFrame(
      { jsonrpc: "2.0", id: entry.id, result },
      { requestKey: idKey(entry.id), kind: "local_response" },
    );
    flushGeneratedFrames();
  };
  const isTerminalJob = (job) => TERMINAL_CODEX_JOB_STATES.has(job?.state);
  const jobStatusStructuredContent = (job) => ({
    jobId: job.jobId,
    state: job.state,
    cursor: job.statusCursor,
    message: job.statusMessage,
    elapsedSeconds: Math.max(0, Math.floor((Date.now() - job.createdAt) / 1_000)),
    lastActivitySeconds: Math.max(
      0,
      Math.floor((Date.now() - job.lastActivityAt) / 1_000),
    ),
    ...(job.threadId ? { threadId: job.threadId } : {}),
    resultAvailable: job.state === "completed",
    resultTruncated: false,
    commentaryStartOffset: job.commentaryStartOffset,
    commentaryEndOffset: job.commentaryEndOffset,
    commentaryTruncated: job.commentaryStartOffset > 0,
  });
  const jobStatusResult = (job, { heartbeat = false } = {}) => {
    const structuredContent = jobStatusStructuredContent(job);
    const visibleMessage = heartbeat && !isTerminalJob(job)
      ? `Codex: still running; last activity ${structuredContent.lastActivitySeconds}s ago`
      : job.statusMessage;
    structuredContent.message = visibleMessage;
    let instruction;
    if (job.state === "completed") {
      instruction = `Call codex-result with jobId ${job.jobId} to read the final answer.`;
    } else if (job.state === "failed" || job.state === "canceled") {
      instruction = "The Codex job is terminal.";
    } else {
      instruction =
        `Call codex-status again with jobId ${job.jobId} and cursor ` +
        `${job.statusCursor}. If commentaryEndOffset advanced, call codex-commentary.`;
    }
    return localToolResult(
      `Codex job ${job.jobId} is ${job.state}: ${visibleMessage}\n\n${instruction}`,
      structuredContent,
    );
  };
  const queueJobStatusResponse = (entry, job, options) => {
    queueLocalToolResponse(entry, jobStatusResult(job, options));
  };
  const wakeJobWaiters = (job) => {
    for (const requestKey of [...job.waiters]) {
      const entry = inFlight.get(requestKey);
      if (!entry || entry.state !== "local_wait") {
        job.waiters.delete(requestKey);
        continue;
      }
      if (job.statusCursor > entry.waitCursor || isTerminalJob(job)) {
        queueJobStatusResponse(entry, job);
      }
    }
  };
  const setJobStatusNow = (job, message, { state } = {}) => {
    if (!job || isTerminalJob(job)) return;
    const formatted = formatProgressMessage(message) ?? job.statusMessage;
    const stateChanged = state && state !== job.state;
    if (!stateChanged && formatted === job.statusMessage) return;
    if (state) job.state = state;
    job.statusMessage = formatted;
    job.statusCursor += 1;
    job.lastStatusAt = Date.now();
    job.pendingStatusMessage = undefined;
    if (job.statusTimer) {
      clearTimeout(job.statusTimer);
      job.statusTimer = undefined;
    }
    wakeJobWaiters(job);
  };
  const flushPendingJobStatus = (job) => {
    job.statusTimer = undefined;
    const message = job.pendingStatusMessage;
    job.pendingStatusMessage = undefined;
    if (message) setJobStatusNow(job, message, { state: "running" });
  };
  const scheduleJobStatus = (job, message) => {
    if (!job || isTerminalJob(job)) return;
    const formatted = formatProgressMessage(message);
    if (
      !formatted || formatted === job.statusMessage ||
      formatted === formatProgressMessage(job.pendingStatusMessage)
    ) {
      return;
    }
    const elapsed = job.lastStatusAt == null
      ? Number.POSITIVE_INFINITY
      : Date.now() - job.lastStatusAt;
    if (elapsed >= progressIntervalMs) {
      setJobStatusNow(job, formatted.slice("Codex: ".length), { state: "running" });
      return;
    }
    job.pendingStatusMessage = formatted.slice("Codex: ".length);
    if (!job.statusTimer) {
      job.statusTimer = setTimeout(
        () => flushPendingJobStatus(job),
        Math.max(1, progressIntervalMs - elapsed),
      );
    }
  };
  const appendJobCommentary = (job, value) => {
    const text = sanitizeCommentaryText(value);
    if (!text) return "";
    job.commentary += text;
    job.commentaryEndOffset += codePointLength(text);
    let byteLength = Buffer.byteLength(job.commentary, "utf8");
    if (byteLength > commentaryByteLimit) {
      const codePoints = Array.from(job.commentary);
      let dropped = 0;
      while (byteLength > commentaryByteLimit && dropped < codePoints.length) {
        byteLength -= Buffer.byteLength(codePoints[dropped], "utf8");
        dropped += 1;
      }
      job.commentary = codePoints.slice(dropped).join("");
      job.commentaryStartOffset += dropped;
      if (!job.commentaryTruncationLogged) {
        logErr(
          `[mcp-agents] Codex job ${job.jobId} commentary exceeded ` +
            `${commentaryByteLimit} bytes; retaining tail`,
        );
        job.commentaryTruncationLogged = true;
      }
    }
    return text;
  };
  const appendJobCommentarySeparator = (job) => {
    if (job.commentary.endsWith("\n\n")) return;
    appendJobCommentary(job, job.commentary.endsWith("\n") ? "\n" : "\n\n");
  };
  const closeActiveCommentaryItem = (job) => {
    const itemId = job.activeCommentaryItemId;
    if (!itemId) return;
    const item = job.commentaryItems.get(itemId);
    if (item?.hasText) appendJobCommentarySeparator(job);
    if (item) item.closed = true;
    job.activeCommentaryItemId = undefined;
  };
  const captureJobCommentary = (job, event) => {
    if (!job || !event || typeof event !== "object" || job.commentaryComplete) return;
    if (event.type === "item_started") {
      const item = event.item;
      if (
        item?.type !== "AgentMessage" || item.phase !== "commentary" ||
        typeof item.id !== "string"
      ) return;
      job.streamedCommentarySeen = true;
      if (job.activeCommentaryItemId && job.activeCommentaryItemId !== item.id) {
        closeActiveCommentaryItem(job);
      }
      job.commentaryItems.set(item.id, {
        observed: "",
        observedOverflow: false,
        sawDelta: false,
        hasText: false,
        closed: false,
      });
      job.activeCommentaryItemId = item.id;
      return;
    }
    if (event.type === "agent_message_content_delta") {
      const item = job.commentaryItems.get(event.item_id);
      if (
        !item || item.closed || job.activeCommentaryItemId !== event.item_id ||
        typeof event.delta !== "string"
      ) return;
      const text = appendJobCommentary(job, event.delta);
      if (!text) return;
      item.sawDelta = true;
      item.hasText = true;
      if (!item.observedOverflow) {
        const combined = `${item.observed}${text}`;
        if (Buffer.byteLength(combined, "utf8") <= commentaryByteLimit) {
          item.observed = combined;
        } else {
          item.observed = "";
          item.observedOverflow = true;
        }
      }
      return;
    }
    if (event.type === "item_completed") {
      const completed = event.item;
      if (
        completed?.type !== "AgentMessage" || completed.phase !== "commentary" ||
        typeof completed.id !== "string"
      ) return;
      const item = job.commentaryItems.get(completed.id);
      if (!item || item.closed || job.activeCommentaryItemId !== completed.id) return;
      const completedText = sanitizeCommentaryText(
        Array.isArray(completed.content)
          ? completed.content
            .filter((part) => part?.type === "Text" && typeof part.text === "string")
            .map((part) => part.text)
            .join("")
          : completed.message,
      );
      if (!item.sawDelta) {
        if (appendJobCommentary(job, completedText)) item.hasText = true;
      } else if (!item.observedOverflow && completedText.startsWith(item.observed)) {
        if (appendJobCommentary(job, completedText.slice(item.observed.length))) {
          item.hasText = true;
        }
      }
      closeActiveCommentaryItem(job);
      return;
    }
    if (
      event.type === "agent_message" && event.phase === "commentary" &&
      typeof event.message === "string" && !job.streamedCommentarySeen
    ) {
      if (appendJobCommentary(job, event.message)) appendJobCommentarySeparator(job);
    }
  };
  const finishJobCommentary = (job) => {
    if (!job || job.commentaryComplete) return;
    closeActiveCommentaryItem(job);
    job.commentaryComplete = true;
  };
  const removeJob = (job) => {
    if (!job) return;
    if (job.statusTimer) clearTimeout(job.statusTimer);
    for (const requestKey of job.waiters) {
      const entry = inFlight.get(requestKey);
      if (entry) {
        clearTimer(entry, "localWaitTimer");
        settleInFlight(entry.id);
      }
    }
    jobs.delete(job.jobId);
    jobsByNativeRequest.delete(job.nativeRequestKey);
  };
  const pruneJobs = () => {
    const now = Date.now();
    for (const job of [...jobs.values()]) {
      if (isTerminalJob(job) && job.expiresAt <= now) removeJob(job);
    }
    if (jobs.size < MAX_RETAINED_CODEX_JOBS) return;
    const evictable = [...jobs.values()]
      .filter((job) =>
        isTerminalJob(job) &&
        (job.resultRead || (job.state !== "completed" && job.terminalRead))
      )
      .sort((a, b) => a.terminalAt - b.terminalAt);
    while (jobs.size >= MAX_RETAINED_CODEX_JOBS && evictable.length > 0) {
      removeJob(evictable.shift());
    }
  };
  const activeJobCount = () =>
    [...jobs.values()].filter((job) => !isTerminalJob(job)).length;
  const transitionJobTerminal = (job, state, message, { resultText, threadId } = {}) => {
    if (!job || isTerminalJob(job)) return;
    if (job.statusTimer) clearTimeout(job.statusTimer);
    job.statusTimer = undefined;
    job.pendingStatusMessage = undefined;
    finishJobCommentary(job);
    job.state = state;
    job.statusMessage = formatProgressMessage(message) ?? `Codex: ${state}`;
    job.statusCursor += 1;
    job.terminalAt = Date.now();
    job.expiresAt = job.terminalAt + CODEX_JOB_RETENTION_MS;
    if (typeof threadId === "string" && threadId) job.threadId = threadId;
    if (state === "completed") {
      job.resultText = typeof resultText === "string" ? resultText : "";
      job.resultEndOffset = codePointLength(job.resultText);
    }
    wakeJobWaiters(job);
  };
  const resultTextFromNative = (result) => {
    if (typeof result?.structuredContent?.content === "string") {
      return result.structuredContent.content;
    }
    if (!Array.isArray(result?.content)) return "";
    return result.content
      .filter((part) => part?.type === "text" && typeof part.text === "string")
      .map((part) => part.text)
      .join("\n");
  };
  const handlePrivateResponse = (entry, msg) => {
    const job = jobs.get(entry.jobId);
    if (!job || isTerminalJob(job)) return;
    const nativeThreadId = msg.result?.structuredContent?.threadId ?? entry.threadId ?? job.threadId;
    if (job.state === "canceling" || entry.state === "canceled") {
      transitionJobTerminal(job, "canceled", "canceled", { threadId: nativeThreadId });
      return;
    }
    if (msg.error) {
      const message = normalizeProgressText(msg.error.message) || "native Codex request failed";
      transitionJobTerminal(job, "failed", message, { threadId: nativeThreadId });
      return;
    }
    if (msg.result?.isError === true) {
      transitionJobTerminal(
        job,
        "failed",
        resultTextFromNative(msg.result) || "native Codex tool returned an error",
        { threadId: nativeThreadId },
      );
      return;
    }
    transitionJobTerminal(job, "completed", "completed", {
      resultText: resultTextFromNative(msg.result),
      threadId: nativeThreadId,
    });
  };
  const jobNotFoundResult = (jobId) => localToolResult(
    `Codex job ${jobId} was not found. Jobs are local to this MCP connection and expire.`,
    { code: "job_not_found", jobId },
    { isError: true },
  );
  const pageByCodePoint = (text, offset) => {
    const codePoints = Array.from(text ?? "");
    const page = codePoints.slice(offset, offset + MAX_CODEX_PAGE_CODEPOINTS);
    return {
      text: page.join(""),
      nextOffset: offset + page.length,
      endOffset: codePoints.length,
    };
  };
  const commentaryResult = (job, requestedOffset) => {
    if (requestedOffset > job.commentaryEndOffset) {
      return localToolResult(
        `Commentary offset ${requestedOffset} is beyond the available range ` +
          `${job.commentaryStartOffset}..${job.commentaryEndOffset}.`,
        {
          code: "commentary_offset_out_of_range",
          jobId: job.jobId,
          requestedOffset,
          startOffset: job.commentaryStartOffset,
          endOffset: job.commentaryEndOffset,
        },
        { isError: true },
      );
    }
    const startOffset = Math.max(requestedOffset, job.commentaryStartOffset);
    const relativeOffset = startOffset - job.commentaryStartOffset;
    const page = pageByCodePoint(job.commentary, relativeOffset);
    const nextOffset = startOffset + codePointLength(page.text);
    const structuredContent = {
      jobId: job.jobId,
      state: job.state,
      latestStatus: job.statusMessage,
      requestedOffset,
      startOffset,
      nextOffset,
      endOffset: job.commentaryEndOffset,
      caughtUp: nextOffset === job.commentaryEndOffset,
      commentaryComplete: job.commentaryComplete,
      truncatedBefore: requestedOffset < job.commentaryStartOffset,
      text: page.text,
    };
    const visible = page.text || "(No new Codex commentary.)";
    return localToolResult(visible, structuredContent);
  };
  const resultPageResult = (job, offset) => {
    if (!isTerminalJob(job)) {
      return localToolResult(
        `Codex job ${job.jobId} is still ${job.state}. Continue with codex-status.`,
        {
          jobId: job.jobId,
          state: job.state,
          resultAvailable: false,
          next: { tool: "codex-status", arguments: { jobId: job.jobId, cursor: job.statusCursor } },
        },
      );
    }
    if (job.state !== "completed") {
      job.terminalRead = true;
      return localToolResult(
        `Codex job ${job.jobId} ${job.state}: ${job.statusMessage}`,
        { jobId: job.jobId, state: job.state, resultAvailable: false },
        { isError: true },
      );
    }
    if (offset > job.resultEndOffset) {
      return localToolResult(
        `Result offset ${offset} is beyond the available range 0..${job.resultEndOffset}.`,
        { code: "result_offset_out_of_range", jobId: job.jobId, offset },
        { isError: true },
      );
    }
    const page = pageByCodePoint(job.resultText, offset);
    const done = page.nextOffset === page.endOffset;
    if (done) job.resultRead = true;
    return localToolResult(
      page.text || "(Codex returned an empty result.)",
      {
        jobId: job.jobId,
        state: job.state,
        ...(job.threadId ? { threadId: job.threadId } : {}),
        offset,
        nextOffset: page.nextOffset,
        endOffset: page.endOffset,
        done,
        resultTruncated: false,
        text: page.text,
      },
    );
  };
  const createJob = ({ nativeId, nativeToolName, startRequestKey }) => {
    const now = Date.now();
    return {
      jobId: randomUUID(),
      nativeId,
      nativeRequestKey: idKey(nativeId),
      nativeToolName,
      startRequestKey,
      state: "starting",
      statusCursor: 0,
      statusMessage: "Codex: starting",
      createdAt: now,
      lastActivityAt: now,
      lastStatusAt: undefined,
      pendingStatusMessage: undefined,
      statusTimer: undefined,
      threadId: undefined,
      waiters: new Set(),
      commentary: "",
      commentaryStartOffset: 0,
      commentaryEndOffset: 0,
      commentaryComplete: false,
      commentaryTruncationLogged: false,
      commentaryItems: new Map(),
      activeCommentaryItemId: undefined,
      streamedCommentarySeen: false,
      resultText: "",
      resultEndOffset: 0,
      resultRead: false,
      terminalRead: false,
      terminalAt: undefined,
      expiresAt: Number.POSITIVE_INFINITY,
    };
  };
  const startResult = (job) => localToolResult(
    `Codex job ${job.jobId} started. Call codex-status with cursor 0 until terminal.`,
    {
      jobId: job.jobId,
      state: job.state,
      cursor: job.statusCursor,
      message: job.statusMessage,
      commentaryStartOffset: 0,
      commentaryEndOffset: 0,
      next: { tool: "codex-status", arguments: { jobId: job.jobId, cursor: 0 } },
    },
  );
  const requestJobCancellation = (job, reason = "canceled by caller") => {
    if (!job || isTerminalJob(job) || job.state === "canceling") return;
    setJobStatusNow(job, "canceling", { state: "canceling" });
    const nativeEntry = inFlight.get(job.nativeRequestKey);
    if (!nativeEntry) {
      transitionJobTerminal(job, "canceled", "canceled");
      return;
    }
    cancelInFlight(job.nativeId);
    try {
      child.stdin.write(`${JSON.stringify({
        jsonrpc: "2.0",
        method: "notifications/cancelled",
        params: { requestId: job.nativeId, reason },
      })}\n`);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      transitionJobTerminal(job, "failed", `cancellation failed: ${message}`);
    }
  };
  const dispatchJob = (msg, clientEntry, nativeToolName) => {
    pruneJobs();
    if (
      activeJobCount() >= MAX_ACTIVE_CODEX_JOBS ||
      jobs.size >= MAX_RETAINED_CODEX_JOBS
    ) {
      queueLocalToolResponse(
        clientEntry,
        localToolResult(
          "Codex background-job capacity is full; collect retained results or wait for expiry.",
          {
            code: "capacity_exceeded",
            activeJobs: activeJobCount(),
            retainedJobs: jobs.size,
            maxActiveJobs: MAX_ACTIVE_CODEX_JOBS,
            maxRetainedJobs: MAX_RETAINED_CODEX_JOBS,
          },
          { isError: true },
        ),
      );
      return;
    }

    const nativeId = `${privateRequestPrefix}${++privateRequestSequence}`;
    const requestKey = idKey(msg.id);
    const job = createJob({ nativeId, nativeToolName, startRequestKey: requestKey });
    const nativeMsg = {
      jsonrpc: "2.0",
      id: nativeId,
      method: "tools/call",
      params: {
        name: nativeToolName,
        arguments: { ...msg.params.arguments },
      },
    };
    jobs.set(job.jobId, job);
    jobsByNativeRequest.set(job.nativeRequestKey, job);
    privateJobRequestIds.add(job.nativeRequestKey);
    if (!addInFlight(nativeMsg)) {
      privateJobRequestIds.delete(job.nativeRequestKey);
      removeJob(job);
      queueLocalToolResponse(
        clientEntry,
        localToolResult(
          "Could not reserve a private Codex request ID.",
          { code: "private_request_id_collision" },
          { isError: true },
        ),
      );
      return;
    }
    const nativeEntry = inFlight.get(job.nativeRequestKey);
    nativeEntry.internalJob = true;
    nativeEntry.jobId = job.jobId;
    prepareLocalEntry(clientEntry);
    clientEntry.startJobId = job.jobId;
    try {
      const transformed = transformCodexToolCall(
        JSON.stringify(nativeMsg),
        { serverGoal: resolvedGoal },
      );
      child.stdin.write(`${transformed}\n`);
    } catch (err) {
      privateJobRequestIds.delete(job.nativeRequestKey);
      settleInFlight(nativeId);
      jobsByNativeRequest.delete(job.nativeRequestKey);
      const message = err instanceof Error ? err.message : String(err);
      transitionJobTerminal(job, "failed", `dispatch failed: ${message}`);
    }
    queueLocalToolResponse(clientEntry, startResult(job));
  };
  const handleJobToolCall = (msg, entry) => {
    const toolName = msg.params?.name;
    const args = msg.params?.arguments ?? {};
    if (toolName === "codex-start" || toolName === "codex-reply-start") {
      dispatchJob(msg, entry, toolName === "codex-start" ? "codex" : "codex-reply");
      return true;
    }
    if (!CODEX_JOB_TOOL_CONTRACTS[toolName]) return false;
    pruneJobs();
    const job = jobs.get(args.jobId);
    if (!job) {
      queueLocalToolResponse(entry, jobNotFoundResult(args.jobId));
      return true;
    }
    if (toolName === "codex-status") {
      if (args.cursor > job.statusCursor) {
        queueLocalToolResponse(
          entry,
          localToolResult(
            `Status cursor ${args.cursor} is ahead of current cursor ${job.statusCursor}.`,
            { code: "status_cursor_ahead", jobId: job.jobId, cursor: job.statusCursor },
            { isError: true },
          ),
        );
        return true;
      }
      if (isTerminalJob(job)) {
        if (job.state !== "completed") job.terminalRead = true;
        queueJobStatusResponse(entry, job);
        return true;
      }
      const waitMs = args.wait_ms ?? DEFAULT_CODEX_WAIT_INTERVAL_MS;
      if (args.cursor < job.statusCursor || waitMs === 0) {
        queueJobStatusResponse(entry, job);
        return true;
      }
      prepareLocalEntry(entry, "local_wait");
      entry.waitJobId = job.jobId;
      entry.waitCursor = args.cursor;
      job.waiters.add(idKey(entry.id));
      entry.localWaitTimer = setTimeout(() => {
        if (inFlight.get(idKey(entry.id)) === entry && entry.state === "local_wait") {
          queueJobStatusResponse(entry, job, { heartbeat: true });
        }
      }, waitMs);
      if (job.statusCursor > args.cursor || isTerminalJob(job)) {
        queueJobStatusResponse(entry, job);
      }
      return true;
    }
    if (toolName === "codex-commentary") {
      queueLocalToolResponse(entry, commentaryResult(job, args.offset ?? 0));
      return true;
    }
    if (toolName === "codex-result") {
      queueLocalToolResponse(entry, resultPageResult(job, args.offset ?? 0));
      return true;
    }
    if (toolName === "codex-cancel") {
      requestJobCancellation(job);
      queueLocalToolResponse(entry, jobStatusResult(job));
      return true;
    }
    return false;
  };
  const emitProgressMessage = (entry, message) => {
    if (
      finalizing || entry.progressToken == null || entry.state !== "open" ||
      inFlight.get(idKey(entry.id)) !== entry
    ) return;
    const formatted = formatProgressMessage(message);
    if (!formatted || formatted === entry.lastProgressMessage) return;
    const now = Date.now();
    entry.lastProgressQueuedAt = now;
    entry.lastProgressMessage = formatted;
    entry.progressSequence += 1;
    queueGeneratedFrame(
      {
        jsonrpc: "2.0",
        method: "notifications/progress",
        params: {
          progressToken: entry.progressToken,
          progress: entry.progressSequence,
          message: formatted,
        },
      },
      { requestKey: idKey(entry.id), kind: "progress" },
    );
  };
  const flushPendingProgress = (entry) => {
    clearTimer(entry, "progressFlushTimer");
    if (finalizing || entry.state !== "open") return;
    const message = entry.pendingProgressMessage;
    entry.pendingProgressMessage = undefined;
    emitProgressMessage(entry, message);
  };
  const scheduleProgress = (entry, message, { useful = true } = {}) => {
    if (finalizing || entry.progressToken == null || entry.state !== "open") return;
    const formatted = formatProgressMessage(message);
    if (!formatted) return;
    if (
      formatted === entry.lastProgressMessage ||
      formatted === entry.pendingProgressMessage
    ) return;

    const firstUseful = useful && !entry.hasUsefulProgress;
    if (useful) entry.hasUsefulProgress = true;
    const elapsed = entry.lastProgressQueuedAt == null
      ? Number.POSITIVE_INFINITY
      : Date.now() - entry.lastProgressQueuedAt;
    if (firstUseful || elapsed >= progressIntervalMs) {
      clearTimer(entry, "progressFlushTimer");
      entry.pendingProgressMessage = undefined;
      emitProgressMessage(entry, formatted.slice("Codex: ".length));
      return;
    }

    entry.pendingProgressMessage = formatted.slice("Codex: ".length);
    if (entry.progressFlushTimer) return;
    entry.progressFlushTimer = setTimeout(
      () => flushPendingProgress(entry),
      Math.max(1, progressIntervalMs - elapsed),
    );
  };
  const armProgressWait = (entry) => {
    clearTimer(entry, "waitTimer");
    if (
      finalizing || entry.progressToken == null || entry.state !== "open" ||
      !(waitIntervalMs > 0)
    ) return;
    const visibleAt = Math.max(
      entry.lastProgressDeliveredAt ?? entry.startedAt,
      entry.lastWaitAttemptAt ?? entry.startedAt,
    );
    const delay = Math.max(1, waitIntervalMs - (Date.now() - visibleAt));
    entry.waitTimer = setTimeout(() => {
      entry.waitTimer = undefined;
      if (
        finalizing || entry.state !== "open" ||
        inFlight.get(idKey(entry.id)) !== entry
      ) return;
      // A generated frame can only be injected at a native frame boundary. Try
      // again on every silence tick; queueGeneratedFrame keeps only the latest
      // status if Codex is currently stalled mid-frame.
      flushGeneratedFrames();
      const lastActivityAt = entry.lastActivityAt ?? entry.startedAt;
      const seconds = Math.max(0, Math.floor((Date.now() - lastActivityAt) / 1_000));
      entry.lastWaitAttemptAt = Date.now();
      scheduleProgress(
        entry,
        `still running; last activity ${seconds}s ago`,
        { useful: false },
      );
      armProgressWait(entry);
    }, delay);
  };
  const progressMessageForEvent = (entry, event) => {
    if (!event || typeof event !== "object") return undefined;
    const type = event.type;

    if (type === "item_started") {
      const item = event.item;
      if (
        item?.type === "AgentMessage" && item.phase === "commentary" &&
        typeof item.id === "string"
      ) {
        entry.commentaryItemIds.add(item.id);
        entry.commentaryBuffers.set(item.id, "");
      }
      return undefined;
    }
    if (type === "agent_message_content_delta") {
      const itemId = event.item_id;
      if (
        typeof itemId !== "string" || !entry.commentaryItemIds.has(itemId) ||
        typeof event.delta !== "string"
      ) return undefined;
      const prior = entry.commentaryBuffers.get(itemId) ?? "";
      const combined = Array.from(`${prior}${event.delta}`).slice(-400).join("");
      entry.commentaryBuffers.set(itemId, combined);
      return combined;
    }
    if (type === "item_completed") {
      const item = event.item;
      if (
        item?.type !== "AgentMessage" || item.phase !== "commentary" ||
        typeof item.id !== "string"
      ) return undefined;
      entry.commentaryItemIds.delete(item.id);
      const buffered = entry.commentaryBuffers.get(item.id);
      entry.commentaryBuffers.delete(item.id);
      const completed = Array.isArray(item.content)
        ? item.content
          .filter((content) => content?.type === "Text" && typeof content.text === "string")
          .map((content) => content.text)
          .join("")
        : undefined;
      return completed || (typeof item.message === "string" ? item.message : buffered);
    }
    if (type === "agent_message") {
      return event.phase === "commentary" && typeof event.message === "string"
        ? event.message
        : undefined;
    }
    if (type === "plan_update" && Array.isArray(event.plan)) {
      const active = event.plan.find((step) =>
        step?.status === "in_progress" && typeof step.step === "string"
      );
      return active ? `working on: ${active.step}` : undefined;
    }

    switch (type) {
      case "task_started":
        return "started";
      case "exec_command_begin":
        return "running a command";
      case "exec_command_end":
        return Number.isInteger(event.exit_code)
          ? `command finished (exit ${event.exit_code})`
          : "command finished";
      case "patch_apply_begin": {
        const count = event.changes && typeof event.changes === "object"
          ? Object.keys(event.changes).length
          : undefined;
        return count == null ? "applying changes" : `applying changes to ${count} file(s)`;
      }
      case "patch_apply_end":
        return event.success === false ? "change application failed" : "changes applied";
      case "mcp_tool_call_begin":
      case "mcp_tool_call_end": {
        const invocation = event.invocation;
        const server = normalizeProgressText(invocation?.server);
        const tool = normalizeProgressText(invocation?.tool);
        const identifier = [server, tool].filter(Boolean).join("/");
        const action = type.endsWith("_begin") ? "calling" : "finished calling";
        return identifier ? `${action} ${identifier}` : `${action} an MCP tool`;
      }
      case "web_search_begin":
        return "searching the web";
      case "web_search_end":
        return "web search finished";
      case "view_image_tool_call":
        return "inspecting an image";
      case "image_generation_begin":
        return "generating an image";
      case "image_generation_end":
        return "image generation finished";
      case "collab_agent_spawn_begin":
        return "starting a subagent";
      case "collab_agent_spawn_end":
        return "subagent started";
      case "collab_agent_interaction_begin":
        return "coordinating with a subagent";
      case "collab_agent_interaction_end":
        return "subagent coordination finished";
      case "collab_waiting_begin":
        return "waiting for a subagent";
      case "collab_waiting_end":
        return "subagent wait finished";
      case "collab_resume_begin":
        return "resuming a subagent";
      case "collab_resume_end":
        return "resuming after subagent work";
      case "collab_close_begin":
        return "closing a subagent";
      case "collab_close_end":
        return "subagent closed";
      default:
        return undefined;
    }
  };
  const terminalResultFrame = (entry) => {
    const text = entry.lastAgentMessage ?? "";
    return {
      jsonrpc: "2.0",
      id: entry.id,
      result: {
        content: [{ type: "text", text }],
        structuredContent: { threadId: entry.threadId ?? "", content: text },
      },
    };
  };
  const synthesizeTerminalResult = (entry) => {
    if (
      finalizing || inFlight.get(idKey(entry.id)) !== entry ||
      entry.state !== "terminal_grace"
    ) return;
    if (entry.internalJob) {
      const key = idKey(entry.id);
      const job = jobs.get(entry.jobId);
      privateJobRequestIds.delete(key);
      suppressedResponseIds.add(key);
      if (job?.state === "canceling") {
        transitionJobTerminal(job, "canceled", "canceled", { threadId: entry.threadId });
      } else if (job) {
        transitionJobTerminal(job, "completed", "completed", {
          resultText: entry.lastAgentMessage ?? "",
          threadId: entry.threadId,
        });
      }
      settleInFlight(entry.id);
      if (suppressedResponseIds.size >= MAX_SUPPRESSED_CODEX_RESPONSES) {
        setImmediate(() => finalize({
          reason: "late-response suppression limit reached",
          emit: true,
          exitCode: 1,
        }));
      }
      return;
    }
    if (!canInjectGeneratedFrame()) {
      entry.fallbackReady = true;
      return;
    }
    entry.fallbackReady = false;
    const key = idKey(entry.id);
    suppressedResponseIds.add(key);
    settleInFlight(entry.id);
    queueGeneratedFrame(
      terminalResultFrame(entry),
      { kind: "terminal_result" },
    );
    logErr(
      `[mcp-agents] recovered missing codex response for request ` +
        `${JSON.stringify(entry.id)} (thread_id=${entry.threadId ?? "unknown"})`,
    );
    if (suppressedResponseIds.size >= MAX_SUPPRESSED_CODEX_RESPONSES) {
      setImmediate(() => finalize({
        reason: "late-response suppression limit reached",
        emit: true,
        exitCode: 1,
      }));
    }
  };
  const flushReadyTerminalResults = () => {
    if (!canInjectGeneratedFrame()) return;
    for (const entry of [...inFlight.values()]) {
      if (entry.fallbackReady) synthesizeTerminalResult(entry);
    }
  };
  const beginTerminalGrace = (entry, message) => {
    if (entry.state !== "open") return;
    if (entry.internalJob) finishJobCommentary(jobs.get(entry.jobId));
    entry.state = "terminal_grace";
    stopEntryProgress(entry);
    entry.lastAgentMessage = typeof message === "string" ? message : "";
    clearTimer(entry, "idleTimer");
    entry.terminalTimer = setTimeout(
      () => synthesizeTerminalResult(entry),
      terminalGraceMs,
    );
  };
  const cancelInFlight = (id) => {
    const entry = id == null ? undefined : inFlight.get(idKey(id));
    if (!entry || entry.state === "canceled") return false;
    if (entry.state === "local_response") {
      if (entry.startJobId) requestJobCancellation(jobs.get(entry.startJobId), "start canceled");
      rememberLocallyHandledResponse(idKey(id));
      dropQueuedLocalResponse(idKey(id));
      settleInFlight(id);
      return true;
    }
    if (entry.state === "local_wait") {
      detachLocalWaiter(entry);
      rememberLocallyHandledResponse(idKey(id));
      settleInFlight(id);
      return true;
    }
    entry.state = "canceled";
    stopEntryProgress(entry);
    clearTimer(entry, "idleTimer");
    clearTimer(entry, "hardTimer");
    clearTimer(entry, "terminalTimer");
    if (canArmResponseSuppression()) suppressedResponseIds.add(idKey(id));
    entry.cancelTimer = setTimeout(() => {
      if (finalizing || inFlight.get(idKey(entry.id)) !== entry) return;
      finalize({
        reason:
          `request ${JSON.stringify(entry.id)} cancellation did not settle ` +
          `within ${cancelGraceMs}ms`,
        emit: true,
        exitCode: 1,
      });
    }, cancelGraceMs);
    return false;
  };

  const killGroup = (signal) => {
    try {
      if (child.pid) process.kill(-child.pid, signal);
      else child.kill(signal);
    } catch {
      try { child.kill(signal); } catch {}
    }
  };

  // Parse one complete codex->client stdout frame (observation only — the raw
  // bytes are forwarded separately). Correlated events are the ONLY activity
  // that extends a request's idle window.
  const observeOutgoingLine = (line) => {
    const trimmed = line.trim();
    if (!trimmed) return;
    let msg;
    try { msg = JSON.parse(trimmed); } catch { return; }
    if (
      msg && typeof msg === "object" && "id" in msg &&
      ("result" in msg || "error" in msg)
    ) {
      const entry = inFlight.get(idKey(msg.id));
      if (entry?.internalJob) handlePrivateResponse(entry, msg);
      const privateJob = jobsByNativeRequest.get(idKey(msg.id));
      settleInFlight(msg.id);
      if (privateJob) jobsByNativeRequest.delete(idKey(msg.id));
      return;
    }
    if (msg?.id != null && typeof msg.method === "string") {
      const correlatedId = msg.params?._meta?.requestId;
      let entry = correlatedId == null
        ? undefined
        : inFlight.get(idKey(correlatedId));
      if (!entry) {
        const threadId = msg.params?._meta?.threadId ??
          msg.params?.threadId ?? msg.params?.thread_id;
        if (typeof threadId === "string") {
          entry = [...inFlight.values()].find((candidate) =>
            candidate.threadId === threadId && candidate.state === "open"
          );
        }
      }
      if (entry) {
        if (entry.internalJob) {
          try {
            child.stdin.write(`${JSON.stringify({
              jsonrpc: "2.0",
              id: msg.id,
              error: {
                code: -32601,
                message: "mcp-agents: interactive server requests are unavailable for background jobs",
              },
            })}\n`);
          } catch {}
          const job = jobs.get(entry.jobId);
          requestJobCancellation(job, "unsupported interactive request");
          transitionJobTerminal(
            job,
            "failed",
            "background job required unsupported interactive input",
          );
          return;
        }
        serverRequestParents.set(idKey(msg.id), idKey(entry.id));
        clearTimer(entry, "idleTimer");
      }
      return;
    }
    if (msg?.method !== "codex/event") return;
    const requestId = msg.params?._meta?.requestId;
    const entry = requestId == null ? undefined : inFlight.get(idKey(requestId));
    if (!entry || entry.state !== "open") return;
    const job = entry.internalJob ? jobs.get(entry.jobId) : undefined;
    const threadId = msg.params?._meta?.threadId;
    if (typeof threadId === "string" && threadId) entry.threadId = threadId;
    if (job && typeof threadId === "string" && threadId) job.threadId = threadId;
    const event = msg.params?.msg;
    const eventType = event?.type;
    entry.lastActivityAt = Date.now();
    if (job) {
      job.lastActivityAt = entry.lastActivityAt;
      captureJobCommentary(job, event);
    }
    armEntryIdle(entry);
    const progressMessage = progressMessageForEvent(entry, event);
    if (job) {
      if (job.state === "starting" && !progressMessage) {
        setJobStatusNow(job, "running", { state: "running" });
      } else if (progressMessage) {
        scheduleJobStatus(job, progressMessage);
      }
    }
    if (progressMessage) scheduleProgress(entry, progressMessage);
    if (eventType === "task_complete" || eventType === "turn_complete") {
      if (job) finishJobCommentary(job);
      beginTerminalGrace(entry, event?.last_agent_message);
    }
  };

  // Classify a (possibly oversized) frame from a bounded prefix: return the
  // request id iff it is clearly a RESPONSE — a top-level "result"/"error" with
  // the "id" appearing before it and no top-level "method" preceding it.
  // Assumes codex's (serde_json) serialization order: a response is
  // {jsonrpc,id,result|error} (id/result within the first handful of bytes), and
  // a notification/request emits its top-level "method" before "params". Under
  // that contract a nested "result"/"id" inside a non-response's params cannot be
  // misread as a response. Only ever consulted for frames too large to buffer.
  const FRAME_HEADER_SCAN = 8192;
  const peekResponseId = (prefix) => {
    const s = prefix
      .subarray(0, Math.min(prefix.length, FRAME_HEADER_SCAN))
      .toString("utf8");
    const resultAt = s.search(/"(?:result|error)"\s*:/);
    if (resultAt === -1) return undefined; // no result/error -> not a response
    const methodAt = s.search(/"method"\s*:/);
    if (methodAt !== -1 && methodAt < resultAt) return undefined; // request/notif
    // Capture the full id TOKEN (number or quoted string) and JSON-decode it so
    // the value matches what noteInbound stored via JSON.parse — otherwise an
    // escaped string id (e.g. "a\\b") would not equal the tracked key.
    const idMatch = s
      .slice(0, resultAt)
      .match(/"id"\s*:\s*(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|"(?:[^"\\]|\\.)*")/);
    if (!idMatch) return undefined;
    try { return JSON.parse(idMatch[1]); } catch { return undefined; }
  };
  const peekCorrelatedRequestId = (prefix) => {
    const s = prefix
      .subarray(0, Math.min(prefix.length, FRAME_HEADER_SCAN))
      .toString("utf8");
    const match = s.match(
      /"requestId"\s*:\s*(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|"(?:[^"\\]|\\.)*")/,
    );
    if (!match) return undefined;
    try { return JSON.parse(match[1]); } catch { return undefined; }
  };

  const logObservationDropOnce = () => {
    if (!observationDropLogged) {
      logErr(
        "[mcp-agents] codex passthrough: stdout frame exceeded observation cap; " +
          "classifying it via a bounded header scan (forwarding unaffected)",
      );
      observationDropLogged = true;
    }
  };

  // Resolve a dropped frame's effect on id-tracking. The frame's raw bytes were
  // already forwarded to the client. If a bounded header scan proves it is the
  // RESPONSE for an in-flight id, clear exactly that id — so we neither
  // double-respond with a synthetic error nor falsely idle-kill a healthy
  // session once codex goes quiet. If it is NOT a response (notification /
  // server->client request) or cannot be classified, leave the in-flight ids
  // tracked so a genuine post-frame stall is still caught. ONLY call this once
  // the frame is COMPLETE (its terminating newline has been seen): clearing on a
  // still-partial frame would prematurely untrack an id whose response codex may
  // never finish writing, re-introducing a hang.
  const resolveDroppedFrame = (prefix) => {
    const id = peekResponseId(prefix);
    if (id !== undefined) settleInFlight(id);
  };

  // Accumulate codex stdout into the observation buffer and parse each complete
  // frame to clear in-flight ids. Soft-bounded by MAX_BUFFER_BYTES so a
  // pathologically large single frame cannot exhaust memory — the bound is
  // approximate (a frame may transiently allocate up to one stream chunk beyond
  // the cap before being dropped). The RAW bytes are always forwarded untouched
  // by the caller regardless. A dropped frame is handled by onObservedFrameDropped().
  const observeOutgoing = (chunk) => {
    let data = chunk;
    if (skippingFrame) {
      const nl = data.indexOf(NEWLINE);
      if (nl === -1) return; // still inside the oversized frame
      // The oversized frame just COMPLETED. Apply the deferred clear now: if its
      // header looked like a response, the response genuinely finished, so clear
      // that id. (If codex had stalled mid-frame, this newline never arrives and
      // the id stays tracked so the watchdog still catches the stall.)
      skippingFrame = false;
      if (droppedFrameResponseId !== undefined) {
        settleInFlight(droppedFrameResponseId);
        droppedFrameResponseId = undefined;
      }
      data = data.subarray(nl + 1); // resume parsing after the frame boundary
    }
    stdoutObsBuf = stdoutObsBuf.length ? Buffer.concat([stdoutObsBuf, data]) : data;
    let nl;
    while ((nl = stdoutObsBuf.indexOf(NEWLINE)) !== -1) {
      if (nl > MAX_BUFFER_BYTES) {
        // A COMPLETE frame larger than the cap: it fully arrived, so classify it
        // from a bounded header prefix and clear its id now (no huge alloc).
        logObservationDropOnce();
        resolveDroppedFrame(stdoutObsBuf.subarray(0, nl));
        stdoutObsBuf = stdoutObsBuf.subarray(nl + 1);
        continue;
      }
      const line = stdoutObsBuf.subarray(0, nl).toString("utf8");
      stdoutObsBuf = stdoutObsBuf.subarray(nl + 1);
      observeOutgoingLine(line);
    }
    if (stdoutObsBuf.length > MAX_BUFFER_BYTES) {
      // A PARTIAL frame already past the cap with no newline yet: classify the
      // prefix but DEFER clearing to the frame's newline (above) — clearing now
      // would untrack an id whose response codex might never finish, hanging it.
      logObservationDropOnce();
      droppedFrameResponseId = peekResponseId(stdoutObsBuf);
      stdoutObsBuf = Buffer.alloc(0);
      skippingFrame = true;
    }
  };

  const hardExit = (code) => {
    if (exited) return;
    exited = true;
    clearAllEntryTimers();
    cleanupIsolatedCodexHome();
    process.exit(code);
  };
  const flushThenExit = (code) => {
    if (exited) return;
    if (process.stdout.writableLength === 0) {
      hardExit(code);
      return;
    }
    // Ref'd safety timer guarantees exit if 'drain' never fires (client gone).
    const safety = setTimeout(() => hardExit(code), 2_000);
    process.stdout.once("drain", () => {
      clearTimeout(safety);
      hardExit(code);
    });
  };

  // Single, idempotent teardown. `emit` controls whether open (non-canceled)
  // requests get a synthetic JSON-RPC error before exit. The detached group is
  // killed on EVERY teardown path so codex and any descendants are never
  // orphaned.
  const finalize = ({ reason, emit, exitCode }) => {
    if (finalizing) return;
    finalizing = true;
    clearAllEntryTimers();
    stopAllEntryProgress();
    logErr(`[mcp-agents] codex passthrough finalize: ${reason}`);

    // Stop forwarding further codex stdout so a late real response cannot race
    // the synthetic error onto the wire after we've taken over the stream.
    try { child.stdout?.pause(); } catch {}

    // Kill the whole detached group so codex AND any descendants it spawned are
    // reaped on EVERY teardown path — never orphaned. On abort paths (idle /
    // signal / EPIPE / fatal) codex is still alive, so there is no PID-reuse
    // risk; on a natural close/spawn-error this runs synchronously right after
    // the child was reaped (a negligible reuse window) to clean up anything
    // codex left behind in its group. A SIGKILL on an already-empty group is a
    // harmless ESRCH (swallowed by killGroup).
    killGroup("SIGKILL");

    if (emit && (hasEmittableInFlight() || generatedFrames.length > 0)) {
      // Framing recovery. Precedence handles bytes WITHHELD by buffer mode (which
      // the plain stdoutObsBuf recovery would mis-handle). EVERY write here is
      // try/catch-guarded: finalize runs synchronously from close/exit/idle/signal
      // handlers, so an unguarded EPIPE would escape into uncaughtException ->
      // fatalShutdown -> a re-entrant finalize early-return, skipping
      // flushThenExit/process.exit and hanging the wrapper.
      if (rewriteSkipUntilNewline) {
        // Oversized/align mid-skip: head already forwarded raw, remainder
        // unrecoverable. Discard; the -32001 loop covers the still-open id.
        rewriteBuf = Buffer.alloc(0);
        rewriteSkipUntilNewline = false;
        stdoutObsBuf = Buffer.alloc(0);
        if (!lastForwardedByteWasNewline) {
          try { process.stdout.write("\n"); } catch {}
          lastForwardedByteWasNewline = true;
        }
      } else if (rewriteDropUntilNewline) {
        rewriteBuf = Buffer.alloc(0);
        rewriteDropUntilNewline = false;
        stdoutObsBuf = Buffer.alloc(0);
      } else if (rewriteBuf.length > 0) {
        // A withheld buffered partial (never forwarded). If it parses as a COMPLETE
        // message (only its trailing newline missing) — possible only when the whole
        // frame arrived post-latch, so NONE of it is on the wire — deliver it
        // (rewritten if a pending tools/list response, else raw) + "\n" and clear its
        // id (no -32001). Otherwise (a mode-boundary tail — pre-empted by the
        // align-skip — or codex died mid-frame) discard; the -32001 loop covers it.
        const frameStr = rewriteBuf.toString("utf8");
        let outStr = null;
        try {
          const m = JSON.parse(frameStr);
          outStr = frameStr;
          const privateEntry = m && typeof m === "object" && "id" in m
            ? inFlight.get(idKey(m.id))
            : undefined;
          if (
            privateEntry?.internalJob && ("result" in m || "error" in m)
          ) {
            handlePrivateResponse(privateEntry, m);
            settleInFlight(m.id);
            jobsByNativeRequest.delete(idKey(m.id));
            privateJobRequestIds.delete(idKey(m.id));
            suppressedResponseIds.delete(idKey(m.id));
            outStr = null;
          } else if (
            m && typeof m === "object" && "id" in m &&
            ("result" in m || "error" in m) &&
            suppressedResponseIds.has(idKey(m.id))
          ) {
            suppressedResponseIds.delete(idKey(m.id));
            outStr = null;
          } else if (
            m && typeof m === "object" && "id" in m &&
            ("result" in m || "error" in m) &&
            pendingToolsListIds.has(idKey(m.id)) &&
            rewriteCodexToolsListMessage(m)
          ) {
            outStr = JSON.stringify(m);
          }
        } catch { outStr = null; }
        rewriteBuf = Buffer.alloc(0);
        stdoutObsBuf = Buffer.alloc(0);
        if (outStr !== null) {
          try { process.stdout.write(`${outStr}\n`); } catch {}
          observeOutgoingLine(frameStr); // clear its id -> no synthetic error for it
          lastForwardedByteWasNewline = true;
        } else if (!lastForwardedByteWasNewline) {
          try { process.stdout.write("\n"); } catch {}
          lastForwardedByteWasNewline = true;
        }
      } else if (stdoutObsBuf.length > 0) {
        observeOutgoingLine(stdoutObsBuf.toString("utf8"));
        stdoutObsBuf = Buffer.alloc(0);
        try { process.stdout.write("\n"); } catch {}
        lastForwardedByteWasNewline = true;
      } else if (!lastForwardedByteWasNewline) {
        try { process.stdout.write("\n"); } catch {}
        lastForwardedByteWasNewline = true;
      }

      while (generatedFrames.length > 0 && lastForwardedByteWasNewline) {
        const frame = generatedFrames.shift();
        if (!generatedFrameIsLive(frame)) continue;
        try {
          process.stdout.write(frame.buffer);
          markGeneratedFrameDelivered(frame);
        } catch {}
      }

      for (const entry of [...inFlight.values()]) {
        if (entry.state !== "terminal_grace") continue;
        try {
          process.stdout.write(`${JSON.stringify(terminalResultFrame(entry))}\n`);
        } catch {}
        settleInFlight(entry.id);
        logErr(
          `[mcp-agents] recovered completed codex request ` +
            `${JSON.stringify(entry.id)} during teardown ` +
            `(thread_id=${entry.threadId ?? "unknown"})`,
        );
      }

      for (const job of jobs.values()) {
        if (!isTerminalJob(job)) {
          transitionJobTerminal(job, "failed", `bridge stopped: ${reason}`);
        }
      }

      for (const entry of inFlight.values()) {
        if (
          entry.internalJob || entry.state === "canceled" ||
          entry.state === "local_response"
        ) continue;
        const frame = {
          jsonrpc: "2.0",
          id: entry.id,
          error: {
            code: -32001,
            message:
              `mcp-agents: codex pass-through aborted before responding ` +
              `(${reason}); the request was still open. Any applied edits may ` +
              `exist — verify the tree.` +
              (entry.threadId ? ` Codex thread: ${entry.threadId}.` : ""),
          },
        };
        try { process.stdout.write(`${JSON.stringify(frame)}\n`); } catch {}
      }
    }

    // Hygiene: drop the rewrite latch/skip state (forwarding has stopped).
    pendingToolsListIds.clear();
    suppressedResponseIds.clear();
    privateJobRequestIds.clear();
    locallyHandledResponseIds.clear();
    serverRequestParents.clear();
    rewriteSkipUntilNewline = false;
    rewriteSkipReleaseId = undefined;
    rewriteDropUntilNewline = false;
    rewriteDropReleaseId = undefined;
    rewriteBuf = Buffer.alloc(0);
    generatedFrames.length = 0;

    flushThenExit(exitCode);
  };

  // Route the global uncaughtException/unhandledRejection handlers through the
  // same teardown so codex's DETACHED group is always killed — otherwise those
  // handlers call process.exit() directly and orphan codex (the 'exit' handler
  // only deletes CODEX_HOME, it cannot reap a detached group).
  fatalShutdown = (reason, code) =>
    finalize({ reason: `fatal: ${reason}`, emit: true, exitCode: code ?? 1 });

  child.stderr.on("data", (chunk) => {
    logErr(`[codex] ${chunk.toString().trimEnd()}`);
  });

  const logRewriteDropOnce = () => {
    if (!oversizedToolsListLogged) {
      logErr(
        "[mcp-agents] codex passthrough: tools/list-window frame exceeded rewrite cap; " +
          "forwarding raw (curated wrapper schema not advertised on this response)",
      );
      oversizedToolsListLogged = true;
    }
  };

  // Raw forward of one buffer plus the existing first-`!ok` backpressure handling
  // (pause codex + suspend the watchdog until drain). Returns the write result.
  // Used by BOTH the raw fast path and buffer mode, so the wire-state tracking and
  // backpressure contract live in exactly one place.
  const forwardChunk = (buf) => {
    if (buf.length === 0) return true;
    lastForwardedByteWasNewline = buf[buf.length - 1] === NEWLINE;
    const ok = process.stdout.write(buf);
    if (!ok && !stdoutPaused) {
      // Downstream full: pause codex and suspend per-request idle timers until
      // the client drains. Immutable hard deadlines continue running.
      stdoutPaused = true;
      for (const entry of inFlight.values()) clearTimer(entry, "idleTimer");
      child.stdout.pause();
    }
    return ok;
  };
  flushGeneratedFrames = () => {
    if (finalizing || stdoutPaused || !canInjectGeneratedFrame()) return;
    while (generatedFrames.length > 0 && !stdoutPaused) {
      const frame = generatedFrames.shift();
      if (!generatedFrameIsLive(frame)) continue;
      forwardChunk(frame.buffer);
      markGeneratedFrameDelivered(frame);
    }
  };

  // Once no tools/list id is outstanding (and not mid-skip), a trailing partial in
  // rewriteBuf is a NON-tools/list frame (no response expected), so it must not stay
  // withheld in buffer mode — raw mode forwards partials as they arrive, and
  // withholding it would byte-lose it if codex dies before its newline. Forward it
  // raw and drop back to the fast path. Called from BOTH paths that can clear the
  // latch: the end of flushRewriteBuf (a response completed) and noteInbound's
  // cancel branch (a tools/list was canceled on stdin, which never runs the flush).
  const returnToRawIfLatchClear = () => {
    if (
      !finalizing && pendingToolsListIds.size === 0 &&
      suppressedResponseIds.size === 0 && privateJobRequestIds.size === 0 &&
      !rewriteSkipUntilNewline &&
      !rewriteDropUntilNewline && rewriteBuf.length > 0
    ) {
      forwardChunk(rewriteBuf);
      rewriteBuf = Buffer.alloc(0);
    }
  };

  // Flush every COMPLETE frame from rewriteBuf, rewriting only the matched
  // tools/list response and forwarding everything else byte-for-byte. NEVER
  // early-returns on backpressure: forwardChunk pauses codex on the first `!ok`,
  // but this chunk's frames are all queued (Node buffers regardless), so no
  // COMPLETE frame is ever stranded — exactly today's "one write(chunk), then
  // pause the source" semantics. After this returns rewriteBuf holds at most one
  // trailing INCOMPLETE partial.
  const flushRewriteBuf = () => {
    if (rewriteDropUntilNewline) {
      const nl = rewriteBuf.indexOf(NEWLINE);
      if (nl === -1) {
        rewriteBuf = Buffer.alloc(0);
        return;
      }
      rewriteBuf = rewriteBuf.subarray(nl + 1);
      if (rewriteDropReleaseId !== undefined) {
        suppressedResponseIds.delete(rewriteDropReleaseId);
        rewriteDropReleaseId = undefined;
      }
      rewriteDropUntilNewline = false;
    }
    if (rewriteSkipUntilNewline) {
      const nl = rewriteBuf.indexOf(NEWLINE);
      if (nl === -1) {
        // Still inside the skipped/aligned frame: forward it all raw, stay skipping.
        forwardChunk(rewriteBuf);
        rewriteBuf = Buffer.alloc(0);
        return;
      }
      forwardChunk(rewriteBuf.subarray(0, nl + 1)); // forward through the newline raw
      rewriteBuf = rewriteBuf.subarray(nl + 1);
      if (rewriteSkipReleaseId !== undefined) {
        pendingToolsListIds.delete(rewriteSkipReleaseId);
        rewriteSkipReleaseId = undefined;
      }
      rewriteSkipUntilNewline = false;
    }
    let nl;
    while ((nl = rewriteBuf.indexOf(NEWLINE)) !== -1) {
      const frameBytes = rewriteBuf.subarray(0, nl + 1); // original bytes incl. delimiter
      rewriteBuf = rewriteBuf.subarray(nl + 1); // consume-first: never re-forward, never wedge
      if (nl > MAX_BUFFER_BYTES) {
        // Complete frame larger than the cap: classify it from a bounded prefix.
        // Private job frames are suppressed; unrelated public frames stay raw.
        logRewriteDropOnce();
        const pid = peekResponseId(frameBytes);
        const key = pid === undefined ? undefined : idKey(pid);
        const privateJob = key === undefined ? undefined : jobsByNativeRequest.get(key);
        if (privateJob) {
          privateJobRequestIds.delete(key);
          suppressedResponseIds.delete(key);
          jobsByNativeRequest.delete(key);
          transitionJobTerminal(
            privateJob,
            "failed",
            "native result exceeded the 10 MiB background-job capture limit",
          );
          continue;
        }
        const correlatedId = peekCorrelatedRequestId(frameBytes);
        if (
          correlatedId !== undefined &&
          jobsByNativeRequest.has(idKey(correlatedId))
        ) {
          continue;
        }
        if (key !== undefined && suppressedResponseIds.has(key)) {
          suppressedResponseIds.delete(key);
          continue;
        }
        if (key !== undefined && pendingToolsListIds.has(key)) {
          pendingToolsListIds.delete(key);
        }
        forwardChunk(frameBytes);
        continue;
      }
      let outBuf = frameBytes; // default: byte-for-byte
      try {
        const msg = JSON.parse(
          frameBytes.subarray(0, frameBytes.length - 1).toString("utf8"),
        );
        const correlatedId = msg?.params?._meta?.requestId;
        const privateCorrelatedJob = correlatedId == null
          ? undefined
          : jobsByNativeRequest.get(idKey(correlatedId));
        if (privateCorrelatedJob && typeof msg.method === "string") {
          outBuf = null;
        } else if (
          msg && typeof msg === "object" && "id" in msg &&
          ("result" in msg || "error" in msg)
        ) {
          const key = idKey(msg.id);
          if (jobsByNativeRequest.has(key)) {
            privateJobRequestIds.delete(key);
            suppressedResponseIds.delete(key);
            outBuf = null;
          } else if (suppressedResponseIds.has(key)) {
            suppressedResponseIds.delete(key);
            outBuf = null;
          } else if (pendingToolsListIds.has(key)) {
            pendingToolsListIds.delete(key);
            if (rewriteCodexToolsListMessage(msg)) {
              outBuf = Buffer.from(`${JSON.stringify(msg)}\n`, "utf8");
            }
          }
        }
      } catch {
        outBuf = frameBytes; // unparseable (mode-boundary tail / partial) — forward original bytes
      }
      if (outBuf) forwardChunk(outBuf);
    }
    if (rewriteBuf.length > MAX_BUFFER_BYTES) {
      // Partial frame already past the cap with no newline: abandon rewriting for
      // THIS frame, forward what we have raw, and skip to its newline. Release only
      // a matching id, deferred to that newline.
      logRewriteDropOnce();
      const pid = peekResponseId(rewriteBuf);
      const key = pid === undefined ? undefined : idKey(pid);
      const privateJob = key === undefined ? undefined : jobsByNativeRequest.get(key);
      const correlatedId = peekCorrelatedRequestId(rewriteBuf);
      const privateCorrelated = correlatedId === undefined
        ? undefined
        : jobsByNativeRequest.get(idKey(correlatedId));
      if (privateJob || privateCorrelated) {
        if (privateJob) {
          transitionJobTerminal(
            privateJob,
            "failed",
            "native result exceeded the 10 MiB background-job capture limit",
          );
          privateJobRequestIds.delete(key);
          suppressedResponseIds.delete(key);
          jobsByNativeRequest.delete(key);
          rewriteDropReleaseId = key;
        } else {
          rewriteDropReleaseId = undefined;
        }
        rewriteBuf = Buffer.alloc(0);
        rewriteDropUntilNewline = true;
      } else if (key !== undefined && suppressedResponseIds.has(key)) {
        rewriteDropReleaseId = key;
        rewriteBuf = Buffer.alloc(0);
        rewriteDropUntilNewline = true;
      } else {
        rewriteSkipReleaseId =
          key !== undefined && pendingToolsListIds.has(key) ? key : undefined;
        forwardChunk(rewriteBuf);
        rewriteBuf = Buffer.alloc(0);
        rewriteSkipUntilNewline = true;
      }
    }
    // Latch boundary: a response just completed may have emptied the latch — if so,
    // flush any trailing NON-tools/list partial raw and return to the fast path.
    returnToRawIfLatchClear();
  };
  const bufferModeForward = (chunk) => {
    rewriteBuf = rewriteBuf.length ? Buffer.concat([rewriteBuf, chunk]) : chunk;
    flushRewriteBuf();
  };

  // Forward codex stdout to the client. Steady state is a byte-for-byte raw
  // passthrough (forwardChunk). A tools/list response or private background job
  // activates bounded frame mode for schema rewriting or private-frame filtering.
  // Observation runs on the ORIGINAL bytes and stays the sole authority for
  // clearing in-flight ids — by the time it runs, every complete frame in this
  // chunk was already forwarded/queued, so it never leads forwarding.
  child.stdout.on("data", (chunk) => {
    if (finalizing) return; // stream ownership has been taken over

    if (
      pendingToolsListIds.size > 0 || suppressedResponseIds.size > 0 ||
      privateJobRequestIds.size > 0 || rewriteBuf.length > 0 ||
      rewriteSkipUntilNewline || rewriteDropUntilNewline
    ) {
      bufferModeForward(chunk);
    } else {
      forwardChunk(chunk);
    }

    try {
      observeOutgoing(chunk); // bounded parse-for-ids; never alters forwarded bytes
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      logErr(`[mcp-agents] codex passthrough: stdout observation error (ignored): ${msg}`);
    }
    flushReadyTerminalResults();
    flushGeneratedFrames();
  });

  process.stdout.on("drain", () => {
    if (!stdoutPaused) return;
    stdoutPaused = false;
    if (finalizing) return;
    child.stdout.resume();
    for (const entry of inFlight.values()) armEntryIdle(entry);
    flushReadyTerminalResults();
    flushGeneratedFrames();
  });

  process.stdout.on("error", (err) => {
    // Client went away mid-write: nothing left to answer, tear codex down.
    if (err && err.code === "EPIPE") {
      finalize({ reason: "stdout EPIPE", emit: false, exitCode: 0 });
    }
  });

  // Pump client stdin -> codex stdin, splitting on the newline BYTE (0x0a) that
  // delimits MCP stdio JSON-RPC frames. Buffering raw bytes (not per-chunk
  // strings) avoids corrupting a multibyte UTF-8 sequence that straddles two
  // read chunks, which would otherwise break the byte-for-byte passthrough.
  child.stdin.on("error", () => {}); // ignore EPIPE if codex exits early

  // Track client requests, enforce the strict Codex argument contract, and honor
  // cancellations. Accepted tools/call frames are transformed only after this
  // validation succeeds.
  const noteInbound = (line) => {
    const trimmed = line.trim();
    if (!trimmed) return true;
    let msg;
    try { msg = JSON.parse(trimmed); } catch { return true; }
    if (!msg || typeof msg !== "object") return true;
    if (
      msg.id != null && typeof msg.method === "string" &&
      typeof msg.id === "string" && msg.id.startsWith(privateRequestPrefix)
    ) {
      if (!addInFlight(msg)) return false;
      const requestKey = idKey(msg.id);
      const entry = inFlight.get(requestKey);
      prepareLocalEntry(entry);
      queueGeneratedFrame(
        {
          jsonrpc: "2.0",
          id: msg.id,
          error: {
            code: -32600,
            message: "mcp-agents: request id uses the reserved private-job namespace",
          },
        },
        { requestKey, kind: "local_response" },
      );
      flushGeneratedFrames();
      return false;
    }
    if (msg.method === "notifications/cancelled") {
      const rid = msg.params?.requestId;
      if (rid != null && locallyHandledResponseIds.has(idKey(rid))) return false;
      const canceledLocalResponse = cancelInFlight(rid);
      // A canceled/never-answered tools/list must not wedge buffer mode open. If
      // this cancel cleared the last pending tools/list id while a NON-tools/list
      // partial is withheld in rewriteBuf, flush it raw — otherwise a codex exit
      // with only-canceled work would drop those bytes (finalize skips recovery).
      if (rid != null) {
        pendingToolsListIds.delete(idKey(rid));
        returnToRawIfLatchClear();
      }
      return !canceledLocalResponse;
    }
    if (msg.id != null && typeof msg.method !== "string") {
      const parentKey = serverRequestParents.get(idKey(msg.id));
      serverRequestParents.delete(idKey(msg.id));
      const entry = parentKey == null ? undefined : inFlight.get(parentKey);
      if (entry?.state === "open") armEntryIdle(entry);
      return true;
    }
    const validation = validateCodexToolCallMessage(msg);
    if (validation && msg.id == null) {
      const fields = validation.issues.map((issue) => issue.argument).join(", ");
      logErr(
        `[mcp-agents] dropped invalid ${validation.toolName} notification; fields: ${fields}`,
      );
      return false;
    }

    // A client message awaits a response iff it carries BOTH an id and a method.
    // A bare id with no method is a *response* to a codex elicitation — skip it
    // for in-flight tracking.
    if (msg.id != null && typeof msg.method === "string") {
      if (!addInFlight(msg)) return false;
      if (validation) {
        const requestKey = idKey(msg.id);
        const entry = inFlight.get(requestKey);
        entry.state = "local_response";
        stopEntryProgress(entry);
        queueGeneratedFrame(
          codexInvalidParamsFrame(msg.id, validation),
          { requestKey, kind: "local_response" },
        );
        const fields = validation.issues.map((issue) => issue.argument).join(", ");
        logErr(
          `[mcp-agents] rejected invalid ${validation.toolName} call; fields: ${fields}`,
        );
        flushGeneratedFrames();
        return false;
      }
      if (msg.method === "tools/call" && handleJobToolCall(msg, inFlight.get(idKey(msg.id)))) {
        return false;
      }
      if (msg.method === "tools/list") {
        // Arm the curated-schema rewrite latch for this tools/list response. If
        // buffer mode would START mid-frame (a pre-latch frame's head was already
        // raw-forwarded and its newline hasn't arrived), first align by raw-skipping
        // the orphan tail to its next newline — so the tail is forwarded
        // byte-for-byte and never mis-parsed as a standalone frame nor byte-lost at
        // finalize. Equivalent to today's raw behaviour for that straddled frame.
        if (
          pendingToolsListIds.size === 0 && suppressedResponseIds.size === 0 &&
          rewriteBuf.length === 0 && !rewriteSkipUntilNewline &&
          !rewriteDropUntilNewline && !lastForwardedByteWasNewline
        ) {
          rewriteSkipUntilNewline = true;
          rewriteSkipReleaseId = undefined;
        }
        pendingToolsListIds.add(idKey(msg.id));
      }
    }
    return true;
  };

  let stdinBuf = Buffer.alloc(0);
  process.stdin.on("data", (chunk) => {
    stdinBuf = stdinBuf.length ? Buffer.concat([stdinBuf, chunk]) : chunk;
    let nl;
    while ((nl = stdinBuf.indexOf(NEWLINE)) !== -1) {
      const line = stdinBuf.subarray(0, nl).toString("utf8");
      stdinBuf = stdinBuf.subarray(nl + 1);
      if (noteInbound(line) && !finalizing) {
        child.stdin.write(`${transformCodexToolCall(line, { serverGoal: resolvedGoal })}\n`);
      }
    }
  });
  process.stdin.on("error", () => {});
  process.stdin.on("end", () => {
    if (stdinBuf.length > 0) {
      const line = stdinBuf.toString("utf8");
      if (noteInbound(line) && !finalizing) {
        child.stdin.write(transformCodexToolCall(line, { serverGoal: resolvedGoal }));
      }
    }
    child.stdin.end();
  });

  child.on("error", (err) => {
    logErr(`[mcp-agents] failed to start codex: ${err.message}`);
    // codex failed to start. The fix that matters is that we EXIT (instead of
    // leaving a childless wrapper alive on the client's open stdin, which used
    // to hang). `emit` synthesizes an error only if a request was already
    // tracked; spawn 'error' usually fires before any stdin is read, so the
    // client typically just sees the server exit — the conventional
    // "server failed to start".
    finalize({
      reason: `codex spawn error: ${err.message}`,
      emit: true,
      exitCode: 1,
    });
  });

  // codex death is handled via BOTH 'exit' and 'close':
  //  - 'exit' fires when the codex PROCESS terminates. A descendant that
  //    inherited codex's stdio can hold those pipes open, delaying or even
  //    preventing 'close' (and would be orphaned), so we kill the group here to
  //    reap it — which also lets 'close' fire. A ref'd fallback guarantees
  //    teardown even if a descendant escaped the group (setsid) so 'close'
  //    never arrives.
  //  - 'close' fires once all stdio is drained, so codex's final response has
  //    been delivered and its id cleared — only THEN do we decide whether to
  //    synthesize, which avoids double-responding.
  let childExitInfo = null;
  const onChildGone = () => {
    const code = childExitInfo?.code;
    const signal = childExitInfo?.signal;
    if (signal) logErr(`[mcp-agents] codex killed by ${signal}`);
    else if (code != null && code !== 0) {
      logErr(`[mcp-agents] codex exited with code ${code}`);
    }
    finalize({
      reason: signal ? `codex killed by ${signal}` : `codex exited (code ${code})`,
      emit: true,
      exitCode: signal ? 128 + (SIGNAL_CODES[signal] ?? 0) : (code ?? 1),
    });
  };

  child.on("exit", (code, signal) => {
    childExitInfo = { code, signal };
    killGroup("SIGKILL");
    setTimeout(onChildGone, 2_000);
  });
  child.on("close", (code, signal) => {
    if (!childExitInfo) childExitInfo = { code, signal };
    onChildGone();
  });
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  const {
    provider: providerName,
    model,
    modelReasoningEffort,
    sandboxMode,
    approvalPolicy,
    goal,
    codexIdleTimeoutMs,
    defaultTimeoutMs,
  } = parseArgs();
  const backend = CLI_BACKENDS[providerName];

  if (!backend) {
    logErr(`[mcp-agents] Unknown provider: ${providerName}`);
    logErr(`[mcp-agents] Available: ${Object.keys(CLI_BACKENDS).join(", ")}`);
    process.exitCode = 1;
    return;
  }

  if (backend.passthrough) {
    runCodexPassthrough({
      model,
      modelReasoningEffort,
      sandboxMode,
      approvalPolicy,
      goal,
      idleTimeoutMs: codexIdleTimeoutMs,
      hardTimeoutMs: defaultTimeoutMs,
    });
    return;
  }

  const server = new Server(
    { name: "mcp-agents", version: VERSION },
    { capabilities: { tools: {} } },
  );
  let keepAlive;
  let shutdownStarted = false;
  let shutdownExitCode = 0;
  let shutdownPromise;
  let shutdownTimer;
  let activeRequests = 0;
  const activeChildren = new Map();

  const maybeFinalizeShutdown = () => {
    if (!shutdownStarted || activeRequests > 0 || shutdownPromise) return;

    shutdownPromise = Promise.resolve()
      .then(async () => {
        if (keepAlive) clearInterval(keepAlive);
        await server.close();
      })
      .catch((err) => {
        const msg = err instanceof Error ? err.message : String(err);
        logErr(`[mcp-agents] shutdown close failed: ${msg}`);
      })
      .finally(() => {
        if (shutdownTimer) clearTimeout(shutdownTimer);
        process.exit(shutdownExitCode);
      });
  };

  const beginShutdown = (reason, exitCode = 0) => {
    if (shutdownStarted) return;

    shutdownStarted = true;
    shutdownExitCode = exitCode;
    logErr(
      `[mcp-agents] shutting down (provider=${providerName}, reason=${reason})`,
    );

    shutdownTimer = setTimeout(() => {
      process.exit(shutdownExitCode);
    }, SHUTDOWN_TIMEOUT_MS);
    shutdownTimer.unref();

    for (const killGroup of activeChildren.values()) {
      killGroup();
    }

    maybeFinalizeShutdown();
  };
  fatalShutdown = beginShutdown;

  const effectiveTimeout =
    defaultTimeoutMs ?? backend.defaultTimeoutMs ?? DEFAULT_TIMEOUT_MS;

  const properties = {
    prompt: {
      type: "string",
      description: `Prompt for ${backend.command}. Unsupported extra arguments are ignored.`,
    },
    timeout_ms: {
      type: "integer",
      minimum: 1,
      description: `Optional timeout override (default ${effectiveTimeout}ms)`,
    },
    ...backend.extraProperties,
  };

  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: [
      {
        name: "ping",
        description:
          "Connectivity test. Returns 'pong' instantly without calling the CLI.",
        inputSchema: {
          type: "object",
          additionalProperties: false,
          properties: {},
        },
      },
      {
        name: backend.toolName,
        description: backend.description,
        inputSchema: {
          type: "object",
          additionalProperties: true,
          properties,
          required: ["prompt"],
        },
      },
    ],
  }));

  server.setRequestHandler(CallToolRequestSchema, async ({ params }) => {
    if (params.name === "ping") {
      return { content: [{ type: "text", text: "pong" }] };
    }

    if (shutdownStarted) {
      return {
        content: [{ type: "text", text: "Server is shutting down" }],
        isError: true,
      };
    }

    if (params.name !== backend.toolName) {
      return {
        content: [
          {
            type: "text",
            text: `Unknown tool: ${params.name}`,
          },
        ],
        isError: true,
      };
    }

    activeRequests += 1;
    const rawArgs =
      params.arguments && typeof params.arguments === "object"
        ? params.arguments
        : {};
    const allowedArgKeys = new Set([
      "prompt",
      "timeout_ms",
      ...Object.keys(backend.extraProperties),
    ]);
    const ignoredArgKeys = Object.keys(rawArgs).filter(
      (key) => !allowedArgKeys.has(key),
    );
    if (ignoredArgKeys.length > 0) {
      logErr(
        `[mcp-agents] tools/call: ignoring unsupported args: ${ignoredArgKeys.join(", ")}`,
      );
    }

    const prompt = toStringArg(rawArgs.prompt);
    const timeoutMsRaw = rawArgs.timeout_ms;
    const timeoutMs = Number.isInteger(timeoutMsRaw)
      ? timeoutMsRaw
      : effectiveTimeout;

    if (!prompt.trim()) {
      activeRequests -= 1;
      maybeFinalizeShutdown();
      return {
        content: [
          {
            type: "text",
            text: "Missing required argument: prompt",
          },
        ],
        isError: true,
      };
    }

    const extraOpts = {};
    for (const key of Object.keys(backend.extraProperties)) {
      extraOpts[key] = rawArgs[key] ?? backend.extraProperties[key].default;
    }

    const cliArgs = backend.stdinPrompt
      ? backend.buildArgs(extraOpts)
      : backend.buildArgs(prompt, extraOpts);
    let isolatedWorkdir;
    const buildCliOpts = (attemptTimeoutMs) => (
      {
        timeoutMs: attemptTimeoutMs,
        ...(backend.stdinPrompt ? { stdinData: prompt } : {}),
        ...(isolatedWorkdir ? { cwd: isolatedWorkdir } : {}),
        onSpawn: ({ pid, killGroup }) => {
          if (!pid) return;
          activeChildren.set(pid, killGroup);
        },
        onSettled: (pid) => {
          if (!pid) return;
          activeChildren.delete(pid);
          maybeFinalizeShutdown();
        },
      }
    );

    logErr(`[mcp-agents] tools/call: running ${backend.command} …`);
    try {
      if (shutdownStarted) {
        return {
          content: [{ type: "text", text: "Server is shutting down" }],
          isError: true,
        };
      }

      if (backend.isolateCwd) {
        try {
          isolatedWorkdir = createIsolatedWorkdir(providerName);
        } catch (err) {
          const msg = err instanceof Error ? err.message : String(err);
          logErr(`[mcp-agents] failed to create isolated workdir: ${msg}`);
          return {
            content: [
              {
                type: "text",
                text: `Failed to prepare isolated working directory: ${msg}`,
              },
            ],
            isError: true,
          };
        }
      }

      const startedAt = Date.now();
      const maxAttempts = providerName === "claude"
        ? CLAUDE_EMPTY_OUTPUT_MAX_ATTEMPTS
        : 1;
      let lastResult;
      let lastNormalized = { text: "", isError: false };

      for (let attempt = 1; attempt <= maxAttempts; attempt++) {
        const elapsedMs = Date.now() - startedAt;
        const remainingMs = timeoutMs - elapsedMs;

        if (remainingMs <= 0) break;

        const result = await runCli(
          backend.command,
          cliArgs,
          buildCliOpts(remainingMs),
        );
        lastResult = result;
        const normalized = normalizeToolOutput(providerName, result.output);
        lastNormalized = normalized;

        if (normalized.isError) {
          const msg = normalized.text.trim() || `${backend.command} returned is_error=true`;
          logErr(
            `[mcp-agents] tools/call: provider returned error payload (provider=${providerName})`,
          );
          return {
            content: [{ type: "text", text: msg }],
            isError: true,
          };
        }

        if (normalized.text.trim()) {
          logErr("[mcp-agents] tools/call: done");
          return {
            content: [{ type: "text", text: normalized.text }],
          };
        }

        if (attempt < maxAttempts) {
          logErr(
            "[mcp-agents] tools/call: empty output; retrying " +
              `(provider=${providerName}, attempt=${attempt}/${maxAttempts}, ` +
              `duration_ms=${result.durationMs}, timeout_ms=${timeoutMs}, ` +
              `stdout_bytes=${result.stdoutBytes}, stderr_bytes=${result.stderrBytes})`,
          );
        }
      }

      if (lastResult && !lastNormalized.text.trim()) {
        const elapsedMs = Date.now() - startedAt;
        const emptyMsg = providerName === "claude"
          ? "claude returned empty output twice (exit 0); treated as failure"
          : `${backend.command} returned empty output (exit 0); treated as failure`;

        logErr(
          "[mcp-agents] tools/call: empty output after retries " +
            `(provider=${providerName}, attempts=${maxAttempts}, ` +
            `elapsed_ms=${elapsedMs}, timeout_ms=${timeoutMs}, ` +
            `stdout_bytes=${lastResult.stdoutBytes}, stderr_bytes=${lastResult.stderrBytes})`,
        );
        return {
          content: [{ type: "text", text: emptyMsg }],
          isError: true,
        };
      }

      const timeoutMsg = `${backend.command} failed: timeout budget exhausted before retry`;
      logErr(
        "[mcp-agents] tools/call: timeout budget exhausted " +
          `(provider=${providerName}, timeout_ms=${timeoutMs})`,
      );
      return {
        content: [{ type: "text", text: timeoutMsg }],
        isError: true,
      };
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      logErr(msg);
      return {
        content: [{ type: "text", text: msg }],
        isError: true,
      };
    } finally {
      if (isolatedWorkdir) {
        try {
          rmSync(isolatedWorkdir, { recursive: true, force: true });
        } catch (err) {
          const msg = err instanceof Error ? err.message : String(err);
          logErr(`[mcp-agents] failed to clean isolated workdir: ${msg}`);
        }
      }
      activeRequests -= 1;
      maybeFinalizeShutdown();
    }
  });

  const transport = new StdioServerTransport();
  await server.connect(transport);

  // Prevent premature exit when stdin EOF arrives before async
  // request handlers (tools/call -> execFile) register active handles.
  // The SDK transport doesn't listen for stdin 'end', so the event
  // loop loses its only handle when the pipe closes.
  keepAlive = setInterval(() => {}, 60_000);
  const origOnClose = transport.onclose;
  transport.onclose = () => {
    clearInterval(keepAlive);
    origOnClose?.();
  };

  process.stdin.once("end", () => {
    beginShutdown("stdin-end");
  });
  process.stdin.once("close", () => {
    beginShutdown("stdin-close");
  });
  process.stdout.on("error", (err) => {
    if (err?.code === "EPIPE") beginShutdown("stdout-epipe");
  });
  for (const sig of ["SIGTERM", "SIGINT", "SIGHUP"]) {
    process.once(sig, () => {
      beginShutdown(sig, 128 + SIGNAL_CODES[sig]);
    });
  }

  logErr(`[mcp-agents] ready (provider: ${providerName})`);
}

process.on("unhandledRejection", (reason) => {
  logErr(
    `UnhandledRejection: ${reason instanceof Error ? reason.stack : reason}`,
  );
  if (fatalShutdown) {
    fatalShutdown("unhandledRejection", 1);
    return;
  }
  process.exit(1);
});

process.on("uncaughtException", (err) => {
  logErr(`UncaughtException: ${err.stack || err.message}`);
  if (fatalShutdown) {
    fatalShutdown("uncaughtException", 1);
    return;
  }
  process.exit(1);
});

main().catch((err) => {
  logErr(err.stack || err.message);
  process.exit(1);
});
