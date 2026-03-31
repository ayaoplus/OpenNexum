import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import type { Command } from 'commander';
import {
  parseContract,
  getTask,
  updateTask,
  loadConfig,
  resolveAgentCli,
} from '@nexum/core';
import type { AgentCli } from '@nexum/core';
import { renderGeneratorPrompt } from '@nexum/prompts';
import { resolveAgents } from '../lib/auto-route.js';

// ---------- commit type detection ----------

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

function isAsciiOnly(value: string): boolean {
  return /^[\x00-\x7F]+$/.test(value);
}

function taskIdToKebabSlug(taskId: string): string {
  return taskId.trim().toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
}

function toEnglishCommitSummary(name: string, taskId: string): string {
  return isAsciiOnly(name) ? name : taskIdToKebabSlug(taskId);
}

export interface SpawnPayload {
  taskId: string;
  taskName: string;
  agentId: string;
  agentCli: AgentCli;
  promptFile: string;
  promptContent: string;
  label: string;
  cwd: string;
}

type ContractWithAgentCompat = {
  generator: string;
  evaluator: string;
  agent?: {
    generator?: string;
    evaluator?: string;
  };
};

function getGeneratorAgentId(contract: ContractWithAgentCompat): string {
  return contract.agent?.generator ?? contract.generator;
}

function getEvaluatorAgentId(contract: ContractWithAgentCompat): string {
  return contract.agent?.evaluator ?? contract.evaluator;
}

export async function runSpawn(taskId: string, projectDir: string): Promise<SpawnPayload> {
  const task = await getTask(projectDir, taskId);
  if (!task) {
    throw new Error(`Task not found: ${taskId}`);
  }

  const contractAbsPath = path.isAbsolute(task.contract_path)
    ? task.contract_path
    : path.join(projectDir, task.contract_path);
  const contract = await parseContract(contractAbsPath);

  const iteration = task.iteration ?? 0;
  const evalResultPath = path.join(
    projectDir,
    'nexum',
    'runtime',
    'eval',
    `${taskId}-iter-${iteration}.yaml`
  );

  const config = await loadConfig(projectDir);
  const resolvedContract = { ...contract, ...resolveAgents(contract, config) };
  // If git.remote is explicitly set to empty string, skip push; otherwise default to 'origin'
  const gitRemoteRaw = config.git?.remote;
  const gitRemote = gitRemoteRaw === '' ? '' : (gitRemoteRaw ?? 'origin');
  const gitBranch = config.git?.branch ?? 'main';

  const type = detectCommitType(resolvedContract.name);
  const scope = taskId.toUpperCase();
  const commitSummary = toEnglishCommitSummary(resolvedContract.name, taskId);
  const commitMsg = `${type}(${scope}): ${taskId}: ${commitSummary}`;
  const gitCommitCmd = gitRemote
    ? [
        `git add -- ${resolvedContract.scope.files.join(' ')}`,
        `git commit -m "${commitMsg}"`,
        `git push -u ${gitRemote} ${gitBranch}`,
      ].join(' && ')
    : [
        `git add -- ${resolvedContract.scope.files.join(' ')}`,
        `git commit -m "${commitMsg}"`,
      ].join(' && ');

  const promptContent = renderGeneratorPrompt({
    contract: resolvedContract,
    task: { id: task.id, name: task.name },
    gitCommitCmd,
    evalResultPath,
    lessons: [],
    projectDir,
  });

  const promptsDir = path.join(projectDir, 'nexum', 'runtime', 'prompts');
  await mkdir(promptsDir, { recursive: true });
  const promptFile = path.join(promptsDir, `${taskId}-gen-${Date.now()}.md`);
  await writeFile(promptFile, promptContent, 'utf8');

  const agentCli = resolveAgentCli(config, resolvedContract.generator);
  const label = `nexum-${taskId.toLowerCase()}-${resolvedContract.generator}`;

  return {
    taskId,
    taskName: resolvedContract.name,
    agentId: resolvedContract.generator,
    agentCli,
    promptFile,
    promptContent,
    label,
    cwd: projectDir,
  };
}

export async function runSpawnEval(taskId: string, projectDir: string): Promise<SpawnPayload> {
  const task = await getTask(projectDir, taskId);
  if (!task) {
    throw new Error(`Task not found: ${taskId}`);
  }

  const contractAbsPath = path.isAbsolute(task.contract_path)
    ? task.contract_path
    : path.join(projectDir, task.contract_path);
  const contract = await parseContract(contractAbsPath);
  const generatorAgentId = getGeneratorAgentId(contract);
  const evaluatorAgentId = getEvaluatorAgentId(contract);
  const config = await loadConfig(projectDir);
  const contractWithAgents = { ...contract, generator: generatorAgentId, evaluator: evaluatorAgentId };
  const resolvedContract =
    generatorAgentId === 'auto' || evaluatorAgentId === 'auto'
      ? { ...contractWithAgents, ...resolveAgents(contractWithAgents, config) }
      : contractWithAgents;

  const iteration = task.iteration ?? 0;
  const evalResultPath = path.join(
    projectDir,
    'nexum',
    'runtime',
    'eval',
    `${taskId}-iter-${iteration}.yaml`
  );

  const { renderEvaluatorPrompt } = await import('@nexum/prompts');
  const promptContent = renderEvaluatorPrompt({
    contract: resolvedContract,
    task: { id: task.id, name: task.name },
    gitCommitCmd: '',
    evalResultPath,
    lessons: [],
  });

  const promptsDir = path.join(projectDir, 'nexum', 'runtime', 'prompts');
  await mkdir(promptsDir, { recursive: true });
  const promptFile = path.join(promptsDir, `${taskId}-eval-${Date.now()}.md`);
  await writeFile(promptFile, promptContent, 'utf8');

  await updateTask(projectDir, taskId, {
    eval_result_path: evalResultPath,
  });

  const agentCli = resolveAgentCli(config, resolvedContract.evaluator);
  const label = `nexum-${taskId.toLowerCase()}-eval`;

  return {
    taskId,
    taskName: resolvedContract.name,
    agentId: resolvedContract.evaluator,
    agentCli,
    promptFile,
    promptContent,
    label,
    cwd: projectDir,
  };
}

export function registerSpawn(program: Command): void {
  program
    .command('spawn <taskId>')
    .description('Prepare a generator task and output spawn payload as JSON')
    .option('--project <dir>', 'Project directory', process.cwd())
    .action(async (taskId: string, options: { project: string }) => {
      try {
        const payload = await runSpawn(taskId, options.project);
        console.log(JSON.stringify(payload, null, 2));
      } catch (err) {
        console.error('spawn failed:', err instanceof Error ? err.message : err);
        process.exit(1);
      }
    });
}
