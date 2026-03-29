import type { Command } from 'commander';
import { getTask, updateTask, TaskStatus, loadConfig, getHeadCommit } from '@nexum/core';
import { sendMessage } from '@nexum/notify';

export async function runCallback(taskId: string, projectDir: string): Promise<void> {
  const task = await getTask(projectDir, taskId);
  if (!task) {
    throw new Error(`Task not found: ${taskId}`);
  }

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
  const config = await loadConfig(projectDir).catch(() => ({}));
  const notifyConfig = (config as Record<string, unknown>).notify as Record<string, string> | undefined;
  const chatId = notifyConfig?.target ?? process.env['TELEGRAM_CHAT_ID'];
  const botToken = notifyConfig?.botToken ?? process.env['TELEGRAM_BOT_TOKEN'];

  if (chatId && botToken) {
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
          '💬 等待编排者触发 eval',
        ];

    await sendMessage(chatId, lines.join('\n'), botToken);
  }

  console.log(JSON.stringify({ ok: true, taskId, status: TaskStatus.GeneratorDone, commitMissing: !!commitMissing }));
}

export function registerCallback(program: Command): void {
  program
    .command('callback <taskId>')
    .description('Mark generator completion and send callback notification')
    .option('--project <dir>', 'Project directory', process.cwd())
    .action(async (taskId: string, options: { project: string }) => {
      try {
        await runCallback(taskId, options.project);
      } catch (err) {
        console.error('callback failed:', err instanceof Error ? err.message : err);
        process.exit(1);
      }
    });
}
