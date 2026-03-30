import type { Command } from 'commander';
import { readTasks, TaskStatus, loadConfig } from '@nexum/core';
import { getSessionStatus } from '@nexum/spawn';
import { sendMessage } from '@nexum/notify';
import {
  readGlobalConfig,
  addProject,
  removeProject,
  globalConfigPath,
} from '../lib/global-config.js';
import { installDaemon, uninstallDaemon, getDaemonStatus } from '../lib/daemon.js';

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
    const sessionInfo =
      t.sessionAlive === null
        ? '（无 session）'
        : t.sessionAlive
        ? 'ACP session 仍在运行'
        : '⚠️ ACP session 已结束';
    console.log(`  🔴 ${t.id}  [${t.status}]  卡住 ${t.stuckMinutes} 分钟  ${sessionInfo}`);
    console.log(`     ${t.name}`);
  }
}

async function sendAlert(projectDir: string, stuck: StuckTask[]): Promise<void> {
  const config = await loadConfig(projectDir).catch(() => ({ notify: undefined }));
  const target = config.notify?.target;
  if (!target) return;

  const lines = [
    `🚨 Nexum Health Alert — ${stuck.length} 个任务疑似卡死`,
    '━━━━━━━━━━━━━━━',
    ...stuck.map((t) => {
      const sessionTag =
        t.sessionAlive === true
          ? '（ACP session 仍在运行）'
          : t.sessionAlive === false
          ? '（ACP session 已结束）'
          : '';
      return `🔴 ${t.id} [${t.status}] 已卡 ${t.stuckMinutes} 分钟 ${sessionTag}\n   ${t.name}`;
    }),
    '',
    '请检查任务状态：nexum status --project <dir>',
  ];

  await sendMessage(target, lines.join('\n'));
}

// ---------- watch loop (polls all global projects) ----------

export async function runWatch(opts: { intervalMin?: number; timeoutMin?: number } = {}): Promise<void> {
  const globalCfg = await readGlobalConfig();
  const intervalMin = opts.intervalMin ?? globalCfg.watch.intervalMin;
  const timeoutMin = opts.timeoutMin ?? globalCfg.watch.timeoutMin;
  const intervalMs = intervalMin * 60_000;

  console.log(`👀 nexum watch 启动 (检查间隔: ${intervalMin}min，卡死阈值: ${timeoutMin}min)`);
  console.log(`📋 全局配置: ${globalConfigPath()}`);
  console.log('按 Ctrl+C 停止\n');

  const check = async () => {
    const cfg = await readGlobalConfig();
    const projects = cfg.projects;

    if (projects.length === 0) {
      console.log(
        `[${new Date().toLocaleTimeString()}] ℹ️  无监控项目，使用 'nexum watch add-project <dir>' 添加`
      );
      return;
    }

    for (const projectDir of projects) {
      try {
        const result = await runHealth(projectDir, { timeoutMin, notify: true, json: false });
        const tag = `[${new Date().toLocaleTimeString()}] [${projectDir}]`;
        if (!result.ok) {
          console.log(`${tag} ⚠️  ${result.stuck.length} 个卡死任务，已发通知`);
        } else if (result.checked > 0) {
          console.log(`${tag} ✅ ${result.checked} 个活跃任务正常`);
        }
      } catch (err) {
        console.warn(
          `[${new Date().toLocaleTimeString()}] ⚠️  检查 ${projectDir} 失败: ${err instanceof Error ? err.message : err}`
        );
      }
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

  // nexum watch — parent command + subcommands
  const watchCmd = program
    .command('watch')
    .description('Manage the nexum watch daemon (global multi-project health monitoring)')
    .option('--interval <min>', 'Check interval in minutes', '5')
    .option('--timeout <min>', `Stuck task threshold in minutes (default: ${DEFAULT_TIMEOUT_MIN})`, String(DEFAULT_TIMEOUT_MIN))
    .action(async (options: { interval: string; timeout: string }) => {
      try {
        await runWatch({
          intervalMin: parseInt(options.interval, 10),
          timeoutMin: parseInt(options.timeout, 10),
        });
      } catch (err) {
        console.error('watch failed:', err instanceof Error ? err.message : err);
        process.exit(1);
      }
    });

  // nexum watch install
  watchCmd
    .command('install')
    .description('Install nexum watch as a system daemon and register the current project')
    .option('--project <dir>', 'Project directory to add', process.cwd())
    .action(async (options: { project: string }) => {
      try {
        await installDaemon();
        await addProject(options.project);
        console.log(`✓ Project added to watch list: ${options.project}`);
      } catch (err) {
        console.error('watch install failed:', err instanceof Error ? err.message : err);
        process.exit(1);
      }
    });

  // nexum watch uninstall
  watchCmd
    .command('uninstall')
    .description('Uninstall the nexum watch daemon')
    .action(async () => {
      try {
        await uninstallDaemon();
      } catch (err) {
        console.error('watch uninstall failed:', err instanceof Error ? err.message : err);
        process.exit(1);
      }
    });

  // nexum watch add-project <dir>
  watchCmd
    .command('add-project <dir>')
    .description('Add a project directory to the global watch list')
    .action(async (dir: string) => {
      try {
        await addProject(dir);
        console.log(`✓ Added: ${dir}`);
        const status = await getDaemonStatus();
        if (status === 'running') {
          console.log('  守护进程正在运行，新项目将在下次检查周期生效。');
        }
      } catch (err) {
        console.error('add-project failed:', err instanceof Error ? err.message : err);
        process.exit(1);
      }
    });

  // nexum watch remove-project <dir>
  watchCmd
    .command('remove-project <dir>')
    .description('Remove a project directory from the global watch list')
    .action(async (dir: string) => {
      try {
        await removeProject(dir);
        console.log(`✓ Removed: ${dir}`);
      } catch (err) {
        console.error('remove-project failed:', err instanceof Error ? err.message : err);
        process.exit(1);
      }
    });

  // nexum watch list
  watchCmd
    .command('list')
    .description('List all projects in the global watch list')
    .action(async () => {
      try {
        const cfg = await readGlobalConfig();
        if (cfg.projects.length === 0) {
          console.log('监控项目列表为空。使用 nexum watch add-project <dir> 添加项目。');
          return;
        }
        console.log(`监控项目列表（${cfg.projects.length} 个）：`);
        for (const p of cfg.projects) {
          console.log(`  ${p}`);
        }
      } catch (err) {
        console.error('watch list failed:', err instanceof Error ? err.message : err);
        process.exit(1);
      }
    });

  // nexum watch status
  watchCmd
    .command('status')
    .description('Show the current status of the nexum watch daemon')
    .action(async () => {
      try {
        const status = await getDaemonStatus();
        const cfg = await readGlobalConfig();
        const statusLabel: Record<typeof status, string> = {
          running: '🟢 运行中 (running)',
          stopped: '🔴 已停止 (stopped)',
          not_installed: '⚪ 未安装 (not installed)',
          unsupported: '⚠️  不支持 (unsupported on this OS)',
        };
        console.log(`守护进程状态: ${statusLabel[status]}`);
        console.log(`监控项目数: ${cfg.projects.length}`);
        console.log(`全局配置: ${globalConfigPath()}`);
        if (status === 'not_installed') {
          console.log('\n使用 nexum watch install 安装守护进程。');
        }
      } catch (err) {
        console.error('watch status failed:', err instanceof Error ? err.message : err);
        process.exit(1);
      }
    });
}
