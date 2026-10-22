import { serve } from '@hono/node-server';
import { createApp } from './app.ts';

const port = Number(process.env.PORT ?? 8787);
const { app, cleanup } = createApp({ dbPath: process.env.DB_PATH ?? './data/openwaze.db' });

// ponytail: single-process interval cleanup. Reads already filter expired rows; this bounds disk use and keeps
// raw speed probes at most about a minute past their 15-min window.
setInterval(cleanup, 60_000).unref();

serve({ fetch: app.fetch, port }, (info) => console.log(`openwaze server on http://localhost:${info.port}`));
