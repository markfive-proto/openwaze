# OpenWaze reports server

Small API for crowd hazard reports, live traffic from anonymous speed probes, and share-ETA links. TypeScript run directly by Node (type stripping),
Hono, and built-in `node:sqlite`. No accounts, no DB server.

Requires Node 22.18+ (24 recommended).

```sh
npm ci
npm run dev     # http://localhost:8787, watches src/
npm test        # node --test
```

Env: `PORT` (default `8787`), `DB_PATH` (default `./data/openwaze.db`, gitignored).

## API

Report object (`deviceId` is never returned):

```json
{ "id": "uuid", "type": "police", "lat": 1.3, "lng": 103.8,
  "createdAt": "2026-10-22T10:00:00Z", "expiresAt": "2026-10-22T11:00:00Z",
  "upvotes": 0, "downvotes": 0 }
```

Timestamps are ISO 8601 UTC with whole seconds (Swift `.iso8601` decodes them).

| Method | Path | Body / query | Success |
|---|---|---|---|
| POST | `/reports` | `{type, lat, lng, deviceId}` | `201` report |
| GET | `/reports` | `?minLat&minLng&maxLat&maxLng` | `200` array of active reports, newest first, max 500 |
| POST | `/reports/:id/vote` | `{deviceId, stillThere}` | `200` updated report |

Rules:
- `type` is one of `police`, `accident`, `hazard`, `traffic`, `closure`, `flood`.
- `lat` -90..90, `lng` -180..180 (JSON numbers). `deviceId` 1-128 chars of `[A-Za-z0-9_-]` (a UUID works).
- Coordinates are rounded to 4 decimals (about 11 m, half away from zero) when stored; responses and bbox matching use the rounded values. Clients should send plain JSON numbers and expect `lat`/`lng` back with at most 4 decimals.
- Lifetime 60 min, `traffic` 30 min, `flood` 120 min.
- `stillThere: true` pushes `expiresAt` to now + the type's lifetime (never shortens it).
- The 2nd `stillThere: false` removes the report: the response has `downvotes: 2` and `expiresAt` = now, and it no longer appears in queries.
- One vote per device per report (`409` on a repeat). The reporting device cannot vote on its own report (`409`). Voting on an expired or unknown report is `404`.
- Per `deviceId`, rolling hour: 10 reports and 60 votes (`429`).
- Bbox: `min <= max` on both axes, each axis span at most 2 degrees, area at most 4 square degrees. Boxes crossing the antimeridian are not supported.
- Bodies over 1 KB get `413` (chunked bodies too). Errors are `{"error": "message"}` with `400`, `404`, `409`, `413` or `429`.

## Live traffic (speed probes, #13)

| Method | Path | Body / query | Success |
|---|---|---|---|
| POST | `/probes` | `{tripId, samples: [{lat, lng, heading, speedKmh, t}]}` | `202 {"accepted": n}` |
| GET | `/traffic` | `?minLat&minLng&maxLat&maxLng` | `200` array of cells |

Cell object:

```json
{ "lat": 3.158, "lng": 101.712, "heading": 90, "level": "jam" }
```

No speed and no sample counts, on purpose: see "Threat" below.

Client rules (the server cannot check these, see [docs/privacy.md](../docs/privacy.md) section 5):
new random `tripId` per trip, no `deviceId`, snap to the grid before sending, round `t` to
the minute, and skip the first and last 500 m of a trip.

Rules:
- `tripId` is a UUID (any version, any case). A body with a `deviceId` field is `400`.
- `samples`: 1-30 objects. `lat` -90..90, `lng` -180..180, `heading` 0..360 degrees,
  `speedKmh` a number, `t` ISO 8601 UTC ending in `Z`. Anything malformed is `400` for the whole call.
- Per sample, silently dropped (not counted in `accepted`): `t` more than 5 min old or more
  than 1 min in the future (clock skew), `speedKmh` outside 0..200.
- The server re-snaps: `lat`/`lng` rounded to 3 decimals (about 110 m cell), `heading` to 8
  buckets (0, 45, ..., 315), `t` floored to the minute.
