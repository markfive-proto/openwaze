// Share-ETA viewer (#19). Served by the API at /t/share.js; {{...}} is filled from MAPLIBRE in src/app.ts.
// No trackers, cookies or web storage. Everything from the API is rendered with textContent.
import { LngLatBounds, Map, Marker, setWorkerUrl } from '{{JS_URL}}';

const POLL_MS = 15_000;
const token = location.pathname.split('/').pop();
const statusEl = document.getElementById('status');
const destEl = document.getElementById('dest');
const say = (text) => { statusEl.textContent = text; };

// MapLibre would load its worker from the CDN without an integrity check. Fetch it with SRI instead and
// start it from a same-origin blob: URL (CSP allows workers from blob: only).
try {
  const res = await fetch('{{WORKER_URL}}', { integrity: '{{WORKER_SRI}}', credentials: 'omit', referrerPolicy: 'no-referrer' });
  if (!res.ok) throw new Error(`worker ${res.status}`);
  setWorkerUrl(URL.createObjectURL(new Blob([await res.text()], { type: 'text/javascript' })));
} catch {
  say('Map failed to load');
  throw new Error('maplibre worker failed its integrity check or did not load');
}

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
  let res;
  try {
    res = await fetch(`/trips/${encodeURIComponent(token)}`, { cache: 'no-store' });
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
