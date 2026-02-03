#!/usr/bin/env node
/* eslint-disable no-console */

import { execFile } from "node:child_process";
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

const DEFAULT_TIMEOUT_MS = 30_000;
const MAX_BUFFER_BYTES = 10 * 1024 * 1024;

// ---------------------------------------------------------------------------
// CLI Backend Definitions
// ---------------------------------------------------------------------------

const CLI_BACKENDS = {
  claude: {
    command: "claude",
    toolName: "claude_code",
    description: "Run Claude Code CLI (claude -p) with a prompt.",
    buildArgs: (prompt) => ["--no-session-persistence", "-p", prompt],
    extraProperties: {},
  },
  gemini: {
    command: "gemini",
    toolName: "gemini",
    description: "Run Gemini CLI (gemini -p) with a prompt.",
    buildArgs: (prompt, opts) => {
      const args = [];
      if (opts.sandbox !== false) args.push("-s");
      args.push("-p", prompt);
      return args;
    },
    extraProperties: {
      sandbox: {
        type: "boolean",
        default: true,
        description: "Run in sandbox mode (-s flag). Defaults to true.",
      },
    },
  },
  codex: {
    command: "codex",
    toolName: "codex",
    description: "Run Codex CLI (codex exec) with a prompt.",
    buildArgs: (prompt) => ["exec", prompt],
    extraProperties: {},
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
  --provider <name>  CLI backend to use (${providers}) [default: codex]
  --help, -h         Show this help message
  --version, -v      Show version number`);
}

/**
 * Parse CLI flags from process.argv.
 * Handles --help, --version, --provider, and unknown flags.
 * @returns {string | null} Provider name, or null if the process should exit.
 */
function parseArgs() {
  const args = process.argv.slice(2);
  let provider = "codex";

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
      default:
        process.stderr.write(`error: unknown option: ${args[i]}\n`);
        process.exit(1);
    }
  }

  return provider;
}

/**
 * Run a CLI command and return stdout (or stderr if stdout is empty).
 * @param {string} command
 * @param {string[]} args
 * @param {{ timeoutMs?: number }} [opts]
 * @returns {Promise<string>}
 */
function runCli(command, args, opts = {}) {
  const timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;

  return new Promise((resolve, reject) => {
    const child = execFile(
      command,
      args,
      {
        timeout: timeoutMs,
        maxBuffer: MAX_BUFFER_BYTES,
        env: { ...process.env, NO_COLOR: "1" },
      },
      (error, stdout, stderr) => {
        if (error) {
          const details = [
            `${command} failed: ${error.message}`,
            stderr ? `stderr:\n${stderr}` : null,
          ]
            .filter(Boolean)
            .join("\n");

          reject(new Error(details));
          return;
        }

        const out = (stdout || stderr || "").trimEnd();
        resolve(out);
      },
    );

    // Close stdin immediately so the child process doesn't wait for piped input.
    // execFile creates a pipe for stdin by default; leaving it open causes
    // the child to hang indefinitely waiting for EOF.
    child.stdin?.end();

    child.on("error", (err) => {
      reject(new Error(`Failed to start ${command}: ${err.message}`));
    });
  });
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  const providerName = parseArgs();
  const backend = CLI_BACKENDS[providerName];

  if (!backend) {
    logErr(`[mcp-agents] Unknown provider: ${providerName}`);
    logErr(
      `[mcp-agents] Available: ${Object.keys(CLI_BACKENDS).join(", ")}`,
    );
    process.exitCode = 1;
    return;
  }

  const server = new Server(
    { name: "mcp-agents", version: VERSION },
    { capabilities: { tools: {} } },
  );

  const properties = {
    prompt: {
      type: "string",
      description: `Prompt for ${backend.command}`,
    },
    timeout_ms: {
      type: "integer",
      minimum: 1,
      description: `Optional timeout override (default ${DEFAULT_TIMEOUT_MS})`,
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
      : DEFAULT_TIMEOUT_MS;

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
      if (params.arguments?.[key] != null) {
        extraOpts[key] = params.arguments[key];
      }
    }

    const cliArgs = backend.buildArgs(prompt, extraOpts);

    logErr(`[mcp-agents] tools/call: running ${backend.command} …`);
    try {
      const output = await runCli(backend.command, cliArgs, { timeoutMs });
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
