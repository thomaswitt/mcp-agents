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
const SIGNAL_CODES = { SIGHUP: 1, SIGINT: 2, SIGTERM: 15 };
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
    if (parsed && typeof parsed === "object" && parsed.type === "result") {
      return {
        text: toStringArg(parsed.result),
        isError: parsed.is_error === true,
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
  --timeout <seconds>            Default timeout per call [default: 300]
  --help, -h                     Show this help message
  --version, -v                  Show version number`);
}

/**
 * Parse CLI flags from process.argv.
 * Handles --help, --version, --provider, --model, --model_reasoning_effort,
 * --sandbox_mode, --approval_policy, and unknown flags.
 * @returns {{ provider: string, model?: string, modelReasoningEffort?: string, sandboxMode?: string, approvalPolicy?: string, defaultTimeoutMs?: number }}
 */
function parseArgs() {
  const args = process.argv.slice(2);
  let provider = "codex";
  let model;
  let modelReasoningEffort;
  let sandboxMode;
  let approvalPolicy;
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
}

/**
 * Filter a single newline-delimited JSON-RPC message on its way to the codex
 * pass-through. Strips per-call model/effort overrides from `tools/call` so the
 * client cannot escape the pinned model/effort — both the top-level `model` arg
 * and the model-envelope keys inside a `config` override map. sandbox/cwd/
 * approval-policy (top-level and inside `config`) are intentionally left intact
 * so callers can steer them per call. Non-`tools/call`, unparseable, and
 * nothing-to-strip lines are returned byte-for-byte unchanged so the MCP framing
 * is preserved.
 * @param {string} line
 * @returns {string}
 */
function filterCodexToolCall(line) {
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

  if (removed.length === 0) return line; // nothing pinned to strip — keep framing

  logErr(
    `[mcp-agents] codex passthrough: pinning model/effort, stripped: ${removed.join(", ")}`,
  );
  return JSON.stringify(msg);
}

/**
 * Spawn codex mcp-server as a pass-through. stdout/stderr flow straight back to
 * the client, but the client's stdin is intercepted line-by-line so per-call
 * model/config overrides are stripped before reaching codex.
 * @param {{ model?: string, modelReasoningEffort?: string, sandboxMode?: string, approvalPolicy?: string }} opts
 */
function runCodexPassthrough({
  model,
  modelReasoningEffort,
  sandboxMode,
  approvalPolicy,
}) {
  const resolvedModel = model || DEFAULT_CODEX_MODEL;
  const resolvedModelReasoningEffort =
    modelReasoningEffort || DEFAULT_CODEX_MODEL_REASONING_EFFORT;
  const resolvedSandboxMode = sandboxMode || DEFAULT_CODEX_SANDBOX_MODE;
  const resolvedApprovalPolicy = approvalPolicy || DEFAULT_CODEX_APPROVAL_POLICY;
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
      `isolated_home=true)`,
  );

  const child = spawn("codex", args, {
    env: { ...process.env, CODEX_HOME: isolatedCodexHome },
    // stdin is piped (not inherited) so we can strip per-call overrides;
    // stdout stays inherited so codex responses reach the client untouched.
    stdio: ["pipe", "inherit", "pipe"],
  });

  child.stderr.on("data", (chunk) => {
    logErr(`[codex] ${chunk.toString().trimEnd()}`);
  });

  // Pump client stdin -> codex stdin, splitting on the newline BYTE (0x0a) that
  // delimits MCP stdio JSON-RPC frames. Buffering raw bytes (not per-chunk
  // strings) avoids corrupting a multibyte UTF-8 sequence that straddles two
  // read chunks, which would otherwise break the byte-for-byte passthrough.
  child.stdin.on("error", () => {}); // ignore EPIPE if codex exits early
  const NEWLINE = 0x0a;
  let stdinBuf = Buffer.alloc(0);
  process.stdin.on("data", (chunk) => {
    stdinBuf = stdinBuf.length ? Buffer.concat([stdinBuf, chunk]) : chunk;
    let nl;
    while ((nl = stdinBuf.indexOf(NEWLINE)) !== -1) {
      const line = stdinBuf.subarray(0, nl).toString("utf8");
      stdinBuf = stdinBuf.subarray(nl + 1);
      child.stdin.write(`${filterCodexToolCall(line)}\n`);
    }
  });
  process.stdin.on("error", () => {});
  process.stdin.on("end", () => {
    if (stdinBuf.length > 0) {
      child.stdin.write(filterCodexToolCall(stdinBuf.toString("utf8")));
    }
    child.stdin.end();
  });

  for (const sig of ["SIGTERM", "SIGINT", "SIGHUP"]) {
    process.once(sig, () => {
      child.kill(sig);
      setTimeout(() => {
        child.kill("SIGKILL");
        cleanupIsolatedCodexHome();
        process.exit(128 + SIGNAL_CODES[sig]);
      }, 5000).unref();
    });
  }

  child.on("error", (err) => {
    cleanupIsolatedCodexHome();
    logErr(`[mcp-agents] failed to start codex: ${err.message}`);
    process.exitCode = 1;
  });

  child.on("exit", (code, signal) => {
    cleanupIsolatedCodexHome();
    if (signal) {
      logErr(`[mcp-agents] codex killed by ${signal}`);
      process.exitCode = 128 + (SIGNAL_CODES[signal] ?? 0);
    } else {
      if (code !== 0) logErr(`[mcp-agents] codex exited with code ${code}`);
      process.exitCode = code ?? 1;
    }
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
