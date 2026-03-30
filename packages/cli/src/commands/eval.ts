import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import type { Command } from 'commander';
import { parseContract, getTask, updateTask, TaskStatus, loadConfig, resolveAgentCli } from '@nexum/core';
import { renderEvaluatorPrompt } from '@nexum/prompts';
import type { SpawnPayload } from './spawn.js';

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

export async function runEval(taskId: string, projectDir: string): Promise<SpawnPayload> {
  const task = await getTask(projectDir, taskId);
  if (!task) {
    throw new Error(`Task not found: ${taskId}`);
  }

  const contractAbsPath = path.isAbsolute(task.contract_path)
    ? task.contract_path
    : path.join(projectDir, task.contract_path);
  const contract = await parseContract(contractAbsPath);
  const contractWithAgents = {
    ...contract,
    generator: getGeneratorAgentId(contract),
    evaluator: getEvaluatorAgentId(contract),
  };

  const iteration = task.iteration ?? 0;
  const evalResultPath = path.join(
    projectDir,
    'nexum',
    'runtime',
    'eval',
    `${taskId}-iter-${iteration}.yaml`
  );

  const promptContent = renderEvaluatorPrompt({
    contract: contractWithAgents,
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
    status: TaskStatus.Evaluating,
    eval_result_path: evalResultPath,
  });

  const config = await loadConfig(projectDir);
  const agentCli = resolveAgentCli(config, contractWithAgents.evaluator);
  const label = `nexum-${taskId.toLowerCase()}-eval`;

  return {
    taskId,
    taskName: contractWithAgents.name,
    agentId: contractWithAgents.evaluator,
    agentCli,
    promptFile,
    promptContent,
    label,
    cwd: projectDir,
  };
}

export function registerEval(program: Command): void {
  program
    .command('eval <taskId>')
    .description('Prepare evaluator task and output spawn payload as JSON')
    .option('--project <dir>', 'Project directory', process.cwd())
    .action(async (taskId: string, options: { project: string }) => {
      try {
        const payload = await runEval(taskId, options.project);
        console.log(JSON.stringify(payload, null, 2));
      } catch (err) {
        console.error('eval failed:', err instanceof Error ? err.message : err);
        process.exit(1);
      }
    });
}