- One sample per trip per cell and heading for the whole 15-min window: the first one counts,
  later ones are ignored until it leaves the window (so one trip cannot outvote others in a
  cell). At most 20 new trips per cell, heading and minute.
- Per `tripId`: 12 posts per rolling minute (`429`). No IPs are stored or used.
- Bodies over 8 KB get `413`.
- `GET /traffic`: per cell and heading bucket, the `level` of the median speed of samples
  from the last 15 min. A cell needs samples from at least 3 distinct trips (a noise floor
  so one stray car does not paint a road). Max 500 cells, busiest first. Same bbox rules as
  `/reports`.
- `level`: `jam` below 15 km/h, `slow` below 40, else `free` (absolute, not per road).
- Raw samples are deleted once 15 min old (probe cleanup runs every minute). No longer history is kept.
- Measured (Node 22, M-series Mac, in-memory DB, 240k in-window rows over 20k cells):
  a max 2x2 degree box takes about 62 ms p50 (500 cells), a city box about 1 ms.

Threat (not anonymity): `tripId`s are client-chosen and free to mint, so the 3-trip floor is
not k-anonymity. An attacker can add 2 fake trips to a cell and subtract their own known
samples to learn a lone real driver's data. That is why `/traffic` returns only a coarse
level, never speeds or counts, which limits what they learn to which of 3 bands the driver
was in. The same weakness lets a forger fake any cell's level, or fill a cell's 20-trip cap
each minute and lock real drivers out of it. The real fix is device attestation (App Attest)
so each trip costs a real device; until then, treat `/traffic` as best effort, not as a
privacy guarantee.

## Share ETA (#19)

The share token is never in a request path, so access logs and proxies do not see it. API calls
send it in the `X-Share-Token` header; the viewer link is `/t/#<shareToken>`, and browsers never
send the `#fragment` to the server.

| Method | Path | Headers | Body | Success |
|---|---|---|---|---|
| POST | `/trips` | | `{destination: {lat, lng, name?}, etaAt}` | `201 {shareToken, ownerToken, expiresAt}` |
| POST | `/trips/current/position` | `X-Share-Token`, `Authorization: Bearer <ownerToken>` | `{lat, lng, heading?, etaAt}` or `{arrived: true}` | `204` |
| POST | `/trips/current/end` | `X-Share-Token`, `Authorization: Bearer <ownerToken>` | none | `204` |
| GET | `/trips/current` | `X-Share-Token` | | `200` trip view |
| GET | `/t/` | | | `200` viewer page (HTML); share link `/t/#<shareToken>` |

Trip view (`position` is `null` until the first update; `destinationName` only if set):

```json
{ "position": { "lat": 3.139, "lng": 101.6869, "heading": 45 },
  "destination": { "lat": 3.1579, "lng": 101.7116 }, "destinationName": "KLCC",
  "etaAt": "2026-10-22T10:30:00Z", "updatedAt": "2026-10-22T10:00:15Z",
  "expiresAt": "2026-10-22T14:00:00Z", "active": true }
```

Rules:
- `shareToken`: 16 random bytes (128 bits) as base64url, 22 chars. It is the secret in the share
  link `/t/#<shareToken>`. `ownerToken`: 32 random bytes as base64url, 43 chars. Only the app keeps
  it. The server stores SHA-256 hashes of both tokens, never the tokens.
- A missing or malformed `X-Share-Token` is `404`, the same as an unknown, ended or expired trip.
- `etaAt` is ISO 8601 UTC, from 1 h ago to 24 h ahead. `lat`/`lng` as for reports, `heading`
  0..360 or `null`, `name` 1-100 chars with no control characters (trimmed).
- Positions and the destination are rounded to 4 decimals (about 11 m), `heading` to whole degrees.
- Only the latest position is kept; each update overwrites it. 1 update per 5 s per trip (`429`),
  checked in the same SQL statement as the write, so concurrent posts cannot both pass.
- No or malformed `Authorization` is `401`; a wrong owner token is `403`.
- A trip ends on `end`, on `{arrived: true}`, or 4 h after `POST /trips` (updates never extend
  it). End and arrival delete the row at once; the trip cleanup deletes expired rows every
  minute. After that every trip call is `404`, the same as for an unknown token.
