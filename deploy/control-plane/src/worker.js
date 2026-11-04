// Cloudflare Worker host for the control plane (Freebuff Sites deployment).
//
// Sign-in is Freebuff's, storage is D1, static files come from the ASSETS
// binding. The routes themselves live in app.js, shared with the Vercel build.
import { createFreebuffAuth, isSameOriginRequest } from '@freebuff/auth';

import { createApp } from './app.js';
import { d1Store } from './store-d1.js';

/** @type {((request: Request, env: Env) => Promise<Response>) | undefined} */
let handler;

/** The only keys the Vercel build may read or write through the state API. */
const STATE_KEYS = new Set([
	'state',
	'activity',
	'events',
	'commands',
	'accounts',
	'settings',
	'pending_cred',
	'owner_sub',
	'owner_email',
	'device_token_hash',
	'pairing_open_until',
]);

function json(body, status = 200) {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
	});
}

function authorised(request, env) {
	const secret = String(env.STATE_SECRET || '');
	if (!secret) return false;
	return (request.headers.get('authorization') || '') === `Bearer ${secret}`;
}

/**
 * The state API the Vercel deployment uses for storage. It is answered before
 * the sign-in wrapper on purpose: the caller is a server with a shared secret,
 * not a browser with a session, and only the keys this app itself uses are
 * reachable.
 */
async function stateRoute(request, env) {
	const url = new URL(request.url);
	if (!url.pathname.startsWith('/api/state/')) return null;
	if (!authorised(request, env)) return new Response('unauthorized', { status: 401 });
	if (request.method !== 'POST') return new Response('method not allowed', { status: 405 });

	const store = d1Store(env);

	if (url.pathname === '/api/state/get') {
		const body = await request.json().catch(() => null);
		const keys = Array.isArray(body?.keys) ? body.keys.filter((k) => STATE_KEYS.has(k)).slice(0, 20) : [];
		const out = {};
		for (const key of keys) out[key] = await store.get(key);
		return json(out);
	}

	if (url.pathname === '/api/state/set') {
		const body = await request.json().catch(() => null);
		const key = String(body?.key || '');
		const value = body?.value;
		if (!STATE_KEYS.has(key)) return json({ error: 'unknown key' }, 400);
		if (typeof value !== 'string') return json({ error: 'value must be a string' }, 400);
		if (value.length > 100_000) return json({ error: 'value is too large' }, 413);
		await store.set(key, value);
		return json({ ok: true });
	}

	return json({ error: 'not found' }, 404);
}

function setup(env) {
	if (handler) return handler;

	const auth = createFreebuffAuth({
		clientId: env.FREEBUFF_CLIENT_ID,
		issuer: env.FREEBUFF_ISSUER,
		baseUrl: env.APP_ORIGIN,
		// Loopback only. A deployed origin is https, so this stays off there.
		allowInsecureLocalhost: env.ALLOW_INSECURE_LOCALHOST === '1',
	});

	const routes = createApp({
		store: d1Store(env),
		origin: env.APP_ORIGIN,
		sameOrigin: (request) => isSameOriginRequest(request, env.APP_ORIGIN),
		auth: {
			getUser: (request) => auth.getUser(request),
			loginUrl: '/auth/freebuff/signin?returnTo=/',
			signoutUrl: '/auth/freebuff/signout',
			signoutMethod: 'POST',
			label: 'Sign in with Freebuff',
		},
	});

	/** @typedef {{ASSETS:{fetch(r:Request):Promise<Response>}, DB:D1Database,
	 *   FREEBUFF_CLIENT_ID:string, FREEBUFF_ISSUER?:string, APP_ORIGIN:string}} Env */
	handler = auth.wrap(async (request, env) => (await routes(request, env)) ?? env.ASSETS.fetch(request));
	return handler;
}

export default {
	/** @param {Request} request @param {Env} env */
	async fetch(request, env) {
		const state = await stateRoute(request, env);
		if (state) return state;
		return setup(env)(request, env);
	},
};
