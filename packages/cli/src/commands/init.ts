import { mkdir, writeFile } from "node:fs/promises";
import { access } from "node:fs/promises";
import path from "node:path";
import type { Command } from "commander";

const DEFAULT_CONFIG = {
  agents: {
    codex: { cli: "codex" },
    claude: { cli: "claude" },
  },
};

const DEFAULT_ACTIVE_TASKS = {
  tasks: [],
};

async function fileExists(filePath: string): Promise<boolean> {
  try {
    await access(filePath);
    return true;
  } catch {
    return false;
  }
}

async function writeIfNotExists(filePath: string, content: string): Promise<boolean> {
  if (await fileExists(filePath)) {
    return false;
  }
  await mkdir(path.dirname(filePath), { recursive: true });
  await writeFile(filePath, content, "utf8");
  return true;
}

async function ensureGitkeep(dirPath: string): Promise<boolean> {
  const gitkeepPath = path.join(dirPath, ".gitkeep");
  if (await fileExists(gitkeepPath)) {
    return false;
  }
  await mkdir(dirPath, { recursive: true });
  await writeFile(gitkeepPath, "", "utf8");
  return true;
}

export async function runInit(projectDir: string): Promise<void> {
  const nexumDir = path.join(projectDir, "nexum");
  const activeTasksPath = path.join(nexumDir, "active-tasks.json");
  const configPath = path.join(nexumDir, "config.json");
  const contractsDir = path.join(projectDir, "docs", "nexum", "contracts");
  const evalDir = path.join(nexumDir, "runtime", "eval");

  const created: string[] = [];

  if (await writeIfNotExists(activeTasksPath, JSON.stringify(DEFAULT_ACTIVE_TASKS, null, 2) + "\n")) {
    created.push(activeTasksPath);
  }

  if (await writeIfNotExists(configPath, JSON.stringify(DEFAULT_CONFIG, null, 2) + "\n")) {
    created.push(configPath);
  }

  if (await ensureGitkeep(contractsDir)) {
    created.push(path.join(contractsDir, ".gitkeep"));
  }

  if (await ensureGitkeep(evalDir)) {
    created.push(path.join(evalDir, ".gitkeep"));
  }

  if (created.length === 0) {
    console.log("nexum already initialized, nothing to do.");
  } else {
    console.log("nexum initialized:");
    for (const file of created) {
      console.log(`  created ${path.relative(projectDir, file)}`);
    }
  }
}

export function registerInit(program: Command): void {
  program
    .command("init")
    .description("Initialize nexum project structure")
    .option("--project <dir>", "Project directory", process.cwd())
    .action(async (options: { project: string }) => {
      try {
        await runInit(options.project);
      } catch (err) {
        console.error("init failed:", err instanceof Error ? err.message : err);
        process.exit(1);
      }
    });
}
