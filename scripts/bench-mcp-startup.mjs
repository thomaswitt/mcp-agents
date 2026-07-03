#!/usr/bin/env node

import { spawn } from "node:child_process";
import {
  mkdir,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { join } from "node:path";

const DEFAULT_TMP_DIR = "/tmp/mcp-agents-startup-bench";

function parseArgs(argv) {
  const options = {
    runs: 5,
    coldRuns: null,
    provider: "claude",
    packageSpec: "mcp-agents@latest",
    tmpDir: DEFAULT_TMP_DIR,
    timeoutMs: 120_000,
    skipDefaultCache: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];

    switch (arg) {
      case "--runs":
        options.runs = parsePositiveInt(arg, argv[++index]);
        break;
      case "--cold-runs":
        options.coldRuns = parsePositiveInt(arg, argv[++index]);
        break;
      case "--provider":
        options.provider = parseValue(arg, argv[++index]);
        break;
      case "--package-spec":
        options.packageSpec = parseValue(arg, argv[++index]);
        break;
      case "--tmp":
        options.tmpDir = parseValue(arg, argv[++index]);
        break;
      case "--timeout-ms":
        options.timeoutMs = parsePositiveInt(arg, argv[++index]);
        break;
      case "--skip-default-cache":
        options.skipDefaultCache = true;
        break;
      case "--help":
      case "-h":
        printHelp();
        process.exit(0);
        break;
      default:
        throw new Error(`Unknown option: ${arg}`);
    }
  }

  options.coldRuns ??= options.runs;
  return options;
}

function parseValue(flag, value) {
  if (!value) throw new Error(`${flag} requires a value`);
  return value;
}

function parsePositiveInt(flag, value) {
  const parsed = Number.parseInt(parseValue(flag, value), 10);
  if (!Number.isInteger(parsed) || parsed <= 0) {
    throw new Error(`${flag} must be a positive integer`);
  }

  return parsed;
}

function printHelp() {
  console.log(`Usage: node scripts/bench-mcp-startup.mjs [options]

Benchmarks MCP startup through real /tmp project .mcp.json files.

Options:
  --runs <n>             Warm/global/default-cache runs (default: 5)
  --cold-runs <n>        Cold npx runs (default: same as --runs)
  --provider <name>      mcp-agents provider to expose (default: claude)
  --package-spec <spec>  npx package spec (default: mcp-agents@latest)
  --tmp <dir>            Benchmark workspace (default: ${DEFAULT_TMP_DIR})
  --timeout-ms <ms>      Per-run timeout (default: 120000)
  --skip-default-cache   Skip the real user npm-cache npx case
  --help, -h             Show this help

Examples:
  npm run bench:mcp-startup
  npm run bench:mcp-startup -- --runs 10
  npm run bench:mcp-startup -- --package-spec mcp-agents`);
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const expectedToolName = expectedTool(options.provider);

  await rm(options.tmpDir, { recursive: true, force: true });
  await mkdir(options.tmpDir, { recursive: true });

  const globalProject = await writeMcpProject({
    tmpDir: options.tmpDir,
    name: "global-install",
    command: "mcp-agents",
    args: ["--provider", options.provider],
  });

  const defaultCacheProject = await writeMcpProject({
    tmpDir: options.tmpDir,
    name: "npx-default-cache",
    command: "npx",
    args: ["-y", options.packageSpec, "--provider", options.provider],
  });

  const warmCacheProject = await writeMcpProject({
    tmpDir: options.tmpDir,
    name: "npx-dedicated-cache-warm",
    command: "npx",
    args: ["-y", options.packageSpec, "--provider", options.provider],
    env: {
      npm_config_cache: join(options.tmpDir, "npm-cache-warm"),
    },
  });

  const cases = [
    {
      label: "global install",
      runs: options.runs,
      projectDir: globalProject,
    },
  ];

  if (!options.skipDefaultCache) {
    cases.push({
      label: "npx default cache",
      runs: options.runs,
      projectDir: defaultCacheProject,
    });
  }

  cases.push({
    label: "npx dedicated cache warm",
    runs: options.runs,
    projectDir: warmCacheProject,
    prewarm: true,
  });

  const coldCase = {
    label: "npx dedicated cache cold",
    runs: options.coldRuns,
    prepareRun: async (runIndex) => {
      const cacheDir = join(options.tmpDir, `npm-cache-cold-${runIndex}`);
      await rm(cacheDir, { recursive: true, force: true });

      return writeMcpProject({
        tmpDir: options.tmpDir,
        name: `npx-dedicated-cache-cold-${runIndex}`,
        command: "npx",
        args: ["-y", options.packageSpec, "--provider", options.provider],
        env: {
          npm_config_cache: cacheDir,
        },
      });
    },
  };

  console.log("MCP startup benchmark");
  console.log(`provider: ${options.provider}`);
  console.log(`package spec: ${options.packageSpec}`);
  console.log(`tmp dir: ${options.tmpDir}`);
  console.log(
    "scope: .mcp.json -> initialize -> notifications/initialized -> tools/list",
  );
  console.log("note: this does not call the provider model/tool\n");

  for (const benchCase of cases) {
    if (benchCase.prewarm) {
      await measureProject({
        projectDir: benchCase.projectDir,
        timeoutMs: options.timeoutMs,
        expectedToolName,
      });
    }

    const results = [];
    for (let index = 0; index < benchCase.runs; index += 1) {
      results.push(
        await measureProject({
          projectDir: benchCase.projectDir,
          timeoutMs: options.timeoutMs,
          expectedToolName,
        }),
      );
    }

    printResult(benchCase.label, results);
  }

  const coldResults = [];
  for (let index = 0; index < coldCase.runs; index += 1) {
    coldResults.push(
      await measureProject({
        projectDir: await coldCase.prepareRun(index),
        timeoutMs: options.timeoutMs,
        expectedToolName,
      }),
    );
  }

  printResult(coldCase.label, coldResults);
}

