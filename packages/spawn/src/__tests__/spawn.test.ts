import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

type ExecaResult = {
  stdout: string;
  stderr: string;
  exitCode: number;
};

const testingGlobals = globalThis as typeof globalThis & {
  __nexumSpawnExeca?: typeof createExecaMock extends (...args: never[]) => infer R
    ? R extends { execaMock: infer T }
      ? T
      : never
    : never;
  __nexumStatusExeca?: typeof createExecaMock extends (...args: never[]) => infer R
    ? R extends { execaMock: infer T }
      ? T
      : never
    : never;
};

function createExecaMock(results: ExecaResult[]) {
  const calls: Array<{ command: string; args: string[]; options: Record<string, unknown> }> = [];
  let index = 0;

  const execaMock = async (
    command: string,
    args: string[],
    options: Record<string, unknown>
  ): Promise<ExecaResult> => {
    calls.push({ command, args, options });
    return results[index++] ?? results.at(-1) ?? { stdout: "", stderr: "", exitCode: 0 };
  };

  return { calls, execaMock };
}

const cliEntryPath = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../../cli/dist/index.js"
);

test("spawnAcpSession constructs the expected openclaw command and updates active-tasks.json", async () => {
  const projectDir = await mkdtemp(path.join(tmpdir(), "nexum-spawn-"));
  const nexumDir = path.join(projectDir, "nexum");
  const activeTasksPath = path.join(nexumDir, "active-tasks.json");

  await mkdir(nexumDir, { recursive: true });
  await writeFile(
    activeTasksPath,
    JSON.stringify(
      {
        tasks: [
          {
            id: "NX-002",
            name: "Spawn ACP session",
            status: "running",
            contract_path: "docs/nexum/contracts/NX-002.yaml",
            depends_on: []
          }
        ]
      },
      null,
      2
    ) + "\n",
    "utf8"
  );

  const { calls, execaMock } = createExecaMock([
    {
      stdout: JSON.stringify({ status: "accepted", childSessionKey: "agent:codex:acp:123" }),
      stderr: "",
      exitCode: 0
    }
  ]);

  testingGlobals.__nexumSpawnExeca = execaMock;

  const { spawnAcpSession } = await import(`../spawn.ts?spawn=${Date.now()}`);
  const options = {
    taskId: "NX-002",
    agentId: "codex-gen-01",
    agentCli: "claude",
    promptFile: path.join(projectDir, "prompt.md"),
    cwd: projectDir,
    mode: "run",
    label: "nx-002-codex"
  };
  const record = await spawnAcpSession(options);

  assert.equal(record.sessionKey, "agent:codex:acp:123");
  assert.equal(record.status, "running");
  assert.equal(calls.length, 2);
  assert.equal(calls[0]?.command, "openclaw");
  assert.deepEqual(calls[0]?.args, [
    "sessions",
    "spawn",
    "--runtime",
    "acp",
    "--agent",
    "codex-gen-01",
    "--mode",
    "run",
    "--cwd",
    projectDir,
    "--label",
    "nx-002-codex",
    "acpx",
    "-s",
    "codex-gen-01",
    "--ttl",
    "0",
    "--approve-all",
    "claude",
    "exec",
    "-f",
    path.join(projectDir, "prompt.md")
  ]);
  assert.equal(calls[1]?.command, process.execPath);
  assert.deepEqual(calls[1]?.args, [
    cliEntryPath,
    "track",
    "NX-002",
    "agent:codex:acp:123",
    "--project",
    projectDir
  ]);

  const persisted = JSON.parse(await readFile(activeTasksPath, "utf8")) as {
    tasks: Array<{ id: string; acp_session_key?: string }>;
  };
  assert.equal(persisted.tasks[0]?.acp_session_key, "agent:codex:acp:123");

  delete testingGlobals.__nexumSpawnExeca;
});

