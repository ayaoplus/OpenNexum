import { readFile } from 'node:fs/promises';
import path from 'node:path';
import type { Command } from 'commander';
import {
  getTask,
  updateTask,
  TaskStatus,
  loadConfig,
  getHeadCommit,
  parseContract,
  type EvalVerdict,
} from '@nexum/core';
import { sendMessage } from '@nexum/notify';
import { spawnAcpSession } from '@nexum/spawn';
import { runComplete } from './complete.js';

interface CallbackOptions {
  project: string;
  model?: string;
  inputTokens?: string;
  outputTokens?: string;
  role?: 'generator' | 'evaluator';
}

function formatTokens(n: number): string {
  return n.toLocaleString('en-US');
}

export async function runCallback(taskId: string, options: CallbackOptions): Promise<void> {
  const role = options.role ?? 'generator';

  if (role !== 'generator' && role !== 'evaluator') {
    throw new Error(`Invalid role: ${role}. Must be generator or evaluator.`);
  }

  if (role === 'generator') {
    await runGeneratorCallback(taskId, options);
    return;
  }

  await runEvaluatorCallback(taskId, options);
}

async function runGeneratorCallback(taskId: string, options: CallbackOptions): Promise<void> {
  const projectDir = options.project;

  const task = await getTask(projectDir, taskId);
  if (!task) {
    throw new Error(`Task not found: ${taskId}`);
  }

  // Parse token / model info
  const model = options.model?.trim() || '';
  const inputTokens = parseInt(options.inputTokens ?? '0', 10) || 0;
  const outputTokens = parseInt(options.outputTokens ?? '0', 10) || 0;
  const hasTokenInfo = inputTokens > 0 || outputTokens > 0;

  // Check whether generator actually committed (HEAD should differ from base_commit)
  const config = await loadConfig(projectDir).catch(() => ({ notify: undefined, git: undefined }));
  const hasRemote = !!(config.git?.remote);
  const currentHead = await getHeadCommit(projectDir).catch(() => '');
  // Only flag commitMissing when a remote is configured (push is expected)
  const commitMissing = hasRemote
    && task.base_commit
    && currentHead
    && currentHead === task.base_commit;

  // Update task status to GeneratorDone
  await updateTask(projectDir, taskId, {
    status: TaskStatus.GeneratorDone,
    ...(currentHead ? { commit_hash: currentHead } : {}),
  });

  // Send Telegram notification
  const target = config.notify?.target;

  if (target) {
    const lines = commitMissing
      ? [
          '⚠️ Generator 完成，但未检测到新 commit！',
          '━━━━━━━━━━━━━━━',
          `📋 任务内容: ${task.name}`,
          `🆔 任务ID: ${taskId}`,
          `📍 HEAD 仍为: \`${currentHead.slice(0, 7)}\`（与 base_commit 相同）`,
          '❗ 请检查 generator 是否执行了 git commit + push',
        ]
      : [
          '✅ Generator 完成',
          '━━━━━━━━━━━━━━━',
          `📋 任务内容: ${task.name}`,
          `🆔 任务ID: ${taskId}`,
          ...(model ? [`🤖 模型: ${model}`] : []),
          ...(hasTokenInfo ? [`🪙 Token: ${formatTokens(inputTokens)} in / ${formatTokens(outputTokens)} out`] : []),
          '💬 等待编排者触发 eval',
        ];

    await sendMessage(target, lines.join('\n'));
  }

  console.log(JSON.stringify({
    ok: true,
    taskId,
    status: TaskStatus.GeneratorDone,
    commitMissing: !!commitMissing,
    model,
    inputTokens,
    outputTokens,
  }));
}

async function runEvaluatorCallback(taskId: string, options: CallbackOptions): Promise<void> {
  const projectDir = options.project;
  const task = await getTask(projectDir, taskId);
  if (!task) {
    throw new Error(`Task not found: ${taskId}`);
  }

  if (!task.eval_result_path) {
    throw new Error(`Task ${taskId} has no eval_result_path`);
  }

  const contractAbsPath = path.isAbsolute(task.contract_path)
    ? task.contract_path
    : path.join(projectDir, task.contract_path);
  const contract = await parseContract(contractAbsPath);
  const evalResultPath = path.isAbsolute(task.eval_result_path)
    ? task.eval_result_path
    : path.join(projectDir, task.eval_result_path);
  const verdict = await readEvalVerdict(evalResultPath);
  const iteration = task.iteration ?? 0;

  const completeResult =
    verdict === 'pass'
      ? await runComplete(taskId, 'pass', projectDir)
      : verdict === 'fail' && iteration < contract.max_iterations
      ? await runComplete(taskId, 'fail', projectDir)
      : await runComplete(taskId, 'escalated', projectDir);

  let sessionKey: string | null = null;
  if (completeResult.action === 'retry' && completeResult.retryPayload) {
    try {
      const session = await spawnAcpSession({
        ...completeResult.retryPayload,
        mode: 'run',
      });
      sessionKey = session.sessionKey;
    } catch (error) {
      await updateTask(projectDir, taskId, {
        status: TaskStatus.Evaluating,
        iteration,
        eval_result_path: task.eval_result_path,
      });
      throw error;
    }
  }

  console.log(JSON.stringify({
    ok: true,
    taskId,
    role: 'evaluator',
    verdict,
    action: completeResult.action,
    sessionKey,
  }));
}

async function readEvalVerdict(evalResultPath: string): Promise<EvalVerdict> {
  const content = await readFile(evalResultPath, 'utf8');
  const match = content.match(/^\s*verdict:\s*(pass|fail|escalated)\s*(?:#.*)?$/m);
  const verdict = match?.[1] as EvalVerdict | undefined;

  if (!verdict) {
    throw new Error(`Unable to parse verdict from ${evalResultPath}`);
  }

  return verdict;
}

export function registerCallback(program: Command): void {
  program
    .command('callback <taskId>')
    .description('Process generator/evaluator callback and send notification')
    .option('--project <dir>', 'Project directory', process.cwd())
    .option('--role <role>', 'Callback role: generator | evaluator', 'generator')
    .option('--model <name>', 'Model used by generator (e.g. claude-sonnet-4-6)')
    .option('--input-tokens <n>', 'Input token count consumed by generator')
    .option('--output-tokens <n>', 'Output token count consumed by generator')
    .action(async (taskId: string, options: CallbackOptions) => {
      try {
        await runCallback(taskId, options);
      } catch (err) {
        console.error('callback failed:', err instanceof Error ? err.message : err);
        process.exit(1);
      }
    });
}
