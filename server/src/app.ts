import { type Context, Hono } from 'hono';
import { bodyLimit } from 'hono/body-limit';
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { mkdirSync, readFileSync } from 'node:fs';
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
// Noise floor, NOT a privacy control: a cell is shown only with this many distinct trips, so one stray car
// does not paint a road. tripIds are client-chosen, so this gives no k-anonymity (see GET /traffic).
const TRAFFIC_MIN_TRIPS = 3;
const JAM_BELOW_KMH = 15;
const SLOW_BELOW_KMH = 40;
const TRIP_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ISO_UTC = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d{1,3})?)?Z$/;

// Share ETA (#19). The share token is the link secret; the owner token posts updates and ends the trip.
// Only SHA-256 hashes of both are stored, so a DB dump reveals neither live links nor owner rights.
const TRIP_MAX_MS = 4 * HOUR;
const TRIP_MIN_POST_GAP_MS = 5_000; // the app posts about every 15 s
const TRIP_MAX_ACTIVE = 10_000;
const TRIP_CREATES_PER_MIN = 300; // global: 10k live trips take at least 33 min to fill
const TRIP_NAME_MAX = 100;
// The share token travels only in the X-Share-Token header and the viewer link's #fragment, never in a
// request path, so access logs and proxies never see it.
const SHARE_TOKEN = /^[A-Za-z0-9_-]{22}$/; // 16 random bytes (128 bits), base64url
const BEARER = /^Bearer ([A-Za-z0-9_-]{43})$/; // owner token: 32 random bytes, base64url
const CONTROL_CHARS = /\p{Cc}/u;

// Viewer page (GET /t/#<token>). MapLibre GL JS comes from a pinned jsDelivr URL. sri.js fetches the module and
// its worker with these SRI hashes (sha384 of the npm tarball's files, equal to what jsDelivr serves) and runs
// only the checked bytes, from blob: URLs; the CSS link carries its own hash. Must stay >= 6.4.1
// (CVE-2026-85061, known-vulns M1).
const MAPLIBRE_BASE = 'https://cdn.jsdelivr.net/npm/maplibre-gl@6.13.0/dist/';
const MAPLIBRE = {
  JS_URL: `${MAPLIBRE_BASE}maplibre-gl.mjs`,
  JS_SRI: 'sha384-tG0qQdL7veKvVoyu6PbnmddDls/OVkTjaK9oVY5eq9afBA6zYptFui69Dx57duAh',
  WORKER_URL: `${MAPLIBRE_BASE}maplibre-gl-worker.mjs`,
  WORKER_SRI: 'sha384-vHxGRAh5VPNspVXjsLuI5wxrF/Jbzfyct4wTbGl6bu89rV2rGJm3cOzMTWIfHK0y',
  CSS_URL: `${MAPLIBRE_BASE}maplibre-gl.css`,
  CSS_SRI: 'sha384-yFNc3bs28S14jOJo1ZO9SnLiAmtyY2a3H9be8GkLMpDGlO5r1zZNP8fYu+fOCE/w',
};
const TILES = 'https://tiles.openfreemap.org';
// No 'unsafe-inline' or 'unsafe-eval'. No CDN host may run script directly: CDN files are only fetched (exact
// paths) and run from blob: URLs that sri.js made from hash-checked bytes. blob: URLs can only be minted by
// script already running on this origin.
const SHARE_HEADERS = {
  'Content-Security-Policy': [
    "default-src 'none'",
    "script-src 'self' blob:",
    `style-src 'self' ${MAPLIBRE.CSS_URL}`,
    `connect-src 'self' ${TILES} ${MAPLIBRE.JS_URL} ${MAPLIBRE.WORKER_URL}`,
    `img-src 'self' data: blob: ${TILES}`,
    'worker-src blob:',
    "base-uri 'none'",
    "form-action 'none'",
    "frame-ancestors 'none'",
  ].join('; '),
  'Referrer-Policy': 'no-referrer',
  'X-Robots-Tag': 'noindex, nofollow',
  'X-Content-Type-Options': 'nosniff',
  'Cache-Control': 'no-store',
};
// server/public files, with {{KEY}} filled from MAPLIBRE so URLs and hashes live in one place.
const publicFile = (name: string) =>
  readFileSync(new URL(`../public/${name}`, import.meta.url), 'utf8').replace(/\{\{(\w+)\}\}/g, (m, k: string) =>
    k in MAPLIBRE ? MAPLIBRE[k as keyof typeof MAPLIBRE] : m,
  );
