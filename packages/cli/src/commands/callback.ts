import { readFile } from 'node:fs/promises';
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
} from '@nexum/core';
import {
  formatGeneratorDone,
  formatComplete,
  formatReviewFailed,
  formatEscalation,
  sendMessage,
} from '@nexum/notify';
import { spawnAcpSession } from '@nexum/spawn';
import { runComplete } from './complete.js';
import { runSpawn, runSpawnEval } from './spawn.js';

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

// ─── Generator Callback ──────────────────────────────────────────────────────
//
// Called when a generator (coding agent) finishes its work.
// Steps:
//   1. Update task status → generator_done
//   2. Send notification (code submitted)
//   3. Auto-dispatch evaluator (best-effort)

async function runGeneratorCallback(taskId: string, options: CallbackOptions): Promise<void> {
  const projectDir = options.project;
  const task = await getTask(projectDir, taskId);
  if (!task) throw new Error(`Task not found: ${taskId}`);

  const contract = await loadContract(projectDir, task.contract_path);
  const config = await loadConfig(projectDir).catch(() => ({ notify: undefined, git: undefined }));

  // Parse optional metadata from generator
  const model = options.model?.trim() || '';
  const inputTokens = parseInt(options.inputTokens ?? '0', 10) || 0;
  const outputTokens = parseInt(options.outputTokens ?? '0', 10) || 0;

  // Check commit status
  const currentHead = await getHeadCommit(projectDir).catch(() => '');
  const hasRemote = !!(config.git?.remote);
  const commitMissing = hasRemote && task.base_commit && currentHead && currentHead === task.base_commit;

  // ── Step 1: Update status ──
  await updateTask(projectDir, taskId, {
    status: TaskStatus.GeneratorDone,
    ...(currentHead ? { commit_hash: currentHead } : {}),
  });

  // ── Step 2: Notify ──
  const target = config.notify?.target;
  if (target) {
    const msg = commitMissing
      ? [
          '⚠️ Generator 完成，但未检测到新 commit！',
          '━━━━━━━━━━━━━━━',
          `📋 任务: ${task.name}`,
          `🆔 ID: ${taskId}`,
          `📍 HEAD: \`${currentHead.slice(0, 7)}\`（与 base_commit 相同）`,
          '❗ 请检查 generator 是否执行了 git commit + push',
        ].join('\n')
      : formatGeneratorDone(taskId, task.name, contract.generator, {
          model,
          inputTokens,
          outputTokens,
          commitHash: currentHead,
          iteration: task.iteration,
          scopeFiles: contract.scope.files,
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
//
// Called when an evaluator finishes reviewing code.
// Steps:
//   1. Read eval result (pass/fail/escalated)
//   2. Run complete → updates status, triggers retry/unlock
//   3. Send notification (appropriate for verdict)
//   4. Auto-dispatch next step (retry generator or next pending task)

async function runEvaluatorCallback(taskId: string, options: CallbackOptions): Promise<void> {
  const projectDir = options.project;
  const task = await getTask(projectDir, taskId);
  if (!task) throw new Error(`Task not found: ${taskId}`);
  if (!task.eval_result_path) throw new Error(`Task ${taskId} has no eval_result_path`);

  const contract = await loadContract(projectDir, task.contract_path);
  const config = await loadConfig(projectDir).catch(() => ({ notify: undefined }));
  const target = config.notify?.target;

  const evalResultPath = resolvePath(projectDir, task.eval_result_path);
  const verdict = await readEvalVerdict(evalResultPath);
  const evalSummary = await readEvalSummary(evalResultPath);
  const iteration = task.iteration ?? 0;
  const startedAt = task.started_at ? new Date(task.started_at).getTime() : Date.now();
  const elapsedMs = Date.now() - startedAt;

  // ── Step 1+2: Run complete (status update + unlock/retry/escalate) ──
  const result = await runComplete(taskId, verdict, projectDir);

  // ── Step 3: Notify (covers ALL scenarios) ──
  if (target) {
    if (result.action === 'done') {
      // ✅ Pass
      const tasks = await readTasks(projectDir);
      const overallDone = tasks.filter((t) => t.status === TaskStatus.Done).length;
      const activeBatch = await getActiveBatch(projectDir);
      const batchProgress = activeBatch ? await getBatchProgress(projectDir, activeBatch) : null;
      const progressStr = batchProgress
        ? `${batchProgress.batch}: ${batchProgress.done}/${batchProgress.total}  |  总体: ${overallDone}/${tasks.length}`
        : `${overallDone}/${tasks.length}`;

      const msg = formatComplete(taskId, contract.name, elapsedMs, iteration,
        evalSummary.passCount, evalSummary.totalCount,
        result.unlockedTasks ?? [], progressStr,
        { evaluatorName: contract.evaluator });
      await sendMessage(target, msg).catch(() => {});

    } else if (result.action === 'retry') {
      // ❌ Fail → retry
      const msg = formatReviewFailed(taskId, contract.name, iteration,
        evalSummary.passCount, evalSummary.totalCount,
        evalSummary.criteriaResults, evalSummary.feedback,
        { evaluatorName: contract.evaluator, autoRetryHint: `自动重试中，第${(iteration + 2)}次迭代` });
      await sendMessage(target, msg).catch(() => {});

    } else if (result.action === 'escalated') {
      // 🚨 Escalated
      const history = evalSummary.criteriaResults.length > 0
        ? [{ iteration, feedback: evalSummary.feedback, criteriaResults: evalSummary.criteriaResults }]
        : [];
      const msg = formatEscalation(taskId, contract.name, history,
        `nexum retry ${taskId} --force`,
        { evaluatorName: contract.evaluator });
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

// ─── Auto-dispatch Helpers ───────────────────────────────────────────────────

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

// ─── Eval YAML Parsing (unified) ─────────────────────────────────────────────

interface CriterionResult {
  id: string;
  passed: boolean;
  reason: string;
}

interface EvalSummary {
  feedback: string;
  passCount: number;
  totalCount: number;
  criteriaResults: CriterionResult[];
}

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

    const criteriaBlocks = content.split(/\n\s*-\s*id:\s*/);
    for (const block of criteriaBlocks.slice(1)) {
      const idMatch = block.match(/^(\S+)/);
      const statusMatch = block.match(/^\s*(?:status|result):\s*(pass|fail)\s*$/m);
      const reason =
        parseYamlScalar(block.match(/^\s*reason:\s*(.+)$/m)?.[1]) ||
        parseYamlScalar(block.match(/^\s*evidence:\s*(.+)$/m)?.[1]) || '';

      if (!idMatch || !statusMatch) continue;

      criteriaResults.push({
        id: idMatch[1],
        passed: statusMatch[1] === 'pass',
        reason,
      });
    }

    const passCount = criteriaResults.filter((c) => c.passed).length;

    return {
      feedback,
      passCount,
      totalCount: criteriaResults.length,
      criteriaResults,
    };
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
  const absPath = path.isAbsolute(contractPath)
    ? contractPath
    : path.join(projectDir, contractPath);
  return parseContract(absPath);
}

function resolvePath(projectDir: string, filePath: string): string {
  return path.isAbsolute(filePath) ? filePath : path.join(projectDir, filePath);
}

// ─── CLI Registration ────────────────────────────────────────────────────────

export function registerCallback(program: Command): void {
  program
    .command('callback <taskId>')
    .description('Process generator/evaluator callback: update status, notify, and auto-dispatch next step')
    .option('--project <dir>', 'Project directory', process.cwd())
    .option('--role <role>', 'Callback role: generator | evaluator', 'generator')
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