function expectedTool(provider) {
  switch (provider) {
    case "claude":
      return "claude_code";
    case "gemini":
      return "gemini";
    case "codex":
      return null;
    default:
      return null;
  }
}

async function writeMcpProject({ tmpDir, name, command, args, env = {} }) {
  const projectDir = join(tmpDir, name);
  const serverName = "mcp-agents-bench";

  await mkdir(projectDir, { recursive: true });
  await writeFile(
    join(projectDir, ".mcp.json"),
    `${JSON.stringify(
      {
        mcpServers: {
          [serverName]: {
            command,
            args,
            ...(Object.keys(env).length > 0 ? { env } : {}),
          },
        },
      },
      null,
      2,
    )}\n`,
  );

  return projectDir;
}

async function measureProject({ projectDir, timeoutMs, expectedToolName }) {
  const server = await readMcpServer(projectDir);
  return measureServer({
    projectDir,
    server,
    timeoutMs,
    expectedToolName,
  });
}

async function readMcpServer(projectDir) {
  const rawConfig = await readFile(join(projectDir, ".mcp.json"), "utf8");
  const config = JSON.parse(rawConfig);
  const server = config.mcpServers?.["mcp-agents-bench"];

  if (!server?.command) {
    throw new Error(`${projectDir}/.mcp.json does not define mcp-agents-bench`);
  }

  return {
    command: server.command,
    args: server.args ?? [],
    env: server.env ?? {},
  };
}

