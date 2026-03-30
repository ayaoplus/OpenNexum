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
  loadConfig,
  resolveAgentCli,
} from '@nexum/core';
import type { EvalVerdict, AgentCli } from '@nexum/core';
import { renderRetryPrompt } from '@nexum/prompts';
import {
  formatComplete,
  formatEscalation,
  formatFail,
  sendMessage,
} from '@nexum/notify';
import { archiveDoneTasks } from '../lib/archive.js';

export interface RetryPayload {
  action: 'retry';
  taskId: string;
  taskName: string;
  agentId: string;
  agentCli: AgentCli;
  promptFile: string;
  promptContent: string;
  label: string;
  cwd: string;
  nextIteration: number;
}

export interface CompleteResult {
  action: 'done' | 'retry' | 'escalated' | 'failed';
  taskId: string;
  unlockedTasks?: string[];
  retryPayload?: RetryPayload;
}

interface CriterionResult {
  id: string;
  passed: boolean;
  reason: string;
}

interface EvalSummary {
  feedback: string;
  failedCriteria: string[];
  passCount: number;
  totalCount: number;
  criteriaResults: CriterionResult[];
}

interface EscalationHistoryEntry {
  iteration: number;
  feedback: string;
  criteriaResults: CriterionResult[];
}

const taskStatusRegistry = TaskStatus as unknown as Record<string, string>;
taskStatusRegistry.Escalated ??= 'escalated';
const ESCALATED_TASK_STATUS = taskStatusRegistry.Escalated as TaskStatus;
const ESCALATED_REASON_PREFIX = 'Escalated:';
const FEEDBACK_SIMILARITY_THRESHOLD = 0.8;

