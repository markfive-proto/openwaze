import { Hono } from 'hono';
import { bodyLimit } from 'hono/body-limit';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { DatabaseSync } from 'node:sqlite';

// Lifetime in minutes per report type; the single source for the type enum too.
const LIFETIME_MIN = { police: 60, accident: 60, hazard: 60, traffic: 30, closure: 60, flood: 120 } as const;
type ReportType = keyof typeof LIFETIME_MIN;
const TYPES = Object.keys(LIFETIME_MIN) as ReportType[];

const MIN = 60_000;
const HOUR = 60 * MIN;
const LIFETIME_MS = (t: ReportType) => LIFETIME_MIN[t] * MIN;
const REPORTS_PER_HOUR = 10;
const VOTES_PER_HOUR = 60;
const REMOVE_AFTER_DOWNVOTES = 2;
const MAX_RESULTS = 500;
const MAX_BBOX_SPAN_DEG = 2; // per axis, roughly 220 km of latitude
const MAX_BBOX_AREA_DEG2 = 4; // enough for a zoomed-out city view
const EPS = 1e-9; // so a box exactly at the cap is not rejected by float subtraction
const MAX_BODY_BYTES = 1024;
const DEVICE_ID = /^[A-Za-z0-9_-]{1,128}$/;

// Speed probes (#13). No deviceId anywhere: a probe is keyed by a random per-trip UUID only.
const PROBE_WINDOW_MS = 15 * MIN; // raw samples live this long (by sample minute), then cleanup deletes them
const PROBE_MAX_AGE_MS = 5 * MIN;
const PROBE_MAX_SKEW_MS = MIN; // device clocks drift and may round t up to the next minute
const PROBE_MAX_SAMPLES = 30;
const PROBE_MAX_BODY_BYTES = 8 * 1024;
const PROBE_MAX_SPEED_KMH = 200;
const PROBE_POSTS_PER_MIN = 12; // the app posts about every 10 s
const PROBE_TRIPS_PER_CELL_MIN = 20; // see the rate-limit note in POST /probes
const TRAFFIC_MIN_TRIPS = 3; // k-anonymity: a cell is shown only with this many distinct trips
const JAM_BELOW_KMH = 15;
const SLOW_BELOW_KMH = 40;
const TRIP_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ISO_UTC = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d{1,3})?)?Z$/;

type Row = {
  id: string;
  type: ReportType;
  lat: number;
  lng: number;
  created_at: number;
  expires_at: number;
  upvotes: number;
  downvotes: number;
};

// ISO 8601 UTC without fractional seconds, so Swift's .iso8601 decoder accepts it.
const iso = (ms: number) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');

// Explicit allowlist: device_id is never selected into a response.
const toReport = (r: Row) => ({
  id: r.id,
  type: r.type,
  lat: r.lat,
  lng: r.lng,
  createdAt: iso(r.created_at),
  expiresAt: iso(r.expires_at),
  upvotes: r.upvotes,
  downvotes: r.downvotes,
});

const COLS = 'id, type, lat, lng, created_at, expires_at, upvotes, downvotes';

const isNum = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v);
const isLat = (v: unknown): v is number => isNum(v) && v >= -90 && v <= 90;
const isLng = (v: unknown): v is number => isNum(v) && v >= -180 && v <= 180;
const isDeviceId = (v: unknown): v is string => typeof v === 'string' && DEVICE_ID.test(v);
// Round half away from zero to `dp` decimals. The exponent-string trick rounds on the decimal
// text, so 1.00005 -> 1.0001 (not 1 via float 10000.4999...), and the result prints with <= dp decimals.
const roundDp = (v: number, dp: number) => {
  const r = Number(`${Math.round(Number(`${Math.abs(v)}e${dp}`))}e-${dp}`);
  return v < 0 && r !== 0 ? -r : r; // never -0
};
const round4 = (v: number) => roundDp(v, 4); // reports: ~11 m
const round3 = (v: number) => roundDp(v, 3); // probe grid cell: ~110 m
const headingBucket = (deg: number) => (Math.round(deg / 45) % 8) * 45; // 8 buckets: 0, 45, ..., 315
const median = (xs: number[]) => {
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
};
// ponytail: absolute thresholds, so a 30 km/h residential street reads "slow" and a 50 km/h crawl on a
// 110 km/h highway reads "free". A per-cell free-flow estimate needs history past the 15-min window, which
// we do not keep; upgrade with OSM maxspeed per cell, or long-term anonymous aggregates if privacy allows.
const level = (kmh: number) => (kmh < JAM_BELOW_KMH ? 'jam' : kmh < SLOW_BELOW_KMH ? 'slow' : 'free');
const qNum = (s: string | undefined) => (s === undefined || s.trim() === '' ? NaN : Number(s));

