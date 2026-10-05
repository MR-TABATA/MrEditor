// 要望（Issue）の約束を守らせる。
//
//   - 受け付けたら、返事の期限（7日）を、その場で書く。
//   - 「やらない」で閉じるときは、理由を書いたコメントが無ければ、開き直して理由を求める。
//   - 期限（7日）までに状況が「受付」のままの要望は、`overdue` を付け、持ち主に知らせる。
//   - 状況のラベルは常に1つ。
//
// `.github/workflows/requests.yml` から呼ぶ。GitHub に触れるのは、`github`（octokit）だけ。
// 要望の題名・本文は他人の入力なので、ここでは読まない（ラベルとコメントの有無だけ見る）。

export const DEADLINE_DAYS = 7;
const DAY = 24 * 60 * 60 * 1000;

export const STATUS = {
  received: "status:received",
  considering: "status:considering",
  adopted: "status:adopted",
  inProgress: "status:in-progress",
  done: "status:done",
  declined: "status:declined",
};
export const REQUEST = "request";
export const OVERDUE = "overdue";

export const LABELS = [
  { name: REQUEST, color: "0E8A7D", description: "要望 / Feature request" },
  { name: STATUS.received, color: "BFD4F2", description: "受付（期限内に返事する）/ Received" },
  { name: STATUS.considering, color: "FBCA04", description: "検討中 / Considering" },
  { name: STATUS.adopted, color: "0E8A16", description: "採用（まだ作っていない）/ Adopted" },
  { name: STATUS.inProgress, color: "1D76DB", description: "実装中 / In progress" },
  { name: STATUS.done, color: "5319E7", description: "完了（リリース済み）/ Done" },
  { name: STATUS.declined, color: "B60205", description: "やらない（理由つき）/ Not doing (with the reason)" },
  { name: OVERDUE, color: "D93F0B", description: "返事の期限（7日）を過ぎた / Past the reply deadline" },
];

const STATUS_NAMES = Object.values(STATUS);
const isOwnerSide = (c) => ["OWNER", "MEMBER", "COLLABORATOR"].includes(c.author_association);
const names = (issue) => (issue.labels || []).map((l) => (typeof l === "string" ? l : l.name));
const ymd = (d) => d.toISOString().slice(0, 10);

/** 理由と認めるコメントの最小の長さ（「やらない」だけでは理由にならない）。 */
export const MIN_REASON = 12;

export async function ensureLabels({ github, context }) {
  const { owner, repo } = context.repo;
  for (const l of LABELS) {
    try {
      await github.rest.issues.createLabel({ owner, repo, ...l });
    } catch (e) {
      if (e.status !== 422) throw e;          // もうある
    }
  }
}

async function setStatus({ github, context }, issue, status) {
  const { owner, repo } = context.repo;
  const have = names(issue);
  for (const s of STATUS_NAMES) {
    if (s !== status && have.includes(s)) {
      await github.rest.issues.removeLabel({ owner, repo, issue_number: issue.number, name: s });
    }
  }
  if (!have.includes(status)) {
    await github.rest.issues.addLabels({ owner, repo, issue_number: issue.number, labels: [status] });
  }
  if (status !== STATUS.received && have.includes(OVERDUE)) {
    await github.rest.issues.removeLabel({ owner, repo, issue_number: issue.number, name: OVERDUE });
  }
}

async function comment({ github, context }, issue, body) {
  const { owner, repo } = context.repo;
  await github.rest.issues.createComment({ owner, repo, issue_number: issue.number, body });
}

async function hasReason({ github, context }, issue) {
  const { owner, repo } = context.repo;
  const comments = await github.paginate(github.rest.issues.listComments, { owner, repo, issue_number: issue.number, per_page: 100 });
  return comments.some((c) => c.user?.type !== "Bot" && isOwnerSide(c) && (c.body || "").trim().length >= MIN_REASON);
}

/** Issue フォームの題名の接頭辞。`request` ラベルがまだ無いリポジトリでは、フォームのラベルが付かない。 */
export const TITLE_PREFIX = "[要望]";

