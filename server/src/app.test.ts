import assert from 'node:assert/strict';
import { beforeEach, test } from 'node:test';
import { createApp } from './app.ts';

let clock: number;
let app: ReturnType<typeof createApp>['app'];
let cleanup: () => number | bigint;
let cleanupProbes: () => number;
let cleanupTrips: () => number;
let db: ReturnType<typeof createApp>['db'];
const MIN = 60_000;

beforeEach(() => {
  clock = Date.parse('2026-10-22T10:00:00Z');
  ({ app, cleanup, cleanupProbes, cleanupTrips, db } = createApp({ dbPath: ':memory:', now: () => clock }));
});

const post = (path: string, body: unknown) =>
  app.request(path, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });

const create = async (over: Record<string, unknown> = {}) => {
  const res = await post('/reports', { type: 'police', lat: 1.3, lng: 103.8, deviceId: 'dev-a', ...over });
  return { res, body: await res.json() };
};

const box = (q = 'minLat=1&minLng=103&maxLat=2&maxLng=104') => app.request(`/reports?${q}`);

const vote = async (id: string, deviceId: string, stillThere: boolean) => {
  const res = await post(`/reports/${id}/vote`, { deviceId, stillThere });
  return { res, body: await res.json() };
};

test('create returns the report contract without deviceId', async () => {
  const { res, body } = await create();
  assert.equal(res.status, 201);
  assert.deepEqual(Object.keys(body).sort(), [
    'createdAt', 'downvotes', 'expiresAt', 'id', 'lat', 'lng', 'type', 'upvotes',
  ]);
  assert.equal(body.type, 'police');
  assert.equal(body.createdAt, '2026-10-22T10:00:00Z');
  assert.equal(body.expiresAt, '2026-10-22T11:00:00Z');
  assert.equal(body.upvotes, 0);
  assert.equal(body.downvotes, 0);
  assert.ok(!JSON.stringify(body).includes('dev-a'));
});

test('traffic reports live 30 minutes', async () => {
  const { body } = await create({ type: 'traffic' });
  assert.equal(body.expiresAt, '2026-10-22T10:30:00Z');
});

test('flood reports live 120 minutes, hidden exactly at expiry', async () => {
  const { res, body } = await create({ type: 'flood' });
  assert.equal(res.status, 201);
  assert.equal(body.type, 'flood');
  assert.equal(body.expiresAt, '2026-10-22T12:00:00Z');
  clock += 120 * MIN - 1;
  assert.equal((await (await box()).json()).length, 1);
  clock += 1;
  assert.deepEqual(await (await box()).json(), []);
  assert.equal((await vote(body.id, 'dev-b', true)).res.status, 404);
});

test('still-there vote on flood extends to now + 120 minutes', async () => {
  const r = (await create({ type: 'flood' })).body;
  clock += 90 * MIN;
  const { res, body } = await vote(r.id, 'dev-b', true);
  assert.equal(res.status, 200);
  assert.equal(body.upvotes, 1);
  assert.equal(body.expiresAt, '2026-10-22T13:30:00Z');
});

test('create rejects invalid input', async () => {
  const bad = [
    { type: 'ufo' },
    { type: 1 },
    { lat: 90.1 },
    { lat: -91 },
    { lat: '1.3' },
    { lng: 180.5 },
    { lng: null },
    { deviceId: '' },
    { deviceId: 'x'.repeat(129) },
    { deviceId: 'has space' },
    { deviceId: undefined },
  ];
  for (const over of bad) {
    const { res } = await create(over);
    assert.equal(res.status, 400, JSON.stringify(over));
  }
  assert.equal((await post('/reports', 'not json')).status, 400);
  assert.equal((await post('/reports', [1, 2])).status, 400);
  assert.equal((await post('/reports', { pad: 'x'.repeat(2000) })).status, 413);
});

test('rate limit: 10 reports per device per hour', async () => {
  for (let i = 0; i < 10; i++) assert.equal((await create()).res.status, 201);
  assert.equal((await create()).res.status, 429);
  assert.equal((await create({ deviceId: 'dev-b' })).res.status, 201, 'other devices unaffected');
  clock += 61 * MIN;
  assert.equal((await create()).res.status, 201, 'window slides');
});

test('bbox query returns only active reports inside the box', async () => {
  const inside = (await create()).body;
  await create({ lat: 5, lng: 103.8 }); // outside lat
  await create({ lat: 1.3, lng: 100 }); // outside lng
  const res = await box();
  assert.equal(res.status, 200);
  const list = await res.json();
  assert.deepEqual(list, [inside]);
  assert.ok(!JSON.stringify(list).includes('deviceId'));
});

