import { serve } from '@hono/node-server';
import { createApp } from './app.ts';

const port = Number(process.env.PORT ?? 8787);
const { app, cleanup, cleanupProbes } = createApp({ dbPath: process.env.DB_PATH ?? './data/openwaze.db' });

// ponytail: single-process interval cleanup; reads already filter expired rows, so this only bounds disk use.
setInterval(cleanup, 5 * 60_000).unref();
// Raw speed probes and their tripIds: at most about a minute past the 15-min window.
setInterval(cleanupProbes, 60_000).unref();

serve({ fetch: app.fetch, port }, (info) => console.log(`openwaze server on http://localhost:${info.port}`));
