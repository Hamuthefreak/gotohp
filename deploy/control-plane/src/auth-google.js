// Sign in with Google, for the Vercel deployment.
//
// Freebuff's sign-in is tied to the Freebuff origin, so a deployment elsewhere
// has to bring its own OAuth client. This is a plain authorization-code flow
// with a signed, HttpOnly session cookie: no database table for sessions, and
// nothing about the Google account is stored beyond the subject and email the
// dashboard needs to recognise its owner.
//
// Required environment:
//   GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET  - from Google Cloud Console
//   AUTH_SECRET                             - any long random string
//   ALLOWED_EMAIL (recommended)             - the only address allowed in
import { createHmac, randomBytes, timingSafeEqual } from 'node:crypto';

const SESSION_COOKIE = 'gthp_session';
const STATE_COOKIE = 'gthp_state';
const SESSION_SECONDS = 30 * 24 * 3600;

const GOOGLE_AUTH = 'https://accounts.google.com/o/oauth2/v2/auth';
const GOOGLE_TOKEN = 'https://oauth2.googleapis.com/token';
const GOOGLE_USERINFO = 'https://openidconnect.googleapis.com/v1/userinfo';

function sign(value, secret) {
	return createHmac('sha256', secret).update(value).digest('base64url');
}

function parseCookies(header) {
	/** @type {Record<string,string>} */
	const out = {};
	for (const part of (header || '').split(';')) {
		const at = part.indexOf('=');
		if (at < 1) continue;
		out[part.slice(0, at).trim()] = decodeURIComponent(part.slice(at + 1).trim());
	}
	return out;
}

function cookie(name, value, { maxAge, secure }) {
	const bits = [`${name}=${encodeURIComponent(value)}`, 'Path=/', 'HttpOnly', `SameSite=Lax`, `Max-Age=${maxAge}`];
	if (secure) bits.push('Secure');
	return bits.join('; ');
}

function html(body, status = 200) {
	return new Response(
		`<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>gotohp relay</title>
		<body style="margin:0;display:grid;place-items:center;min-height:100vh;background:#0b0f14;color:#e6edf3;font:16px/1.6 system-ui,sans-serif">
		<div style="max-width:32rem;padding:2rem;text-align:center">${body}</div></body>`,
		{ status, headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' } },
	);
}

/**
 * @param {Record<string,string|undefined>} env
 * @param {string} origin canonical https origin of this deployment
 */
export function createGoogleAuth(env, origin) {
	const clientId = env.GOOGLE_CLIENT_ID || '';
	const clientSecret = env.GOOGLE_CLIENT_SECRET || '';
	const secret = env.AUTH_SECRET || '';
	const allowlist = String(env.ALLOWED_EMAIL || '')
		.split(',')
		.map((s) => s.trim().toLowerCase())
		.filter(Boolean);
	const configured = Boolean(clientId && clientSecret && secret);
	const secure = origin.startsWith('https://');
	const redirectUri = `${origin}/api/auth/callback`;

	function readSession(request) {
		if (!configured) return null;
		const raw = parseCookies(request.headers.get('cookie'))[SESSION_COOKIE];
		if (!raw) return null;
		const at = raw.lastIndexOf('.');
		if (at < 1) return null;
		const payload = raw.slice(0, at);
		const signature = raw.slice(at + 1);
		const expected = sign(payload, secret);
		const a = Buffer.from(signature);
		const b = Buffer.from(expected);
		if (a.length !== b.length || !timingSafeEqual(a, b)) return null;
		try {
			const data = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
			if (!data || !data.sub || !data.exp || data.exp < Math.floor(Date.now() / 1000)) return null;
			return { sub: String(data.sub), email: String(data.email || '') };
		} catch {
			return null;
		}
	}

	function issue(method, url, headers) {
		return new Response(null, { status: 303, headers: { ...headers, location: url } });
	}

	return {
		configured,
		label: 'Sign in with Google',

		async getUser(request) {
			return readSession(request);
		},

		/**
		 * Handles /api/auth/* and returns a Response, or null when the request is
		 * something else. The caller must not treat null as "not authenticated".
		 */
		async handle(request) {
			const url = new URL(request.url);

			if (url.pathname === '/api/auth/login') {
				if (!configured) return html('<h1>Google sign-in is not configured</h1><p>Set GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET and AUTH_SECRET, then redeploy.</p>', 503);
				const state = randomBytes(16).toString('hex');
				const authorize = new URL(GOOGLE_AUTH);
				authorize.searchParams.set('client_id', clientId);
				authorize.searchParams.set('redirect_uri', redirectUri);
				authorize.searchParams.set('response_type', 'code');
				authorize.searchParams.set('scope', 'openid email profile');
				authorize.searchParams.set('state', state);
				authorize.searchParams.set('prompt', 'select_account');
				return issue('GET', authorize.toString(), {
					'set-cookie': cookie(STATE_COOKIE, state, { maxAge: 600, secure }),
				});
			}

			if (url.pathname === '/api/auth/callback') {
				if (!configured) return html('<h1>Google sign-in is not configured</h1>', 503);

				const code = url.searchParams.get('code') || '';
				const state = url.searchParams.get('state') || '';
				const expected = parseCookies(request.headers.get('cookie'))[STATE_COOKIE] || '';
				if (!code) return html('<h1>Sign-in cancelled</h1><p>Google did not return a code.</p>', 400);
				if (!state || state !== expected) return html('<h1>Sign-in expired</h1><p>Start again from the dashboard.</p>', 400);

				const token = await fetch(GOOGLE_TOKEN, {
					method: 'POST',
					headers: { 'content-type': 'application/x-www-form-urlencoded' },
					body: new URLSearchParams({
						code,
						client_id: clientId,
						client_secret: clientSecret,
						redirect_uri: redirectUri,
						grant_type: 'authorization_code',
					}),
				}).catch(() => null);

				if (!token || !token.ok) return html('<h1>Google refused the token exchange</h1><p>Check the client secret and the redirect URI.</p>', 502);

				const tokens = await token.json().catch(() => ({}));
				const info = await fetch(GOOGLE_USERINFO, {
					headers: { authorization: `Bearer ${tokens.access_token || ''}` },
				}).catch(() => null);
				if (!info || !info.ok) return html('<h1>Could not read your Google profile</h1>', 502);

				const profile = await info.json().catch(() => ({}));
				const email = String(profile.email || '').toLowerCase();
				if (!profile.sub || !email) return html('<h1>Google returned no email address</h1>', 400);
				if (profile.email_verified === false) return html('<h1>That Google address is not verified</h1>', 403);
				if (allowlist.length && !allowlist.includes(email)) {
					return html(`<h1>Not allowed</h1><p>${email.replace(/[<>&]/g, '')} is not the operator of this dashboard.</p>`, 403);
				}

				const payload = Buffer.from(
					JSON.stringify({
						sub: String(profile.sub),
						email,
						exp: Math.floor(Date.now() / 1000) + SESSION_SECONDS,
					}),
				).toString('base64url');
				const value = `${payload}.${sign(payload, secret)}`;

				return issue('GET', '/', {
					'set-cookie': [cookie(SESSION_COOKIE, value, { maxAge: SESSION_SECONDS, secure }), cookie(STATE_COOKIE, '', { maxAge: 0, secure })].join(', '),
				});
			}

			if (url.pathname === '/api/auth/logout') {
				return issue('GET', '/', { 'set-cookie': cookie(SESSION_COOKIE, '', { maxAge: 0, secure }) });
			}

			return null;
		},
	};
}