test('bbox query validates bounds and area', async () => {
  for (const q of [
    '',
    'minLat=1&minLng=103&maxLat=2',
    'minLat=&minLng=103&maxLat=2&maxLng=104',
    'minLat=abc&minLng=103&maxLat=2&maxLng=104',
    'minLat=-91&minLng=103&maxLat=2&maxLng=104',
    'minLat=1&minLng=103&maxLat=2&maxLng=181',
    'minLat=2&minLng=103&maxLat=1&maxLng=104', // inverted
    'minLat=0&minLng=100&maxLat=3&maxLng=104', // 12 sq deg > max
  ]) {
    assert.equal((await box(q)).status, 400, q);
  }
});

test('bbox query caps results at 500', async () => {
  for (let i = 0; i < 51; i++) for (let j = 0; j < 10; j++) await create({ deviceId: `d${i}`, lat: 1 + i / 100 });
  assert.equal((await (await box()).json()).length, 500);
});

test('expired reports are hidden and cleaned up', async () => {
  const police = (await create()).body;
  await create({ type: 'traffic' });
  clock += 31 * MIN;
  assert.deepEqual((await (await box()).json()).map((r: { id: string }) => r.id), [police.id]);
  clock += 30 * MIN;
  assert.deepEqual(await (await box()).json(), []);
  assert.equal((await vote(police.id, 'dev-b', true)).res.status, 404, 'cannot vote on expired');
  assert.equal(cleanup(), 0, 'kept for an hour past expiry (rate-limit window)');
  clock += 60 * MIN;
  assert.equal(cleanup(), 2);
});

test('still-there vote extends expiry from now and counts', async () => {
  const r = (await create()).body;
  clock += 45 * MIN;
  const { res, body } = await vote(r.id, 'dev-b', true);
  assert.equal(res.status, 200);
  assert.equal(body.upvotes, 1);
  assert.equal(body.expiresAt, '2026-10-22T11:45:00Z');
  assert.ok(!('deviceId' in body));
});

test('two not-there votes remove a report', async () => {
  const r = (await create()).body;
  const first = await vote(r.id, 'dev-b', false);
  assert.equal(first.body.downvotes, 1);
  assert.equal(first.body.expiresAt, r.expiresAt);
  const second = await vote(r.id, 'dev-c', false);
  assert.equal(second.res.status, 200);
  assert.equal(second.body.downvotes, 2);
  assert.equal(second.body.expiresAt, '2026-10-22T10:00:00Z', 'expired now');
  assert.deepEqual(await (await box()).json(), []);
  assert.equal((await vote(r.id, 'dev-d', true)).res.status, 404);
});

test('one vote per device per report', async () => {
  const r = (await create()).body;
  assert.equal((await vote(r.id, 'dev-b', true)).res.status, 200);
  const again = await vote(r.id, 'dev-b', false);
  assert.equal(again.res.status, 409);
  const other = (await create()).body;
  assert.equal((await vote(other.id, 'dev-b', true)).res.status, 200, 'same device, other report is fine');
});

test('vote validates input and unknown ids', async () => {
  const r = (await create()).body;
  assert.equal((await vote(r.id, 'dev-b', 'yes' as unknown as boolean)).res.status, 400);
  assert.equal((await vote(r.id, '', true)).res.status, 400);
  assert.equal((await post(`/reports/${r.id}/vote`, 'nope')).status, 400);
  assert.equal((await vote('missing', 'dev-b', true)).res.status, 404);
});

test('oversized chunked body without Content-Length gets 413', async () => {
  const chunk = new TextEncoder().encode('x'.repeat(500));
  const body = new ReadableStream({
    start(c) {
      for (let i = 0; i < 4; i++) c.enqueue(chunk);
      c.close();
    },
  });
  const req = new Request('http://localhost/reports', {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'transfer-encoding': 'chunked' },
    body,
    duplex: 'half',
  } as RequestInit);
  assert.equal(req.headers.has('content-length'), false);
  assert.equal((await app.fetch(req)).status, 413);
});

test('author cannot vote on their own report', async () => {
  const r = (await create({ deviceId: 'author-1' })).body;
  assert.equal((await vote(r.id, 'author-1', true)).res.status, 409);
  assert.equal((await vote(r.id, 'author-1', false)).res.status, 409);
  const after = await vote(r.id, 'dev-b', true);
  assert.equal(after.body.upvotes, 1, 'author row does not count as a vote');
});

test('vote rate limit: 60 per device per hour, author rows not counted', async () => {
  const ids: string[] = [];
  for (let d = 0; d < 7; d++) for (let i = 0; i < 10; i++) ids.push((await create({ deviceId: `r${d}` })).body.id);
  await create({ deviceId: 'voter' });
  for (let i = 0; i < 60; i++) assert.equal((await vote(ids[i], 'voter', true)).res.status, 200, `vote ${i}`);
  assert.equal((await vote(ids[60], 'voter', true)).res.status, 429);
  assert.equal((await vote(ids[60], 'other-voter', true)).res.status, 200);
  clock += 30 * MIN;
  const fresh = (await create({ deviceId: 'late' })).body.id;
  clock += 30 * MIN - 1;
  assert.equal((await vote(fresh, 'voter', true)).res.status, 429);
  clock += 1;
  assert.equal((await vote(fresh, 'voter', true)).res.status, 200, 'window slides at exactly 60 min');
});

