// Control plane for the gotohp relay.
//
// The VM has no inbound port and no TLS. It pulls instead: the agent on the box
// asks this Worker for settings and commands, applies them locally, and reports
// what it sees. Nothing here can reach into the VM, and no Google credential or
// SSH key ever passes through this Worker.
import { createFreebuffAuth, isSameOriginRequest } from '@freebuff/auth';

import { defaults, SETTINGS, validateAll } from './schema.js';

const JSON_HEAD = {
  'content-type': 'application/json; charset=utf-8',
  'cache-control': 'private, no-store',
};
const TEXT_HEAD = {
  'content-type': 'text/plain; charset=utf-8',
  'cache-control': 'no-store',
};

/** @type {import('@freebuff/auth').FreebuffAuth | undefined} */
let auth;
/** @type {((request: Request, env: Env) => Promise<Response>) | undefined} */
let handler;

function setup(env) {
  auth ??= createFreebuffAuth({
    clientId: env.FREEBUFF_CLIENT_ID,
    issuer: env.FREEBUFF_ISSUER,
    baseUrl: env.APP_ORIGIN,
    // Loopback only. The deployed origin is https, so this stays off there.
    allowInsecureLocalhost: env.ALLOW_INSECURE_LOCALHOST === '1',
  });
  handler ??= auth.wrap(route);
  return { auth, handler };
}

/** @typedef {{ASSETS:{fetch(r:Request):Promise<Response>}, DB:D1Database,
 *   FREEBUFF_CLIENT_ID:string, FREEBUFF_ISSUER?:string, APP_ORIGIN:string}} Env */

// ---------------------------------------------------------------------------
// storage: one key/value table holds everything. The relay has one owner, one
// device and one settings document, so a schema per concern would be noise.
// ---------------------------------------------------------------------------

const SCHEMA = [
  `create table if not exists kv (
     k text primary key,
     v text not null,
     updated_at text not null
   )`,
];

let schemaReady = false;

async function db(env) {
  if (!schemaReady) {
    await env.DB.batch(SCHEMA.map((sql) => env.DB.prepare(sql)));
    schemaReady = true;
  }
  return env.DB;
}

async function get(env, key) {
  const d = await db(env);
  const row = await d.prepare('select v from kv where k = ?').bind(key).first();
  return row ? row.v : null;
}

async function set(env, key, value) {
  const d = await db(env);
  await d
    .prepare('insert into kv (k, v, updated_at) values (?, ?, ?) on conflict(k) do update set v = excluded.v, updated_at = excluded.updated_at')
    .bind(key, value, new Date().toISOString())
    .run();
}

async function getJSON(env, key, fallback) {
  const raw = await get(env, key);
  if (!raw) return fallback;
  try {
    return JSON.parse(raw);
  } catch {
    return fallback;
  }
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

function json(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEAD });
}

function text(body, status = 200) {
  return new Response(body, { status, headers: TEXT_HEAD });
}

function bearer(request) {
  const header = request.headers.get('authorization') || '';
  const match = /^Bearer\s+(.+)$/i.exec(header);
  return match ? match[1].trim() : '';
}

