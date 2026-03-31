import { readFile, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
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
  parseEvalResult,
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
import { runComplete } from './complete.js';
import { runSpawn, runSpawnEval } from './spawn.js';

const execFileAsync = promisify(execFile);
const DEFAULT_WEBHOOK_GATEWAY_URL = 'http://127.0.0.1:18789';
const WEBHOOK_AGENT_PATH = 'hooks/agent';

// ─── Types ───────────────────────────────────────────────────────────────────

interface CallbackOptions {
  project: string;
  model?: string;
  inputTokens?: string;
  outputTokens?: string;
  role?: 'generator' | 'evaluator';
}

type DispatchRole = 'generator' | 'evaluator';
type ContractWithAgentCompat = {
  generator: string;
  evaluator: string;
  agent?: {
    generator?: string;
    evaluator?: string;
  };
};

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
  if (reportedModel && !['codex', 'claude', 'auto'].includes(reportedModel.toLowerCase())) {
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

async function dispatchViaWebhook(taskId: string, role: DispatchRole, projectDir: string): Promise<boolean> {
  try {
    const config = await loadConfig(projectDir).catch(() => ({ webhook: undefined } as NexumConfig));
    const token = await resolveWebhookToken(config);

    if (!token) {
      console.warn(`[callback] webhook dispatch skipped for ${taskId}: no hooks token configured`);
      return false;
    }

    const endpoint = new URL(
      WEBHOOK_AGENT_PATH,
      withTrailingSlash(config.webhook?.gatewayUrl?.trim() || DEFAULT_WEBHOOK_GATEWAY_URL)
    ).toString();
    const payload = {
      message: `nexum-dispatch: ${taskId} ${role} ${projectDir}`,
      name: 'Nexum',
      agentId: 'main',
      deliver: false,
    };

    const response = await fetch(endpoint, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(payload),
    });

    if (!response.ok) {
      const details = summarizeResponse(await response.text().catch(() => ''));
      console.warn(
        `[callback] webhook dispatch failed for ${taskId}: ${response.status} ${response.statusText}${details ? ` - ${details}` : ''}`
      );
      return false;
    }

    return true;
  } catch (err) {
    console.warn(`[callback] webhook dispatch failed for ${taskId}: ${err instanceof Error ? err.message : err}`);
    return false;
  }
}

// ─── Dispatch Queue (heartbeat fallback) ─────────────────────────────────────

type DispatchAction = 'spawn-evaluator' | 'spawn-retry' | 'spawn-next';

interface DispatchQueueEntry {
  taskId: string;
  action: DispatchAction;
  projectDir: string;
  createdAt: string;
}

async function writeDispatchQueue(taskId: string, action: DispatchAction, projectDir: string): Promise<void> {
  try {
    const queuePath = path.join(projectDir, 'nexum', 'dispatch-queue.jsonl');
    const existingContents = await readFile(queuePath, 'utf8').catch((err: NodeJS.ErrnoException) => {
      if (err.code === 'ENOENT') {
        return '';
      }
      throw err;
    });
    const existingLines = existingContents
      .split('\n')
      .map((line) => line.trim())
      .filter((line) => line.length > 0);
    const existingEntries = existingLines.map(
      (line) => JSON.parse(line) as DispatchQueueEntry
    );

    if (existingEntries.some((entry) => entry.taskId === taskId && entry.action === action)) {
      console.warn(`[callback] dispatch queue entry already exists for ${taskId} (${action}), skipping append`);
      return;
    }

    const entry: DispatchQueueEntry = {
      taskId,
      action,
      projectDir,
      createdAt: new Date().toISOString(),
    };
    existingLines.push(JSON.stringify(entry));
    await writeFile(queuePath, `${existingLines.join('\n')}\n`, 'utf8');
  } catch (err) {
    console.warn(`[callback] failed to write dispatch queue: ${err instanceof Error ? err.message : err}`);
  }
}

// ─── Webhook Token Resolution ────────────────────────────────────────────────

async function resolveWebhookToken(config: NexumConfig): Promise<string | undefined> {
  const envToken = process.env.OPENCLAW_HOOKS_TOKEN?.trim();
  if (envToken) {
    return envToken;
  }

  const configToken = config.webhook?.token?.trim();
  if (configToken) {
    return configToken;
  }

  return readOpenClawHooksToken();
}

async function readOpenClawHooksToken(): Promise<string | undefined> {
  const openClawConfigPath = path.join(homedir(), '.openclaw', 'openclaw.json');

  try {
    const contents = await readFile(openClawConfigPath, 'utf8');
    const parsed = JSON.parse(contents) as { hooks?: { token?: unknown } };
    const token = parsed.hooks?.token;
    return typeof token === 'string' && token.trim() ? token.trim() : undefined;
  } catch {
    return undefined;
  }
}

function withTrailingSlash(url: string): string {
  return url.endsWith('/') ? url : `${url}/`;
}

function summarizeResponse(body: string): string {
  const normalized = body.trim().replace(/\s+/g, ' ');
  if (!normalized) {
    return '';
  }
  return normalized.length > 200 ? `${normalized.slice(0, 197)}...` : normalized;
}

function getGeneratorAgentId(contract: ContractWithAgentCompat): string {
  return contract.agent?.generator ?? contract.generator;
}

function getEvaluatorAgentId(contract: ContractWithAgentCompat): string {
  return contract.agent?.evaluator ?? contract.evaluator;
}

// ─── Generator Callback ──────────────────────────────────────────────────────

async function runGeneratorCallback(taskId: string, options: CallbackOptions): Promise<void> {
  const projectDir = options.project;
  const task = await getTask(projectDir, taskId);
  if (!task) throw new Error(`Task not found: ${taskId}`);

  const contract = await loadContract(projectDir, task.contract_path);
  const config = await loadConfig(projectDir).catch(() => ({ notify: undefined, git: undefined } as NexumConfig));
  const generatorAgentId = getGeneratorAgentId(contract);

  const inputTokens = parseInt(options.inputTokens ?? '0', 10) || 0;
  const outputTokens = parseInt(options.outputTokens ?? '0', 10) || 0;
  const model = resolveModelName(config, generatorAgentId, options.model);

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
          agent: generatorAgentId,
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
  await writeDispatchQueue(taskId, 'spawn-evaluator', projectDir);
  try {
    await runSpawnEval(taskId, projectDir);
    const evalSessionName = `claude-eval-${taskId}`;
    const dispatched = await dispatchViaWebhook(taskId, 'evaluator', projectDir);
    if (dispatched) {
      console.log(`[callback] auto-dispatched evaluator ${evalSessionName} via webhook`);
    }
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
  const evaluatorAgentId = getEvaluatorAgentId(contract);

  const evalResultPath = resolvePath(projectDir, task.eval_result_path);
  const verdict = await readEvalVerdict(evalResultPath);
  const evalSummary = await parseEvalResult(evalResultPath);
  const iteration = task.iteration ?? 0;
  const startedAt = task.started_at ? new Date(task.started_at).getTime() : Date.now();
  const elapsedMs = Date.now() - startedAt;
  const evalModel = resolveModelName(config, evaluatorAgentId);

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
        evaluator: evaluatorAgentId,
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
        evaluator: evaluatorAgentId,
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
        evaluator: evaluatorAgentId,
        history,
        retryCommand: `nexum retry ${taskId} --force`,
      });
      await sendMessage(target, msg).catch(() => {});
    }
  }

  // ── Step 4: Auto-dispatch next step ──
  if (result.action === 'retry' && result.retryPayload) {
    await writeDispatchQueue(taskId, 'spawn-retry', projectDir);
    try {
      const dispatched = await dispatchViaWebhook(taskId, 'generator', projectDir);
      if (dispatched) {
        console.log(`[callback] auto-dispatched retry generator for ${taskId} via webhook`);
      }
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

    await writeDispatchQueue(id, 'spawn-next', projectDir);
    try {
      await runSpawn(id, projectDir);
      const sessionName = `codex-gen-${id}`;
      const dispatched = await dispatchViaWebhook(id, 'generator', projectDir);
      if (dispatched) {
        console.log(`[callback] auto-dispatched next generator ${sessionName} via webhook`);
      }
    } catch (err) {
      console.warn(`[callback] auto-dispatch generator failed for ${id}: ${err instanceof Error ? err.message : err}`);
    }
  }
}

async function readEvalVerdict(evalResultPath: string): Promise<EvalVerdict> {
  const content = await readFile(evalResultPath, 'utf8');
  const match = content.match(/^\s*verdict:\s*(pass|fail|escalated)\s*(?:#.*)?$/m);
  if (!match?.[1]) throw new Error(`Unable to parse verdict from ${evalResultPath}`);
  return match[1] as EvalVerdict;
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