test('report rate window boundary is exactly 60 minutes', async () => {
  for (let i = 0; i < 10; i++) await create();
  clock += 60 * MIN - 1;
  assert.equal((await create()).res.status, 429);
  clock += 1;
  assert.equal((await create()).res.status, 201);
});

test('report is hidden exactly at expiresAt', async () => {
  const r = (await create()).body;
  clock += 60 * MIN - 1;
  assert.equal((await (await box()).json()).length, 1);
  clock += 1;
  assert.deepEqual(await (await box()).json(), []);
  assert.equal((await vote(r.id, 'dev-b', true)).res.status, 404);
});

test('bbox caps each axis span and accepts a box exactly at the caps', async () => {
  assert.equal((await box('minLat=0&minLng=0&maxLat=2.5&maxLng=1')).status, 400, 'lat span 2.5, area 2.5');
  assert.equal((await box('minLat=0&minLng=0&maxLat=1&maxLng=2.5')).status, 400, 'lng span 2.5, area 2.5');
  assert.equal((await box('minLat=0&minLng=0&maxLat=2&maxLng=2')).status, 200);
  assert.equal((await box('minLat=1.2&minLng=103.1&maxLat=3.2&maxLng=105.1')).status, 200, 'float subtraction');
  assert.equal((await box('minLat=0&minLng=0&maxLat=2.001&maxLng=2')).status, 400);
});

test('deviceId values never appear in create, list or vote responses', async () => {
  const created = await post('/reports', { type: 'hazard', lat: 1.3, lng: 103.8, deviceId: 'canary-author' });
  const createText = await created.text();
  const { id } = JSON.parse(createText);
  const voteText = await (await post(`/reports/${id}/vote`, { deviceId: 'canary-voter', stillThere: true })).text();
  const listText = await (await box()).text();
  assert.ok(listText.includes(id));
  for (const text of [createText, voteText, listText]) {
    assert.ok(!text.includes('canary-author'), text);
    assert.ok(!text.includes('canary-voter'), text);
    assert.ok(!text.includes('deviceId'), text);
  }
});

test('create rounds lat/lng to 4 decimals, half away from zero, no float artefacts', async () => {
  const cases: [number, number, number, number][] = [
    [3.15789999999, 101.71164999, 3.1579, 101.7116],
    [3.15785, -101.71165, 3.1579, -101.7117],
    [-1.00005, 0.00004, -1.0001, 0],
    [-0.00004, 1.3, 0, 1.3],
  ];
  for (const [lat, lng, wantLat, wantLng] of cases) {
    const { res, body } = await create({ lat, lng });
    assert.equal(res.status, 201);
    assert.equal(body.lat, wantLat);
    assert.equal(body.lng, wantLng);
    assert.ok(!Object.is(body.lat, -0) && !Object.is(body.lng, -0));
  }
});

test('responses carry at most 4 decimals in raw JSON (create, list, vote)', async () => {
  const { body } = await create({ lat: 3.15790000001, lng: 101.711600000049 });
  const decimals = /"(?:lat|lng)":-?\d+(?:\.(\d+))?/g;
  const check = (json: string) => {
    const hits = [...json.matchAll(decimals)];
    assert.equal(hits.length >= 2, true);
    for (const m of hits) assert.ok((m[1] ?? '').length <= 4, m[0]);
  };
  check(JSON.stringify(body));
  check(await (await box('minLat=3&minLng=101&maxLat=4&maxLng=102')).text());
  check(JSON.stringify((await vote(body.id, 'dev-b', true)).body));
});

test('bbox edge: raw point just outside the edge rounds onto it and is found; far side stays out', async () => {
  const onEdge = (await create({ lat: 1.99996, lng: 103.5 })).body; // raw < maxLat, stored as 2
  const pastEdge = (await create({ lat: 2.00004, lng: 103.5 })).body; // raw > maxLat, stored as 2
  const justOut = (await create({ lat: 2.00006, lng: 103.5 })).body; // stored as 2.0001
  assert.equal(onEdge.lat, 2);
  assert.equal(pastEdge.lat, 2);
  assert.equal(justOut.lat, 2.0001);
  const ids = (await (await box('minLat=1&minLng=103&maxLat=2&maxLng=104')).json()).map((r: { id: string }) => r.id);
  assert.deepEqual(ids.sort(), [onEdge.id, pastEdge.id].sort());
});

// --- speed probes and live traffic (#13) ---