async function sha256(value) {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function randomToken() {
  const bytes = crypto.getRandomValues(new Uint8Array(24));
  return [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** `key=value` lines, as the agent sends them. */
function parseKv(body) {
  /** @type {Record<string,string>} */
  const out = {};
  for (const line of body.split('\n')) {
    if (!line || line.startsWith('#')) continue;
    const at = line.indexOf('=');
    if (at < 1) continue;
    const key = line.slice(0, at).trim();
    if (!/^[a-z0-9_]{1,40}$/.test(key)) continue;
    out[key] = line.slice(at + 1).trim().slice(0, 400);
  }
  return out;
}

/**
 * Resolve the signed-in user and confirm they are the owner. The first account
 * to load the dashboard claims it; everyone else gets 403 forever after. That
 * keeps the box's controls to a single person without a password to store.
 */
async function owner(request, env) {
  const { auth } = setup(env);
  const user = await auth.getUser(request);
  if (!user) return { error: json({ error: 'sign in required' }, 401) };

  let ownerSub = await get(env, 'owner_sub');
  if (!ownerSub) {
    await set(env, 'owner_sub', user.sub);
    await set(env, 'owner_email', user.email || '');
    ownerSub = user.sub;
  }
  if (ownerSub !== user.sub) return { error: json({ error: 'this dashboard belongs to another account' }, 403) };
  return { user };
}

function sameOrigin(request, env) {
  return isSameOriginRequest(request, env.APP_ORIGIN);
}

// ---------------------------------------------------------------------------
// routes
// ---------------------------------------------------------------------------

/** @param {Request} request @param {Env} env */
async function route(request, env) {
  const url = new URL(request.url);
  const path = url.pathname;
  const method = request.method;

  if (path === '/api/session' && method === 'GET') {
    const { auth } = setup(env);
    const user = await auth.getUser(request);
    const ownerSub = await get(env, 'owner_sub');
    return json({
      signedIn: Boolean(user),
      email: user?.email || user?.name || '',
      isOwner: Boolean(user && ownerSub === user.sub),
      claimable: Boolean(user && !ownerSub),
    });
  }

  if (path === '/api/dashboard' && method === 'GET') {
    const who = await owner(request, env);
    if (who.error) return who.error;

    const stored = await getJSON(env, 'settings', {});
    const settings = { ...defaults(), ...stored };
    const state = await getJSON(env, 'state', {});
    const commands = await getJSON(env, 'commands', []);
    const tokenHash = await get(env, 'device_token_hash');

    return json({
      settings,
      state,
      schema: SETTINGS,
      commands: commands.slice(-10).reverse(),
      device: { paired: Boolean(tokenHash) },
      ownerEmail: (await get(env, 'owner_email')) || '',
    });
  }

  if (path === '/api/settings' && (method === 'PUT' || method === 'POST')) {
    if (!sameOrigin(request, env)) return json({ error: 'cross-origin request rejected' }, 403);
    const who = await owner(request, env);
    if (who.error) return who.error;

    const body = await request.json().catch(() => null);
    if (!body || typeof body !== 'object') return json({ error: 'expected a JSON object' }, 400);

    const result = validateAll(body);
    if ('errors' in result) return json({ errors: result.errors }, 400);

    await set(env, 'settings', JSON.stringify(result.settings));
    return json({ ok: true, settings: result.settings });
  }

  if (path === '/api/commands' && method === 'POST') {
    if (!sameOrigin(request, env)) return json({ error: 'cross-origin request rejected' }, 403);
    const who = await owner(request, env);
    if (who.error) return who.error;

    const body = await request.json().catch(() => null);
    const kind = String(body?.kind || '');
    const KINDS = ['run-now', 'refresh', 'rescan'];
    if (!KINDS.includes(kind)) return json({ error: `kind must be one of ${KINDS.join(', ')}` }, 400);

    const commands = await getJSON(env, 'commands', []);
    const entry = { id: crypto.randomUUID().slice(0, 8), kind, created_at: new Date().toISOString(), done: false };
    commands.push(entry);
    await set(env, 'commands', JSON.stringify(commands.slice(-50)));
    return json({ ok: true, command: entry });
  }

  if (path === '/api/device/token' && method === 'GET') {
    const who = await owner(request, env);
    if (who.error) return who.error;
    return json({ paired: Boolean(await get(env, 'device_token_hash')) });
  }

  if (path === '/api/device/token' && method === 'POST') {
    if (!sameOrigin(request, env)) return json({ error: 'cross-origin request rejected' }, 403);
    const who = await owner(request, env);
    if (who.error) return who.error;

    // Shown exactly once. Only the hash is stored, the same way a password would be.
    const token = randomToken();
    await set(env, 'device_token_hash', await sha256(token));
    return json({ ok: true, token });
  }

  // ---- device channel: authenticated by a device token, never by a session --

  if (path === '/api/device/poll' && method === 'POST') {
    const token = bearer(request);
    if (!token) return text('unauthorized', 401);
    const stored = await get(env, 'device_token_hash');
    if (!stored || stored !== (await sha256(token))) return text('unauthorized', 401);

    const state = parseKv(await request.text());
    await set(env, 'state', JSON.stringify({ ...state, reported_at: new Date().toISOString() }));

    const settings = { ...defaults(), ...(await getJSON(env, 'settings', {})) };
    const commands = await getJSON(env, 'commands', []);
    const pending = commands.filter((c) => !c.done);

    const lines = Object.entries(settings).map(([k, v]) => `SET ${k}=${v}`);
    for (const c of pending) lines.push(`CMD ${c.id} ${c.kind}`);
    return text(`${lines.join('\n')}\n`);
  }

  if (path === '/api/device/result' && method === 'POST') {
    const token = bearer(request);
    if (!token) return text('unauthorized', 401);
    const stored = await get(env, 'device_token_hash');
    if (!stored || stored !== (await sha256(token))) return text('unauthorized', 401);

    const commands = await getJSON(env, 'commands', []);
    let changed = false;
    for (const line of (await request.text()).split('\n')) {
      const match = /^RESULT\s+(\S+)\s+(ok|fail)(?:\s+(.*))?$/.exec(line.trim());
      if (!match) continue;
      const target = commands.find((c) => c.id === match[1]);
      if (!target || target.done) continue;
      target.done = true;
      target.ok = match[2] === 'ok';
      target.output = (match[3] || '').slice(0, 500);
      target.done_at = new Date().toISOString();
      changed = true;
    }
    if (changed) await set(env, 'commands', JSON.stringify(commands));
    return json({ ok: true });
  }

  if (path.startsWith('/api/')) return json({ error: 'not found' }, 404);

  return env.ASSETS.fetch(request);
}

export default {
  /** @param {Request} request @param {Env} env */
  fetch(request, env) {
    return setup(env).handler(request, env);
  },
};
