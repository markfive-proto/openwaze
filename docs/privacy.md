# Privacy and PDPA review

Status: draft for issue #31. **This is not legal advice.** It is an engineering review
by contributors. Section 7 lists what needs a lawyer. The notice text in section 8 is
text only; building it into the app is still open in #22.

Malaysia's Personal Data Protection Act 2010 (Act 709, "PDPA"), as amended by the
Personal Data Protection (Amendment) Act 2024 (Act A1727), is the law we design against.

## 1. What the code does today

Checked against `main` on 2026-10-22.

| Data | Where it goes | Retention | Who can see it | User control |
|---|---|---|---|---|
| **Report location** (lat/lng of a hazard report, rounded to 4 decimals, about 11 m, on write; plus type and time) | Our reports server (`server/src/app.ts`), SQLite `reports` table. Returned to anyone who queries a bbox. | Expires after 30-120 min by type. The row is deleted 1 h after expiry (cleanup runs every 5 min). A report with 2 downvotes expires at once. | Everyone using the API (public by design, no `deviceId`). | None yet. No delete-my-reports endpoint. Reports are short-lived. |
| **`deviceId`** (client-chosen, 1-128 chars, no accounts) | Same server: `reports.device_id` and `votes.device_id`. Used for rate limits and one-vote-per-report. Never returned by the API. | Reports: as above. Votes: deleted with their report (cascade). | Server operator only. | The client picks it, so a user can rotate it. The app does not send reports yet and no `DeviceID` code exists in `App/Sources`. |
| **Votes** (still there / gone) | `votes` table, tied to `deviceId` and report | Deleted with the report | Operator only | None yet |
| **Speed probes** (#13, server side only; the app does not send them yet) | Same server, `probes` table: grid cell (lat/lng rounded to 3 decimals, about 110 m), heading bucket (8), minute, speed, random per-trip `tripId`. `probe_posts`: `tripId` and time, for the per-trip rate limit. No `deviceId`, no IP, no exact position or time is stored. | Samples: deleted once 15 min old (probe cleanup every minute, so at most about 16 min). `probe_posts`: 1 min. | `GET /traffic` returns only cell, heading bucket and level (free/slow/jam), no speeds or counts, for cells with at least 3 distinct trips (a noise floor, not anonymity: see section 5). `tripId` is never returned. Operator sees raw rows. | Opt-out in the app (to build, #22). |
| **Shared trip** (share ETA #19, server side only; the app does not share yet) | Same server, `trips` table: destination (lat/lng rounded to 4 decimals, about 11 m), optional destination name, ETA, the **latest** position only (rounded to 4 decimals, heading), last update time. SHA-256 hashes of the share token and owner token, never the tokens. No `deviceId`, no IP, no position history. | Until the driver ends the trip, sends `arrived`, or 4 h after it started, whichever is first. End and arrival delete the row at once; expired rows are deleted by the trip cleanup within a minute. | Anyone holding the share link sees the latest position, destination, name and ETA via `GET /trips/current` (token in the `X-Share-Token` header) and the viewer page `/t/#<token>`. The token is never in a request path or log. Operator sees raw rows. | The driver starts each share and can stop it any time (app side to build). |
| **Share viewer page loads** | Viewers' browsers fetch MapLibre GL JS from jsDelivr (`cdn.jsdelivr.net`) and tiles from OpenFreeMap. `Referrer-Policy: no-referrer`, so neither gets the share URL. | Third party's policy | jsDelivr, OpenFreeMap (viewer IP, user agent) | Viewer's choice to open the link |
| **IP address** | Whatever fronts the server (host, reverse proxy, CDN). The app code does not log IPs. `console.error` logs errors only. | **Unknown, set by the host.** Decide before production. | Host operator | None |
| **Search text + rounded location bias** | Photon / Komoot (`photon.komoot.io`), from `Photon.swift`. Bias is rounded to 2 decimals (about 1 km). | Third party's policy | Komoot | Do not search |
| **Route origin and destination** | OSRM public demo server (`router.project-osrm.org`), from `Router.swift`. **Sent at full precision, not rounded.** | Third party's policy | OSRM demo operators | Do not route. See gap G1. |
| **Map tile requests** | OpenFreeMap (`tiles.openfreemap.org`), from `MapView.swift`. They see your IP and which tiles you load, which is roughly your area. | Third party's policy | OpenFreeMap | Do not use the map |
| **Saved places** | Planned local-only store. No `Places.swift` or SwiftData exists in the app yet. | On the device until the user deletes them | The user | Delete in app (to build) |
| **GPS position for navigation** | Stays on the device. Core Location, "when in use" only (`project.yml`). | Not stored | The user | iOS location permission |

Planned, not built: the app side of speed probes (#13) and share ETA (#19), onboarding and settings (#22).
Their rules are in section 5.

### Gaps found

- **G1. Routing sends the exact origin and destination to the OSRM demo server.** This breaks
  the `AGENTS.md` rule "Send a user's precise location to a third party. Round or drop it
  first." The origin is the user's real position, and the destination is often a home or
  workplace. Fix before any public release: self-host OSRM, or keep it to dev builds and say
  so in the notice. Needs its own ticket.
- **G2. The OSRM demo and public Photon servers have no service promise** and are not for
  production traffic. Treat both as dev-only (section 3).
- **G3. Rounding to 2 decimals is about 1.1 km.** That is fine for search bias. It is not
  "anonymous" in a quiet area, and it is not enough for probes (section 5).
- **G4. No IP or log policy** for the reports server yet.
- **G5. Report coordinates (done).** The server rounds lat/lng to 4 decimals (about 11 m) on
  write, so exact positions are never stored. Reports are still kept with a client-chosen id
  for up to about 1.5 h (flood: 3 h), so a short pseudonymous trail per `deviceId` remains,
  now at about 11 m precision.

## 2. Is anonymous or pseudonymous location data "personal data"?

Short answer: **assume yes** for anything tied to a `deviceId`, and treat precise location
as personal data anyway.

- The PDPA covers information "in respect of commercial transactions" that relates directly
  or indirectly to a data subject who is identified or identifiable from that information,
  or from it plus other information the controller holds (section 4 and section 2(1) of the
  2010 Act). Wording taken from secondary sources, see section 9.
- A `deviceId` that links a person's reports over time, plus exact coordinates, can single
  someone out, for example reports from outside a home at the same time every day. So it is
  "identifiable" under that test.
- Fully aggregated or grid-snapped data with no stable id is much less likely to be personal
  data, but **we found no source that settles this for Malaysia.** Uncertain.
- **Uncertain: does the PDPA reach us at all?** It covers processing "in respect of commercial
  transactions". A free, non-commercial open-source app may fall outside that. We do not rely
  on this. We follow the principles anyway, because someone may run the server commercially
  and users expect it. A lawyer should confirm (section 7).

## 3. Third parties

| Service | Gets | Notes |
|---|---|---|
| OpenFreeMap tiles | IP, tile requests (so rough area), user agent | Free, community-run. No account. |
| Photon (Komoot) | Search text, rounded bias lat/lon, IP, app user agent | Public instance. **Dev-only at scale.** Self-host before heavy use. |
| OSRM demo (`router.project-osrm.org`) | Exact origin and destination, IP, app user agent | **Dev-only.** See G1. |
| Reports server (ours) | Report lat/lng, type, `deviceId`, IP | The only service we control. Host not chosen yet. |
| jsDelivr (`cdn.jsdelivr.net`) | Share-ETA viewers only: IP, user agent, which MapLibre file. No referrer, and the token is never in a URL. | Pinned version. The module and worker run only after a `fetch` integrity check, the CSS has SRI, so a changed CDN file stops the map loading instead of running. |

Rules:
- Each new third-party endpoint gets a row here, in the same PR.
- A third party is a "data processor" only if it handles data **on our behalf and on our
  instructions**. Public tile and geocoding servers are probably separate controllers or plain
  public services. Uncertain, see section 7.

## 4. PDPA principles as project rules

The Act has seven principles (sections 6 to 12 of the 2010 Act): General, Notice and Choice,
Disclosure, Security, Retention, Data Integrity, Access.

| Principle | Rule for this project |
|---|---|
| **General** (consent, only what is needed) | Collect only what a feature needs. Location is requested "when in use" only. Reports are sent only after an explicit user action. Probes (#13) stay off until the user has seen the notice, and can be switched off in settings. |
| **Notice and Choice** | Show the notice (section 8) at first run, before location permission or any report. Name every third party. Keep this doc as the long version. Offer English and Bahasa Malaysia (the Act asks for notice in both; uncertain, check). |
| **Disclosure** | No selling, no ads, no sharing beyond the services in section 3. The public API shows reports only, never `deviceId`. |
| **Security** | Keep the server minimal: body limit, input checks, rate limits, `deviceId` never in a response. TLS in production. DB file readable by the operator only. No secrets in the repo. Third-party services must be HTTPS. |
| **Retention** | Reports die within 1 h of expiry. Any new data store states its retention in section 1 before merge. Logs: see section 5. |
| **Data Integrity** | Reports can be voted down and expire, so stale hazards go away. Saved places are edited by the user. |
| **Access** | A user can ask what we hold. With no accounts and client-chosen ids, we can match data only if they give their `deviceId` (to show in settings, to build). Publish a contact address, and give the operator a delete-by-`deviceId` command (to build). |

### 2024 amendment items

All from secondary sources, unverified against the Act. See section 9.

| Item | What it means here |
|---|---|
| **Breach notification** (new s.12B) | If we have reason to believe personal data was breached, tell the Commissioner (JPDP) as soon as practicable, and tell affected users if significant harm is likely. Secondary sources cite 72 hours for the Commissioner, from the JPDP guideline. Keep a short incident runbook before production. With no accounts we cannot contact users, so a public notice may be the only route. |
| **Data Protection Officer** (s.12) | Controllers and processors appoint a DPO and notify the Commissioner, subject to thresholds. Sources disagree on the thresholds (one cites 20,000 data subjects, or 10,000 for sensitive data). We are probably below them. Still, name a privacy contact in the notice. Confirm with a lawyer. |
| **Data portability** (new s.43A) | A user can ask us to move their data to another controller, where technically feasible. Ours is short-lived reports with no accounts, so there is little to port. Say so if asked. |
| **Processors** (s.9 and others) | Processors are now directly bound by the Security principle. If we use a hosting or logging provider that handles personal data for us, we need a written agreement requiring security and breach reporting. |
| **Cross-border transfer** (s.129 as amended) | The Minister's whitelist is gone. Transfers abroad are allowed to places with substantially similar protection, or under listed exceptions such as consent. JPDP issued a cross-border guideline (No. 3/2025, 29 April 2025, per secondary sources). Photon, OSRM and OpenFreeMap are hosted outside Malaysia. Our own host region is undecided: prefer Malaysia or Singapore, and mention it in the notice. |
| **Penalties** | Secondary sources say the fine for breaching the principles rose from RM300,000 to RM1,000,000 and jail from 2 to 3 years. Sources conflict. Verify. |

## 5. Design rules for upcoming features

Use these as acceptance criteria in the tickets.

**Speed probes (#13)**
- Rotating per-trip random id (new for every trip, never reused). **No `deviceId`.**
- Snap the position to the ~100 m grid cell **on the device** before sending. The server
  never receives the exact position. Round the timestamp to the minute.
- Do not send the first and last 500 m of a trip (hides home and work).
- The server keeps only the rolling 15-min per-cell median and deletes raw samples after
  aggregating (target: within 1 h). Do not keep trip ids after the trip ends.
- Built (server): the server re-snaps every sample to a 3-decimal cell (about 110 m), 8 heading
  buckets and the minute, so a client that skips snapping still is not stored exactly. Raw
  samples (with `tripId`) live 15 min by sample time; the median is computed on read from
  them, so there is no separate aggregate store. A `tripId` is gone at most about 16 min after
  its last sample. One sample per trip per cell per 15-min window. `/traffic` returns only
  cell, heading bucket and level, never speeds, counts or `tripId`. A body carrying `deviceId`
  is rejected. Rate limits use `tripId` and per-cell trip counts only, never IPs.
- **Not k-anonymity.** `/traffic` hides cells with fewer than 3 distinct trips, but `tripId`s
  are client-chosen, so an attacker can add 2 fake trips next to one real driver and subtract
  their own samples. The 3-trip rule is a noise floor only. What limits the leak is that only
  a coarse level is published; it still reveals which band (under 15, under 40, or faster) a
  lone driver was in for that cell and 15 minutes. The same gap lets anyone forge traffic. Real
  fix: device attestation (App Attest) so a trip id costs a real device (separate ticket).
- Not enforceable on the server, so the app must do it: new `tripId` per trip, grid snapping
  on the device, minute timestamps, and skipping the first and last 500 m.
- Off until the user has seen the notice. Opt-out in settings (#22) stops sending at once.
- Never join probe data to reports or to a `deviceId`.

**Share ETA (#19)**
- Needs the driver's explicit action each time, a visible "sharing" state, and a stop button.
- The token is long, random and unguessable. It expires on arrival or at 4 h, whichever comes
  first, and the server deletes the trip's positions at expiry. Stopping early revokes it.
- Keep only the latest position, not a history.
- The viewer page loads no third-party script that could leak the token via a referrer
  (self-host MapLibre GL JS or pin it with SRI, and send `Referrer-Policy: no-referrer`). The tile source still
  sees the viewer's IP.
- The token never appears in a request path, so access logs, proxies and CDNs in front of the
  server cannot record it. Never log request headers.
- Built (server): `POST /trips` returns a 128-bit random share token and a separate 256-bit
  owner token; the server stores only SHA-256 hashes of both. API calls carry the share token in
  the `X-Share-Token` header (`/trips/current...`), and the viewer link is `/t/#<token>`: the
  `#fragment` stays in the browser, so the server only sees `GET /t/`. Updates and end also need
  the owner token (`Authorization: Bearer`). One row per trip holds only the latest position,
  rounded to 4 decimals, and is overwritten on each update (at most one per 5 s, checked
  atomically). The row is deleted on end, on `arrived: true`, or by the trip cleanup (every
  minute) once 4 h have passed since creation; updates never extend that. After that every
  call is `404`. The destination name is optional. The server logs no URLs, headers or tokens
  (only `console.error` of internal errors). A `trip_creates` table keeps only creation times,
  for 1 minute, for the global create cap.
- Viewer page: one static HTML page for every token, with the script in separate same-origin
  files. MapLibre GL JS comes from a pinned jsDelivr URL instead of being self-hosted, so no npm
  dependency is added. What is guaranteed: the page fetches the MapLibre module and its worker
  with `fetch(url, {integrity})` and runs only those hash-checked bytes, from `blob:` URLs. A
  changed file fails the fetch, and the map does not load. The CSS link has its own
  `integrity`. The CSP lets no CDN URL run as script (`script-src 'self' blob:`), so an
  unchecked copy cannot run by another route; the cost is that `blob:` scripts are allowed,
  which only script already running on the page can create. What is not guaranteed: the CDN
  sees the viewer's IP and user agent (with `Referrer-Policy: no-referrer` it gets no referrer
  and the token is not in any URL anyway), and a CDN outage breaks the map. Also: no inline
  script, `X-Robots-Tag: noindex`, no analytics, cookies or storage. Shows the OpenStreetMap
  attribution.
- Not enforceable on the server, so the app must do it: explicit start, a visible "sharing"
  state, a stop button that calls end, and `arrived: true` on arrival.

**All features**
- No precise location to a third party. Round it (2 decimals) or drop it. Fix G1.
- No `deviceId` or person identifier in stored data, except the report and vote rate-limit
  rows, for the retention in section 1.
- Server logs must not store full IP addresses long-term. Keep full IPs at most 7 days for
  abuse and security, then delete. Truncate (IPv4 to /24, IPv6 to /48) in anything kept
  longer. Never log request bodies. These numbers are a starting proposal.
- No analytics SDKs, ad IDs, or crash reporters that send location, without updating this doc.
- A new data store or third party updates section 1 or 3 in the same PR.

## 6. Contributor checklist

- [ ] Does this send location off the device? To whom? Rounded?
- [ ] Is a stable id attached? Can it be dropped or rotated?
- [ ] What is the retention, and who deletes it?
- [ ] Is it listed in section 1 or 3 of this file?
- [ ] Is the notice (section 8) still true?

## 7. Needs a lawyer

1. Does the PDPA apply to a free, non-commercial open-source app, given the "commercial
   transactions" wording? Does that change if someone runs a hosted server?
2. Is a `deviceId` plus exact coordinates personal data? What about grid-snapped probes?
3. Who is the "data controller" for a self-hosted server: the project, or whoever runs it?
4. Are Photon, OSRM and OpenFreeMap processors, controllers, or neither? What is needed for
   transfers to them?
5. Cross-border rules: what counts as adequate, and is notice plus consent enough for each
   third party? Which server region should we use?
6. Does the DPO duty or registration apply at our size? Exact thresholds.
7. Breach notice: exact deadlines, and how to notify users when we hold no contact details.
8. Language requirements for the notice (Bahasa Malaysia and English).
9. Minors: any age-gate or parental-consent duty?
10. App Store privacy labels and Google Play data-safety answers must match this doc.
11. Whether other Malaysian laws add duties around location data.

## 8. Privacy notice for onboarding (#22), English

Ready to localise (`String(localized:)`, add Bahasa Malaysia). Keep it short and link to this doc.

> **Your privacy**
>
> OpenWaze does not need an account.
>
> **Your location** stays on your phone for the map and navigation. We ask for it only
> while the app is open.
>
> **Searching and routes.** To find places and routes, the app sends your search words, your
> start and end points, and your IP address to outside services (Photon and OSRM for search
> and routes, OpenFreeMap for map tiles). They run outside Malaysia and have their own
> privacy policies.
>
> **Hazard reports.** If you report or confirm a hazard, we store its position, type, time and
> a random device code. Other drivers see the position and type, but not the code. Reports
> are deleted about an hour after they expire.
>
> **Traffic sharing (optional).** If you leave this on, we send anonymous speed samples while
> you drive. Each trip uses a new random code, positions are rounded to about 100 m, and
> nothing is linked to your device. You can turn it off any time in Settings.
>
> To ask a question or ask us to delete your data, contact: [privacy contact, to fill in].
>
> [Continue]  [Read the full policy]

Before shipping this text: the search and routes paragraph describes dev builds until G1 is
fixed, and the traffic paragraph is only true once #13 is built as in section 5. Change the
text to match what the build really does.

## 9. Sources

Primary. These could not be opened when this was written (the JPDP portal returned 404 or
was under maintenance), so section numbers and dates here come from secondary summaries and
**must be checked against the Acts**:

- JPDP (Jabatan Perlindungan Data Peribadi), Personal Data Protection (Amendment) Act 2024:
  https://www.pdp.gov.my/ppdpv1/en/akta/personal-data-protection-amendment-act-2024/
- Act A1727 PDF as listed by search: https://www.pdp.gov.my/ppdpv1/wp-content/uploads/2024/11/Act-A1727.pdf
- JPDP portal, PDPA 2010 (Act 709): https://www.pdp.gov.my
- JPDP breach notification service: https://daftar.pdp.gov.my/v1/dbn
- JPDP guidelines (Data Breach Notification, DPO Appointment, Cross-Border Transfer No. 3/2025):
  listed on the JPDP site, not read.

Secondary, read and used for the summaries:

- Mayer Brown, "Key Amendments to Malaysia's PDPA and the Launch of Cross-Border Transfer
  Guidelines" (July 2025):
  https://www.mayerbrown.com/en/insights/publications/2025/07/from-legislative-reform-to-practical-guidance-key-amendments-to-malaysias-pdpa-and-the-launch-of-cross-border-transfer-guidelines
- DataGuidance, "Personal Data Protection (Amendment) Act 2024: key changes":
  https://www.dataguidance.com/opinion/malaysia-personal-data-protection-amendment-act
- GLT Law, "Personal Data Protection (Amendment) Bill 2024: what you need to know":
  https://gltlaw.my/personal-data-protection-2024-what-you-need-to-know/
- Search summaries on the personal data definition and "commercial transactions" from
  practitioner sites (for example Lexology, Christopher & Lee Ong). None settles whether
  location data is personal data.

Commencement: secondary sources say cross-border changes from 1 April 2025 and the DPO,
breach and portability duties from 1 June 2025. Unverified.
