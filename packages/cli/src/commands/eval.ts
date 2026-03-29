import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import type { Command } from 'commander';
import { parseContract, getTask, updateTask, TaskStatus } from '@nexum/core';
import type { SpawnOptions, SessionRecord } from '@nexum/spawn';
import { renderEvaluatorPrompt } from '@nexum/prompts';

// Global mock hook for testing
const testingGlobals = globalThis as typeof globalThis & {
  __nexumCliSpawnAcpSession?: (opts: SpawnOptions) => Promise<SessionRecord>;
};

async function getSpawnFn(): Promise<(opts: SpawnOptions) => Promise<SessionRecord>> {
  if (testingGlobals.__nexumCliSpawnAcpSession) {
    return testingGlobals.__nexumCliSpawnAcpSession;
  }
  const { spawnAcpSession } = await import('@nexum/spawn');
  return spawnAcpSession;
}

export async function runEval(taskId: string, projectDir: string): Promise<void> {
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

  const promptContent = renderEvaluatorPrompt({
    contract,
    task: { id: task.id, name: task.name },
    gitCommitCmd: '',
    evalResultPath,
    lessons: [],
  });

  const promptsDir = path.join(projectDir, 'nexum', 'runtime', 'prompts');
  await mkdir(promptsDir, { recursive: true });
  const promptFile = path.join(promptsDir, `${taskId}-eval-${Date.now()}.md`);
  await writeFile(promptFile, promptContent, 'utf8');

  await updateTask(projectDir, taskId, {
    status: TaskStatus.Evaluating,
    eval_result_path: evalResultPath,
  });

  const spawnFn = await getSpawnFn();
  const record = await spawnFn({
    taskId,
    agentId: contract.evaluator,
    promptFile,
    cwd: projectDir,
    mode: 'session',
    label: `nexum-${taskId.toLowerCase()}-eval`,
  });

  await updateTask(projectDir, taskId, {
    eval_tmux_session: record.sessionKey,
  });
}

export function registerEval(program: Command): void {
  program
    .command('eval <taskId>')
    .description('Spawn an evaluator agent for a task')
    .option('--project <dir>', 'Project directory', process.cwd())
    .action(async (taskId: string, options: { project: string }) => {
      try {
        await runEval(taskId, options.project);
      } catch (err) {
        console.error('eval failed:', err instanceof Error ? err.message : err);
        process.exit(1);
      }
    });
}
