/* eslint-disable no-console */

// Deprecated compatibility island for `codex mcp-server`. Keep its private
// contracts and lifecycle machinery here so removing --provider codex-legacy
// does not disturb the App Server adapter.

import { randomUUID } from "node:crypto";
import { execFileSync, spawn } from "node:child_process";
import {
  chmodSync,
  closeSync,
  copyFileSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readFileSync,
  readdirSync,
  statSync,
  renameSync,
  rmSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { isAbsolute, join } from "node:path";

const STARTUP_CWD = process.cwd();

const DEFAULT_CODEX_TIMEOUT_MS = 7_200_000;
const DEFAULT_CODEX_MODEL = "gpt-6.2-astra";
const DEFAULT_CODEX_MODEL_REASONING_EFFORT = "xhigh";
const DEFAULT_CODEX_SANDBOX_MODE = "workspace-write";
const DEFAULT_CODEX_APPROVAL_POLICY = "never";
const DEFAULT_CODEX_WORKSPACE_NETWORK_ACCESS = true;
// Correlated watchdogs for the codex pass-through. Only a codex/event carrying
// the matching MCP request id extends a call's idle window; stderr, pings, and
// unrelated calls cannot keep a wedged request alive. 0 disables the idle cap.
const DEFAULT_CODEX_IDLE_TIMEOUT_MS = 600_000;
const DEFAULT_CODEX_TERMINAL_GRACE_MS = 1_000;
const SUCCESS_TERMINAL_EVENTS = new Set(["task_complete", "turn_complete"]);
const ABORT_TERMINAL_EVENTS = new Set(["turn_aborted"]);
// How long codex gets to acknowledge a cancellation before the bridge stops
// waiting. A codex mid-turn is running sandboxed commands and streaming model
// output; it does NOT service a cancellation promptly, so this must be generous.
// Expiry no longer tears the bridge down (see onCancelGraceExpired) — it only
// decides when the wrapper stops holding the request id open.
const DEFAULT_CODEX_CANCEL_GRACE_MS = 30_000;
// Backstop for a queued generated frame that cannot flush because codex left a
// native frame unterminated (buffer mode latched, no boundary). Generous: it
// must never fire for legitimate slow-frame delivery, only a genuine wedge.
const DEFAULT_CODEX_FLUSH_STALL_MS = 60_000;
const DEFAULT_CODEX_PROGRESS_INTERVAL_MS = 1_000;
// Cadence of a background job's status CURSOR — deliberately far coarser than the
// progress-notification interval above. Notifications are a free UI stream, but every
// cursor bump wakes a codex-status long-poll, and each wake costs the polling agent a
// whole model turn over its accumulated transcript. At the 1s progress cadence an
// active job woke a poller ~1x/second, so `wait_ms` never engaged (a status call
// returns immediately whenever the cursor is behind the head) and a 40-minute build
// cost hundreds of poll turns. Terminal transitions bypass this entirely, so a longer
// interval never delays completion.
const DEFAULT_CODEX_STATUS_INTERVAL_MS = 30_000;
// Largest delay setTimeout can represent; Node clamps anything larger to 1ms.
const MAX_TIMER_DELAY_MS = 2_147_483_647;
const DEFAULT_CODEX_WAIT_INTERVAL_MS = 10_000;
const MAX_CODEX_STATUS_WAIT_MS = 60_000;
const MAX_CODEX_PROGRESS_CODEPOINTS = 200;
const MAX_CODEX_PAGE_CODEPOINTS = 32_768;
const MAX_CODEX_COMMENTARY_BYTES = 1024 * 1024;
const MAX_ACTIVE_CODEX_JOBS = 8;
const MAX_RETAINED_CODEX_JOBS = 32;
// `codex-reply` takes no cwd — a reply inherits the workspace of the thread it
// continues — so the only way codex-peek can name a reply's workspace is to
// remember where each thread was opened. Bounded FIFO; losing an old mapping
// costs a peek row its cwd, never correctness.
const MAX_REMEMBERED_CODEX_THREAD_WORKSPACES = 64;
const CODEX_JOB_RETENTION_MS = 60 * 60 * 1_000;
const MAX_BUFFER_BYTES = 10 * 1024 * 1024;

const MAX_SUPPRESSED_CODEX_RESPONSES = 32;
const CODEX_AUTH_FAILURE_CODE = "codex_auth_invalidated";
const CODEX_AUTH_FAILURE_ACTION = "reauthenticate_and_restart";
const CODEX_AUTH_FAILURE_MESSAGE =
  "Codex authentication is invalid for this MCP process. Stop this " +
  "mcp-agents bridge, run `codex logout` and `codex login` as the same OS " +
  "user, verify with `codex exec`, then restart or reconnect the bridge.";
// Isolated Codex homes older than this are assumed to belong to a bridge that
// died without cleanup and are swept at startup. Comfortably longer than the
// hard timeout so a live long-running session is never touched.
const STALE_CODEX_HOME_MAX_AGE_MS = 12 * 60 * 60 * 1_000;

const CODEX_PER_SESSION_MODEL_ARG = "model";
const CODEX_PER_SESSION_MODELS = [DEFAULT_CODEX_MODEL, "gpt-5.6-terra"];
const CODEX_PER_SESSION_MODEL_SET = new Set(CODEX_PER_SESSION_MODELS);
const CODEX_PER_SESSION_REASONING_EFFORT_ARG = "model_reasoning_effort";
const CODEX_PER_SESSION_REASONING_EFFORTS = ["medium", "high", "xhigh", "max"];
const CODEX_PER_SESSION_REASONING_EFFORT_SET = new Set(
  CODEX_PER_SESSION_REASONING_EFFORTS,
);
const CODEX_SANDBOXES = ["read-only", "workspace-write", "danger-full-access"];
const CODEX_SANDBOX_SET = new Set(CODEX_SANDBOXES);
const CODEX_ALLOW_SUBAGENTS_ARG = "allow_subagents";
const CODEX_TOOL_CONTRACTS = {
  codex: {
    allowed: [
      "prompt",
      "cwd",
      "sandbox",
      CODEX_PER_SESSION_MODEL_ARG,
      CODEX_PER_SESSION_REASONING_EFFORT_ARG,
      CODEX_ALLOW_SUBAGENTS_ARG,
      "goal",
    ],
    required: ["prompt", "cwd", "sandbox"],
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
// Tools answered entirely from wrapper state, addressing no job. codex-peek reads
// the in-flight table so a caller blocked on `codex` / `codex-reply` has SOME
// readable liveness: a blocking call is otherwise opaque until it returns, which
// is exactly the gap that let an operator mistake a working turn for a dead one.
const CODEX_LOCAL_TOOL_CONTRACTS = {
  "codex-peek": {
    allowed: ["cwd", "threadId", "requestId"],
    required: [],
  },
};
const CODEX_LOCAL_TOOL_NAMES = Object.keys(CODEX_LOCAL_TOOL_CONTRACTS);
const TERMINAL_CODEX_JOB_STATES = new Set(["completed", "failed", "canceled"]);

const SIGNAL_CODES = { SIGHUP: 1, SIGINT: 2, SIGKILL: 9, SIGTERM: 15 };

const testTunableMs = (name, fallback) => {
  const value = process.env[name];
  if (value == null) return fallback;
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? Math.round(parsed) : fallback;
};

function logErr(message) {
  process.stderr.write(`${message}\n`);
}

function idKey(id) {
  return `${typeof id}:${id}`;
}

const FRAME_HEADER_SCAN = 8192;

/**
 * Classify a bounded frame prefix and return its response id when present.
 * @param {Buffer} prefix
 * @returns {unknown}
 */
function peekResponseId(prefix) {
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
}

function resolveCodexHome() {
  return process.env.CODEX_HOME || join(process.env.HOME || tmpdir(), ".codex");
}

/**
 * Return TOML lines with comments and multiline-string bodies removed.
 * @param {string} source
 * @returns {string[] | null}
 */
function structuralTomlLines(source) {
  const lines = [];
  let multilineQuote;

  for (const rawLine of source.split(/\r?\n/)) {
    let code = "";
    let quote;
    let escaped = false;
    let touchedMultiline = Boolean(multilineQuote);

    for (let index = 0; index < rawLine.length; index += 1) {
      const char = rawLine[index];
      const triple = rawLine.slice(index, index + 3);

      if (multilineQuote) {
        if (triple === multilineQuote) {
          let backslashes = 0;
          for (let before = index - 1; rawLine[before] === "\\"; before -= 1) {
            backslashes += 1;
          }
          if (multilineQuote === "'''" || backslashes % 2 === 0) {
            let quoteRun = 3;
            while (rawLine[index + quoteRun] === multilineQuote[0]) {
              quoteRun += 1;
            }
            if (quoteRun > 5) return null;
            multilineQuote = undefined;
            index += quoteRun - 1;
          }
        }
        continue;
      }

      if (quote) {
        code += char;
        if (quote === '"' && escaped) {
          escaped = false;
        } else if (quote === '"' && char === "\\") {
          escaped = true;
        } else if (char === quote) {
          quote = undefined;
        }
        continue;
      }

      if (triple === "'''" || triple === '\"\"\"') {
        multilineQuote = triple;
        touchedMultiline = true;
        index += 2;
        continue;
      }
      if (char === "#") break;

      code += char;
      if (char === "'" || char === '"') quote = char;
    }

    if (quote) return null;
    lines.push(touchedMultiline ? "" : code.trim());
  }

  return multilineQuote ? null : lines;
}

/**
 * Detect the explicit Fast-mode pair without inheriting any other user config.
 * @param {string} source
 * @returns {boolean}
 */
function hasCodexFastModeOptIn(source) {
  const lines = structuralTomlLines(source);
  if (!lines) return false;

  let table = "";
  let serviceTierFast = false;
  let serviceTierSeen = false;
  let fastModeEnabled = false;
  let fastModeSeen = false;

  for (const line of lines) {
    if (!line) continue;

    const tableMatch = line.match(/^\[\s*([^\[\]]+?)\s*\]$/);
    if (tableMatch) {
      table = tableMatch[1];
      continue;
    }
    if (line.startsWith("[")) {
      table = undefined;
      continue;
    }

    if (table === "" && /^service_tier\s*=/.test(line)) {
      if (serviceTierSeen) return false;
      serviceTierSeen = true;
      serviceTierFast = /^service_tier\s*=\s*(["'])fast\1\s*$/.test(line);
    } else if (table === "features" && /^fast_mode\s*=/.test(line)) {
      if (fastModeSeen) return false;
      fastModeSeen = true;
      fastModeEnabled = /^fast_mode\s*=\s*true\s*$/.test(line);
    }
  }

  return serviceTierSeen && serviceTierFast && fastModeSeen && fastModeEnabled;
}

/**
 * Read the source Codex config and fail closed when Fast mode cannot be resolved.
 * @param {string} codexHome
 * @returns {boolean}
 */
function readCodexFastModeOptIn(codexHome) {
  const configPath = join(codexHome, "config.toml");
  try {
    return hasCodexFastModeOptIn(readFileSync(configPath, "utf8"));
  } catch (err) {
    if (err?.code !== "ENOENT") {
      const msg = err instanceof Error ? err.message : String(err);
      logErr(`[mcp-agents] failed to read source Codex Fast-mode config: ${msg}`);
    }
    return false;
  }
}

/**
 * Probe the installed codex binary's version once at bridge startup.
 * @returns {{ major: number, minor: number, patch: number } | undefined}
 */
function readCodexBinaryVersion() {
  try {
    const output = execFileSync("codex", ["--version"], {
      stdio: ["ignore", "pipe", "ignore"],
      timeout: 3_000,
      encoding: "utf8",
    });
    const match = /(\d+)\.(\d+)\.(\d+)/.exec(output);
    if (!match) return undefined;
    return {
      major: Number(match[1]),
      minor: Number(match[2]),
      patch: Number(match[3]),
    };
  } catch {
    return undefined;
  }
}

/**
 * Whether this codex accepts the scalar `agents.enabled` config key.
 *
 * Version-dependent on purpose (verified against codex-rs source history):
 *   - >= 0.145.0: `enabled` is an explicit Option<bool> — accepted, and the
 *     only gate that actually removes the collab tools there.
 *   - 0.102.0 – 0.144.x: `[agents]` flattens unreserved keys into a
 *     role-name -> role-table map, so a boolean `enabled` HARD-FAILS config
 *     parsing at startup and codex exits. Never emit it there; the
 *     `features.multi_agent` flag still gates the (experimental) collab tools.
 *   - < 0.102.0: unknown key/table, silently ignored either way.
 * An unknown version assumes modern codex: that fails toward subagents
 * staying OFF (the safety property) and any breakage is loud, never silent.
 * @param {{ major: number, minor: number } | undefined} version
 * @returns {boolean}
 */
function codexSupportsAgentsEnabledKey(version) {
  if (!version) return true;
  return version.major > 0 || version.minor >= 145;
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
 * @param {{ model: string, modelReasoningEffort: string, sandboxMode: string, approvalPolicy: string, workspaceNetworkAccess: boolean, fastModeEnabled: boolean, agentsEnabledKeySupported: boolean }} opts
 * @returns {string}
 */
function buildCodexBridgeConfig({
  model,
  modelReasoningEffort,
  sandboxMode,
  approvalPolicy,
  workspaceNetworkAccess,
  fastModeEnabled,
  agentsEnabledKeySupported,
}) {
  return [
    `model = ${toTomlString(model)}`,
    `model_reasoning_effort = ${toTomlString(modelReasoningEffort)}`,
    ...(fastModeEnabled ? ['service_tier = "fast"'] : []),
    `approval_policy = ${toTomlString(approvalPolicy)}`,
    `sandbox_mode = ${toTomlString(sandboxMode)}`,
    'web_search = "cached"',
    "check_for_update_on_startup = false",
    "allow_login_shell = false",
    "",
    "[sandbox_workspace_write]",
    `network_access = ${workspaceNetworkAccess}`,
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
    ...(fastModeEnabled ? ["fast_mode = true"] : []),
    "",
    // `features.multi_agent` alone is NOT a working off switch on Codex
    // >= 0.145.0 — the flag is stabilized (on by default) and sessions still
    // get the collab tools with it set to false. `agents.enabled = false` is
    // the gate that actually removes them; keep both so older Codex versions
    // stay disabled through the feature flag. Sessions opt back in per call
    // with `allow_subagents` (see transformCodexToolCall). The [agents] line
    // is version-gated: 0.102–0.144 hard-fail parsing a boolean there (see
    // codexSupportsAgentsEnabledKey), and the feature flag still gates the
    // collab tools on those versions.
    ...(agentsEnabledKeySupported ? ["[agents]", "enabled = false", ""] : []),
  ].join("\n");
}

/**
 * Prepare the private parent for isolated Codex homes inside the startup cwd.
 * Keeping it outside the OS temp directory allows Codex to create its PATH
 * helper aliases without weakening the isolation between bridge instances.
 * @returns {string}
 */
function prepareIsolatedCodexHomesRoot() {
  const projectTmp = join(STARTUP_CWD, "tmp");
  const root = join(projectTmp, "codex-homes");

  mkdirSync(projectTmp, { recursive: true });
  mkdirSync(root, { recursive: true, mode: 0o700 });

  const rootStat = lstatSync(root);
  if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) {
    throw new Error(`isolated Codex home root is not a directory: ${root}`);
  }
  chmodSync(root, 0o700);

  return root;
}

/**
 * Remove isolated Codex homes left behind by bridges that died without running
 * their cleanup (SIGKILL, a hard crash, a machine restart). Each one holds a
 * copy of auth.json, so they are both disk litter and credential sprawl. Only
 * directories older than the cutoff are touched, so a concurrently starting
 * bridge is never disturbed. Entirely best-effort.
 * @param {string} root
 * @param {number} [maxAgeMs]
 * @returns {number} count removed
 */
function sweepStaleCodexHomes(
  root,
  maxAgeMs = STALE_CODEX_HOME_MAX_AGE_MS,
) {
  const cutoff = Date.now() - maxAgeMs;
  let removed = 0;
  let names;
  try {
    names = readdirSync(root);
  } catch {
    return 0;
  }
  for (const name of names) {
    if (!name.startsWith("mcp-agents-codex-")) continue;
    const dir = join(root, name);
    try {
      if (statSync(dir).mtimeMs >= cutoff) continue;
      rmSync(dir, { recursive: true, force: true });
      removed += 1;
    } catch {}
  }
  return removed;
}

/**
 * Create an isolated Codex home that preserves auth but strips inherited MCP servers.
 * @param {{ homesRoot: string, sourceCodexHome: string, model: string, modelReasoningEffort: string, sandboxMode: string, approvalPolicy: string, workspaceNetworkAccess: boolean, fastModeEnabled: boolean, agentsEnabledKeySupported: boolean }} opts
 * @returns {string}
 */
function createIsolatedCodexHome({
  homesRoot,
  sourceCodexHome,
  model,
  modelReasoningEffort,
  sandboxMode,
  approvalPolicy,
  workspaceNetworkAccess,
  fastModeEnabled,
  agentsEnabledKeySupported,
}) {
  const codexHome = mkdtempSync(join(homesRoot, "mcp-agents-codex-"));
  // If auth copy or config write throws after the dir exists, remove the
  // partially-prepared dir before rethrowing so it is never leaked.
  try {
    chmodSync(codexHome, 0o700);
    const sourceAuthPath = join(sourceCodexHome, "auth.json");
    const targetAuthPath = join(codexHome, "auth.json");
    const configPath = join(codexHome, "config.toml");

    if (existsSync(sourceAuthPath)) {
      copyFileSync(sourceAuthPath, targetAuthPath);
      chmodSync(targetAuthPath, 0o600);
    }

    // Seed the model catalogue from the real CODEX_HOME. Without it every bridge
    // start is a cold Codex install that re-fetches ~280 KB before it is useful;
    // with several concurrent sessions that is a pointless, repeated dependency
    // on the network during startup. Best-effort: a missing or unreadable cache
    // just means codex fetches it as before.
    try {
      const sourceModelsCache = join(sourceCodexHome, "models_cache.json");
      if (existsSync(sourceModelsCache)) {
        const targetModelsCache = join(codexHome, "models_cache.json");
        copyFileSync(sourceModelsCache, targetModelsCache);
        chmodSync(targetModelsCache, 0o600);
      }
    } catch {}

    writeFileSync(
      configPath,
      buildCodexBridgeConfig({
        model,
        modelReasoningEffort,
        sandboxMode,
        approvalPolicy,
        workspaceNetworkAccess,
        fastModeEnabled,
        agentsEnabledKeySupported,
      }),
      { encoding: "utf8", mode: 0o600 },
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
 * No-ops when auth was never copied in (API-key mode), when the isolated token
 * is unchanged, or when the canonical file changed after this bridge copied
 * it. That startup-snapshot conflict guard prevents a stale bridge from
 * overwriting a newer manual login or another bridge's successful rotation
 * during ordinary cleanup.
 * @param {string} isolatedCodexHome
 * @param {Buffer | undefined} initialAuth
 */
function persistIsolatedCodexAuth(isolatedCodexHome, initialAuth) {
  try {
    if (!Buffer.isBuffer(initialAuth)) return;
    const realHome = resolveCodexHome();
    const canonical = join(realHome, "auth.json");
    const rotated = join(isolatedCodexHome, "auth.json");
    if (!existsSync(rotated) || !existsSync(canonical)) return;

    const rotatedBuf = readFileSync(rotated);
    if (rotatedBuf.equals(initialAuth)) return; // isolated auth never rotated

    const canonicalBuf = readFileSync(canonical);
    if (rotatedBuf.equals(canonicalBuf)) return; // already persisted elsewhere
    if (!canonicalBuf.equals(initialAuth)) {
      logErr(
        "[mcp-agents] skipped refreshed Codex auth.json write-back because " +
          "canonical auth changed while this bridge was running",
      );
      return;
    }

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

      // Narrow the non-atomic compare/rename window: another bridge or a manual
      // login may have replaced canonical auth while this temp file was being
      // prepared. POSIX has no portable rename-if-contents-still-match primitive.
      if (!readFileSync(canonical).equals(initialAuth)) {
        unlinkSync(tmp);
        logErr(
          "[mcp-agents] skipped refreshed Codex auth.json write-back because " +
            "canonical auth changed while this bridge was running",
        );
        return;
      }
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
 *   2. Strip the wrapper-only `allow_subagents` flag; `true` becomes the native
 *      per-call config overrides `agents.enabled = true` +
 *      `features.multi_agent = true` for the new session (the isolated home
 *      keeps both gates hard-off as the baseline).
 *   3. Inject the wrapper-only goal — codex's native `/goal` is a TUI-only slash
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
 * @param {{ serverGoal?: string, agentsEnabledKeySupported?: boolean }} [opts]
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

  if (
    toolName === "codex" &&
    Object.hasOwn(args, CODEX_PER_SESSION_REASONING_EFFORT_ARG)
  ) {
    const requestedSessionEffort = args[CODEX_PER_SESSION_REASONING_EFFORT_ARG];
    delete args[CODEX_PER_SESSION_REASONING_EFFORT_ARG];
    args.config = { model_reasoning_effort: requestedSessionEffort };
    effortLog = `applied per-session reasoning effort ${requestedSessionEffort}`;
    changed = true;
  }

  // ── Native subagent opt-in ────────────────────────────────────────────────
  // The wrapper-only `allow_subagents` flag is always stripped; only an
  // explicit `true` re-enables the session's multi-agent gates via per-call
  // native config overrides. The isolated home config keeps its hard-off
  // baseline (`[features] multi_agent = false` + `[agents] enabled = false`)
  // and writes no [mcp_servers], so an enabled session can spawn only
  // Codex-native in-process subagents — never MCP or other LLM-backed tools.
  // Session-scoped like `sandbox`: replies inherit it.
  let subagentsLog;
  if (toolName === "codex" && Object.hasOwn(args, CODEX_ALLOW_SUBAGENTS_ARG)) {
    const allowSubagents = args[CODEX_ALLOW_SUBAGENTS_ARG] === true;
    delete args[CODEX_ALLOW_SUBAGENTS_ARG];
    if (allowSubagents) {
      // Flip the right gate(s) for the running codex: `agents.enabled` is the
      // effective switch on >= 0.145.0 but a fatal config type error on
      // 0.102–0.144 (see codexSupportsAgentsEnabledKey), where the
      // `features.multi_agent` flag still gates the collab tools itself.
      args.config = {
        ...args.config,
        "features.multi_agent": true,
        ...(opts.agentsEnabledKeySupported === false
          ? {}
          : { "agents.enabled": true }),
      };
      subagentsLog =
        "enabled native Codex subagents for this session " +
        `(features.multi_agent=true${
          opts.agentsEnabledKeySupported === false ? "" : ", agents.enabled=true"
        })`;
    }
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
    logErr(`[mcp-agents] codex-legacy passthrough: ${effortLog}`);
  }
  if (subagentsLog) {
    logErr(`[mcp-agents] codex-legacy passthrough: ${subagentsLog}`);
  }
  if (goalLog) {
    logErr(`[mcp-agents] codex-legacy passthrough: ${goalLog}`);
  }
  return JSON.stringify(msg);
}

const CODEX_GOAL_PROPERTY_DESCRIPTION =
  "Optional standing objective. mcp-agents injects it as developer instructions " +
  "for a new session or a prompt reminder for a reply. An empty string suppresses " +
  "the server-wide goal for this call.";
const CODEX_PER_SESSION_MODEL_PROPERTY_DESCRIPTION =
  `Optional model for this new session: ${DEFAULT_CODEX_MODEL} for demanding work ` +
  "or gpt-5.6-terra for faster, easier jobs. Defaults to the server-configured " +
  `${DEFAULT_CODEX_MODEL}; replies inherit it.`;
const CODEX_PER_SESSION_REASONING_EFFORT_PROPERTY_DESCRIPTION =
  "Optional reasoning effort for this new session: medium for balanced speed, " +
  "high for complex work, xhigh for hard work, or max for quality-first work " +
  "requiring deeper exploration. Defaults to the server-configured xhigh; replies " +
  "inherit it.";
const CODEX_ALLOW_SUBAGENTS_PROPERTY_DESCRIPTION =
  "Optional: let this session spawn Codex's native in-process subagents " +
  "(default false). Subagents share the session's sandbox and approval policy " +
  "and get no MCP or external tool access. Set at session start; replies " +
  "inherit it.";

function codexToolPresentation(toolName) {
  if (toolName === "codex") {
    return {
      description:
        "Start a Codex session with an explicit workspace and sandbox, optional model " +
        "and reasoning effort, optional standing goal, and optional native subagents " +
        "(allow_subagents, default false; Codex-only, no external tool access).",
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
          [CODEX_PER_SESSION_MODEL_ARG]: {
            type: "string",
            enum: [...CODEX_PER_SESSION_MODELS],
            description: CODEX_PER_SESSION_MODEL_PROPERTY_DESCRIPTION,
          },
          [CODEX_PER_SESSION_REASONING_EFFORT_ARG]: {
            type: "string",
            enum: [...CODEX_PER_SESSION_REASONING_EFFORTS],
            description: CODEX_PER_SESSION_REASONING_EFFORT_PROPERTY_DESCRIPTION,
          },
          [CODEX_ALLOW_SUBAGENTS_ARG]: {
            type: "boolean",
            description: CODEX_ALLOW_SUBAGENTS_PROPERTY_DESCRIPTION,
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
        "Continue a Codex session by thread ID. Model, sandbox, and reasoning effort are inherited.",
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
        "Start an optional background Codex job (same arguments as codex, including " +
        "allow_subagents). This returns immediately; call codex-status with the " +
        "returned job ID and cursor until the job is terminal. PREFER THE BLOCKING " +
        "`codex` TOOL, including for long builds: it costs one call instead of one " +
        "model turn per status change, emits progress notifications whenever the " +
        "caller supplied a progress token (a job never can — its request carries " +
        "none), and is canceled by aborting the turn. Use this when the job must OUTLIVE the " +
        "caller (it keeps running after you stop waiting, or another agent must be " +
        "able to cancel it later by job ID), or when your client does not render " +
        "progress notifications and you need status as ordinary tool results. Note a " +
        "terminal status is evidence, not proof: `canceled` is also recorded when Codex " +
        "never acknowledged, so inspect the workspace before reusing it.",
    };
  }
  if (toolName === "codex-reply-start") {
    const presentation = codexToolPresentation("codex-reply");
    return {
      ...presentation,
      description:
        "Start an optional background reply on an existing Codex thread. This returns " +
        "immediately; call codex-status until the job is terminal. PREFER THE BLOCKING " +
        "`codex-reply` TOOL unless the job must OUTLIVE the caller (see codex-start).",
    };
  }
  if (toolName === "codex-status") {
    return {
      description:
        "Poll a background Codex job. At the current cursor this waits for new status " +
        "or a heartbeat, producing an ordinary transcript-visible tool result. Two " +
        "things end the wait: a cursor advance, paced server-side by " +
        "--codex_status_interval, and the wait_ms heartbeat. A call returns IMMEDIATELY " +
        "whenever the cursor is already behind the head, so wait_ms cannot slow a " +
        "poller that is behind — but it does bound how often a caught-up poller is " +
        "re-woken, so leave it at the default or raise it rather than lowering it.",
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
            description:
              "Maximum idle wait in milliseconds. Omitted, it tracks the server's status " +
              "interval, capped at the 60s maximum — so an interval above 60s still " +
              "heartbeats every 60s — and is 10000 when pacing is disabled. A ceiling " +
              "on idle waiting, not a floor on poll spacing: a call still returns at " +
              "once when the cursor is behind.",
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
  if (toolName === "codex-peek") {
    return {
      description:
        "List the Codex turns this server currently has in flight, blocking and " +
        "background alike. Read-only and immediate: it starts nothing, cancels " +
        "nothing, and never returns prompts or model output. Use it to tell a working " +
        "turn from a wedged one WITHOUT cancelling to find out — a blocking `codex` / " +
        "`codex-reply` call is otherwise opaque until it returns, and neither the " +
        "process table nor a quiet transcript can see it. Each row carries the threadId " +
        "once Codex reports one, the workspace, and lastActivitySeconds — small and " +
        "falling means healthy however long elapsedSeconds grows. A client call is " +
        "identified by requestId (stable for the life of the call); a background job by " +
        "its jobId. `state` is `running`, or `canceling` for a turn whose cancellation " +
        "has not been confirmed — that turn is still executing and still WRITING. Two " +
        "answers that mean less than they look like: an EMPTY list is not evidence a " +
        "turn finished (an abandoned turn keeps running with no in-flight request left " +
        "to report — see abandonedTurns), and a row may carry cwdUnknown when the " +
        "workspace could not be recovered, in which case a cwd filter still reports it " +
        "rather than hiding it.",
      inputSchema: {
        type: "object",
        properties: {
          cwd: {
            type: "string",
            description: "Only turns whose workspace equals this absolute path.",
          },
          threadId: { type: "string", description: "Only the turn on this Codex thread." },
          requestId: {
            type: "string",
            description: "Only the turn with this requestId, as returned by a previous peek.",
          },
        },
        required: [...CODEX_LOCAL_TOOL_CONTRACTS[toolName].required],
        additionalProperties: false,
      },
    };
  }
  return undefined;
}

function validateCodexToolCallMessage(msg) {
  if (!msg || typeof msg !== "object" || msg.method !== "tools/call") return undefined;
  const toolName = msg.params?.name;
  const contract = CODEX_TOOL_CONTRACTS[toolName] ?? CODEX_JOB_TOOL_CONTRACTS[toolName] ??
    CODEX_LOCAL_TOOL_CONTRACTS[toolName];
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
  if (Object.hasOwn(args, CODEX_PER_SESSION_MODEL_ARG)) {
    const model = args[CODEX_PER_SESSION_MODEL_ARG];
    if (typeof model !== "string" || !CODEX_PER_SESSION_MODEL_SET.has(model)) {
      issues.push({
        argument: CODEX_PER_SESSION_MODEL_ARG,
        problem: `must be one of: ${CODEX_PER_SESSION_MODELS.join(", ")}`,
      });
    }
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
  if (
    Object.hasOwn(args, CODEX_ALLOW_SUBAGENTS_ARG) &&
    typeof args[CODEX_ALLOW_SUBAGENTS_ARG] !== "boolean"
  ) {
    issues.push({
      argument: CODEX_ALLOW_SUBAGENTS_ARG,
      problem: "must be a boolean",
    });
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
  // Without this a codex-peek filter of the wrong type is silently coerced away, so
  // "is request X still alive?" is answered with every turn in the process — which
  // reads as yes.
  if (Object.hasOwn(args, "requestId")) {
    if (typeof args.requestId !== "string") {
      issues.push({ argument: "requestId", problem: "must be a string" });
    } else if (!args.requestId.trim()) {
      issues.push({ argument: "requestId", problem: "must not be blank" });
    }
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
  const availableAddedTools = [...CODEX_JOB_TOOL_NAMES, ...CODEX_LOCAL_TOOL_NAMES].filter(
    (toolName) => {
      if (toolName === "codex-start") return hasCodex;
      if (toolName === "codex-reply-start") return hasCodexReply;
      return hasCodex || hasCodexReply;
    },
  );
  for (const toolName of availableAddedTools) {
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
 * Run the deprecated native `codex mcp-server` bridge.
 *
 * @param {{
 *   model?: string,
 *   modelReasoningEffort?: string,
 *   sandboxMode?: string,
 *   approvalPolicy?: string,
 *   workspaceNetworkAccess?: boolean,
 *   idleTimeoutMs?: number,
 *   cancelGraceOverrideMs?: number,
 *   statusIntervalOverrideMs?: number,
 *   hardTimeoutMs?: number,
 *   goal?: string,
 *   registerFatalShutdown?: (handler: (reason: string, code?: number) => void) => void,
 * }} opts
 * @returns {void}
 */
export function runCodexLegacy({
  model,
  modelReasoningEffort,
  sandboxMode,
  approvalPolicy,
  workspaceNetworkAccess,
  idleTimeoutMs,
  cancelGraceOverrideMs,
  statusIntervalOverrideMs,
  hardTimeoutMs,
  goal,
  registerFatalShutdown,
}) {
  const resolvedModel = model || DEFAULT_CODEX_MODEL;
  const resolvedModelReasoningEffort =
    modelReasoningEffort || DEFAULT_CODEX_MODEL_REASONING_EFFORT;
  const resolvedSandboxMode = sandboxMode || DEFAULT_CODEX_SANDBOX_MODE;
  const resolvedApprovalPolicy = approvalPolicy || DEFAULT_CODEX_APPROVAL_POLICY;
  const resolvedWorkspaceNetworkAccess =
    workspaceNetworkAccess ?? DEFAULT_CODEX_WORKSPACE_NETWORK_ACCESS;
  const resolvedIdleTimeoutMs = idleTimeoutMs ?? DEFAULT_CODEX_IDLE_TIMEOUT_MS;
  const resolvedHardTimeoutMs = hardTimeoutMs ?? DEFAULT_CODEX_TIMEOUT_MS;
  const terminalGraceMs = testTunableMs(
    "MCP_AGENTS_CODEX_TERMINAL_GRACE_MS",
    DEFAULT_CODEX_TERMINAL_GRACE_MS,
  );
  // CLI flag wins over the env tunable, which wins over the default.
  const cancelGraceMs = cancelGraceOverrideMs ?? testTunableMs(
    "MCP_AGENTS_CODEX_CANCEL_GRACE_MS",
    DEFAULT_CODEX_CANCEL_GRACE_MS,
  );
  // How long codex may keep working after the client's stdin closed before the
  // detached group is reaped outright.
  const clientGoneGraceMs = testTunableMs(
    "MCP_AGENTS_CODEX_CLIENT_GONE_GRACE_MS",
    Math.max(cancelGraceMs * 2, DEFAULT_CODEX_CANCEL_GRACE_MS),
  );
  let clientGoneTimer;
  const flushStallLimitMs = testTunableMs(
    "MCP_AGENTS_CODEX_FLUSH_STALL_MS",
    DEFAULT_CODEX_FLUSH_STALL_MS,
  );
  const progressIntervalMs = testTunableMs(
    "MCP_AGENTS_CODEX_PROGRESS_INTERVAL_MS",
    DEFAULT_CODEX_PROGRESS_INTERVAL_MS,
  );
  // CLI flag wins over the env tunable, which wins over the default. Clamped to the
  // largest delay setTimeout represents: Node silently fires anything above it after
  // 1ms, which would invert this knob into a cursor bump per event.
  const statusIntervalMs = Math.min(
    MAX_TIMER_DELAY_MS,
    statusIntervalOverrideMs ?? testTunableMs(
      "MCP_AGENTS_CODEX_STATUS_INTERVAL_MS",
      DEFAULT_CODEX_STATUS_INTERVAL_MS,
    ),
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
  const sourceCodexHome = resolveCodexHome();
  const fastModeEnabled = readCodexFastModeOptIn(sourceCodexHome);
  const codexVersion = readCodexBinaryVersion();
  const agentsEnabledKeySupported = codexSupportsAgentsEnabledKey(codexVersion);
  let codexAuthInvalidated = false;
  let isolatedCodexHomesRoot;

  try {
    isolatedCodexHomesRoot = prepareIsolatedCodexHomesRoot();
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    logErr(`[mcp-agents] failed to prepare isolated codex home root: ${msg}`);
    process.exitCode = 1;
    return;
  }

  const sweptHomes =
    sweepStaleCodexHomes(isolatedCodexHomesRoot) +
    sweepStaleCodexHomes(tmpdir());
  if (sweptHomes > 0) {
    logErr(
      `[mcp-agents] swept ${sweptHomes} stale isolated codex home(s) left by ` +
        `bridges that exited without cleanup`,
    );
  }
  let isolatedCodexHome;

  try {
    isolatedCodexHome = createIsolatedCodexHome({
      homesRoot: isolatedCodexHomesRoot,
      sourceCodexHome,
      model: resolvedModel,
      modelReasoningEffort: resolvedModelReasoningEffort,
      sandboxMode: resolvedSandboxMode,
      approvalPolicy: resolvedApprovalPolicy,
      workspaceNetworkAccess: resolvedWorkspaceNetworkAccess,
      fastModeEnabled,
      agentsEnabledKeySupported,
    });
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    logErr(`[mcp-agents] failed to prepare isolated codex home: ${msg}`);
    process.exitCode = 1;
    return;
  }

  const args = ["mcp-server"];
  let initialIsolatedAuth;
  try {
    const isolatedAuthPath = join(isolatedCodexHome, "auth.json");
    if (existsSync(isolatedAuthPath)) initialIsolatedAuth = readFileSync(isolatedAuthPath);
  } catch {}
  let cleanedUp = false;
  const cleanupIsolatedCodexHome = () => {
    if (cleanedUp || !isolatedCodexHome) return;
    cleanedUp = true;

    // Write any rotated OAuth token back to the real CODEX_HOME before the temp
    // home is removed. A credential Codex classified as unauthorized is never
    // eligible: copying it back could clobber the manual login this error asks
    // the operator to perform.
    if (codexAuthInvalidated) {
      logErr(
        "[mcp-agents] skipped Codex auth.json write-back after authentication invalidation",
      );
    } else {
      persistIsolatedCodexAuth(isolatedCodexHome, initialIsolatedAuth);
    }
    try {
      rmSync(isolatedCodexHome, { recursive: true, force: true });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      logErr(`[mcp-agents] failed to clean isolated codex home: ${msg}`);
    }
  };

  logErr(
    `[mcp-agents] codex-legacy passthrough: codex ${args.join(" ")} ` +
      `(model=${resolvedModel}, reasoning_effort=${resolvedModelReasoningEffort}, ` +
      `sandbox_mode=${resolvedSandboxMode}, approval_policy=${resolvedApprovalPolicy}, ` +
      `workspace_network_access=${resolvedWorkspaceNetworkAccess}, ` +
      `fast_mode_opt_in=${fastModeEnabled}, ` +
      `codex_version=${
        codexVersion
          ? `${codexVersion.major}.${codexVersion.minor}.${codexVersion.patch}`
          : "unknown"
      }, ` +
      `subagent_gate=${
        agentsEnabledKeySupported ? "agents_enabled" : "feature_flag_only"
      }, ` +
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
  // Requests the wrapper stopped waiting for while codex was still working on
  // them. The turn keeps running inside codex (it does not honour MCP
  // cancellation promptly), so it can still write to the workspace long after
  // the client gave up — the "zombie writer". Tracked purely for operator
  // visibility: entries are logged on abandonment and again when the real
  // response finally lands, so a stale tree can be explained rather than
  // guessed at. Bounded by MAX_SUPPRESSED_CODEX_RESPONSES via the same ids.
  const abandonedTurns = new Map(); // request key -> { threadId, jobId, at }
  let rewriteBuf = Buffer.alloc(0); // buffer-mode accumulator; holds ≤1 trailing partial after a flush
  let rewriteSkipUntilNewline = false; // forwarding raw to the next newline (oversized frame or mode-boundary align)
  let rewriteSkipReleaseId; // idKey to release when the skipped frame's newline lands (oversized response only)
  let rewriteDropUntilNewline = false; // discarding an oversized suppressed response through its delimiter
  let rewriteDropReleaseId;
  let oversizedToolsListLogged = false; // log the first rewrite-cap drop only
  const generatedFrames = [];
  const locallyHandledResponseIds = new Set();
  const privateJobRequestIds = new Set();
  // Foreground turns normally remain byte-for-byte passthrough. Their ids keep
  // the existing bounded frame path active only until the terminal response so
  // a typed Codex authentication failure can be replaced before it reaches the
  // client. Every unrelated frame is still forwarded with its original bytes.
  const foregroundTurnRequestIds = new Set();
  let flushGeneratedFrames = () => {};

  // ── In-flight request tracking ──────────────────────────────────────────
  // Every request owns its own lifecycle and progress timers.
  // JSON-RPC numeric `1` and string `"1"` remain distinct keys.
  const inFlight = new Map();
  const serverRequestParents = new Map();
  const jobs = new Map();
  const jobsByNativeRequest = new Map();
  const threadWorkspaces = new Map(); // threadId -> { cwd, sandbox } from the opening `codex` call
  // LRU, not FIFO. Map iteration order is insertion order, so evicting the first key
  // without refreshing on use throws out the long-lived thread you keep replying to
  // before idle newer ones — exactly backwards for the case this map exists to serve.
  const lookupThreadWorkspace = (threadId) => {
    if (!threadId) return undefined;
    const found = threadWorkspaces.get(threadId);
    if (!found) return undefined;
    threadWorkspaces.delete(threadId);
    threadWorkspaces.set(threadId, found);
    return found;
  };
  const rememberThreadWorkspace = (threadId, cwd, sandbox) => {
    if (!threadId || !cwd) return;
    if (threadWorkspaces.has(threadId)) {
      lookupThreadWorkspace(threadId);
      return;
    }
    threadWorkspaces.set(threadId, { cwd, sandbox });
    while (threadWorkspaces.size > MAX_REMEMBERED_CODEX_THREAD_WORKSPACES) {
      threadWorkspaces.delete(threadWorkspaces.keys().next().value);
    }
  };
  const privateRequestPrefix = process.env.MCP_AGENTS_TEST_PRIVATE_PREFIX ??
    `mcp-agents/job/${randomUUID()}/`;
  let privateRequestSequence = 0;
  let authFailureLogged = false;
  const authFailureToolResult = (threadId) => ({
    content: [{ type: "text", text: CODEX_AUTH_FAILURE_MESSAGE }],
    structuredContent: {
      code: CODEX_AUTH_FAILURE_CODE,
      action: CODEX_AUTH_FAILURE_ACTION,
      content: CODEX_AUTH_FAILURE_MESSAGE,
      ...(threadId ? { threadId } : {}),
    },
    isError: true,
  });
  const hasAuthInvalidationMarker = (value) => {
    if (typeof value !== "string") return false;
    const normalized = value.toLowerCase();
    return normalized.includes("refresh_token_invalidated") ||
      normalized.includes("refresh token was revoked") ||
      normalized.includes("refresh token has been revoked") ||
      normalized.includes("authentication token has been invalidated");
  };
  const isTypedCodexAuthFailure = (msg) =>
    msg?.method === "codex/event" &&
    msg.params?.msg?.type === "error" &&
    msg.params.msg.codex_error_info === "unauthorized";
  const isKnownCodexTurnKey = (key) =>
    key !== undefined &&
    (foregroundTurnRequestIds.has(key) || jobsByNativeRequest.has(key) ||
      suppressedResponseIds.has(key));
  const isCodexAuthFailureResult = (msg) => {
    if (msg?.result?.isError !== true) return false;
    const texts = [
      msg.result.structuredContent?.content,
      ...(Array.isArray(msg.result.content)
        ? msg.result.content
          .filter((part) => part?.type === "text")
          .map((part) => part.text)
        : []),
    ];
    return texts.some(hasAuthInvalidationMarker);
  };
  const markCodexAuthInvalidated = (entry) => {
    codexAuthInvalidated = true;
    if (entry) entry.codexAuthInvalidated = true;
    if (authFailureLogged) return;
    authFailureLogged = true;
    logErr(
      `[mcp-agents] ${CODEX_AUTH_FAILURE_CODE}: Codex rejected this process's ` +
        "cached authentication; reauthenticate, then restart or reconnect the bridge",
    );
  };
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
      "abortEscalationTimer",
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
    // A cancellation-driven drop can empty the queue without a flush. Reset the
    // delivery backstop here too, so the next stuck frame gets its OWN full grace
    // window rather than inheriting this now-stale timer's remaining time.
    if (generatedFrames.length === 0) clearFlushStallGuard();
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
    foregroundTurnRequestIds.delete(key);
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
      // A per-request idle timeout aborts ONLY this request — it must NOT tear
      // down the whole bridge, which would close the stdio transport and make
      // the client permanently unregister every codex tool.
      abortRequestNoTeardown(
        entry,
        `request idle timeout (${Math.round(resolvedIdleTimeoutMs / 1000)}s)`,
      );
    }, resolvedIdleTimeoutMs);
  };
  const armEntryHard = (entry) => {
    if (!(resolvedHardTimeoutMs > 0)) return;
    entry.hardTimer = setTimeout(() => {
      if (finalizing || inFlight.get(idKey(entry.id)) !== entry) return;
      const label =
        `request hard timeout (${Math.round(resolvedHardTimeoutMs / 1000)}s)`;
      if (entry.state === "open") {
        // Bound the single request, keep the transport (defer/escalate if needed).
        abortRequestNoTeardown(entry, label);
        return;
      }
      // The immutable hard deadline must ALWAYS bound the request. Unlike
      // idleTimer, beginTerminalGrace deliberately does NOT clear hardTimer, so
      // this can fire while the entry sits in terminal_grace (its terminalTimer
      // not yet run, or its synthesizeTerminalResult deferred on a mid-frame
      // stall). Try the safe, no-teardown settlement FIRST — synthesizeTerminalResult
      // settles an internalJob unconditionally and a normal entry when framing is
      // clean; only a genuinely wedged mid-frame entry stays in_flight afterward.
      // Fall back to a bounded teardown ONLY for that residue, rather than tearing
      // the whole bridge down for a request that could have been answered safely.
      if (entry.state === "terminal_grace") {
        synthesizeTerminalResult(entry, entry.terminalOutcome);
        if (finalizing || inFlight.get(idKey(entry.id)) !== entry) return;
      }
      finalize({
        reason: `${label} while state=${entry.state}`,
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
    // Workspace identity for codex-peek. `codex`/`codex-start` carry cwd + sandbox
    // as required arguments; `codex-reply`/`codex-reply-start` carry neither, so a
    // reply's workspace is recovered from the thread it continues and flagged as
    // inferred rather than asserted.
    // Harvest ONLY from a call that is itself a turn. codex-peek takes cwd/threadId/
    // requestId as FILTERS, and recording those as the request's own identity would
    // make a peek entry claim to be a turn on that thread in that workspace.
    const isTurnCall = msg.method === "tools/call" &&
      Boolean(CODEX_TOOL_CONTRACTS[msg.params?.name] ?? CODEX_JOB_TOOL_CONTRACTS[msg.params?.name]);
    const callArgs = isTurnCall ? msg.params?.arguments : undefined;
    const suppliedCwd = typeof callArgs?.cwd === "string" ? callArgs.cwd : undefined;
    const suppliedSandbox = typeof callArgs?.sandbox === "string" ? callArgs.sandbox : undefined;
    const repliedThreadId = typeof callArgs?.threadId === "string" ? callArgs.threadId : undefined;
    const inheritedWorkspace = suppliedCwd ? undefined : lookupThreadWorkspace(repliedThreadId);
    const entry = {
      id: msg.id,
      method: msg.method,
      toolName: msg.method === "tools/call" ? msg.params?.name : undefined,
      progressToken,
      threadId: repliedThreadId,
      cwd: suppliedCwd ?? inheritedWorkspace?.cwd,
      sandbox: suppliedSandbox ?? inheritedWorkspace?.sandbox,
      cwdInferred: !suppliedCwd && Boolean(inheritedWorkspace),
      state: "open",
      lastAgentMessage: undefined,
      terminalEventType: undefined,
      terminalEventObservedAt: undefined,
      terminalOutcome: undefined,
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
      timeoutPending: undefined,
      nativeCancelSent: false,
      suppressedNativeResponseSeen: false,
      confirmedCancelGraceEscalated: false,
      confirmedCancelPending: false,
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
  // Session-level delivery backstop. Suppressing a request id (per-call timeout,
  // terminal-grace fallback, or cancel) latches buffer mode for the WHOLE stream;
  // if codex then leaves a native frame unterminated and neither completes it nor
  // exits, canInjectGeneratedFrame() stays false forever and EVERY queued
  // generated frame (local tool responses, other requests' aborts) is blocked —
  // a whole-bridge hang no per-request timer covers once its entry has settled.
  // Armed when a frame cannot flush; on fire, escalate to a bounded teardown ONLY
  // if still wedged on FRAMING (not mere client backpressure, which resolves on
  // drain/EPIPE); otherwise disarm or re-arm while frames remain queued.
  let flushStallTimer;
  const clearFlushStallGuard = () => {
    if (!flushStallTimer) return;
    clearTimeout(flushStallTimer);
    flushStallTimer = undefined;
  };
  const armFlushStallGuard = () => {
    if (flushStallTimer || finalizing || flushStallLimitMs <= 0) return;
    flushStallTimer = setTimeout(() => {
      flushStallTimer = undefined;
      if (finalizing || generatedFrames.length === 0) return;
      if (!stdoutPaused && !canInjectGeneratedFrame()) {
        finalize({
          reason:
            `generated frames undeliverable for ${flushStallLimitMs}ms ` +
            `(codex left a native frame unterminated)`,
          emit: true,
          exitCode: 1,
        });
        return;
      }
      armFlushStallGuard(); // still queued but backpressured/flushable — wait more
    }, flushStallLimitMs);
    flushStallTimer.unref?.();
  };
  const queueGeneratedFrame = (frame, { requestKey, kind } = {}) => {
    const queued = {
      buffer: Buffer.from(`${JSON.stringify(frame)}\n`, "utf8"),
      requestKey,
      kind,
    };
    if (kind === "progress") {
      // Backpressure or a partial native frame can delay injection. Retain only
      // the latest progress update for this request so silence cannot grow an
      // unbounded side queue. Coalesce IN PLACE (replace the matching frame's
      // buffer) rather than remove-then-push: a remove-then-push would transiently
      // empty the queue and reset the flush-stall delivery backstop on every
      // heartbeat, defeating it for a genuinely wedged request that keeps
      // emitting progress. In-place replacement preserves the backstop's original
      // arm time (how long the queue has actually been stuck).
      const existing = generatedFrames.findIndex(
        (f) => f.kind === "progress" && f.requestKey === requestKey,
      );
      if (existing !== -1) {
        generatedFrames[existing] = queued;
        queueMicrotask(() => flushGeneratedFrames());
        return;
      }
    }
    generatedFrames.push(queued);
    if (!canInjectGeneratedFrame()) armFlushStallGuard();
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
    ...(job.errorCode ? { code: job.errorCode } : {}),
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
    if (elapsed >= statusIntervalMs) {
      setJobStatusNow(job, formatted.slice("Codex: ".length), { state: "running" });
      return;
    }
    job.pendingStatusMessage = formatted.slice("Codex: ".length);
    if (!job.statusTimer) {
      job.statusTimer = setTimeout(
        () => flushPendingJobStatus(job),
        Math.max(1, statusIntervalMs - elapsed),
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
  const transitionJobTerminal = (
    job,
    state,
    message,
    { resultText, threadId, code } = {},
  ) => {
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
    if (typeof code === "string" && code) job.errorCode = code;
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
    if (entry.terminalOutcome === "aborted") {
      transitionJobTerminal(
        job,
        "failed",
        `${entry.terminalEventType ?? "turn_aborted"}: Codex aborted the turn before completion`,
        { threadId: nativeThreadId },
      );
      return;
    }
    if (entry.codexAuthInvalidated || isCodexAuthFailureResult(msg)) {
      markCodexAuthInvalidated(entry);
      transitionJobTerminal(job, "failed", CODEX_AUTH_FAILURE_MESSAGE, {
        threadId: nativeThreadId,
        code: CODEX_AUTH_FAILURE_CODE,
      });
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
        {
          jobId: job.jobId,
          state: job.state,
          ...(job.errorCode ? { code: job.errorCode } : {}),
          resultAvailable: false,
        },
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
      errorCode: undefined,
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
        { serverGoal: resolvedGoal, agentsEnabledKeySupported },
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
  // Read-only view of the in-flight table for codex-peek. Only real Codex turns are
  // listed — `codex` and `codex-reply` — whether the client issued one directly or a
  // job dispatched it privately. The peek call is a different tool, so a peek can
  // never report itself.
  const normalizeWorkspace = (value) =>
    typeof value === "string" && value.length > 1 && value.endsWith("/")
      ? value.replace(/\/+$/, "")
      : value;
  const peekRows = (filter) => {
    const now = Date.now();
    const rows = [];
    for (const entry of inFlight.values()) {
      if (entry.method !== "tools/call") continue;
      if (!entry.toolName || !CODEX_TOOL_CONTRACTS[entry.toolName]) continue;
      // "canceled" is NOT gone. The bridge cancels best-effort and waits out
      // --codex_cancel_grace, during which Codex is still executing under
      // workspace-write. Dropping those rows would answer "nothing in flight" to the
      // one caller who most needs a yes: someone deciding whether it is safe to send a
      // second writer into that tree.
      const live = entry.state === "open";
      const canceling = entry.state === "canceled";
      if (!live && !canceling) continue;
      // A job's native request id belongs to the wrapper's private namespace; handing
      // it out makes it addressable from outside the job state machine. Jobs are
      // addressed by jobId.
      const requestId = entry.internalJob ? undefined : idKey(entry.id);
      if (filter.requestId && filter.requestId !== requestId) continue;
      if (filter.threadId && filter.threadId !== entry.threadId) continue;
      const cwd = normalizeWorkspace(entry.cwd);
      // A cwd filter must never HIDE a turn whose workspace is merely unknown — that
      // converts "I cannot tell" into "nothing is running there", the exact inversion
      // this tool exists to prevent. Unknown-workspace turns are always reported.
      if (filter.cwd && cwd !== undefined && filter.cwd !== cwd) continue;
      rows.push({
        ...(requestId ? { requestId } : {}),
        tool: entry.toolName,
        state: canceling ? "canceling" : "running",
        ...(entry.threadId ? { threadId: entry.threadId } : {}),
        ...(cwd ? { cwd, cwdInferred: Boolean(entry.cwdInferred) } : { cwdUnknown: true }),
        ...(entry.sandbox ? { sandbox: entry.sandbox } : {}),
        ...(entry.internalJob && entry.jobId ? { jobId: entry.jobId } : {}),
        elapsedSeconds: Math.max(0, Math.floor((now - entry.startedAt) / 1_000)),
        lastActivitySeconds: Math.max(
          0,
          Math.floor((now - (entry.lastActivityAt ?? entry.startedAt)) / 1_000),
        ),
      });
    }
    rows.sort((a, b) =>
      b.elapsedSeconds - a.elapsedSeconds ||
      String(a.requestId ?? a.jobId ?? "").localeCompare(String(b.requestId ?? b.jobId ?? ""))
    );
    return rows;
  };
  const describePeekRow = (turn) =>
    `${turn.tool} ${turn.requestId ?? turn.jobId ?? "(unidentified)"}: ` +
    `${turn.elapsedSeconds}s elapsed, last activity ${turn.lastActivitySeconds}s ago` +
    (turn.state === "canceling" ? ", CANCELING (not confirmed stopped)" : "") +
    (turn.threadId ? `, thread ${turn.threadId}` : ", thread not yet reported") +
    (turn.cwd
      ? `, cwd ${turn.cwd}${turn.cwdInferred ? " (inherited)" : ""}`
      : ", workspace unknown");
  const peekResult = (args) => {
    const filter = {
      cwd: typeof args.cwd === "string" ? normalizeWorkspace(args.cwd) : undefined,
      threadId: typeof args.threadId === "string" ? args.threadId : undefined,
      requestId: typeof args.requestId === "string" ? args.requestId : undefined,
    };
    const filtered = Boolean(filter.cwd || filter.threadId || filter.requestId);
    const turns = peekRows(filter);
    const canceling = turns.filter((turn) => turn.state === "canceling").length;
    // An empty peek is the one answer a caller must not over-read: a turn the wrapper
    // stopped waiting for keeps running inside Codex with no in-flight request left.
    let text = turns.length === 0
      ? `No ${filtered ? "matching " : ""}Codex turn is in flight. This is not evidence ` +
        "one finished — an abandoned turn keeps running with nothing left to report."
      : turns.map(describePeekRow).join("\n");
    if (filtered && turns.length > 1) {
      text += `\n\n${turns.length} turns match; the filter does not identify a single turn.`;
    }
    if (canceling > 0) {
      text += `\n\n${canceling} turn(s) cancelled but NOT confirmed stopped — still writing.`;
    }
    if (abandonedTurns.size > 0) {
      text += `\n\n${abandonedTurns.size} abandoned turn(s) may still be writing` +
        `${filtered ? " (process-wide; not narrowed by your filter)" : ""}.`;
    }
    return localToolResult(text, {
      turns,
      count: turns.length,
      canceling,
      ambiguous: filtered && turns.length > 1,
      // Process-wide by nature — abandoned turns retain no workspace — so it is named
      // for what it is. A machine consumer reading a bare `abandonedTurns` under a cwd
      // filter would attribute all of them to that workspace.
      abandonedTurnsProcessWide: abandonedTurns.size,
    });
  };
  const handleJobToolCall = (msg, entry) => {
    const toolName = msg.params?.name;
    const args = msg.params?.arguments ?? {};
    if (toolName === "codex-start" || toolName === "codex-reply-start") {
      dispatchJob(msg, entry, toolName === "codex-start" ? "codex" : "codex-reply");
      return true;
    }
    if (toolName === "codex-peek") {
      queueLocalToolResponse(entry, peekResult(args));
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
      // Pacing the cursor alone does not bound wakeups: a caught-up poller is still
      // re-woken by the heartbeat every wait_ms. Default that wait to the status
      // cadence so a heartbeat never out-paces the cursor it reports on, capped at the
      // protocol maximum, and fall back to the plain default when pacing is disabled.
      const defaultWaitMs = statusIntervalMs > 0
        ? Math.min(MAX_CODEX_STATUS_WAIT_MS, statusIntervalMs)
        : DEFAULT_CODEX_WAIT_INTERVAL_MS;
      const waitMs = args.wait_ms ?? defaultWaitMs;
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
      // Multi-agent V2 (codex >= 0.145.0) reports spawn/lifecycle work as
      // sub_agent_activity; the older collab_agent_* names remain for
      // earlier versions.
      case "sub_agent_activity":
        return "subagent activity";
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
  const terminalAbortErrorFrame = (entry) => ({
    jsonrpc: "2.0",
    id: entry.id,
    error: {
      code: -32001,
      message:
        `mcp-agents: Codex reported ${entry.terminalEventType ?? "turn_aborted"}; ` +
        `the turn did not complete. Any writes it made are in the tree — verify ` +
        `the workspace before continuing.` +
        (entry.threadId ? ` Codex thread: ${entry.threadId}.` : ""),
    },
  });
  const terminalFrameForOutcome = (entry, outcome) =>
    outcome === "aborted" ? terminalAbortErrorFrame(entry) : terminalResultFrame(entry);
  const synthesizeTerminalResult = (entry, outcome) => {
    if (
      finalizing || inFlight.get(idKey(entry.id)) !== entry ||
      entry.state !== "terminal_grace" || entry.terminalOutcome !== outcome ||
      (outcome !== "completed" && outcome !== "aborted")
    ) return;
    if (entry.internalJob) {
      const key = idKey(entry.id);
      const job = jobs.get(entry.jobId);
      privateJobRequestIds.delete(key);
      suppressedResponseIds.add(key);
      if (job?.state === "canceling") {
        transitionJobTerminal(job, "canceled", "canceled", { threadId: entry.threadId });
      } else if (job && outcome === "aborted") {
        transitionJobTerminal(
          job,
          "failed",
          `${entry.terminalEventType ?? "turn_aborted"}: Codex aborted the turn before completion`,
          { threadId: entry.threadId },
        );
      } else if (job) {
        transitionJobTerminal(job, "completed", "completed", {
          resultText: entry.lastAgentMessage ?? "",
          threadId: entry.threadId,
        });
      }
      settleInFlight(entry.id);
      finalizeOnSuppressionCap();
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
      terminalFrameForOutcome(entry, outcome),
      { kind: "terminal_result" },
    );
    logErr(
      `[mcp-agents] settled ${outcome} codex request from terminal event for request ` +
        `${JSON.stringify(entry.id)} (thread_id=${entry.threadId ?? "unknown"})`,
    );
    finalizeOnSuppressionCap();
  };
  // Answer a single request that hit its idle/hard timeout with a JSON-RPC
  // error, suppress codex's eventual (late) native response, and settle it —
  // WITHOUT tearing down the bridge. A per-request timeout used to call
  // finalize(), which process.exit()s; that closed the stdio transport and made
  // Claude Code route the server to `failed` and strip every mcp__codex__* tool
  // for the rest of the session (stdio servers are not auto-reconnected). This
  // mirrors synthesizeTerminalResult's frame-boundary + suppression discipline
  // so a late native response is dropped in the forward path rather than
  // double-delivered.
  const timeoutErrorFrame = (entry, label) => ({
    jsonrpc: "2.0",
    id: entry.id,
    error: {
      code: -32001,
      message:
        `mcp-agents: codex pass-through ${label}; the request was aborted but ` +
        `the bridge stayed connected. Any applied edits may exist — verify the ` +
        `tree, then retry the call.` +
        (entry.threadId ? ` Codex thread: ${entry.threadId}.` : ""),
    },
  });
  // Tell codex to stop working on a request whose deadline we've given up on, so
  // a slow/hung call is not left running unbounded once we stop waiting for it
  // (the old finalize path SIGKILLed the whole group; a per-request abort must
  // cancel just this one). Best-effort and idempotent; also prods a codex that
  // stalled mid-frame to emit a boundary or exit, which lets a deferred abort
  // resolve. Written to codex's stdin — it never touches the client stdout frame.
  const requestNativeCancel = (entry, reason) => {
    if (!entry || entry.nativeCancelSent) return;
    entry.nativeCancelSent = true;
    try {
      child.stdin.write(`${JSON.stringify({
        jsonrpc: "2.0",
        method: "notifications/cancelled",
        params: { requestId: entry.id, reason },
      })}\n`);
    } catch {}
  };
  const overSuppressionCap = () =>
    suppressedResponseIds.size >= MAX_SUPPRESSED_CODEX_RESPONSES;
  const finalizeOnSuppressionCap = () => {
    if (!overSuppressionCap()) return;
    // Re-check inside the tick: a late native response may have relieved the cap
    // between scheduling and firing, in which case a full teardown is not needed.
    setImmediate(() => {
      if (finalizing || !overSuppressionCap()) return;
      finalize({
        reason: "late-response suppression limit reached",
        emit: true,
        exitCode: 1,
      });
    });
  };
  const abortRequestNoTeardown = (entry, label) => {
    if (
      finalizing || inFlight.get(idKey(entry.id)) !== entry ||
      entry.state !== "open"
    ) return;
    const key = idKey(entry.id);
    requestNativeCancel(entry, `mcp-agents: ${label}`);
    if (entry.internalJob) {
      // Background job: the client already holds the jobId, so there is no
      // client frame to emit — fail the job and suppress codex's late native
      // response (mirrors synthesizeTerminalResult's internalJob branch).
      const job = jobs.get(entry.jobId);
      privateJobRequestIds.delete(key);
      suppressedResponseIds.add(key);
      // A job abandoned by the idle or hard deadline is exactly as unconfirmed as a
      // blocking call abandoned the same way — Codex may still be writing. Recording it
      // here is what lets codex-peek's abandonedTurnsProcessWide see it at all; without
      // this the job path reported nothing in flight and nothing abandoned, which is the
      // inversion this tool exists to prevent.
      noteAbandonedTurn(entry, label);
      if (job && !isTerminalJob(job)) transitionJobTerminal(job, "failed", label);
      settleInFlight(entry.id);
      entry.timeoutPending = undefined;
      finalizeOnSuppressionCap();
      return;
    }
    if (!canInjectGeneratedFrame()) {
      // No safe frame boundary (codex stalled mid-frame, or stdout is
      // backpressured): we CANNOT splice a synthetic frame into a partial native
      // one, so defer. flushReadyTerminalResults retries on the next codex
      // stdout activity / drain — which the cancellation above helps produce.
      // But a codex wedged mid-frame that also ignores the cancellation would
      // never produce that activity, so a one-shot escalation guarantees the
      // request cannot hang forever: after the cancel grace, fall back to a
      // bounded teardown (the only safe resolution for a mid-frame wedge; the
      // client can then reconnect to a clean bridge).
      entry.timeoutPending = label;
      if (!entry.abortEscalationTimer) {
        const escalate = () => {
          if (finalizing || inFlight.get(idKey(entry.id)) !== entry) return;
          // Retry first: the boundary may simply not have arrived yet. Only a
          // stream still wedged after a second window justifies dropping the
          // bridge (and with it every other request and background job).
          if (canInjectGeneratedFrame()) {
            entry.abortEscalationTimer = undefined;
            abortRequestNoTeardown(entry, label);
            return;
          }
          if (!entry.abortEscalated) {
            entry.abortEscalated = true;
            entry.abortEscalationTimer = setTimeout(escalate, cancelGraceMs);
            return;
          }
          finalize({
            reason: `request ${JSON.stringify(entry.id)} ${label} could not be ` +
              `delivered at a frame boundary within ${cancelGraceMs * 2}ms`,
            emit: true,
            exitCode: 1,
          });
        };
        entry.abortEscalationTimer = setTimeout(escalate, cancelGraceMs);
      }
      return;
    }
    entry.timeoutPending = undefined;
    clearTimer(entry, "abortEscalationTimer");
    suppressedResponseIds.add(key);
    settleInFlight(entry.id);
    queueGeneratedFrame(timeoutErrorFrame(entry, label), { kind: "terminal_result" });
    noteAbandonedTurn(entry, label);
    finalizeOnSuppressionCap();
  };
  const flushReadyTerminalResults = () => {
    if (!canInjectGeneratedFrame()) return;
    for (const entry of [...inFlight.values()]) {
      if (entry.fallbackReady) {
        synthesizeTerminalResult(entry, entry.terminalOutcome);
      } else if (entry.timeoutPending) {
        abortRequestNoTeardown(entry, entry.timeoutPending);
      }
    }
  };
  const beginTerminalGrace = (entry, message, outcome) => {
    if (entry.state !== "open") return;
    if (entry.internalJob) finishJobCommentary(jobs.get(entry.jobId));
    entry.state = "terminal_grace";
    entry.terminalOutcome = outcome;
    stopEntryProgress(entry);
    entry.lastAgentMessage = typeof message === "string" ? message : "";
    clearTimer(entry, "idleTimer");
    entry.terminalTimer = setTimeout(
      () => synthesizeTerminalResult(entry, outcome),
      terminalGraceMs,
    );
  };
  // Record — and shout about — a request the wrapper has stopped waiting for
  // while codex may still be executing it. This is the single most expensive
  // failure mode in practice: the client believes the work is dead, codex keeps
  // editing the workspace, and a second agent is dispatched onto the same files.
  const noteAbandonedTurn = (entry, label) => {
    const key = idKey(entry.id);
    abandonedTurns.set(key, {
      threadId: entry.threadId,
      jobId: entry.jobId,
      at: Date.now(),
    });
    logErr(
      `[mcp-agents] WARNING codex turn abandoned while possibly still running: ` +
        `request ${JSON.stringify(entry.id)} (${label}); ` +
        `thread_id=${entry.threadId ?? "unknown"} ` +
        `job_id=${entry.jobId ?? "none"} ` +
        `sandbox_mode=${resolvedSandboxMode}. The bridge stays connected, but ` +
        `codex was NOT confirmed stopped — treat the workspace as having a live ` +
        `writer until this bridge exits` +
        (entry.jobId ? `, or stop it with codex-cancel jobId=${entry.jobId}` : "") +
        `.`,
    );
  };
  // The counterpart: codex finally answered a request nobody is waiting for. It
  // proves the turn ran to completion after the client gave up, which is the
  // evidence needed to explain unexpected edits in the tree.
  const noteAbandonedTurnSettled = (key) => {
    const info = abandonedTurns.get(key);
    if (!info) return;
    abandonedTurns.delete(key);
    logErr(
      `[mcp-agents] abandoned codex turn finished after ` +
        `${Math.round((Date.now() - info.at) / 1_000)}s and its result was ` +
        `discarded (thread_id=${info.threadId ?? "unknown"} ` +
        `job_id=${info.jobId ?? "none"}); any writes it made are in the tree`,
    );
  };
  const releaseSuppressedResponse = (key) => {
    const entry = inFlight.get(key);
    if (entry?.state === "canceled") entry.suppressedNativeResponseSeen = true;
    suppressedResponseIds.delete(key);
    noteAbandonedTurnSettled(key);
  };
  const confirmedCancellationMessage = (entry) =>
    entry.terminalOutcome === "completed"
      ? `completed after cancellation was requested ` +
        `(${entry.terminalEventType}; result discarded)`
      : `canceled (confirmed by ${entry.terminalEventType})`;
  const settleConfirmedCancellation = (entry) => {
    if (
      finalizing || inFlight.get(idKey(entry.id)) !== entry ||
      entry.state !== "canceled" || entry.confirmedCancelPending
    ) return;
    clearTimer(entry, "cancelTimer");
    const key = idKey(entry.id);
    if (entry.internalJob) {
      const job = jobs.get(entry.jobId);
      privateJobRequestIds.delete(key);
      if (!entry.suppressedNativeResponseSeen) suppressedResponseIds.add(key);
      if (job && !isTerminalJob(job)) {
        transitionJobTerminal(
          job,
          "canceled",
          confirmedCancellationMessage(entry),
          { threadId: entry.threadId },
        );
      }
      settleInFlight(entry.id);
      finalizeOnSuppressionCap();
      return;
    }
    if (entry.suppressedNativeResponseSeen) {
      settleInFlight(entry.id);
      return;
    }
    if (canArmResponseSuppression()) {
      suppressedResponseIds.add(key);
      settleInFlight(entry.id);
      finalizeOnSuppressionCap();
      return;
    }
    // The terminal event proves the turn stopped, but a response suppression
    // latch still cannot start in the middle of a native frame. Give that frame
    // one bounded window to finish; only a continuing framing wedge can escalate.
    if (!entry.confirmedCancelGraceEscalated) {
      entry.confirmedCancelGraceEscalated = true;
      entry.confirmedCancelPending = true;
      entry.cancelTimer = setTimeout(
        () => {
          entry.confirmedCancelPending = false;
          settleConfirmedCancellation(entry);
        },
        cancelGraceMs,
      );
      return;
    }
    finalize({
      reason:
        `request ${JSON.stringify(entry.id)} cancellation was confirmed by ` +
        `${entry.terminalEventType}, but codex left a frame unterminated`,
      emit: true,
      exitCode: 1,
    });
  };
  // A cancellation grace expiry used to tear the WHOLE bridge down, which killed
  // every other in-flight request and every background job in this process, and
  // destroyed the isolated CODEX_HOME (so no thread could ever be resumed). A
  // codex mid-turn simply does not service MCP cancellation quickly, so this
  // fired routinely and was the dominant cause of "the MCP keeps dropping".
  // The client has already cancelled — it will never read a response for this id
  // — so the correct resolution is to stop tracking the id and swallow codex's
  // late response. Teardown is reserved for the one case that genuinely cannot
  // be resolved per-request: a stream wedged mid-frame with no safe boundary.
  const onCancelGraceExpired = (entry) => {
    if (finalizing || inFlight.get(idKey(entry.id)) !== entry) return;
    const key = idKey(entry.id);
    if (entry.suppressedNativeResponseSeen) {
      settleInFlight(entry.id);
      return;
    }
    if (entry.internalJob) {
      // Background job: the client polls by jobId and never sees this native id,
      // so there is no client frame to place and no boundary to wait for. Drive
      // the job terminal, otherwise it sits in "canceling" forever and every
      // codex-status long-poll against it hangs.
      const job = jobs.get(entry.jobId);
      privateJobRequestIds.delete(key);
      suppressedResponseIds.add(key);
      if (job && !isTerminalJob(job)) {
        transitionJobTerminal(
          job,
          "canceled",
          `canceled (codex did not acknowledge within ${cancelGraceMs}ms)`,
        );
      }
      settleInFlight(entry.id);
      noteAbandonedTurn(
        entry,
        `cancellation unacknowledged within ${cancelGraceMs}ms`,
      );
      finalizeOnSuppressionCap();
      return;
    }
    if (canArmResponseSuppression()) {
      suppressedResponseIds.add(key);
      settleInFlight(entry.id);
      noteAbandonedTurn(
        entry,
        `cancellation unacknowledged within ${cancelGraceMs}ms`,
      );
      finalizeOnSuppressionCap();
      return;
    }
    // No frame boundary yet: splicing suppression state in now could corrupt a
    // partial native frame. Give the stream one more window to reach a boundary
    // before falling back to the bounded teardown.
    if (!entry.cancelGraceEscalated) {
      entry.cancelGraceEscalated = true;
      entry.cancelTimer = setTimeout(
        () => onCancelGraceExpired(entry),
        cancelGraceMs,
      );
      return;
    }
    finalize({
      reason:
        `request ${JSON.stringify(entry.id)} cancellation did not settle ` +
        `within ${cancelGraceMs * 2}ms and codex left a frame unterminated`,
      emit: true,
      exitCode: 1,
    });
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
    const terminalEvidenceRecorded =
      entry.state === "terminal_grace" &&
      (entry.terminalOutcome === "completed" || entry.terminalOutcome === "aborted");
    entry.state = "canceled";
    stopEntryProgress(entry);
    clearTimer(entry, "idleTimer");
    clearTimer(entry, "hardTimer");
    clearTimer(entry, "terminalTimer");
    clearTimer(entry, "abortEscalationTimer");
    if (canArmResponseSuppression()) suppressedResponseIds.add(idKey(id));
    // Ask codex to stop as well. Without this the turn runs to completion even
    // though nothing will ever read its result.
    requestNativeCancel(entry, "mcp-agents: client cancelled the request");
    entry.cancelGraceEscalated = false;
    entry.confirmedCancelGraceEscalated = false;
    entry.confirmedCancelPending = false;
    entry.suppressedNativeResponseSeen = false;
    if (terminalEvidenceRecorded) {
      settleConfirmedCancellation(entry);
      return false;
    }
    entry.cancelTimer = setTimeout(
      () => onCancelGraceExpired(entry),
      cancelGraceMs,
    );
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
      const key = idKey(msg.id);
      const entry = inFlight.get(key);
      if (
        entry && !entry.internalJob && entry.state === "terminal_grace" &&
        entry.terminalOutcome === "aborted"
      ) {
        logErr(
          `[mcp-agents] WARNING native codex response settled aborted request ` +
            `${JSON.stringify(entry.id)}; forwarding unchanged because foreground ` +
            `Codex calls are byte-for-byte passthrough ` +
            `(thread_id=${entry.threadId ?? "unknown"})`,
        );
      }
      if (entry?.internalJob) handlePrivateResponse(entry, msg);
      const privateJob = jobsByNativeRequest.get(key);
      // Forwarding leads observation. A cancellation that began mid-frame may
      // arm suppression only after this response was already forwarded in the
      // same chunk; release that newly-created latch before settling the entry.
      if (suppressedResponseIds.has(key)) releaseSuppressedResponse(key);
      settleInFlight(msg.id);
      if (privateJob) jobsByNativeRequest.delete(key);
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
    const event = msg.params?.msg;
    const eventType = event?.type;
    if (entry && isTypedCodexAuthFailure(msg)) {
      markCodexAuthInvalidated(entry);
    }
    const terminalOutcome = SUCCESS_TERMINAL_EVENTS.has(eventType)
      ? "completed"
      : ABORT_TERMINAL_EVENTS.has(eventType) ? "aborted" : undefined;
    if (
      !entry ||
      (entry.state !== "open" && !(entry.state === "canceled" && terminalOutcome))
    ) return;
    const job = entry.internalJob ? jobs.get(entry.jobId) : undefined;
    const threadId = msg.params?._meta?.threadId;
    if (typeof threadId === "string" && threadId) {
      entry.threadId = threadId;
      // Learned here rather than at dispatch: the opening `codex` call supplies the
      // cwd but not the thread, and Codex names the thread only once it starts.
      if (!entry.cwdInferred) rememberThreadWorkspace(threadId, entry.cwd, entry.sandbox);
    }
    if (job && typeof threadId === "string" && threadId) job.threadId = threadId;
    entry.lastActivityAt = Date.now();
    if (terminalOutcome) {
      entry.terminalEventType = eventType;
      entry.terminalEventObservedAt = entry.lastActivityAt;
      entry.terminalOutcome = terminalOutcome;
    }
    if (entry.state === "canceled") {
      if (job) finishJobCommentary(job);
      settleConfirmedCancellation(entry);
      return;
    }
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
    if (terminalOutcome) {
      if (job) finishJobCommentary(job);
      beginTerminalGrace(entry, event?.last_agent_message, terminalOutcome);
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
        "[mcp-agents] codex-legacy passthrough: stdout frame exceeded observation cap; " +
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
    if (clientGoneTimer) {
      clearTimeout(clientGoneTimer);
      clientGoneTimer = undefined;
    }
    logErr(`[mcp-agents] codex-legacy passthrough finalize: ${reason}`);
    if (abandonedTurns.size > 0) {
      logErr(
        `[mcp-agents] ${abandonedTurns.size} abandoned codex turn(s) were still ` +
          `unaccounted for at teardown: ` +
          [...abandonedTurns.values()]
            .map((info) => info.threadId ?? "unknown")
            .join(", "),
      );
    }

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

    const shouldEmitTeardownResponses =
      emit && (hasEmittableInFlight() || generatedFrames.length > 0);
    const shouldInspectBufferedOutput =
      shouldEmitTeardownResponses || rewriteBuf.length > 0 ||
      stdoutObsBuf.length > 0 || rewriteSkipUntilNewline ||
      rewriteDropUntilNewline;

    if (shouldInspectBufferedOutput) {
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
        if (shouldEmitTeardownResponses && !lastForwardedByteWasNewline) {
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
          const correlatedId = m?.params?._meta?.requestId;
          const correlatedKey = correlatedId == null ? undefined : idKey(correlatedId);
          const correlatedEntry = correlatedKey == null
            ? undefined
            : inFlight.get(correlatedKey);
          const privateEntry = m && typeof m === "object" && "id" in m
            ? inFlight.get(idKey(m.id))
            : undefined;
          if (
            isKnownCodexTurnKey(correlatedKey) && isTypedCodexAuthFailure(m)
          ) {
            markCodexAuthInvalidated(correlatedEntry);
            outStr = null;
          } else if (
            privateEntry?.internalJob && ("result" in m || "error" in m)
          ) {
            handlePrivateResponse(privateEntry, m);
            settleInFlight(m.id);
            jobsByNativeRequest.delete(idKey(m.id));
            privateJobRequestIds.delete(idKey(m.id));
            releaseSuppressedResponse(idKey(m.id));
            outStr = null;
          } else if (
            m && typeof m === "object" && "id" in m &&
            ("result" in m || "error" in m) &&
            foregroundTurnRequestIds.has(idKey(m.id))
          ) {
            if (privateEntry?.codexAuthInvalidated || isCodexAuthFailureResult(m)) {
              markCodexAuthInvalidated(privateEntry);
              m.result = authFailureToolResult(
                m.result?.structuredContent?.threadId ?? privateEntry?.threadId,
              );
              delete m.error;
              outStr = JSON.stringify(m);
            }
          } else if (
            m && typeof m === "object" && "id" in m &&
            ("result" in m || "error" in m) &&
            suppressedResponseIds.has(idKey(m.id))
          ) {
            releaseSuppressedResponse(idKey(m.id));
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
        if (outStr !== null && shouldEmitTeardownResponses) {
          try { process.stdout.write(`${outStr}\n`); } catch {}
          observeOutgoingLine(frameStr); // clear its id -> no synthetic error for it
          lastForwardedByteWasNewline = true;
        } else if (
          shouldEmitTeardownResponses && !lastForwardedByteWasNewline
        ) {
          try { process.stdout.write("\n"); } catch {}
          lastForwardedByteWasNewline = true;
        }
      } else if (stdoutObsBuf.length > 0) {
        if (shouldEmitTeardownResponses) {
          observeOutgoingLine(stdoutObsBuf.toString("utf8"));
        }
        stdoutObsBuf = Buffer.alloc(0);
        if (shouldEmitTeardownResponses) {
          try { process.stdout.write("\n"); } catch {}
          lastForwardedByteWasNewline = true;
        }
      } else if (
        shouldEmitTeardownResponses && !lastForwardedByteWasNewline
      ) {
        try { process.stdout.write("\n"); } catch {}
        lastForwardedByteWasNewline = true;
      }
    }

    if (shouldEmitTeardownResponses) {
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
        const outcome = entry.terminalOutcome;
        const outcomeLabel = outcome === "completed" || outcome === "aborted"
          ? outcome
          : "terminal";
        const job = entry.internalJob ? jobs.get(entry.jobId) : undefined;
        if (job?.state === "canceling") {
          transitionJobTerminal(job, "canceled", "canceled", { threadId: entry.threadId });
        } else if (job && outcome === "aborted") {
          transitionJobTerminal(
            job,
            "failed",
            `${entry.terminalEventType ?? "turn_aborted"}: Codex aborted the turn before completion`,
            { threadId: entry.threadId },
          );
        } else if (!entry.internalJob && (outcome === "completed" || outcome === "aborted")) {
          try {
            process.stdout.write(
              `${JSON.stringify(terminalFrameForOutcome(entry, outcome))}\n`,
            );
          } catch {}
        }
        settleInFlight(entry.id);
        logErr(
          `[mcp-agents] recovered ${outcomeLabel} codex request ` +
            `${JSON.stringify(entry.id)} during teardown ` +
            `(thread_id=${entry.threadId ?? "unknown"})`,
        );
      }

      for (const job of jobs.values()) {
        if (!isTerminalJob(job)) {
          const nativeEntry = inFlight.get(job.nativeRequestKey);
          if (nativeEntry?.codexAuthInvalidated) {
            transitionJobTerminal(job, "failed", CODEX_AUTH_FAILURE_MESSAGE, {
              threadId: nativeEntry.threadId,
              code: CODEX_AUTH_FAILURE_CODE,
            });
          } else {
            transitionJobTerminal(job, "failed", `bridge stopped: ${reason}`);
          }
        }
      }

      for (const entry of inFlight.values()) {
        if (
          entry.internalJob || entry.state === "canceled" ||
          entry.state === "local_response"
        ) continue;
        const frame = entry.codexAuthInvalidated
          ? {
            jsonrpc: "2.0",
            id: entry.id,
            result: authFailureToolResult(entry.threadId),
          }
          : {
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
    abandonedTurns.clear();
    privateJobRequestIds.clear();
    foregroundTurnRequestIds.clear();
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
  registerFatalShutdown?.((reason, code) =>
    finalize({ reason: `fatal: ${reason}`, emit: true, exitCode: code ?? 1 }));

  child.stderr.on("data", (chunk) => {
    logErr(`[codex-legacy] ${chunk.toString().trimEnd()}`);
  });

  const logRewriteDropOnce = () => {
    if (!oversizedToolsListLogged) {
      logErr(
        "[mcp-agents] codex-legacy passthrough: tools/list-window frame exceeded rewrite cap; " +
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
    // Queue drained (or emptied by dropped/non-live frames): the delivery
    // backstop is no longer needed until the next stuck frame arms it.
    if (generatedFrames.length === 0) clearFlushStallGuard();
  };

  // Once no rewrite/filter id is outstanding (and not mid-skip), a trailing partial in
  // rewriteBuf has no response expected, so it must not stay
  // withheld in buffer mode — raw mode forwards partials as they arrive, and
  // withholding it would byte-lose it if codex dies before its newline. Forward it
  // raw and drop back to the fast path. Called from BOTH paths that can clear the
  // latch: the end of flushRewriteBuf (a response completed) and noteInbound's
  // cancel branch (a tools/list was canceled on stdin, which never runs the flush).
  const returnToRawIfLatchClear = () => {
    if (
      !finalizing && pendingToolsListIds.size === 0 &&
      suppressedResponseIds.size === 0 && privateJobRequestIds.size === 0 &&
      foregroundTurnRequestIds.size === 0 &&
      !rewriteSkipUntilNewline &&
      !rewriteDropUntilNewline && rewriteBuf.length > 0
    ) {
      forwardChunk(rewriteBuf);
      rewriteBuf = Buffer.alloc(0);
    }
  };

  // Flush every COMPLETE frame from rewriteBuf, rewriting only the matched
  // tools/list/auth response and forwarding everything else byte-for-byte. NEVER
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
        releaseSuppressedResponse(rewriteDropReleaseId);
        // The response finally landed, oversized or not — the turn is no longer
        // abandoned. Without this an over-limit result left its record forever and
        // abandonedTurnsProcessWide only ever climbed.
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
        foregroundTurnRequestIds.delete(rewriteSkipReleaseId);
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
          releaseSuppressedResponse(key);
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
          releaseSuppressedResponse(key);
          continue;
        }
        if (key !== undefined && pendingToolsListIds.has(key)) {
          pendingToolsListIds.delete(key);
        }
        if (key !== undefined && foregroundTurnRequestIds.has(key)) {
          foregroundTurnRequestIds.delete(key);
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
        const correlatedKey = correlatedId == null ? undefined : idKey(correlatedId);
        const correlatedEntry = correlatedKey == null
          ? undefined
          : inFlight.get(correlatedKey);
        const privateCorrelatedJob = correlatedId == null
          ? undefined
          : jobsByNativeRequest.get(correlatedKey);
        if (isKnownCodexTurnKey(correlatedKey) && isTypedCodexAuthFailure(msg)) {
          markCodexAuthInvalidated(correlatedEntry);
          // Codex duplicates this error in the terminal tool result. Suppress
          // the event so the client receives exactly one wrapper-owned failure.
          outBuf = null;
        } else if (privateCorrelatedJob && typeof msg.method === "string") {
          outBuf = null;
        } else if (
          msg && typeof msg === "object" && "id" in msg &&
          ("result" in msg || "error" in msg)
        ) {
          const key = idKey(msg.id);
          const entry = inFlight.get(key);
          if (foregroundTurnRequestIds.has(key)) {
            foregroundTurnRequestIds.delete(key);
            if (entry?.codexAuthInvalidated || isCodexAuthFailureResult(msg)) {
              markCodexAuthInvalidated(entry);
              msg.result = authFailureToolResult(
                msg.result?.structuredContent?.threadId ?? entry?.threadId,
              );
              delete msg.error;
              outBuf = Buffer.from(`${JSON.stringify(msg)}\n`, "utf8");
            }
          }
          if (jobsByNativeRequest.has(key)) {
            privateJobRequestIds.delete(key);
            releaseSuppressedResponse(key);
            // A job's late native response settles its abandonment just as a plain
            // call's does. Without this the record survived for the life of the
            // process, so codex-peek's abandonedTurnsProcessWide only ever climbed and
            // its "may still be writing" warning stopped meaning anything.
            outBuf = null;
          } else if (suppressedResponseIds.has(key)) {
            releaseSuppressedResponse(key);
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
          jobsByNativeRequest.delete(key);
          // Keep suppression until the oversized response reaches its newline;
          // rewriteDropReleaseId then releases it through the common helper.
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
          key !== undefined &&
          (pendingToolsListIds.has(key) || foregroundTurnRequestIds.has(key))
            ? key
            : undefined;
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
      privateJobRequestIds.size > 0 || foregroundTurnRequestIds.size > 0 ||
      rewriteBuf.length > 0 ||
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
      logErr(`[mcp-agents] codex-legacy passthrough: stdout observation error (ignored): ${msg}`);
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
      const toolName = msg.method === "tools/call" ? msg.params?.name : undefined;
      const startsCodexTurn = Boolean(
        CODEX_TOOL_CONTRACTS[toolName] ||
        toolName === "codex-start" || toolName === "codex-reply-start",
      );
      if (codexAuthInvalidated && startsCodexTurn) {
        queueLocalToolResponse(
          inFlight.get(idKey(msg.id)),
          authFailureToolResult(),
        );
        return false;
      }
      if (msg.method === "tools/call" && handleJobToolCall(msg, inFlight.get(idKey(msg.id)))) {
        return false;
      }
      if (msg.method === "tools/call" && CODEX_TOOL_CONTRACTS[toolName]) {
        const key = idKey(msg.id);
        if (
          pendingToolsListIds.size === 0 && suppressedResponseIds.size === 0 &&
          privateJobRequestIds.size === 0 && foregroundTurnRequestIds.size === 0 &&
          rewriteBuf.length === 0 && !rewriteSkipUntilNewline &&
          !rewriteDropUntilNewline && !lastForwardedByteWasNewline
        ) {
          rewriteSkipUntilNewline = true;
          rewriteSkipReleaseId = undefined;
        }
        foregroundTurnRequestIds.add(key);
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
        child.stdin.write(`${transformCodexToolCall(line, {
          serverGoal: resolvedGoal,
          agentsEnabledKeySupported,
        })}\n`);
      }
    }
  });
  process.stdin.on("error", () => {});
  process.stdin.on("end", () => {
    if (stdinBuf.length > 0) {
      const line = stdinBuf.toString("utf8");
      if (noteInbound(line) && !finalizing) {
        child.stdin.write(transformCodexToolCall(line, {
          serverGoal: resolvedGoal,
          agentsEnabledKeySupported,
        }));
      }
    }
    // The client is gone for good. A background job (codex-start) is polled by
    // jobId through THIS process, so once the client disconnects nothing can
    // ever read its result — but codex keeps executing it, writing to the
    // workspace, invisible to the client's own task registry (a harness
    // "stop task" cannot reach it; only codex-cancel could, and the jobId died
    // with the connection). Cancel every non-terminal job and every open
    // request before closing codex's stdin so the turn is asked to stop rather
    // than left running as an unattended writer.
    if (!finalizing) {
      for (const job of jobs.values()) {
        if (!isTerminalJob(job)) {
          logErr(
            `[mcp-agents] client disconnected; cancelling background job ` +
              `${job.jobId} (state=${job.state}, ` +
              `thread_id=${job.threadId ?? "unknown"})`,
          );
          requestJobCancellation(job, "client disconnected");
        }
      }
      for (const entry of [...inFlight.values()]) {
        if (entry.state === "open") {
          requestNativeCancel(entry, "mcp-agents: client disconnected");
        }
      }
      // Hard backstop. Closing codex's stdin normally makes it exit, but a codex
      // mid-turn may ignore both the EOF and the cancellations above and keep
      // writing. Nothing can consume its output any more, so bound the wind-down
      // and then reap the whole detached group — an unattended writer must never
      // outlive the client that dispatched it.
      if (!clientGoneTimer) {
        clientGoneTimer = setTimeout(() => {
          if (finalizing) return;
          finalize({
            reason:
              `client disconnected and codex did not wind down within ` +
              `${clientGoneGraceMs}ms`,
            emit: false,
            exitCode: 0,
          });
        }, clientGoneGraceMs);
      }
    }
    child.stdin.end();
  });

  child.on("error", (err) => {
    logErr(
      `[mcp-agents] failed to start codex-legacy transport: ${err.message}`,
    );
    // codex failed to start. The fix that matters is that we EXIT (instead of
    // leaving a childless wrapper alive on the client's open stdin, which used
    // to hang). `emit` synthesizes an error only if a request was already
    // tracked; spawn 'error' usually fires before any stdin is read, so the
    // client typically just sees the server exit — the conventional
    // "server failed to start".
    finalize({
      reason: `codex-legacy spawn error: ${err.message}`,
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
    if (signal) logErr(`[mcp-agents] codex mcp-server killed by ${signal}`);
    else if (code != null && code !== 0) {
      logErr(`[mcp-agents] codex mcp-server exited with code ${code}`);
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
