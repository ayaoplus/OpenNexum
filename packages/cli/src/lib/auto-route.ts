import type { Contract, NexumConfig, RoutingRule } from '@nexum/core';

function findMatchingRule(
  contract: Pick<Contract, 'name'>,
  config: NexumConfig,
): RoutingRule | undefined {
  return config.routing?.rules?.find((rule) => new RegExp(rule.match).test(contract.name));
}

function isAutoAgent(agentId?: string): boolean {
  return !agentId || agentId === 'auto';
}

export function autoSelectGenerator(
  contract: Pick<Contract, 'name' | 'type'>,
  config: NexumConfig,
): string {
  const matchedRule = findMatchingRule(contract, config);
  if (matchedRule) {
    return matchedRule.generator;
  }

  if (contract.type === 'creative') {
    return 'claude-write-01';
  }

  const contractName = contract.name.toLowerCase();

  if (
    contractName.includes('webui') ||
    contractName.includes('frontend') ||
    contract.name.includes('用户端') ||
    contractName.includes('portal')
  ) {
    return 'claude-gen-01';
  }

  if (
    contractName.includes('admin') ||
    contractName.includes('dashboard') ||
    contract.name.includes('管理')
  ) {
    return 'codex-frontend-01';
  }

  if (
    contractName.includes('e2e') ||
    contractName.includes('test') ||
    contract.name.includes('测试')
  ) {
    return 'codex-e2e-01';
  }

  return 'codex-gen-01';
}

export function autoSelectEvaluator(
  generatorId: string,
  _contract: Pick<Contract, 'name' | 'type'>,
  _config: NexumConfig,
): string {
  if (generatorId.startsWith('codex-')) {
    return 'claude-eval-01';
  }

  if (generatorId.startsWith('claude-')) {
    return 'codex-eval-01';
  }

  return 'codex-eval-01';
}

export function resolveAgents(
  contract: Pick<Contract, 'name' | 'type' | 'generator' | 'evaluator' | 'agent'>,
  config: NexumConfig,
): { generator: string; evaluator: string } {
  const rawGenerator = contract.agent?.generator ?? contract.generator;
  const rawEvaluator = contract.agent?.evaluator ?? contract.evaluator;

  const generator = isAutoAgent(rawGenerator)
    ? autoSelectGenerator(contract, config)
    : rawGenerator;

  const evaluator = isAutoAgent(rawEvaluator)
    ? autoSelectEvaluator(generator, contract, config)
    : rawEvaluator;

  return { generator, evaluator };
}
