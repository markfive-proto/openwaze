// Fetch a CDN file with Subresource Integrity and return a same-origin blob: URL of exactly those bytes.
// fetch() rejects on a hash mismatch, so nothing unchecked is ever imported or started as a worker.
// Plain fetch() APIs only, so src/app.test.ts runs this same file under Node against a tampered fixture.
export async function checkedBlobUrl(url, integrity) {
  if (!/^sha384-[A-Za-z0-9+/]{64}$/.test(integrity)) throw new Error('integrity hash required');
  const res = await fetch(url, { integrity, credentials: 'omit', referrerPolicy: 'no-referrer' });
  if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
  return URL.createObjectURL(new Blob([await res.arrayBuffer()], { type: 'text/javascript' }));
}
