// Storage for the Vercel build: Turso (libSQL) over its HTTP pipeline API.
//
// The relay keeps eleven small JSON strings, read and written through
// /api/state/get and /api/state/set. They used to live in the D1 database behind
// the Freebuff Sites deployment of this same app, which pauses the whole site
// once its 10,000 daily requests are spent - taking the dashboard down with it
// and making the login page claim no password was set. A database with real
// headroom is the durable answer: this store spends roughly 3,000 requests a day
// against a free allowance measured in millions.
//
// No SDK is involved: the pipeline endpoint takes a JSON array of statements
// over HTTPS with a bearer token, which is all this needs.
const TTL_MS = 1500;
const memo = new Map();

export function tursoStore(env, options = {}) {
	// The CLI hands out libsql:// URLs; the HTTP endpoint is the same host over
	// https://, so both forms are accepted.
	const endpoint = () =>
		`${String(env.TURSO_DATABASE_URL || '')
			.trim()
			.replace(/\/+$/, '')
			.replace(/^libsql:/, 'https:')}/v2/pipeline`;
	const token = () => String(env.TURSO_AUTH_TOKEN || '').trim();

	// The previous store, used only to seed keys this one has never seen, so the
	// switch does not lose the device pairing hash or the stored accounts.
	const importFrom = options.importFrom || null;

	let ready;

	const arg = (value) => ({ type: 'text', value: String(value) });

	async function pipeline(requests) {
		const response = await fetch(endpoint(), {
			method: 'POST',
			headers: { 'content-type': 'application/json', authorization: `Bearer ${token()}` },
			body: JSON.stringify({ requests: [...requests, { type: 'close' }] }),
		});
		if (!response.ok) {
			const detail = (await response.text()).slice(0, 120);
			throw new Error(`relay state turso failed: ${response.status} ${detail}`);
		}
		return response.json();
	}

	function rowsOf(body, index = 0) {
		const result = body?.results?.[index];
		if (!result || result.type !== 'ok') {
			const message = result?.error?.message || 'turso rejected the statement';
			throw new Error(`relay state turso failed: ${message}`);
		}
		const rows = result.response?.result?.rows || [];
		return rows.map((row) => row.map((cell) => (cell?.type === 'null' ? null : (cell?.value ?? null))));
	}

	// Once per instance, not per request. An empty table is the only schema step
	// this store needs.
	function ensure() {
		ready ??= pipeline([
			{ type: 'execute', stmt: { sql: 'CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT NOT NULL)' } },
		]).catch((error) => {
			ready = undefined;
			throw error;
		});
		return ready;
	}

	async function getDirect(key) {
		await ensure();
		const body = await pipeline([
			{ type: 'execute', stmt: { sql: 'SELECT v FROM kv WHERE k = ?', args: [arg(key)] } },
		]);
		const rows = rowsOf(body);
		return rows.length ? rows[0][0] : null;
	}

	async function setDirect(key, value) {
		await ensure();
		await pipeline([
			{
				type: 'execute',
				stmt: {
					sql: 'INSERT INTO kv (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v',
					args: [arg(key), arg(value)],
				},
			},
		]);
		memo.set(key, { at: Date.now(), value });
	}

	// The old store can be paused, and a failure there must not look like a
	// failure here: it only means the key stays absent.
	async function importKey(key) {
		if (!importFrom) return null;
		try {
			const value = await importFrom.get(key);
			if (typeof value !== 'string' || !value) return null;
			await setDirect(key, value);
			return value;
		} catch {
			return null;
		}
	}

	function remember(key, value) {
		memo.set(key, { at: Date.now(), value });
		return value;
	}

	return {
		async get(key) {
			const hit = memo.get(key);
			if (hit && Date.now() - hit.at <= TTL_MS) return hit.value;

			const value = await getDirect(key);
			if (value !== null) return remember(key, value);
			return remember(key, await importKey(key));
		},

		// One round trip for several keys: the device heartbeat reads four on every
		// poll, and separate reads are what exhausted the last host.
		async getMany(keys) {
			if (!keys.length) return {};
			await ensure();
			const body = await pipeline([
				{
					type: 'execute',
					stmt: {
						sql: `SELECT k, v FROM kv WHERE k IN (${keys.map(() => '?').join(',')})`,
						args: keys.map(arg),
					},
				},
			]);

			const out = {};
			for (const [key, value] of rowsOf(body)) out[key] = value;

			for (const key of keys) {
				if (out[key] === undefined) out[key] = await importKey(key);
				remember(key, out[key]);
			}
			return out;
		},

		async set(key, value) {
			await setDirect(key, value);
		},
	};
}
