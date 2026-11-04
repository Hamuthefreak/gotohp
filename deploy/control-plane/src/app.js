// The dashboard's HTTP surface, written once and mounted on both hosts:
//
//   * Cloudflare Worker + D1  (the Freebuff Sites deployment)
//   * Vercel functions + Blob (the Vercel deployment)
//
// Everything here speaks Web `Request`/`Response`, so both runtimes can use it
// unchanged. Storage and sign-in come in through `createApp`: a store is just
// get/set by key, an auth object only has to answer "who is this request".
import { defaults, SETTINGS, validateAll } from './schema.js';

const JSON_HEAD = {
	'content-type': 'application/json; charset=utf-8',
	'cache-control': 'private, no-store',
};
const TEXT_HEAD = {
	'content-type': 'text/plain; charset=utf-8',
	'cache-control': 'no-store',
};

const COMMAND_KINDS = ['run-now', 'refresh', 'rescan', 'creds-set', 'creds-remove', 'clear-log'];

/** Credentials are account emails; nothing else ever reaches a shell. */
const EMAIL = /^[A-Za-z0-9._%+@-]{3,120}$/;
const PHASES = ['idle', 'scanning', 'waiting', 'uploading', 'error'];

/** Longest accepted device activity body, in bytes. */
const ACTIVITY_LIMIT = 16 * 1024;
/** How long an event stays in the live feed. */
const EVENT_LIMIT = 40;

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

function b64(value) {
	const bytes = new TextEncoder().encode(value);
	let out = '';
	for (const b of bytes) out += String.fromCharCode(b);
	return btoa(out);
}

