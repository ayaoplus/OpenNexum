import type { Command } from 'commander';
import { getTask, updateTask, TaskStatus, loadConfig, getHeadCommit } from '@nexum/core';
import { sendMessage } from '@nexum/notify';

interface CallbackOptions {
  project: string;
  model?: string;
  inputTokens?: string;
  outputTokens?: string;
}

function formatTokens(n: number): string {
  return n.toLocaleString('en-US');
}

export async function runCallback(taskId: string, options: CallbackOptions): Promise<void> {
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
  const currentHead = await getHeadCommit(projectDir).catch(() => '');
  const commitMissing = task.base_commit
    && currentHead
    && currentHead === task.base_commit;

  // Update task status to GeneratorDone
  await updateTask(projectDir, taskId, {
    status: TaskStatus.GeneratorDone,
    ...(currentHead ? { commit_hash: currentHead } : {}),
  });

  // Send Telegram notification
  const config = await loadConfig(projectDir).catch(() => ({ notify: undefined }));
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

export function registerCallback(program: Command): void {
  program
    .command('callback <taskId>')
    .description('Mark generator completion and send callback notification')
    .option('--project <dir>', 'Project directory', process.cwd())
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
