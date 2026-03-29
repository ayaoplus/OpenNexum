import type { Command } from 'commander';
import { readTasks, TaskStatus } from '@nexum/core';
import { getSessionStatus } from '@nexum/spawn';

export async function runStatus(projectDir: string): Promise<void> {
  const tasks = await readTasks(projectDir);

  if (tasks.length === 0) {
    console.log('No tasks found.');
    return;
  }

  const rows: Array<{ id: string; name: string; status: string; session: string }> = [];

  for (const task of tasks) {
    let sessionStatus = '-';
    if (task.status === TaskStatus.Running && task.acp_session_key) {
      try {
        sessionStatus = await getSessionStatus(task.acp_session_key);
      } catch {
        sessionStatus = 'error';
      }
    }
    rows.push({
      id: task.id,
      name: task.name.slice(0, 40),
      status: task.status,
      session: sessionStatus,
    });
  }

  const colWidths = {
    id: Math.max(4, ...rows.map((r) => r.id.length)),
    name: Math.max(4, ...rows.map((r) => r.name.length)),
    status: Math.max(6, ...rows.map((r) => r.status.length)),
    session: Math.max(7, ...rows.map((r) => r.session.length)),
  };

  const fmt = (s: string, w: number) => s.padEnd(w);
  const header = [
    fmt('ID', colWidths.id),
    fmt('NAME', colWidths.name),
    fmt('STATUS', colWidths.status),
    fmt('SESSION', colWidths.session),
  ].join('  ');
  const sep = '-'.repeat(header.length);

  console.log(header);
  console.log(sep);
  for (const row of rows) {
    console.log(
      [
        fmt(row.id, colWidths.id),
        fmt(row.name, colWidths.name),
        fmt(row.status, colWidths.status),
        fmt(row.session, colWidths.session),
      ].join('  ')
    );
  }
}

export function registerStatus(program: Command): void {
  program
    .command('status')
    .description('Show status of all tasks')
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