const sample = (over: Record<string, unknown> = {}) => ({
  lat: 3.1579, lng: 101.7116, heading: 90, speedKmh: 10, t: new Date(clock).toISOString(), ...over,
});
const probe = async (tripId: string, samples: unknown[]) => {
  const res = await post('/probes', { tripId, samples });
  return { res, body: await res.json() };
};
const trip = () => crypto.randomUUID();
const trips3 = async (over: Record<string, unknown> = {}) => {
  for (let i = 0; i < 3; i++) await probe(trip(), [sample(over)]);
};
type Cell = { lat: number; lng: number; heading: number; level: string };
const traffic = async (q = 'minLat=3&minLng=101&maxLat=4&maxLng=102'): Promise<Cell[]> =>
  (await app.request(`/traffic?${q}`)).json();
const byLat = (cells: Cell[]) => cells.sort((a, b) => a.lat - b.lat);
const count = (table: string) => (db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get() as { n: number }).n;

test('probes: validates body, tripId and samples', async () => {
  const ok = await probe(trip(), [sample()]);
  assert.equal(ok.res.status, 202);
  assert.deepEqual(ok.body, { accepted: 1 });
  const id = trip();
  for (const [tripId, samples] of [
    ['not-a-uuid', [sample()]],
    ['', [sample()]],
    [42, [sample()]],
    [id, []],
    [id, Array.from({ length: 31 }, () => sample())],
    [id, 'nope'],
    [id, [null]],
    [id, [sample({ lat: 91 })]],
    [id, [sample({ lng: '101' })]],
    [id, [sample({ heading: -1 })]],
    [id, [sample({ heading: 361 })]],
    [id, [sample({ speedKmh: '10' })]],
    [id, [sample({ t: 1761127200000 })]],
    [id, [sample({ t: 'yesterday' })]],
    [id, [sample({ t: '2026-10-22T10:00:00+08:00' })]],
    [id, [sample({ t: '2026-13-01T10:00:00Z' })]], // matches the regex, Date.parse is NaN
    [id, [sample({ t: '2026-10-22T25:00:00Z' })]],
  ] as [unknown, unknown][]) {
    const res = await post('/probes', { tripId, samples });
    assert.equal(res.status, 400, JSON.stringify({ tripId, samples }).slice(0, 120));
  }
  assert.equal((await post('/probes', { tripId: id, samples: [sample()], deviceId: 'dev-a' })).status, 400);
  assert.equal((await post('/probes', 'not json')).status, 400);
  assert.equal((await post('/probes', { tripId: id, samples: [sample()], pad: 'x'.repeat(8200) })).status, 413);
  assert.equal((await probe(id, Array.from({ length: 30 }, (_, i) => sample({ lat: 3 + i / 100 })))).body.accepted, 30);
});

test('probes: drops samples older than 5 min, in the future, or with speed outside 0..200', async () => {
  const at = (ms: number, i: number, speedKmh = 10) =>
    sample({ lat: 3 + i / 100, speedKmh, t: new Date(clock + ms).toISOString() });
  const { body } = await probe(trip(), [
    at(-5 * MIN, 0), // kept: exactly 5 min old
    at(-5 * MIN - 1000, 1), // dropped
    at(MIN, 2), // kept: within 1 min clock skew
    at(MIN + 1000, 3), // dropped
    at(0, 4, 0), // kept
    at(0, 5, 200), // kept
    at(0, 6, -1), // dropped
    at(0, 7, 200.1), // dropped
  ]);
  assert.deepEqual(body, { accepted: 4 });
  assert.equal(count('probes'), 4);
});

test('traffic: returns only cell, heading bucket and level; no speed, counts or tripId', async () => {
  const ids = [trip(), trip(), trip()];
  await probe(ids[0], [sample({ lat: 3.1575, lng: 101.7116, heading: 22 })]);
  await probe(ids[1], [sample({ lat: 3.15849, lng: 101.71249, heading: 350 })]);
  await probe(ids[2], [sample({ lat: 3.1579, lng: 101.7115, heading: 360 })]);
  const text = await (await app.request('/traffic?minLat=3&minLng=101&maxLat=4&maxLng=102')).text();
  assert.deepEqual(JSON.parse(text), [{ lat: 3.158, lng: 101.712, heading: 0, level: 'jam' }]);
  for (const id of ids) assert.ok(!text.includes(id));
  assert.ok(!/trip|speed|sample/i.test(text), text);
});