test("spawnAcpSession infers cliName from agentId prefix when agentCli is omitted", async () => {
  const projectDir = await mkdtemp(path.join(tmpdir(), "nexum-spawn-"));
  const nexumDir = path.join(projectDir, "nexum");
  const activeTasksPath = path.join(nexumDir, "active-tasks.json");

  await mkdir(nexumDir, { recursive: true });
  await writeFile(
    activeTasksPath,
    JSON.stringify(
      {
        tasks: [
          {
            id: "NX-003",
            name: "Infer CLI name",
            status: "running",
            contract_path: "docs/nexum/contracts/NX-003.yaml",
            depends_on: []
          }
        ]
      },
      null,
      2
    ) + "\n",
    "utf8"
  );

  const { calls, execaMock } = createExecaMock([
    {
      stdout: JSON.stringify({ status: "accepted", childSessionKey: "agent:codex:acp:201" }),
      stderr: "",
      exitCode: 0
    },
    {
      stdout: "",
      stderr: "",
      exitCode: 0
    },
    {
      stdout: JSON.stringify({ status: "accepted", childSessionKey: "agent:claude:acp:202" }),
      stderr: "",
      exitCode: 0
    },
    {
      stdout: "",
      stderr: "",
      exitCode: 0
    },
    {
      stdout: JSON.stringify({ status: "accepted", childSessionKey: "agent:codex:acp:203" }),
      stderr: "",
      exitCode: 0
    },
    {
      stdout: "",
      stderr: "",
      exitCode: 0
    }
  ]);

  testingGlobals.__nexumSpawnExeca = execaMock;

  const { spawnAcpSession } = await import(`../spawn.ts?spawn-prefix=${Date.now()}`);
  const cases = [
    { agentId: "codex-gen-01", expectedCliName: "codex" },
    { agentId: "claude-gen-01", expectedCliName: "claude" },
    { agentId: "unknown", expectedCliName: "codex" }
  ] as const;

  for (const [index, testCase] of cases.entries()) {
    await spawnAcpSession({
      taskId: "NX-003",
      agentId: testCase.agentId,
      promptFile: path.join(projectDir, `prompt-${index}.md`),
      cwd: projectDir,
      mode: "run",
      label: `nx-003-${index}`
    });
  }

  const spawnCalls = calls.filter((call) => call.command === "openclaw");
  const trackCalls = calls.filter((call) => call.command === process.execPath);

  assert.equal(spawnCalls.length, 3);
  assert.equal(trackCalls.length, 3);
  assert.deepEqual(
    spawnCalls.map((call) => call.args.slice(-10)),
    cases.map((testCase, index) => [
      "acpx",
      "-s",
      testCase.agentId,
      "--ttl",
      "0",
      "--approve-all",
      testCase.expectedCliName,
      "exec",
      "-f",
      path.join(projectDir, `prompt-${index}.md`)
    ])
  );
  assert.deepEqual(
    trackCalls.map((call) => call.args),
    [
      [
        cliEntryPath,
        "track",
        "NX-003",
        "agent:codex:acp:201",
        "--project",
        projectDir
      ],
      [
        cliEntryPath,
        "track",
        "NX-003",
        "agent:claude:acp:202",
        "--project",
        projectDir
      ],
      [
        cliEntryPath,
        "track",
        "NX-003",
        "agent:codex:acp:203",
        "--project",
        projectDir
      ]
    ]
  );

  delete testingGlobals.__nexumSpawnExeca;
});

test("getSessionStatus parses done, running, and unknown states from openclaw sessions list", async () => {
  const { calls, execaMock } = createExecaMock([
    {
      stdout: JSON.stringify({
        sessions: [
          { key: "session-running", status: "running" },
          { key: "session-done", status: "done" }
        ]
      }),
      stderr: "",
      exitCode: 0
    },
    {
      stdout: JSON.stringify({
        sessions: [
          { key: "session-running", status: "running" },
          { key: "session-done", status: "done" }
        ]
      }),
      stderr: "",
      exitCode: 0
    },
    {
      stdout: JSON.stringify({ sessions: [{ key: "session-running", status: "running" }] }),
      stderr: "",
      exitCode: 0
    }
  ]);

  testingGlobals.__nexumStatusExeca = execaMock;

  const { getSessionStatus } = await import(`../status.ts?status=${Date.now()}`);

  assert.equal(await getSessionStatus("session-done"), "done");
  assert.equal(await getSessionStatus("session-running"), "running");
  assert.equal(await getSessionStatus("missing"), "unknown");
  assert.equal(calls.length, 3);
  assert.deepEqual(calls[0]?.args, ["sessions", "list", "--json"]);

  delete testingGlobals.__nexumStatusExeca;
});

test("pollUntilDone throws TimeoutError when the session never completes", async () => {
  const { execaMock } = createExecaMock([
    {
      stdout: JSON.stringify({ sessions: [{ key: "session-running", status: "running" }] }),
      stderr: "",
      exitCode: 0
    }
  ]);

  testingGlobals.__nexumStatusExeca = execaMock;

  const { TimeoutError, pollUntilDone } = await import(`../status.ts?timeout=${Date.now()}`);

  await assert.rejects(
    pollUntilDone("session-running", { timeoutMs: 30, intervalMs: 5 }),
    (error: unknown) => error instanceof TimeoutError
  );

  delete testingGlobals.__nexumStatusExeca;
});
