import { access } from 'node:fs/promises';
import path from 'node:path';
import type { Command } from 'commander';
import { readTasks, TaskStatus, loadConfig } from '@nexum/core';
import { getSessionStatus } from '@nexum/spawn';
import { sendMessage, formatHealthAlert } from '@nexum/notify';
import {
  resolveWebhookAgentEndpoint,
  resolveWebhookToken,
  summarizeResponse,
} from './callback.js';
import {
  readGlobalConfig,
  addProject,
  removeProject,
  globalConfigPath,
} from '../lib/global-config.js';
import { installDaemon, uninstallDaemon, getDaemonStatus } from '../lib/daemon.js';

const DEFAULT_TIMEOUT_MIN = 30;

// ─── Types ───────────────────────────────────────────────────────────────────

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

// ─── Health Check (single project) ───────────────────────────────────────────

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
  const config = await loadConfig(projectDir).catch(() => ({ notify: undefined, webhook: undefined }));
  const target = config.notify?.target;
  if (target) {
    const msg = formatHealthAlert(stuck);
    await sendMessage(target, msg);
  }

  const token = await resolveWebhookToken(config);
  if (!token) return;

  const endpoint = resolveWebhookAgentEndpoint(config);
  const taskIds = stuck.map((task) => task.id).join(', ');
  const payload = {
    message: `nexum-health-alert: ${projectDir} stuck tasks: ${taskIds}`,
    name: 'Nexum',
    agentId: 'main',
    deliver: false,
  };

  try {
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
        `[health] webhook alert failed for ${projectDir}: ${response.status} ${response.statusText}${details ? ` - ${details}` : ''}`
      );
    }
  } catch (err) {
    console.warn(`[health] webhook alert failed for ${projectDir}: ${err instanceof Error ? err.message : err}`);
  }
}

// ─── Watch (daemon mode, health-only, no dispatch) ───────────────────────────
//
// Watch ONLY does:
//   - Periodic health checks across all global projects
//   - Alert on stuck tasks
//
// Dispatch is handled by callback.ts (event-driven, not polling).

export async function runWatch(opts: { intervalMin?: number; timeoutMin?: number } = {}): Promise<void> {
  const globalCfg = await readGlobalConfig();
  const intervalMin = opts.intervalMin ?? globalCfg.watch.intervalMin;
  const timeoutMin = opts.timeoutMin ?? globalCfg.watch.timeoutMin;
  const intervalMs = intervalMin * 60_000;

  console.log(`👀 nexum watch 启动 (检查间隔: ${intervalMin}min，卡死阈值: ${timeoutMin}min)`);
  console.log(`📋 全局配置: ${globalConfigPath()}`);
  console.log('📝 Watch 只做卡死检测。Dispatch 由 callback 事件驱动。');
  console.log('按 Ctrl+C 停止\n');

  const check = async () => {
    const cfg = await readGlobalConfig();
    const projects = cfg.projects;

    if (projects.length === 0) {
      console.log(`[${ts()}] ℹ️  无监控项目，使用 'nexum watch add-project <dir>' 添加`);
      return;
    }

    for (const projectDir of projects) {
      try {
        const result = await runHealth(projectDir, { timeoutMin, notify: true });
        const tag = `[${ts()}] [${path.basename(projectDir)}]`;
        if (!result.ok) {
          console.log(`${tag} ⚠️  ${result.stuck.length} 个卡死任务，已发通知`);
        } else if (result.checked > 0) {
          console.log(`${tag} ✅ ${result.checked} 个活跃任务正常`);
        }
      } catch (err) {
        console.warn(`[${ts()}] ⚠️  检查 ${projectDir} 失败: ${err instanceof Error ? err.message : err}`);
      }
    }
  };

  await check();
  setInterval(check, intervalMs);
  await new Promise<void>(() => {});
}

function ts(): string {
  return new Date().toLocaleTimeString();
}

// ─── CLI Registration ────────────────────────────────────────────────────────

export function registerHealth(program: Command): void {
  program
    .command('health')
    .description('Check for stuck/hung tasks and alert via Telegram')
    .option('--project <dir>', 'Project directory', process.cwd())
    .option('--timeout <min>', 'Minutes before stuck', String(DEFAULT_TIMEOUT_MIN))
    .option('--no-notify', 'Skip notification')
    .option('--json', 'JSON output')
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

  const watchCmd = program
    .command('watch')
    .description('Health monitoring daemon (卡死检测 only, dispatch by callback)')
    .option('--interval <min>', 'Check interval', '5')
    .option('--timeout <min>', 'Stuck threshold', String(DEFAULT_TIMEOUT_MIN))
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

  watchCmd.command('install')
    .description('Install watch daemon')
    .option('--project <dir>', 'Project to add', process.cwd())
    .action(async (options: { project: string }) => {
      try {
        await installDaemon();
        await addProject(options.project);
        console.log(`✓ Project added: ${options.project}`);
      } catch (err) {
        console.error('install failed:', err instanceof Error ? err.message : err);
        process.exit(1);
      }
    });

  watchCmd.command('uninstall')
    .description('Uninstall watch daemon')
    .action(async () => {
      try { await uninstallDaemon(); }
      catch (err) { console.error('uninstall failed:', err instanceof Error ? err.message : err); process.exit(1); }
    });

  watchCmd.command('add-project <dir>')
    .description('Add project to watch list')
    .action(async (dir: string) => {
      try {
        await addProject(dir);
        console.log(`✓ Added: ${dir}`);
      } catch (err) {
        console.error('add failed:', err instanceof Error ? err.message : err);
        process.exit(1);
      }
    });

  watchCmd.command('remove-project <dir>')
    .description('Remove project from watch list')
    .action(async (dir: string) => {
      try {
        await removeProject(dir);
        console.log(`✓ Removed: ${dir}`);
      } catch (err) {
        console.error('remove failed:', err instanceof Error ? err.message : err);
        process.exit(1);
      }
    });

  watchCmd.command('list')
    .description('List watched projects')
    .action(async () => {
      try {
        const cfg = await readGlobalConfig();
        if (cfg.projects.length === 0) { console.log('无监控项目。'); return; }
        console.log(`监控项目（${cfg.projects.length} 个）：`);
        for (const p of cfg.projects) console.log(`  ${p}`);
      } catch (err) {
        console.error('list failed:', err instanceof Error ? err.message : err);
        process.exit(1);
      }
    });

  watchCmd.command('status')
    .description('Daemon status')
    .action(async () => {
      try {
        const status = await getDaemonStatus();
        const cfg = await readGlobalConfig();
        const labels: Record<string, string> = {
          running: '🟢 运行中', stopped: '🔴 已停止',
          not_installed: '⚪ 未安装', unsupported: '⚠️ 不支持',
        };
        console.log(`守护进程: ${labels[status] ?? status}`);
        console.log(`监控项目: ${cfg.projects.length}`);
        console.log(`配置: ${globalConfigPath()}`);
        if (status === 'not_installed') console.log('\n使用 nexum watch install 安装。');
      } catch (err) {
        console.error('status failed:', err instanceof Error ? err.message : err);
        process.exit(1);
      }
    });
}