test('traffic: snapping handles negative coordinates and half-cell and half-bucket boundaries', async () => {
  const cases: [Record<string, number>, Cell][] = [
    [{ lat: -3.1575, lng: -101.7125, heading: 22.5 }, { lat: -3.158, lng: -101.713, heading: 45, level: 'jam' }],
    [{ lat: -3.15749, lng: -101.71249, heading: 22.4 }, { lat: -3.157, lng: -101.712, heading: 0, level: 'jam' }],
    [{ lat: 3.15749, lng: 101.71249, heading: 337.4 }, { lat: 3.157, lng: 101.712, heading: 315, level: 'jam' }],
    [{ lat: 3.1575, lng: 101.7125, heading: 337.5 }, { lat: 3.158, lng: 101.713, heading: 0, level: 'jam' }],
    [{ lat: -0.0004, lng: -0.0005, heading: 0 }, { lat: 0, lng: -0.001, heading: 0, level: 'jam' }],
  ];
  for (const [over] of cases) await trips3(over);
  const want = cases.map(([, cell]) => cell);
  assert.deepEqual(byLat(await traffic('minLat=-3.5&minLng=-102&maxLat=-2.5&maxLng=-101')), want.slice(0, 2));
  assert.deepEqual(byLat(await traffic('minLat=3&minLng=101&maxLat=3.5&maxLng=102')), want.slice(2, 4));
  const [zero] = await traffic('minLat=-0.5&minLng=-0.5&maxLat=0.5&maxLng=0.5');
  assert.deepEqual(zero, want[4]);
  assert.ok(!Object.is(zero.lat, -0));
});

test('traffic: hidden below 3 distinct trips (noise floor)', async () => {
  const a = trip();
  await probe(a, [sample()]);
  clock += MIN;
  await probe(a, [sample()]); // same trip, later minute: still 1 trip
  await probe(trip(), [sample()]);
  assert.deepEqual(await traffic(), []);
  await probe(trip(), [sample()]);
  assert.equal((await traffic()).length, 1);
});

test('traffic: one trip counts once per cell per 15-min window (13 samples cannot outvote 2 trips)', async () => {
  const a = trip();
  assert.equal((await probe(a, [sample({ speedKmh: 5 })])).body.accepted, 1);
  for (let m = 1; m < 13; m++) {
    clock += MIN;
    assert.equal((await probe(a, [sample({ speedKmh: 5 })])).body.accepted, 0, `minute ${m}`);
  }
  await probe(trip(), [sample({ speedKmh: 60 })]);
  await probe(trip(), [sample({ speedKmh: 60 })]);
  assert.equal((await traffic())[0].level, 'free', 'median of 5, 60, 60; 13 rows of 5 would read jam');
  assert.equal(count('probes'), 3);
  clock += 3 * MIN; // a's first sample is now 15 min old
  assert.equal(cleanupProbes() > 0, true);
  assert.equal((await probe(a, [sample({ speedKmh: 5 })])).body.accepted, 1, 'counts again once out of window');
});

test('traffic: levels from the median speed, jam < 15, slow < 40, else free', async () => {
  const cases: [number[], string][] = [
    [[14, 14, 14], 'jam'],
    [[15, 15, 15], 'slow'],
    [[39, 39, 100], 'slow'],
    [[40, 40, 0], 'free'],
    [[10, 20, 30, 40], 'slow'], // even count: mean of the middle two, 25
    [[0, 14, 16, 100], 'slow'], // 15
    [[0, 13, 16, 100], 'jam'], // 14.5
  ];
  for (const [i, [speeds]] of cases.entries())
    for (const speedKmh of speeds) await probe(trip(), [sample({ lat: 3 + i / 10, speedKmh })]);
  assert.deepEqual(byLat(await traffic()).map((c) => c.level), cases.map(([, lvl]) => lvl));
});

test('traffic: samples leave the window at 15 min and cleanupProbes deletes them', async () => {
  await trips3();
  clock += 15 * MIN - 1;
  assert.equal((await traffic()).length, 1);
  assert.equal(cleanupProbes(), 3, 'rate-limit rows (1 min) go; samples stay');
  assert.equal(count('probes'), 3);
  clock += 1;
  assert.deepEqual(await traffic(), []);
  assert.equal(cleanupProbes(), 3);
  assert.equal(count('probes'), 0);
  assert.equal(count('probe_posts'), 0);
});

test('traffic: bbox validated like /reports, edges inclusive on the cell, outside hidden', async () => {
  for (const q of [
    '',
    'minLat=3&minLng=101&maxLat=4',
    'minLat=4&minLng=101&maxLat=3&maxLng=102', // inverted
    'minLat=0&minLng=100&maxLat=3&maxLng=104', // area
  ])
    assert.equal((await app.request(`/traffic?${q}`)).status, 400, q);
  await trips3(); // cell 3.158, 101.712
  await trips3({ lat: 5.5 });
  assert.equal((await traffic()).length, 1);
  assert.equal((await traffic('minLat=5&minLng=101&maxLat=6&maxLng=102'))[0].lat, 5.5);
  assert.equal((await traffic('minLat=3.158&minLng=101.712&maxLat=3.158&maxLng=101.712')).length, 1);
  assert.deepEqual(await traffic('minLat=3.1581&minLng=101&maxLat=5&maxLng=102'), []);
  assert.deepEqual(await traffic('minLat=3&minLng=101&maxLat=3.1579&maxLng=102'), []);
});

