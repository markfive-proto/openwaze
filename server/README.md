# OpenWaze reports server

Small API for crowd hazard reports and live traffic from anonymous speed probes. TypeScript run directly by Node (type stripping),
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
{ "lat": 3.158, "lng": 101.712, "heading": 90, "level": "jam", "speedKmh": 12, "samples": 7 }
```

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
- One sample per trip per cell, heading and minute; later ones are ignored (so one trip
  cannot dominate a cell). At most 20 trips per cell, heading and minute.
- Per `tripId`: 12 posts per rolling minute (`429`). No IPs are stored or used.
- Bodies over 8 KB get `413`.
- `GET /traffic`: per cell and heading bucket, the median speed of samples from the last
  15 min, rounded to km/h, and the sample count. Only cells with samples from at least 3
  distinct trips are returned. Max 500 cells, busiest first. Same bbox rules as `/reports`.
- `level`: `jam` below 15 km/h, `slow` below 40, else `free` (absolute, not per road).
- Raw samples are deleted once 15 min old (cleanup runs every minute). No longer history is kept.

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

# invalid input -> 400
curl -s -X POST localhost:8787/reports -H 'content-type: application/json' \
  -d '{"type":"ufo","lat":91,"lng":0,"deviceId":"x"}'
```
