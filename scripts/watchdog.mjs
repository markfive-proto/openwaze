#!/usr/bin/env node
// watchdog.mjs [--dry-run] [--json]   (#6)
//
// Finds stalled agent-loop work and writes it to the ONE open issue titled
// "Agent watchdog" (created and pinned if missing):
//   running      issue labelled agent-running for more than 2 h
//   ci-red       draft PR whose ci-ok check failed more than 1 day ago
//   changes      PR whose REQUEST_CHANGES review is at head and over 2 days old
//   no-pr        remote branch, last commit over 1 day ago, never had a PR
//
// --dry-run prints the report and edits nothing. Node 22+, needs `gh` and a
// checkout with origin fetched; no dependencies. Run daily by
// .github/workflows/watchdog.yml.
//
// Exit 0 when every check ran, 2 when one could not run: could-not-check is
// its own outcome, never folded into "nothing stalled".
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

const HOUR = 3600 * 1000;
const DAY = 24 * HOUR;
export const LIMITS = { running: 2 * HOUR, ciRed: DAY, changes: 2 * DAY, noPr: DAY };
const TITLE = 'Agent watchdog';
const SECTIONS = [
  ['running', 'agent-running for more than 2 h'],
  ['ciRed', 'Draft PRs with ci-ok red for more than 1 day'],
  ['changes', 'Changes requested, not addressed for more than 2 days'],
  ['noPr', 'Branches with no PR (last commit over 1 day ago)'],
];

// ---- pure logic (tested in scripts/test/agent.test.mjs) ----

// When `label` was last added, from an issue's events, or null.
export function labelledAt(events, label) {
  const t = events.filter((e) => e.event === 'labeled' && e.label?.name === label).map((e) => Date.parse(e.created_at));
  return t.length ? Math.max(...t) : null;
}

export function ciOkRedSince(pr) {
  const c = (pr.statusCheckRollup ?? []).find((x) => x.name === 'ci-ok');
  return c && ['FAILURE', 'TIMED_OUT', 'CANCELLED', 'STARTUP_FAILURE'].includes(c.conclusion) ? Date.parse(c.completedAt) : null;
}

// The oldest REQUEST_CHANGES that is still each reviewer's latest word and was
// made against the current head (a new commit counts as an answer), or null.
export function changesRequestedSince(pr) {
  const latest = new Map();
  for (const r of [...(pr.reviews ?? [])].sort((a, b) => Date.parse(a.submittedAt) - Date.parse(b.submittedAt))) {
    if (r.state === 'COMMENTED' || r.state === 'PENDING') continue; // a comment does not withdraw a verdict
    latest.set(r.author?.login ?? '?', r);
  }
  const open = [...latest.values()].filter((r) => r.state === 'CHANGES_REQUESTED' && r.commit?.oid === pr.headRefOid);
  return open.length ? Math.min(...open.map((r) => Date.parse(r.submittedAt))) : null;
}

export function branchesWithoutPr(branches, prHeads, now, limit = LIMITS.noPr) {
  return branches.filter((b) => b.name !== 'main' && b.name !== 'HEAD' && !prHeads.has(b.name) && now - b.dateMs > limit);
}

export const over = (since, now, limit) => since !== null && now - since > limit;

export function renderMarkdown(report) {
  const lines = [`# ${TITLE}`, '', `Generated ${report.generatedAt} by \`scripts/watchdog.mjs\`. Edited in place each run.`, ''];
  if (report.couldNotCheck.length) lines.push('## Could not check', '', ...report.couldNotCheck.map((c) => `- ${c}`), '');
  let any = false;
  for (const [key, title] of SECTIONS) {
    const items = report.items[key];
    if (!items.length) continue;
    any = true;
    lines.push(`## ${title} (${items.length})`, '', ...items.map((i) => `- ${i}`), '');
  }
  if (!any) lines.push(report.couldNotCheck.length ? 'Nothing stalled in the checks that ran. Some checks did not run (above), so this is not a clean report.' : 'Nothing stalled.', '');
  return lines.join('\n');
}

// ---- side effects ----

