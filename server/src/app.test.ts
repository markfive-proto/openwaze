import assert from 'node:assert/strict';
import { beforeEach, test } from 'node:test';
import { createApp } from './app.ts';

let clock: number;
let app: ReturnType<typeof createApp>['app'];
let cleanup: () => number | bigint;
const MIN = 60_000;

beforeEach(() => {
  clock = Date.parse('2026-10-22T10:00:00Z');
  ({ app, cleanup } = createApp({ dbPath: ':memory:', now: () => clock }));
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
