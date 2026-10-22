# Known vulnerabilities and incidents (May to Oct 2026)

Last reviewed: 2026-10-22

This covers recent security issues in the stack openwaze will likely use, and the
supply-chain incidents that shape how we build. It feeds the rules in AGENTS.md and the
PR gate (#4, #6). Every entry links a primary source: a vendor advisory, a GitHub
Security Advisory (GHSA), NVD, or the maintainer's or security firm's write-up. Where a
detail could not be confirmed, it is left out or marked *unconfirmed*.

To refresh this file: re-check each source, add new entries, drop entries older than
about 6 months unless they still drive a rule, and update the date above.

Entry IDs (P1, N1, ...) are referenced from [Actions for openwaze](#actions-for-openwaze).

## PHP

| # | ID | Date | Affected | Fixed | Impact | Source |
|---|---|---|---|---|---|---|
| P1 | CVE-2026-109618 (GHSA-w8hw-w9fx-j79w) | 2026-10-21 | All supported branches before the fix | 8.2.35, 8.3.36, 8.4.27, 8.5.12 | Critical. Unauthenticated RCE: out-of-memory handling leaves request data half-initialized and cleanup trusts it. php.net says there is no complete mitigation; mod_php has a demonstrated pre-application exploit. | [php.net archive](https://www.php.net/archive/2026.php), [GHSA](https://github.com/php/php-src/security/advisories/GHSA-w8hw-w9fx-j79w) |
| P2 | CVE-2026-109619 (GHSA-6wmf-4rv5-p3rp) | 2026-10-21 | Same as P1 | Same as P1 | Critical. Unauthenticated RCE: freed request state survives into the next request on the same worker. RCE was confirmed on mod_php and, via the session path, on FPM. LSAPI is a conditional candidate. | [php.net archive](https://www.php.net/archive/2026.php), [GHSA](https://github.com/php/php-src/security/advisories/GHSA-6wmf-4rv5-p3rp) |
| P3 | CVE-2026-91765, -91766, -91767, -91768, -91769 and others | 2026-09-24 | Before the fixed versions | 8.2.34, 8.3.35, 8.4.26, 8.5.11 | Security release. It includes unbounded SOAP recursion, cross-origin credential leak on HTTP stream redirects, a heap overflow in the OpenSSL wildcard match, an FPM IPv6 `allowed_clients` ACL bypass, and TLS hostname check falling back to CN. | [php.net news](https://www.php.net/), [ChangeLog 8.5.11](https://www.php.net/ChangeLog-8.php) |
| P4 | CVE-2026-17543, CVE-2026-17544, CVE-2026-9672, CVE-2026-7260 | 2026-07-30 | Before the fixed versions | 8.2.33, 8.3.33, 8.4.24, 8.5.9 | Security release. It includes SQL injection in PGSQL escaping via `E'...'` backslash breakout, an out-of-bounds write in `bccomp()`, a libgd update, and a Phar recursive-symlink crash. | [php.net news](https://www.php.net/), [ChangeLog 8.5.9](https://www.php.net/ChangeLog-8.php) |
| P5 | CVE-2026-6735, CVE-2025-14179, CVE-2026-7261 and others | 2026-05-07 | Before the fixed versions | 8.2.31, 8.3.31, 8.4.21, 8.5.6 | Security release. It includes XSS in the FPM status page, SQL injection in PDO_Firebird via NUL bytes, and a SOAP use-after-free. | [php.net archive](https://www.php.net/archive/2026.php), [ChangeLog 8.5.6](https://www.php.net/ChangeLog-8.php) |
| P6 | WordPress core security releases | 2026-07-17 to 2026-10-06 | Before the fixed versions | 7.0.2 (Jul 17), 7.0.3, 7.0.4, 7.1.1, 7.1.2 (Sep 22), 7.1.3 (Oct 6) | 7.0.2 fixed one critical and one high-severity issue and forced auto-updates. 7.1.2 fixed one critical issue. CVE IDs are *unconfirmed*: secondary sources disagree. | [wordpress.org security news](https://wordpress.org/news/category/security/) |

Note: PHP 8.2 reaches end of life on 2026-12-31, and 8.1 and older no longer get fixes ([php.net](https://www.php.net/archive/2026.php)). The per-CVE lists above were checked against the 8.5 ChangeLog. The 8.2, 8.3 and 8.4 fixed versions come from the php.net release announcements.

## Node.js runtime

| # | Release | Date | Fixed versions | Highlights | Source |
|---|---|---|---|---|---|
| N1 | October 2026 security release | 2026-10-21 | 22.23.4, 24.22.1, 26.12.1 | CVE-2026-111497 (High): Brotli decoder out-of-bounds write, RCE. CVE-2026-106069 and CVE-2026-105483 (High): TLS hostname verification bypasses. CVE-2026-105482 (High): `dns.resolve` NUL truncation. CVE-2026-106074 (Medium): `crypto.randomUUID()` entropy cache baked into snapshots and SEAs. Also ships a CA-store update for the compromised eMudhra intermediate certificate. | [nodejs.org](https://nodejs.org/en/blog/vulnerability/october-2026-security-releases) |
| N2 | July 2026 security release | 2026-07-29 | 22.23.2, 24.18.1, 26.5.1 | CVE-2026-56848 (High): nghttp2 heap use-after-free. CVE-2026-56846 (High): HTTP/2 `maxSessionMemory` bypass. CVE-2026-58043 (High): Permission Model over-grants filesystem access. CVE-2026-58044 (Low): request smuggling via hidden excess headers. | [nodejs.org](https://nodejs.org/en/blog/vulnerability/july-2026-security-releases) |
| N3 | June 2026 security release | 2026-06-18 | 22.23.0, 24.17.0, 26.3.1 | CVE-2026-48618 (High): TLS wildcard-depth auth bypass via Unicode dots. CVE-2026-48933 (High): WebCrypto AES integer overflow crash. CVE-2026-48934 and CVE-2026-48928 (Medium): TLS session reuse and SNI case bypasses. OpenSSL 3.5.7. | [nodejs.org](https://nodejs.org/en/blog/vulnerability/june-2026-security-releases) |
| N4 | End-of-life lines | n/a | None | Each advisory says EOL lines are affected and not patched. Node 18 and 20 are EOL. | [nodejs.org previous releases](https://nodejs.org/en/about/previous-releases) |

## npm supply chain

| # | Incident | Date | Affected | Fixed / remediation | Impact | Source |
|---|---|---|---|---|---|---|
| S1 | TanStack Router compromise (GHSA-g7cv-rxg3-hmpx) | 2026-05-11 | 84 versions across 42 `@tanstack/*` packages (Router/Start repo) | Versions deprecated and tarballs removed the same day | A `pull_request_target` "pwn request" poisoned the Actions cache, and the release job then leaked an OIDC token. The publishes went through the project's legitimate OIDC trusted-publisher binding, and the payload stole credentials and self-propagated. | [TanStack postmortem](https://tanstack.com/blog/npm-supply-chain-compromise-postmortem) |
| S2 | Mini Shai-Hulud wave: `@antv/*` and others | 2026-05-19 | 639 versions across 323 packages, e.g. `@antv/g2`, `echarts-for-react`, `timeago.js` | Remove the bad versions and rotate credentials | A maintainer account was hijacked. A `preinstall` hook ran Bun and harvested cloud, CI and password-manager credentials. | [Unit 42](https://unit42.paloaltonetworks.com/monitoring-npm-supply-chain-attacks/) |
| S3 | `@redhat-cloud-services/*` (Miasma) | 2026-06-01 | At least 32 packages (versions listed in source) | Remove the bad versions and rotate credentials | A compromised employee GitHub account pushed orphan commits and bypassed review. The release workflows then published trojans with valid SLSA provenance. | [Unit 42](https://unit42.paloaltonetworks.com/monitoring-npm-supply-chain-attacks/) |
| S4 | `@mastra/*` scope via `easy-day-js` | 2026-06-17 | 142 to 144 packages. Malicious dependency `easy-day-js` 1.11.22 (1.11.21 was a clean cover release) | Forward-rolled clean releases, e.g. `@mastra/core` 1.42.0 (1.42.1 is malicious, so confirm a known-good version). Regenerate lockfiles. | A former contributor's npm access was never revoked. The attacker added a caret-range dependency whose `postinstall` dropped a wallet stealer and RAT. | [Snyk](https://snyk.io/blog/a-forgotten-contributor-account-compromised-the-entire-mastra-npm-package-scope/) |
| S5 | AsyncAPI release pipelines | 2026-07-14 | `@asyncapi/generator` 3.3.1, `@asyncapi/specs` 6.11.2, `generator-helpers` 1.1.1, `generator-components` 0.7.1 | Remove the bad versions and rotate credentials | Direct pushes to unprotected pre-release branches triggered the release workflows, which leaked npm and GitHub tokens. Unit 42 saw a Copilot workspace parse load the trojan. | [Unit 42](https://unit42.paloaltonetworks.com/monitoring-npm-supply-chain-attacks/) |
| S6 | Shai-Hulud "ChainDrop": `keyv`, `cacheable`, `flat-cache` and others | 2026-08-04 | e.g. `keyv` 6.0.0, `flat-cache` 6.1.24, `file-entry-cache` 11.1.6, `cache-manager` 7.2.10. At least 444 packages and 1,381 versions by Aug 5. | Remove the bad versions, rebuild affected hosts, rotate credentials | The maintainer's GitHub account was hijacked and malicious code pushed to main. The project's own release workflow published it, so it had valid provenance. A `preinstall` worm steals tokens, republishes the victim's packages, and commits hooks into `.claude/settings.json` and `.vscode/tasks.json`. | [Aikido](https://www.aikido.dev/blog/keyv-and-friends-compromised-in-npm-supply-chain-attack), [CSA Singapore AD-2026-009](https://csa.gov.sg/alerts-and-advisories/advisories/ad-2026-009) |

Common pattern: stolen or stale maintainer access, or a CI release job, publishes a version
with an install script. A legitimate publishing identity or valid provenance did **not** prove a release was safe in S1, S3 and S6.

## Swift, iOS, Xcode, SwiftPM

| # | ID | Date | Affected | Fixed | Impact | Source |
|---|---|---|---|---|---|---|
| I1 | CVE-2026-86950 (CoreGraphics) | 2026-09-28 | iOS/iPadOS 26 before 26.7.1 | iOS/iPadOS 26.7.1 | Out-of-bounds write. Processing a crafted file can lead to code execution. Apple says it may have been exploited against targeted individuals. | [Apple HT 149226](https://support.apple.com/en-us/149226) |
| I2 | CVE-2026-86949, CVE-2026-86948, CVE-2026-65393 and others | 2026-09-14 | Xcode before 27 | Xcode 27 (macOS Tahoe 26.6+) | Sandbox escapes and an IDE issue that exposes user-sensitive data. Crafted binaries crash otool and CoreSymbolication. | [Apple HT 149040](https://support.apple.com/en-us/149040) |
| I3 | CVE-2026-28970 (GHSA-cq87-8r7h-962v) | 2026-05-21 | swift-nio 2.0.0 to 2.99.0 | 2.100.0 | CRLF injection in outbound HTTP/1.1 start lines, enabling request smuggling and response splitting. | [GHSA](https://github.com/apple/swift-nio/security/advisories/GHSA-cq87-8r7h-962v) |
| I4 | CVE-2026-43671 (GHSA-r3rc-9hpw-54v9) | 2026-05-21 | swift-nio 1.0.0 to 2.99.0 | 2.100.0 | ByteBuffer UInt32 truncation leads to an out-of-bounds write. | [GHSA](https://github.com/apple/swift-nio/security/advisories/GHSA-r3rc-9hpw-54v9) |
| I5 | CVE-2026-43678 (GHSA-qcc5-f287-vgmq) | 2026-07-09 | swift-nio up to 2.100.0 | 2.101.0 | One malformed WebSocket frame crashes NIOWebSocket servers (remote DoS). | [GHSA](https://github.com/apple/swift-nio/security/advisories/GHSA-qcc5-f287-vgmq) |
| I6 | CVE-2026-43820 (GHSA-xfxg-9975-pc2j) | 2026-07-15 | swift-nio-ssl 2.18.0 to 2.37.1 | 2.37.2 | Critical. Out-of-bounds read when accessing non-string SAN bytes. | [GHSA](https://github.com/apple/swift-nio-ssl/security/advisories/GHSA-xfxg-9975-pc2j) |

SwiftPM itself: no 2026 advisory found. The ecosystem risk is still structural.
`Package.swift` is code that runs when packages are resolved, and dependencies are
usually pinned by version range or tag, not by commit.

## MapLibre and map tile stack

| # | ID | Date | Affected | Fixed | Impact | Source |
|---|---|---|---|---|---|---|
| M1 | CVE-2026-85061 (GHSA-jrc7-96c5-q579) | 2026-08-19 | `maplibre-gl` (npm) up to 6.4.0 | 6.4.1 | Critical (CVSS 10.0). `DOM.sanitize()` skips attributes while mutating a live NamedNodeMap, which allows zero-click XSS via untrusted style or attribution strings. | [GHSA](https://github.com/maplibre/maplibre-gl-js/security/advisories/GHSA-jrc7-96c5-q579) |

maplibre-native (the iOS/Android SDK) has no published advisories ([advisories page](https://github.com/maplibre/maplibre-native/security/advisories)).
For tile servers (tileserver-gl, Martin, PMTiles), the only 2026 records found were
distro-packaging advisories for transitive npm dependencies. No upstream advisory could be
verified, so none are listed.

## GitHub Actions

| # | Incident | Date | Affected | Fixed / remediation | Impact | Source |
|---|---|---|---|---|---|---|
| G1 | `codfish/semantic-release-action` tag hijack | 2026-06-24 (15:39 UTC) | Every workflow that referenced the action by tag (v1 to v5, 23 tags repointed) | Pin to an independently verified full commit SHA. Review runs after the compromise time and rotate secrets. | Imposter orphan commits replaced the Docker action with a composite action that ran an obfuscated payload. It stole OIDC tokens and PATs, scraped Runner.Worker memory, and planted `.claude/` and `.vscode/` files with `skip-checks:true`. Workflows pinned by SHA were unaffected. | [StepSecurity](https://www.stepsecurity.io/blog/supply-chain-compromise-codfish-semantic-release-action) |
| G2 | `pull_request_target` plus cache poisoning (TanStack) | 2026-05-11 | `bundle-size.yml` built fork code under `pull_request_target` | `repository_owner` guards, SHA-pinned actions, cache purge | `permissions: read` did not stop `actions/cache` from saving a poisoned cache that the release job later restored. See S1. | [TanStack postmortem](https://tanstack.com/blog/npm-supply-chain-compromise-postmortem) |
| G3 | Release-on-push from unprotected or hijacked branches | 2026-06-01, 2026-07-14, 2026-08-04 | Red Hat (S3), AsyncAPI (S5), keyv (S6) | Branch protection and rulesets on every branch that can trigger a release. Require review before publish. | Attackers did not need to break CI. They pushed to a branch that the release workflow trusted. | [Unit 42](https://unit42.paloaltonetworks.com/monitoring-npm-supply-chain-attacks/), [Aikido](https://www.aikido.dev/blog/keyv-and-friends-compromised-in-npm-supply-chain-attack) |

## AI coding agents and MCP

| # | ID | Date | Affected | Fixed | Impact | Source |
|---|---|---|---|---|---|---|
| A1 | CVE-2026-47751 (GHSA-8q5r-mmjf-575q) | 2026-05-20 | `anthropics/claude-code-action` before 1.0.74 | 1.0.74 | A malicious `.mcp.json` in a PR gave RCE on the runner and exfiltrated workflow secrets: the action checked out the PR head and auto-enabled project MCP servers. | [GHSA](https://github.com/anthropics/claude-code-action/security/advisories/GHSA-8q5r-mmjf-575q) |
| A2 | CVE-2026-54316 (GHSA-fg94-h982-f3mm) | 2026-06-13 | `@anthropic-ai/claude-code` 0.2.54 to before 2.1.163 | 2.1.163 | Prompt injection in untrusted content made the agent exfiltrate data through WebFetch to a pre-approved domain (huggingface.co), encoding it in request paths. | [GHSA](https://github.com/anthropics/claude-code/security/advisories/GHSA-fg94-h982-f3mm) |
| A3 | CVE-2026-86063 (GHSA-pq7j-f95f-qfcv) | 2026-10-09 | `@anthropic-ai/claude-code` before 2.1.179 | 2.1.179 | A plugin pinned to a commit SHA could be swapped: the attacker creates a branch *named* after the SHA, and `git checkout` resolves to it. | [GHSA](https://github.com/anthropics/claude-code/security/advisories/GHSA-pq7j-f95f-qfcv) |
| A4 | CVE-2026-88066 (GHSA-4p2j-qj3c-6x84) | 2026-10-13 | Claude Desktop (Windows) before 1.8089.0 | 1.8089.0 | A `git.exe` planted in a cloned repo runs when the directory is opened, because `git` was resolved from the working directory first. | [GHSA](https://github.com/anthropics/claude-code/security/advisories/GHSA-4p2j-qj3c-6x84) |
| A5 | CVE-2026-48529 (GHSA-pjp5-fpmr-3349) | 2026-06-09 | `github-mcp-server` 0.22.0 to before 1.1.2 | 1.1.2 | In HTTP mode with lockdown enabled, a process-wide cache binds to the first user, so other users' checks run under that user's identity. | [GHSA](https://github.com/github/github-mcp-server/security/advisories/GHSA-pjp5-fpmr-3349) |
| A6 | CVE-2026-47427 (GHSA-w4q6-qw23-4rg7) | 2026-07-20 | `github-mcp-server` up to 0.33.0 | Not listed on the advisory (*unconfirmed*) | Unauthenticated nil-pointer crash in the `completion/complete` handler (DoS). | [GHSA](https://github.com/github/github-mcp-server/security/advisories/GHSA-w4q6-qw23-4rg7) |
| A7 | CVE-2026-75130 ("ContextCrush", Context7 MCP) | Reported to vendor Feb 2026. CVE publish date *unconfirmed*. | Context7 through 2.1.2 (per CVE record) | Vendor mitigated server-side, per Noma. Package fix version *unconfirmed*. | Library-owner "custom rules" reached coding agents unfiltered. A docs lookup could trigger credential theft and file deletion. | [NVD](https://nvd.nist.gov/vuln/detail/CVE-2026-75130) |
| A8 | Worms that plant agent config (S6, G1) | 2026-06-24, 2026-08-04 | Repos and machines that installed or ran the payload | Review diffs to agent config files. Rotate AI provider keys. | Both payloads commit `.claude/settings.json` hooks and `.vscode/tasks.json`, which then run the next time an agent or editor opens the repo. | [Aikido](https://www.aikido.dev/blog/keyv-and-friends-compromised-in-npm-supply-chain-attack), [StepSecurity](https://www.stepsecurity.io/blog/supply-chain-compromise-codfish-semantic-release-action) |

## Actions for openwaze

Each rule names the entries that motivate it.

1. **Commit lockfiles and install from them.** Commit `package-lock.json` (or the pnpm/yarn lockfile) and `Package.resolved`. CI uses `npm ci` (or `pnpm install --frozen-lockfile`) and `swift package resolve` with no lockfile updates. Lockfile changes go in their own reviewed PR. *Motivated by S4 (a caret range resolved to the armed version), S1, S2 and S6.*
2. **Pin exact versions and block install scripts by default.** Use exact npm versions (`save-exact=true`) and set `ignore-scripts=true` in `.npmrc`, allowlisting packages that really need scripts. Pin SwiftPM dependencies with `exact:` or a revision, not `from:`. Do not take a new release in its first few days unless it fixes one of the advisories above. *S2, S4, S6 (malicious `preinstall`/`postinstall`); I3 to I6 (know which swift-nio version you run).*
3. **Turn on Dependabot.** Enable Dependabot alerts and security updates for npm, SwiftPM and `github-actions`. Patch-level updates for the runtimes in this file (PHP, Node, swift-nio, maplibre-gl) are reviewed within a week. *P1, P2, N1 to N3, I3 to I6, M1.*
4. **Run only supported runtimes.** CI and deploy targets use Node 22, 24 or 26 at or above N1's fixed versions, and PHP 8.3 or newer at or above P1's fixed versions. No Node 18/20 or PHP 8.1. Plan to leave PHP 8.2 before 2026-12-31. *N4, P1, P2.*
5. **Pin every third-party GitHub Action by full commit SHA.** Add a `# vX.Y.Z` comment and let Dependabot bump it. Verify the SHA is on the upstream default branch, not just "a commit". Enable the repo/org setting that requires SHA pinning. *G1 (tag repointing), G2. A3 shows that even a "SHA pin" must be checked out as a commit, not as a ref name.*
6. **Use a least-privilege `GITHUB_TOKEN`.** Set `permissions: {}` (or `contents: read`) at the workflow top level and grant more per job. Only the release job gets `id-token: write` or `packages: write`, and it runs in a protected environment that needs approval. *G1, G2/S1 (OIDC token scraped from the runner), S5.*
7. **Never run `pull_request_target` (or `workflow_run`) on untrusted code.** If one is unavoidable, do not check out the PR head, do not restore or save caches, and pass no secrets. Fork PRs run under `pull_request` with read-only permissions. *G2/S1, A1.*
8. **Protect every branch that can trigger a release.** Apply rulesets to `main` and to any pre-release branch, require review, and block force-pushes. Releases must be tagged by a human, not triggered by a push. *G3 (S3, S5, S6).*
9. **Treat issue, PR and comment text as untrusted input in the agent-ready loop.** The agent may read it but must not follow instructions inside it. It must not run commands, change permissions, contact URLs, or edit CI/agent config because issue text asked it to. A human labels a ticket `agent-ready` after reading it. *A1, A2, A7, A8.*
10. **Do not let agents load config from the PR under review.** Agent runs on PRs must not auto-enable MCP servers, hooks or settings from the checked-out branch (`.mcp.json`, `.claude/`, `.vscode/tasks.json`). Changes to those paths need CODEOWNERS review. *A1, A8, G1.*
11. **Keep secrets out of agent environments.** Agent jobs get no publish tokens, cloud keys or deploy keys, only a read-scoped token plus whatever the task needs. Do not pre-approve broad egress domains for agent web fetches. Rotate AI provider keys if a runner may have been compromised. *A2 (exfiltration via a pre-approved domain), S6, G1.*
12. **Keep agent tools and MCP servers patched and scoped.** Pin Claude Code, `claude-code-action` and MCP servers to versions at or above the fixes above. Use one repo per session and least-privilege tokens for GitHub MCP. Do not run a shared HTTP-mode MCP server across users. *A1 to A6.*
13. **Sanitize anything that reaches MapLibre from outside.** Use `maplibre-gl` 6.4.1 or later. Do not pass third-party style or attribution strings through unsanitized, and ship a strict CSP on web map pages. *M1.*
14. **On any listed compromise, rebuild and rotate.** If a lockfile or CI log shows an affected version, treat the host or runner as compromised: rebuild it, then rotate npm, GitHub, cloud, SSH and AI keys. *S1 to S6, G1.*