export async function onOpened(ctx, issue, now = new Date()) {
  const labelled = names(issue).includes(REQUEST);
  if (!labelled && !(issue.title || "").startsWith(TITLE_PREFIX)) return "ignored";
  await ensureLabels(ctx);
  if (!labelled) {
    const { owner, repo } = ctx.context.repo;
    await ctx.github.rest.issues.addLabels({ owner, repo, issue_number: issue.number, labels: [REQUEST] });
    issue = { ...issue, labels: [...(issue.labels || []), { name: REQUEST }] };
  }
  await setStatus(ctx, issue, STATUS.received);
  const due = ymd(new Date(new Date(issue.created_at).getTime() + DEADLINE_DAYS * DAY));
  await comment(ctx, issue,
    `要望を受け付けました。**${due} までに**、このページで返事をします。返事は、採用／検討中／やらない（理由つき）のどれかです。\n\n` +
    `We have your request. We will reply here **by ${due}** — adopted, considering, or not doing (always with the reason).`);
  return "opened";
}

export async function onClosed(ctx, issue) {
  if (!names(issue).includes(REQUEST)) return "ignored";
  const declined = issue.state_reason === "not_planned" || names(issue).includes(STATUS.declined);
  if (declined) {
    if (!(await hasReason(ctx, issue))) {
      const { owner, repo } = ctx.context.repo;
      await ctx.github.rest.issues.update({ owner, repo, issue_number: issue.number, state: "open", state_reason: "reopened" });
      await comment(ctx, issue,
        "「やらない」で閉じるときは、**理由をこのページにコメントで書く**決まりです。理由が見つからなかったので、開き直しました。" +
        "理由を書いてから、もう一度閉じてください。\n\n" +
        "A request is never closed as \"not planned\" without the reason written here. None was found, so it has been reopened — please add it, then close again.");
      return "reopened";
    }
    await setStatus(ctx, issue, STATUS.declined);
    return "declined";
  }
  await setStatus(ctx, issue, STATUS.done);
  return "done";
}

/** 状況のラベルが付いたら、ほかの状況を外す。期限切れの印も外す。 */
export async function onLabeled(ctx, issue, label) {
  if (!names(issue).includes(REQUEST) || !STATUS_NAMES.includes(label?.name)) return "ignored";
  await setStatus(ctx, issue, label.name);
  return "status";
}

/** 毎日1回: 受付のまま期限を過ぎた要望に印を付け、持ち主に知らせる。 */
export async function sweep(ctx, now = new Date()) {
  const { github, context } = ctx;
  const { owner, repo } = context.repo;
  const open = await github.paginate(github.rest.issues.listForRepo, { owner, repo, state: "open", labels: REQUEST, per_page: 100 });
  const marked = [];
  for (const issue of open) {
    if (issue.pull_request) continue;
    const have = names(issue);
    const waiting = have.includes(STATUS.received) || !have.some((n) => STATUS_NAMES.includes(n));
    const age = (now - new Date(issue.created_at)) / DAY;
    if (waiting && age >= DEADLINE_DAYS && !have.includes(OVERDUE)) {
      await ensureLabels(ctx);
      await github.rest.issues.addLabels({ owner, repo, issue_number: issue.number, labels: [OVERDUE] });
      await comment(ctx, issue,
        `@${owner} 返事の期限（${DEADLINE_DAYS}日）を過ぎました。採用／検討中／やらない（理由つき）のどれかを返してください。\n\n` +
        `The ${DEADLINE_DAYS}-day reply deadline has passed.`);
      marked.push(issue.number);
    } else if (!waiting && have.includes(OVERDUE)) {
      await github.rest.issues.removeLabel({ owner, repo, issue_number: issue.number, name: OVERDUE });
    }
  }
  return { overdue: marked };
}

export async function handle({ github, context, now = new Date() }) {
  const ctx = { github, context };
  const issue = context.payload?.issue;
  switch (context.eventName) {
    case "issues":
      if (context.payload.action === "opened") return onOpened(ctx, issue, now);
      if (context.payload.action === "closed") return onClosed(ctx, issue);
      if (context.payload.action === "labeled") return onLabeled(ctx, issue, context.payload.label);
      return "ignored";
    case "schedule":
    case "workflow_dispatch":
      await ensureLabels(ctx);
      return sweep(ctx, now);
    default:
      return "ignored";
  }
}
