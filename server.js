#!/usr/bin/env node
/* eslint-disable no-console */

import { spawn } from "node:child_process";
import {
  copyFileSync,
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
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
const DEFAULT_CODEX_MODEL = "gpt-5.5";
const DEFAULT_CODEX_MODEL_REASONING_EFFORT = "xhigh";
const DEFAULT_CODEX_SANDBOX_MODE = "workspace-write";
const DEFAULT_CODEX_APPROVAL_POLICY = "never";
// Idle watchdog for the codex pass-through: if a request is in flight and codex
// emits nothing on stdout/stderr for this long, the wrapper synthesizes a
// JSON-RPC error for the open request(s) and tears codex down — converting an
// unbounded post-completion stall into a surfaced error. 0 disables it.
const DEFAULT_CODEX_IDLE_TIMEOUT_MS = 600_000;
const DEFAULT_CLAUDE_MODEL = "claude-opus-4-8";
const DEFAULT_CLAUDE_EFFORT = "xhigh";
// tools/call argument keys stripped from the codex pass-through so callers
// cannot override the pinned model/effort. sandbox/cwd/approval-policy are
// intentionally left intact so callers can steer them per call.
//   - top-level: only the dedicated `model` arg (there is no top-level
//     model_reasoning_effort/profile arg in the codex tool schema)
//   - inside the `config` override map: model/effort plus every other
//     model-envelope vector — a `profile`/`profiles` can carry its own
//     model/effort, provider/base-url keys re-point the same model name to a
//     different backend, and the plan/review variants carry their own
//     model/effort; all are stripped so the pin cannot be bypassed. Matched on
//     each config key's HEAD segment so dotted overrides (codex accepts paths
//     like `profiles.x.model`) are caught too, not just exact keys.
const CODEX_STRIPPED_TOP_LEVEL_ARGS = ["model"];
const CODEX_STRIPPED_CONFIG_KEYS = [
  "model",
  "model_reasoning_effort",
  "profile",
  "profiles",
  "model_provider",
  "model_providers",
  "openai_base_url",
  "chatgpt_base_url",
  "model_catalog_json",
  "plan_mode_reasoning_effort",
  "review_model",
];
const MAX_BUFFER_BYTES = 10 * 1024 * 1024;
const CLAUDE_EMPTY_OUTPUT_MAX_ATTEMPTS = 2;
const SIGNAL_CODES = { SIGHUP: 1, SIGINT: 2, SIGKILL: 9, SIGTERM: 15 };
const SHUTDOWN_TIMEOUT_MS = 3_000;
let fatalShutdown;

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
  --timeout <seconds>            Default timeout per call [default: 300]
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
    "",
    "[features]",
    "multi_agent = false",
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
 * Build the text for codex's native `developer-instructions` field (a
 * developer-role message) from a goal. This is the MCP-correct vehicle for a
 * standing objective: it is higher-altitude than the user prompt and persists
 * across the thread. It is NOT codex's `/goal` subsystem — that is a TUI-only
 * slash command (parsed in codex-rs/tui, e.g. chatwidget/slash_dispatch.rs) and
 * is not reachable through the MCP `codex`/`codex-reply` tool surface. Any
 * caller-supplied developer instructions are preserved after the objective.
 * @param {string} goal
 * @param {string} [existing] caller-supplied developer-instructions, if any
 * @returns {string}
 */