test('traffic query is a range search on the probes primary key, not a table scan', () => {
  const plan = db
    .prepare(
      `EXPLAIN QUERY PLAN SELECT cell_lat FROM probes
       WHERE cell_lat BETWEEN 1 AND 2 AND cell_lng BETWEEN 1 AND 2 AND minute > 0
       GROUP BY cell_lat, cell_lng, heading`,
    )
    .all()
    .map((r) => (r as { detail: string }).detail)
    .join('; ');
  assert.match(plan, /SEARCH probes USING PRIMARY KEY \(cell_lat>\? AND cell_lat<\?\)/, plan);
});

test('probes rate limits: 12 posts per trip per minute, 20 new trips per cell per minute', async () => {
  const a = trip();
  for (let i = 0; i < 12; i++) assert.equal((await probe(a, [sample({ lat: 3 + i / 100 })])).res.status, 202);
  assert.equal((await probe(a, [sample()])).res.status, 429);
  assert.equal((await probe(trip(), [sample()])).res.status, 202, 'other trips unaffected');
  clock += MIN;
  assert.equal((await probe(a, [sample({ lat: 3.5 })])).res.status, 202, 'window slides');

  const accepted = [];
  for (let i = 0; i < 21; i++) accepted.push((await probe(trip(), [sample({ lat: 3.9 })])).body.accepted);
  assert.deepEqual(accepted, [...Array(20).fill(1), 0]);
  clock += MIN;
  assert.equal((await probe(trip(), [sample({ lat: 3.9 })])).body.accepted, 1, 'next minute has room');
});

// Share ETA (#19)
const ETA = '2026-10-22T10:30:00Z';
type Share = { shareToken: string; ownerToken: string };
const tripBody = (over: Record<string, unknown> = {}) => ({
  destination: { lat: 3.1579, lng: 101.7116, name: 'KLCC' },
  etaAt: ETA,
  ...over,
});
const startTrip = async (over: Record<string, unknown> = {}) => {
  const res = await post('/trips', tripBody(over));
  return { res, body: await res.json() };
};
const ownerPost = (path: string, body: unknown, auth?: string) =>
  app.request(path, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...(auth === undefined ? {} : { authorization: auth }) },
    body: JSON.stringify(body),
  });
const move = (s: Share, over: Record<string, unknown> = {}, auth = `Bearer ${s.ownerToken}`) =>
  ownerPost(`/trips/${s.shareToken}/position`, { lat: 3.15, lng: 101.7, heading: 90, etaAt: ETA, ...over }, auth);
const endTrip = (s: Share, auth = `Bearer ${s.ownerToken}`) => ownerPost(`/trips/${s.shareToken}/end`, {}, auth);
const view = (shareToken: string) => app.request(`/trips/${shareToken}`);
const tripRows = () => db.prepare('SELECT * FROM trips').all() as Record<string, unknown>[];

test('trips: create returns a 128-bit URL-safe share token, a separate owner token, 4 h expiry', async () => {
  const { res, body } = await startTrip();
  assert.equal(res.status, 201);
  assert.deepEqual(Object.keys(body).sort(), ['expiresAt', 'ownerToken', 'shareToken']);
  assert.match(body.shareToken, /^[A-Za-z0-9_-]{22}$/);
  assert.equal(Buffer.from(body.shareToken, 'base64url').length, 16);
  assert.match(body.ownerToken, /^[A-Za-z0-9_-]{43}$/);
  assert.equal(Buffer.from(body.ownerToken, 'base64url').length, 32);
  assert.ok(!body.ownerToken.includes(body.shareToken));
  assert.equal(body.expiresAt, '2026-10-22T14:00:00Z');

  const seen = new Set<string>();
  for (let i = 0; i < 200; i++) {
    const b = (await startTrip()).body;
    seen.add(b.shareToken).add(b.ownerToken);
  }
  assert.equal(seen.size, 400, 'tokens never repeat');
});

test('trips: neither token is stored in plain text, only hashes', async () => {
  const { body } = await startTrip();
  const dump = JSON.stringify(tripRows(), (_, v) =>
    v instanceof Uint8Array ? [Buffer.from(v).toString('base64url'), Buffer.from(v).toString('hex')] : v,
  );
  assert.ok(!dump.includes(body.shareToken), 'share token stored');
  assert.ok(!dump.includes(body.ownerToken), 'owner token stored');
  assert.equal(tripRows().length, 1);
});

