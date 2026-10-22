# OpenWaze reports server

Small API for crowd hazard reports. TypeScript run directly by Node (type stripping),
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
- `type` is one of `police`, `accident`, `hazard`, `traffic`, `closure`.
- `lat` -90..90, `lng` -180..180 (JSON numbers). `deviceId` 1-128 chars of `[A-Za-z0-9_-]` (a UUID works).
- Lifetime 60 min, `traffic` 30 min.
- `stillThere: true` pushes `expiresAt` to now + the type's lifetime (never shortens it).
- The 2nd `stillThere: false` removes the report: the response has `downvotes: 2` and `expiresAt` = now, and it no longer appears in queries.
- One vote per device per report (`409` on a repeat). The reporting device cannot vote on its own report (`409`). Voting on an expired or unknown report is `404`.
- Per `deviceId`, rolling hour: 10 reports and 60 votes (`429`).
- Bbox: `min <= max` on both axes, each axis span at most 2 degrees, area at most 4 square degrees. Boxes crossing the antimeridian are not supported.
- Bodies over 1 KB get `413` (chunked bodies too). Errors are `{"error": "message"}` with `400`, `404`, `409`, `413` or `429`.

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

# invalid input -> 400
curl -s -X POST localhost:8787/reports -H 'content-type: application/json' \
  -d '{"type":"ufo","lat":91,"lng":0,"deviceId":"x"}'
```
