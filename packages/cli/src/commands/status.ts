import { readFile } from 'node:fs/promises';
import type { Command } from 'commander';
import {
  getBatchProgress,
  readTasks,
  TaskStatus,
  type Task,
  NexumError,
} from '@nexum/core';
import { getSessionStatus } from '@nexum/spawn';
import { archiveDoneTasks } from '../lib/archive.js';

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

function getCurrentBatch(tasks: Task[]): string | undefined {
  const batchedTasks = tasks.filter((task): task is Task & { batch: string } => Boolean(task.batch));

  if (batchedTasks.length === 0) {
    return undefined;
  }

  const latestTask = batchedTasks.reduce((latest, task) => {
    if (!latest) {
      return task;
    }

    const latestTime = latest.updated_at ? Date.parse(latest.updated_at) : Number.NEGATIVE_INFINITY;
    const taskTime = task.updated_at ? Date.parse(task.updated_at) : Number.NEGATIVE_INFINITY;

    if (taskTime !== latestTime) {
      return taskTime > latestTime ? task : latest;
    }

    return task.batch.localeCompare(latest.batch) > 0 ? task : latest;
  }, undefined as (Task & { batch: string }) | undefined);

  return latestTask?.batch;
}

export async function runStatus(
  projectDir: string,
  options: { json?: boolean; batch?: string } = {}
): Promise<void> {
  const tasks = await readTasks(projectDir);
  const currentBatch = getCurrentBatch(tasks);
  const visibleTasks =
    options.batch === undefined ? tasks : tasks.filter((task) => task.batch === options.batch);

  if (options.json) {
    const output = visibleTasks.map((task) => ({
      id: task.id,
      name: task.name,
      status: task.status,
      batch: task.batch,
      iteration: task.iteration,
      acp_session_key: task.acp_session_key,
      acp_stream_log: task.acp_stream_log,
    }));
    console.log(JSON.stringify(output, null, 2));
    return;
  }

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

  for (const task of visibleTasks) {
    const icon = STATUS_ICONS[task.status] ?? '❓';
    const sessionInfo = task.acp_session_key
      ? ` [${task.acp_session_key.slice(-8)}]`
      : '';

    let activityLine = '';
    if (
      (task.status === TaskStatus.Running || task.status === TaskStatus.Evaluating) &&
      task.acp_stream_log
    ) {
      const activity = await getStreamActivity(task.acp_stream_log);
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

  const overallDone = tasks.filter((task) => task.status === TaskStatus.Done).length;

  if (currentBatch) {
    const batchProgress = await getBatchProgress(projectDir, currentBatch);
    console.log(`\n📊 当前批次 (${batchProgress.batch}): ${batchProgress.done}/${batchProgress.total}`);
    console.log(`📊 总体: ${overallDone}/${tasks.length}`);
  } else {
    console.log(`\n📊 总体: ${overallDone}/${tasks.length}`);
  }
}

export function registerStatus(program: Command): void {
  program
    .command('status')
    .description('Show status of all tasks with live ACP activity')
    .option('--project <dir>', 'Project directory', process.cwd())
    .option('--batch <name>', 'Filter displayed tasks to one batch')
    .option('--json', 'Output task list as JSON')
    .action(async (options: { project: string; json?: boolean; batch?: string }) => {
      try {
        await runStatus(options.project, { json: options.json, batch: options.batch });
      } catch (err) {
        if (err instanceof NexumError) {
          console.error(`status failed [${err.code}]: ${err.message}`);
        } else {
          console.error('status failed:', err instanceof Error ? err.message : err);
        }
        process.exit(1);
      }
    });

  program
    .command('archive')
    .description('Archive done tasks into nexum/history')
    .option('--project <dir>', 'Project directory', process.cwd())
    .option('--batch <name>', 'Archive done tasks for one batch')
    .action(async (options: { project: string; batch?: string }) => {
      try {
        const result = await archiveDoneTasks(options.project, options.batch);

        if (result.archivedCount === 0) {
          console.log('No done tasks to archive.');
          return;
        }

        console.log(`Archived ${result.archivedCount} task(s) to ${result.archivePath}`);
      } catch (err) {
        console.error('archive failed:', err instanceof Error ? err.message : err);
        process.exit(1);
      }
    });
}