function measureServer({ projectDir, server, timeoutMs, expectedToolName }) {
  return new Promise((resolve) => {
    const startedAt = process.hrtime.bigint();
    const stderrLines = [];
    let readyMs = null;
    let stdoutBuffer = "";
    let stderrBuffer = "";
    let settled = false;

    const child = spawn(server.command, server.args, {
      cwd: projectDir,
      env: {
        ...process.env,
        ...server.env,
      },
      stdio: ["pipe", "pipe", "pipe"],
    });

    const timer = setTimeout(() => {
      finish({
        ok: false,
        error: `timeout after ${timeoutMs}ms`,
      });
    }, timeoutMs);

    child.once("error", (err) => {
      finish({
        ok: false,
        error: err.message,
      });
    });

    child.once("exit", (code, signal) => {
      if (settled) return;

      finish({
        ok: false,
        error: `process exited before tools/list (code=${code}, signal=${signal})`,
      });
    });

    child.stdout.on("data", (chunk) => {
      stdoutBuffer += chunk.toString("utf8");
      stdoutBuffer = consumeLines(stdoutBuffer, (line) => {
        if (line.blank) return;

        let message;
        try {
          message = JSON.parse(line.value);
        } catch {
          return;
        }

        if (message.id === 1 && message.result) {
          send(child, {
            jsonrpc: "2.0",
            method: "notifications/initialized",
          });
          send(child, {
            jsonrpc: "2.0",
            id: 2,
            method: "tools/list",
            params: {},
          });
          return;
        }

        if (message.id === 2) {
          const tools = message.result?.tools ?? [];
          const toolNames = tools.map((tool) => tool.name);
          const hasExpectedTool =
            !expectedToolName || toolNames.includes(expectedToolName);

          finish({
            ok: Boolean(message.result) && hasExpectedTool,
            elapsedMs: elapsedMs(startedAt),
            readyMs,
            toolNames,
            error: hasExpectedTool
              ? null
              : `tools/list missing ${expectedToolName}; saw ${toolNames.join(", ")}`,
          });
        }
      });
    });

    child.stderr.on("data", (chunk) => {
      stderrBuffer += chunk.toString("utf8");
      stderrBuffer = consumeLines(stderrBuffer, (line) => {
        if (line.blank) return;

        stderrLines.push(line.value);
        if (readyMs === null && line.value.includes("[mcp-agents] ready")) {
          readyMs = elapsedMs(startedAt);
        }
      });
    });

    send(child, {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        protocolVersion: "2024-11-05",
        capabilities: {},
        clientInfo: {
          name: "mcp-agents-startup-bench",
          version: "0.0.0",
        },
      },
    });

    function finish(result) {
      if (settled) return;

      settled = true;
      clearTimeout(timer);

      if (!result.ok) {
        result.elapsedMs ??= elapsedMs(startedAt);
        result.readyMs ??= readyMs;
        result.stderr = trim(stderrLines.join("\n"));
      }

      child.stdin.destroy();
      child.kill("SIGTERM");
      resolve(result);
    }
  });
}

function send(child, message) {
  child.stdin.write(`${JSON.stringify(message)}\n`);
}

function consumeLines(buffer, callback) {
  const lines = buffer.split("\n");
  const remainder = lines.pop() ?? "";

  for (const rawLine of lines) {
    const value = rawLine.trim();
    callback({ value, blank: value.length === 0 });
  }

  return remainder;
}

function elapsedMs(startedAt) {
  return Number(process.hrtime.bigint() - startedAt) / 1_000_000;
}

function printResult(label, results) {
  const successes = results.filter((result) => result.ok);
  const failures = results.filter((result) => !result.ok);
  const elapsedStats = stats(successes.map((result) => result.elapsedMs));
  const readyStats = stats(
    successes
      .map((result) => result.readyMs)
      .filter((value) => Number.isFinite(value)),
  );

  console.log(label);
  console.log(`  ok: ${successes.length}/${results.length}`);

  if (elapsedStats) {
    console.log(
      `  tools/list: avg=${formatMs(elapsedStats.avg)} p50=${formatMs(
        elapsedStats.p50,
      )} min=${formatMs(elapsedStats.min)} max=${formatMs(elapsedStats.max)}`,
    );
  }

  if (readyStats) {
    console.log(
      `  ready log:  avg=${formatMs(readyStats.avg)} p50=${formatMs(
        readyStats.p50,
      )} min=${formatMs(readyStats.min)} max=${formatMs(readyStats.max)}`,
    );
  }

  if (failures.length > 0) {
    const firstFailure = failures[0];
    console.log(`  first failure: ${firstFailure.error}`);
    if (firstFailure.stderr) {
      console.log(`  stderr: ${firstFailure.stderr}`);
    }
  }

  console.log("");
}

function stats(values) {
  if (values.length === 0) return null;

  const sorted = [...values].sort((a, b) => a - b);
  return {
    avg: sorted.reduce((total, value) => total + value, 0) / sorted.length,
    p50: sorted[Math.floor(sorted.length / 2)],
    min: sorted[0],
    max: sorted[sorted.length - 1],
  };
}

function formatMs(ms) {
  return `${(ms / 1000).toFixed(3)}s`;
}

function trim(value) {
  const trimmed = value.trim();
  return trimmed.length > 500 ? `${trimmed.slice(0, 500)}...` : trimmed;
}

main().catch((err) => {
  console.error(err.message);
  process.exit(1);
});
