// Shared body for every Vercel function.
//
// Vercel's Node runtime hands over (req, res); src/app.js speaks Web
// Request/Response, so this adapter converts both directions. Each route in
// api/ is a one-line re-export of this, which keeps Vercel's file-system routing
// unambiguous for nested paths like /api/device/poll.
import { createApp } from '../../src/app.js';
import { createPasswordAuth } from '../../src/auth-password.js';
import { blobStore } from '../../src/store-blob.js';
import { remoteStore } from '../../src/store-remote.js';

let cached;

function build(env, origin) {
	// The store choice is part of the cache key: an instance that cached a
	// Blob-backed app must not keep answering after the switch to D1.
	const backend = env.STATE_URL && env.STATE_SECRET ? 'd1' : 'blob';
	if (cached && cached.origin === origin && cached.backend === backend) return cached;
	const auth = createPasswordAuth(env, origin);
	const routes = createApp({
		// D1 through the Sites deployment when it is configured; Blob only as a
		// fallback for a deployment that predates it (its free quota is too small
		// for this relay's polling).
		store: env.STATE_URL && env.STATE_SECRET ? remoteStore(env) : blobStore(env),
		origin,
		sameOrigin: (request) => {
			const site = request.headers.get('origin');
			// Same-origin fetches send the exact origin; a form post from the login
			// page may send nothing at all, which only same-site requests can do.
			return !site || site === origin;
		},
		auth: {
			getUser: (request) => auth.getUser(request),
			loginUrl: '/api/auth/login',
			signoutUrl: '/api/auth/logout',
			signoutMethod: 'GET',
			label: 'Sign in',
			configured: auth.configured,
		},
	});
	cached = { origin, backend, auth, routes };
	return cached;
}

async function readBody(req) {
	const chunks = [];
	for await (const chunk of req) chunks.push(Buffer.from(chunk));
	return chunks.length ? Buffer.concat(chunks) : undefined;
}

export default async function handle(req, res) {
	try {
		await respond(req, res);
	} catch (error) {
		// Vercel answers any uncaught error with "A server error has occurred",
		// which never says which call failed. Answer in JSON with the reason so
		// the dashboard and curl both show something actionable.
		console.error('gotohp relay handler failed:', error);
		const detail = String(error?.message || error).slice(0, 300);
		res.statusCode = 500;
		res.setHeader('content-type', 'application/json; charset=utf-8');
		res.setHeader('cache-control', 'no-store');
		res.end(JSON.stringify({ error: 'the relay could not answer', detail }));
	}
}

async function respond(req, res) {
	// The canonical origin is the OAuth redirect URI and the origin every
	// state-changing request is checked against. APP_ORIGIN wins; the request's
	// own scheme and host are only a fallback for preview URLs.
	const proto = String(req.headers['x-forwarded-proto'] || 'https').split(',')[0].trim();
	const origin = process.env.APP_ORIGIN || `${proto}://${req.headers.host}`;
	const { auth, routes } = build(process.env, origin);

	const url = new URL(req.url, origin);
	const headers = new Headers();
	for (const [key, value] of Object.entries(req.headers)) {
		if (typeof value === 'string') headers.set(key, value);
		else if (Array.isArray(value)) headers.set(key, value.join(', '));
	}

	const body = req.method === 'GET' || req.method === 'HEAD' ? undefined : await readBody(req);
	const request = new Request(url, { method: req.method, headers, body });

	let response = await auth.handle(request);
	if (!response) response = await routes(request, process.env);
	if (!response) response = new Response('Not found', { status: 404 });

	res.statusCode = response.status;
	response.headers.forEach((value, key) => res.setHeader(key, value));
	res.end(Buffer.from(await response.arrayBuffer()));
}

export const config = { api: { bodyParser: false } };
