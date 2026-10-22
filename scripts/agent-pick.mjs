#!/usr/bin/env node
// agent-pick.mjs [--dry-run] [--allow-protected] [--timeout-min N]   (#6)
//
// Takes ONE `agent-ready` issue to a draft PR, on a maintainer's machine with
// `gh` (logged in) and `claude` on PATH. Node 22+, no dependencies.
//
//   1. Picks the oldest open `agent-ready` issue (sprint-* labelled first) with
//      no agent-* state label and no linked PR. Issues whose text names a
//      CODEOWNERS path are skipped unless --allow-protected.
//   2. Labels it `agent-running` (removes `agent-ready`), creates a worktree on
//      branch agent/<n>-<slug> from origin/main under .claude/worktrees/.
//   3. Runs `claude -p` with scripts/agent-prompt.md. The issue text goes in as
//      delimited untrusted data. The model can edit files and run the checks,
//      nothing else: no gh, no git push, no web, no MCP servers.
//   4. This script, not the model, checks the diff (CODEOWNERS paths refused
//      unless --allow-protected), runs the checks for what changed, commits,
//      pushes and opens a draft PR with "Closes #n".
//   5. Success: `agent-review`. Failure: `agent-failed` plus a comment with this
//      script's own stage summary, never model output.
//
// One run at a time (lock in the git common dir). --dry-run prints the plan
// and changes nothing. Retry a failed issue: remove agent-failed, add agent-ready.
// See docs/security/known-vulns.md, "Actions for openwaze" 9 to 11.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

export const READY = 'agent-ready';
export const STATE_LABELS = ['agent-running', 'agent-review', 'agent-failed', 'needs-human'];
const LABEL_DEFS = [
  ['agent-running', '1D76DB', 'An agent run is working on this issue'],
  ['agent-review', '5319E7', 'Agent opened a draft PR; needs review'],
  ['agent-failed', 'B60205', 'Agent run stopped; see the comment, then relabel agent-ready to retry'],
  ['needs-human', 'FBCA04', 'Agent loop handed this back to a human'],
];
// Never committed by an agent, even with --allow-protected (AGENTS.md "Never").
const NEVER = [/(^|\/)\.env($|\.)/, /\.(pem|p12|pfx|key|mobileprovision)$/i, /\.xcodeproj\/(?!project\.xcworkspace\/xcshareddata\/swiftpm\/Package\.resolved$)/];

// ---- pure logic (tested in scripts/test/agent.test.mjs) ----

export function slugify(title, max = 40) {
  const s = String(title).toLowerCase().replace(/[^a-z0-9]+/g, '-').slice(0, max).replace(/^-+|-+$/g, '');
  return s || 'issue';
}

const names = (issue) => (issue.labels ?? []).map((l) => (typeof l === 'string' ? l : l.name));

