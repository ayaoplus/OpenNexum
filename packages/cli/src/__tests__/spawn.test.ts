import assert from 'node:assert/strict';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { mkdtemp } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

const testingGlobals = globalThis as typeof globalThis & {
  __nexumCliSendMessage?: (chatId: string, text: string, token: string) => Promise<void>;
};

// Minimal valid contract YAML for tests
const CONTRACT_YAML = `id: TEST-001
name: Test Task
type: coding
created_at: "2026-01-01T00:00:00Z"
scope:
  files:
    - src/foo.ts
  boundaries:
    - packages/core/
  conflicts_with: []
deliverables:
  - "src/foo.ts: implement foo"
eval_strategy:
  type: unit
  criteria:
    - id: C1
      desc: foo is implemented
      method: "unit: check foo"
      threshold: pass
generator: cc-frontend
evaluator: eval
max_iterations: 3
depends_on: []
`;

async function setupProject(
  tasks: object[],
  contract = CONTRACT_YAML,
  taskId = 'TEST-001'
): Promise<string> {
  const projectDir = await mkdtemp(path.join(tmpdir(), 'nexum-cli-test-'));
  const nexumDir = path.join(projectDir, 'nexum');
  const contractDir = path.join(projectDir, 'docs', 'nexum', 'contracts');
  await mkdir(nexumDir, { recursive: true });
  await mkdir(contractDir, { recursive: true });
  await writeFile(
    path.join(nexumDir, 'active-tasks.json'),
    JSON.stringify({ tasks }, null, 2) + '\n',
    'utf8'
  );
  await writeFile(path.join(contractDir, `${taskId}.yaml`), contract, 'utf8');
  return projectDir;
}

// ─── C2: spawn prepares payload without faking a running session ───

test('runSpawn reads contract and returns generator payload with correct agentId', async () => {
  const taskId = 'TEST-001';
  const projectDir = await setupProject([
    {
      id: taskId,
      name: 'Test Task',
      status: 'pending',
      contract_path: `docs/nexum/contracts/${taskId}.yaml`,
      depends_on: [],
      iteration: 0,
    },
  ]);

  testingGlobals.__nexumCliSendMessage = async () => {};

  const { runSpawn } = await import(`../commands/spawn.ts?t=${Date.now()}`);
  const payload = await runSpawn(taskId, projectDir);

  assert.equal(payload.agentId, 'cc-frontend', 'agentId should match contract.generator');
  assert.equal(payload.runtime, 'acp', 'unknown agents should default to ACP');
  assert.equal(payload.runtimeAgentId, 'codex', 'unknown ACP agents should default to codex backend');
  assert.equal(payload.taskId, taskId);
  assert.ok(
    payload.promptFile.includes(taskId),
    'promptFile should contain taskId'
  );
  assert.ok(
    (await readFile(payload.promptFile, 'utf8')).includes('Test Task'),
    'prompt file should contain task name'
  );

  // Verify task status is unchanged until orchestrator tracks a real session
  const tasksRaw = JSON.parse(
    await readFile(path.join(projectDir, 'nexum', 'active-tasks.json'), 'utf8')
  ) as { tasks: Array<{ id: string; started_at?: string; status?: string }> };
  const updatedTask = tasksRaw.tasks.find((t) => t.id === taskId);
  assert.equal(updatedTask?.status, 'pending');
  assert.equal(updatedTask?.started_at, undefined);

  delete testingGlobals.__nexumCliSendMessage;
});

