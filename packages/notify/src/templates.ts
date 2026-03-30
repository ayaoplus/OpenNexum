const SEP = '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━';

export interface NotifyCriterionResult {
  id: string;
  passed: boolean;
  reason?: string;
}

export interface GeneratorCompleteOptions {
  model?: string;
  tokenText?: string;
  commitHash?: string;
  iteration?: number;
}

export interface ReviewPassOptions {
  evaluatorName?: string;
}

export interface ReviewFailOptions {
  evaluatorName?: string;
  criteriaResults?: NotifyCriterionResult[];
  autoRetryHint?: string;
}

export interface EscalationHistoryItem {
  iteration: number;
  feedback: string;
  criteriaResults?: NotifyCriterionResult[];
}

export interface EscalationOptions {
  evaluatorName?: string;
  reason?: string;
  note?: string;
}

function formatElapsed(ms: number): string {
  if (ms < 1000) return `${ms}ms`;
  const secs = Math.floor(ms / 1000);
  if (secs < 60) return `${secs}s`;
  const mins = Math.floor(secs / 60);
  const rem = secs % 60;
  return `${mins}m${rem}s`;
}

function shortHash(hash: string | undefined): string {
  return hash?.trim() ? hash.trim().slice(0, 7) : 'unknown';
}

function formatCriteriaLines(criteriaResults: NotifyCriterionResult[]): string[] {
  if (criteriaResults.length === 0) {
    return ['(none)'];
  }

  return criteriaResults.map((criterion) => {
    const icon = criterion.passed ? '✅' : '❌';
    const reason = criterion.reason?.trim() || (criterion.passed ? '通过' : '未提供原因');
    return `${icon} ${criterion.id}: ${reason}`;
  });
}

export function formatGeneratorComplete(
  taskId: string,
  taskName: string,
  agentName: string,
  options: GeneratorCompleteOptions = {}
): string {
  return [
    `🔨 [1/2] 代码已提交 — ${taskId}`,
    SEP,
    `📋 任务: ${taskName}`,
    `🤖 Agent: ${agentName}`,
    ...(options.model ? [`🧠 模型: ${options.model}`] : []),
    ...(options.tokenText ? [`🪙 Token: ${options.tokenText}`] : []),
    `🧾 Commit: ${shortHash(options.commitHash)}`,
    `🔁 迭代: 第${(options.iteration ?? 0) + 1}次`,
    '⏳ 状态: 等待审查',
    SEP,
  ].join('\n');
}

export function formatDispatchNotification(
  taskId: string,
  taskName: string,
  agentOrSessionName: string,
  scopeCount: number,
  progress: string,
  deliverablesCount?: number
): string {
  return [
    `🚀 派发任务 — ${taskId}`,
    SEP,
    `📋 任务: ${taskName}`,
    `🤖 Agent/Session: ${agentOrSessionName}`,
    `📁 Scope: ${scopeCount} 个文件`,
    ...(typeof deliverablesCount === 'number' ? [`📦 Deliverables: ${deliverablesCount} 项`] : []),
    `📊 进度: ${progress}`,
    SEP,
  ].join('\n');
}

export function formatReviewPassed(
  taskId: string,
  taskName: string,
  evaluatorName: string,
  elapsedMs: number,
  iteration: number,
  passCount: number,
  totalCount: number,
  unlockedTasks: string[],
  progress: string
): string {
  return [
    `✅ [2/2] 审查通过 — ${taskId}`,
    SEP,
    `📋 任务: ${taskName}`,
    `🧪 Evaluator: ${evaluatorName}`,
    `⏱️ 用时: ${formatElapsed(elapsedMs)}`,
    `🔁 迭代: 第${iteration + 1}次`,
    `🎯 Criteria: ${passCount}/${totalCount}`,
    `🔓 解锁任务: ${unlockedTasks.length > 0 ? unlockedTasks.join(', ') : '无'}`,
    `📊 进度: ${progress}`,
    SEP,
  ].join('\n');
}