type Bbox = { minLat: number; minLng: number; maxLat: number; maxLng: number };
// Shared by /reports and /traffic: returns the box, or an error message for a 400.
const parseBbox = (query: (k: string) => string | undefined): Bbox | string => {
  const [minLat, minLng, maxLat, maxLng] = ['minLat', 'minLng', 'maxLat', 'maxLng'].map((k) => qNum(query(k)));
  if (!isLat(minLat) || !isLat(maxLat) || !isLng(minLng) || !isLng(maxLng))
    return 'minLat, maxLat in -90..90 and minLng, maxLng in -180..180 are required';
  // ponytail: no antimeridian-crossing boxes (minLng > maxLng); split into two queries client-side if needed.
  if (minLat > maxLat || minLng > maxLng) return 'min must be <= max';
  if (maxLat - minLat > MAX_BBOX_SPAN_DEG + EPS || maxLng - minLng > MAX_BBOX_SPAN_DEG + EPS)
    return `bbox span must be <= ${MAX_BBOX_SPAN_DEG} degrees per axis`;
  if ((maxLat - minLat) * (maxLng - minLng) > MAX_BBOX_AREA_DEG2 + EPS)
    return `bbox area must be <= ${MAX_BBOX_AREA_DEG2} square degrees`;
  return { minLat, minLng, maxLat, maxLng };
};