function parseYamlScalar(raw: string | undefined): string {
  if (!raw) {
    return '';
  }

  return raw.trim().replace(/^["']|["']$/g, '');
}

async function readEvalSummary(evalResultPath: string): Promise<EvalSummary> {
  try {
    const content = await readFile(evalResultPath, 'utf8');
    const feedback = parseYamlScalar(content.match(/^feedback:\s*(.+)$/m)?.[1]);
    const criteriaResults: CriterionResult[] = [];
    const failedCriteria: string[] = [];
    const criteriaBlocks = content.split(/\n\s*-\s*id:\s*/);

    for (const block of criteriaBlocks.slice(1)) {
      const idMatch = block.match(/^(\S+)/);
      const statusMatch = block.match(/^\s*(?:status|result):\s*(pass|fail)\s*$/m);
      const reason =
        parseYamlScalar(block.match(/^\s*reason:\s*(.+)$/m)?.[1]) ||
        parseYamlScalar(block.match(/^\s*evidence:\s*(.+)$/m)?.[1]) ||
        parseYamlScalar(block.match(/^\s*detail:\s*(.+)$/m)?.[1]);

      if (!idMatch || !statusMatch) {
        continue;
      }

      const passed = statusMatch[1] === 'pass';
      criteriaResults.push({ id: idMatch[1], passed, reason });

      if (!passed) {
        failedCriteria.push(idMatch[1]);
      }
    }

    const passCount =
      criteriaResults.length > 0
        ? criteriaResults.filter((result) => result.passed).length
        : [...content.matchAll(/(?:status|result):\s*pass/g)].length;
    const failCount =
      criteriaResults.length > 0
        ? criteriaResults.filter((result) => !result.passed).length
        : [...content.matchAll(/(?:status|result):\s*fail/g)].length;
    const totalCount = criteriaResults.length > 0 ? criteriaResults.length : passCount + failCount;

    return { feedback, failedCriteria, passCount, totalCount, criteriaResults };
  } catch {
    return { feedback: '', failedCriteria: [], passCount: 0, totalCount: 0, criteriaResults: [] };
  }
}

function tokenizeFeedback(text: string): string[] {
  return (text.toLowerCase().match(/[a-z0-9]+|[\u4e00-\u9fff]+/g) ?? []).filter(Boolean);
}

function calculateFeedbackSimilarity(left: string, right: string): number {
  const leftWords = new Set(tokenizeFeedback(left));
  const rightWords = new Set(tokenizeFeedback(right));

  if (leftWords.size === 0 || rightWords.size === 0) {
    return 0;
  }

  let commonCount = 0;
  for (const word of leftWords) {
    if (rightWords.has(word)) {
      commonCount += 1;
    }
  }

  return commonCount / Math.max(leftWords.size, rightWords.size);
}

function buildEvalResultPath(projectDir: string, taskId: string, iteration: number): string {
  return path.join(projectDir, 'nexum', 'runtime', 'eval', `${taskId}-iter-${iteration}.yaml`);
}

async function readEscalationHistory(
  projectDir: string,
  taskId: string,
  latestIteration: number
): Promise<EscalationHistoryEntry[]> {
  const history: EscalationHistoryEntry[] = [];

  for (let iteration = 0; iteration <= latestIteration; iteration += 1) {
    const summary = await readEvalSummary(buildEvalResultPath(projectDir, taskId, iteration));

    if (!summary.feedback && summary.criteriaResults.length === 0) {
      continue;
    }

    history.push({
      iteration,
      feedback: summary.feedback,
      criteriaResults: summary.criteriaResults,
    });
  }

  return history;
}

function isEscalatedTask(task: Awaited<ReturnType<typeof getTask>>): boolean {
  return Boolean(
    task &&
      (task.status === ESCALATED_TASK_STATUS ||
        task.last_error?.startsWith(ESCALATED_REASON_PREFIX))
  );
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
): Promise<CompleteResult> {
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
    : { feedback: '', failedCriteria: [], passCount: 0, totalCount: 0, criteriaResults: [] };
  const previousEvalSummary =
    normalizedVerdict === 'fail' && iteration > 0
      ? await readEvalSummary(buildEvalResultPath(projectDir, taskId, iteration - 1))
      : null;
  const feedbackSimilarity = previousEvalSummary
    ? calculateFeedbackSimilarity(evalSummary.feedback, previousEvalSummary.feedback)
    : 0;
  const shouldEscalateBySimilarity =
    normalizedVerdict === 'fail' && feedbackSimilarity > FEEDBACK_SIMILARITY_THRESHOLD;
  const shouldEscalateByLimit =
    normalizedVerdict === 'fail' && iteration >= contract.max_iterations;

  const notifyTarget = (await loadConfig(projectDir).catch(() => ({ notify: undefined }))).notify?.target;

  // ── PASS ──
  if (normalizedVerdict === 'pass') {
    const now = new Date().toISOString();
    await updateTask(projectDir, taskId, {
      status: TaskStatus.Done,
      completed_at: now,
    });

    const unlockedIds = await unlockDownstreamTasks(projectDir, taskId);
    const tasks = await readTasks(projectDir);
    const doneCount = tasks.filter((t) => t.status === TaskStatus.Done).length;

    if (notifyTarget) {
      const msg = formatComplete(
        taskId,
        contract.name,
        elapsedMs,
        iteration,
        evalSummary.passCount,
        evalSummary.totalCount,
        unlockedIds,
        `${doneCount}/${tasks.length}`,
        { evaluatorName: contract.evaluator }
      );
      await sendMessage(notifyTarget, msg).catch(() => {});
    }

    if (doneCount > 20) {
      await archiveDoneTasks(projectDir).catch((error) => {
        console.warn(
          'auto-archive failed:',
          error instanceof Error ? error.message : String(error)
        );
      });
    }

    return { action: 'done', taskId, unlockedTasks: unlockedIds };
  }

  // ── FAIL + can retry ──
  if (
    normalizedVerdict === 'fail' &&
    !shouldEscalateBySimilarity &&
    !shouldEscalateByLimit
  ) {
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
      eval_result_path: nextEvalResultPath,
      ...(baseCommit ? { base_commit: baseCommit } : {}),
    });

    const config = await loadConfig(projectDir);
    const agentCli = resolveAgentCli(config, contract.generator);
    const label = `nexum-${taskId.toLowerCase()}-${contract.generator}-retry-${nextIteration}`;

    if (notifyTarget) {
      const msg = formatFail(
        taskId,
        contract.name,
        iteration,
        evalSummary.passCount,
        evalSummary.totalCount,
        evalSummary.failedCriteria.length,
        evalSummary.failedCriteria,
        evalSummary.feedback.slice(0, 200),
        {
          evaluatorName: contract.evaluator,
          criteriaResults: evalSummary.criteriaResults,
          autoRetryHint: `系统将自动重试，下一次迭代: 第${nextIteration + 1}次`,
        }
      );
      await sendMessage(notifyTarget, msg).catch(() => {});
    }

    const retryPayload: RetryPayload = {
      action: 'retry',
      taskId,
      taskName: contract.name,
      agentId: contract.generator,
      agentCli,
      promptFile,
      promptContent,
      label,
      cwd: projectDir,
      nextIteration,
    };

    return { action: 'retry', taskId, retryPayload };
  }

  // ── ESCALATED or max iterations reached ──
  const similarityPercent = Math.round(feedbackSimilarity * 100);
  const escalationReason =
    normalizedVerdict === 'escalated'
      ? 'requires human intervention'
      : shouldEscalateBySimilarity
        ? `consecutive evaluator feedback similarity ${similarityPercent}% (> 80%), possible Contract criteria issue`
        : `max_iterations reached (${iteration}/${contract.max_iterations})`;
  const escalationHistory = await readEscalationHistory(projectDir, taskId, iteration);

  await updateTask(projectDir, taskId, {
    status: ESCALATED_TASK_STATUS,
    last_error: `${ESCALATED_REASON_PREFIX} ${escalationReason}`,
  });

  if (notifyTarget) {
    const msg = formatEscalation(
      taskId,
      contract.name,
      escalationHistory,
      `nexum retry ${taskId} --force`,
      {
        evaluatorName: contract.evaluator,
        reason: escalationReason,
        note: shouldEscalateBySimilarity
          ? '连续 2 次 fail 的 feedback 高度相似，可能是 Contract criteria 写错。'
          : undefined,
      }
    );
    await sendMessage(notifyTarget, msg).catch(() => {});
  }

  return {
    action: 'escalated',
    taskId,
  };
}

