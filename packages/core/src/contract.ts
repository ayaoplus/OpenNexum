import { readFile } from "node:fs/promises";
import { load as loadYaml } from "js-yaml";

import type {
  Contract,
  ContractCriterion,
  ContractEvalStrategy,
  ContractScope,
  ContractType,
  EvalStrategyType
} from "./types";

export interface CriterionResult {
  id: string;
  passed: boolean;
  reason: string;
}

export interface EvalSummary {
  feedback: string;
  failedCriteria: string[];
  passCount: number;
  totalCount: number;
  criteriaResults: CriterionResult[];
}

const CONTRACT_TYPES = new Set<ContractType>(["coding", "task", "creative"]);
const EVAL_STRATEGY_TYPES = new Set<EvalStrategyType>([
  "unit",
  "integration",
  "review"
]);

export async function parseContract(filePath: string): Promise<Contract> {
  const source = await readFile(filePath, "utf8");
  const parsed = loadYaml(source);

  if (!isPlainObject(parsed)) {
    throw new Error(`Contract root must be an object: ${filePath}`);
  }

  return parsed as unknown as Contract;
}

export async function parseEvalResult(filePath: string): Promise<EvalSummary> {
  try {
    const content = await readFile(filePath, "utf8");
    const feedback = parseQuotedScalar(content.match(/^feedback:\s*(.+)$/m)?.[1]);
    const criteriaResults: CriterionResult[] = [];
    const failedCriteria: string[] = [];
    const criteriaBlocks = content.split(/\n\s*-\s*id:\s*/);

    for (const block of criteriaBlocks.slice(1)) {
      const idMatch = block.match(/^(\S+)/);
      const statusMatch = block.match(/^\s*(?:status|result):\s*(pass|fail)\s*$/m);
      const reason =
        parseQuotedScalar(block.match(/^\s*reason:\s*(.+)$/m)?.[1]) ||
        parseQuotedScalar(block.match(/^\s*evidence:\s*(.+)$/m)?.[1]) ||
        parseQuotedScalar(block.match(/^\s*detail:\s*(.+)$/m)?.[1]);

      if (!idMatch || !statusMatch) {
        continue;
      }

      const passed = statusMatch[1] === "pass";
      criteriaResults.push({ id: idMatch[1], passed, reason });

      if (!passed) {
        failedCriteria.push(idMatch[1]);
      }
    }

    const passCount =
      criteriaResults.length > 0
        ? criteriaResults.filter((result) => result.passed).length
        : [...content.matchAll(/(?:status|result):\s*pass/g)].length;
    const failCount =
      criteriaResults.length > 0
        ? criteriaResults.filter((result) => !result.passed).length
        : [...content.matchAll(/(?:status|result):\s*fail/g)].length;
    const totalCount = criteriaResults.length > 0 ? criteriaResults.length : passCount + failCount;

    return { feedback, failedCriteria, passCount, totalCount, criteriaResults };
  } catch {
    return { feedback: "", failedCriteria: [], passCount: 0, totalCount: 0, criteriaResults: [] };
  }
}

export function validateContract(contract: Contract): string[] {
  const errors: string[] = [];
  const record = contract as unknown as Record<string, unknown>;

  requireString(record.id, "id", errors);
  requireString(record.name, "name", errors);
  requireEnum(record.type, "type", CONTRACT_TYPES, errors);
  requireString(record.created_at, "created_at", errors);
  requireString(record.generator, "generator", errors);
  requireString(record.evaluator, "evaluator", errors);

  if (typeof record.max_iterations !== "number") {
    errors.push("Missing or invalid field: max_iterations");
  }

  const scope = record.scope;
  if (!isPlainObject(scope)) {
    errors.push("Missing or invalid field: scope");
  } else {
    requireStringArray(scope.files, "scope.files", errors);
    requireStringArray(scope.boundaries, "scope.boundaries", errors);
    requireStringArray(scope.conflicts_with, "scope.conflicts_with", errors);
  }

  requireStringArray(record.deliverables, "deliverables", errors);
  requireStringArray(record.depends_on, "depends_on", errors);

  const evalStrategy = record.eval_strategy;
  if (!isPlainObject(evalStrategy)) {
    errors.push("Missing or invalid field: eval_strategy");
  } else {
    requireEnum(evalStrategy.type, "eval_strategy.type", EVAL_STRATEGY_TYPES, errors);

    if (!Array.isArray(evalStrategy.criteria)) {
      errors.push("Missing or invalid field: eval_strategy.criteria");
    } else {
      evalStrategy.criteria.forEach((criterion, index) => {
        if (!isPlainObject(criterion)) {
          errors.push(`Invalid criterion at eval_strategy.criteria[${index}]`);
          return;
        }

        requireString(criterion.id, `eval_strategy.criteria[${index}].id`, errors);
        requireString(criterion.desc, `eval_strategy.criteria[${index}].desc`, errors);
        requireString(criterion.method, `eval_strategy.criteria[${index}].method`, errors);
        requireString(criterion.threshold, `eval_strategy.criteria[${index}].threshold`, errors);
      });
    }
  }

  return errors;
}

function parseQuotedScalar(raw: string | undefined): string {
  if (!raw) {
    return "";
  }

  return raw.trim().replace(/^["']|["']$/g, "");
}

function requireString(value: unknown, field: string, errors: string[]): void {
  if (typeof value !== "string" || value.trim() === "") {
    errors.push(`Missing or invalid field: ${field}`);
  }
}

function requireStringArray(value: unknown, field: string, errors: string[]): void {
  if (!Array.isArray(value) || !value.every((entry) => typeof entry === "string")) {
    errors.push(`Missing or invalid field: ${field}`);
  }
}

function requireEnum<T extends string>(
  value: unknown,
  field: string,
  allowed: Set<T>,
  errors: string[]
): void {
  if (typeof value !== "string" || !allowed.has(value as T)) {
    errors.push(`Missing or invalid field: ${field}`);
  }
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export type { Contract, ContractCriterion, ContractEvalStrategy, ContractScope };