test('trips: view before and after a position update', async () => {
  const s = (await startTrip()).body;
  let res = await view(s.shareToken);
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('cache-control'), 'no-store');
  assert.equal(res.headers.get('referrer-policy'), 'no-referrer');
  assert.deepEqual(await res.json(), {
    position: null,
    destination: { lat: 3.1579, lng: 101.7116 },
    destinationName: 'KLCC',
    etaAt: ETA,
    updatedAt: '2026-10-22T10:00:00Z',
    expiresAt: '2026-10-22T14:00:00Z',
    active: true,
  });

  clock += 15_000;
  const upd = { lat: 3.123456, lng: 101.654349, heading: 359.6, etaAt: '2026-10-22T10:31:00Z' };
  assert.equal((await move(s, upd)).status, 204);
  res = await view(s.shareToken);
  const v = await res.json();
  assert.deepEqual(v.position, { lat: 3.1235, lng: 101.6543, heading: 0 }, 'rounded to 4 decimals, heading mod 360');
  assert.equal(v.etaAt, '2026-10-22T10:31:00Z');
  assert.equal(v.updatedAt, '2026-10-22T10:00:15Z');
  assert.ok(!JSON.stringify(v).includes(s.ownerToken));
});

test('trips: destination name is optional; create validates its body', async () => {
  const s = (await startTrip({ destination: { lat: 1.23456, lng: 2 } })).body;
  const v = await (await view(s.shareToken)).json();
  assert.ok(!('destinationName' in v));
  assert.deepEqual(v.destination, { lat: 1.2346, lng: 2 });
  const bad = [
    { destination: null },
    { destination: [1, 2] },
    { destination: { lat: 91, lng: 0 } },
    { destination: { lat: 0, lng: '1' } },
    { destination: { lat: 0, lng: 0, name: '  ' } },
    { destination: { lat: 0, lng: 0, name: 'x'.repeat(101) } },
    { destination: { lat: 0, lng: 0, name: 'a\nb' } },
    { destination: { lat: 0, lng: 0, name: 7 } },
    { etaAt: 'soon' },
    { etaAt: '2026-10-22T08:59:00Z' }, // more than 1 h ago
    { etaAt: '2026-10-23T10:01:00Z' }, // more than 24 h ahead
  ];
  for (const b of bad) assert.equal((await post('/trips', tripBody(b))).status, 400, JSON.stringify(b));
  assert.equal((await post('/trips', '[]')).status, 400);
  assert.equal((await post('/trips', { ...tripBody(), pad: 'x'.repeat(2000) })).status, 413);
});

test('trips: only the latest position is kept, no trail', async () => {
  const s = (await startTrip()).body;
  for (let i = 0; i < 5; i++) {
    assert.equal((await move(s, { lat: 3 + i / 100 })).status, 204);
    clock += 5_000;
  }
  const rows = tripRows();
  assert.equal(rows.length, 1);
  assert.equal(rows[0].lat, 3.04);
  const tables = db
    .prepare("SELECT name FROM sqlite_master WHERE type = 'table'")
    .all()
    .map((r) => (r as { name: string }).name);
  assert.deepEqual(tables.filter((n) => /trip|position|track|trail/i.test(n)), ['trips'], 'no history table');
});

test('trips: owner auth, missing or malformed token 401, wrong token 403', async () => {
  const s = (await startTrip()).body;
  const other = (await startTrip()).body;
  const res = await ownerPost(`/trips/${s.shareToken}/position`, { lat: 3, lng: 101, etaAt: ETA });
  assert.equal(res.status, 401);
  assert.equal(res.headers.get('www-authenticate'), 'Bearer');
  assert.equal((await ownerPost(`/trips/${s.shareToken}/end`, {})).status, 401);
  for (const auth of ['', `Basic ${s.ownerToken}`, `Bearer ${s.ownerToken}x`, `Bearer ${s.shareToken}`, s.ownerToken]) {
    assert.equal((await move(s, {}, auth)).status, 401, auth);
    assert.equal((await endTrip(s, auth)).status, 401, auth);
  }
  assert.equal((await move(s, {}, `Bearer ${other.ownerToken}`)).status, 403);
  assert.equal((await endTrip(s, `Bearer ${other.ownerToken}`)).status, 403);
  const v = await (await view(s.shareToken)).json();
  assert.equal(v.active, true, 'still active after failed attempts');
  assert.equal(v.position, null, 'nothing was written');
});

test('trips: position validates its body', async () => {
  const s = (await startTrip()).body;
  const bad = [{ lat: 91 }, { lng: -181 }, { lat: '3' }, { heading: 361 }, { heading: -1 }, { etaAt: 'x' }, { arrived: 'yes' }];
  for (const b of bad) assert.equal((await move(s, b)).status, 400, JSON.stringify(b));
  assert.equal((await move(s, { heading: null })).status, 204, 'heading optional');
  assert.equal((await (await view(s.shareToken)).json()).position.heading, null);
});

