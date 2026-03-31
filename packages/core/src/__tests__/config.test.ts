import assert from "node:assert/strict";
import { mkdir, mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

import { loadConfig, resolveAgentCli, resolveAgentExecution } from "../config";

test("loadConfig returns empty object when config.json does not exist", async () => {
  const projectDir = await mkdtemp(path.join(tmpdir(), "nexum-config-"));
  const config = await loadConfig(projectDir);
  assert.deepEqual(config, {});
});

test("loadConfig reads and parses config.json", async () => {
  const projectDir = await mkdtemp(path.join(tmpdir(), "nexum-config-"));
  const nexumDir = path.join(projectDir, "nexum");
  await mkdir(nexumDir, { recursive: true });

  const configData = {
    notify: { target: "telegram", botToken: "abc123" },
    agents: {
      "claude-agent": { cli: "claude" as const, model: "claude-sonnet-4-6" },
      "codex-agent": { cli: "codex" as const },
    },
  };

  await writeFile(
    path.join(nexumDir, "config.json"),
    JSON.stringify(configData, null, 2),
    "utf8"
  );

  const config = await loadConfig(projectDir);
  assert.deepEqual(config, configData);
});

test("resolveAgentCli returns cli from config when agent exists", () => {
  const config = {
    agents: {
      "my-agent": { cli: "claude" as const },
    },
  };
  assert.equal(resolveAgentCli(config, "my-agent"), "claude");
});

test("resolveAgentCli defaults to codex when agent not in config", () => {
  const config = {};
  assert.equal(resolveAgentCli(config, "unknown-agent"), "codex");
});

test("resolveAgentCli defaults to codex when agents map is empty", () => {
  const config = { agents: {} };
  assert.equal(resolveAgentCli(config, "any-agent"), "codex");
});

test("resolveAgentExecution defaults codex agents to ACP codex backend", () => {
  const config = {
    agents: {
      "codex-gen-01": { cli: "codex" as const },
    },
  };

  assert.deepEqual(resolveAgentExecution(config, "codex-gen-01"), {
    cli: "codex",
    runtime: "acp",
    runtimeAgentId: "codex",
  });
});

test("resolveAgentExecution defaults claude agents to acp main backend", () => {
  const config = {
    agents: {
      "claude-gen-01": { cli: "claude" as const },
    },
  };

  assert.deepEqual(resolveAgentExecution(config, "claude-gen-01"), {
    cli: "claude",
    runtime: "acp",
    runtimeAgentId: "main",
  });
});

test("resolveAgentExecution honors explicit execution mapping", () => {
  const config = {
    agents: {
      review: {
        cli: "claude" as const,
        execution: {
          runtime: "acp" as const,
          agentId: "review-acp",
        },
      },
    },
  };

  assert.deepEqual(resolveAgentExecution(config, "review"), {
    cli: "claude",
    runtime: "acp",
    runtimeAgentId: "review-acp",
  });
});

test("resolveAgentExecution defaults claude ACP backend to main when no agentId override", () => {
  const config = {
    agents: {
      review: {
        cli: "claude" as const,
        execution: {
          runtime: "acp" as const,
        },
      },
    },
  };

  assert.deepEqual(resolveAgentExecution(config, "review"), {
    cli: "claude",
    runtime: "acp",
    runtimeAgentId: "main",
  });
});
