import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { load as loadYaml } from "js-yaml";

import { parseContract, validateContract } from "../contract";

const FIXTURE_CONTRACT_PATH = path.resolve(
  path.dirname(new URL(import.meta.url).pathname),
  "../../../../docs/nexum/contracts/NX-001.yaml"
);

test("parseContract parses an existing contract file", async () => {
  const contract = await parseContract(FIXTURE_CONTRACT_PATH);

  assert.equal(contract.id, "NX-001");
  assert.equal(contract.type, "coding");
  assert.equal(contract.scope.files[0], "pnpm-workspace.yaml");
  assert.equal(contract.eval_strategy.criteria[0].id, "C1");
  assert.equal(contract.deliverables[0]?.description.startsWith("pnpm-workspace.yaml"), true);
  assert.equal(validateContract(contract).length, 0);
});

test("validateContract reports missing required fields", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "nexum-contract-"));
  const contractPath = path.join(directory, "missing-fields.yaml");

  await writeFile(
    contractPath,
    [
      "id: NX-MISSING",
      "type: coding",
      "created_at: \"2026-03-29T04:00:00Z\"",
      "scope:",
      "  files: []",
      "  boundaries: []",
      "  conflicts_with: []",
      "deliverables: []",
      "eval_strategy:",
      "  type: unit",
      "  criteria: []",
      "generator: codex-1",
      "evaluator: eval",
      "max_iterations: 3",
      "depends_on: []",
      ""
    ].join("\n"),
    "utf8"
  );

  const raw = loadYaml(await readFile(contractPath, "utf8"));
  const errors = validateContract(raw);

  assert.ok(errors.includes("Missing or invalid field: name"));
});

test("validateContract rejects unknown eval_strategy.type", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "nexum-contract-"));
  const contractPath = path.join(directory, "invalid-eval.yaml");

  await writeFile(
    contractPath,
    [
      "id: NX-BAD-EVAL",
      "name: \"Bad Eval Strategy\"",
      "type: coding",
      "created_at: \"2026-03-29T04:00:00Z\"",
      "scope:",
      "  files: []",
      "  boundaries: []",
      "  conflicts_with: []",
      "deliverables: []",
      "eval_strategy:",
      "  type: smoke",
      "  criteria:",
      "    - id: C1",
      "      desc: \"desc\"",
      "      method: \"method\"",
      "      threshold: pass",
      "generator: codex-1",
      "evaluator: eval",
      "max_iterations: 3",
      "depends_on: []",
      ""
    ].join("\n"),
    "utf8"
  );

  const raw = loadYaml(await readFile(contractPath, "utf8"));
  const errors = validateContract(raw);

  assert.ok(errors.includes("Missing or invalid field: eval_strategy.type"));
});

test("parseContract normalizes modern contract schema", async () => {
  const modernContractPath = path.resolve(
    path.dirname(new URL(import.meta.url).pathname),
    "../../../../docs/nexum/contracts/NEXUM-023.yaml"
  );

  const contract = await parseContract(modernContractPath);

  assert.equal(contract.type, "coding");
  assert.equal(contract.generator, "codex-gen-01");
  assert.equal(contract.evaluator, "claude-eval-01");
  assert.equal(contract.depends_on.length, 0);
  assert.deepEqual(contract.deliverables[0], {
    path: "packages/cli/src/commands/callback.ts",
    description:
      "1) In autoDispatchUnlockedTasks and the evaluator auto-dispatch: replace hardcoded session names (codex-gen-TASK-ID, claude-eval-TASK-ID) with sequential numbered names from a shared counter. Add getNextSessionName(role: 'gen'|'eval', projectDir) that reads/writes nexum/session-counter.json atomically to get next number. Format: codex-gen-01, codex-gen-02 for generators; claude-eval-01, claude-eval-02 for evaluators. Pass the resolved session name to dispatchViaWebhook message payload so orchestrator knows which session to track. 2) The webhook message body should include sessionName: 'codex-gen-02' so I can use it in track."
  });
  assert.equal(contract.eval_strategy.criteria[0]?.weight, 3);
});
