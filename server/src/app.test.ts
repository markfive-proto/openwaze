import assert from 'node:assert/strict';
import { beforeEach, test } from 'node:test';
import { createApp } from './app.ts';

let clock: number;
let app: ReturnType<typeof createApp>['app'];
let cleanup: () => number | bigint;
let cleanupProbes: () => number;
let db: ReturnType<typeof createApp>['db'];
const MIN = 60_000;

beforeEach(() => {
  clock = Date.parse('2026-10-22T10:00:00Z');
  ({ app, cleanup, cleanupProbes, db } = createApp({ dbPath: ':memory:', now: () => clock }));
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