function buildGoalDeveloperInstructions(goal, existing) {
  const directive =
    "Persistent objective for this Codex thread (a standing goal — keep " +
    "pursuing it across turns unless explicitly superseded):\n" +
    goal.trim();
  const prior = typeof existing === "string" ? existing.trim() : "";
  return prior ? `${directive}\n\n---\n\n${prior}` : directive;
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
 * Filter a single newline-delimited JSON-RPC message on its way to the codex
 * pass-through. Two transforms, both confined to `tools/call`:
 *   1. Strip per-call model/effort overrides — the top-level `model` arg and the
 *      model-envelope keys inside a `config` override map — so the client cannot
 *      escape the pinned model/effort. sandbox/cwd/approval-policy (top-level and
 *      inside `config`) are intentionally left intact so callers can steer them
 *      per call.
 *   2. Goal injection — codex's native `/goal` is a TUI-only slash command, not
 *      reachable via MCP, so a wrapper-only `goal` arg is always stripped and the
 *      objective is injected the MCP-correct way: into `developer-instructions`
 *      (a developer-role message) for the initial `codex` call, or as a concise
 *      prompt reminder for a `codex-reply` turn (which has no
 *      `developer-instructions` field). A per-call `goal` overrides the
 *      server-wide `--goal` default (`opts.serverGoal`); only a string per-call
 *      goal overrides (a blank one suppresses the default for that call), while a
 *      non-string `goal` is dropped without disturbing the default.
 * Non-`tools/call`, unparseable, and nothing-to-change lines are returned
 * byte-for-byte unchanged so the MCP framing is preserved; any actual mutation
 * re-serializes the message (the intended, framing-safe path for a changed
 * message).
 * @param {string} line
 * @param {{ serverGoal?: string }} [opts]
 * @returns {string}
 */
function filterCodexToolCall(line, opts = {}) {
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

  const removed = [];

  for (const key of CODEX_STRIPPED_TOP_LEVEL_ARGS) {
    if (key in args) {
      delete args[key];
      removed.push(key);
    }
  }

  // Per-call `config` overrides beat CODEX_HOME/config.toml, so the pinned
  // model/effort must be stripped from here too; everything else (sandbox_mode,
  // approval_policy, cwd, sandbox_workspace_write, …) is left untouched. codex
  // config overrides also accept dotted paths (e.g. "profiles.x.model"), so
  // match each key on its HEAD segment, not the exact key.
  const cfg = args.config;
  if (cfg && typeof cfg === "object" && !Array.isArray(cfg)) {
    for (const key of Object.keys(cfg)) {
      if (CODEX_STRIPPED_CONFIG_KEYS.includes(key.split(".")[0])) {
        delete cfg[key];
        removed.push(`config.${key}`);
      }
    }
    // Drop a now-empty override map so codex never receives a bare `config: {}`.
    if (Object.keys(cfg).length === 0) delete args.config;
  }

  // ── Goal injection ────────────────────────────────────────────────────────
  // A per-call `goal` (any value) is always stripped — codex's schema has no
  // `goal`, so it must never be forwarded. Only a STRING per-call goal counts as
  // an override: a string (including "") replaces the server default for this
  // call, so "" suppresses it. A non-string `goal` is malformed and is dropped
  // without disturbing the configured server default. A blank effective goal
  // injects nothing.
  let goalLog;
  let goalSource = "server";
  let effectiveGoal = opts.serverGoal;
  if ("goal" in args) {
    const perCallGoal = args.goal;
    delete args.goal;
    goalLog = "stripped per-call goal arg";
    if (typeof perCallGoal === "string") {
      effectiveGoal = perCallGoal;
      goalSource = "per-call";
    }
  }
  if (effectiveGoal && effectiveGoal.trim()) {
    if (msg.params?.name === "codex") {
      // Initial `codex` call: the native developer-instructions field is the
      // correct, thread-persistent vehicle for a standing objective.
      args["developer-instructions"] = buildGoalDeveloperInstructions(
        effectiveGoal,
        args["developer-instructions"],
      );
      goalLog = `injected ${goalSource} goal into developer-instructions`;
    } else if (msg.params?.name === "codex-reply" && typeof args.prompt === "string") {
      // codex-reply has no developer-instructions field, so restate the
      // objective as a concise prompt reminder. Any other (unknown/future) tool
      // is left untouched — only the wrapper-only `goal` arg stripped above is
      // removed, never the prompt — so the byte-for-byte invariant holds for
      // tools this wrapper does not explicitly support.
      args.prompt = applyGoalPreamble(args.prompt, effectiveGoal);
      goalLog = `injected ${goalSource} goal into codex-reply prompt`;
    }
  }

  if (removed.length === 0 && !goalLog) return line; // nothing changed — keep framing

  if (removed.length > 0) {
    logErr(
      `[mcp-agents] codex passthrough: pinning model/effort, stripped: ${removed.join(", ")}`,
    );
  }
  if (goalLog) {
    logErr(`[mcp-agents] codex passthrough: ${goalLog}`);
  }
  return JSON.stringify(msg);
}

// Tools whose advertised inputSchema gains a wrapper-only `goal` property so a
// client's model knows it can pass one (the model only emits args declared in
// the schema). The arg is stripped inbound by filterCodexToolCall before it
// reaches codex; advertising it here is purely for discoverability.
const CODEX_GOAL_TOOLS = new Set(["codex", "codex-reply"]);
const CODEX_GOAL_PROPERTY_DESCRIPTION =
  "Optional standing objective for this Codex session. mcp-agents injects it as " +
  "`developer-instructions` (codex) or a prompt reminder (codex-reply); it is not a " +
  "native Codex parameter. Overrides the server-wide --goal default for this call; " +
  "pass an empty string to suppress that default.";

/**
 * Mutate a parsed `tools/list` RESPONSE in place, adding a `goal` property to the
 * advertised inputSchema of the `codex` and `codex-reply` tools. Returns true iff
 * it added `goal` to at least one tool. Only `properties` is touched — `required`
 * and `additionalProperties` are left intact (a declared property is not an
 * "additional" one, so `additionalProperties:false` stays valid). Best-effort per
 * tool: a target tool that already declares `goal` (idempotent) or whose
 * inputSchema.properties is missing/malformed (drifted schema) is simply skipped;
 * other valid targets are still augmented. Returns false (→ the caller forwards the
 * original bytes byte-for-byte) for an error response, a non-array `result.tools`,
 * or when no `codex`/`codex-reply` target was augmentable.
 * @param {any} msg
 * @returns {boolean}
 */
function injectGoalIntoToolsListMessage(msg) {
  const tools = msg?.result?.tools;
  if (!Array.isArray(tools)) return false;
  let changed = false;
  for (const tool of tools) {
    if (!tool || typeof tool !== "object" || !CODEX_GOAL_TOOLS.has(tool.name)) continue;
    const schema = tool.inputSchema;
    if (!schema || typeof schema !== "object" || Array.isArray(schema)) continue;
    const props = schema.properties;
    if (!props || typeof props !== "object" || Array.isArray(props)) continue;
    if ("goal" in props) continue; // idempotent — respect an existing declaration
    props.goal = { type: "string", description: CODEX_GOAL_PROPERTY_DESCRIPTION };
    changed = true;
  }
  return changed;
}

/**
 * Spawn codex mcp-server as a pass-through. codex stdout is forwarded back to
 * the client byte-for-byte, but the client's stdin is intercepted line-by-line
 * so per-call model/config overrides are stripped before reaching codex. An
 * idle watchdog converts an unbounded codex stall (no stdout/stderr while a
 * request is in flight) into a synthesized JSON-RPC error so the caller never
 * hangs forever.
 * @param {{ model?: string, modelReasoningEffort?: string, sandboxMode?: string, approvalPolicy?: string, idleTimeoutMs?: number, goal?: string }} opts
 */
function runCodexPassthrough({
  model,
  modelReasoningEffort,
  sandboxMode,
  approvalPolicy,
  idleTimeoutMs,
  goal,
}) {
  const resolvedModel = model || DEFAULT_CODEX_MODEL;
  const resolvedModelReasoningEffort =
    modelReasoningEffort || DEFAULT_CODEX_MODEL_REASONING_EFFORT;
  const resolvedSandboxMode = sandboxMode || DEFAULT_CODEX_SANDBOX_MODE;
  const resolvedApprovalPolicy = approvalPolicy || DEFAULT_CODEX_APPROVAL_POLICY;
  const resolvedIdleTimeoutMs = idleTimeoutMs ?? DEFAULT_CODEX_IDLE_TIMEOUT_MS;
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
      `idle_timeout_ms=${resolvedIdleTimeoutMs}, isolated_home=true)`,
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

  // ── In-flight request tracking ──────────────────────────────────────────
  // Client requests (id + method) awaiting a codex response. Keyed by a
  // type-preserving key so JSON-RPC `1` (number) and `"1"` (string) never
  // collide. `canceled` marks ids the client gave up on (notifications/
  // cancelled): we never synthesize a response for them, but they still count
  // toward teardown so a canceled-but-wedged codex is not left running.
  const inFlight = new Map();
  const idKey = (id) => `${typeof id}:${id}`;
  const addInFlight = (id) => {
    if (id == null) return;
    const key = idKey(id);
    if (!inFlight.has(key)) inFlight.set(key, { id, canceled: false });
  };
  const clearInFlight = (id) => {
    if (id != null) inFlight.delete(idKey(id));
  };
  const cancelInFlight = (id) => {
    const entry = id == null ? undefined : inFlight.get(idKey(id));
    if (entry) entry.canceled = true;
  };
  const hasEmittableInFlight = () => {
    for (const entry of inFlight.values()) if (!entry.canceled) return true;
    return false;
  };

  // ── Liveness / lifecycle state ──────────────────────────────────────────
  let finalizing = false;
  let exited = false;
  let stdoutPaused = false; // process.stdout backpressured (downstream, not idle)
  let idleTimer;
  let lastForwardedByteWasNewline = true; // nothing forwarded yet
  let stdoutObsBuf = Buffer.alloc(0); // observation copy of codex stdout
  let skippingFrame = false; // mid-skip of an oversized stdout frame (resync at \n)
  let droppedFrameResponseId; // partial oversized frame's classified id (cleared at its newline)
  let observationDropLogged = false; // log the first observation-cap drop only

  // ── tools/list goal-advertising rewrite (contained latch) ────────────────
  // While a `tools/list` request id is outstanding the forwarder switches from
  // raw passthrough to buffer-and-rewrite, injecting a `goal` property into the
  // advertised codex/codex-reply schemas of that one response, then returns to
  // raw. Observation above stays the SOLE authority for inFlight/the watchdog;
  // this path only changes HOW bytes reach the wire.
  const pendingToolsListIds = new Set(); // idKey(id) of outstanding tools/list requests (the latch)
  let rewriteBuf = Buffer.alloc(0); // buffer-mode accumulator; holds ≤1 trailing partial after a flush
  let rewriteSkipUntilNewline = false; // forwarding raw to the next newline (oversized frame or mode-boundary align)
  let rewriteSkipReleaseId; // idKey to release when the skipped frame's newline lands (oversized response only)
  let oversizedToolsListLogged = false; // log the first rewrite-cap drop only

  const killGroup = (signal) => {
    try {
      if (child.pid) process.kill(-child.pid, signal);
      else child.kill(signal);
    } catch {
      try { child.kill(signal); } catch {}
    }
  };

  const clearIdle = () => {
    if (idleTimer) {
      clearTimeout(idleTimer);
      idleTimer = undefined;
    }
  };
  const armIdle = () => {
    clearIdle();
    // No watchdog when disabled, while finalizing, or while downstream is
    // backpressured (blocked downstream != idle upstream).
    if (!(resolvedIdleTimeoutMs > 0) || finalizing || stdoutPaused) return;
    idleTimer = setTimeout(onIdle, resolvedIdleTimeoutMs);
  };
  const resetIdle = armIdle;

  // Parse one complete codex->client stdout frame (observation only — the raw
  // bytes are forwarded separately). Clears an id once its result/error lands.
  const observeOutgoingLine = (line) => {
    const trimmed = line.trim();
    if (!trimmed) return;
    let msg;
    try { msg = JSON.parse(trimmed); } catch { return; }
    if (
      msg && typeof msg === "object" && "id" in msg &&
      ("result" in msg || "error" in msg)
    ) {
      clearInFlight(msg.id);
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
    if (id !== undefined) clearInFlight(id);
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
        clearInFlight(droppedFrameResponseId);
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
    clearIdle();
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
    clearIdle();
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

    if (emit && hasEmittableInFlight()) {
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
          if (
            m && typeof m === "object" && "id" in m &&
            ("result" in m || "error" in m) &&
            pendingToolsListIds.has(idKey(m.id)) && injectGoalIntoToolsListMessage(m)
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

      for (const entry of inFlight.values()) {
        if (entry.canceled) continue;
        const frame = {
          jsonrpc: "2.0",
          id: entry.id,
          error: {
            code: -32001,
            message:
              `mcp-agents: codex pass-through aborted before responding ` +
              `(${reason}); the request was still open. Any applied edits may ` +
              `exist — verify the tree.`,
          },
        };
        try { process.stdout.write(`${JSON.stringify(frame)}\n`); } catch {}
      }
    }

    // Hygiene: drop the rewrite latch/skip state (forwarding has stopped).
    pendingToolsListIds.clear();
    rewriteSkipUntilNewline = false;
    rewriteSkipReleaseId = undefined;
    rewriteBuf = Buffer.alloc(0);

    flushThenExit(exitCode);
  };

  // Route the global uncaughtException/unhandledRejection handlers through the
  // same teardown so codex's DETACHED group is always killed — otherwise those
  // handlers call process.exit() directly and orphan codex (the 'exit' handler
  // only deletes CODEX_HOME, it cannot reap a detached group).
  fatalShutdown = (reason, code) =>
    finalize({ reason: `fatal: ${reason}`, emit: true, exitCode: code ?? 1 });

  function onIdle() {
    idleTimer = undefined;
    if (finalizing) return;
    if (hasEmittableInFlight()) {
      finalize({
        reason: `idle timeout (${Math.round(resolvedIdleTimeoutMs / 1000)}s)`,
        emit: true,
        exitCode: 1,
      });
      return;
    }
    // Only canceled requests left -> tear down quietly. Nothing open at all ->
    // healthy idle between calls, just re-arm.
    if (inFlight.size > 0) {
      finalize({
        reason: "idle timeout (canceled-only)",
        emit: false,
        exitCode: 1,
      });
    } else {
      armIdle();
    }
  }

  child.stderr.on("data", (chunk) => {
    resetIdle();
    logErr(`[codex] ${chunk.toString().trimEnd()}`);
  });

  const logRewriteDropOnce = () => {
    if (!oversizedToolsListLogged) {
      logErr(
        "[mcp-agents] codex passthrough: tools/list-window frame exceeded rewrite cap; " +
          "forwarding raw (goal not advertised on this response)",
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
      // Downstream full: pause codex and suspend the idle watchdog until the
      // client drains, so a slow reader is never mistaken for a stalled codex.
      stdoutPaused = true;
      clearIdle();
      child.stdout.pause();
    }
    return ok;
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
      !rewriteSkipUntilNewline && rewriteBuf.length > 0
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
        // Complete frame larger than the cap: forward raw without parsing (mirrors
        // observeOutgoing's oversized branch), releasing only a matching pending id.
        logRewriteDropOnce();
        const pid = peekResponseId(frameBytes);
        if (pid !== undefined && pendingToolsListIds.has(idKey(pid))) {
          pendingToolsListIds.delete(idKey(pid));
        }
        forwardChunk(frameBytes);
        continue;
      }
      let outBuf = frameBytes; // default: byte-for-byte
      try {
        const msg = JSON.parse(
          frameBytes.subarray(0, frameBytes.length - 1).toString("utf8"),
        );
        if (
          msg && typeof msg === "object" && "id" in msg &&
          ("result" in msg || "error" in msg) &&
          pendingToolsListIds.has(idKey(msg.id))
        ) {
          pendingToolsListIds.delete(idKey(msg.id));
          if (injectGoalIntoToolsListMessage(msg)) {
            outBuf = Buffer.from(`${JSON.stringify(msg)}\n`, "utf8");
          }
        }
      } catch {
        outBuf = frameBytes; // unparseable (mode-boundary tail / partial) — forward original bytes
      }
      forwardChunk(outBuf);
    }
    if (rewriteBuf.length > MAX_BUFFER_BYTES) {
      // Partial frame already past the cap with no newline: abandon rewriting for
      // THIS frame, forward what we have raw, and skip to its newline. Release only
      // a matching id, deferred to that newline.
      logRewriteDropOnce();
      const pid = peekResponseId(rewriteBuf);
      rewriteSkipReleaseId =
        pid !== undefined && pendingToolsListIds.has(idKey(pid)) ? idKey(pid) : undefined;
      forwardChunk(rewriteBuf);
      rewriteBuf = Buffer.alloc(0);
      rewriteSkipUntilNewline = true;
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
  // passthrough (forwardChunk); while a tools/list response is pending the
  // forwarder buffers and rewrites that one frame (bufferModeForward) to advertise
  // `goal`. Observation runs on the ORIGINAL bytes and stays the sole authority for
  // clearing in-flight ids — by the time it runs, every complete frame in this
  // chunk was already forwarded/queued, so it never leads forwarding.
  child.stdout.on("data", (chunk) => {
    if (finalizing) return; // stream ownership has been taken over
    resetIdle(); // UNCONDITIONAL, before the mode branch — buffer-mode activity must keep the watchdog alive

    if (pendingToolsListIds.size > 0 || rewriteBuf.length > 0 || rewriteSkipUntilNewline) {
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
  });

  process.stdout.on("drain", () => {
    if (!stdoutPaused) return;
    stdoutPaused = false;
    if (finalizing) return;
    child.stdout.resume();
    resetIdle();
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

  // Read-only inbound tracking: record client requests (id + method) as
  // in-flight and honor cancellations. Never mutates what is forwarded —
  // filterCodexToolCall remains the sole authority on the forwarded bytes.
  const noteInbound = (line) => {
    const trimmed = line.trim();
    if (!trimmed) return;
    let msg;
    try { msg = JSON.parse(trimmed); } catch { return; }
    if (!msg || typeof msg !== "object") return;
    // (Watchdog liveness is reset at the byte level in the stdin 'data' handler,
    // so even an elicitation response — bare id, no method — keeps a healthy
    // interactive flow alive.)
    if (msg.method === "notifications/cancelled") {
      const rid = msg.params?.requestId;
      cancelInFlight(rid);
      // A canceled/never-answered tools/list must not wedge buffer mode open. If
      // this cancel cleared the last pending tools/list id while a NON-tools/list
      // partial is withheld in rewriteBuf, flush it raw — otherwise a codex exit
      // with only-canceled work would drop those bytes (finalize skips recovery).
      if (rid != null) {
        pendingToolsListIds.delete(idKey(rid));
        returnToRawIfLatchClear();
      }
      return;
    }
    // A client message awaits a response iff it carries BOTH an id and a method.
    // A bare id with no method is a *response* to a codex elicitation — skip it
    // for in-flight tracking.
    if (msg.id != null && typeof msg.method === "string") {
      addInFlight(msg.id);
      if (msg.method === "tools/list") {
        // Arm the goal-advertising rewrite latch for this tools/list response. If
        // buffer mode would START mid-frame (a pre-latch frame's head was already
        // raw-forwarded and its newline hasn't arrived), first align by raw-skipping
        // the orphan tail to its next newline — so the tail is forwarded
        // byte-for-byte and never mis-parsed as a standalone frame nor byte-lost at
        // finalize. Equivalent to today's raw behaviour for that straddled frame.
        if (
          pendingToolsListIds.size === 0 && rewriteBuf.length === 0 &&
          !rewriteSkipUntilNewline && !lastForwardedByteWasNewline
        ) {
          rewriteSkipUntilNewline = true;
          rewriteSkipReleaseId = undefined;
        }
        pendingToolsListIds.add(idKey(msg.id));
      }
    }
  };

  let stdinBuf = Buffer.alloc(0);
  process.stdin.on("data", (chunk) => {
    // ANY inbound bytes mean the client side of the exchange is alive — even a
    // large/slow elicitation response arriving across chunks without a newline.
    // Reset the watchdog here at the BYTE level (not per parsed line): a truly
    // stalled exchange (codex silent AND client sending nothing) still produces
    // no inbound, so the genuine stall is still caught.
    resetIdle();
    stdinBuf = stdinBuf.length ? Buffer.concat([stdinBuf, chunk]) : chunk;
    let nl;
    while ((nl = stdinBuf.indexOf(NEWLINE)) !== -1) {
      const line = stdinBuf.subarray(0, nl).toString("utf8");
      stdinBuf = stdinBuf.subarray(nl + 1);
      noteInbound(line);
      child.stdin.write(`${filterCodexToolCall(line, { serverGoal: resolvedGoal })}\n`);
    }
  });
  process.stdin.on("error", () => {});
  process.stdin.on("end", () => {
    if (stdinBuf.length > 0) {
      const line = stdinBuf.toString("utf8");
      noteInbound(line);
      child.stdin.write(filterCodexToolCall(line, { serverGoal: resolvedGoal }));
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

  const effectiveTimeout = defaultTimeoutMs ?? DEFAULT_TIMEOUT_MS;

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