export async function runRetry(
  taskId: string,
  projectDir: string,
  force: boolean
): Promise<{ ok: true; taskId: string; status: TaskStatus.Pending }> {
  if (!force) {
    throw new Error('retry requires --force');
  }

  const task = await getTask(projectDir, taskId);
  if (!task) {
    throw new Error(`Task not found: ${taskId}`);
  }

  if (!isEscalatedTask(task)) {
    throw new Error(`Task ${taskId} is not escalated.`);
  }

  await updateTask(projectDir, taskId, {
    status: TaskStatus.Pending,
    iteration: 0,
    last_error: null,
    eval_result_path: undefined,
    started_at: undefined,
    completed_at: undefined,
    acp_session_key: undefined,
    acp_stream_log: undefined,
    eval_tmux_session: undefined,
  });

  return { ok: true, taskId, status: TaskStatus.Pending };
}

export function registerComplete(program: Command): void {
  program
    .command('complete <taskId> <verdict>')
    .description('Process evaluator result (verdict: pass|fail|escalated). Outputs JSON — retry action includes spawn payload for orchestrator.')
    .option('--project <dir>', 'Project directory', process.cwd())
    .action(async (taskId: string, verdict: string, options: { project: string }) => {
      try {
        const result = await runComplete(taskId, verdict, options.project);
        console.log(JSON.stringify(result, null, 2));
      } catch (err) {
        console.error('complete failed:', err instanceof Error ? err.message : err);
        process.exit(1);
      }
    });

  program
    .command('retry <taskId>')
    .description('Reset an escalated task to pending and clear iteration; requires --force.')
    .option('--project <dir>', 'Project directory', process.cwd())
    .option('--force', 'Required to reset escalated task state')
    .action(async (taskId: string, options: { project: string; force?: boolean }) => {
      try {
        const result = await runRetry(taskId, options.project, !!options.force);
        console.log(JSON.stringify(result, null, 2));
      } catch (err) {
        console.error('retry failed:', err instanceof Error ? err.message : err);
        process.exit(1);
      }
    });
}