- Creation is keyed on nothing (no accounts, no IPs). Two global caps instead: 300 creates per
  rolling minute (`429`) and 10,000 live trips (`503`). Remaining risk: a flood can still fill
  the pool in about 33 minutes and block real drivers from sharing until those trips expire
  (availability, not privacy). Fix: App Attest on create (#46) or a per-IP limit at the proxy.
- Bodies over 1 KB get `413`. `GET /trips/current` is `Cache-Control: no-store`.
- Viewer page: the same static HTML for every token. `/t/share.js` reads the token from
  `location.hash`, polls `GET /trips/current` every 15 s, and shows "Trip ended" on `404`.
  MapLibre GL JS 6.13.0 (needs 6.4.1+, see `docs/security/known-vulns.md` M1) comes from
  jsDelivr. `/t/sri.js` fetches the module and its worker with `fetch(url, {integrity})` and
  runs only those checked bytes, from `blob:` URLs; a hash mismatch rejects the fetch, so the map
  does not load. The CSS link has its own `integrity`. Hashes live in `MAPLIBRE` in
  `src/app.ts`. CSP: `script-src 'self' blob:` (no CDN may run script directly), no inline
  script, CDN files allowed only as exact `connect-src`/`style-src` paths. Also
  `Referrer-Policy: no-referrer`, `X-Robots-Tag: noindex, nofollow`, `no-store`. Map: OpenFreeMap
  liberty style with OpenStreetMap attribution. No analytics.
- To bump MapLibre: change the version in `src/app.ts`, then recompute each hash from the npm
  tarball (`npm pack maplibre-gl@X`, `openssl dgst -sha384 -binary <file> | openssl base64 -A`)
  and check it equals the jsDelivr file.
- Nothing logs tokens or URLs. Privacy and retention: [docs/privacy.md](../docs/privacy.md) sections 1 and 5.

## curl

```sh
# create
curl -s -X POST localhost:8787/reports -H 'content-type: application/json' \
  -d '{"type":"police","lat":1.3521,"lng":103.8198,"deviceId":"demo-device-1"}'

# query a box
curl -s 'localhost:8787/reports?minLat=1.2&minLng=103.6&maxLat=1.5&maxLng=104.0'

# vote (replace ID)
curl -s -X POST localhost:8787/reports/ID/vote -H 'content-type: application/json' \
  -d '{"deviceId":"demo-device-2","stillThere":true}'

# speed probe, then traffic in a box
curl -s -X POST localhost:8787/probes -H 'content-type: application/json' \
  -d '{"tripId":"6f1c2a9e-3b4d-4e5f-8a7b-9c0d1e2f3a4b","samples":[{"lat":3.158,"lng":101.712,"heading":90,"speedKmh":12,"t":"'"$(date -u +%Y-%m-%dT%H:%M:00Z)"'"}]}'
curl -s 'localhost:8787/traffic?minLat=3.1&minLng=101.6&maxLat=3.2&maxLng=101.8'

# share ETA: create, post a position (use the tokens from the reply), view, open the page, end
curl -s -X POST localhost:8787/trips -H 'content-type: application/json' \
  -d '{"destination":{"lat":3.1579,"lng":101.7116,"name":"KLCC"},"etaAt":"'"$(date -u -v+12M +%Y-%m-%dT%H:%M:%SZ)"'"}'
curl -s -X POST localhost:8787/trips/current/position -H 'content-type: application/json' \
  -H 'x-share-token: SHARE' -H 'authorization: Bearer OWNER' \
  -d '{"lat":3.139,"lng":101.6869,"heading":45,"etaAt":"'"$(date -u -v+12M +%Y-%m-%dT%H:%M:%SZ)"'"}'
curl -s localhost:8787/trips/current -H 'x-share-token: SHARE'
open 'http://localhost:8787/t/#SHARE'
curl -s -X POST localhost:8787/trips/current/end -H 'x-share-token: SHARE' -H 'authorization: Bearer OWNER'

# invalid input -> 400
curl -s -X POST localhost:8787/reports -H 'content-type: application/json' \
  -d '{"type":"ufo","lat":91,"lng":0,"deviceId":"x"}'
```
