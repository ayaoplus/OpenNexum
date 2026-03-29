const SEP = "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━";

function formatElapsed(ms: number): string {
  if (ms < 1000) return `${ms}ms`;
  const secs = Math.floor(ms / 1000);
  if (secs < 60) return `${secs}s`;
  const mins = Math.floor(secs / 60);
  const rem = secs % 60;
  return `${mins}m${rem}s`;
}

export function formatDispatch(
  taskId: string,
  taskName: string,
  agentId: string,
  scopeCount: number,
  deliverablesCount: number,
  progress: string
): string {
  return [
    `🚀 <b>Task Dispatched</b>`,
    SEP,
    `Task: ${taskId} — ${taskName}`,
    `Agent: ${agentId}`,
    `Scope files: ${scopeCount}`,
    `Deliverables: ${deliverablesCount}`,
    `Progress: ${progress}`,
    SEP,
  ].join("\n");
}

export function formatComplete(
  taskId: string,
  taskName: string,
  elapsedMs: number,
  iteration: number,
  passCount: number,
  totalCount: number,
  unlockedTasks: string[],
  progress: string
): string {
  const unlockedLine =
    unlockedTasks.length > 0
      ? `Unlocked: ${unlockedTasks.join(", ")}`
      : "Unlocked: none";
  return [
    `✅ <b>Task Complete</b>`,
    SEP,
    `Task: ${taskId} — ${taskName}`,
    `Elapsed: ${formatElapsed(elapsedMs)}`,
    `Iteration: ${iteration}`,
    `Criteria: ${passCount}/${totalCount} passed`,
    unlockedLine,
    `Progress: ${progress}`,
    SEP,
  ].join("\n");
}

export function formatFail(
  taskId: string,
  taskName: string,
  iteration: number,
  passCount: number,
  totalCount: number,
  failCount: number,
  failedCriteria: string[],
  feedbackExcerpt: string
): string {
  const criteriaLines =
    failedCriteria.length > 0
      ? failedCriteria.map((c) => `  • ${c}`).join("\n")
      : "  (none)";
  return [
    `❌ <b>Task Failed</b>`,
    SEP,
    `Task: ${taskId} — ${taskName}`,
    `Iteration: ${iteration}`,
    `Criteria: ${passCount}/${totalCount} passed, ${failCount} failed`,
    `Failed criteria:`,
    criteriaLines,
    `Feedback: ${feedbackExcerpt}`,
    SEP,
  ].join("\n");
}

export function formatBatchDone(
  projectName: string,
  tasks: Array<{ taskId: string; taskName: string; status: "done" | "fail"; elapsedMs: number }>
): string {
  const taskLines = tasks
    .map((t) => {
      const icon = t.status === "done" ? "✅" : "❌";
      return `  ${icon} ${t.taskId} — ${t.taskName} (${formatElapsed(t.elapsedMs)})`;
    })
    .join("\n");
  return [
    `📦 <b>Batch Done</b> — ${projectName}`,
    SEP,
    `Tasks (${tasks.length}):`,
    taskLines,
    SEP,
  ].join("\n");
}
