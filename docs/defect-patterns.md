# Defect patterns

Mistakes this repo has made more than once. Each one was found in review after
the author's own tests passed. Read this before you start work and before you
review. It is not a style guide and not a checklist to tick.

## Rules

- **Add a pattern at its third instance.** One or two instances go under
  [Watching](#watching). The third instance, from a different PR, moves it up.
- **After a review finding**, look the defect up here. Listed: add the PR to its
  instances and bump "Last seen". New: add it under Watching. The agent loop
  (`scripts/agent-pick.mjs`, `.claude/skills/babysit-pr/SKILL.md`) does this too.
- **Prune after 3 months unused.** A pattern whose "Last seen" is more than 3
  months old is deleted, not kept for completeness. Same for Watching entries.
- Each instance names the PR and the file. Keep entries short.

## Format

```
## Dn. <name>
<what it looks like, one or two sentences>
| PR | Where | What went wrong |
**Check:** <the question that catches it>
Last seen: YYYY-MM-DD
```

## D1. A stale async result overwrites newer state

A request, timer or callback finishes after the user or the app has moved on,
and its result is applied anyway: old results for a new query, a route for a
trip that ended, a prompt for a maneuver already passed.

| PR | Where | What went wrong |
|---|---|---|
| #26 | `SearchView.swift` | results for the previous query stayed on screen; cancellation was not checked |
| #26 | `MapView.swift` | the first-GPS-fix zoom moved the map away from a destination picked meanwhile |
| #34 | `Navigator.swift` | a route response for an ended trip was applied (fixed with a trip counter) |
| #34 | `Speech.swift` | queued prompts for older maneuvers were still spoken after a reroute |

**Check:** for every `await`, callback or timer, what if the state changed
before it returned? Tag the request (counter, id, `.task(id:)`) and drop
results that do not match. Test it with an injected fetch that resolves late.

Last seen: 2026-10-22

## D2. The boundary is not tested

The code is right in the middle of the range and wrong at the edge: exactly at
expiry, exactly at a cap, zero, the first or last element. The tests only used
comfortable values.

| PR | Where | What went wrong |
|---|---|---|
| #12 | `Zoom.swift` | accuracy 0 did not map to max zoom |
| #17 | `server/src/app.ts` | rate window, expiry and bbox-at-cap boundaries untested; float error at the cap |
| #34 | `Guidance.swift`, `Route` | looped routes and zero-length steps matched the wrong step |

**Check:** for each limit, test the value just inside, exactly at, and just
outside it. For each collection, test empty, one, and repeated elements.

Last seen: 2026-10-22

## D3. A vague or old GPS fix is treated as truth

The code acts on a location without asking how accurate or how old it is, so
a cached fix or a 300 m cell-tower fix triggers zoom, reroute or arrival.

| PR | Where | What went wrong |
|---|---|---|
| #12 | `Zoom.swift`, `MapView.swift` | the first-fix zoom used old or very inaccurate fixes (now age <= 10 s, 0 to 500 m) |
| #34 | `Navigator.swift` | fixes vaguer than 50 m counted towards going off route |
| #34 | `Navigator.swift` | arrival fired from a parallel street; now needs to be on the road |

**Check:** every use of a `CLLocation` checks `horizontalAccuracy` (and
`timestamp` where it matters). Test with a vague fix.

Last seen: 2026-10-22

## D4. A precise location leaves the device unrounded

A user's exact coordinates go to a third party or into storage, where a
rounded value would do (`AGENTS.md`, "Never").

| PR | Where | What went wrong |
|---|---|---|
| #26 | `Photon.swift` | the search bias sent the exact position (now rounded to 2 decimals) |
| #34 | `Router.swift` | the OSRM demo server gets the exact origin (open: self-host before release) |
| #43 | `server/src/app.ts` | reports were stored with full precision (now 4 decimals) |

**Check:** for every request or row that carries coordinates, what precision
does it need? Round before it leaves the function.

Last seen: 2026-10-22

## Watching

Fewer than three instances. Move up at the third.

- **The end or cancel path leaves state behind.** #34 `Speech.swift`: `stop()`
  left the audio session active and `didCancel` was not handled, so other audio
  stayed ducked. #34 `LocationFeed`: background updates must be on only while
  navigating. Last seen: 2026-10-22
- **An HTTP error is read as data.** A non-2xx body decoded as results, or
  every failure handled the same. #26 `Photon.swift`: no status check (now
  `PhotonError.http`). #34 `Navigator.swift`: a 429/5xx on reroute stopped
  rerouting (now retries with backoff). `Router.swift` (#34) checked status
  from its first commit, so it is not counted. Last seen: 2026-10-22
- **One bad element fails the whole payload.** #26 `Photon.swift`: one
  malformed feature failed the search (now `Lossy<Feature>`). #34 `Route`: empty
  geometry crashed init. `Router.swift` decoded per element from its first
  commit. Last seen: 2026-10-22
- **A gate that the PR under check can weaken.** #35: CI now runs the base
  branch's copy of `check-test-bites.sh`, and the AI review agent holds no
  write token. Last seen: 2026-10-22
