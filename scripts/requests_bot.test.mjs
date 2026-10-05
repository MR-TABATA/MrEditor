// node --test scripts/requests_bot.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import * as bot from "./requests_bot.mjs";

const OWNER = "MR-TABATA";
const ctxFor = (eventName, payload) => ({ eventName, payload, repo: { owner: OWNER, repo: "MrEditor" } });
const DAY = 24 * 60 * 60 * 1000;
const T0 = new Date("2026-10-05T00:00:00Z");
const iso = (daysAgo) => new Date(T0 - daysAgo * DAY).toISOString();
const issue = (n, labels, extra = {}) => ({ number: n, labels: labels.map((name) => ({ name })), created_at: iso(1), state_reason: null, ...extra });

/** A GitHub that remembers what it was asked to do. */
function fakeGithub({ comments = {}, open = [] } = {}) {
  const calls = [];
  const rec = (name) => async (args) => { calls.push([name, args]); return { data: {} }; };
  const listComments = Object.assign(async () => ({ data: [] }), { __data: (a) => comments[a.issue_number] || [] });
  const listForRepo = Object.assign(async () => ({ data: [] }), { __data: () => open });
  return {
    calls,
    paginate: async (fn, args) => fn.__data(args),
    rest: { issues: { createLabel: rec("createLabel"), addLabels: rec("addLabels"), removeLabel: rec("removeLabel"),
                      createComment: rec("createComment"), update: rec("update"), listComments, listForRepo } },
  };
}
const did = (g, name) => g.calls.filter(([n]) => n === name).map(([, a]) => a);
const added = (g) => did(g, "addLabels").flatMap((a) => a.labels);
const removed = (g) => did(g, "removeLabel").map((a) => a.name);

test("a new request gets the 'received' status and a reply date seven days out, in both languages", async () => {
  const g = fakeGithub();
  const r = await bot.onOpened({ github: g, context: ctxFor("issues", {}) }, issue(7, ["request"], { created_at: "2026-10-05T03:00:00Z" }));
  assert.equal(r, "opened");
  assert.deepEqual(added(g), ["status:received"]);
  const body = did(g, "createComment")[0].body;
  assert.match(body, /2026-10-12 までに/);
  assert.match(body, /by 2026-10-12/);
  assert.ok(did(g, "createLabel").length >= bot.LABELS.length, "labels are created if they are missing");
});

test("a form request whose 'request' label did not stick is recognised by its title and labelled", async () => {
  const g = fakeGithub();
  const r = await bot.onOpened({ github: g, context: ctxFor("issues", {}) }, issue(14, [], { title: "[要望] 検索履歴を分けたい", created_at: "2026-10-05T03:00:00Z" }));
  assert.equal(r, "opened");
  assert.deepEqual(added(g), ["request", "status:received"]);
  assert.match(did(g, "createComment")[0].body, /2026-10-12/);
});

test("an issue that is not a request is left alone", async () => {
  const g = fakeGithub();
  assert.equal(await bot.onOpened({ github: g, context: ctxFor("issues", {}) }, issue(8, ["bug"], { title: "crash on open" })), "ignored");
  assert.equal(g.calls.length, 0);
});

test("'not planned' with no reason is reopened, and the reason is asked for", async () => {
  const g = fakeGithub();
  const r = await bot.onClosed({ github: g, context: ctxFor("issues", {}) }, issue(9, ["request", "status:received"], { state_reason: "not_planned" }));
  assert.equal(r, "reopened");
  assert.deepEqual(did(g, "update")[0], { owner: OWNER, repo: "MrEditor", issue_number: 9, state: "open", state_reason: "reopened" });
  assert.match(did(g, "createComment")[0].body, /理由/);
  assert.deepEqual(added(g), [], "it is not marked declined");
});