test('runTrack marks generator sessions as running and evaluator sessions as evaluating', async () => {
  const taskId = 'TEST-001';
  const projectDir = await setupProject([
    {
      id: taskId,
      name: 'Test Task',
      status: 'pending',
      contract_path: `docs/nexum/contracts/${taskId}.yaml`,
      depends_on: [],
      iteration: 0,
    },
  ]);

  const { runTrack } = await import(`../commands/track.ts?track=${Date.now()}`);

  await runTrack(taskId, 'session-gen', projectDir, '/tmp/gen.log', 'generator');

  let tasksRaw = JSON.parse(
    await readFile(path.join(projectDir, 'nexum', 'active-tasks.json'), 'utf8')
  ) as { tasks: Array<{ id: string; status: string; started_at?: string }> };
  let trackedTask = tasksRaw.tasks.find((t) => t.id === taskId);
  assert.equal(trackedTask?.status, 'running');
  assert.ok(trackedTask?.started_at);

  await writeFile(
    path.join(projectDir, 'nexum', 'dispatch-queue.jsonl'),
    `${JSON.stringify({
      taskId,
      action: 'spawn-evaluator',
      role: 'evaluator',
      projectDir,
      sessionName: 'claude-eval-01',
      createdAt: new Date().toISOString(),
    })}\n`,
    'utf8'
  );
  await writeFile(
    path.join(projectDir, 'nexum', 'active-tasks.json'),
    JSON.stringify(
      {
        tasks: [
          {
            ...tasksRaw.tasks[0],
            status: 'generator_done',
            eval_result_path: 'nexum/runtime/eval/TEST-001-iter-0.yaml',
          },
        ],
      },
      null,
      2
    ) + '\n',
    'utf8'
  );

  await runTrack(taskId, 'session-eval', projectDir, '/tmp/eval.log', 'evaluator');

  tasksRaw = JSON.parse(
    await readFile(path.join(projectDir, 'nexum', 'active-tasks.json'), 'utf8')
  ) as { tasks: Array<{ id: string; status: string }> };
  trackedTask = tasksRaw.tasks.find((t) => t.id === taskId);
  assert.equal(trackedTask?.status, 'evaluating');

  const queueContents = await readFile(path.join(projectDir, 'nexum', 'dispatch-queue.jsonl'), 'utf8');
  assert.equal(queueContents.trim(), '');
});

// ─── C3: complete pass updates task to done and unlocks downstream tasks ───

test('runComplete with pass marks task done and unlocks blocked downstream tasks', async () => {
  const taskId = 'TEST-001';
  const downstreamId = 'TEST-002';
  const projectDir = await setupProject([
    {
      id: taskId,
      name: 'Test Task',
      status: 'running',
      contract_path: `docs/nexum/contracts/${taskId}.yaml`,
      depends_on: [],
      iteration: 0,
      started_at: new Date(Date.now() - 5000).toISOString(),
    },
    {
      id: downstreamId,
      name: 'Downstream Task',
      status: 'blocked',
      contract_path: `docs/nexum/contracts/${taskId}.yaml`,
      depends_on: [taskId],
    },
  ]);

  testingGlobals.__nexumCliSendMessage = async () => {};

  const { runComplete } = await import(`../commands/complete.ts?t=${Date.now()}`);
  await runComplete(taskId, 'pass', projectDir);

  const tasksRaw = JSON.parse(
    await readFile(path.join(projectDir, 'nexum', 'active-tasks.json'), 'utf8')
  ) as { tasks: Array<{ id: string; status: string }> };

  const upstream = tasksRaw.tasks.find((t) => t.id === taskId);
  const downstream = tasksRaw.tasks.find((t) => t.id === downstreamId);

  assert.equal(upstream?.status, 'done', 'upstream task should be done');
  assert.equal(downstream?.status, 'pending', 'downstream blocked task should become pending');

  delete testingGlobals.__nexumCliSendMessage;
});

// ─── C4: complete fail with iteration < max_iterations triggers retry ───

test('runComplete with fail and iteration < max_iterations returns retry payload', async () => {
  const taskId = 'TEST-001';
  const projectDir = await setupProject([
    {
      id: taskId,
      name: 'Test Task',
      status: 'evaluating',
      contract_path: `docs/nexum/contracts/${taskId}.yaml`,
      depends_on: [],
      iteration: 0,
      started_at: new Date(Date.now() - 5000).toISOString(),
    },
  ]);

  testingGlobals.__nexumCliSendMessage = async () => {};

  const { runComplete } = await import(`../commands/complete.ts?t2=${Date.now()}`);
  const result = await runComplete(taskId, 'fail', projectDir);

  assert.equal(result.action, 'retry');
  assert.equal(result.retryPayload?.agentId, 'cc-frontend', 'retry should use contract.generator');
  assert.equal(result.retryPayload?.runtime, 'acp');
  assert.equal(result.retryPayload?.runtimeAgentId, 'codex');
  assert.equal(result.retryPayload?.taskId, taskId);
  assert.equal(result.retryPayload?.nextIteration, 1);
  assert.ok(result.retryPayload?.promptFile.includes(`${taskId}-retry-`));

  const tasksRaw = JSON.parse(
    await readFile(path.join(projectDir, 'nexum', 'active-tasks.json'), 'utf8')
  ) as { tasks: Array<{ id: string; status: string; iteration?: number }> };

  const retried = tasksRaw.tasks.find((t) => t.id === taskId);
  assert.equal(retried?.status, 'pending', 'task should return to pending until a new session is tracked');
  assert.equal(retried?.iteration, 1, 'iteration should be incremented to 1');

  delete testingGlobals.__nexumCliSendMessage;
});

