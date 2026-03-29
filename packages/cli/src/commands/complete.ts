import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import type { Command } from 'commander';
import {
  parseContract,
  getTask,
  readTasks,
  updateTask,
  TaskStatus,
  getHeadCommit,
} from '@nexum/core';
import type { EvalVerdict } from '@nexum/core';
import type { SpawnOptions, SessionRecord } from '@nexum/spawn';
import { renderRetryPrompt } from '@nexum/prompts';
import { formatComplete, formatFail, sendMessage, getChatId, getBotToken } from '@nexum/notify';

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

interface EvalSummary {
  feedback: string;
  failedCriteria: string[];
  passCount: number;
  totalCount: number;
}

async function readEvalSummary(evalResultPath: string): Promise<EvalSummary> {
  try {
    const content = await readFile(evalResultPath, 'utf8');
    const feedbackMatch = content.match(/^feedback:\s*["']?(.*?)["']?\s*$/m);
    const feedback = feedbackMatch?.[1]?.trim() ?? '';

    // Count pass/fail from criteria_results
    const passMatches = [...content.matchAll(/result:\s*pass/g)];
    const failMatches = [...content.matchAll(/result:\s*fail/g)];
    const passCount = passMatches.length;
    const failCount = failMatches.length;
    const totalCount = passCount + failCount;

    // Extract failed criteria IDs
    const failedCriteria: string[] = [];
    const criteriaBlocks = content.split(/\n\s*-\s*id:\s*/);
    for (const block of criteriaBlocks.slice(1)) {
      const idMatch = block.match(/^(\S+)/);
      if (idMatch && /result:\s*fail/.test(block)) {
        failedCriteria.push(idMatch[1]);
      }
    }

    return { feedback, failedCriteria, passCount, totalCount };
  } catch {
    return { feedback: '', failedCriteria: [], passCount: 0, totalCount: 0 };
  }
}

async function unlockDownstreamTasks(projectDir: string, completedTaskId: string): Promise<string[]> {
  const tasks = await readTasks(projectDir);
  const completedIds = new Set(
    tasks.filter((t) => t.status === TaskStatus.Done).map((t) => t.id)
  );
  completedIds.add(completedTaskId);

  const toUnlock = tasks.filter(
    (t) =>
      (t.status === TaskStatus.Blocked || t.status === TaskStatus.Pending) &&
      t.depends_on.includes(completedTaskId) &&
      t.depends_on.every((dep) => completedIds.has(dep))
  );

  for (const t of toUnlock) {
    if (t.status !== TaskStatus.Pending) {
      await updateTask(projectDir, t.id, { status: TaskStatus.Pending });
    }
  }

  return toUnlock.map((t) => t.id);
}

export async function runComplete(
  taskId: string,
  verdict: string,
  projectDir: string
): Promise<void> {
  const normalizedVerdict = verdict as EvalVerdict;
  if (!['pass', 'fail', 'escalated'].includes(normalizedVerdict)) {
    throw new Error(`Invalid verdict: ${verdict}. Must be pass, fail, or escalated.`);
  }

  const task = await getTask(projectDir, taskId);
  if (!task) {
    throw new Error(`Task not found: ${taskId}`);
  }

  const contractAbsPath = path.isAbsolute(task.contract_path)
    ? task.contract_path
    : path.join(projectDir, task.contract_path);
  const contract = await parseContract(contractAbsPath);

  const startedAt = task.started_at ? new Date(task.started_at).getTime() : Date.now();
  const elapsedMs = Date.now() - startedAt;
  const iteration = task.iteration ?? 0;

  const evalSummary = task.eval_result_path
    ? await readEvalSummary(task.eval_result_path)
    : { feedback: '', failedCriteria: [], passCount: 0, totalCount: 0 };

  const chatId = getChatId();
  const botToken = getBotToken();

  if (normalizedVerdict === 'pass') {
    const now = new Date().toISOString();
    await updateTask(projectDir, taskId, {
      status: TaskStatus.Done,
      completed_at: now,
    });

    const unlockedIds = await unlockDownstreamTasks(projectDir, taskId);

    if (chatId && botToken) {
      const tasks = await readTasks(projectDir);
      const doneCount = tasks.filter((t) => t.status === TaskStatus.Done).length;
      const progress = `${doneCount}/${tasks.length}`;
      const msg = formatComplete(
        taskId,
        contract.name,
        elapsedMs,
        iteration,
        evalSummary.passCount,
        evalSummary.totalCount,
        unlockedIds,
        progress
      );
      const notifyFn = await getNotifyFn();
      await notifyFn(chatId, msg, botToken);
    }

    console.log(`Task ${taskId} completed. Unlocked: ${unlockedIds.join(', ') || 'none'}`);
    return;
  }

  if (normalizedVerdict === 'fail' && iteration < contract.max_iterations) {
    // Retry: increment iteration, re-spawn generator
    const nextIteration = iteration + 1;
    const nextEvalResultPath = path.join(
      projectDir,
      'nexum',
      'runtime',
      'eval',
      `${taskId}-iter-${nextIteration}.yaml`
    );

    const gitCommitCmd = [
      `git add -- ${contract.scope.files.join(' ')}`,
      `git commit -m "feat(${taskId.toLowerCase()}): implement ${contract.name} (iter ${nextIteration})"`,
    ].join(' && ');

    const promptContent = renderRetryPrompt(
      {
        contract,
        task: { id: task.id, name: task.name },
        gitCommitCmd,
        evalResultPath: nextEvalResultPath,
        lessons: [],
      },
      verdict,
      evalSummary.feedback,
      evalSummary.failedCriteria
    );

    const promptsDir = path.join(projectDir, 'nexum', 'runtime', 'prompts');
    await mkdir(promptsDir, { recursive: true });
    const promptFile = path.join(promptsDir, `${taskId}-retry-${Date.now()}.md`);
    await writeFile(promptFile, promptContent, 'utf8');

    const baseCommit = await getHeadCommit(projectDir).catch(() => '');

    await updateTask(projectDir, taskId, {
      status: TaskStatus.Running,
      iteration: nextIteration,
      ...(baseCommit ? { base_commit: baseCommit } : {}),
    });

    const spawnFn = await getSpawnFn();
    const record = await spawnFn({
      taskId,
      agentId: contract.generator,
      promptFile,
      cwd: projectDir,
      mode: 'session',
      label: `nexum-${taskId.toLowerCase()}-${contract.generator}-retry-${nextIteration}`,
    });

    await updateTask(projectDir, taskId, {
      acp_session_key: record.sessionKey,
    });

    if (chatId && botToken) {
      const msg = formatFail(
        taskId,
        contract.name,
        iteration,
        evalSummary.passCount,
        evalSummary.totalCount,
        evalSummary.failedCriteria.length,
        evalSummary.failedCriteria,
        evalSummary.feedback.slice(0, 200)
      );
      const notifyFn = await getNotifyFn();
      await notifyFn(chatId, msg, botToken);
    }

    console.log(`Task ${taskId} failed. Retrying as iteration ${nextIteration}.`);
    return;
  }

  // fail with max_iterations reached, or escalated: mark as failed
  await updateTask(projectDir, taskId, {
    status: TaskStatus.Failed,
    last_error:
      normalizedVerdict === 'escalated'
        ? 'Escalated: requires human intervention'
        : `Failed after ${iteration} iterations`,
  });

  if (chatId && botToken) {
    const msg = formatFail(
      taskId,
      contract.name,
      iteration,
      evalSummary.passCount,
      evalSummary.totalCount,
      evalSummary.failedCriteria.length,
      evalSummary.failedCriteria,
      normalizedVerdict === 'escalated'
        ? 'Escalated: requires human intervention'
        : evalSummary.feedback.slice(0, 200)
    );
    const notifyFn = await getNotifyFn();
    await notifyFn(chatId, msg, botToken);
  }

  const reason =
    normalizedVerdict === 'escalated'
      ? 'escalated — human intervention required'
      : `failed after max iterations (${contract.max_iterations})`;
  console.log(`Task ${taskId} ${reason}.`);
}

export function registerComplete(program: Command): void {
  program
    .command('complete <taskId> <verdict>')
    .description('Process evaluator result for a task (verdict: pass|fail|escalated)')
    .option('--project <dir>', 'Project directory', process.cwd())
    .action(async (taskId: string, verdict: string, options: { project: string }) => {
      try {
        await runComplete(taskId, verdict, options.project);
      } catch (err) {
        console.error('complete failed:', err instanceof Error ? err.message : err);
        process.exit(1);
      }
    });
}
