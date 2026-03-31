import { readFile } from "node:fs/promises";
import path from "node:path";

export type AgentCli = "codex" | "claude";
export type AgentRuntime = "acp" | "tmux";

export interface AgentExecutionConfig {
  runtime?: AgentRuntime;
  agentId?: string;
}

export interface AgentConfig {
  cli: AgentCli;
  model?: string;
  reasoning?: string;
  execution?: AgentExecutionConfig;
}

export interface RoutingRule {
  match: string;
  generator: string;
  evaluator: string;
}

export interface RoutingConfig {
  defaultGenerator?: string;
  defaultEvaluator?: string;
  rules?: RoutingRule[];
}

export interface NotifyConfig {
  target?: string;
}

export interface GitConfig {
  remote?: string;
  branch?: string;
}

export interface WatchConfig {
  enabled?: boolean;
  intervalMin?: number;
  timeoutMin?: number;
}

export interface HealthConfig {
  timeoutMin?: number;
}

export interface WebhookConfig {
  gatewayUrl?: string;
  token?: string;
}

export interface NexumConfig {
  notify?: NotifyConfig;
  agents?: Record<string, AgentConfig>;
  git?: GitConfig;
  watch?: WatchConfig;
  health?: HealthConfig;
  routing?: RoutingConfig;
  webhook?: WebhookConfig;
}

export interface ResolvedAgentExecution {
  cli: AgentCli;
  runtime: AgentRuntime;
  runtimeAgentId: string;
}

export async function loadConfig(projectDir: string): Promise<NexumConfig> {
  const configPath = path.join(projectDir, "nexum", "config.json");

  try {
    const contents = await readFile(configPath, "utf8");
    return JSON.parse(contents) as NexumConfig;
  } catch (error) {
    if (isNodeError(error) && error.code === "ENOENT") {
      return {};
    }
    throw error;
  }
}

export function resolveAgentCli(config: NexumConfig, agentId: string): AgentCli {
  return config.agents?.[agentId]?.cli ?? "codex";
}

export function resolveAgentExecution(
  config: NexumConfig,
  logicalAgentId: string
): ResolvedAgentExecution {
  const cli = resolveAgentCli(config, logicalAgentId);
  const execution = config.agents?.[logicalAgentId]?.execution;
  const runtime = execution?.runtime ?? defaultRuntimeForCli(cli);
  const runtimeAgentId = execution?.agentId ?? defaultRuntimeAgentId(runtime, cli);

  return { cli, runtime, runtimeAgentId };
}

function defaultRuntimeForCli(_cli: AgentCli): AgentRuntime {
  return "acp";
}

function defaultRuntimeAgentId(runtime: AgentRuntime, cli: AgentCli): string {
  if (runtime === "acp") {
    return cli === "claude" ? "main" : cli;
  }

  return cli;
}

function isNodeError(error: unknown): error is NodeJS.ErrnoException {
  return error instanceof Error;
}
