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
const qNum = (s: string | undefined) => (s === undefined || s.trim() === '' ? NaN : Number(s));

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
      q.insert.run(id, type, lat, lng, deviceId, t, t + LIFETIME_MS(type as ReportType));
      q.insertVote.run(id, deviceId, null, t); // author cannot vote on their own report
    });
    return c.json(toReport(q.byId.get(id) as Row), 201);
  });

  app.get('/reports', (c) => {
    const minLat = qNum(c.req.query('minLat'));
    const minLng = qNum(c.req.query('minLng'));
    const maxLat = qNum(c.req.query('maxLat'));
    const maxLng = qNum(c.req.query('maxLng'));
    if (!isLat(minLat) || !isLat(maxLat) || !isLng(minLng) || !isLng(maxLng))
      return c.json({ error: 'minLat, maxLat in -90..90 and minLng, maxLng in -180..180 are required' }, 400);
    // ponytail: no antimeridian-crossing boxes (minLng > maxLng); split into two queries client-side if needed.
    if (minLat > maxLat || minLng > maxLng) return c.json({ error: 'min must be <= max' }, 400);
    if (maxLat - minLat > MAX_BBOX_SPAN_DEG + EPS || maxLng - minLng > MAX_BBOX_SPAN_DEG + EPS)
      return c.json({ error: `bbox span must be <= ${MAX_BBOX_SPAN_DEG} degrees per axis` }, 400);
    if ((maxLat - minLat) * (maxLng - minLng) > MAX_BBOX_AREA_DEG2 + EPS)
      return c.json({ error: `bbox area must be <= ${MAX_BBOX_AREA_DEG2} square degrees` }, 400);
    const rows = q.bbox.all(minLat, maxLat, minLng, maxLng, now()) as Row[];
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

  const cleanup = () => q.cleanup.run(now() - HOUR).changes;

  return { app, db, cleanup };
}