const SHARE_HTML = publicFile('share.html');
const SHARE_JS = publicFile('share.js');
const SHARE_CSS = publicFile('share.css');
const SRI_JS = publicFile('sri.js');

const sha256 = (s: string) => createHash('sha256').update(s).digest();
const newToken = (bytes: number) => randomBytes(bytes).toString('base64url');

type TripRow = {
  owner_hash: Uint8Array;
  dest_lat: number;
  dest_lng: number;
  dest_name: string | null;
  eta_at: number;
  lat: number | null;
  lng: number | null;
  heading: number | null;
  posted_at: number | null;
  updated_at: number;
  expires_at: number;
};

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
const cellKey = (v: number) => Math.round(roundDp(v, 3) * 1000); // probe grid cell (~110 m) as an integer
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
    -- Speed probes: one row per (cell, heading bucket, trip). The primary key is what stops a single trip
    -- from dominating a cell: one sample per trip per cell for the whole 15-min window (first one wins; the
    -- row leaves the window and is deleted 15 min after its minute, then the trip may count again).
    -- Integer cell keys make the bbox a range on the primary key's first column.
    CREATE TABLE IF NOT EXISTS probes (
      cell_lat INTEGER NOT NULL, -- lat rounded to 3 decimals, times 1000
      cell_lng INTEGER NOT NULL,
      heading INTEGER NOT NULL,  -- bucket: 0, 45, ..., 315
      trip_id TEXT NOT NULL,     -- random per trip, never linked to a deviceId
      minute INTEGER NOT NULL,   -- sample time floored to the minute, epoch ms
      speed REAL NOT NULL,
      PRIMARY KEY (cell_lat, cell_lng, heading, trip_id)
    ) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS probes_minute ON probes (minute);
    CREATE TABLE IF NOT EXISTS probe_posts (trip_id TEXT NOT NULL, at INTEGER NOT NULL); -- rate limit, 1 min
    CREATE INDEX IF NOT EXISTS probe_posts_trip ON probe_posts (trip_id, at);
    -- Share ETA: one row per shared trip with only the latest position (no trail). Deleted on end, on
    -- arrival, or by cleanup once expired (4 h after creation at most).
    CREATE TABLE IF NOT EXISTS trips (
      share_hash BLOB PRIMARY KEY, -- SHA-256 of the share token
      owner_hash BLOB NOT NULL,    -- SHA-256 of the owner token
      dest_lat REAL NOT NULL,
      dest_lng REAL NOT NULL,
      dest_name TEXT,
      eta_at INTEGER NOT NULL,
      lat REAL, lng REAL, heading REAL, -- latest position, NULL until the first update
      posted_at INTEGER,                -- time of the latest position, for the rate limit
      updated_at INTEGER NOT NULL,
      expires_at INTEGER NOT NULL
    ) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS trips_expires ON trips (expires_at);
    CREATE TABLE IF NOT EXISTS trip_creates (at INTEGER NOT NULL); -- global create rate limit, kept 1 min
    CREATE INDEX IF NOT EXISTS trip_creates_at ON trip_creates (at);
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
    // Skips the row once PROBE_TRIPS_PER_CELL_MIN trips entered the cell this minute; OR IGNORE drops any
    // further sample from a trip already in the cell's window.
    insertProbe: db.prepare(
      `INSERT OR IGNORE INTO probes (cell_lat, cell_lng, heading, trip_id, minute, speed)
       SELECT :cellLat, :cellLng, :heading, :tripId, :minute, :speed
       WHERE (SELECT COUNT(*) FROM probes
              WHERE cell_lat = :cellLat AND cell_lng = :cellLng AND heading = :heading AND minute = :minute)
         < ${PROBE_TRIPS_PER_CELL_MIN}`,
    ),
    // One row per trip per cell, so COUNT(*) is the distinct-trip count.
    traffic: db.prepare(
      `SELECT cell_lat, cell_lng, heading, json_group_array(speed) AS speeds FROM probes
       WHERE cell_lat BETWEEN ? AND ? AND cell_lng BETWEEN ? AND ? AND minute > ?
       GROUP BY cell_lat, cell_lng, heading HAVING COUNT(*) >= ${TRAFFIC_MIN_TRIPS}
       ORDER BY COUNT(*) DESC LIMIT ${MAX_RESULTS}`,
    ),
    cleanupProbes: db.prepare('DELETE FROM probes WHERE minute <= ?'),
    cleanupProbePosts: db.prepare('DELETE FROM probe_posts WHERE at <= ?'),
    activeTrips: db.prepare('SELECT COUNT(*) AS n FROM trips WHERE expires_at > ?'),
    insertTrip: db.prepare(
      `INSERT INTO trips (share_hash, owner_hash, dest_lat, dest_lng, dest_name, eta_at, updated_at, expires_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
    ),
    trip: db.prepare('SELECT * FROM trips WHERE share_hash = ? AND expires_at > ?'),
    // The rate limit is in the WHERE, so check and write are one statement: two concurrent posts cannot both
    // pass. 0 changes means "too soon" (or the trip ended in between).
    moveTrip: db.prepare(
      `UPDATE trips SET lat = :lat, lng = :lng, heading = :heading, eta_at = :eta, posted_at = :t, updated_at = :t
       WHERE share_hash = :hash AND expires_at > :t AND (posted_at IS NULL OR posted_at <= :t - ${TRIP_MIN_POST_GAP_MS})`,
    ),
    endTrip: db.prepare('DELETE FROM trips WHERE share_hash = ?'),
    cleanupTrips: db.prepare('DELETE FROM trips WHERE expires_at <= ?'),
    recentTripCreates: db.prepare('SELECT COUNT(*) AS n FROM trip_creates WHERE at > ?'),
    insertTripCreate: db.prepare('INSERT INTO trip_creates (at) VALUES (?)'),
    cleanupTripCreates: db.prepare('DELETE FROM trip_creates WHERE at <= ?'),
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
          s.heading <= 360 && isNum(s.speedKmh) && typeof s.t === 'string' && ISO_UTC.test(s.t) &&
          !Number.isNaN(Date.parse(s.t)); // the regex admits month 13 or hour 25
        if (!ok)
          return c.json(
            { error: 'each sample needs lat, lng, heading 0..360, speedKmh (numbers) and t (ISO 8601 UTC)' },
            400,
          );
      }

      // ponytail: no IPs and no accounts, so tripIds are free to mint: a forger can fake any cell's level with
      // TRAFFIC_MIN_TRIPS made-up trips. Two IP-less limits only bound the damage: PROBE_POSTS_PER_MIN per
      // tripId stops one trip flooding, and PROBE_TRIPS_PER_CELL_MIN caps new trips per cell per minute, so a
      // tripId-rotating flood cannot grow the table past cells x 20 x 15 rows. Trade-off: that cap is first
      // come, first served, so a flood that fills a cell each minute locks real drivers out of it and owns its
      // level (an availability attack on that cell, not on the server). Real fix: device attestation (App
      // Attest) on trip start, so each tripId costs a real device.
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
            cellLat: cellKey(s.lat),
            cellLng: cellKey(s.lng),
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

  // Returns only cell, heading bucket and level. No speed and no sample counts: tripIds are client-chosen, so
  // an attacker can add their own trips to a cell and subtract them out; exact speeds or counts would let
  // them recover a lone real driver's speed. A coarse level leaks far less, but it is still not anonymity.
  // ponytail: real fix is device attestation (App Attest) so fake trips cost real devices.
  app.get('/traffic', (c) => {
    const box = parseBbox((k) => c.req.query(k));
    if (typeof box === 'string') return c.json({ error: box }, 400);
    const lo = (v: number) => Math.ceil(v * 1000 - EPS);
    const hi = (v: number) => Math.floor(v * 1000 + EPS);
    const t = now();
    const rows = q.traffic.all(lo(box.minLat), hi(box.maxLat), lo(box.minLng), hi(box.maxLng), t - PROBE_WINDOW_MS) as {
      cell_lat: number;
      cell_lng: number;
      heading: number;
      speeds: string;
    }[];
    return c.json(
      rows.map((r) => ({
        lat: r.cell_lat / 1000,
        lng: r.cell_lng / 1000,
        heading: r.heading,
        level: level(median(JSON.parse(r.speeds))),
      })),
    );
  });

  // Share ETA (#19). See docs/privacy.md section 5 for the design rules.
  // etaAt: ISO 8601 UTC, from an hour ago (running late) to a day ahead.
  const parseEta = (v: unknown, t: number) => {
    const at = typeof v === 'string' && ISO_UTC.test(v) ? Date.parse(v) : NaN;
    return at >= t - HOUR && at <= t + 24 * HOUR ? at : null;
  };
  const ETA_ERROR = 'etaAt must be ISO 8601 UTC, from 1 h ago to 24 h ahead';

  // The share token comes from the X-Share-Token header (never the path, so it stays out of access logs).
  // A missing, malformed, unknown, ended or expired token all look the same: no row.
  const findTrip = (c: Context) => {
    const shareToken = c.req.header('x-share-token') ?? '';
    if (!SHARE_TOKEN.test(shareToken)) return null;
    const hash = sha256(shareToken);
    const row = q.trip.get(hash, now()) as TripRow | undefined;
    return row ? { hash, row } : null;
  };
  const notFound = (c: Context) => c.json({ error: 'trip not found or ended' }, 404);

  // 401 without a well-formed bearer token, 403 when it is not this trip's owner token, else null.
  const ownerCheck = (c: Context, row: TripRow) => {
    const m = BEARER.exec(c.req.header('authorization') ?? '');
    if (!m) {
      c.header('WWW-Authenticate', 'Bearer');
      return c.json({ error: 'owner token required' }, 401);
    }
    return timingSafeEqual(sha256(m[1]), row.owner_hash) ? null : c.json({ error: 'wrong owner token' }, 403);
  };

  app.post('/trips', limit, async (c) => {
    const b = await readJson(c);
    if (!b) return c.json({ error: 'body must be a JSON object' }, 400);
    const d = b.destination as Record<string, unknown> | null | undefined;
    if (!d || typeof d !== 'object' || Array.isArray(d))
      return c.json({ error: 'destination must be an object {lat, lng, name?}' }, 400);
    if (!isLat(d.lat)) return c.json({ error: 'destination.lat must be a number in -90..90' }, 400);
    if (!isLng(d.lng)) return c.json({ error: 'destination.lng must be a number in -180..180' }, 400);
    const name = typeof d.name === 'string' ? d.name.trim() : d.name;
    if (name != null && (typeof name !== 'string' || !name || name.length > TRIP_NAME_MAX || CONTROL_CHARS.test(name)))
      return c.json({ error: `destination.name must be 1-${TRIP_NAME_MAX} chars, no control characters` }, 400);
    const t = now();
    const eta = parseEta(b.etaAt, t);
    if (eta === null) return c.json({ error: ETA_ERROR }, 400);

    // ponytail: creation is keyed on nothing (no accounts, no IPs; `limit` above is only the 1 KB body cap).
    // Two global caps: TRIP_CREATES_PER_MIN slows a flood, TRIP_MAX_ACTIVE bounds the table (rows die in 4 h).
    // A flood can still fill the 10k pool in about 33 min and lock real drivers out of sharing until rows
    // expire (availability, not privacy). Real fix: App Attest on create (#46) or a per-IP limit at the proxy.
    const recent = (q.recentTripCreates.get(t - MIN) as { n: number }).n;
    if (recent >= TRIP_CREATES_PER_MIN) return c.json({ error: 'too many new trips, try again in a minute' }, 429);
    const { n } = q.activeTrips.get(t) as { n: number };
    if (n >= TRIP_MAX_ACTIVE) return c.json({ error: 'too many active trips, try again later' }, 503);

    const shareToken = newToken(16);
    const ownerToken = newToken(32);
    const expiresAt = t + TRIP_MAX_MS;
    tx(() => {
      q.insertTripCreate.run(t);
      q.insertTrip.run(sha256(shareToken), sha256(ownerToken), round4(d.lat), round4(d.lng), name ?? null, eta, t, expiresAt);
    });
    return c.json({ shareToken, ownerToken, expiresAt: iso(expiresAt) }, 201);
  });

  app.post('/trips/current/position', limit, async (c) => {
    const trip = findTrip(c);
    if (!trip) return notFound(c);
    const denied = ownerCheck(c, trip.row);
    if (denied) return denied;
    const b = await readJson(c);
    if (!b) return c.json({ error: 'body must be a JSON object' }, 400);
    const { lat, lng, heading, etaAt, arrived } = b;
    if (arrived !== undefined && typeof arrived !== 'boolean') return c.json({ error: 'arrived must be a boolean' }, 400);
    if (arrived) {
      q.endTrip.run(trip.hash); // arrival ends the share at once
      return c.body(null, 204);
    }
    if (!isLat(lat)) return c.json({ error: 'lat must be a number in -90..90' }, 400);
    if (!isLng(lng)) return c.json({ error: 'lng must be a number in -180..180' }, 400);
    if (heading != null && !(isNum(heading) && heading >= 0 && heading <= 360))
      return c.json({ error: 'heading must be a number in 0..360' }, 400);
    const t = now();
    const eta = parseEta(etaAt, t);
    if (eta === null) return c.json({ error: ETA_ERROR }, 400);
    // Overwrites the previous position in place: no trail is kept.
    const heading360 = isNum(heading) ? Math.round(heading) % 360 : null;
    const row = { lat: round4(lat), lng: round4(lng), heading: heading360, eta, t, hash: trip.hash };
    if (Number(q.moveTrip.run(row).changes) === 0) return c.json({ error: 'rate limit: 1 position per 5 s' }, 429);
    return c.body(null, 204);
  });

  app.post('/trips/current/end', (c) => {
    const trip = findTrip(c);
    if (!trip) return notFound(c);
    const denied = ownerCheck(c, trip.row);
    if (denied) return denied;
    q.endTrip.run(trip.hash);
    return c.body(null, 204);
  });

  app.get('/trips/current', (c) => {
    c.header('Cache-Control', 'no-store');
    c.header('Referrer-Policy', 'no-referrer');
    c.header('X-Robots-Tag', 'noindex, nofollow');
    const trip = findTrip(c);
    if (!trip) return notFound(c);
    const r = trip.row;
    // Explicit allowlist: never the token hashes or posted_at.
    return c.json({
      position: r.lat === null ? null : { lat: r.lat, lng: r.lng, heading: r.heading },
      destination: { lat: r.dest_lat, lng: r.dest_lng },
      ...(r.dest_name === null ? {} : { destinationName: r.dest_name }),
      etaAt: iso(r.eta_at),
      updatedAt: iso(r.updated_at),
      expiresAt: iso(r.expires_at),
      active: true,
    });
  });

  // Viewer link: /t/#<shareToken>. Browsers never send the #fragment, so the server only ever sees GET /t/.
  // share.js reads location.hash and polls GET /trips/current with the X-Share-Token header.
  const serve = (body: string, type: string) => (c: Context) => c.body(body, 200, { ...SHARE_HEADERS, 'Content-Type': type });
  app.get('/t/', serve(SHARE_HTML, 'text/html; charset=utf-8'));
  app.get('/t/share.js', serve(SHARE_JS, 'text/javascript; charset=utf-8'));
  app.get('/t/sri.js', serve(SRI_JS, 'text/javascript; charset=utf-8'));
  app.get('/t/share.css', serve(SHARE_CSS, 'text/css; charset=utf-8'));

  const cleanup = () => q.cleanup.run(now() - HOUR).changes;
  // Expired trips and their last position, plus the 1-min create log; server.ts runs this every minute.
  const cleanupTrips = () => {
    const t = now();
    q.cleanupTripCreates.run(t - MIN);
    return Number(q.cleanupTrips.run(t).changes);
  };
  // Probes run on their own 60 s timer (server.ts) so raw samples outlive the window by at most a minute.
  const cleanupProbes = () => {
    const t = now();
    return Number(q.cleanupProbes.run(t - PROBE_WINDOW_MS).changes) + Number(q.cleanupProbePosts.run(t - MIN).changes);
  };

  return { app, db, cleanup, cleanupProbes, cleanupTrips };
}