test('runComplete auto-archives done tasks once the active list exceeds 20 done items', async () => {
  const taskId = 'TEST-021';
  const projectDir = await setupProject(
    Array.from({ length: 21 }, (_, index) => {
      const id = `TEST-${String(index + 1).padStart(3, '0')}`;
      return {
        id,
        name: `Task ${id}`,
        status: id === taskId ? 'running' : 'done',
        batch: 'batch-a',
        contract_path: `docs/nexum/contracts/${taskId}.yaml`,
        depends_on: [],
        iteration: 0,
        started_at: new Date(Date.now() - 5000).toISOString(),
      };
    }),
    CONTRACT_YAML.replace(/^id: TEST-001$/m, `id: ${taskId}`),
    taskId
  );

  testingGlobals.__nexumCliSendMessage = async () => {};

  const { runComplete } = await import(`../commands/complete.ts?archive=${Date.now()}`);
  const result = await runComplete(taskId, 'pass', projectDir);

  assert.equal(result.action, 'done');

  const activeTasksRaw = JSON.parse(
    await readFile(path.join(projectDir, 'nexum', 'active-tasks.json'), 'utf8')
  ) as { tasks: Array<{ id: string; status: string }> };
  assert.equal(activeTasksRaw.tasks.length, 0, 'done tasks should be removed from active tasks');

  const archiveDate = new Date().toISOString().slice(0, 10);
  const archivedTasks = JSON.parse(
    await readFile(path.join(projectDir, 'nexum', 'history', `${archiveDate}.json`), 'utf8')
  ) as Array<{ id: string; status: string }>;
  assert.equal(archivedTasks.length, 21);
  assert.ok(archivedTasks.every((task) => task.status === 'done'));

  delete testingGlobals.__nexumCliSendMessage;
});

test('runComplete resolves auto-routed retry payload to the same logical agent family', async () => {
  const taskId = 'TEST-AUTO';
  const contract = CONTRACT_YAML
    .replace(/^id: TEST-001$/m, `id: ${taskId}`)
    .replace(/^name: Test Task$/m, 'name: Frontend Portal')
    .replace(/^generator: cc-frontend$/m, 'generator: auto');
  const projectDir = await setupProject(
    [
      {
        id: taskId,
        name: 'Frontend Portal',
        status: 'evaluating',
        contract_path: `docs/nexum/contracts/${taskId}.yaml`,
        depends_on: [],
        iteration: 0,
        started_at: new Date(Date.now() - 5000).toISOString(),
      },
    ],
    contract,
    taskId
  );

  await writeFile(
    path.join(projectDir, 'nexum', 'config.json'),
    JSON.stringify(
      {
        agents: {
          'claude-gen-01': {
            cli: 'claude',
            execution: {
              runtime: 'acp',
              agentId: 'claude',
            },
          },
        },
      },
      null,
      2
    ),
    'utf8'
  );

  const { runComplete } = await import(`../commands/complete.ts?auto-retry=${Date.now()}`);
  const result = await runComplete(taskId, 'fail', projectDir);

  assert.equal(result.action, 'retry');
  assert.equal(result.retryPayload?.agentId, 'claude-gen-01');
  assert.equal(result.retryPayload?.agentCli, 'claude');
  assert.equal(result.retryPayload?.runtime, 'acp');
  assert.equal(result.retryPayload?.runtimeAgentId, 'claude');
});

// ─── C5: config eval→codex mapping is resolved in spawn payload ───

