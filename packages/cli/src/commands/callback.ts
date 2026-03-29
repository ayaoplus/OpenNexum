import { execFile } from "node:child_process";
import path from "node:path";
import type { Command } from 'commander';
import { getTask, updateTask, TaskStatus, loadConfig, parseContract, commitFiles, getHeadCommit } from '@nexum/core';
import { sendMessage } from '@nexum/notify';

// ---------- git push ----------

async function gitPush(projectDir: string): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    execFile(
      "git",
      ["-C", projectDir, "push", "-u", "origin", "HEAD"],
      (error, _stdout, stderr) => {
        if (error) {
          reject(new Error(`git push failed: ${stderr || error.message}`));
          return;
        }
        resolve();
      }
    );
  });
}

// ---------- changed files from scope ----------

async function getChangedFiles(projectDir: string): Promise<string[]> {
  return new Promise<string[]>((resolve, reject) => {
    execFile(
      "git",
      ["-C", projectDir, "diff", "--name-only", "HEAD"],
      (error, stdout, stderr) => {
        if (error) {
          // No changes or error — treat as empty
          resolve([]);
          return;
        }
        resolve(
          stdout
            .split("\n")
            .map((l) => l.trim())
            .filter((l) => l.length > 0)
        );
      }
    );
  });
}

// ---------- commit message building ----------

function detectCommitType(taskName: string): string {
  const lower = taskName.toLowerCase();
  if (/\bfix\b|bug|hotfix|修复|修补/.test(lower)) return 'fix';
  if (/\brefactor|重构/.test(lower)) return 'refactor';
  if (/\bdocs?|文档|readme|comment/.test(lower)) return 'docs';
  if (/\btest|测试/.test(lower)) return 'test';
  if (/\bperf|性能|optimize|优化/.test(lower)) return 'perf';
  if (/\bci|cd|pipeline|github/.test(lower)) return 'ci';
  if (/\bchore|杂务/.test(lower)) return 'chore';
  return 'feat';
}

function extractScope(contractPath: string): string {
  // e.g. "/path/to/docs/nexum/contracts/INFRA-001.yaml" → "INFRA-001"
  const base = path.basename(contractPath, path.extname(contractPath));
  return base;
}

function buildCommitMessage(taskId: string, taskName: string, contractPath: string): string {
  const type = detectCommitType(taskName);
  const scope = extractScope(contractPath);
  return `${type}(${scope}): ${taskId}: ${taskName}`;
}

// ---------- main callback ----------

export async function runCallback(taskId: string, projectDir: string): Promise<void> {
  const task = await getTask(projectDir, taskId);
  if (!task) {
    throw new Error(`Task not found: ${taskId}`);
  }

  // 1. Git commit + push (if there are changes)
  const changedFiles = await getChangedFiles(projectDir);
  if (changedFiles.length > 0) {
    const msg = buildCommitMessage(taskId, task.name, task.contract_path);
    await commitFiles(projectDir, changedFiles, msg);
    await gitPush(projectDir);
    console.log(`[nexum] committed: ${msg}`);
  } else {
    console.log("[nexum] no changes to commit");
  }

  // 2. Update task status
  await updateTask(projectDir, taskId, {
    status: TaskStatus.GeneratorDone,
  });

  // 3. Send Telegram notification
  const config = await loadConfig(projectDir).catch(() => ({}));
  const notifyConfig = (config as Record<string, unknown>).notify as Record<string, string> | undefined;
  const chatId = notifyConfig?.target ?? process.env['TELEGRAM_CHAT_ID'];
  const botToken = notifyConfig?.botToken ?? process.env['TELEGRAM_BOT_TOKEN'];

  if (chatId && botToken) {
    const pushInfo = changedFiles.length > 0
      ? `已 push：\`${changedFiles.length} 个文件\``
      : '（无文件变更）';
    const message = [
      '✅ Generator 完成 + 已 push',
      '━━━━━━━━━━━━━━━',
      `📋 任务内容: ${task.name}`,
      `🆔 任务ID: ${taskId}`,
      `📦 ${pushInfo}`,
      '💬 等待编排者触发 eval',
    ].join('\n');

    await sendMessage(chatId, message, botToken);
  }

  console.log(JSON.stringify({ ok: true, taskId, status: TaskStatus.GeneratorDone, changedFiles }));
}

export function registerCallback(program: Command): void {
  program
    .command('callback <taskId>')
    .description('Mark generator completion, commit + push changes, and send callback notification')
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
