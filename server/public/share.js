// Share-ETA viewer (#19). Served by the API at /t/share.js; {{...}} is filled from MAPLIBRE in src/app.ts.
// No trackers, cookies or web storage. Everything from the API is rendered with textContent.
import { checkedBlobUrl } from '/t/sri.js';

const POLL_MS = 15_000;
// The link is /t/#<token>: the fragment never leaves the browser, and the API gets it in a header.
const token = decodeURIComponent(location.hash.slice(1));
const statusEl = document.getElementById('status');
const destEl = document.getElementById('dest');
const say = (text) => { statusEl.textContent = text; };

// MapLibre's module and its worker are fetched with SRI and run only from blob: URLs of the checked bytes.
// CSP lets no CDN URL run as script, so an unchecked copy cannot load by any other path.
let maplibre;
try {
  const [lib, worker] = await Promise.all([
    checkedBlobUrl('{{JS_URL}}', '{{JS_SRI}}'),
    checkedBlobUrl('{{WORKER_URL}}', '{{WORKER_SRI}}'),
  ]);
  maplibre = await import(lib);
  maplibre.setWorkerUrl(worker);
} catch {
  say('Map failed to load');
  throw new Error('maplibre-gl failed its integrity check or did not load');
}
const { LngLatBounds, Map, Marker } = maplibre;

const map = new Map({
  container: 'map',
  style: 'https://tiles.openfreemap.org/styles/liberty',
  center: [101.7116, 3.1579],
  zoom: 12,
  attributionControl: {
    compact: false,
    customAttribution:
      '<a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener noreferrer">© OpenStreetMap contributors</a>',
  },
});

const carEl = document.createElement('div');
carEl.className = 'car';
carEl.setAttribute('aria-label', 'Driver');
let car = null;
let dest = null;
let fitted = false;
let stopped = false;

const etaText = (etaAt) => {
  const eta = new Date(etaAt);
  const min = Math.max(0, Math.round((eta.getTime() - Date.now()) / 60_000));
  return `Arriving ${eta.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })} (${min} min)`;
};

const ended = () => {
  stopped = true;
  car?.remove();
  car = null;
  say('Trip ended');
};

async function poll() {
  if (!/^[A-Za-z0-9_-]{22}$/.test(token)) return ended(); // not a link we made
  let res;
  try {
    res = await fetch('/trips/current', { cache: 'no-store', headers: { 'X-Share-Token': token } });
  } catch {
    say('Reconnecting…');
    return;
  }
  if (res.status === 404) return ended();
  if (!res.ok) return say('Reconnecting…');
  const trip = await res.json();

  destEl.textContent = trip.destinationName ? `To ${trip.destinationName}` : '';
  say(etaText(trip.etaAt));
  const to = [trip.destination.lng, trip.destination.lat];
  dest ??= new Marker({ color: '#d93025' }).setLngLat(to).addTo(map);
  if (trip.position) {
    const at = [trip.position.lng, trip.position.lat];
    car ??= new Marker({ element: carEl, rotationAlignment: 'map' }).setLngLat(at).addTo(map);
    car.setLngLat(at).setRotation(trip.position.heading ?? 0);
    if (!fitted) map.fitBounds(new LngLatBounds(at, at).extend(to), { padding: 80, maxZoom: 15, duration: 0 });
  } else if (!fitted) {
    map.jumpTo({ center: to, zoom: 14 });
  }
  fitted = true;
}

await poll();
const timer = setInterval(() => (stopped ? clearInterval(timer) : poll()), POLL_MS);
