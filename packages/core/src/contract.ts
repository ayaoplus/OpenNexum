import { readFile } from "node:fs/promises";
import { load as loadYaml } from "js-yaml";

import type {
  Contract,
  ContractCriterion,
  ContractEvalStrategy,
  ContractScope
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

function parseQuotedScalar(raw: string | undefined): string {
  if (!raw) {
    return "";
  }

  return raw.trim().replace(/^["']|["']$/g, "");
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export type { Contract, ContractCriterion, ContractEvalStrategy, ContractScope };
