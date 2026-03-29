import type { Command } from 'commander';
import { readTasks, TaskStatus, loadConfig } from '@nexum/core';
import { getSessionStatus } from '@nexum/spawn';
import { sendMessage } from '@nexum/notify';

const DEFAULT_TIMEOUT_MIN = 30;

export interface StuckTask {
  id: string;
  name: string;
  status: string;
  stuckMinutes: number;
  sessionAlive: boolean | null;
}

export interface HealthResult {
  ok: boolean;
  checked: number;
  stuck: StuckTask[];
  timestamp: string;
}

function minutesSince(iso: string | undefined): number {
  if (!iso) return Infinity;
  return (Date.now() - new Date(iso).getTime()) / 60_000;
}

export async function runHealth(
  projectDir: string,
  opts: { timeoutMin?: number; notify?: boolean; json?: boolean } = {}
): Promise<HealthResult> {
  const timeoutMin = opts.timeoutMin ?? DEFAULT_TIMEOUT_MIN;
  const tasks = await readTasks(projectDir);

  const activeTasks = tasks.filter(
    (t) => t.status === TaskStatus.Running || t.status === TaskStatus.Evaluating
  );

  const stuck: StuckTask[] = [];

  for (const task of activeTasks) {
    const age = minutesSince(task.updated_at ?? task.started_at);
    if (age < timeoutMin) continue;

    // Check if ACP session is still alive
    let sessionAlive: boolean | null = null;
    if (task.acp_session_key) {
      try {
        const s = await getSessionStatus(task.acp_session_key);
        sessionAlive = s === 'running';
      } catch {
        sessionAlive = null;
      }
    }

    stuck.push({
      id: task.id,
      name: task.name,
      status: task.status,
      stuckMinutes: Math.floor(age),
      sessionAlive,
    });
  }

  const result: HealthResult = {
    ok: stuck.length === 0,
    checked: activeTasks.length,
    stuck,
    timestamp: new Date().toISOString(),
  };

  // Send Telegram alert if any stuck tasks found
  if (!result.ok && opts.notify !== false) {
    await sendAlert(projectDir, stuck);
  }

  if (opts.json) {
    console.log(JSON.stringify(result, null, 2));
  } else {
    printHealthReport(result, timeoutMin);
  }

  return result;
}

function printHealthReport(result: HealthResult, timeoutMin: number): void {
  if (result.checked === 0) {
    console.log('✅ 无活跃任务');
    return;
  }

  if (result.ok) {
    console.log(`✅ ${result.checked} 个活跃任务均正常（< ${timeoutMin} min）`);
    return;
  }

  console.log(`⚠️  发现 ${result.stuck.length} 个疑似卡死任务：\n`);
  for (const t of result.stuck) {
    const sessionInfo = t.sessionAlive === null
      ? '（无 session）'
      : t.sessionAlive
        ? 'ACP session 仍在运行'
        : '⚠️ ACP session 已结束';
    console.log(`  🔴 ${t.id}  [${t.status}]  卡住 ${t.stuckMinutes} 分钟  ${sessionInfo}`);
    console.log(`     ${t.name}`);
  }
}

async function sendAlert(projectDir: string, stuck: StuckTask[]): Promise<void> {
  const config = await loadConfig(projectDir).catch(() => ({}));
  const notifyConfig = (config as Record<string, unknown>).notify as Record<string, string> | undefined;
  const chatId = notifyConfig?.target ?? process.env['TELEGRAM_CHAT_ID'];
  const botToken = notifyConfig?.botToken ?? process.env['TELEGRAM_BOT_TOKEN'];
  if (!chatId || !botToken) return;

  const lines = [
    `🚨 Nexum Health Alert — ${stuck.length} 个任务疑似卡死`,
    '━━━━━━━━━━━━━━━',
    ...stuck.map((t) => {
      const sessionTag = t.sessionAlive === true
        ? '（ACP session 仍在运行）'
        : t.sessionAlive === false
          ? '（ACP session 已结束）'
          : '';
      return `🔴 ${t.id} [${t.status}] 已卡 ${t.stuckMinutes} 分钟 ${sessionTag}\n   ${t.name}`;
    }),
    '',
    '请检查任务状态：nexum status --project <dir>',
  ];

  await sendMessage(chatId, lines.join('\n'), botToken);
}

// ---------- watch mode ----------

export async function runWatch(
  projectDir: string,
  opts: { intervalMin?: number; timeoutMin?: number }
): Promise<void> {
  const intervalMin = opts.intervalMin ?? 5;
  const timeoutMin = opts.timeoutMin ?? DEFAULT_TIMEOUT_MIN;
  const intervalMs = intervalMin * 60_000;

  console.log(`👀 nexum watch 启动 (检查间隔: ${intervalMin}min，卡死阈值: ${timeoutMin}min)`);
  console.log(`📁 项目目录: ${projectDir}`);
  console.log('按 Ctrl+C 停止\n');

  const check = async () => {
    const result = await runHealth(projectDir, { timeoutMin, notify: true });
    if (!result.ok) {
      console.log(`[${new Date().toLocaleTimeString()}] ⚠️  ${result.stuck.length} 个卡死任务，已发 Telegram 通知`);
    } else if (result.checked > 0) {
      console.log(`[${new Date().toLocaleTimeString()}] ✅ ${result.checked} 个活跃任务正常`);
    }
  };

  // Run immediately on start
  await check();

  // Then poll on interval
  setInterval(check, intervalMs);

  // Keep alive
  await new Promise<void>(() => { /* intentionally never resolves */ });
}

// ---------- register ----------

export function registerHealth(program: Command): void {
  // nexum health — single check
  program
    .command('health')
    .description('Check for stuck/hung tasks and alert via Telegram if found')
    .option('--project <dir>', 'Project directory', process.cwd())
    .option('--timeout <min>', 'Minutes before a task is considered stuck', String(DEFAULT_TIMEOUT_MIN))
    .option('--no-notify', 'Skip Telegram notification even if stuck tasks found')
    .option('--json', 'Output result as JSON')
    .action(async (options: { project: string; timeout: string; notify: boolean; json?: boolean }) => {
      try {
        const result = await runHealth(options.project, {
          timeoutMin: parseInt(options.timeout, 10),
          notify: options.notify,
          json: options.json,
        });
        process.exit(result.ok ? 0 : 1);
      } catch (err) {
        console.error('health check failed:', err instanceof Error ? err.message : err);
        process.exit(2);
      }
    });

  // nexum watch — daemon mode
  program
    .command('watch')
    .description('Run continuous health checks in the background (daemon mode)')
    .option('--project <dir>', 'Project directory', process.cwd())
    .option('--interval <min>', 'Check interval in minutes (default: 5)', '5')
    .option('--timeout <min>', `Minutes before task is considered stuck (default: ${DEFAULT_TIMEOUT_MIN})`, String(DEFAULT_TIMEOUT_MIN))
    .action(async (options: { project: string; interval: string; timeout: string }) => {
      try {
        await runWatch(options.project, {
          intervalMin: parseInt(options.interval, 10),
          timeoutMin: parseInt(options.timeout, 10),
        });
      } catch (err) {
        console.error('watch failed:', err instanceof Error ? err.message : err);
        process.exit(1);
      }
    });
}
