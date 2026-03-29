import { readFile } from 'node:fs/promises';
import type { Command } from 'commander';
import { readTasks, TaskStatus } from '@nexum/core';
import { getSessionStatus } from '@nexum/spawn';

/** Read the last N non-empty lines from an ACP stream log JSONL file */
async function getStreamActivity(streamLogPath: string, lines = 2): Promise<string> {
  try {
    const content = await readFile(streamLogPath, 'utf8');
    const entries = content
      .split('\n')
      .filter((l) => l.trim())
      .map((l) => {
        try { return JSON.parse(l) as Record<string, unknown>; } catch { return null; }
      })
      .filter(Boolean) as Record<string, unknown>[];

    const textEntries = entries
      .filter((e) => typeof e.text === 'string' && (e.text as string).trim())
      .slice(-lines);

    if (textEntries.length === 0) return '';
    return textEntries
      .map((e) => (e.text as string).trim().slice(0, 80))
      .join(' / ');
  } catch {
    return '';
  }
}

export async function runStatus(projectDir: string): Promise<void> {
  const tasks = await readTasks(projectDir);

  if (tasks.length === 0) {
    console.log('No tasks found.');
    return;
  }

  const STATUS_ICONS: Record<string, string> = {
    done:       '✅',
    running:    '🔄',
    evaluating: '🔍',
    pending:    '⏳',
    blocked:    '🔒',
    failed:     '🔴',
    escalated:  '🚨',
    cancelled:  '⛔',
  };

  for (const task of tasks) {
    const icon = STATUS_ICONS[task.status] ?? '❓';
    const sessionInfo = task.acp_session_key
      ? ` [${task.acp_session_key.slice(-8)}]`
      : '';

    let activityLine = '';
    const taskExtra = task as unknown as Record<string, unknown>;
    if (
      (task.status === TaskStatus.Running || task.status === TaskStatus.Evaluating) &&
      taskExtra.acp_stream_log
    ) {
      const activity = await getStreamActivity(taskExtra.acp_stream_log as string);
      if (activity) {
        activityLine = `\n    💬 ${activity}`;
      }
    }

    let sessionStatus = '';
    if (task.status === TaskStatus.Running && task.acp_session_key) {
      try {
        const s = await getSessionStatus(task.acp_session_key);
        sessionStatus = s !== 'running' ? ` (ACP: ${s})` : '';
      } catch { /* ignore */ }
    }

    console.log(
      `${icon} ${task.id}  ${task.name.slice(0, 50)}${sessionInfo}${sessionStatus}${activityLine}`
    );
  }

  const done = tasks.filter((t) => t.status === TaskStatus.Done).length;
  console.log(`\n📊 进度: ${done}/${tasks.length} done`);
}

export function registerStatus(program: Command): void {
  program
    .command('status')
    .description('Show status of all tasks with live ACP activity')
    .option('--project <dir>', 'Project directory', process.cwd())
    .action(async (options: { project: string }) => {
      try {
        await runStatus(options.project);
      } catch (err) {
        console.error('status failed:', err instanceof Error ? err.message : err);
        process.exit(1);
      }
    });
}
