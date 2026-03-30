import { readFile } from 'node:fs/promises';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import path from 'node:path';
import type { Command } from 'commander';
import {
  getActiveBatch,
  getBatchProgress,
  getTask,
  readTasks,
  updateTask,
  TaskStatus,
  loadConfig,
  getHeadCommit,
  parseContract,
  type EvalVerdict,
  type NexumConfig,
} from '@nexum/core';
import {
  formatGeneratorDone,
  formatReviewPassed,
  formatReviewFailed,
  formatEscalation,
  formatCommitMissing,
  sendMessage,
} from '@nexum/notify';
import { spawnAcpSession } from '@nexum/spawn';
import { runComplete } from './complete.js';
import { runSpawn, runSpawnEval } from './spawn.js';

const execFileAsync = promisify(execFile);

// ─── Types ───────────────────────────────────────────────────────────────────

interface CallbackOptions {
  project: string;
  model?: string;
  inputTokens?: string;
  outputTokens?: string;
  role?: 'generator' | 'evaluator';
}

// ─── Entry Point ─────────────────────────────────────────────────────────────

export async function runCallback(taskId: string, options: CallbackOptions): Promise<void> {
  const role = options.role ?? 'generator';

  if (role === 'generator') {
    await runGeneratorCallback(taskId, options);
  } else if (role === 'evaluator') {
    await runEvaluatorCallback(taskId, options);
  } else {
    throw new Error(`Invalid role: ${role}. Must be generator or evaluator.`);
  }
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

/** Resolve the actual model name from config agents map */
function resolveModelName(config: NexumConfig, agentId: string, reportedModel?: string): string {
  // If generator reported a standard model name, use it
  if (reportedModel && !['codex', 'claude', 'auto', 'gpt-5', 'gpt5'].includes(reportedModel.toLowerCase())) {
    return reportedModel;
  }
  // Otherwise look up from config
  const agentConfig = config.agents?.[agentId];
  if (agentConfig?.model) return agentConfig.model;
  // Fallback: derive from agentId prefix
  if (agentId.startsWith('codex-')) return 'gpt-5.4';
  if (agentId.startsWith('claude-')) return 'claude-sonnet-4-6';
  return reportedModel || 'unknown';
}

/** Get the latest commit message from git log */
async function getLastCommitMessage(projectDir: string): Promise<string> {
  try {
    const { stdout } = await execFileAsync('git', ['-C', projectDir, 'log', '-1', '--pretty=%s'], { encoding: 'utf8' });
    return stdout.trim();
  } catch {
    return '';
  }
}

// ─── Generator Callback ──────────────────────────────────────────────────────

async function runGeneratorCallback(taskId: string, options: CallbackOptions): Promise<void> {
  const projectDir = options.project;
  const task = await getTask(projectDir, taskId);
  if (!task) throw new Error(`Task not found: ${taskId}`);

  const contract = await loadContract(projectDir, task.contract_path);
  const config = await loadConfig(projectDir).catch(() => ({ notify: undefined, git: undefined } as NexumConfig));

  const inputTokens = parseInt(options.inputTokens ?? '0', 10) || 0;
  const outputTokens = parseInt(options.outputTokens ?? '0', 10) || 0;
  const model = resolveModelName(config, contract.generator, options.model);

  const currentHead = await getHeadCommit(projectDir).catch(() => '');
  const hasRemote = !!(config.git?.remote);
  const commitMissing = hasRemote && task.base_commit && currentHead && currentHead === task.base_commit;

  const startedAt = task.started_at ? new Date(task.started_at).getTime() : Date.now();
  const elapsedMs = Date.now() - startedAt;
  const commitMessage = commitMissing ? '' : await getLastCommitMessage(projectDir);

  // ── Step 1: Update status ──
  await updateTask(projectDir, taskId, {
    status: TaskStatus.GeneratorDone,
    ...(currentHead ? { commit_hash: currentHead } : {}),
  });

  // ── Step 2: Notify ──
  const target = config.notify?.target;
  if (target) {
    const msg = commitMissing
      ? formatCommitMissing({ taskId, taskName: task.name, headHash: currentHead })
      : formatGeneratorDone({
          taskId,
          taskName: task.name,
          agent: contract.generator,
          model,
          inputTokens,
          outputTokens,
          scopeFiles: contract.scope.files,
          commitHash: currentHead,
          commitMessage,
          iteration: task.iteration,
          elapsedMs,
        });

    await sendMessage(target, msg).catch(() => {});
  }

  // ── Step 3: Auto-dispatch evaluator ──
  try {
    const evalPayload = await runSpawnEval(taskId, projectDir);
    const evalSessionName = `claude-eval-${taskId}`;
    const session = await spawnAcpSession({
      ...evalPayload,
      agentId: evalSessionName,
      mode: 'run',
    });
    console.log(`[callback] auto-dispatched evaluator ${evalSessionName}: ${session.sessionKey}`);
  } catch (err) {
    console.warn(`[callback] auto-dispatch evaluator failed for ${taskId}: ${err instanceof Error ? err.message : err}`);
  }

  console.log(JSON.stringify({ ok: true, taskId, status: 'generator_done', commitMissing: !!commitMissing, model, inputTokens, outputTokens }));
}

// ─── Evaluator Callback ──────────────────────────────────────────────────────

async function runEvaluatorCallback(taskId: string, options: CallbackOptions): Promise<void> {
  const projectDir = options.project;
  const task = await getTask(projectDir, taskId);
  if (!task) throw new Error(`Task not found: ${taskId}`);
  if (!task.eval_result_path) throw new Error(`Task ${taskId} has no eval_result_path`);

  const contract = await loadContract(projectDir, task.contract_path);
  const config = await loadConfig(projectDir).catch(() => ({ notify: undefined } as NexumConfig));
  const target = config.notify?.target;

  const evalResultPath = resolvePath(projectDir, task.eval_result_path);
  const verdict = await readEvalVerdict(evalResultPath);
  const evalSummary = await readEvalSummary(evalResultPath);
  const iteration = task.iteration ?? 0;
  const startedAt = task.started_at ? new Date(task.started_at).getTime() : Date.now();
  const elapsedMs = Date.now() - startedAt;
  const evalModel = resolveModelName(config, contract.evaluator);

  // ── Step 1+2: Run complete ──
  const result = await runComplete(taskId, verdict, projectDir);

  // ── Step 3: Notify ──
  if (target) {
    if (result.action === 'done') {
      const tasks = await readTasks(projectDir);
      const overallDone = tasks.filter((t) => t.status === TaskStatus.Done).length;
      const activeBatch = await getActiveBatch(projectDir);
      const batchProgress = activeBatch ? await getBatchProgress(projectDir, activeBatch) : null;

      const msg = formatReviewPassed({
        taskId,
        taskName: contract.name,
        evaluator: contract.evaluator,
        model: evalModel,
        elapsedMs,
        iteration,
        passCount: evalSummary.passCount,
        totalCount: evalSummary.totalCount,
        unlockedTasks: result.unlockedTasks ?? [],
        progress: `${overallDone}/${tasks.length}`,
        batchProgress: batchProgress
          ? `${batchProgress.batch}: ${batchProgress.done}/${batchProgress.total}`
          : undefined,
      });
      await sendMessage(target, msg).catch(() => {});

    } else if (result.action === 'retry') {
      const msg = formatReviewFailed({
        taskId,
        taskName: contract.name,
        evaluator: contract.evaluator,
        model: evalModel,
        iteration,
        passCount: evalSummary.passCount,
        totalCount: evalSummary.totalCount,
        criteriaResults: evalSummary.criteriaResults,
        feedback: evalSummary.feedback,
        autoRetryHint: `自动重试中，第${iteration + 2}次迭代`,
      });
      await sendMessage(target, msg).catch(() => {});

    } else if (result.action === 'escalated') {
      const history = evalSummary.criteriaResults.length > 0
        ? [{ iteration, feedback: evalSummary.feedback, criteriaResults: evalSummary.criteriaResults }]
        : [];
      const msg = formatEscalation({
        taskId,
        taskName: contract.name,
        evaluator: contract.evaluator,
        history,
        retryCommand: `nexum retry ${taskId} --force`,
      });
      await sendMessage(target, msg).catch(() => {});
    }
  }

  // ── Step 4: Auto-dispatch next step ──
  if (result.action === 'retry' && result.retryPayload) {
    try {
      const session = await spawnAcpSession({ ...result.retryPayload, mode: 'run' });
      console.log(`[callback] auto-dispatched retry generator: ${session.sessionKey}`);
    } catch (err) {
      console.warn(`[callback] auto-dispatch retry failed for ${taskId}: ${err instanceof Error ? err.message : err}`);
    }
  }

  if (result.action === 'done') {
    await autoDispatchUnlockedTasks(projectDir, result.unlockedTasks ?? []);
  }

  console.log(JSON.stringify({ ok: true, taskId, role: 'evaluator', verdict, action: result.action }));
}

// ─── Auto-dispatch ───────────────────────────────────────────────────────────

async function autoDispatchUnlockedTasks(projectDir: string, unlockedIds: string[]): Promise<void> {
  if (unlockedIds.length === 0) return;
  const tasks = await readTasks(projectDir);

  for (const id of unlockedIds) {
    const task = tasks.find((t) => t.id === id && t.status === TaskStatus.Pending);
    if (!task) continue;

    try {
      const payload = await runSpawn(id, projectDir);
      const sessionName = `codex-gen-${id}`;
      const session = await spawnAcpSession({ ...payload, agentId: sessionName, mode: 'run' });
      console.log(`[callback] auto-dispatched next generator ${sessionName}: ${session.sessionKey}`);
    } catch (err) {
      console.warn(`[callback] auto-dispatch generator failed for ${id}: ${err instanceof Error ? err.message : err}`);
    }
  }
}

// ─── Eval YAML Parsing ───────────────────────────────────────────────────────

interface CriterionResult { id: string; passed: boolean; reason: string; }
interface EvalSummary { feedback: string; passCount: number; totalCount: number; criteriaResults: CriterionResult[]; }

async function readEvalVerdict(evalResultPath: string): Promise<EvalVerdict> {
  const content = await readFile(evalResultPath, 'utf8');
  const match = content.match(/^\s*verdict:\s*(pass|fail|escalated)\s*(?:#.*)?$/m);
  if (!match?.[1]) throw new Error(`Unable to parse verdict from ${evalResultPath}`);
  return match[1] as EvalVerdict;
}

async function readEvalSummary(evalResultPath: string): Promise<EvalSummary> {
  try {
    const content = await readFile(evalResultPath, 'utf8');
    const feedback = parseYamlScalar(content.match(/^feedback:\s*(.+)$/m)?.[1]);
    const criteriaResults: CriterionResult[] = [];

    const blocks = content.split(/\n\s*-\s*id:\s*/);
    for (const block of blocks.slice(1)) {
      const idMatch = block.match(/^(\S+)/);
      const statusMatch = block.match(/^\s*(?:status|result):\s*(pass|fail)\s*$/m);
      const reason =
        parseYamlScalar(block.match(/^\s*reason:\s*(.+)$/m)?.[1]) ||
        parseYamlScalar(block.match(/^\s*evidence:\s*(.+)$/m)?.[1]) || '';
      if (!idMatch || !statusMatch) continue;
      criteriaResults.push({ id: idMatch[1], passed: statusMatch[1] === 'pass', reason });
    }

    return { feedback, passCount: criteriaResults.filter((c) => c.passed).length, totalCount: criteriaResults.length, criteriaResults };
  } catch {
    return { feedback: '', passCount: 0, totalCount: 0, criteriaResults: [] };
  }
}

function parseYamlScalar(raw: string | undefined): string {
  if (!raw) return '';
  return raw.trim().replace(/^["']|["']$/g, '');
}

// ─── Shared Helpers ──────────────────────────────────────────────────────────

async function loadContract(projectDir: string, contractPath: string) {
  const absPath = path.isAbsolute(contractPath) ? contractPath : path.join(projectDir, contractPath);
  return parseContract(absPath);
}

function resolvePath(projectDir: string, filePath: string): string {
  return path.isAbsolute(filePath) ? filePath : path.join(projectDir, filePath);
}

// ─── CLI ─────────────────────────────────────────────────────────────────────

export function registerCallback(program: Command): void {
  program
    .command('callback <taskId>')
    .description('Process generator/evaluator callback: update status, notify, auto-dispatch')
    .option('--project <dir>', 'Project directory', process.cwd())
    .option('--role <role>', 'generator | evaluator', 'generator')
    .option('--model <name>', 'Model used by generator')
    .option('--input-tokens <n>', 'Input tokens consumed')
    .option('--output-tokens <n>', 'Output tokens consumed')
    .action(async (taskId: string, options: CallbackOptions) => {
      try {
        await runCallback(taskId, options);
      } catch (err) {
        console.error('callback failed:', err instanceof Error ? err.message : err);
        process.exit(1);
      }
    });
}
