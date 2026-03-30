import { access, mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import type { SessionRecord, SpawnOptions } from "./types.js";

const ACTIVE_TASKS_RELATIVE_PATH = path.join("nexum", "active-tasks.json");
type AgentCliName = "claude" | "codex";
type ExecaResult = {
  stdout: string;
  stderr: string;
  exitCode: number;
};
type ExecaRunner = (
  command: string,
  args: string[],
  options: { reject: false }
) => Promise<ExecaResult>;
const testingGlobals = globalThis as typeof globalThis & {
  __nexumSpawnExeca?: ExecaRunner;
};
let cachedExecaRunner: ExecaRunner | undefined;
const loadExecaModule = new Function("return import('execa')") as () => Promise<{ execa: ExecaRunner }>;

interface ActiveTask {
  id: string;
  acp_session_key?: string;
  updated_at?: string;
  [key: string]: unknown;
}

interface ActiveTasksFile {
  tasks: ActiveTask[];
}

export function buildPromptArgs(
  promptFilePath: string,
  agentId: string,
  cliName: AgentCliName
): string[] {
  return ["acpx", "-s", agentId, "--ttl", "0", "--approve-all", cliName, "exec", "-f", promptFilePath];
}

function resolveCliName(options: SpawnOptions): AgentCliName {
  const agentCli = (options as SpawnOptions & { agentCli?: AgentCliName }).agentCli;

  if (agentCli === "claude" || agentCli === "codex") {
    return agentCli;
  }

  if (options.agentId.startsWith("claude-")) {
    return "claude";
  }

  return "codex";
}

export async function spawnAcpSession(options: SpawnOptions): Promise<SessionRecord> {
  const startedAt = new Date().toISOString();
  const cliName = resolveCliName(options);
  const args = [
    "sessions",
    "spawn",
    "--runtime",
    "acp",
    "--agent",
    options.agentId,
    "--mode",
    options.mode,
    "--cwd",
    options.cwd,
    "--label",
    options.label,
    ...buildPromptArgs(options.promptFile, options.agentId, cliName)
  ];
  const result = await (await getExecaRunner())("openclaw", args, { reject: false });

  if (result.exitCode !== 0) {
    throw new Error(result.stderr || result.stdout || "Failed to spawn ACP session.");
  }

  const sessionKey = parseSessionKey(result.stdout);
  const projectDir = await resolveProjectDir(options.cwd);
  await updateActiveTaskSessionKey(projectDir, options.taskId, sessionKey, startedAt);
  await runTrack(projectDir, options.taskId, sessionKey);

  return {
    taskId: options.taskId,
    sessionKey,
    agentId: options.agentId,
    startedAt,
    status: "running"
  };
}

function parseSessionKey(output: string): string {
  if (!output.trim()) {
    throw new Error("OpenClaw spawn command returned no output.");
  }

  try {
    const parsed = JSON.parse(output) as Record<string, unknown>;
    const value = pickSessionKey(parsed);

    if (value) {
      return value;
    }
  } catch {
    // Fall back to text parsing because some CLI builds print banners/log lines.
  }

  const match = output.match(
    /"(?:childSessionKey|sessionKey|key)"\s*:\s*"([^"]+)"|(?:childSessionKey|sessionKey|key)\s*[:=]\s*([^\s]+)/m
  );
  const sessionKey = match?.[1] ?? match?.[2];

  if (!sessionKey) {
    throw new Error(`Unable to parse session key from OpenClaw output: ${output}`);
  }

  return sessionKey.trim();
}

function pickSessionKey(record: Record<string, unknown>): string | undefined {
  for (const key of ["childSessionKey", "sessionKey", "key"]) {
    const value = record[key];

    if (typeof value === "string" && value.trim()) {
      return value.trim();
    }
  }

  return undefined;
}

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
    throw new Error(`Task not found in active-tasks.json: ${taskId}`);
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

async function runTrack(projectDir: string, taskId: string, sessionKey: string): Promise<void> {
  const cliEntryPath = path.resolve(
    path.dirname(fileURLToPath(import.meta.url)),
    "../../cli/dist/index.js"
  );
  const result = await (await getExecaRunner())(
    process.execPath,
    [cliEntryPath, "track", taskId, sessionKey, "--project", projectDir],
    { reject: false }
  );

  if (result.exitCode !== 0) {
    throw new Error(result.stderr || result.stdout || "Failed to run nexum track.");
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