// Issue numbers an open PR is already working on: any `#n` in its body, or an agent/<n>- branch.
// Over-matching is the safe failure: the issue waits for a human.
export function issuesInFlight(openPrs) {
  const nums = openPrs.flatMap((p) => [
    ...[...String(p.body ?? '').matchAll(/(?<![\w/])#(\d+)\b/g)].map((m) => Number(m[1])),
    ...(/^agent\/(\d+)-/.exec(p.headRefName ?? '') ? [Number(/^agent\/(\d+)-/.exec(p.headRefName)[1])] : []),
  ]);
  return new Set(nums);
}

// Eligible issues, best first: sprint-* labelled, then oldest, then lowest number.
// ponytail: any linked PR blocks, even a closed one; unlink it on the issue to retry.
export function eligibleIssues(issues, inFlight = new Set()) {
  const sprint = (i) => (names(i).some((n) => n.startsWith('sprint-')) ? 0 : 1);
  return issues
    .filter((i) => names(i).includes(READY) && !names(i).some((n) => STATE_LABELS.includes(n)))
    .filter((i) => !(i.closedByPullRequestsReferences ?? []).length && !inFlight.has(i.number))
    .sort((a, b) => sprint(a) - sprint(b) || Date.parse(a.createdAt) - Date.parse(b.createdAt) || a.number - b.number);
}

// CODEOWNERS glob -> RegExp, for the subset of gitignore syntax CODEOWNERS uses.
export function codeownersRegex(pattern) {
  const anchored = pattern.startsWith('/');
  let p = pattern.replace(/^\//, '');
  const dir = p.endsWith('/');
  p = p.replace(/\/$/, '');
  const body = p
    .split(/(\*\*\/|\*\*|\*)/)
    .map((t) => (t === '**/' ? '(?:.*/)?' : t === '**' ? '.*' : t === '*' ? '[^/]*' : t.replace(/[.+?^${}()|[\]\\]/g, '\\$&')))
    .join('');
  return new RegExp(`^${anchored ? '' : '(?:.*/)?'}${body}${dir ? '/' : '(?:$|/)'}`);
}

export function parseCodeowners(text) {
  return text
    .split('\n')
    .map((l) => l.trim().split(/\s+/)[0])
    .filter((p) => p && !p.startsWith('#'))
    .map((pattern) => ({ pattern, re: codeownersRegex(pattern) }));
}

// The CODEOWNERS patterns these paths hit (patterns, not paths: paths can be model-chosen).
export function protectedHits(files, rules) {
  return [...new Set(files.flatMap((f) => rules.filter((r) => r.re.test(f)).map((r) => r.pattern)))];
}

// Path-like tokens in issue text: a pre-screen only. The diff check after the run is the gate.
export function mentionedPaths(text) {
  const tokens = String(text).match(/[\w.*-]*\/[\w./*-]*|\b(?:Makefile|Brewfile|project\.yml|\.mcp\.json)\b/g) ?? [];
  return [...new Set(tokens.map((t) => t.replace(/^\.?\//, '').replace(/[.,;:]+$/, '')).filter(Boolean))];
}

export function neverFiles(files) {
  return files.filter((f) => NEVER.some((re) => re.test(f)));
}

// The checks the delivery gate runs for these files (AGENTS.md, "Delivery gate").
export function checksFor(files) {
  const checks = [];
  if (files.some((f) => /^(App\/|project\.yml$|\.swiftlint\.yml$)/.test(f))) {
    checks.push({ name: 'make lint', cmd: 'make', args: ['lint'] }, { name: 'make test', cmd: 'make', args: ['test'] });
  }
  if (files.some((f) => f.startsWith('server/'))) checks.push({ name: 'npm test (server)', cmd: 'npm', args: ['--prefix', 'server', 'test'] });
  if (files.some((f) => /^scripts\/.*\.mjs$/.test(f))) checks.push({ name: 'node --test scripts', cmd: 'node', args: ['--test', 'scripts/test/*.test.mjs'] });
  return checks;
}

// Issue text as data. The delimiter carries a random nonce, so the text cannot close it.
export function untrustedBlock(issue, nonce) {
  const tag = `untrusted-issue-${nonce}`;
  const clean = (s) => String(s ?? '').split(tag).join('[removed]');
  return [
    `<${tag}>`,
    `Issue #${issue.number}: ${clean(issue.title)}`,
    '',
    clean(issue.body) || '(no description)',
    `</${tag}>`,
  ].join('\n');
}

export function lockIsStale(owner, alive) {
  return !owner || !Number.isInteger(owner.pid) || !alive(owner.pid);
}

// ---- side effects ----

class StageError extends Error {
  // `summary` is posted on the issue, so it is always this script's own text.
  constructor(stage, summary, detail = '') {
    super(`${stage}: ${summary}`);
    Object.assign(this, { stage, summary, detail });
  }
}

function run(cmd, args, opts = {}) {
  const r = spawnSync(cmd, args, { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024, ...opts });
  return { rc: r.status ?? 1, out: r.stdout ?? '', err: (r.stderr ?? '').trim(), timedOut: r.error?.code === 'ETIMEDOUT' };
}

function must(stage, summary, cmd, args, opts) {
  const r = run(cmd, args, opts);
  if (r.rc !== 0) throw new StageError(stage, summary, `${cmd} ${args.join(' ')}\n${r.err || r.out}`);
  return r.out;
}

function alive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return e.code === 'EPERM';
  }
}

function acquireLock(dir) {
  const owner = path.join(dir, 'owner.json');
  try {
    fs.mkdirSync(dir);
  } catch (e) {
    if (e.code !== 'EEXIST') throw e;
    let o = null;
    try { o = JSON.parse(fs.readFileSync(owner, 'utf8')); } catch { /* unreadable: stale */ }
    if (!lockIsStale(o, alive)) throw new Error(`another agent-pick run is active (pid ${o.pid}, lock ${dir})`);
    fs.rmSync(dir, { recursive: true, force: true });
    fs.mkdirSync(dir);
  }
  fs.writeFileSync(owner, JSON.stringify({ pid: process.pid, startedAt: new Date().toISOString() }));
  return () => fs.rmSync(dir, { recursive: true, force: true });
}

const comment = (n, body, cwd) => run('gh', ['issue', 'comment', String(n), '--body', body], { cwd });
const relabel = (n, add, remove, cwd) =>
  run('gh', ['issue', 'edit', String(n), '--add-label', add, ...remove.flatMap((l) => ['--remove-label', l])], { cwd });

function claudeArgs() {
  return [
    '-p', '--output-format', 'json', '--no-session-persistence',
    '--strict-mcp-config', '--setting-sources', 'project',
    '--permission-mode', 'dontAsk', '--permission-prompts', 'none',
    '--tools', 'Read,Edit,Write,Glob,Grep,Bash',
    '--allowedTools', 'Read,Edit,Write,Glob,Grep,Bash(make lint),Bash(make test),Bash(npm --prefix server test),Bash(node --test scripts/test/*.test.mjs),Bash(git status),Bash(git diff:*)',
    '--disallowedTools', 'WebFetch,WebSearch,Bash(gh:*),Bash(git push:*),Bash(curl:*),Bash(wget:*)',
  ];
}

function changedFiles(wt) {
  must('diff', 'could not read the change', 'git', ['add', '-A'], { cwd: wt });
  return must('diff', 'could not read the change', 'git', ['diff', '--cached', '--name-only', '-z'], { cwd: wt }).split('\0').filter(Boolean);
}

function main(argv) {
  const dryRun = argv.includes('--dry-run');
  const allowProtected = argv.includes('--allow-protected');
  const ti = argv.indexOf('--timeout-min');
  const timeoutMin = ti >= 0 ? Number(argv[ti + 1]) : 60;
  if (!(timeoutMin > 0) || argv.some((a) => a.startsWith('--') && !['--dry-run', '--allow-protected', '--timeout-min'].includes(a))) {
    console.error('usage: scripts/agent-pick.mjs [--dry-run] [--allow-protected] [--timeout-min N]');
    return 2;
  }

  const root = must('setup', 'not in a git checkout', 'git', ['rev-parse', '--show-toplevel']).trim();
  const common = must('setup', 'not in a git checkout', 'git', ['rev-parse', '--path-format=absolute', '--git-common-dir'], { cwd: root }).trim();
  const mainRoot = path.dirname(common);
  const rules = parseCodeowners(fs.readFileSync(path.join(root, '.github', 'CODEOWNERS'), 'utf8'));
  const promptFile = path.join(root, 'scripts', 'agent-prompt.md');

  const listed = run('gh', ['issue', 'list', '--label', READY, '--state', 'open', '--limit', '200',
    '--json', 'number,title,body,labels,createdAt,url,closedByPullRequestsReferences'], { cwd: root });
  if (listed.rc !== 0) {
    console.error(`agent-pick: gh issue list failed: ${listed.err}`);
    return 2;
  }
  const prs = run('gh', ['pr', 'list', '--state', 'open', '--limit', '200', '--json', 'body,headRefName'], { cwd: root });
  if (prs.rc !== 0) {
    console.error(`agent-pick: gh pr list failed: ${prs.err}`);
    return 2;
  }
  let issue = null;
  for (const i of eligibleIssues(JSON.parse(listed.out), issuesInFlight(JSON.parse(prs.out)))) {
    const hits = protectedHits(mentionedPaths(`${i.title}\n${i.body}`), rules);
    if (hits.length && !allowProtected) {
      console.log(`skip #${i.number}: its text names CODEOWNERS paths (${hits.join(', ')}); use --allow-protected`);
      continue;
    }
    issue = i;
    break;
  }
  if (!issue) {
    console.log(`agent-pick: no eligible open ${READY} issue.`);
    return 0;
  }

  const branch = `agent/${issue.number}-${slugify(issue.title)}`;
  const wt = path.join(mainRoot, '.claude', 'worktrees', branch.replace('/', '-'));
  if (dryRun) {
    console.log([
      'agent-pick plan (dry run, nothing changed):',
      `  issue      #${issue.number} ${issue.title}`,
      `  labels     +agent-running -${READY}`,
      `  worktree   ${wt}`,
      `  branch     ${branch} from origin/main`,
      `  agent      claude ${claudeArgs().join(' ')} < ${path.relative(root, promptFile)} + issue text (untrusted block)`,
      `  timeout    ${timeoutMin} min`,
      `  protected  ${allowProtected ? 'allowed (--allow-protected)' : 'refused: a diff touching CODEOWNERS paths fails the run'}`,
      '  checks     chosen from the diff: make lint + make test (App/), npm test (server/), node --test (scripts/*.mjs)',
      `  publish    commit, push ${branch}, draft PR "Closes #${issue.number}", label agent-review`,
      '  on failure label agent-failed + stage summary comment; worktree kept',
    ].join('\n'));
    return 0;
  }

  const release = acquireLock(path.join(common, 'agent-pick.lock'));
  try {
    for (const [name, color, desc] of LABEL_DEFS) run('gh', ['label', 'create', name, '--color', color, '--description', desc, '--force'], { cwd: root });
    const claimed = relabel(issue.number, 'agent-running', [READY], root);
    if (claimed.rc !== 0) {
      console.error(`agent-pick: could not label #${issue.number} agent-running: ${claimed.err}`);
      return 2;
    }
    console.log(`agent-pick: #${issue.number} ${issue.title}\n  worktree ${wt}\n  branch   ${branch}`);
    try {
      const prUrl = work({ issue, branch, wt, root, rules, promptFile, allowProtected, timeoutMin });
      relabel(issue.number, 'agent-review', ['agent-running'], root);
      comment(issue.number, `agent-pick opened a draft PR: ${prUrl}`, root);
      console.log(`agent-pick: draft PR ${prUrl}`);
      return 0;
    } catch (e) {
      const se = e instanceof StageError ? e : new StageError('internal', 'unexpected error in agent-pick', e.stack);
      relabel(issue.number, 'agent-failed', ['agent-running'], root);
      comment(issue.number, [
        `agent-pick stopped at stage \`${se.stage}\`: ${se.summary}.`,
        '',
        'Details and the worktree are on the maintainer machine that ran it. To retry: remove `agent-failed`, add `agent-ready`.',
      ].join('\n'), root);
      console.error(`agent-pick: FAILED ${se.message}\n${se.detail}\n  worktree kept: ${wt}`);
      return 1;
    }
  } finally {
    release();
  }
}

function work({ issue, branch, wt, root, rules, promptFile, allowProtected, timeoutMin }) {
  must('worktree', 'git fetch origin main failed', 'git', ['fetch', 'origin', 'main'], { cwd: root });
  fs.mkdirSync(path.dirname(wt), { recursive: true });
  must('worktree', 'could not create the worktree (branch or path may already exist)', 'git', ['worktree', 'add', '-b', branch, wt, 'origin/main'], { cwd: root });
  if (fs.existsSync(path.join(wt, 'server', 'package-lock.json'))) {
    must('setup', 'npm ci in server/ failed', 'npm', ['ci'], { cwd: path.join(wt, 'server') });
  }

  const allow = allowProtected ? '\n\nProtected paths: allowed (the maintainer ran --allow-protected).' : '';
  const prompt = `${fs.readFileSync(promptFile, 'utf8').trim()}${allow}\n\n${untrustedBlock(issue, crypto.randomBytes(8).toString('hex'))}\n`;
  // The agent gets no GitHub token from the environment; gh is also denied as a tool.
  const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !/^(GH_|GITHUB_)/.test(k)));
  const agent = run('claude', claudeArgs(), { cwd: wt, input: prompt, env, timeout: timeoutMin * 60_000 });
  if (agent.timedOut) throw new StageError('agent', `claude did not finish in ${timeoutMin} min`);
  let result = {};
  try { result = JSON.parse(agent.out); } catch { /* handled below */ }
  if (agent.rc !== 0 || result.is_error) throw new StageError('agent', `claude exited with code ${agent.rc}`, agent.err || agent.out.slice(-4000));

  const files = changedFiles(wt);
  if (!files.length) throw new StageError('diff', 'the agent made no changes');
  if (neverFiles(files).length) throw new StageError('policy', `${neverFiles(files).length} file(s) of a kind agents must never commit (.env, keys, .xcodeproj)`);
  const hits = protectedHits(files, rules);
  if (hits.length && !allowProtected) throw new StageError('policy', `the change touches CODEOWNERS paths (${hits.join(', ')}); rerun with --allow-protected after review`);

  const checks = checksFor(files);
  for (const c of checks) {
    const r = run(c.cmd, c.args, { cwd: wt, timeout: 45 * 60_000 });
    if (r.rc !== 0) throw new StageError('verify', `\`${c.name}\` failed`, (r.err || r.out).slice(-4000));
  }
  // Verification ran model-written code: read the change again before committing it.
  const after = changedFiles(wt);
  if (protectedHits(after, rules).length > hits.length || neverFiles(after).length) throw new StageError('policy', 'the checks changed protected files');

  const title = `Fix #${issue.number}: ${issue.title.replace(/[\r\n]+/g, ' ')}`.slice(0, 120);
  // --no-verify: the checks above already ran; a hook in the worktree is not trusted.
  must('publish', 'git commit failed', 'git', ['commit', '--no-verify', '-q', '-m', `${title}\n\nCo-Authored-By: Claude <noreply@anthropic.com>`], { cwd: wt });
  must('publish', 'git push failed', 'git', ['push', '--no-verify', '-u', 'origin', branch], { cwd: wt });
  const summary = String(result.result ?? '').replace(/`{3,}/g, "'''").slice(0, 3000);
  const body = [
    `Closes #${issue.number}`,
    '',
    'Draft opened by `scripts/agent-pick.mjs`. A human reviews and merges; see `.claude/skills/babysit-pr/SKILL.md`.',
    '',
    '## Checks run by the script',
    checks.length ? checks.map((c) => `- PASS ${c.name}`).join('\n') : '- none apply to the changed files (docs only)',
    '',
    `## Files (${after.length})`,
    ...after.map((f) => `- \`${f.replace(/`/g, '')}\``),
    '',
    '## Agent summary (model output, unverified)',
    '```text', summary || '(none)', '```',
    '',
    '🤖 Generated with [Claude Code](https://claude.com/claude-code)',
  ].join('\n');
  const bodyFile = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'agent-pick-')), 'body.md');
  fs.writeFileSync(bodyFile, body);
  try {
    return must('publish', 'gh pr create failed', 'gh', ['pr', 'create', '--draft', '--base', 'main', '--head', branch, '--title', title, '--body-file', bodyFile], { cwd: wt }).trim();
  } finally {
    fs.rmSync(bodyFile, { force: true });
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    process.exitCode = main(process.argv.slice(2));
  } catch (e) {
    console.error(`agent-pick: ${e.message}${e.detail ? `\n${e.detail}` : ''}`);
    process.exitCode = 2;
  }
}