test('runSpawnEval resolves evaluator execution target from config', async () => {
  const taskId = 'TEST-001';
  const projectDir = await setupProject([
    {
      id: taskId,
      name: 'Test Task',
      status: 'running',
      contract_path: `docs/nexum/contracts/${taskId}.yaml`,
      depends_on: [],
      iteration: 0,
    },
  ]);

  // Write config mapping 'eval' agent to codex
  const nexumDir = path.join(projectDir, 'nexum');
  await writeFile(
    path.join(nexumDir, 'config.json'),
    JSON.stringify(
      {
        agents: {
          eval: {
            cli: 'codex',
            model: 'gpt-4o',
            execution: {
              runtime: 'acp',
              agentId: 'codex-evaluator',
            },
          },
        },
      },
      null,
      2
    ),
    'utf8'
  );

  testingGlobals.__nexumCliSendMessage = async () => {};

  const { runSpawnEval } = await import(`../commands/spawn.ts?t=${Date.now()}`);
  const payload = await runSpawnEval(taskId, projectDir);

  assert.equal(payload.agentCli, 'codex', 'agentCli should be codex per config');
  assert.equal(payload.agentId, 'eval', 'agentId should remain the logical evaluator id');
  assert.equal(payload.runtime, 'acp', 'runtime should come from execution config');
  assert.equal(payload.runtimeAgentId, 'codex-evaluator', 'runtime agent should come from execution config');
  const tasksRaw = JSON.parse(
    await readFile(path.join(projectDir, 'nexum', 'active-tasks.json'), 'utf8')
  ) as { tasks: Array<{ id: string; status: string; eval_result_path?: string }> };
  const updatedTask = tasksRaw.tasks.find((t) => t.id === taskId);
  assert.equal(updatedTask?.status, 'running');
  assert.equal(
    updatedTask?.eval_result_path,
    path.join(projectDir, 'nexum', 'runtime', 'eval', `${taskId}-iter-0.yaml`)
  );

  delete testingGlobals.__nexumCliSendMessage;
});

test('runEval delegates to evaluator payload generation and preserves claude acp defaults', async () => {
  const taskId = 'TEST-CLAUDE';
  const contract = CONTRACT_YAML
    .replace(/^id: TEST-001$/m, `id: ${taskId}`)
    .replace(/^generator: cc-frontend$/m, 'generator: codex-gen-01')
    .replace(/^evaluator: eval$/m, 'evaluator: claude-eval-01');
  const projectDir = await setupProject(
    [
      {
        id: taskId,
        name: 'Test Task',
        status: 'generator_done',
        contract_path: `docs/nexum/contracts/${taskId}.yaml`,
        depends_on: [],
        iteration: 0,
      },
    ],
    contract,
    taskId
  );

  await writeFile(
    path.join(projectDir, 'nexum', 'config.json'),
    JSON.stringify(
      {
        agents: {
          'claude-eval-01': {
            cli: 'claude',
            model: 'sonnet-4-6',
          },
        },
      },
      null,
      2
    ),
    'utf8'
  );

  const { runEval } = await import(`../commands/eval.ts?eval=${Date.now()}`);
  const payload = await runEval(taskId, projectDir);

  assert.equal(payload.agentId, 'claude-eval-01');
  assert.equal(payload.agentCli, 'claude');
  assert.equal(payload.runtime, 'acp');
  assert.equal(payload.runtimeAgentId, 'claude');
  assert.ok(payload.promptContent.includes(taskId));
});

test('runStatus reports batch progress using currentBatch', async () => {
  const taskId = 'TEST-001';
  const projectDir = await setupProject([
    {
      id: taskId,
      name: 'Alpha done',
      status: 'done',
      batch: 'batch-a',
      contract_path: `docs/nexum/contracts/${taskId}.yaml`,
      depends_on: [],
    },
    {
      id: 'TEST-002',
      name: 'Alpha pending',
      status: 'pending',
      batch: 'batch-a',
      contract_path: `docs/nexum/contracts/${taskId}.yaml`,
      depends_on: [],
    },
    {
      id: 'TEST-003',
      name: 'Beta done',
      status: 'done',
      batch: 'batch-b',
      contract_path: `docs/nexum/contracts/${taskId}.yaml`,
      depends_on: [],
    },
  ]);

  await writeFile(
    path.join(projectDir, 'nexum', 'active-tasks.json'),
    JSON.stringify(
      {
        currentBatch: 'batch-a',
        tasks: JSON.parse(
          await readFile(path.join(projectDir, 'nexum', 'active-tasks.json'), 'utf8')
        ).tasks,
      },
      null,
      2
    ) + '\n',
    'utf8'
  );

  const logs: string[] = [];
  const originalLog = console.log;
  console.log = (...args: unknown[]) => {
    logs.push(args.join(' '));
  };

  try {
    const { runStatus } = await import(`../commands/status.ts?status=${Date.now()}`);
    await runStatus(projectDir);
  } finally {
    console.log = originalLog;
  }

  assert.ok(logs.some((line) => line.includes('📊 batch-a: 1/2  |  总体: 2/3')));
});