export function formatReviewFailed(
  taskId: string,
  taskName: string,
  iteration: number,
  passCount: number,
  totalCount: number,
  criteriaResults: NotifyCriterionResult[],
  feedbackSummary: string,
  options: ReviewFailOptions = {}
): string {
  const failCount = criteriaResults.filter((criterion) => !criterion.passed).length;

  return [
    `❌ [2/2] 审查失败 — ${taskId} (第${iteration + 1}次)`,
    SEP,
    `📋 任务: ${taskName}`,
    `🧪 Evaluator: ${options.evaluatorName ?? 'evaluator'}`,
    `🎯 Criteria: ${passCount}/${totalCount} 通过，${failCount} 失败`,
    '📌 Criteria 结果:',
    ...formatCriteriaLines(criteriaResults),
    `💬 Feedback: ${feedbackSummary || '无'}`,
    `🔄 自动重试: ${options.autoRetryHint ?? '系统将自动触发下一次 retry'}`,
    SEP,
  ].join('\n');
}

export function formatEscalation(
  taskId: string,
  taskName: string,
  history: EscalationHistoryItem[],
  retryCommand: string,
  options: EscalationOptions = {}
): string {
  const historyLines =
    history.length > 0
      ? history.flatMap((entry) => [
          `• 第${entry.iteration + 1}次: ${entry.feedback || '无详细反馈'}`,
          ...formatCriteriaLines(entry.criteriaResults ?? []).map((line) => `  ${line}`),
        ])
      : ['(none)'];

  return [
    `🚨 任务升级 — ${taskId}`,
    SEP,
    `📋 任务: ${taskName}`,
    `🧪 Evaluator: ${options.evaluatorName ?? 'evaluator'}`,
    ...(options.reason ? [`🧯 升级原因: ${options.reason}`] : []),
    ...(options.note ? [`📝 备注: ${options.note}`] : []),
    '🧾 历史 fail 原因:',
    ...historyLines,
    `🛠 可用命令: ${retryCommand}`,
    SEP,
  ].join('\n');
}

export function formatDispatch(
  taskId: string,
  taskName: string,
  agentId: string,
  scopeCount: number,
  deliverablesCount: number,
  progress: string
): string {
  return formatDispatchNotification(
    taskId,
    taskName,
    agentId,
    scopeCount,
    progress,
    deliverablesCount
  );
}

export function formatComplete(
  taskId: string,
  taskName: string,
  elapsedMs: number,
  iteration: number,
  passCount: number,
  totalCount: number,
  unlockedTasks: string[],
  progress: string,
  options: ReviewPassOptions = {}
): string {
  return formatReviewPassed(
    taskId,
    taskName,
    options.evaluatorName ?? 'evaluator',
    elapsedMs,
    iteration,
    passCount,
    totalCount,
    unlockedTasks,
    progress
  );
}

export function formatFail(
  taskId: string,
  taskName: string,
  iteration: number,
  passCount: number,
  totalCount: number,
  failCount: number,
  failedCriteria: string[],
  feedbackExcerpt: string,
  options: ReviewFailOptions = {}
): string {
  const criteriaResults =
    options.criteriaResults && options.criteriaResults.length > 0
      ? options.criteriaResults
      : [
          ...failedCriteria.map((criterionId) => ({
            id: criterionId,
            passed: false,
            reason: '未通过',
          })),
          ...Array.from({ length: Math.max(passCount - Math.max(0, failCount), 0) }, (_, index) => ({
            id: `PASS-${index + 1}`,
            passed: true,
            reason: '通过',
          })),
        ];

  return formatReviewFailed(
    taskId,
    taskName,
    iteration,
    passCount,
    totalCount,
    criteriaResults,
    feedbackExcerpt,
    options
  );
}

export function formatBatchDone(
  projectName: string,
  tasks: Array<{ taskId: string; taskName: string; status: 'done' | 'fail'; elapsedMs: number }>
): string {
  const taskLines = tasks
    .map((task) => {
      const icon = task.status === 'done' ? '✅' : '❌';
      return `${icon} ${task.taskId} — ${task.taskName} (${formatElapsed(task.elapsedMs)})`;
    })
    .join('\n');

  return [
    `🎉 批次完成 — ${projectName}`,
    SEP,
    `📦 任务列表 (${tasks.length}):`,
    taskLines,
    SEP,
  ].join('\n');
}