test("a one-word comment, or one from somebody else, is not a reason", async () => {
  for (const comments of [
    [{ user: { type: "User" }, author_association: "OWNER", body: "やらない" }],
    [{ user: { type: "User" }, author_association: "NONE", body: "この機能は、とても長く説明すれば理由に見えるが、持ち主ではない人の言葉" }],
    [{ user: { type: "Bot" }, author_association: "NONE", body: "要望を受け付けました。返事をします。かならず。" }],
  ]) {
    const g = fakeGithub({ comments: { 10: comments } });
    const r = await bot.onClosed({ github: g, context: ctxFor("issues", {}) }, issue(10, ["request"], { state_reason: "not_planned" }));
    assert.equal(r, "reopened");
  }
});

test("'not planned' with the owner's reason stays closed and is marked declined", async () => {
  const g = fakeGithub({ comments: { 11: [{ user: { type: "User" }, author_association: "OWNER", body: "編集機能は読み取り専用の設計と両立しないため、今回は見送ります。" }] } });
  const r = await bot.onClosed({ github: g, context: ctxFor("issues", {}) }, issue(11, ["request", "status:received", "overdue"], { state_reason: "not_planned" }));
  assert.equal(r, "declined");
  assert.deepEqual(added(g), ["status:declined"]);
  assert.deepEqual(removed(g).sort(), ["overdue", "status:received"]);
  assert.equal(did(g, "update").length, 0);
});

test("closed as completed becomes 'done' and the other status goes", async () => {
  const g = fakeGithub();
  const r = await bot.onClosed({ github: g, context: ctxFor("issues", {}) }, issue(12, ["request", "status:in-progress"], { state_reason: "completed" }));
  assert.equal(r, "done");
  assert.deepEqual(added(g), ["status:done"]);
  assert.deepEqual(removed(g), ["status:in-progress"]);
});

test("a new status label replaces the old one and clears 'overdue'", async () => {
  const g = fakeGithub();
  const iss = issue(13, ["request", "status:received", "status:adopted", "overdue"]);
  assert.equal(await bot.onLabeled({ github: g, context: ctxFor("issues", {}) }, iss, { name: "status:adopted" }), "status");
  assert.deepEqual(removed(g).sort(), ["overdue", "status:received"]);
  assert.deepEqual(added(g), []);
  // a label that is not a status is none of its business
  assert.equal(await bot.onLabeled({ github: fakeGithub(), context: ctxFor("issues", {}) }, iss, { name: "good first issue" }), "ignored");
});

test("the daily sweep marks what is still 'received' after seven days, once, and tells the owner", async () => {
  const g = fakeGithub({ open: [
    issue(20, ["request", "status:received"], { created_at: iso(8) }),              // late
    issue(21, ["request", "status:received"], { created_at: iso(3) }),              // in time
    issue(22, ["request", "status:received", "overdue"], { created_at: iso(30) }),  // already marked
    issue(23, ["request", "status:considering", "overdue"], { created_at: iso(30) }), // answered since
    issue(24, ["request"], { created_at: iso(9) }),                                   // never got a status
    { ...issue(25, ["request"], { created_at: iso(20) }), pull_request: {} },        // a PR is not a request
  ] });
  const r = await bot.sweep({ github: g, context: ctxFor("schedule", {}) }, T0);
  assert.deepEqual(r.overdue, [20, 24]);
  assert.deepEqual(did(g, "createComment").map((a) => a.issue_number), [20, 24]);
  assert.match(did(g, "createComment")[0].body, new RegExp(`@${OWNER}`));
  assert.deepEqual(removed(g), ["overdue"]);                       // only 23's
  assert.equal(did(g, "removeLabel")[0].issue_number, 23);
});

test("events are dispatched by name, and others are ignored", async () => {
  const g = fakeGithub();
  assert.equal(await bot.handle({ github: g, context: ctxFor("push", {}) }), "ignored");
  assert.equal(await bot.handle({ github: g, context: ctxFor("issues", { action: "edited", issue: issue(1, ["request"]) }) }), "ignored");
  const r = await bot.handle({ github: g, context: ctxFor("workflow_dispatch", {}), now: T0 });
  assert.deepEqual(r, { overdue: [] });
});