export function createApp({ dbPath = ':memory:', now = () => Date.now() } = {}) {
  if (dbPath !== ':memory:') mkdirSync(dirname(dbPath), { recursive: true });
  const db = new DatabaseSync(dbPath);
  db.exec(`
    PRAGMA foreign_keys = ON;
    PRAGMA journal_mode = WAL;
    CREATE TABLE IF NOT EXISTS reports (
      id TEXT PRIMARY KEY,
      type TEXT NOT NULL,
      lat REAL NOT NULL,
      lng REAL NOT NULL,
      device_id TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      expires_at INTEGER NOT NULL,
      upvotes INTEGER NOT NULL DEFAULT 0,
      downvotes INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS reports_geo ON reports (lat, lng);
    CREATE INDEX IF NOT EXISTS reports_device ON reports (device_id, created_at);
    CREATE TABLE IF NOT EXISTS votes (
      report_id TEXT NOT NULL REFERENCES reports(id) ON DELETE CASCADE,
      device_id TEXT NOT NULL,
      still_there INTEGER, -- NULL = implicit author row, blocks self-votes and is not rate-counted
      created_at INTEGER NOT NULL,
      PRIMARY KEY (report_id, device_id)
    );
    CREATE INDEX IF NOT EXISTS votes_device ON votes (device_id, created_at);
    -- Speed probes: one row per (cell, heading bucket, minute, trip). The primary key is what stops a single
    -- trip from dominating a cell: at most one sample per trip per cell per minute (first one wins).
    CREATE TABLE IF NOT EXISTS probes (
      lat REAL NOT NULL,        -- cell, rounded to 3 decimals
      lng REAL NOT NULL,
      heading INTEGER NOT NULL, -- bucket: 0, 45, ..., 315
      minute INTEGER NOT NULL,  -- sample time floored to the minute, epoch ms
      trip_id TEXT NOT NULL,    -- random per trip, never linked to a deviceId
      speed REAL NOT NULL,
      PRIMARY KEY (lat, lng, heading, minute, trip_id)
    ) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS probes_minute ON probes (minute);
    CREATE TABLE IF NOT EXISTS probe_posts (trip_id TEXT NOT NULL, at INTEGER NOT NULL); -- rate limit, 1 min
    CREATE INDEX IF NOT EXISTS probe_posts_trip ON probe_posts (trip_id, at);
  `);

  const q = {
    insert: db.prepare(
      'INSERT INTO reports (id, type, lat, lng, device_id, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
    ),
    recentByDevice: db.prepare('SELECT COUNT(*) AS n FROM reports WHERE device_id = ? AND created_at > ?'),
    bbox: db.prepare(
      `SELECT ${COLS} FROM reports WHERE lat BETWEEN ? AND ? AND lng BETWEEN ? AND ? AND expires_at > ?
       ORDER BY created_at DESC LIMIT ${MAX_RESULTS}`,
    ),
    active: db.prepare(`SELECT ${COLS} FROM reports WHERE id = ? AND expires_at > ?`),
    byId: db.prepare(`SELECT ${COLS} FROM reports WHERE id = ?`),
    insertVote: db.prepare(
      'INSERT OR IGNORE INTO votes (report_id, device_id, still_there, created_at) VALUES (?, ?, ?, ?)',
    ),
    // Votes on cleaned-up reports vanish with them, but cleanup lags expiry by an hour, so the window stays intact.
    recentVotesByDevice: db.prepare(
      'SELECT COUNT(*) AS n FROM votes WHERE device_id = ? AND created_at > ? AND still_there IS NOT NULL',
    ),
    upvote: db.prepare('UPDATE reports SET upvotes = upvotes + 1, expires_at = MAX(expires_at, ?) WHERE id = ?'),
    // Reaching the downvote threshold "removes" the report by expiring it now; cleanup deletes it later.
    downvote: db.prepare(
      `UPDATE reports SET downvotes = downvotes + 1,
         expires_at = CASE WHEN downvotes + 1 >= ${REMOVE_AFTER_DOWNVOTES} THEN ? ELSE expires_at END
       WHERE id = ?`,
    ),
    // Keep rows for an hour past expiry so the per-device hourly rate limit still counts them.
    cleanup: db.prepare('DELETE FROM reports WHERE expires_at < ?'),
    probePostsByTrip: db.prepare('SELECT COUNT(*) AS n FROM probe_posts WHERE trip_id = ? AND at > ?'),
    insertProbePost: db.prepare('INSERT INTO probe_posts (trip_id, at) VALUES (?, ?)'),
    // Skips the row once the cell already has PROBE_TRIPS_PER_CELL_MIN trips this minute; OR IGNORE drops
    // a second sample from the same trip in the same cell and minute.
    insertProbe: db.prepare(
      `INSERT OR IGNORE INTO probes (lat, lng, heading, minute, trip_id, speed)
       SELECT :lat, :lng, :heading, :minute, :tripId, :speed
       WHERE (SELECT COUNT(*) FROM probes WHERE lat = :lat AND lng = :lng AND heading = :heading AND minute = :minute)
         < ${PROBE_TRIPS_PER_CELL_MIN}`,
    ),
    probesInBox: db.prepare(
      `SELECT lat, lng, heading, trip_id, speed FROM probes
       WHERE lat BETWEEN ? AND ? AND lng BETWEEN ? AND ? AND minute > ?`,
    ),
    cleanupProbes: db.prepare('DELETE FROM probes WHERE minute <= ?'),
    cleanupProbePosts: db.prepare('DELETE FROM probe_posts WHERE at <= ?'),
  };

  const tx = <T>(fn: () => T): T => {
    db.exec('BEGIN');
    try {
      const out = fn();
      db.exec('COMMIT');
      return out;
    } catch (e) {
      db.exec('ROLLBACK');
      throw e;
    }
  };

  const app = new Hono();

  app.onError((err, c) => {
    console.error(err);
    return c.json({ error: 'internal error' }, 500);
  });
  app.notFound((c) => c.json({ error: 'not found' }, 404));

  const limit = bodyLimit({
    maxSize: MAX_BODY_BYTES,
    onError: (c) => c.json({ error: 'body too large' }, 413),
  });

  const readJson = async (c: { req: { json: () => Promise<unknown> } }) => {
    try {
      const b = await c.req.json();
      return b && typeof b === 'object' && !Array.isArray(b) ? (b as Record<string, unknown>) : null;
    } catch {
      return null;
    }
  };

  app.get('/health', (c) => c.json({ ok: true }));

  app.post('/reports', limit, async (c) => {
    const b = await readJson(c);
    if (!b) return c.json({ error: 'body must be a JSON object' }, 400);
    const { type, lat, lng, deviceId } = b;
    if (typeof type !== 'string' || !TYPES.includes(type as ReportType))
      return c.json({ error: `type must be one of ${TYPES.join(', ')}` }, 400);
    if (!isLat(lat)) return c.json({ error: 'lat must be a number in -90..90' }, 400);
    if (!isLng(lng)) return c.json({ error: 'lng must be a number in -180..180' }, 400);
    if (!isDeviceId(deviceId)) return c.json({ error: 'deviceId must be 1-128 chars of [A-Za-z0-9_-]' }, 400);

    // ponytail: deviceId is client-chosen with no accounts (v1), so a client can rotate IDs to dodge this;
    // add a per-IP limit or device attestation if abuse shows up.
    const t = now();
    const { n } = q.recentByDevice.get(deviceId, t - HOUR) as { n: number };
    if (n >= REPORTS_PER_HOUR) return c.json({ error: 'rate limit: 10 reports per hour' }, 429);

    const id = crypto.randomUUID();
    tx(() => {
      q.insert.run(id, type, round4(lat), round4(lng), deviceId, t, t + LIFETIME_MS(type as ReportType));
      q.insertVote.run(id, deviceId, null, t); // author cannot vote on their own report
    });
    return c.json(toReport(q.byId.get(id) as Row), 201);
  });

  app.get('/reports', (c) => {
    const box = parseBbox((k) => c.req.query(k));
    if (typeof box === 'string') return c.json({ error: box }, 400);
    const rows = q.bbox.all(box.minLat, box.maxLat, box.minLng, box.maxLng, now()) as Row[];
    return c.json(rows.map(toReport));
  });

  app.post('/reports/:id/vote', limit, async (c) => {
    const b = await readJson(c);
    if (!b) return c.json({ error: 'body must be a JSON object' }, 400);
    const { deviceId, stillThere } = b;
    if (!isDeviceId(deviceId)) return c.json({ error: 'deviceId must be 1-128 chars of [A-Za-z0-9_-]' }, 400);
    if (typeof stillThere !== 'boolean') return c.json({ error: 'stillThere must be a boolean' }, 400);

    const id = c.req.param('id');
    const t = now();
    const report = q.active.get(id, t) as Row | undefined;
    if (!report) return c.json({ error: 'report not found or expired' }, 404);
    const { n } = q.recentVotesByDevice.get(deviceId, t - HOUR) as { n: number };
    if (n >= VOTES_PER_HOUR) return c.json({ error: 'rate limit: 60 votes per hour' }, 429);

    const voted = tx(() => {
      if (q.insertVote.run(id, deviceId, stillThere ? 1 : 0, t).changes === 0) return false;
      if (stillThere) q.upvote.run(t + LIFETIME_MS(report.type), id);
      else q.downvote.run(t, id);
      return true;
    });
    if (!voted) return c.json({ error: 'already voted on this report' }, 409);
    return c.json(toReport(q.byId.get(id) as Row));
  });

  app.post(
    '/probes',
    bodyLimit({ maxSize: PROBE_MAX_BODY_BYTES, onError: (c) => c.json({ error: 'body too large' }, 413) }),
    async (c) => {
      const b = await readJson(c);
      if (!b) return c.json({ error: 'body must be a JSON object' }, 400);
      if ('deviceId' in b) return c.json({ error: 'probes must not carry a deviceId' }, 400);
      const { tripId, samples } = b;
      if (typeof tripId !== 'string' || !TRIP_ID.test(tripId)) return c.json({ error: 'tripId must be a UUID' }, 400);
      if (!Array.isArray(samples) || samples.length < 1 || samples.length > PROBE_MAX_SAMPLES)
        return c.json({ error: `samples must be an array of 1-${PROBE_MAX_SAMPLES}` }, 400);
      for (const s of samples) {
        const ok =
          s && typeof s === 'object' && isLat(s.lat) && isLng(s.lng) && isNum(s.heading) && s.heading >= 0 &&
          s.heading <= 360 && isNum(s.speedKmh) && typeof s.t === 'string' && ISO_UTC.test(s.t);
        if (!ok)
          return c.json(
            { error: 'each sample needs lat, lng, heading 0..360, speedKmh (numbers) and t (ISO 8601 UTC)' },
            400,
          );
      }

      // ponytail: no IPs and no accounts, so a forger can mint TRAFFIC_MIN_TRIPS fresh tripIds and fake a cell.
      // Two IP-less limits bound the damage: PROBE_POSTS_PER_MIN per tripId stops one trip flooding, and
      // PROBE_TRIPS_PER_CELL_MIN caps distinct trips per cell per minute, so a tripId-rotating flood cannot
      // grow the table past cells x 20 x 15 rows or bury a cell under hundreds of fake trips. Real fix: device
      // attestation (App Attest) on trip start.
      const t = now();
      const { n } = q.probePostsByTrip.get(tripId, t - MIN) as { n: number };
      if (n >= PROBE_POSTS_PER_MIN)
        return c.json({ error: `rate limit: ${PROBE_POSTS_PER_MIN} posts per minute` }, 429);

      const accepted = tx(() => {
        q.insertProbePost.run(tripId, t);
        let added = 0;
        for (const s of samples) {
          const at = Date.parse(s.t);
          // Stale, future or implausible samples are dropped, not 400: a batch held back offline still
          // delivers its fresh samples.
          if (at < t - PROBE_MAX_AGE_MS || at > t + PROBE_MAX_SKEW_MS) continue;
          if (s.speedKmh < 0 || s.speedKmh > PROBE_MAX_SPEED_KMH) continue;
          const row = {
            lat: round3(s.lat),
            lng: round3(s.lng),
            heading: headingBucket(s.heading),
            minute: Math.floor(at / MIN) * MIN,
            tripId,
            speed: s.speedKmh,
          };
          added += Number(q.insertProbe.run(row).changes);
        }
        return added;
      });
      return c.json({ accepted }, 202);
    },
  );

  app.get('/traffic', (c) => {
    const box = parseBbox((k) => c.req.query(k));
    if (typeof box === 'string') return c.json({ error: box }, 400);
    const rows = q.probesInBox.all(box.minLat, box.maxLat, box.minLng, box.maxLng, now() - PROBE_WINDOW_MS) as {
      lat: number;
      lng: number;
      heading: number;
      trip_id: string;
      speed: number;
    }[];
    // ponytail: groups every in-window row of the box in memory; fine while rows are bounded by the 15-min
    // window, move to a per-minute aggregate table if a busy 4 sq deg box gets slow.
    type Agg = { lat: number; lng: number; heading: number; trips: Set<string>; speeds: number[] };
    const cells = new Map<string, Agg>();
    for (const r of rows) {
      const key = `${r.lat},${r.lng},${r.heading}`;
      let cell = cells.get(key);
      if (!cell) cells.set(key, (cell = { lat: r.lat, lng: r.lng, heading: r.heading, trips: new Set(), speeds: [] }));
      cell.trips.add(r.trip_id);
      cell.speeds.push(r.speed);
    }
    const out = [...cells.values()]
      .filter((cell) => cell.trips.size >= TRAFFIC_MIN_TRIPS)
      .sort((a, b) => b.speeds.length - a.speeds.length)
      .slice(0, MAX_RESULTS)
      .map((cell) => {
        const speedKmh = Math.round(median(cell.speeds));
        const { lat, lng, heading, speeds } = cell;
        return { lat, lng, heading, level: level(speedKmh), speedKmh, samples: speeds.length };
      });
    return c.json(out);
  });

  const cleanup = () => {
    const t = now();
    const runs = [q.cleanup.run(t - HOUR), q.cleanupProbes.run(t - PROBE_WINDOW_MS), q.cleanupProbePosts.run(t - MIN)];
    return runs.reduce((sum, r) => sum + Number(r.changes), 0);
  };

  return { app, db, cleanup };
}
