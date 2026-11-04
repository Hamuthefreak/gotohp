// A single password, remembered by a signed cookie.
//
// The dashboard controls one person's backup relay, so it does not need an
// identity provider: it needs to keep strangers out and not ask for the
// password again every day. The password lives in the deployment's environment
// (DASHBOARD_PASSWORD); the cookie holds only an expiry and an HMAC over it, so
// the server never has to store a session.
//
// Required environment: DASHBOARD_PASSWORD, AUTH_SECRET.
// Optional: DASHBOARD_USER, the username to type alongside it (default "hamu").
import { createHash, createHmac, timingSafeEqual } from 'node:crypto';

const SESSION_COOKIE = 'gthp_session';
const SESSION_SECONDS = 30 * 24 * 3600;

function sign(value, secret) {
	return createHmac('sha256', secret).update(value).digest('base64url');
}

function digest(value) {
	return createHash('sha256').update(value).digest();
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
	const bits = [`${name}=${encodeURIComponent(value)}`, 'Path=/', 'HttpOnly', 'SameSite=Lax', `Max-Age=${maxAge}`];
	if (secure) bits.push('Secure');
	return bits.join('; ');
}

const PAGE = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>gotohp relay</title>
<style>
  :root { color-scheme: dark; }
  body { margin:0; min-height:100vh; display:grid; place-items:center; background:#0a0e13; color:#e8eef5;
         font:15px/1.55 ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
  form { width:min(360px, calc(100vw - 48px)); background:#121a23; border:1px solid #1e2a36; border-radius:14px;
         padding:26px; box-shadow:0 20px 50px -30px #000; }
  h1 { font-size:18px; margin:0 0 6px; letter-spacing:-0.01em; }
  p { color:#8b9bab; font-size:13px; margin:0 0 18px; }
  input { width:100%; box-sizing:border-box; font:inherit; color:#e8eef5; background:#0a1016;
          border:1px solid #2a3a4a; border-radius:9px; padding:10px 12px; margin-bottom:12px; }
  input:focus { outline:2px solid #3ddc8440; outline-offset:1px; border-color:#1f6b45; }
  button { width:100%; font:inherit; font-weight:640; color:#04140b; background:#3ddc84; border:0;
           border-radius:9px; padding:10px 12px; cursor:pointer; }
  .err { color:#ff7b72; font-size:13px; margin:0 0 12px; }
</style>
<form method="post" action="/api/auth/login">
  <h1>gotohp relay</h1>
  <p>Sign in with your username and password.</p>
  {{ERROR}}
  <input type="text" name="username" value="{{USER}}" autocomplete="username" autocapitalize="none" spellcheck="false" required autofocus />
  <input type="password" name="password" autocomplete="current-password" required />
  <button type="submit">Sign in</button>
</form>`;

function escapeHtml(value) {
	return String(value).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
}

function page(username, status, error = '') {
	const body = PAGE.replaceAll('{{USER}}', escapeHtml(username)).replace('{{ERROR}}', error ? `<p class="err">${error}</p>` : '');
	return new Response(body, {
		status,
		headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' },
	});
}

/**
 * @param {Record<string,string|undefined>} env
 * @param {string} origin canonical https origin of this deployment
 */
export function createPasswordAuth(env, origin) {
	const password = env.DASHBOARD_PASSWORD || '';
	const secret = env.AUTH_SECRET || '';
	const username = (env.DASHBOARD_USER || 'hamu').trim() || 'hamu';
	const configured = Boolean(password && secret);
	const secure = origin.startsWith('https://');

	function readSession(request) {
		if (!configured) return null;
		const raw = parseCookies(request.headers.get('cookie'))[SESSION_COOKIE];
		if (!raw) return null;
		const at = raw.lastIndexOf('.');
		if (at < 1) return null;
		const payload = raw.slice(0, at);
		const expected = sign(payload, secret);
		const a = Buffer.from(raw.slice(at + 1));
		const b = Buffer.from(expected);
		if (a.length !== b.length || !timingSafeEqual(a, b)) return null;
		try {
			const data = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
			if (!data || !data.exp || data.exp < Math.floor(Date.now() / 1000)) return null;
			return { sub: 'operator', email: username };
		} catch {
			return null;
		}
	}

	function sessionCookie() {
		const payload = Buffer.from(JSON.stringify({ exp: Math.floor(Date.now() / 1000) + SESSION_SECONDS })).toString('base64url');
		return cookie(SESSION_COOKIE, `${payload}.${sign(payload, secret)}`, { maxAge: SESSION_SECONDS, secure });
	}

	return {
		configured,
		label: 'Sign in',

		async getUser(request) {
			return readSession(request);
		},

		/** Handles /api/auth/*, or returns null for anything else. */
		async handle(request) {
			const url = new URL(request.url);

			if (url.pathname === '/api/auth/login' && request.method === 'GET') {
				if (!configured) return page(username, 503, 'Set DASHBOARD_PASSWORD and AUTH_SECRET on the deployment, then reload.');
				return page(username, 200);
			}

			if (url.pathname === '/api/auth/login' && request.method === 'POST') {
				if (!configured) return page(username, 503, 'Set DASHBOARD_PASSWORD and AUTH_SECRET on the deployment, then reload.');

				const form = new URLSearchParams(await request.text());
				// One account, so the username is only a label to type: it still has to
				// match, or a leaked password alone would be enough.
				const named = (form.get('username') || '').trim().toLowerCase() === username.toLowerCase();
				const given = digest(form.get('password') || '');
				const expected = digest(password);
				if (!named || !timingSafeEqual(given, expected)) return page(username, 401, 'Wrong username or password.');
				return new Response(null, { status: 303, headers: { location: '/', 'set-cookie': sessionCookie() } });
			}

			if (url.pathname === '/api/auth/logout') {
				return new Response(null, {
					status: 303,
					headers: { location: '/', 'set-cookie': cookie(SESSION_COOKIE, '', { maxAge: 0, secure }) },
				});
			}

			return null;
		},
	};
}
