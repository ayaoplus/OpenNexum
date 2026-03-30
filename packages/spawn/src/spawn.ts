import { access, mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import path from "node:path";

import type { SessionRecord, SpawnOptions } from "./types.js";

// ─── Constants ───────────────────────────────────────────────────────────────

const ACTIVE_TASKS_RELATIVE_PATH = path.join("nexum", "active-tasks.json");

// ─── Types ───────────────────────────────────────────────────────────────────

type AgentCliName = "claude" | "codex";

type ExecaResult = {
  stdout: string;
  stderr: string;
  exitCode: number;
};

type ExecaRunner = (
  command: string,
  args: string[],
  options: { reject: false; cwd?: string }
) => Promise<ExecaResult>;

const testingGlobals = globalThis as typeof globalThis & {
  __nexumSpawnExeca?: ExecaRunner;
};

let cachedExecaRunner: ExecaRunner | undefined;

const loadExecaModule = new Function(
  "return import('execa')"
) as () => Promise<{ execa: ExecaRunner }>;

// ─── Helpers ─────────────────────────────────────────────────────────────────

interface ActiveTask {
  id: string;
  acp_session_key?: string;
  updated_at?: string;
  [key: string]: unknown;
}

interface ActiveTasksFile {
  tasks: ActiveTask[];
}

/**
 * Resolve CLI name from agentId prefix.
 * codex-* → codex, claude-* → claude, default → codex
 */
export function resolveCliName(agentId: string, explicitCli?: string): AgentCliName {
  if (explicitCli === "claude" || explicitCli === "codex") {
    return explicitCli;
  }
  if (agentId.startsWith("claude-")) return "claude";
  return "codex";
}

// ─── Core: spawn ACP session via acpx ────────────────────────────────────────

/**
 * Spawn an ACP coding agent session directly via acpx.
 *
 * Command:
 *   acpx --approve-all --ttl 0 <cliName> -s <sessionName> exec -f <promptFile>
 *
 * Where:
 *   - cliName = "codex" | "claude" (resolved from agentId)
 *   - sessionName = agentId (e.g. "codex-gen-01", "claude-eval-NEXUM-011")
 *   - promptFile = path to the generated prompt markdown
 *   - --ttl 0 prevents idle timeout killing the session
 *   - --approve-all auto-approves all permission requests
 *   - exec = one-shot mode (no persistent session)
 */
export async function spawnAcpSession(options: SpawnOptions): Promise<SessionRecord> {
  const startedAt = new Date().toISOString();
  const cliName = resolveCliName(
    options.agentId,
    (options as SpawnOptions & { agentCli?: string }).agentCli
  );

  // Step 1: Ensure named session exists
  //   acpx <cliName> sessions ensure --name <agentId>
  const ensureArgs = [cliName, "sessions", "ensure", "--name", options.agentId];
  const ensureResult = await (await getExecaRunner())("acpx", ensureArgs, {
    reject: false,
    cwd: options.cwd,
  });

  // Ignore ensure failure — session may already exist, or `ensure` may not be supported
  if (ensureResult.exitCode !== 0) {
    // Try `sessions new` as fallback (some acpx versions don't have ensure)
    const newArgs = [cliName, "sessions", "new", "--name", options.agentId];
    await (await getExecaRunner())("acpx", newArgs, {
      reject: false,
      cwd: options.cwd,
    });
  }

  // Step 2: Send prompt to the session
  //   acpx --approve-all --ttl 0 <cliName> -s <agentId> -f <promptFile> --no-wait
  const args = [
    "--approve-all",
    "--ttl", "0",
    cliName,
    "-s", options.agentId,
    "-f", options.promptFile,
    "--no-wait",
  ];

  const result = await (await getExecaRunner())("acpx", args, {
    reject: false,
    cwd: options.cwd,
  });

  if (result.exitCode !== 0) {
    throw new Error(
      `acpx spawn failed (exit ${result.exitCode}): ${result.stderr || result.stdout || "no output"}`
    );
  }

  // Parse session key from acpx output
  const sessionKey = parseSessionKey(result.stdout, options.agentId);

  // Step 3: Update active-tasks.json
  const projectDir = await resolveProjectDir(options.cwd);
  await updateActiveTaskSessionKey(projectDir, options.taskId, sessionKey, startedAt);

  return {
    taskId: options.taskId,
    sessionKey,
    agentId: options.agentId,
    startedAt,
    status: "running",
  };
}

// ─── Output Parsing ──────────────────────────────────────────────────────────

function parseSessionKey(output: string, fallbackAgentId: string): string {
  if (!output.trim()) {
    // acpx --no-wait may not output a session key, use agentId as fallback
    return fallbackAgentId;
  }

  // Try JSON parse first
  try {
    const parsed = JSON.parse(output) as Record<string, unknown>;
    const value = pickSessionKey(parsed);
    if (value) return value;
  } catch {
    // Not JSON, try text patterns
  }

  // Try common patterns from acpx output
  // e.g. "[acpx] session codex-gen-01 (UUID) · ..."
  const uuidMatch = output.match(
    /\(([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\)/
  );
  if (uuidMatch?.[1]) return uuidMatch[1];

  // e.g. "[queued] UUID"
  const queuedMatch = output.match(
    /\[queued\]\s+([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/
  );
  if (queuedMatch?.[1]) return queuedMatch[1];

  // Fallback: use agentId
  return fallbackAgentId;
}

function pickSessionKey(record: Record<string, unknown>): string | undefined {
  for (const key of ["childSessionKey", "sessionKey", "key", "id"]) {
    const value = record[key];
    if (typeof value === "string" && value.trim()) {
      return value.trim();
    }
  }
  return undefined;
}

// ─── Active Tasks File ───────────────────────────────────────────────────────

async function updateActiveTaskSessionKey(
  projectDir: string,
  taskId: string,
  sessionKey: string,
  updatedAt: string
): Promise<void> {
  const filePath = path.join(projectDir, ACTIVE_TASKS_RELATIVE_PATH);
  const temporaryPath = `${filePath}.${process.pid}.${Date.now()}.tmp`;
  const payload = await readActiveTasks(filePath);
  const task = payload.tasks.find((entry) => entry.id === taskId);

  if (!task) {
    // Don't throw — task might not be registered yet (e.g. auto-dispatched downstream)
    console.warn(`[spawn] Task not found in active-tasks.json: ${taskId}, skipping session key update`);
    return;
  }

  task.acp_session_key = sessionKey;
  task.updated_at = updatedAt;

  try {
    await mkdir(path.dirname(filePath), { recursive: true });
    await writeFile(temporaryPath, `${JSON.stringify(payload, null, 2)}\n`, "utf8");
    await rename(temporaryPath, filePath);
  } catch (error) {
    await rm(temporaryPath, { force: true });
    throw error;
  }
}

async function readActiveTasks(filePath: string): Promise<ActiveTasksFile> {
  const raw = await readFile(filePath, "utf8");
  const parsed = JSON.parse(raw) as ActiveTasksFile;

  if (!parsed || !Array.isArray(parsed.tasks)) {
    throw new Error(`Invalid active tasks file: ${filePath}`);
  }

  return parsed;
}

async function resolveProjectDir(startDir: string): Promise<string> {
  let currentDir = path.resolve(startDir);

  while (true) {
    try {
      await access(path.join(currentDir, ACTIVE_TASKS_RELATIVE_PATH));
      return currentDir;
    } catch {
      const parentDir = path.dirname(currentDir);
      if (parentDir === currentDir) {
        return path.resolve(startDir);
      }
      currentDir = parentDir;
    }
  }
}

// ─── Execa Loader ────────────────────────────────────────────────────────────

async function getExecaRunner(): Promise<ExecaRunner> {
  if (testingGlobals.__nexumSpawnExeca) {
    return testingGlobals.__nexumSpawnExeca;
  }

  if (cachedExecaRunner) {
    return cachedExecaRunner;
  }

  const { execa } = await loadExecaModule();
  cachedExecaRunner = execa;
  return execa;
}
