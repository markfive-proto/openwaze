# PR gate

What a pull request must get through before it merges to `main`.

## 1. `ci-ok` (required)

`.github/workflows/ci.yml` runs only the jobs your change touches (iOS, server,
test bites), and `ci-ok` passes when each of them passed or was skipped. It is
the one required status check on `main`.

## 2. Tests must bite

If a PR adds or edits a server test (`server/src/**/*.test.ts`), the
`test-bites` job runs `scripts/check-test-bites.sh`. For every changed test file
it:

1. copies the PR's version of the test onto the **base branch's** source and
   runs it. It must **fail** there. A test for code that does not exist yet
   fails to import, and that counts as a fail.
2. runs it on the PR's head. It must **pass**.

A test that passes on the base branch is decorative (it would pass with or
without your change) and fails the job. Fix it so it checks the new behaviour.

Run it yourself before pushing:

```sh
(cd server && npm ci)
scripts/check-test-bites.sh            # base defaults to origin/main
```

iOS tests (`App/Tests/**`) are **not** checked. Doing so needs two `xcodebuild`
runs on a macOS runner for every PR. The script lists changed iOS tests so the
gap is visible. Reviewers should check by hand that a new iOS test fails
without the change.

## 3. Pre-push hook

`make bootstrap` sets `git config core.hooksPath scripts/githooks`. Before each
push, `scripts/githooks/pre-push` runs `make lint` if `App/` changed and the
server tests if `server/` changed. To skip it once, use `git push --no-verify`.
CI still runs everything.

## 4. Human review (CODEOWNERS)

`.github/CODEOWNERS` assigns @markfive-proto to these paths:

- location, probe and share code (`App/Sources/**/Location*`, `Probe*`, `Share*`)
- `server/src/`, where report storage and data retention live
- the gate itself: `.github/`, `scripts/`, `Makefile`
- agent and editor config: `.claude/`, `.mcp.json`, `.vscode/`
- `docs/security/` and `docs/privacy.md`

A PR that touches these paths needs that owner's approval. This is enforced only
when the branch rule on `main` has "Require review from Code Owners" turned on.

## 5. AI review (advisory)

`.github/workflows/ai-review.yml` runs `anthropics/claude-code-action`. The
action is pinned by commit SHA to v1.0.250, which is newer than the CVE-2026-47751
fix in 1.0.74. The review:

- runs on `pull_request`, never `pull_request_target`, and only for branches in
  this repository. PRs from forks are not reviewed.
- has only `contents: read` and `pull-requests: write`.
- checks out the **base** commit and reads the PR through `gh pr diff`, so no
  `.mcp.json`, `.claude/` or `.vscode/` file from the PR is ever loaded. It
  also runs with `--strict-mcp-config` and `--setting-sources user`, and has no
  web access.
- treats the PR text and diff as untrusted data. It posts one review, with
  findings tagged `[P1]` (must fix), `[P2]` (should fix) or `[P3]` (nit). Any
  `[P1]` finding makes it a "request changes" review.

The AI review is not part of `ci-ok`, so it can be skipped without blocking a
merge. Read its findings anyway. A `[P1]` needs a fix or a reply.

**Turning it on (maintainer):** add the API key as a repository secret. Either
go to Settings > Secrets and variables > Actions > New repository secret and
name it `ANTHROPIC_API_KEY`, or run `gh secret set ANTHROPIC_API_KEY -R
markfive-proto/openwaze`. Without the key, the job prints a notice and does
nothing.

See `docs/security/known-vulns.md` ("Actions for openwaze", 5 to 12) for the
reasons behind these rules.