test('trips: rate limit 1 position per 5 s per trip', async () => {
  const s = (await startTrip()).body;
  const other = (await startTrip()).body;
  assert.equal((await move(s)).status, 204);
  clock += 4_999;
  assert.equal((await move(s)).status, 429);
  assert.equal((await move(other)).status, 204, 'other trips unaffected');
  clock += 1;
  assert.equal((await move(s)).status, 204);
});

test('trips: end deletes the trip and its position; later calls 404', async () => {
  const s = (await startTrip()).body;
  await move(s);
  assert.equal((await endTrip(s)).status, 204);
  assert.equal(tripRows().length, 0);
  assert.equal((await view(s.shareToken)).status, 404);
  assert.equal((await move(s)).status, 404);
  assert.equal((await endTrip(s)).status, 404);
});

test('trips: arrived flag ends the trip', async () => {
  const s = (await startTrip()).body;
  assert.equal((await move(s, { arrived: true })).status, 204);
  assert.equal(tripRows().length, 0);
  assert.equal((await view(s.shareToken)).status, 404);
});

test('trips: expire 4 h after creation even with updates, then cleanup deletes them', async () => {
  const s = (await startTrip()).body;
  clock += 4 * 60 * MIN - 1;
  assert.equal((await move(s, { etaAt: '2026-10-22T14:30:00Z' })).status, 204, 'updates do not extend');
  assert.equal((await view(s.shareToken)).status, 200);
  assert.equal(cleanupTrips(), 0);
  clock += 1;
  assert.equal((await view(s.shareToken)).status, 404);
  assert.equal((await move(s, { etaAt: '2026-10-22T14:30:00Z' })).status, 404);
  assert.equal((await endTrip(s)).status, 404);
  assert.equal(cleanupTrips(), 1);
  assert.equal(tripRows().length, 0);
});

test('trips: unknown or malformed share tokens 404', async () => {
  await startTrip();
  for (const t of ['AAAAAAAAAAAAAAAAAAAAAA', 'short', 'A'.repeat(23), '..%2F..'])
    assert.equal((await view(t)).status, 404, t);
});

test('share page: static HTML, strict CSP, SRI on MapLibre >= 6.4.1, no inline script', async () => {
  const s = (await startTrip()).body;
  const res = await app.request(`/t/${s.shareToken}`);
  assert.equal(res.status, 200);
  assert.match(res.headers.get('content-type') ?? '', /^text\/html/);
  assert.equal(res.headers.get('referrer-policy'), 'no-referrer');
  assert.match(res.headers.get('x-robots-tag') ?? '', /noindex/);
  const csp = res.headers.get('content-security-policy') ?? '';
  assert.match(csp, /default-src 'none'/);
  assert.match(csp, /script-src 'self' https:\/\/cdn\.jsdelivr\.net\/npm\/maplibre-gl@[\d.]+\/dist\/maplibre-gl\.mjs;/);
  assert.doesNotMatch(csp, /unsafe-inline|unsafe-eval|\*/);
  const html = await res.text();
  assert.ok(!html.includes(s.shareToken), 'token not echoed into the page');
  assert.ok(!html.includes('{{'), 'template filled');
  const version = /maplibre-gl@(\d+\.\d+\.\d+)\//.exec(html)?.[1] ?? '0.0.0';
  const [maj, min, pat] = version.split('.').map(Number);
  assert.ok(maj > 6 || (maj === 6 && (min > 4 || (min === 4 && pat >= 1))), `maplibre-gl ${version} < 6.4.1`);
  const cdnTags = html.match(/<link[^>]+cdn\.jsdelivr\.net[^>]*>/g) ?? [];
  assert.equal(cdnTags.length, 2, 'module preload and stylesheet');
  for (const tag of cdnTags) {
    assert.match(tag, /integrity="sha384-[A-Za-z0-9+/]{64}"/, tag);
    assert.match(tag, /crossorigin="anonymous"/, tag);
  }
  const scripts = html.match(/<script\b[^>]*>/g) ?? [];
  assert.deepEqual(scripts, ['<script type="module" src="/t/share.js">'], 'only the same-origin script');
  assert.match(html, /<meta name="referrer" content="no-referrer">/);

  const js = await app.request('/t/share.js');
  assert.equal(js.status, 200);
  assert.match(js.headers.get('content-type') ?? '', /^text\/javascript/);
  assert.equal(js.headers.get('content-security-policy'), csp);
  const code = await js.text();
  assert.match(code, /integrity: 'sha384-[A-Za-z0-9+/]{64}'/, 'worker fetched with SRI');
  assert.match(code, /POLL_MS = 15_000/);
  assert.match(code, /OpenStreetMap/);
  assert.doesNotMatch(code, /innerHTML|localStorage|document\.cookie|analytics|gtag/);
  assert.equal((await app.request('/t/share.css')).status, 200);
  assert.equal((await app.request('/t/not-a-token')).status, 404);
});
