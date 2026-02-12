#!/usr/bin/env node
/* eslint-disable no-console */

import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
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
const MAX_BUFFER_BYTES = 10 * 1024 * 1024;

// ---------------------------------------------------------------------------
// CLI Backend Definitions
// ---------------------------------------------------------------------------

const CLI_BACKENDS = {
  claude: {
    command: "claude",
    toolName: "claude_code",
    description: "Run Claude Code CLI with a prompt (via stdin).",
    stdinPrompt: true,
    buildArgs: () => ["--no-session-persistence", "-p"],
    extraProperties: {},
  },
  gemini: {
    command: "gemini",
    toolName: "gemini",
    description: "Run Gemini CLI (gemini -p) with a prompt.",
    stdinPrompt: false,
    buildArgs: (prompt, opts) => {
      const args = [];
      if (opts.sandbox === true) args.push("-s");
      args.push("-p", prompt);
      return args;
    },
    extraProperties: {
      sandbox: {
        type: "boolean",
        default: false,
        description: "Run in sandbox mode (-s flag). Defaults to false.",
      },
    },
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
 * Print usage information to stdout.
 */
function printHelp() {
  const providers = Object.keys(CLI_BACKENDS).join(", ");
  console.log(`mcp-agents v${VERSION}

Usage: mcp-agents [options]

Options:
  --provider <name>              CLI backend to use (${providers}) [default: codex]
  --model <model>                Model to use (codex) [default: gpt-5.3-codex]
  --model_reasoning_effort <e>   Reasoning effort (codex) [default: high]
  --sandbox <bool>               Gemini sandbox mode (true/false) [default: false]
  --timeout <seconds>            Default timeout per call [default: 300]
  --help, -h                     Show this help message
  --version, -v                  Show version number`);
}

/**
 * Parse CLI flags from process.argv.
 * Handles --help, --version, --provider, --model, --model_reasoning_effort, --sandbox, and unknown flags.
 * @returns {{ provider: string, model?: string, modelReasoningEffort?: string, sandbox: boolean, defaultTimeoutMs?: number }}
 */
function parseArgs() {
  const args = process.argv.slice(2);
  let provider = "codex";
  let model;
  let modelReasoningEffort;
  let sandbox = false;
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
      case "--sandbox":
        if (i + 1 >= args.length) {
          process.stderr.write("error: --sandbox requires a value\n");
          process.exit(1);
        }
        sandbox = args[++i] === "true";
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

  return { provider, model, modelReasoningEffort, sandbox, defaultTimeoutMs };
}

/**
 * Run a CLI command and return stdout (or stderr if stdout is empty).
 * Uses spawn with detached:true so the entire process group can be killed
 * on timeout — prevents orphan child processes.
 * @param {string} command
 * @param {string[]} args
 * @param {{ timeoutMs?: number, stdinData?: string }} [opts]
 * @returns {Promise<string>}
 */
function runCli(command, args, opts = {}) {
  const timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const stdinData = opts.stdinData;

  return new Promise((resolve, reject) => {
    let stdout = "";
    let stderr = "";
    let stdoutLen = 0;
    let stderrLen = 0;
    let settled = false;

    const child = spawn(command, args, {
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

    const done = (err) => {
      clearTimeout(timer);
      if (settled) return;
      settled = true;
      err ? reject(err) : resolve((stdout || stderr || "").trimEnd());
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
 * Spawn codex mcp-server as a pass-through, piping stdio directly.
 * @param {{ model?: string, modelReasoningEffort?: string }} opts
 */
function runCodexPassthrough({ model, modelReasoningEffort }) {
  const args = [
    "-m",
    model || "gpt-5.3-codex",
    "-s",
    "read-only",
    "-a",
    "never",
    "-c",
    `model_reasoning_effort=${modelReasoningEffort || "high"}`,
    "mcp-server",
  ];

  logErr(`[mcp-agents] passthrough: codex ${args.join(" ")}`);

  const child = spawn("codex", args, { stdio: "inherit" });

  child.on("error", (err) => {
    logErr(`[mcp-agents] failed to start codex: ${err.message}`);
    process.exitCode = 1;
  });

  child.on("exit", (code) => {
    process.exitCode = code ?? 1;
  });
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  const { provider: providerName, model, modelReasoningEffort, sandbox, defaultTimeoutMs } = parseArgs();
  const backend = CLI_BACKENDS[providerName];

  if (!backend) {
    logErr(`[mcp-agents] Unknown provider: ${providerName}`);
    logErr(`[mcp-agents] Available: ${Object.keys(CLI_BACKENDS).join(", ")}`);
    process.exitCode = 1;
    return;
  }

  if (backend.passthrough) {
    runCodexPassthrough({ model, modelReasoningEffort });
    return;
  }

  if (backend.extraProperties.sandbox) {
    backend.extraProperties.sandbox.default = sandbox;
  }

  const server = new Server(
    { name: "mcp-agents", version: VERSION },
    { capabilities: { tools: {} } },
  );

  const effectiveTimeout = defaultTimeoutMs ?? DEFAULT_TIMEOUT_MS;

  const properties = {
    prompt: {
      type: "string",
      description: `Prompt for ${backend.command}`,
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
          additionalProperties: false,
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

    const prompt = toStringArg(params.arguments?.prompt);
    const timeoutMsRaw = params.arguments?.timeout_ms;
    const timeoutMs = Number.isInteger(timeoutMsRaw)
      ? timeoutMsRaw
      : effectiveTimeout;

    if (!prompt.trim()) {
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
      extraOpts[key] = params.arguments?.[key] ?? backend.extraProperties[key].default;
    }

    const cliArgs = backend.stdinPrompt
      ? backend.buildArgs(extraOpts)
      : backend.buildArgs(prompt, extraOpts);
    const cliOpts = backend.stdinPrompt
      ? { timeoutMs, stdinData: prompt }
      : { timeoutMs };

    logErr(`[mcp-agents] tools/call: running ${backend.command} …`);
    try {
      const output = await runCli(backend.command, cliArgs, cliOpts);
      logErr("[mcp-agents] tools/call: done");
      return {
        content: [{ type: "text", text: output || "" }],
      };
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      logErr(msg);
      return {
        content: [{ type: "text", text: msg }],
        isError: true,
      };
    }
  });

  const transport = new StdioServerTransport();
  await server.connect(transport);

  // Prevent premature exit when stdin EOF arrives before async
  // request handlers (tools/call -> execFile) register active handles.
  // The SDK transport doesn't listen for stdin 'end', so the event
  // loop loses its only handle when the pipe closes.
  const keepAlive = setInterval(() => {}, 60_000);
  const origOnClose = transport.onclose;
  transport.onclose = () => {
    clearInterval(keepAlive);
    origOnClose?.();
  };

  logErr(`[mcp-agents] ready (provider: ${providerName})`);
}

process.on("unhandledRejection", (reason) => {
  logErr(
    `UnhandledRejection: ${reason instanceof Error ? reason.stack : reason}`,
  );
  process.exitCode = 1;
});

process.on("uncaughtException", (err) => {
  logErr(`UncaughtException: ${err.stack || err.message}`);
  process.exitCode = 1;
});

main().catch((err) => {
  logErr(err.stack || err.message);
  process.exitCode = 1;
});
