import type { Command } from 'commander';
import {
  getTask,
  updateTask,
  readTasks,
  TaskStatus,
  parseContract,
  getHeadCommit,
} from '@nexum/core';
import { formatDispatch, sendMessage } from '@nexum/notify';
import { loadConfig } from '@nexum/core';
import path from 'node:path';
import { acknowledgeDispatchEntries } from '../lib/dispatch-queue.js';
import { resolveContractAgents } from '../lib/resolve-contract-agents.js';

type TrackRole = 'generator' | 'evaluator';

/**
 * track: called by the orchestrator (AI agent) after a runtime session is started.
 * Writes the sessionKey (and optional streamLogPath) to active-tasks.json
 * and sends a Telegram dispatch notification.
 */
export async function runTrack(
  taskId: string,
  sessionKey: string,
  projectDir: string,
  streamLogPath?: string,
  role?: TrackRole
): Promise<void> {
  const task = await getTask(projectDir, taskId);
  if (!task) {
    throw new Error(`Task not found: ${taskId}`);
  }

  const trackedRole = role ?? inferTrackRole(task.status);
  const now = new Date().toISOString();
  const baseCommit =
    trackedRole === 'generator' && !task.base_commit
      ? await getHeadCommit(projectDir).catch(() => '')
      : task.base_commit ?? '';

  await updateTask(projectDir, taskId, {
    status: trackedRole === 'generator' ? TaskStatus.Running : TaskStatus.Evaluating,
    acp_session_key: sessionKey,
    ...(streamLogPath ? { acp_stream_log: streamLogPath } : {}),
    ...(trackedRole === 'generator' ? { started_at: task.started_at ?? now } : {}),
    ...(baseCommit ? { base_commit: baseCommit } : {}),
    updated_at: now,
  });

  await acknowledgeDispatchEntries(projectDir, (entry) => {
    if (entry.taskId !== taskId) {
      return false;
    }

    if (trackedRole === 'evaluator') {
      return entry.action === 'spawn-evaluator';
    }

    return entry.action === 'spawn-retry' || entry.action === 'spawn-next';
  });

  // Send dispatch notification
  const config = await loadConfig(projectDir);
  const target = config.notify?.target;
  if (target) {
    try {
      const contractAbsPath = path.isAbsolute(task.contract_path)
        ? task.contract_path
        : path.join(projectDir, task.contract_path);
      const contract = await parseContract(contractAbsPath);
      const resolvedContract = resolveContractAgents(contract, config);
      const tasks = await readTasks(projectDir);
      const doneCount = tasks.filter((t) => t.status === TaskStatus.Done).length;
      const progress = `${doneCount}/${tasks.length}`;

      const trackedAgentId =
        trackedRole === 'evaluator'
          ? resolvedContract.evaluator
          : resolvedContract.generator;
      const agentConfig = config.agents?.[trackedAgentId];
      const msg = formatDispatch({
        taskId,
        taskName: resolvedContract.name,
        agent: `${trackedAgentId} (${taskId})`,
        model: agentConfig?.model,
        scopeCount: resolvedContract.scope.files.length,
        deliverablesCount: resolvedContract.deliverables.length,
        progress,
      });
      await sendMessage(target, msg);
    } catch {
      // Notification failure is non-fatal
    }
  }

  console.log(JSON.stringify({ ok: true, taskId, sessionKey, streamLogPath: streamLogPath ?? null }));
}

export function registerTrack(program: Command): void {
  program
    .command('track <taskId> <sessionKey>')
    .description('Record runtime session key for a running task (called by orchestrator after spawn)')
    .option('--project <dir>', 'Project directory', process.cwd())
    .option('--role <role>', 'generator | evaluator')
    .option('--stream-log <path>', 'Path to runtime stream log file (if available)')
    .action(async (
      taskId: string,
      sessionKey: string,
      options: { project: string; streamLog?: string; role?: TrackRole }
    ) => {
      try {
        await runTrack(taskId, sessionKey, options.project, options.streamLog, options.role);
      } catch (err) {
        console.error('track failed:', err instanceof Error ? err.message : err);
        process.exit(1);
      }
    });
}

function inferTrackRole(status: TaskStatus): TrackRole {
  return status === TaskStatus.GeneratorDone || status === TaskStatus.Evaluating
    ? 'evaluator'
    : 'generator';
}
