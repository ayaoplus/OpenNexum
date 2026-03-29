import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import type { Command } from 'commander';
import {
  parseContract,
  getTask,
  updateTask,
  readTasks,
  TaskStatus,
  getHeadCommit,
} from '@nexum/core';
import type { SpawnOptions, SessionRecord } from '@nexum/spawn';
import { renderGeneratorPrompt } from '@nexum/prompts';
import { formatDispatch, sendMessage, getChatId, getBotToken } from '@nexum/notify';

// Global mock hooks for testing
const testingGlobals = globalThis as typeof globalThis & {
  __nexumCliSpawnAcpSession?: (opts: SpawnOptions) => Promise<SessionRecord>;
  __nexumCliSendMessage?: (chatId: string, text: string, token: string) => Promise<void>;
};

async function getSpawnFn(): Promise<(opts: SpawnOptions) => Promise<SessionRecord>> {
  if (testingGlobals.__nexumCliSpawnAcpSession) {
    return testingGlobals.__nexumCliSpawnAcpSession;
  }
  const { spawnAcpSession } = await import('@nexum/spawn');
  return spawnAcpSession;
}

async function getNotifyFn(): Promise<(chatId: string, text: string, token: string) => Promise<void>> {
  if (testingGlobals.__nexumCliSendMessage) {
    return testingGlobals.__nexumCliSendMessage;
  }
  return sendMessage;
}

export async function runSpawn(taskId: string, projectDir: string): Promise<void> {
  const task = await getTask(projectDir, taskId);
  if (!task) {
    throw new Error(`Task not found: ${taskId}`);
  }

  const contractAbsPath = path.isAbsolute(task.contract_path)
    ? task.contract_path
    : path.join(projectDir, task.contract_path);
  const contract = await parseContract(contractAbsPath);

  const iteration = task.iteration ?? 0;
  const evalResultPath = path.join(
    projectDir,
    'nexum',
    'runtime',
    'eval',
    `${taskId}-iter-${iteration}.yaml`
  );

  const gitCommitCmd = [
    `git add -- ${contract.scope.files.join(' ')}`,
    `git commit -m "feat(${taskId.toLowerCase()}): implement ${contract.name}"`,
  ].join(' && ');

  const promptContent = renderGeneratorPrompt({
    contract,
    task: { id: task.id, name: task.name },
    gitCommitCmd,
    evalResultPath,
    lessons: [],
  });

  const promptsDir = path.join(projectDir, 'nexum', 'runtime', 'prompts');
  await mkdir(promptsDir, { recursive: true });
  const promptFile = path.join(promptsDir, `${taskId}-gen-${Date.now()}.md`);
  await writeFile(promptFile, promptContent, 'utf8');

  const baseCommit = await getHeadCommit(projectDir).catch(() => '');

  await updateTask(projectDir, taskId, {
    status: TaskStatus.Running,
    started_at: new Date().toISOString(),
    ...(baseCommit ? { base_commit: baseCommit } : {}),
    iteration,
  });

  const spawnFn = await getSpawnFn();
  const record = await spawnFn({
    taskId,
    agentId: contract.generator,
    promptFile,
    cwd: projectDir,
    mode: 'session',
    label: `nexum-${taskId.toLowerCase()}-${contract.generator}`,
  });

  await updateTask(projectDir, taskId, {
    acp_session_key: record.sessionKey,
  });

  const chatId = getChatId();
  const botToken = getBotToken();
  if (chatId && botToken) {
    const tasks = await readTasks(projectDir);
    const doneCount = tasks.filter((t) => t.status === TaskStatus.Done).length;
    const progress = `${doneCount}/${tasks.length}`;
    const msg = formatDispatch(
      taskId,
      contract.name,
      contract.generator,
      contract.scope.files.length,
      contract.deliverables.length,
      progress
    );
    const notifyFn = await getNotifyFn();
    await notifyFn(chatId, msg, botToken);
  }
}

export function registerSpawn(program: Command): void {
  program
    .command('spawn <taskId>')
    .description('Spawn a generator agent for a task')
    .option('--project <dir>', 'Project directory', process.cwd())
    .action(async (taskId: string, options: { project: string }) => {
      try {
        await runSpawn(taskId, options.project);
      } catch (err) {
        console.error('spawn failed:', err instanceof Error ? err.message : err);
        process.exit(1);
      }
    });
}