function randomToken() {
	const bytes = crypto.getRandomValues(new Uint8Array(24));
	return [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');
}

const now = () => new Date().toISOString();

function str(value, max = 300) {
	return typeof value === 'string' ? value.slice(0, max) : value === undefined || value === null ? '' : String(value).slice(0, max);
}

function int(value) {
	const n = Number(value);
	return Number.isFinite(n) && n >= 0 ? Math.floor(n) : 0;
}

/** `key=value` lines, as the VM agent sends them. */
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
 * Shape whatever the agent reported into the fields the dashboard draws. Extra
 * keys are dropped, strings are capped, and a phase we do not know becomes
 * "idle" rather than an arbitrary value rendered into the page.
 */
function normalizeActivity(raw) {
	if (!raw || typeof raw !== 'object') return {};
	const phase = PHASES.includes(raw.phase) ? raw.phase : 'idle';
	const out = {
		phase,
		run_id: str(raw.run_id, 40),
		started_at: str(raw.started_at, 40),
		updated_at: str(raw.updated_at, 40),
		total: int(raw.total),
		uploaded: int(raw.uploaded),
		pending: int(raw.pending),
		current: str(raw.current, 300),
		batch: int(raw.batch),
		batches: int(raw.batches),
		message: str(raw.message, 300),
		error: str(raw.error, 300),
		log: str(raw.log, 2000),
		reported_at: now(),
	};
	if (raw.exit === null || raw.exit === undefined || raw.exit === '') out.exit = null;
	else out.exit = int(raw.exit);
	return out;
}

// ---------------------------------------------------------------------------
// app
// ---------------------------------------------------------------------------

/**
 * @param {{store:{get(k:string):Promise<string|null>, set(k:string,v:string):Promise<void>},
 *          auth:{getUser(r:Request, env:unknown):Promise<{sub:string,email?:string}|null>,
 *                loginUrl?:string, signoutUrl?:string, label?:string, configured?:boolean},
 *          origin:string,
 *          sameOrigin:(r:Request)=>boolean,
 *          live?:boolean}} config
 */
export function createApp(config) {
	const { store, auth, sameOrigin } = config;

	const kget = (key) => store.get(key);
	const kset = (key, value) => store.set(key, value);

	async function kjson(key, fallback) {
		const raw = await kget(key);
		if (!raw) return fallback;
		try {
			return JSON.parse(raw);
		} catch {
			return fallback;
		}
	}

	const ksetjson = (key, value) => kset(key, JSON.stringify(value));

	/**
	 * The signed-in user, confirmed to be the owner. The first account to reach
	 * the dashboard claims it; every other account gets 403 from then on.
	 */
	async function owner(request, env) {
		const user = await auth.getUser(request, env);
		if (!user) return { error: json({ error: 'sign in required' }, 401) };

		let ownerSub = await kget('owner_sub');
		if (!ownerSub) {
			await kset('owner_sub', user.sub);
			await kset('owner_email', user.email || '');
			ownerSub = user.sub;
		}
		if (ownerSub !== user.sub) return { error: json({ error: 'this dashboard belongs to another account' }, 403) };
		return { user };
	}

	/** The VM's own credential: no cookie, no session, just the device token. */
	async function device(request) {
		const token = bearer(request);
		if (!token) return false;
		const stored = await kget('device_token_hash');
		return Boolean(stored) && stored === (await sha256(token));
	}

	async function pushEvent(kind, message) {
		const events = await kjson('events', []);
		// An id is what lets the dashboard delete one entry instead of all of them.
		events.push({ id: crypto.randomUUID().slice(0, 8), t: now(), kind, message: str(message, 200) });
		await ksetjson('events', events.slice(-EVENT_LIMIT));
	}

	/**
	 * Keep the feed honest: only record a transition the operator can act on,
	 * not every heartbeat. A rising upload count is progress; a repeated error
	 * is not a new event.
	 */
	async function recordActivity(incoming) {
		const previous = await kjson('activity', {});
		const next = normalizeActivity(incoming);

		if (next.phase !== previous.phase) {
			const labels = {
				scanning: 'Scanning the node for new files',
				waiting: 'Waiting for the next run',
				uploading: `Uploading ${next.total || '?'} file(s)`,
				idle: 'Idle',
				error: 'Run failed',
			};
			if (next.phase in labels) await pushEvent(next.phase === 'error' ? 'error' : 'phase', labels[next.phase]);
		}
		if (next.uploaded > (previous.uploaded || 0)) {
			const delta = next.uploaded - (previous.uploaded || 0);
			await pushEvent('upload', `${delta} file(s) uploaded${next.current ? ` - ${next.current}` : ''}`);
		}
		if (next.error && next.error !== previous.error) await pushEvent('error', next.error);

		await ksetjson('activity', next);
		return next;
	}

	return async function handle(request, env) {
		const url = new URL(request.url);
		const path = url.pathname;
		const method = request.method;

		if (path === '/api/session' && method === 'GET') {
			const user = await auth.getUser(request, env);
			const ownerSub = await kget('owner_sub');
			return json({
				signedIn: Boolean(user),
				email: user?.email || '',
				isOwner: Boolean(user && ownerSub === user.sub),
				claimable: Boolean(user && !ownerSub),
				loginUrl: auth.loginUrl || null,
				signoutUrl: auth.signoutUrl || null,
				signoutMethod: auth.signoutMethod || 'POST',
				label: auth.label || 'Sign in',
				configured: auth.configured !== false,
				server_time: now(),
			});
		}

		if (path === '/api/dashboard' && method === 'GET') {
			const who = await owner(request, env);
			if (who.error) return who.error;

			const settings = { ...defaults(), ...(await kjson('settings', {})) };
			const commands = await kjson('commands', []);
			const events = await kjson('events', []);

			return json({
				settings,
				schema: SETTINGS,
				state: await kjson('state', {}),
				activity: await kjson('activity', {}),
				events: events.slice().reverse(),
				commands: commands.slice(-10).reverse(),
				device: { paired: Boolean(await kget('device_token_hash')) },
				accounts: await kjson('accounts', { list: [], selected: '' }),
				pendingCredential: Boolean(await kget('pending_cred')),
				ownerEmail: (await kget('owner_email')) || '',
				loginUrl: auth.loginUrl || null,
				signoutUrl: auth.signoutUrl || null,
				signoutMethod: auth.signoutMethod || 'POST',
				server_time: now(),
			});
		}

		// The live half: small, polled every few seconds by the open dashboard.
		if (path === '/api/activity' && method === 'GET') {
			const who = await owner(request, env);
			if (who.error) return who.error;

			const events = await kjson('events', []);
			const commands = await kjson('commands', []);
			return json({
				activity: await kjson('activity', {}),
				events: events.slice().reverse(),
				state: await kjson('state', {}),
				commands: commands.slice(-10).reverse(),
				accounts: await kjson('accounts', { list: [], selected: '' }),
				pendingCredential: Boolean(await kget('pending_cred')),
				server_time: now(),
			});
		}

		if (path === '/api/settings' && (method === 'PUT' || method === 'POST')) {
			if (!sameOrigin(request)) return json({ error: 'cross-origin request rejected' }, 403);
			const who = await owner(request, env);
			if (who.error) return who.error;

			const body = await request.json().catch(() => null);
			if (!body || typeof body !== 'object') return json({ error: 'expected a JSON object' }, 400);

			const result = validateAll(body);
			if ('errors' in result) return json({ errors: result.errors }, 400);

			await ksetjson('settings', result.settings);
			await pushEvent('settings', 'Settings saved from the dashboard');
			return json({ ok: true, settings: result.settings });
		}

		if (path === '/api/commands' && method === 'POST') {
			if (!sameOrigin(request)) return json({ error: 'cross-origin request rejected' }, 403);
			const who = await owner(request, env);
			if (who.error) return who.error;

			const body = await request.json().catch(() => null);
			const kind = String(body?.kind || '');
			if (!COMMAND_KINDS.includes(kind)) return json({ error: `kind must be one of ${COMMAND_KINDS.join(', ')}` }, 400);

			// Only the two account commands carry a value, and it is always an email.
			const needsArg = kind === 'creds-set' || kind === 'creds-remove';
			const arg = str(body?.arg, 120);
			if (needsArg && !EMAIL.test(arg)) return json({ error: 'arg must be an account email' }, 400);

			const commands = await kjson('commands', []);
			const entry = { id: crypto.randomUUID().slice(0, 8), kind, created_at: now(), done: false };
			if (needsArg) entry.arg = arg;
			commands.push(entry);
			await ksetjson('commands', commands.slice(-50));
			await pushEvent('command', needsArg ? `Queued "${kind}" for ${arg}` : `Queued "${kind}" for the relay`);
			return json({ ok: true, command: entry });
		}

		// ---- deleting the dashboard's own records --------------------------

		// Deliberately narrow: this drops history the dashboard keeps, never a
		// file on the relay and never anything in Google Photos. Emptying the
		// relay's own logs is a command, because only the box can do that.
		if ((path === '/api/events' || path.startsWith('/api/events/') || path === '/api/commands') && method === 'DELETE') {
			if (!sameOrigin(request)) return json({ error: 'cross-origin request rejected' }, 403);
			const who = await owner(request, env);
			if (who.error) return who.error;

			if (path === '/api/commands') {
				// A command the relay has not picked up yet is still work to do.
				const commands = await kjson('commands', []);
				const kept = commands.filter((c) => !c.done);
				await ksetjson('commands', kept);
				return json({ ok: true, removed: commands.length - kept.length });
			}

			const events = await kjson('events', []);
			if (path === '/api/events') {
				await ksetjson('events', []);
				return json({ ok: true, removed: events.length });
			}

			const id = decodeURIComponent(path.slice('/api/events/'.length));
			const kept = events.filter((e) => e.id !== id);
			if (kept.length === events.length) return json({ error: 'no such event' }, 404);
			await ksetjson('events', kept);
			return json({ ok: true, removed: 1 });
		}

		if (path === '/api/device/token' && method === 'GET') {
			const who = await owner(request, env);
			if (who.error) return who.error;
			return json({ paired: Boolean(await kget('device_token_hash')) });
		}

		if (path === '/api/device/token' && method === 'POST') {
			if (!sameOrigin(request)) return json({ error: 'cross-origin request rejected' }, 403);
			const who = await owner(request, env);
			if (who.error) return who.error;

			// Shown exactly once. Only the hash is stored, the way a password would be.
			const token = randomToken();
			await kset('device_token_hash', await sha256(token));
			await pushEvent('device', 'New device token issued');
			return json({ ok: true, token });
		}

		// ---- device channel: authenticated by a device token, never a session ---

		if (path === '/api/device/poll' && method === 'POST') {
			if (!(await device(request))) return text('unauthorized', 401);

			const state = parseKv(await request.text());
			await ksetjson('state', { ...state, reported_at: now() });

			const settings = { ...defaults(), ...(await kjson('settings', {})) };
			const commands = await kjson('commands', []);
			const pending = commands.filter((c) => !c.done);

			const lines = Object.entries(settings).map(([k, v]) => `SET ${k}=${v}`);
			for (const c of pending) lines.push(`CMD ${c.id} ${c.kind}${c.arg ? ` ${c.arg}` : ''}`);

			// A credential handed in from the dashboard is delivered exactly once
			// and then forgotten, so a stolen dashboard session cannot re-read it
			// and the VM does not depend on a second round trip.
			const pendingCred = await kjson('pending_cred', null);
			if (pendingCred?.value) {
				lines.push(`CREDS ${b64(pendingCred.value)}`);
				await kset('pending_cred', '');
			}

			return text(`${lines.join('\n')}\n`);
		}

		// Live progress. Separately from the poll so a large log tail never
		// disturbs the settings/command exchange.
		if (path === '/api/device/activity' && method === 'POST') {
			if (!(await device(request))) return text('unauthorized', 401);

			const raw = await request.text();
			if (raw.length > ACTIVITY_LIMIT) return text('too large', 413);

			let body;
			try {
				body = JSON.parse(raw);
			} catch {
				return text('expected JSON', 400);
			}

			const activity = await recordActivity(body?.activity ?? body);
			if (body?.log) activity.log = str(body.log, 2000).replace(/[^\t\n\x20-\x7e]/g, '');
			await ksetjson('activity', activity);
			return json({ ok: true });
		}

		if (path === '/api/device/result' && method === 'POST') {
			if (!(await device(request))) return text('unauthorized', 401);

			const commands = await kjson('commands', []);
			const body = await request.text();
			let changed = false;

			for (const line of body.split('\n')) {
				const text_ = line.trim();

				const match = /^RESULT\s+(\S+)\s+(ok|fail)(?:\s+(.*))?$/.exec(text_);
				if (match) {
					const target = commands.find((c) => c.id === match[1]);
					if (!target || target.done) continue;
					target.done = true;
					target.ok = match[2] === 'ok';
					target.output = (match[3] || '').slice(0, 500);
					target.done_at = now();
					changed = true;
					await pushEvent(target.ok ? 'command' : 'error', `"${target.kind}" ${target.ok ? 'done' : 'failed'}: ${target.output || ''}`);
					continue;
				}

				// The account list the box actually holds, after any change.
				if (text_.startsWith('ACCOUNTS ')) {
					let parsed;
					try {
						parsed = JSON.parse(text_.slice('ACCOUNTS '.length));
					} catch {
						continue;
					}
					const list = Array.isArray(parsed?.list) ? parsed.list : [];
					const clean = list
						.filter((a) => EMAIL.test(String(a?.email || '')))
						.slice(0, 20)
						.map((a) => ({ email: String(a.email), selected: Boolean(a.selected) }));
					const selected = clean.find((a) => a.selected)?.email || str(parsed?.selected, 120);
					await ksetjson('accounts', { list: clean, selected });
					continue;
				}

				if (text_.startsWith('CREDS_RESULT ')) {
					const rest = text_.slice('CREDS_RESULT '.length);
					const ok = rest.startsWith('ok');
					const detail = rest.replace(/^(ok|fail)\s*/, '').slice(0, 300);
					await pushEvent(ok ? 'upsert' : 'error', ok ? `Google account added: ${detail}` : `Google sign-in failed: ${detail}`);
				}
			}

			if (changed) await ksetjson('commands', commands);
			return json({ ok: true });
		}

		// ---- accounts -----------------------------------------------------

		if (path === '/api/accounts/credential' && method === 'POST') {
			if (!sameOrigin(request)) return json({ error: 'cross-origin request rejected' }, 403);
			const who = await owner(request, env);
			if (who.error) return who.error;

			const body = await request.json().catch(() => null);
			const value = String(body?.value || '').trim();
			if (value.length < 8) return json({ error: 'that does not look like an oauth_token value' }, 400);
			if (value.length > 4096) return json({ error: 'that value is too long to be a cookie' }, 400);
			if (/[\s\x00-\x1f\x7f]/.test(value)) return json({ error: 'the value contains whitespace or control characters' }, 400);

			await ksetjson('pending_cred', { value, created_at: now() });
			await pushEvent('upsert', 'Google sign-in handed to the relay');
			return json({ ok: true });
		}

		if (path === '/api/accounts/select' && method === 'POST') {
			if (!sameOrigin(request)) return json({ error: 'cross-origin request rejected' }, 403);
			const who = await owner(request, env);
			if (who.error) return who.error;

			const email = str((await request.json().catch(() => null))?.email, 120);
			if (!EMAIL.test(email)) return json({ error: 'email is required' }, 400);

			const commands = await kjson('commands', []);
			commands.push({ id: crypto.randomUUID().slice(0, 8), kind: 'creds-set', arg: email, created_at: now(), done: false });
			await ksetjson('commands', commands.slice(-50));
			await pushEvent('command', `Switching uploads to ${email}`);
			return json({ ok: true });
		}

		if (path === '/api/accounts/remove' && method === 'POST') {
			if (!sameOrigin(request)) return json({ error: 'cross-origin request rejected' }, 403);
			const who = await owner(request, env);
			if (who.error) return who.error;

			const email = str((await request.json().catch(() => null))?.email, 120);
			if (!EMAIL.test(email)) return json({ error: 'email is required' }, 400);

			const commands = await kjson('commands', []);
			commands.push({ id: crypto.randomUUID().slice(0, 8), kind: 'creds-remove', arg: email, created_at: now(), done: false });
			await ksetjson('commands', commands.slice(-50));
			await pushEvent('command', `Removing ${email} from the relay`);
			return json({ ok: true });
		}

		if (path.startsWith('/api/')) return json({ error: 'not found' }, 404);

		return null;
	};
}