function sh(cmd, args) {
  const r = spawnSync(cmd, args, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  return { rc: r.status ?? 1, out: r.stdout ?? '', err: (r.stderr ?? '').trim().split('\n').at(-1) };
}

function json(cmd, args, couldNotCheck, what) {
  const r = sh(cmd, args);
  try {
    if (r.rc !== 0) throw new Error();
    return JSON.parse(r.out);
  } catch {
    couldNotCheck.push(`${what}: ${r.err || 'bad output'}`);
    return null;
  }
}

const ago = (ms) => (ms >= 2 * DAY ? `${Math.round(ms / DAY)} d` : `${Math.round(ms / HOUR)} h`);
// Titles are user text; keep them on one line and out of Markdown structure.
const t = (s) => String(s).replace(/[\r\n]+/g, ' ').replace(/[<>]/g, '').slice(0, 100);

function collect(now = Date.now()) {
  const couldNotCheck = [];
  const items = Object.fromEntries(SECTIONS.map(([k]) => [k, []]));

  const running = json('gh', ['issue', 'list', '--label', 'agent-running', '--state', 'open', '--json', 'number,title'], couldNotCheck, 'agent-running issues');
  for (const i of running ?? []) {
    const events = json('gh', ['api', '--paginate', '--slurp', `repos/{owner}/{repo}/issues/${i.number}/events`], couldNotCheck, `events of #${i.number}`);
    if (!events) continue;
    const since = labelledAt(events.flat(), 'agent-running');
    if (over(since, now, LIMITS.running)) items.running.push(`#${i.number} ${t(i.title)}: running for ${ago(now - since)}`);
  }

  const prs = json('gh', ['pr', 'list', '--state', 'open', '--limit', '200', '--json', 'number,title,isDraft,headRefName,headRefOid,reviews,statusCheckRollup'], couldNotCheck, 'open PRs');
  for (const pr of prs ?? []) {
    const red = ciOkRedSince(pr);
    if (pr.isDraft && over(red, now, LIMITS.ciRed)) items.ciRed.push(`#${pr.number} ${t(pr.title)}: ci-ok red for ${ago(now - red)}`);
    const asked = changesRequestedSince(pr);
    if (over(asked, now, LIMITS.changes)) items.changes.push(`#${pr.number} ${t(pr.title)}: changes requested ${ago(now - asked)} ago, no new commit`);
  }

  if (sh('git', ['fetch', '-q', '--prune', 'origin']).rc !== 0) couldNotCheck.push('git fetch origin failed; branch check used the last fetched refs');
  const refs = sh('git', ['for-each-ref', 'refs/remotes/origin', '--format=%(refname:lstrip=3)%09%(committerdate:unix)']);
  const all = json('gh', ['pr', 'list', '--state', 'all', '--limit', '1000', '--json', 'headRefName'], couldNotCheck, 'all PRs');
  if (refs.rc !== 0) couldNotCheck.push('git for-each-ref failed');
  else if (all) {
    const branches = refs.out.split('\n').filter(Boolean).map((l) => {
      const [name, s] = l.split('\t');
      return { name, dateMs: Number(s) * 1000 };
    });
    for (const b of branchesWithoutPr(branches, new Set(all.map((p) => p.headRefName)), now)) items.noPr.push(`\`${b.name}\`: last commit ${ago(now - b.dateMs)} ago`);
  }

  return { generatedAt: new Date(now).toISOString(), items, couldNotCheck };
}

function updateIssue(body) {
  const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-')), 'body.md');
  fs.writeFileSync(file, body);
  const found = sh('gh', ['issue', 'list', '--state', 'open', '--search', `"${TITLE}" in:title`, '--json', 'number,title']);
  if (found.rc !== 0) throw new Error(`could not look up the "${TITLE}" issue: ${found.err}`);
  const hit = JSON.parse(found.out).find((i) => i.title === TITLE);
  if (hit) {
    const r = sh('gh', ['issue', 'edit', String(hit.number), '--body-file', file]);
    if (r.rc !== 0) throw new Error(`gh issue edit #${hit.number} failed: ${r.err}`);
    return `updated #${hit.number}`;
  }
  const r = sh('gh', ['issue', 'create', '--title', TITLE, '--body-file', file]);
  if (r.rc !== 0) throw new Error(`gh issue create failed: ${r.err}`);
  const url = r.out.trim();
  const pin = sh('gh', ['issue', 'pin', url]);
  return `created ${url}${pin.rc === 0 ? ' and pinned it' : ` (pin failed: ${pin.err})`}`;
}

function main(argv) {
  if (argv.some((a) => !['--dry-run', '--json'].includes(a))) {
    console.error('usage: scripts/watchdog.mjs [--dry-run] [--json]');
    return 2;
  }
  const report = collect();
  const md = renderMarkdown(report);
  console.log(argv.includes('--json') ? JSON.stringify(report, null, 2) : md);
  if (!argv.includes('--dry-run')) {
    try {
      console.error(`watchdog: ${updateIssue(md)}`);
    } catch (e) {
      console.error(`watchdog: ${e.message}`);
      return 2;
    }
  }
  return report.couldNotCheck.length ? 2 : 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) process.exitCode = main(process.argv.slice(2));
